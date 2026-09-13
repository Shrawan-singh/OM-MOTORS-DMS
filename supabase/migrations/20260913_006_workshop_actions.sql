BEGIN;
CREATE FUNCTION public.ws_snapshot() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE result jsonb; full_access boolean:=public.has_permission('service.write') OR public.has_permission('service_reports.read'); finance boolean:=public.has_permission('service_finance.read');
BEGIN
 IF NOT public.has_permission('service.read') THEN RAISE EXCEPTION 'Service access required'; END IF;
 WITH jobs AS (SELECT j.* FROM public.service_jobs j WHERE public.ws_job_access(j.id)),
 vs AS (SELECT v.* FROM public.vehicles v WHERE full_access OR public.has_permission('customers.read') OR public.has_permission('warranty.read') OR finance OR v.id IN (SELECT vehicle_id FROM jobs) OR (public.has_permission('pdi.read') AND (public.access_role()<>'pdi' OR EXISTS(SELECT 1 FROM public.pdi_checks p WHERE p.vehicle_id=v.id AND p.inspector_email=public.ws_email()))) OR (public.has_permission('delivery.read') AND EXISTS(SELECT 1 FROM public.delivery_checklist d WHERE d.vehicle_id=v.id AND d.assigned_email=public.ws_email()))),
 ws AS (SELECT w.* FROM public.warranties w WHERE public.has_permission('warranty.read') OR full_access OR w.vehicle_id IN (SELECT vehicle_id FROM jobs))
 SELECT jsonb_build_object(
 'jobs',coalesce((SELECT jsonb_agg(CASE WHEN finance THEN to_jsonb(j) ELSE to_jsonb(j)-'financials' END ORDER BY created_at DESC) FROM jobs j),'[]'),
 'vehicles',coalesce((SELECT jsonb_agg(to_jsonb(v)) FROM vs v),'[]'),
 'customers',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'phone',c.phone,'village',c.village)) FROM public.customers c WHERE full_access OR public.has_permission('customers.read') OR finance OR c.id IN (SELECT customer_id FROM vs) OR c.id IN (SELECT customer_id FROM ws)),'[]'),
 'products',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'model_name',p.model_name,'brand',p.brand,'variant',p.variant,'category',p.category,'code',p.code)) FROM public.catalog_products p),'[]'),
 'inventory',coalesce((SELECT jsonb_agg(jsonb_build_object('id',i.id,'item_id',i.item_id,'item_name',i.item_name,'sku',i.sku_or_code,'qty',i.qty_available-i.qty_reserved)) FROM public.inventory i WHERE i.item_type IN ('part','battery','implement') AND (full_access OR public.has_permission('service_work.read') OR finance)),'[]'),
 'technicians',coalesce((SELECT jsonb_agg(jsonb_build_object('email',a.email,'role',a.role)) FROM public.access_assignments a WHERE a.active AND (full_access OR public.has_permission('pdi.write') OR a.email=public.ws_email()) AND (a.role IN ('mechanic','pdi','manager','service_manager','owner') OR EXISTS(SELECT 1 FROM public.access_permissions ap WHERE ap.role=a.role AND ap.permission IN ('service_work.write','pdi.write')))),'[]'),
 'pdi',coalesce((SELECT jsonb_agg(to_jsonb(p)) FROM public.pdi_checks p WHERE public.has_permission('pdi.read') AND (full_access OR public.access_role()<>'pdi' OR p.inspector_email=public.ws_email())),'[]'),
 'templates',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.pdi_templates t WHERE public.has_permission('pdi.read')),'[]'),
 'warranties',coalesce((SELECT jsonb_agg(to_jsonb(w)) FROM ws w),'[]'),
 'claims',coalesce((SELECT jsonb_agg(to_jsonb(c)) FROM public.warranty_claims c WHERE c.warranty_id IN (SELECT id FROM ws)),'[]'),
 'deliveries',coalesce((SELECT jsonb_agg(to_jsonb(d)) FROM public.delivery_checklist d WHERE public.has_permission('delivery.read') AND (full_access OR d.assigned_email=public.ws_email())),'[]'),
 'invoices',coalesce((SELECT jsonb_agg(CASE WHEN finance OR public.has_permission('invoices.read') THEN to_jsonb(b) ELSE jsonb_build_object('id',b.id,'number',b.number,'customer_id',b.customer_id,'document_date',b.document_date,'cancelled_at',b.cancelled_at) END) FROM public.billing_documents b WHERE b.kind='invoice' AND (finance OR public.has_permission('invoices.read') OR public.has_permission('delivery.read') OR public.has_permission('warranty.read'))),'[]'),
 'payments',coalesce((SELECT jsonb_agg(to_jsonb(p)) FROM public.billing_payments p WHERE finance),'[]'),
 'events',coalesce((SELECT jsonb_agg(CASE WHEN finance THEN to_jsonb(a) ELSE to_jsonb(a)-'before_record'-'after_record' END ORDER BY a.created_at DESC) FROM public.workshop_audit a WHERE full_access OR a.vehicle_id IN (SELECT id FROM vs) OR a.customer_id IN (SELECT customer_id FROM jobs)),'[]')
 ) INTO result;
 RETURN result;
END $$;
CREATE FUNCTION public.ws_save_job(p jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE old public.service_jobs; j public.service_jobs; v public.vehicles; part jsonb; mail text; id uuid:=coalesce(nullif(p->>'id','')::uuid,gen_random_uuid()); manager boolean:=public.has_permission('service.write');
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(id::text,1)); SELECT * INTO old FROM public.service_jobs WHERE service_jobs.id=id FOR UPDATE;
 IF old.id IS NULL AND NOT manager THEN RAISE EXCEPTION 'Job creation access denied'; END IF;
 IF NOT manager AND NOT (public.has_permission('service_work.write') AND public.ws_email()=ANY(old.technician_emails)) AND NOT (public.has_permission('service_finance.write') AND old.id IS NOT NULL) THEN RAISE EXCEPTION 'Job edit access denied'; END IF;
 IF old.id IS NOT NULL AND (p->>'updated_at')::timestamptz IS DISTINCT FROM old.updated_at THEN RAISE EXCEPTION 'Job changed. Reload before saving.'; END IF;
 j:=jsonb_populate_record(old,p);
 IF old.id IS NULL THEN j.id:=id;j.number:='JOB-'||lpad(nextval('public.workshop_number_seq')::text,6,'0');j.status:=coalesce(j.status,'new');j.received_at:=coalesce(j.received_at,current_date);j.technician_emails:=coalesce(j.technician_emails,'{}'); END IF;
 IF NOT manager THEN
  j.customer_id:=old.customer_id;j.vehicle_id:=old.vehicle_id;j.complaint:=old.complaint;j.priority:=old.priority;j.job_type:=old.job_type;j.received_at:=old.received_at;j.expected_date:=old.expected_date;j.technician_emails:=old.technician_emails;
  IF NOT public.has_permission('service_work.write') THEN j.diagnosis:=old.diagnosis;j.findings:=old.findings;j.work_performed:=old.work_performed;j.parts_used:=old.parts_used;j.labour_hours:=old.labour_hours; END IF;
  IF j.status IS DISTINCT FROM old.status AND (NOT public.has_permission('service_work.write') OR j.status NOT IN ('inspection','work_in_progress','waiting_for_parts','ready_for_delivery')) THEN RAISE EXCEPTION 'Status change requires manager'; END IF;
 END IF;
 IF NOT public.has_permission('service_finance.write') THEN j.financials:=coalesce(old.financials,'{}'); END IF;
 IF old.invoice_id IS NOT NULL AND (j.financials IS DISTINCT FROM old.financials OR j.parts_used IS DISTINCT FROM old.parts_used OR j.customer_id<>old.customer_id OR j.vehicle_id<>old.vehicle_id) THEN RAISE EXCEPTION 'Finalized job: cancel the unpaid invoice before changing charges or parts'; END IF;
 IF old.invoice_id IS NOT NULL AND j.status NOT IN ('invoiced','paid','completed') THEN RAISE EXCEPTION 'Finalized job status cannot return to technical work'; END IF;
 IF old.id IS NOT NULL AND (j.vehicle_id<>old.vehicle_id OR j.customer_id<>old.customer_id) THEN RAISE EXCEPTION 'Job customer and vehicle are permanent'; END IF;
 IF old.status='completed' THEN RAISE EXCEPTION 'Completed history is locked'; END IF;
 SELECT * INTO v FROM public.vehicles WHERE vehicles.id=j.vehicle_id;
 IF NOT FOUND OR v.customer_id IS DISTINCT FROM j.customer_id THEN RAISE EXCEPTION 'Select a vehicle belonging to this customer'; END IF;
 IF length(trim(coalesce(j.complaint,'')))<3 THEN RAISE EXCEPTION 'Customer complaint is required'; END IF;
 IF j.expected_date<j.received_at THEN RAISE EXCEPTION 'Expected date precedes receipt'; END IF;
 FOREACH mail IN ARRAY j.technician_emails LOOP
  IF NOT EXISTS(SELECT 1 FROM public.access_assignments a WHERE a.email=mail AND a.active AND (a.role='owner' OR EXISTS(SELECT 1 FROM public.access_permissions ap WHERE ap.role=a.role AND ap.permission='service_work.write'))) THEN RAISE EXCEPTION 'Technician must be an approved active team member with work permission'; END IF;
 END LOOP;
 IF j.status='assigned' AND cardinality(j.technician_emails)=0 THEN RAISE EXCEPTION 'Assign a technician first'; END IF;
 IF j.status IN ('ready_for_delivery','invoiced','paid','completed') AND length(trim(coalesce(j.work_performed,'')))<3 THEN RAISE EXCEPTION 'Record work performed before completion'; END IF;
 IF j.status IN ('invoiced','paid','completed') AND NOT EXISTS(SELECT 1 FROM public.billing_documents b WHERE b.id=old.invoice_id AND b.finalized_at IS NOT NULL AND b.cancelled_at IS NULL AND (j.status='invoiced' OR b.amount_paid=b.total)) THEN RAISE EXCEPTION 'Finalize the invoice and settle the balance first'; END IF;
 IF jsonb_typeof(coalesce(j.parts_used,'[]'))<>'array' THEN RAISE EXCEPTION 'Invalid parts'; END IF;
 FOR part IN SELECT value FROM jsonb_array_elements(coalesce(j.parts_used,'[]')) LOOP
  IF NOT EXISTS(SELECT 1 FROM public.inventory i WHERE i.id=(part->>'inventoryId')::uuid AND i.item_type IN ('part','battery','implement')) OR coalesce((part->>'qty')::numeric,0)<=0 OR (part->>'qty')::numeric<>trunc((part->>'qty')::numeric) THEN RAISE EXCEPTION 'Choose stocked parts and positive whole quantities'; END IF;
 END LOOP;
 INSERT INTO public.service_jobs(id,number,vehicle_id,customer_id,job_type,status,scheduled_date,complaint,priority,received_at,expected_date,meter,meter_unit,technician_emails,diagnosis,findings,work_performed,parts_used,labour_hours,financials,notes,next_service_date,next_service_meter,recommended_work,created_by,completed_date)
 VALUES(id,j.number,j.vehicle_id,j.customer_id,coalesce(j.job_type,'General Service'),j.status,j.received_at,j.complaint,coalesce(j.priority,'normal'),j.received_at,j.expected_date,j.meter,coalesce(j.meter_unit,'hours'),j.technician_emails,coalesce(j.diagnosis,''),coalesce(j.findings,''),coalesce(j.work_performed,''),coalesce(j.parts_used,'[]'),coalesce(j.labour_hours,0),coalesce(j.financials,'{}'),coalesce(j.notes,''),j.next_service_date,j.next_service_meter,coalesce(j.recommended_work,''),auth.uid(),CASE WHEN j.status='completed' THEN current_date END)
 ON CONFLICT ON CONSTRAINT service_jobs_pkey DO UPDATE SET job_type=excluded.job_type,status=excluded.status,complaint=excluded.complaint,priority=excluded.priority,expected_date=excluded.expected_date,meter=excluded.meter,meter_unit=excluded.meter_unit,technician_emails=excluded.technician_emails,diagnosis=excluded.diagnosis,findings=excluded.findings,work_performed=excluded.work_performed,parts_used=excluded.parts_used,labour_hours=excluded.labour_hours,financials=excluded.financials,notes=excluded.notes,next_service_date=excluded.next_service_date,next_service_meter=excluded.next_service_meter,recommended_work=excluded.recommended_work,completed_date=excluded.completed_date,updated_at=clock_timestamp() RETURNING * INTO j;
 PERFORM public.ws_audit('job',id,j.customer_id,j.vehicle_id,CASE WHEN old.id IS NULL THEN 'Service job created' ELSE 'Service job updated' END,to_jsonb(old),to_jsonb(j)); RETURN id;
END $$;

COMMIT;
