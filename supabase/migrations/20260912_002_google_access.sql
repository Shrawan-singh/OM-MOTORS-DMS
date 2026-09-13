-- Run after 20260911_001_initial_schema.sql. All access decisions use auth.users,
-- never user-editable metadata or a role supplied by the browser.
BEGIN;
CREATE TABLE public.access_assignments (
 email text PRIMARY KEY CHECK (email = lower(trim(email)) AND email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
 role text NOT NULL CHECK (role IN ('owner','salesperson','inventory','mechanic','accountant')),
 active boolean NOT NULL DEFAULT true,
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.access_permissions (
 role text NOT NULL CHECK (role IN ('salesperson','inventory','mechanic','accountant')),
 permission text NOT NULL CHECK (permission ~ '^(dashboard\.read|(catalogue|customers|inventory|quotations|invoices|service)\.(read|write))$'),
 PRIMARY KEY(role,permission)
);
CREATE TABLE public.access_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 actor uuid NOT NULL, action text NOT NULL, target text NOT NULL,
 details jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.access_assignments(email,role) VALUES ('suryasingh4395@gmail.com','owner');
INSERT INTO public.access_permissions(role,permission)
SELECT r, p FROM (VALUES
 ('salesperson',ARRAY['dashboard.read','catalogue.read','customers.read','customers.write','quotations.read','quotations.write']),
 ('inventory',ARRAY['dashboard.read','catalogue.read','inventory.read','inventory.write']),
 ('mechanic',ARRAY['dashboard.read','catalogue.read','service.read','service.write']),
 ('accountant',ARRAY['dashboard.read','customers.read','quotations.read','invoices.read','invoices.write'])
) AS defaults(r,ps) CROSS JOIN LATERAL unnest(ps) AS p;
CREATE FUNCTION public.access_role() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT a.role FROM public.access_assignments a JOIN auth.users u ON lower(u.email)=a.email
 WHERE u.id=auth.uid() AND u.email_confirmed_at IS NOT NULL AND a.active;
$$;
CREATE FUNCTION public.has_permission(p_permission text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT coalesce(public.access_role()='owner' OR EXISTS(SELECT 1 FROM public.access_permissions WHERE role=public.access_role() AND permission=p_permission),false);
$$;
CREATE FUNCTION public.my_access() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT jsonb_build_object('role', public.access_role(), 'email',coalesce((SELECT lower(email) FROM auth.users WHERE id=auth.uid()),''),'permissions',coalesce((SELECT jsonb_agg(permission) FROM public.access_permissions WHERE role=public.access_role()),'[]'::jsonb));
$$;
CREATE FUNCTION public.admin_assign_access(p_email text,p_role text,p_active boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE normalized text := lower(trim(p_email));
BEGIN
 -- Serialize admin changes to prevent concurrent last-admin removal.
 PERFORM pg_advisory_xact_lock(20260912);
 IF public.access_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Administrator access required'; END IF;
 IF normalized=(SELECT lower(email) FROM auth.users WHERE id=auth.uid()) AND (p_role<>'owner' OR NOT p_active) THEN RAISE EXCEPTION 'You cannot revoke or downgrade your own administrator access'; END IF;
 INSERT INTO public.access_assignments(email,role,active) VALUES(normalized,p_role,p_active)
 ON CONFLICT(email) DO UPDATE SET role=excluded.role,active=excluded.active,updated_at=now();
 INSERT INTO public.access_audit(actor,action,target,details) VALUES(auth.uid(),'assign_access',normalized,jsonb_build_object('role',p_role,'active',p_active));
END; $$;
CREATE FUNCTION public.admin_save_permissions(p_role text,p_permissions text[]) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(20260912);
 IF public.access_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Administrator access required'; END IF;
 IF p_role NOT IN ('salesperson','inventory','mechanic','accountant') OR p_role IS NULL THEN RAISE EXCEPTION 'Invalid staff role'; END IF;
 IF p_permissions IS NULL THEN RAISE EXCEPTION 'Permissions are required'; END IF;
 DELETE FROM public.access_permissions WHERE role=p_role;
 INSERT INTO public.access_permissions(role,permission) SELECT p_role,p FROM (SELECT DISTINCT unnest(p_permissions) p) v;
 IF EXISTS(SELECT 1 FROM unnest(p_permissions) p WHERE p LIKE '%.write' AND NOT replace(p,'.write','.read')=ANY(p_permissions)) THEN RAISE EXCEPTION 'Edit permission requires view permission'; END IF;
 INSERT INTO public.access_audit(actor,action,target,details) VALUES(auth.uid(),'save_permissions',p_role,to_jsonb(p_permissions));
END; $$;
ALTER TABLE public.access_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.access_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.access_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY admin_read_assignments ON public.access_assignments FOR SELECT TO authenticated USING(public.access_role()='owner');
CREATE POLICY admin_read_permissions ON public.access_permissions FOR SELECT TO authenticated USING(public.access_role()='owner');
CREATE POLICY admin_read_audit ON public.access_audit FOR SELECT TO authenticated USING(public.access_role()='owner');
REVOKE ALL ON public.access_assignments,public.access_permissions,public.access_audit FROM anon,authenticated;
GRANT SELECT ON public.access_assignments,public.access_permissions,public.access_audit TO authenticated;
REVOKE ALL ON FUNCTION public.access_role(),public.has_permission(text),public.my_access(),public.admin_assign_access(text,text,boolean),public.admin_save_permissions(text,text[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.access_role(),public.has_permission(text),public.my_access(),public.admin_assign_access(text,text,boolean),public.admin_save_permissions(text,text[]) TO authenticated;
-- Replace the legacy unconditional policies and cover previously unprotected tables.
DO $$ DECLARE rec record; old_policy record; BEGIN
 FOR rec IN SELECT * FROM (VALUES
 ('staff','admin'),('customers','customers'),('customer_locations','customers'),('customer_timeline','customers'),
 ('vehicle_models','catalogue'),('batteries','catalogue'),('implements','catalogue'),('parts','catalogue'),('implement_compatibility','catalogue'),('parts_compatibility','catalogue'),
 ('vehicles','inventory'),('battery_serials','inventory'),('suppliers','inventory'),('purchases','inventory'),('purchase_items','inventory'),('inventory','inventory'),
 ('quotations','quotations'),('sales','invoices'),('sale_items','invoices'),('invoices','invoices'),('payments','invoices'),
 ('warranties','service'),('warranty_claims','service'),('pdi_checks','service'),('delivery_checklist','service'),('service_jobs','service'),
 ('leads','customers'),('followups','customers'),('documents','admin')
 ) AS mapping(tbl,module) LOOP
 EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',rec.tbl);
 FOR old_policy IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename=rec.tbl LOOP
 EXECUTE format('DROP POLICY %I ON public.%I',old_policy.policyname,rec.tbl);
 END LOOP;
 EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated',rec.tbl);
 EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated',rec.tbl);
 EXECUTE format('CREATE POLICY access_read ON public.%I FOR SELECT TO authenticated USING(public.has_permission(%L))',rec.tbl,rec.module||'.read');
 EXECUTE format('CREATE POLICY access_insert ON public.%I FOR INSERT TO authenticated WITH CHECK(public.has_permission(%L))',rec.tbl,rec.module||'.write');
 EXECUTE format('CREATE POLICY access_update ON public.%I FOR UPDATE TO authenticated USING(public.has_permission(%L)) WITH CHECK(public.has_permission(%L))',rec.tbl,rec.module||'.write',rec.module||'.write');
 EXECUTE format('CREATE POLICY access_delete ON public.%I FOR DELETE TO authenticated USING(public.has_permission(%L))',rec.tbl,rec.module||'.write');
 END LOOP;
END $$;
-- The legacy sale RPC bypasses RLS and is not used by this prototype. Disable
-- client execution until its financial/stock validations are production-ready.
REVOKE ALL ON FUNCTION public.fn_confirm_sale(uuid,numeric,public.payment_method,text,uuid) FROM PUBLIC,anon,authenticated;
COMMIT;
