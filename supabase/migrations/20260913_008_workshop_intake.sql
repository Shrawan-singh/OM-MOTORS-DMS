BEGIN;
CREATE FUNCTION public.ws_save_vehicle(p jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE old public.vehicles;v public.vehicles;prod public.catalog_products;stock uuid;checklist jsonb;pid uuid;id uuid:=coalesce(nullif(p->>'id','')::uuid,gen_random_uuid());intake boolean:=coalesce((p->>'intake')::boolean,false);
BEGIN
 IF NOT public.has_permission('service.write') AND NOT public.has_permission('pdi.write') THEN RAISE EXCEPTION 'Vehicle intake permission required'; END IF;
 SELECT * INTO old FROM public.vehicles WHERE vehicles.id=id FOR UPDATE;
 IF old.id IS NOT NULL THEN
  IF NOT public.has_permission('service.write') THEN RAISE EXCEPTION 'Manager required for vehicle corrections'; END IF;
  IF (p->>'updated_at')::timestamptz IS DISTINCT FROM old.updated_at THEN RAISE EXCEPTION 'Vehicle changed. Reload before saving.'; END IF;
  IF length(trim(coalesce(p->>'correction_reason','')))<5 THEN RAISE EXCEPTION 'A correction reason is required'; END IF;
  IF length(trim(coalesce(p->>'model_name','')))<2 OR length(trim(coalesce(p->>'chassis_no','')))<3 THEN RAISE EXCEPTION 'Model and chassis required'; END IF;
  UPDATE public.vehicles SET model_name=trim(p->>'model_name'),variant=coalesce(p->>'variant',''),chassis_no=upper(trim(p->>'chassis_no')),engine_no=nullif(upper(trim(p->>'engine_no')),''),motor_no=nullif(upper(trim(p->>'motor_no')),''),battery_no=nullif(upper(trim(p->>'battery_no')),''),registration_no=nullif(upper(trim(p->>'registration_no')),''),colour=coalesce(p->>'colour',''),location=coalesce(p->>'location',''),updated_at=clock_timestamp() WHERE vehicles.id=id RETURNING * INTO v;
  PERFORM public.ws_audit('vehicle',id,v.customer_id,id,'Vehicle details corrected',to_jsonb(old),to_jsonb(v),p->>'correction_reason');RETURN id;
 END IF;
 IF NOT intake AND NOT public.has_permission('service.write') THEN RAISE EXCEPTION 'Service manager required for customer vehicle registration'; END IF;
 IF length(trim(coalesce(p->>'chassis_no','')))<3 OR length(trim(coalesce(p->>'model_name','')))<2 THEN RAISE EXCEPTION 'Model and chassis required'; END IF;
 IF intake AND nullif(p->>'product_id','') IS NULL THEN RAISE EXCEPTION 'Choose a catalogue product for stock intake'; END IF;
 IF NOT intake AND nullif(p->>'customer_id','') IS NULL THEN RAISE EXCEPTION 'Choose the vehicle owner'; END IF;
 IF nullif(p->>'purchase_invoice_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.billing_documents b WHERE b.id=(p->>'purchase_invoice_id')::uuid AND b.kind='invoice' AND b.cancelled_at IS NULL AND b.customer_id=(p->>'customer_id')::uuid) THEN RAISE EXCEPTION 'Purchase invoice does not match customer'; END IF;
 IF intake THEN
  IF NOT EXISTS(SELECT 1 FROM public.access_assignments a WHERE a.email=coalesce(nullif(p->>'inspector_email',''),public.ws_email()) AND a.active AND (a.role='owner' OR EXISTS(SELECT 1 FROM public.access_permissions ap WHERE ap.role=a.role AND ap.permission='pdi.write'))) THEN RAISE EXCEPTION 'Select an active inspector with PDI permission'; END IF;
  IF NOT public.has_permission('service.write') AND coalesce(nullif(p->>'inspector_email',''),public.ws_email())<>public.ws_email() THEN RAISE EXCEPTION 'Only managers can assign another inspector'; END IF;
  SELECT * INTO prod FROM public.catalog_products WHERE catalog_products.id=(p->>'product_id')::uuid;
  IF NOT FOUND OR prod.category NOT IN ('tractor','e_rickshaw','cng_rickshaw','diesel_rickshaw') THEN RAISE EXCEPTION 'Choose a vehicle product'; END IF;
  INSERT INTO public.inventory(item_type,item_id,item_name,sku_or_code,qty_available) VALUES('vehicle',prod.id,prod.model_name,prod.code,0) ON CONFLICT(item_type,item_id) DO NOTHING;
  SELECT i.id INTO stock FROM public.inventory i WHERE i.item_id=prod.id AND i.item_type='vehicle';
  PERFORM public.app_move_stock(stock,1,coalesce(nullif(p->>'shipment_ref',''),'Vehicle intake '||(p->>'chassis_no')));
  SELECT i.id INTO stock FROM public.inventory i WHERE i.item_id=(p->>'product_id')::uuid AND i.item_type='vehicle';
  IF stock IS NULL THEN RAISE EXCEPTION 'Select a vehicle category product'; END IF;
  UPDATE public.inventory SET qty_reserved=qty_reserved+1 WHERE inventory.id=stock;
 END IF;
 INSERT INTO public.vehicles(id,product_id,model_name,variant,vehicle_type,chassis_no,engine_no,motor_no,battery_no,registration_no,colour,customer_id,purchase_invoice_id,purchase_date,received_date,location,manufacturer,shipment_ref,supplier_invoice,lifecycle,stock_id)
 VALUES(id,nullif(p->>'product_id','')::uuid,trim(p->>'model_name'),coalesce(p->>'variant',''),coalesce(p->>'vehicle_type','tractor'),upper(trim(p->>'chassis_no')),nullif(upper(trim(p->>'engine_no')),''),nullif(upper(trim(p->>'motor_no')),''),nullif(upper(trim(p->>'battery_no')),''),nullif(upper(trim(p->>'registration_no')),''),coalesce(p->>'colour',''),nullif(p->>'customer_id','')::uuid,nullif(p->>'purchase_invoice_id','')::uuid,nullif(p->>'purchase_date','')::date,coalesce(nullif(p->>'received_date','')::date,current_date),coalesce(p->>'location',''),coalesce(p->>'manufacturer',''),coalesce(p->>'shipment_ref',''),coalesce(p->>'supplier_invoice',''),CASE WHEN intake THEN 'pdi_pending' ELSE 'delivered' END,stock) RETURNING * INTO v;
 IF intake THEN
  SELECT items INTO checklist FROM public.pdi_templates WHERE vehicle_type=v.vehicle_type;
  IF checklist IS NULL THEN RAISE EXCEPTION 'Configure a PDI template for this vehicle type first'; END IF;
  INSERT INTO public.pdi_checks(vehicle_id,inspector_email,checklist) VALUES(id,coalesce(p->>'inspector_email',public.ws_email()),checklist) RETURNING pdi_checks.id INTO pid;
 END IF;
 PERFORM public.ws_audit('vehicle',id,v.customer_id,id,CASE WHEN intake THEN 'Vehicle received and PDI created' ELSE 'Customer vehicle registered' END,NULL,to_jsonb(v)); RETURN id;
END $$;
CREATE FUNCTION public.ws_save_pdi(p jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE old public.pdi_checks;r public.pdi_checks;v public.vehicles;item jsonb;baseline jsonb;result text:=coalesce(p->>'result','pending');id uuid:=nullif(p->>'id','')::uuid;
BEGIN
 IF NOT public.has_permission('pdi.write') THEN RAISE EXCEPTION 'PDI edit permission required'; END IF;
 SELECT * INTO old FROM public.pdi_checks WHERE pdi_checks.id=id FOR UPDATE;
 IF NOT FOUND THEN
  SELECT * INTO v FROM public.vehicles WHERE vehicles.id=(p->>'vehicle_id')::uuid FOR UPDATE;
  IF NOT FOUND OR v.lifecycle IN ('sold','delivered') THEN RAISE EXCEPTION 'Select an undelivered vehicle'; END IF;
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
CREATE FUNCTION public.ws_save_template(p jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE id uuid;item jsonb;
BEGIN
 IF NOT public.has_permission('service_approve.write') OR NOT public.has_permission('pdi.write') THEN RAISE EXCEPTION 'Manager PDI approval required'; END IF;
 IF length(trim(coalesce(p->>'name','')))<3 OR jsonb_typeof(p->'items') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'items') NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Name and 1–100 checklist items required'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(p->'items') LOOP
 IF length(coalesce(item->>'label',''))<2 OR item->>'id' IS NULL OR jsonb_typeof(item->'required')<>'boolean' THEN RAISE EXCEPTION 'Invalid checklist item'; END IF; END LOOP;
 IF (SELECT count(DISTINCT x->>'id') FROM jsonb_array_elements(p->'items') x)<>jsonb_array_length(p->'items') THEN RAISE EXCEPTION 'Duplicate checklist identifiers'; END IF;
 INSERT INTO public.pdi_templates(name,vehicle_type,items) VALUES(p->>'name',p->>'vehicle_type',(SELECT jsonb_agg(x||jsonb_build_object('result','','notes','')) FROM jsonb_array_elements(p->'items') x)) ON CONFLICT(vehicle_type) DO UPDATE SET name=excluded.name,items=excluded.items,updated_at=clock_timestamp() RETURNING pdi_templates.id INTO id;
 PERFORM public.ws_audit('template',id,NULL,NULL,'Checklist template saved',NULL,p); RETURN id;
END $$;
COMMIT;
