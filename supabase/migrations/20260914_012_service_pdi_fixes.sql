-- Service & PDI Critical Fixes
-- 1. ws_save_pdi: enforce lifecycle = 'pdi_pending' strictly
-- 2. ws_finalize: normalize cost=0 server-side, only require price+gst
-- 3. Unique partial index: one active PDI per vehicle

BEGIN;

-- 1. Replace ws_save_pdi with strict pdi_pending enforcement
CREATE OR REPLACE FUNCTION public.ws_save_pdi(p jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE old public.pdi_checks;r public.pdi_checks;v public.vehicles;item jsonb;baseline jsonb;result text:=coalesce(p->>'result','pending');id uuid:=nullif(p->>'id','')::uuid;
BEGIN
 IF NOT public.has_permission('pdi.write') THEN RAISE EXCEPTION 'PDI edit permission required'; END IF;
 SELECT * INTO old FROM public.pdi_checks WHERE pdi_checks.id=id FOR UPDATE;
 IF NOT FOUND THEN
  SELECT * INTO v FROM public.vehicles WHERE vehicles.id=(p->>'vehicle_id')::uuid FOR UPDATE;
  IF NOT FOUND OR v.lifecycle <> 'pdi_pending' THEN RAISE EXCEPTION 'Select an undelivered vehicle awaiting PDI'; END IF;
  IF NOT public.has_permission('service.write') AND coalesce(p->>'inspector_email',public.ws_email())<>public.ws_email() THEN RAISE EXCEPTION 'Assign yourself or ask a manager'; END IF;
  IF EXISTS(SELECT 1 FROM public.pdi_checks WHERE vehicle_id=v.id) THEN RAISE EXCEPTION 'Open the existing PDI record for this vehicle'; END IF;
  SELECT items INTO baseline FROM public.pdi_templates WHERE vehicle_type=v.vehicle_type;
  IF baseline IS NULL THEN RAISE EXCEPTION 'Configure a checklist template first'; END IF;
  INSERT INTO public.pdi_checks(vehicle_id,inspector_email,checklist) VALUES(v.id,coalesce(p->>'inspector_email',public.ws_email()),baseline) RETURNING * INTO r;
 ELSE
  IF NOT public.has_permission('service.write') AND old.inspector_email<>public.ws_email() THEN RAISE EXCEPTION 'Only the assigned inspector may edit'; END IF;
  IF (p->>'updated_at')::timestamptz IS DISTINCT FROM old.updated_at THEN RAISE EXCEPTION 'PDI changed. Reload first.'; END IF;
  SELECT * INTO v FROM public.vehicles WHERE vehicles.id=old.vehicle_id FOR UPDATE;
  IF v.lifecycle IN ('sold','delivered') THEN RAISE EXCEPTION 'Delivered PDI history is locked'; END IF;
  IF jsonb_typeof(p->'checklist') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'checklist')<>jsonb_array_length(old.checklist) THEN RAISE EXCEPTION 'Checklist items cannot be removed'; END IF;
  FOR baseline IN SELECT value FROM jsonb_array_elements(old.checklist) LOOP
   SELECT value INTO item FROM jsonb_array_elements(p->'checklist') WHERE value->>'id'=baseline->>'id';
   IF item IS NULL OR item->>'label' IS DISTINCT FROM baseline->>'label' OR item->>'section' IS DISTINCT FROM baseline->>'section' OR item->'required' IS DISTINCT FROM baseline->'required' THEN RAISE EXCEPTION 'Checklist identity cannot change'; END IF;
   IF coalesce(item->>'result','') NOT IN ('','pass','fail','na') THEN RAISE EXCEPTION 'Invalid checklist result'; END IF;
   IF result<>'pending' AND (coalesce(item->>'result','')='' OR (baseline->>'required')::boolean AND item->>'result'='na') THEN RAISE EXCEPTION 'Complete all mandatory PDI checks'; END IF;
   IF result='passed' AND item->>'result'='fail' THEN RAISE EXCEPTION 'Failed checks cannot be marked passed'; END IF;
  END LOOP;
  IF result='issues' AND (NOT public.has_permission('service_approve.write') OR length(trim(coalesce(p->>'corrective_action','')))<3) THEN RAISE EXCEPTION 'Manager approval and corrective action required for issues'; END IF;
  IF result='failed' AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p->'checklist') x WHERE x->>'result'='fail') THEN RAISE EXCEPTION 'Mark the failed checklist item'; END IF;
  UPDATE public.pdi_checks SET checklist=p->'checklist',result=result,passed=result IN ('passed','issues'),corrective_action=coalesce(p->>'corrective_action',''),responsible_email=coalesce(p->>'responsible_email',''),inspector_email=CASE WHEN public.has_permission('service.write') THEN coalesce(p->>'inspector_email',old.inspector_email) ELSE old.inspector_email END,inspected_at=CASE WHEN result<>'pending' THEN now() END,updated_at=clock_timestamp() WHERE pdi_checks.id=id RETURNING * INTO r;
  IF v.stock_id IS NOT NULL THEN
   IF old.result NOT IN ('passed','issues') AND result IN ('passed','issues') THEN UPDATE public.inventory SET qty_reserved=qty_reserved-1 WHERE inventory.id=v.stock_id AND qty_reserved>0;
   ELSIF old.result IN ('passed','issues') AND result NOT IN ('passed','issues') THEN UPDATE public.inventory SET qty_reserved=qty_reserved+1 WHERE inventory.id=v.stock_id AND qty_available>qty_reserved; IF NOT FOUND THEN RAISE EXCEPTION 'Vehicle stock already consumed; cannot reopen PDI'; END IF;
   END IF;
  END IF;
  UPDATE public.vehicles SET lifecycle=CASE result WHEN 'passed' THEN 'available' WHEN 'issues' THEN 'pdi_issues' WHEN 'failed' THEN 'pdi_failed' ELSE 'pdi_pending' END WHERE vehicles.id=v.id;
 END IF;
 PERFORM public.ws_audit('pdi',r.id,v.customer_id,v.id,'PDI updated',to_jsonb(old),to_jsonb(r)); RETURN r.id;
END $$;

-- 2. Replace ws_finalize with server-side cost normalization
CREATE OR REPLACE FUNCTION public.ws_finalize(p_job uuid,p_number text,p_tax_mode text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE j public.service_jobs;v public.vehicles;lines jsonb:='[]';part jsonb;rate jsonb;stock public.inventory;doc jsonb; inv uuid; cost numeric:=0;before_movement bigint;
 part_price numeric; part_discount numeric; part_gst numeric; part_gross numeric;
 labour_charge numeric; labour_discount numeric; labour_gst numeric;
BEGIN
 IF NOT public.has_permission('service_finance.write') OR NOT public.has_permission('service_approve.write') THEN RAISE EXCEPTION 'Service financial approval required'; END IF;
 SELECT * INTO j FROM public.service_jobs WHERE id=p_job FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Job not found'; END IF;
 IF j.invoice_id IS NOT NULL THEN RETURN j.invoice_id; END IF;
 IF j.status<>'ready_for_delivery' THEN RAISE EXCEPTION 'Review work and mark Ready for Delivery first'; END IF;
 SELECT * INTO v FROM public.vehicles WHERE id=j.vehicle_id;

 -- Process parts: only require price and gst, inject cost=0 server-side
 FOR part IN SELECT value FROM jsonb_array_elements(j.parts_used) LOOP
  SELECT * INTO stock FROM public.inventory WHERE id=(part->>'inventoryId')::uuid;
  rate:=j.financials->'rates'->stock.id::text;
  IF rate IS NULL OR NOT rate ?& ARRAY['price','gst'] THEN RAISE EXCEPTION 'Set selling price and GST for every part'; END IF;

  part_price := coalesce((rate->>'price')::numeric, 0);
  part_discount := coalesce((rate->>'discount')::numeric, 0);
  part_gst := coalesce((rate->>'gst')::numeric, 0);
  part_gross := part_price * (part->>'qty')::numeric;

  IF part_price < 0 OR part_price > 100000000 THEN RAISE EXCEPTION 'Invalid selling price'; END IF;
  IF part_discount < 0 OR part_discount > part_gross THEN RAISE EXCEPTION 'Discount cannot exceed gross amount'; END IF;
  IF part_gst < 0 OR part_gst > 100 THEN RAISE EXCEPTION 'GST rate must be between 0 and 100'; END IF;

  -- cost is always 0 for billing purposes (internal cost not tracked through service invoices)
  cost := cost + 0;

  lines:=lines||jsonb_build_array(jsonb_build_object('productId',stock.item_id,'inventoryId',stock.id,'name',stock.item_name,'hsnCode',coalesce(rate->>'hsn',''),'qty',(part->>'qty')::int,'unitPrice',part_price,'discount',part_discount,'gstRatePct',part_gst));
 END LOOP;

 -- Process labour: only require labour_charge, inject labour_cost=0 server-side
 labour_charge := coalesce((j.financials->>'labour_charge')::numeric, 0);
 labour_discount := coalesce((j.financials->>'labour_discount')::numeric, 0);
 labour_gst := coalesce((j.financials->>'labour_gst')::numeric, 0);

 IF labour_charge < 0 OR labour_charge > 100000000 THEN RAISE EXCEPTION 'Invalid labour charge'; END IF;
 IF labour_discount < 0 OR labour_discount > labour_charge THEN RAISE EXCEPTION 'Labour discount cannot exceed charge'; END IF;
 IF labour_gst < 0 OR labour_gst > 100 THEN RAISE EXCEPTION 'Labour GST must be between 0 and 100'; END IF;

 lines:=lines||jsonb_build_array(jsonb_build_object('productId',NULL,'inventoryId',NULL,'name','Labour / Service','hsnCode',coalesce(j.financials->>'labour_hsn',''),'qty',1,'unitPrice',labour_charge,'discount',labour_discount,'gstRatePct',labour_gst));

 SELECT coalesce(max(id),0) INTO before_movement FROM public.stock_movements;
 doc:=public.ws_base_save_document(jsonb_build_object('kind','invoice','number',p_number,'customerId',j.customer_id,'date',current_date,'items',lines,'taxMode',p_tax_mode,'notes','Job: '||j.number||E'\nVehicle: '||v.model_name||' '||v.variant||E'\nChassis: '||v.chassis_no||E'\nRegistration: '||coalesce(v.registration_no,'')||E'\nComplaint: '||j.complaint||E'\nWork: '||j.work_performed||E'\nTechnicians: '||array_to_string(j.technician_emails,', ')));
 inv:=(doc->>'id')::uuid;
 UPDATE public.billing_documents SET service_job_id=j.id,finalized_at=now() WHERE id=inv;
 UPDATE public.service_jobs SET invoice_id=inv,status=CASE WHEN (doc->>'total')::numeric=0 THEN 'paid' ELSE 'invoiced' END,updated_at=clock_timestamp() WHERE id=j.id;
 UPDATE public.stock_movements SET job_id=j.id,invoice_id=inv,movement_type='service_consumption' WHERE id>before_movement AND actor=auth.uid() AND reference=doc->>'number';
 PERFORM public.ws_audit('job',j.id,j.customer_id,j.vehicle_id,'Service invoice finalized',to_jsonb(j),doc); RETURN inv;
END $$;

-- 3. Unique partial index: prevent multiple active PDIs for the same vehicle
CREATE UNIQUE INDEX IF NOT EXISTS pdi_one_active_per_vehicle
ON public.pdi_checks(vehicle_id)
WHERE result IN ('pending', 'issues');

COMMIT;
