-- Run once AFTER UPGRADE_LIVE_OPERATIONS.sql. Preserves existing records.
-- Adds General Manager and scoped workshop roles; no users are assigned automatically.
BEGIN;
-- Apply after operational migrations 003 and 004.

ALTER TYPE public.staff_role ADD VALUE IF NOT EXISTS 'manager';
ALTER TYPE public.staff_role ADD VALUE IF NOT EXISTS 'service_manager';
ALTER TYPE public.staff_role ADD VALUE IF NOT EXISTS 'pdi';
ALTER TYPE public.staff_role ADD VALUE IF NOT EXISTS 'warranty';
ALTER TABLE public.access_assignments DROP CONSTRAINT access_assignments_role_check;
ALTER TABLE public.access_assignments ADD CHECK(role IN ('owner','manager','service_manager','pdi','warranty','salesperson','inventory','mechanic','accountant'));
ALTER TABLE public.access_permissions DROP CONSTRAINT access_permissions_role_check;
ALTER TABLE public.access_permissions DROP CONSTRAINT access_permissions_permission_check;
ALTER TABLE public.access_permissions ADD CHECK(role IN ('manager','service_manager','pdi','warranty','salesperson','inventory','mechanic','accountant'));
ALTER TABLE public.access_permissions ADD CHECK(permission ~ '^(dashboard\.read|(catalogue|customers|inventory|quotations|invoices|service|service_work|service_finance|service_approve|service_reports|pdi|delivery|warranty)\.(read|write))$');
DELETE FROM public.access_permissions WHERE role='mechanic';
INSERT INTO public.access_permissions(role,permission) SELECT r,p FROM (VALUES
 ('manager',ARRAY['dashboard.read','catalogue.read','catalogue.write','customers.read','customers.write','inventory.read','inventory.write','quotations.read','quotations.write','invoices.read','invoices.write','service.read','service.write','service_work.read','service_work.write','service_finance.read','service_finance.write','service_approve.read','service_approve.write','service_reports.read','pdi.read','pdi.write','delivery.read','delivery.write','warranty.read','warranty.write']),
 ('service_manager',ARRAY['catalogue.read','customers.read','customers.write','inventory.read','invoices.read','invoices.write','service.read','service.write','service_work.read','service_work.write','service_finance.read','service_finance.write','service_approve.read','service_approve.write','service_reports.read','pdi.read','pdi.write','delivery.read','delivery.write','warranty.read','warranty.write']),
 ('mechanic',ARRAY['service.read','service_work.read','service_work.write']),
 ('pdi',ARRAY['service.read','pdi.read','pdi.write','delivery.read','delivery.write']),
 ('warranty',ARRAY['service.read','warranty.read','warranty.write']),
 ('accountant',ARRAY['service.read','service_finance.read','service_finance.write']),
 ('salesperson',ARRAY['service.read'])
) d(r,ps) CROSS JOIN LATERAL unnest(ps) p ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION public.admin_save_permissions(p_role text,p_permissions text[]) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

BEGIN
 PERFORM pg_advisory_xact_lock(20260912);
 IF public.access_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Administrator access required'; END IF;
 IF p_role IS NULL OR p_role NOT IN ('manager','service_manager','pdi','warranty','salesperson','inventory','mechanic','accountant') THEN RAISE EXCEPTION 'Invalid staff role'; END IF;
 IF p_permissions IS NULL THEN RAISE EXCEPTION 'Permissions required'; END IF;
 DELETE FROM public.access_permissions WHERE role=p_role;
 INSERT INTO public.access_permissions SELECT p_role,p FROM (SELECT DISTINCT unnest(p_permissions) p) a;
 IF EXISTS(SELECT 1 FROM unnest(p_permissions) p WHERE p LIKE '%.write' AND NOT replace(p,'.write','.read')=ANY(p_permissions)) THEN RAISE EXCEPTION 'Edit permission requires view permission'; END IF;
 INSERT INTO public.access_audit(actor,action,target,details) VALUES(auth.uid(),'save_permissions',p_role,to_jsonb(p_permissions));
END $$;
CREATE SEQUENCE public.workshop_number_seq;
ALTER TABLE public.vehicles ALTER COLUMN model_id DROP NOT NULL, ALTER COLUMN engine_no DROP NOT NULL, ALTER COLUMN colour DROP DEFAULT;
ALTER TABLE public.vehicles ADD COLUMN product_id uuid REFERENCES public.catalog_products(id), ADD COLUMN model_name text NOT NULL DEFAULT '', ADD COLUMN variant text NOT NULL DEFAULT '', ADD COLUMN vehicle_type text NOT NULL DEFAULT 'tractor', ADD COLUMN registration_no text, ADD COLUMN motor_no text, ADD COLUMN battery_no text, ADD COLUMN purchase_invoice_id uuid REFERENCES public.billing_documents(id), ADD COLUMN purchase_date date, ADD COLUMN location text NOT NULL DEFAULT '', ADD COLUMN manufacturer text NOT NULL DEFAULT '', ADD COLUMN shipment_ref text NOT NULL DEFAULT '', ADD COLUMN supplier_invoice text NOT NULL DEFAULT '', ADD COLUMN lifecycle text NOT NULL DEFAULT 'received' CHECK(lifecycle IN ('received','pdi_pending','pdi_passed','pdi_failed','pdi_issues','available','reserved','sold','delivered')), ADD COLUMN stock_id uuid REFERENCES public.inventory(id);
CREATE UNIQUE INDEX workshop_chassis_unique ON public.vehicles(lower(trim(chassis_no)));
CREATE UNIQUE INDEX workshop_engine_unique ON public.vehicles(lower(trim(engine_no))) WHERE nullif(trim(engine_no),'') IS NOT NULL;
CREATE UNIQUE INDEX workshop_motor_unique ON public.vehicles(lower(trim(motor_no))) WHERE nullif(trim(motor_no),'') IS NOT NULL;
CREATE UNIQUE INDEX workshop_battery_unique ON public.vehicles(lower(trim(battery_no))) WHERE nullif(trim(battery_no),'') IS NOT NULL;
ALTER TABLE public.service_jobs ALTER COLUMN status DROP DEFAULT;
ALTER TABLE public.service_jobs ALTER COLUMN status TYPE text USING status::text;
UPDATE public.service_jobs SET status=CASE status WHEN 'completed' THEN 'completed' WHEN 'in_progress' THEN 'work_in_progress' ELSE 'new' END;
ALTER TABLE public.service_jobs ALTER COLUMN status SET DEFAULT 'new', ALTER COLUMN job_type SET DEFAULT 'General Service';
ALTER TABLE public.service_jobs ADD CHECK(status IN ('new','assigned','vehicle_received','inspection','work_in_progress','waiting_for_parts','ready_for_delivery','invoiced','paid','completed'));
ALTER TABLE public.service_jobs ADD COLUMN number text UNIQUE DEFAULT ('JOB-'||lpad(nextval('public.workshop_number_seq')::text,6,'0')), ADD COLUMN complaint text NOT NULL DEFAULT '', ADD COLUMN priority text NOT NULL DEFAULT 'normal' CHECK(priority IN ('low','normal','high','urgent')), ADD COLUMN received_at date NOT NULL DEFAULT current_date, ADD COLUMN expected_date date, ADD COLUMN meter numeric CHECK(meter>=0), ADD COLUMN meter_unit text NOT NULL DEFAULT 'hours' CHECK(meter_unit IN ('hours','km')), ADD COLUMN technician_emails text[] NOT NULL DEFAULT '{}', ADD COLUMN diagnosis text NOT NULL DEFAULT '', ADD COLUMN findings text NOT NULL DEFAULT '', ADD COLUMN work_performed text NOT NULL DEFAULT '', ADD COLUMN labour_hours numeric NOT NULL DEFAULT 0 CHECK(labour_hours>=0), ADD COLUMN financials jsonb NOT NULL DEFAULT '{}', ADD COLUMN invoice_id uuid UNIQUE REFERENCES public.billing_documents(id), ADD COLUMN next_service_date date, ADD COLUMN next_service_meter numeric CHECK(next_service_meter>=0), ADD COLUMN recommended_work text NOT NULL DEFAULT '', ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(), ADD COLUMN created_by uuid REFERENCES auth.users(id);
ALTER TABLE public.billing_documents ADD COLUMN service_job_id uuid UNIQUE REFERENCES public.service_jobs(id), ADD COLUMN finalized_at timestamptz, ADD COLUMN cancelled_at timestamptz;
ALTER TABLE public.stock_movements ADD COLUMN job_id uuid REFERENCES public.service_jobs(id), ADD COLUMN invoice_id uuid REFERENCES public.billing_documents(id), ADD COLUMN movement_type text NOT NULL DEFAULT 'adjustment';
CREATE TABLE public.pdi_templates(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text NOT NULL,vehicle_type text NOT NULL UNIQUE,items jsonb NOT NULL CHECK(jsonb_typeof(items)='array'),updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.pdi_checks ALTER COLUMN checklist SET DEFAULT '[]';
ALTER TABLE public.pdi_checks ADD COLUMN number text UNIQUE DEFAULT ('PDI-'||lpad(nextval('public.workshop_number_seq')::text,6,'0')), ADD COLUMN inspector_email text NOT NULL DEFAULT '', ADD COLUMN result text NOT NULL DEFAULT 'pending' CHECK(result IN ('pending','passed','failed','issues')), ADD COLUMN corrective_action text NOT NULL DEFAULT '', ADD COLUMN responsible_email text NOT NULL DEFAULT '', ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
-- Preserve old boolean checklists as evidence; do not treat their old default true values as verified inspections.
ALTER TABLE public.pdi_checks ADD COLUMN legacy_checklist jsonb;
UPDATE public.pdi_checks p SET legacy_checklist=checklist,checklist=coalesce((SELECT jsonb_agg(jsonb_build_object('id',s.key||'-'||i.key,'section',s.key,'label',replace(i.key,'_',' '),'required',true,'result','','notes','Legacy value retained; reinspection required')) FROM jsonb_each(p.checklist) s CROSS JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(s.value)='object' THEN s.value ELSE '{}'::jsonb END) i),'[]'::jsonb) WHERE jsonb_typeof(checklist)='object';
ALTER TABLE public.warranties ADD COLUMN vehicle_id uuid REFERENCES public.vehicles(id), ADD COLUMN product_id uuid REFERENCES public.catalog_products(id), ADD COLUMN billing_invoice_id uuid REFERENCES public.billing_documents(id), ADD COLUMN product_name text NOT NULL DEFAULT '', ADD COLUMN brand text NOT NULL DEFAULT '', ADD COLUMN coverage_evidence text NOT NULL DEFAULT '', ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.warranty_claims ALTER COLUMN status DROP DEFAULT;
ALTER TABLE public.warranty_claims ALTER COLUMN status TYPE text USING status::text;
UPDATE public.warranty_claims SET status=CASE status WHEN 'closed' THEN 'closed' ELSE 'new' END;
ALTER TABLE public.warranty_claims ALTER COLUMN status SET DEFAULT 'new';
ALTER TABLE public.warranty_claims ADD CHECK(status IN ('new','inspection','submitted','approved','rejected','repair','replacement','closed'));
ALTER TABLE public.warranty_claims ADD COLUMN number text UNIQUE DEFAULT ('CLM-'||lpad(nextval('public.workshop_number_seq')::text,6,'0')), ADD COLUMN job_id uuid REFERENCES public.service_jobs(id), ADD COLUMN diagnosis text NOT NULL DEFAULT '', ADD COLUMN technician_email text NOT NULL DEFAULT '', ADD COLUMN review_reason text NOT NULL DEFAULT '', ADD COLUMN replacement_product_id uuid REFERENCES public.catalog_products(id), ADD COLUMN replacement_serial text NOT NULL DEFAULT '', ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.delivery_checklist ALTER COLUMN sale_id DROP NOT NULL;
ALTER TABLE public.delivery_checklist ADD COLUMN customer_id uuid REFERENCES public.customers(id), ADD COLUMN invoice_id uuid REFERENCES public.billing_documents(id), ADD COLUMN assigned_email text NOT NULL DEFAULT '', ADD COLUMN notes text NOT NULL DEFAULT '', ADD COLUMN override_reason text NOT NULL DEFAULT '', ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
CREATE UNIQUE INDEX delivery_vehicle_once ON public.delivery_checklist(vehicle_id);
CREATE UNIQUE INDEX warranty_serial_unique ON public.warranties(lower(trim(serial_no)));
CREATE UNIQUE INDEX claim_replacement_serial_unique ON public.warranty_claims(lower(trim(replacement_serial))) WHERE replacement_serial<>'';
CREATE TABLE public.workshop_audit(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,actor uuid NOT NULL REFERENCES auth.users(id),role text NOT NULL,entity text NOT NULL,record_id uuid NOT NULL,customer_id uuid REFERENCES public.customers(id),vehicle_id uuid REFERENCES public.vehicles(id),action text NOT NULL,before_record jsonb,after_record jsonb,reason text NOT NULL DEFAULT '',created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.workshop_attachments(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),entity text NOT NULL CHECK(entity IN ('job','pdi','claim')),record_id uuid NOT NULL,label text NOT NULL,object_path text NOT NULL UNIQUE,uploaded_by uuid NOT NULL REFERENCES auth.users(id),created_at timestamptz NOT NULL DEFAULT now());
CREATE OR REPLACE FUNCTION public.ws_email() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT lower(email) FROM auth.users WHERE id=auth.uid() $$;
CREATE OR REPLACE FUNCTION public.ws_job_access(p_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT public.has_permission('service.read') AND EXISTS(SELECT 1 FROM public.service_jobs j WHERE j.id=p_id AND (public.has_permission('service.write') OR public.has_permission('service_finance.read') OR public.has_permission('service_reports.read') OR public.has_permission('customers.read') OR public.ws_email()=ANY(j.technician_emails))) $$;
CREATE OR REPLACE FUNCTION public.ws_audit(p_entity text,p_id uuid,p_customer uuid,p_vehicle uuid,p_action text,p_old jsonb,p_new jsonb,p_reason text DEFAULT '') RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable
 BEGIN
 INSERT INTO public.workshop_audit(actor,role,entity,record_id,customer_id,vehicle_id,action,before_record,after_record,reason) VALUES(auth.uid(),public.access_role(),p_entity,p_id,p_customer,p_vehicle,p_action,p_old,p_new,coalesce(p_reason,''));
 IF p_customer IS NOT NULL THEN INSERT INTO public.customer_timeline(customer_id,event_type,description,reference_id) VALUES(p_customer,p_entity,p_action||coalesce(' · '||(p_new->>'number'),''),p_id::text); END IF;
END $$;
REVOKE ALL ON public.service_jobs,public.pdi_checks,public.warranties,public.warranty_claims,public.delivery_checklist FROM authenticated,anon;
REVOKE INSERT,UPDATE,DELETE ON public.vehicles FROM authenticated;
ALTER TABLE public.pdi_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workshop_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workshop_attachments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pdi_templates,public.workshop_audit,public.workshop_attachments FROM authenticated,anon;




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




ALTER FUNCTION public.app_save_document(jsonb) RENAME TO ws_base_save_document;
CREATE FUNCTION public.app_save_document(p_doc jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable
 BEGIN
 IF EXISTS(SELECT 1 FROM public.billing_documents WHERE id=nullif(p_doc->>'id','')::uuid AND (service_job_id IS NOT NULL OR cancelled_at IS NOT NULL)) THEN RAISE EXCEPTION 'Use the service job to manage this finalized invoice'; END IF;
 RETURN public.ws_base_save_document(p_doc);
END $$;
ALTER FUNCTION public.app_record_payment(uuid,uuid,numeric,public.payment_method,text) RENAME TO ws_base_record_payment;
CREATE FUNCTION public.app_record_payment(p_id uuid,p_invoice uuid,p_amount numeric,p_method public.payment_method,p_reference text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE b public.billing_documents;j public.service_jobs;already_recorded boolean;
BEGIN
 SELECT * INTO b FROM public.billing_documents WHERE id=p_invoice FOR UPDATE;
 IF b.cancelled_at IS NOT NULL THEN RAISE EXCEPTION 'Invoice is cancelled'; END IF;
 IF b.service_job_id IS NOT NULL AND NOT public.has_permission('service_finance.write') THEN RAISE EXCEPTION 'Service finance permission required'; END IF;
 SELECT EXISTS(SELECT 1 FROM public.billing_payments WHERE id=p_id) INTO already_recorded;
 PERFORM public.ws_base_record_payment(p_id,p_invoice,p_amount,p_method,p_reference);
 IF already_recorded THEN RETURN; END IF;
 IF b.service_job_id IS NOT NULL THEN
  SELECT * INTO j FROM public.service_jobs WHERE id=b.service_job_id FOR UPDATE;
  UPDATE public.service_jobs SET status=CASE WHEN (SELECT amount_paid=total FROM public.billing_documents WHERE id=p_invoice) THEN 'paid' ELSE 'invoiced' END,updated_at=clock_timestamp() WHERE id=j.id AND status<>'completed';
  PERFORM public.ws_audit('job',j.id,j.customer_id,j.vehicle_id,'Service payment recorded',NULL,jsonb_build_object('number',j.number,'invoice',b.number,'payment_id',p_id));
 END IF;
END $$;
ALTER TABLE public.billing_documents DROP CONSTRAINT billing_documents_service_job_id_key;
CREATE UNIQUE INDEX service_active_invoice_once ON public.billing_documents(service_job_id) WHERE cancelled_at IS NULL;
CREATE FUNCTION public.ws_finalize(p_job uuid,p_number text,p_tax_mode text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE j public.service_jobs;v public.vehicles;lines jsonb:='[]';part jsonb;rate jsonb;stock public.inventory;doc jsonb; inv uuid; cost numeric:=0;before_movement bigint;
BEGIN
 IF NOT public.has_permission('service_finance.write') OR NOT public.has_permission('service_approve.write') THEN RAISE EXCEPTION 'Service financial approval required'; END IF;
 SELECT * INTO j FROM public.service_jobs WHERE id=p_job FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Job not found'; END IF;
 IF j.invoice_id IS NOT NULL THEN RETURN j.invoice_id; END IF;
 IF j.status<>'ready_for_delivery' THEN RAISE EXCEPTION 'Review work and mark Ready for Delivery first'; END IF;
 SELECT * INTO v FROM public.vehicles WHERE id=j.vehicle_id;
 FOR part IN SELECT value FROM jsonb_array_elements(j.parts_used) LOOP
  SELECT * INTO stock FROM public.inventory WHERE id=(part->>'inventoryId')::uuid;
  rate:=j.financials->'rates'->stock.id::text;
  IF rate IS NULL OR NOT rate ?& ARRAY['price','cost','gst'] THEN RAISE EXCEPTION 'Set price, cost and GST for every part'; END IF;
  IF (rate->>'cost')::numeric IS NULL OR (rate->>'cost')::numeric NOT BETWEEN 0 AND 100000000 OR (rate->>'cost')::numeric::text='NaN' THEN RAISE EXCEPTION 'Invalid part cost'; END IF;
  cost:=cost+(rate->>'cost')::numeric*(part->>'qty')::numeric;
  lines:=lines||jsonb_build_array(jsonb_build_object('productId',stock.item_id,'inventoryId',stock.id,'name',stock.item_name,'hsnCode',coalesce(rate->>'hsn',''),'qty',(part->>'qty')::int,'unitPrice',(rate->>'price')::numeric,'discount',coalesce((rate->>'discount')::numeric,0),'gstRatePct',(rate->>'gst')::numeric));
 END LOOP;
 IF NOT j.financials ?& ARRAY['labour_charge','labour_cost','labour_gst'] THEN RAISE EXCEPTION 'Enter labour charge, cost and GST (zero where applicable)'; END IF;
 IF (j.financials->>'labour_cost')::numeric IS NULL OR (j.financials->>'labour_cost')::numeric NOT BETWEEN 0 AND 100000000 OR (j.financials->>'labour_cost')::numeric::text='NaN' THEN RAISE EXCEPTION 'Invalid labour cost'; END IF;
 lines:=lines||jsonb_build_array(jsonb_build_object('productId',NULL,'inventoryId',NULL,'name','Labour / Service','hsnCode',coalesce(j.financials->>'labour_hsn',''),'qty',1,'unitPrice',(j.financials->>'labour_charge')::numeric,'discount',coalesce((j.financials->>'labour_discount')::numeric,0),'gstRatePct',(j.financials->>'labour_gst')::numeric));
 SELECT coalesce(max(id),0) INTO before_movement FROM public.stock_movements;
 doc:=public.ws_base_save_document(jsonb_build_object('kind','invoice','number',p_number,'customerId',j.customer_id,'date',current_date,'items',lines,'taxMode',p_tax_mode,'notes','Job: '||j.number||E'\nVehicle: '||v.model_name||' '||v.variant||E'\nChassis: '||v.chassis_no||E'\nRegistration: '||coalesce(v.registration_no,'')||E'\nComplaint: '||j.complaint||E'\nWork: '||j.work_performed||E'\nTechnicians: '||array_to_string(j.technician_emails,', ')));
 inv:=(doc->>'id')::uuid;
 UPDATE public.billing_documents SET service_job_id=j.id,finalized_at=now() WHERE id=inv;
 UPDATE public.service_jobs SET invoice_id=inv,status=CASE WHEN (doc->>'total')::numeric=0 THEN 'paid' ELSE 'invoiced' END,updated_at=clock_timestamp() WHERE id=j.id;
 UPDATE public.stock_movements SET job_id=j.id,invoice_id=inv,movement_type='service_consumption' WHERE id>before_movement AND actor=auth.uid() AND reference=doc->>'number';
 PERFORM public.ws_audit('job',j.id,j.customer_id,j.vehicle_id,'Service invoice finalized',to_jsonb(j),doc); RETURN inv;
END $$;
CREATE FUNCTION public.ws_cancel_invoice(p_invoice uuid,p_reason text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE b public.billing_documents;j public.service_jobs;r record;
BEGIN
 IF NOT public.has_permission('service_approve.write') OR NOT public.has_permission('service_finance.write') OR length(trim(coalesce(p_reason,'')))<5 THEN RAISE EXCEPTION 'Approval access and cancellation reason required'; END IF;
 SELECT * INTO b FROM public.billing_documents WHERE id=p_invoice FOR UPDATE;
 IF b.service_job_id IS NULL THEN RAISE EXCEPTION 'Service invoice required'; END IF;
 IF b.cancelled_at IS NOT NULL THEN RETURN; END IF;
 IF b.amount_paid>0 THEN RAISE EXCEPTION 'Paid invoices cannot be cancelled; resolve the payment with accounting first'; END IF;
 SELECT * INTO j FROM public.service_jobs WHERE id=b.service_job_id FOR UPDATE;
 IF j.status='completed' THEN RAISE EXCEPTION 'Completed history is locked'; END IF;
 FOR r IN SELECT (x->>'inventoryId')::uuid id,sum((x->>'qty')::int)::int qty FROM jsonb_array_elements(b.items) x WHERE x->>'inventoryId' IS NOT NULL GROUP BY 1 ORDER BY 1 LOOP
  PERFORM public.app_move_stock(r.id,r.qty,'Cancel '||b.number||': '||p_reason);
 END LOOP;
 UPDATE public.billing_documents SET cancelled_at=now(),updated_at=clock_timestamp() WHERE id=p_invoice;
 UPDATE public.service_jobs SET invoice_id=NULL,status='ready_for_delivery',updated_at=clock_timestamp() WHERE id=j.id;
 PERFORM public.ws_audit('job',j.id,j.customer_id,j.vehicle_id,'Service invoice cancelled',to_jsonb(b),jsonb_build_object('number',b.number),p_reason);
END $$;
REVOKE ALL ON FUNCTION public.ws_base_save_document(jsonb),public.ws_base_record_payment(uuid,uuid,numeric,public.payment_method,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.app_save_document(jsonb),public.app_record_payment(uuid,uuid,numeric,public.payment_method,text),public.ws_finalize(uuid,text,text),public.ws_cancel_invoice(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.app_save_document(jsonb),public.app_record_payment(uuid,uuid,numeric,public.payment_method,text),public.ws_finalize(uuid,text,text),public.ws_cancel_invoice(uuid,text) TO authenticated;



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



CREATE FUNCTION public.ws_attachment_access(p_entity text,p_id uuid,p_write boolean DEFAULT false) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT public.has_permission('service.read') AND CASE p_entity
 WHEN 'job' THEN public.ws_job_access(p_id) AND (NOT p_write OR (EXISTS(SELECT 1 FROM public.service_jobs WHERE id=p_id AND status<>'completed') AND (public.has_permission('service.write') OR (public.has_permission('service_work.write') AND EXISTS(SELECT 1 FROM public.service_jobs WHERE id=p_id AND public.ws_email()=ANY(technician_emails))))))
 WHEN 'pdi' THEN public.has_permission(CASE WHEN p_write THEN 'pdi.write' ELSE 'pdi.read' END) AND EXISTS(SELECT 1 FROM public.pdi_checks WHERE id=p_id AND (public.has_permission('service.write') OR inspector_email=public.ws_email()))
 WHEN 'claim' THEN public.has_permission(CASE WHEN p_write THEN 'warranty.write' ELSE 'warranty.read' END) AND EXISTS(SELECT 1 FROM public.warranty_claims WHERE id=p_id AND (NOT p_write OR status<>'closed'))
 ELSE false END
$$;
CREATE FUNCTION public.ws_attach(p_entity text,p_id uuid,p_path text,p_label text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable

DECLARE result uuid;
BEGIN
 IF NOT public.ws_attachment_access(p_entity,p_id,true) OR split_part(p_path,'/',1)<>p_entity OR split_part(p_path,'/',2)<>p_id::text OR split_part(p_path,'/',3)<>auth.uid()::text OR length(trim(coalesce(p_label,'')))<2 THEN RAISE EXCEPTION 'Attachment access denied'; END IF;
 IF p_entity='job' AND EXISTS(SELECT 1 FROM public.service_jobs WHERE id=p_id AND status='completed') THEN RAISE EXCEPTION 'Completed history is locked'; END IF;
 IF p_entity='claim' AND EXISTS(SELECT 1 FROM public.warranty_claims WHERE id=p_id AND status='closed') THEN RAISE EXCEPTION 'Closed claim history is locked'; END IF;
 INSERT INTO public.workshop_attachments(entity,record_id,label,object_path,uploaded_by) VALUES(p_entity,p_id,p_label,p_path) RETURNING id INTO result;
 PERFORM public.ws_audit(p_entity,p_id,NULL,NULL,'Attachment added',NULL,jsonb_build_object('label',p_label));RETURN result;
END $$;
CREATE FUNCTION public.ws_attachments(p_entity text,p_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable
 BEGIN
 IF NOT public.ws_attachment_access(p_entity,p_id,false) THEN RAISE EXCEPTION 'Attachment access denied'; END IF;
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(a)) FROM public.workshop_attachments a WHERE entity=p_entity AND record_id=p_id),'[]');
END $$;
-- Supabase Storage is provisioned only in the hosted environment; SQL tests use no storage service.
DO $$ BEGIN IF to_regclass('storage.buckets') IS NOT NULL THEN
 INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES('workshop-evidence','workshop-evidence',false,10485760,ARRAY['image/jpeg','image/png','image/webp','application/pdf']) ON CONFLICT(id) DO NOTHING;
 EXECUTE $policy$ CREATE POLICY workshop_evidence_read ON storage.objects FOR SELECT TO authenticated USING(bucket_id='workshop-evidence' AND public.ws_attachment_access(split_part(name,'/',1),nullif(split_part(name,'/',2),'')::uuid,false)) $policy$;
 EXECUTE $policy$ CREATE POLICY workshop_evidence_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='workshop-evidence' AND split_part(name,'/',3)=auth.uid()::text AND public.ws_attachment_access(split_part(name,'/',1),nullif(split_part(name,'/',2),'')::uuid,true)) $policy$;
 END IF; END $$;
DO $$ DECLARE r record; BEGIN FOR r IN SELECT p.oid::regprocedure signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'ws_%' LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',r.signature); END LOOP; END $$;
GRANT EXECUTE ON FUNCTION public.ws_snapshot(),public.ws_save_job(jsonb),public.ws_save_vehicle(jsonb),public.ws_save_pdi(jsonb),public.ws_save_template(jsonb),public.ws_save_warranty(jsonb),public.ws_save_claim(jsonb),public.ws_save_delivery(jsonb),public.ws_finalize(uuid,text,text),public.ws_cancel_invoice(uuid,text),public.ws_attachment_access(text,uuid,boolean),public.ws_attach(text,uuid,text,text),public.ws_attachments(text,uuid) TO authenticated;
NOTIFY pgrst,'reload schema';



-- Configurable checklist templates, not business/demo records.
INSERT INTO public.pdi_templates(name,vehicle_type,items) VALUES ('tractor intake','tractor','[{"id":"Engine-0","section":"Engine","label":"Engine oil","required":true,"result":"","notes":""},{"id":"Engine-1","section":"Engine","label":"Coolant","required":true,"result":"","notes":""},{"id":"Engine-2","section":"Engine","label":"Fuel system","required":true,"result":"","notes":""},{"id":"Engine-3","section":"Engine","label":"Leakage","required":true,"result":"","notes":""},{"id":"Engine-4","section":"Engine","label":"Starting","required":true,"result":"","notes":""},{"id":"Engine-5","section":"Engine","label":"Engine sound","required":true,"result":"","notes":""},{"id":"Transmission-0","section":"Transmission","label":"Gear operation","required":true,"result":"","notes":""},{"id":"Transmission-1","section":"Transmission","label":"Clutch","required":true,"result":"","notes":""},{"id":"Transmission-2","section":"Transmission","label":"Transmission oil","required":true,"result":"","notes":""},{"id":"Hydraulic-0","section":"Hydraulic","label":"Hydraulic oil","required":true,"result":"","notes":""},{"id":"Hydraulic-1","section":"Hydraulic","label":"Lift operation","required":true,"result":"","notes":""},{"id":"Hydraulic-2","section":"Hydraulic","label":"Leakage","required":true,"result":"","notes":""},{"id":"Hydraulic-3","section":"Hydraulic","label":"3-point linkage","required":true,"result":"","notes":""},{"id":"PTO-0","section":"PTO","label":"PTO operation","required":true,"result":"","notes":""},{"id":"PTO-1","section":"PTO","label":"PTO selector","required":true,"result":"","notes":""},{"id":"Electrical-0","section":"Electrical","label":"Battery","required":true,"result":"","notes":""},{"id":"Electrical-1","section":"Electrical","label":"Headlights","required":true,"result":"","notes":""},{"id":"Electrical-2","section":"Electrical","label":"Indicators","required":true,"result":"","notes":""},{"id":"Electrical-3","section":"Electrical","label":"Horn","required":true,"result":"","notes":""},{"id":"Electrical-4","section":"Electrical","label":"Instrument panel","required":true,"result":"","notes":""},{"id":"Tyres-0","section":"Tyres","label":"Front tyres","required":true,"result":"","notes":""},{"id":"Tyres-1","section":"Tyres","label":"Rear tyres","required":true,"result":"","notes":""},{"id":"Tyres-2","section":"Tyres","label":"Pressure","required":true,"result":"","notes":""},{"id":"Exterior-0","section":"Exterior","label":"Paint","required":true,"result":"","notes":""},{"id":"Exterior-1","section":"Exterior","label":"Scratches","required":true,"result":"","notes":""},{"id":"Exterior-2","section":"Exterior","label":"Body","required":true,"result":"","notes":""},{"id":"Exterior-3","section":"Exterior","label":"Seat","required":true,"result":"","notes":""},{"id":"Exterior-4","section":"Exterior","label":"Mirrors","required":true,"result":"","notes":""},{"id":"Documents-0","section":"Documents","label":"Invoice / dispatch documents","required":true,"result":"","notes":""},{"id":"Documents-1","section":"Documents","label":"Warranty documents","required":true,"result":"","notes":""},{"id":"Documents-2","section":"Documents","label":"Manual","required":true,"result":"","notes":""},{"id":"Documents-3","section":"Documents","label":"Tool kit","required":true,"result":"","notes":""}]'::jsonb);
INSERT INTO public.pdi_templates(name,vehicle_type,items) VALUES ('e rickshaw intake','e_rickshaw','[{"id":"Electrical-0","section":"Electrical","label":"Battery","required":true,"result":"","notes":""},{"id":"Electrical-1","section":"Electrical","label":"Charger","required":true,"result":"","notes":""},{"id":"Electrical-2","section":"Electrical","label":"Controller","required":true,"result":"","notes":""},{"id":"Electrical-3","section":"Electrical","label":"Wiring","required":true,"result":"","notes":""},{"id":"Electrical-4","section":"Electrical","label":"Motor","required":true,"result":"","notes":""},{"id":"Mechanical-0","section":"Mechanical","label":"Brakes","required":true,"result":"","notes":""},{"id":"Mechanical-1","section":"Mechanical","label":"Steering","required":true,"result":"","notes":""},{"id":"Mechanical-2","section":"Mechanical","label":"Suspension","required":true,"result":"","notes":""},{"id":"Mechanical-3","section":"Mechanical","label":"Tyres","required":true,"result":"","notes":""},{"id":"Body-0","section":"Body","label":"Roof","required":true,"result":"","notes":""},{"id":"Body-1","section":"Body","label":"Seats","required":true,"result":"","notes":""},{"id":"Body-2","section":"Body","label":"Body panels","required":true,"result":"","notes":""},{"id":"Body-3","section":"Body","label":"Paint","required":true,"result":"","notes":""},{"id":"Electronics-0","section":"Electronics","label":"Display","required":true,"result":"","notes":""},{"id":"Electronics-1","section":"Electronics","label":"Lights","required":true,"result":"","notes":""},{"id":"Electronics-2","section":"Electronics","label":"Indicators","required":true,"result":"","notes":""},{"id":"Electronics-3","section":"Electronics","label":"Horn","required":true,"result":"","notes":""}]'::jsonb);
INSERT INTO public.pdi_templates(name,vehicle_type,items) VALUES ('cng rickshaw intake','cng_rickshaw','[{"id":"Engine-0","section":"Engine","label":"Fuel system","required":true,"result":"","notes":""},{"id":"Engine-1","section":"Engine","label":"Leakage","required":true,"result":"","notes":""},{"id":"Engine-2","section":"Engine","label":"Starting","required":true,"result":"","notes":""},{"id":"Engine-3","section":"Engine","label":"Engine oil","required":true,"result":"","notes":""},{"id":"Mechanical-0","section":"Mechanical","label":"Brakes","required":true,"result":"","notes":""},{"id":"Mechanical-1","section":"Mechanical","label":"Steering","required":true,"result":"","notes":""},{"id":"Mechanical-2","section":"Mechanical","label":"Suspension","required":true,"result":"","notes":""},{"id":"Mechanical-3","section":"Mechanical","label":"Tyres","required":true,"result":"","notes":""},{"id":"Body-0","section":"Body","label":"Roof","required":true,"result":"","notes":""},{"id":"Body-1","section":"Body","label":"Seats","required":true,"result":"","notes":""},{"id":"Body-2","section":"Body","label":"Body panels","required":true,"result":"","notes":""},{"id":"Body-3","section":"Body","label":"Paint","required":true,"result":"","notes":""},{"id":"Electrical-0","section":"Electrical","label":"Battery","required":true,"result":"","notes":""},{"id":"Electrical-1","section":"Electrical","label":"Lights","required":true,"result":"","notes":""},{"id":"Electrical-2","section":"Electrical","label":"Indicators","required":true,"result":"","notes":""},{"id":"Electrical-3","section":"Electrical","label":"Horn","required":true,"result":"","notes":""}]'::jsonb);
INSERT INTO public.pdi_templates(name,vehicle_type,items) VALUES ('diesel rickshaw intake','diesel_rickshaw','[{"id":"Engine-0","section":"Engine","label":"Fuel system","required":true,"result":"","notes":""},{"id":"Engine-1","section":"Engine","label":"Leakage","required":true,"result":"","notes":""},{"id":"Engine-2","section":"Engine","label":"Starting","required":true,"result":"","notes":""},{"id":"Engine-3","section":"Engine","label":"Engine oil","required":true,"result":"","notes":""},{"id":"Mechanical-0","section":"Mechanical","label":"Brakes","required":true,"result":"","notes":""},{"id":"Mechanical-1","section":"Mechanical","label":"Steering","required":true,"result":"","notes":""},{"id":"Mechanical-2","section":"Mechanical","label":"Suspension","required":true,"result":"","notes":""},{"id":"Mechanical-3","section":"Mechanical","label":"Tyres","required":true,"result":"","notes":""},{"id":"Body-0","section":"Body","label":"Roof","required":true,"result":"","notes":""},{"id":"Body-1","section":"Body","label":"Seats","required":true,"result":"","notes":""},{"id":"Body-2","section":"Body","label":"Body panels","required":true,"result":"","notes":""},{"id":"Body-3","section":"Body","label":"Paint","required":true,"result":"","notes":""},{"id":"Electrical-0","section":"Electrical","label":"Battery","required":true,"result":"","notes":""},{"id":"Electrical-1","section":"Electrical","label":"Lights","required":true,"result":"","notes":""},{"id":"Electrical-2","section":"Electrical","label":"Indicators","required":true,"result":"","notes":""},{"id":"Electrical-3","section":"Electrical","label":"Horn","required":true,"result":"","notes":""}]'::jsonb);


COMMIT;
