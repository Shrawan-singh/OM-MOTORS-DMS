BEGIN;
CREATE FUNCTION public.ws_save_warranty(p jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE old public.warranties;w public.warranties;b public.billing_documents;id uuid:=coalesce(nullif(p->>'id','')::uuid,gen_random_uuid());
BEGIN
 IF NOT public.has_permission('warranty.write') THEN RAISE EXCEPTION 'Warranty edit access required'; END IF;
 SELECT * INTO old FROM public.warranties WHERE warranties.id=id FOR UPDATE;
 IF old.id IS NOT NULL AND (p->>'updated_at')::timestamptz IS DISTINCT FROM old.updated_at THEN RAISE EXCEPTION 'Warranty changed; reload'; END IF;
 IF old.id IS NOT NULL AND NOT public.has_permission('service_approve.write') THEN RAISE EXCEPTION 'Manager approval required to change registered coverage'; END IF;
 IF length(trim(coalesce(p->>'serial_no','')))<3 OR length(trim(coalesce(p->>'coverage_evidence','')))<5 OR length(trim(coalesce(p->>'product_name','')))<2 THEN RAISE EXCEPTION 'Product, serial and verified coverage evidence required'; END IF;
 IF (p->>'end_date')::date<(p->>'start_date')::date THEN RAISE EXCEPTION 'Invalid coverage dates'; END IF;
 IF EXISTS(SELECT 1 FROM public.warranties w WHERE lower(trim(w.serial_no))=lower(trim(p->>'serial_no')) AND w.id<>id) THEN RAISE EXCEPTION 'Serial already has a warranty; open that record'; END IF;
 IF nullif(p->>'vehicle_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.vehicles WHERE vehicles.id=(p->>'vehicle_id')::uuid AND customer_id=(p->>'customer_id')::uuid) THEN RAISE EXCEPTION 'Vehicle must belong to selected customer'; END IF;
 IF nullif(p->>'billing_invoice_id','') IS NOT NULL THEN SELECT * INTO b FROM public.billing_documents WHERE billing_documents.id=(p->>'billing_invoice_id')::uuid AND kind='invoice' AND cancelled_at IS NULL AND customer_id=(p->>'customer_id')::uuid; IF NOT FOUND THEN RAISE EXCEPTION 'Invoice must belong to customer'; END IF; END IF;
 INSERT INTO public.warranties(id,item_type,item_id,serial_no,customer_id,invoice_no,start_date,end_date,vehicle_id,product_id,billing_invoice_id,product_name,brand,coverage_evidence)
 VALUES(id,(p->>'item_type')::public.item_type,coalesce(nullif(p->>'product_id','')::uuid,nullif(p->>'vehicle_id','')::uuid,id),upper(trim(p->>'serial_no')),(p->>'customer_id')::uuid,coalesce(b.number,nullif(p->>'invoice_no',''),'External purchase'),(p->>'start_date')::date,(p->>'end_date')::date,nullif(p->>'vehicle_id','')::uuid,nullif(p->>'product_id','')::uuid,b.id,p->>'product_name',coalesce(p->>'brand',''),p->>'coverage_evidence')
 ON CONFLICT ON CONSTRAINT warranties_pkey DO UPDATE SET start_date=excluded.start_date,end_date=excluded.end_date,coverage_evidence=excluded.coverage_evidence,updated_at=clock_timestamp() RETURNING * INTO w;
 PERFORM public.ws_audit('warranty',id,w.customer_id,w.vehicle_id,'Warranty coverage registered',to_jsonb(old),to_jsonb(w),p->>'coverage_evidence'); RETURN id;
END $$;
CREATE FUNCTION public.ws_save_claim(p jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE old public.warranty_claims;c public.warranty_claims;w public.warranties;replacement_stock uuid;id uuid:=coalesce(nullif(p->>'id','')::uuid,gen_random_uuid());next_status text:=coalesce(p->>'status','new');
BEGIN
 IF NOT public.has_permission('warranty.write') THEN RAISE EXCEPTION 'Warranty claim access required'; END IF;
 SELECT * INTO old FROM public.warranty_claims WHERE warranty_claims.id=id FOR UPDATE;
 IF old.id IS NOT NULL AND (p->>'updated_at')::timestamptz IS DISTINCT FROM old.updated_at THEN RAISE EXCEPTION 'Claim changed; reload'; END IF;
 IF old.status='closed' THEN RAISE EXCEPTION 'Closed claim history is locked'; END IF;
 SELECT * INTO w FROM public.warranties WHERE warranties.id=coalesce(old.warranty_id,(p->>'warranty_id')::uuid) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Select a stored warranty'; END IF;
 IF length(trim(coalesce(p->>'complaint_description','')))<3 THEN RAISE EXCEPTION 'Claim issue required'; END IF;
 IF old.id IS NULL AND next_status<>'new' THEN RAISE EXCEPTION 'Claims start as new'; END IF;
 IF old.id IS NOT NULL AND next_status<>old.status AND NOT ((old.status='new' AND next_status='inspection') OR (old.status='inspection' AND next_status='submitted') OR (old.status='submitted' AND next_status IN ('approved','rejected')) OR (old.status='approved' AND next_status IN ('repair','replacement')) OR (old.status IN ('repair','replacement','rejected') AND next_status='closed')) THEN RAISE EXCEPTION 'Invalid claim transition'; END IF;
 IF next_status IN ('approved','rejected') AND (NOT public.has_permission('service_approve.write') OR length(trim(coalesce(p->>'review_reason','')))<5) THEN RAISE EXCEPTION 'Manager decision and reason required'; END IF;
 IF next_status='approved' AND (w.start_date>current_date OR w.end_date<coalesce(old.opened_at::date,current_date)) THEN RAISE EXCEPTION 'Claim was outside stored coverage dates'; END IF;
 IF next_status='replacement' AND (nullif(p->>'replacement_product_id','') IS NULL OR length(trim(coalesce(p->>'replacement_serial','')))<3) THEN RAISE EXCEPTION 'Replacement product and serial required'; END IF;
 IF next_status='closed' AND length(trim(coalesce(p->>'resolution','')))<3 THEN RAISE EXCEPTION 'Resolution required'; END IF;
 IF old.status IN ('replacement','closed') AND (nullif(p->>'replacement_product_id','')::uuid IS DISTINCT FROM old.replacement_product_id OR coalesce(p->>'replacement_serial','')<>old.replacement_serial) THEN RAISE EXCEPTION 'Replacement already issued; its identifiers are locked'; END IF;
 IF next_status='replacement' AND old.status IS DISTINCT FROM 'replacement' THEN
  IF EXISTS(SELECT 1 FROM public.warranty_claims x WHERE lower(x.replacement_serial)=lower(p->>'replacement_serial') AND x.id<>id) THEN RAISE EXCEPTION 'Replacement serial already used'; END IF;
  SELECT i.id INTO replacement_stock FROM public.inventory i WHERE i.item_id=(p->>'replacement_product_id')::uuid;
  IF replacement_stock IS NULL THEN RAISE EXCEPTION 'Receive replacement stock first'; END IF;
  PERFORM public.app_move_stock(replacement_stock,-1,'Warranty replacement '||old.number);
  UPDATE public.stock_movements SET movement_type='warranty_replacement' WHERE inventory_id=replacement_stock AND reference='Warranty replacement '||old.number;
 END IF;
 INSERT INTO public.warranty_claims(id,warranty_id,status,complaint_description,diagnosis,technician_email,review_reason,replacement_product_id,replacement_serial,resolution,notes,job_id,closed_at)
 VALUES(id,w.id,next_status,p->>'complaint_description',coalesce(p->>'diagnosis',''),coalesce(p->>'technician_email',''),coalesce(p->>'review_reason',''),nullif(p->>'replacement_product_id','')::uuid,coalesce(p->>'replacement_serial',''),coalesce(p->>'resolution',''),coalesce(p->>'notes',''),nullif(p->>'job_id','')::uuid,CASE WHEN next_status='closed' THEN now() END)
 ON CONFLICT ON CONSTRAINT warranty_claims_pkey DO UPDATE SET status=excluded.status,diagnosis=excluded.diagnosis,technician_email=excluded.technician_email,review_reason=CASE WHEN public.has_permission('service_approve.write') THEN excluded.review_reason ELSE warranty_claims.review_reason END,replacement_product_id=excluded.replacement_product_id,replacement_serial=excluded.replacement_serial,resolution=excluded.resolution,notes=excluded.notes,closed_at=excluded.closed_at,updated_at=clock_timestamp() RETURNING * INTO c;
 IF c.job_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.service_jobs WHERE service_jobs.id=c.job_id AND customer_id=w.customer_id AND (w.vehicle_id IS NULL OR vehicle_id=w.vehicle_id)) THEN RAISE EXCEPTION 'Related job does not match this warranty'; END IF;
 PERFORM public.ws_audit('claim',id,w.customer_id,w.vehicle_id,'Warranty claim '||next_status,to_jsonb(old),to_jsonb(c),p->>'review_reason');RETURN id;
END $$;
CREATE FUNCTION public.ws_save_delivery(p jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE old public.delivery_checklist;d public.delivery_checklist;v public.vehicles;b public.billing_documents;id uuid:=coalesce(nullif(p->>'id','')::uuid,gen_random_uuid());finish boolean:=coalesce((p->>'finish')::boolean,false);override text:=coalesce(p->>'override_reason','');k text;
BEGIN
 IF NOT public.has_permission('delivery.write') THEN RAISE EXCEPTION 'Delivery edit permission required'; END IF;
 SELECT * INTO old FROM public.delivery_checklist WHERE delivery_checklist.id=id FOR UPDATE;
 IF old.signed_at IS NOT NULL THEN RAISE EXCEPTION 'Completed delivery is locked'; END IF;
 IF old.id IS NOT NULL AND (p->>'updated_at')::timestamptz IS DISTINCT FROM old.updated_at THEN RAISE EXCEPTION 'Delivery changed; reload'; END IF;
 IF NOT public.has_permission('service.write') AND coalesce(old.assigned_email,p->>'assigned_email',public.ws_email())<>public.ws_email() THEN RAISE EXCEPTION 'Only assigned delivery staff may edit'; END IF;
 SELECT * INTO v FROM public.vehicles WHERE vehicles.id=coalesce(old.vehicle_id,(p->>'vehicle_id')::uuid) FOR UPDATE;
 SELECT * INTO b FROM public.billing_documents WHERE billing_documents.id=(p->>'invoice_id')::uuid AND kind='invoice' AND cancelled_at IS NULL;
 IF v.id IS NULL OR b.id IS NULL OR v.product_id IS NULL OR b.service_job_id IS NOT NULL THEN RAISE EXCEPTION 'Select a stock vehicle and its sales invoice'; END IF;
 IF (SELECT coalesce(sum((x->>'qty')::int),0) FROM jsonb_array_elements(b.items) x WHERE x->>'productId'=v.product_id::text AND x->>'inventoryId'=v.stock_id::text)<=(SELECT count(*) FROM public.delivery_checklist WHERE invoice_id=b.id AND vehicle_id<>v.id) THEN RAISE EXCEPTION 'Invoice has no unallocated stock vehicle of this model'; END IF;
 IF finish THEN
  IF b.amount_paid<b.total THEN RAISE EXCEPTION 'Settle the invoice before delivery'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.pdi_checks WHERE vehicle_id=v.id AND result IN ('passed','issues')) AND (NOT public.has_permission('service_approve.write') OR length(trim(override))<10) THEN RAISE EXCEPTION 'PDI must pass, or manager must record an override reason'; END IF;
  FOREACH k IN ARRAY ARRAY['invoice_handed','warranty_explained','manual_given','vehicle_demonstrated'] LOOP IF coalesce((p->'checklist'->>k)::boolean,false)=false THEN RAISE EXCEPTION 'Complete all delivery checks'; END IF; END LOOP;
 END IF;
 INSERT INTO public.delivery_checklist(id,vehicle_id,customer_id,invoice_id,assigned_email,checklist,notes,override_reason,signed_at) VALUES(id,v.id,b.customer_id,b.id,coalesce(p->>'assigned_email',public.ws_email()),coalesce(p->'checklist','{}'),coalesce(p->>'notes',''),override,CASE WHEN finish THEN now() END)
 ON CONFLICT ON CONSTRAINT delivery_checklist_pkey DO UPDATE SET checklist=excluded.checklist,notes=excluded.notes,override_reason=excluded.override_reason,signed_at=excluded.signed_at,updated_at=clock_timestamp() RETURNING * INTO d;
 UPDATE public.vehicles SET customer_id=b.customer_id,purchase_invoice_id=b.id,purchase_date=b.document_date,status=CASE WHEN finish THEN 'delivered'::public.vehicle_status ELSE 'sold'::public.vehicle_status END,lifecycle=CASE WHEN finish THEN 'delivered' ELSE 'sold' END WHERE vehicles.id=v.id;
 PERFORM public.ws_audit('delivery',id,b.customer_id,v.id,CASE WHEN finish THEN 'Vehicle delivered' ELSE 'Delivery prepared' END,to_jsonb(old),to_jsonb(d),override); RETURN id;
END $$;
COMMIT;
