-- Apply after operational migrations 003 and 004.
BEGIN;
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

COMMIT;
