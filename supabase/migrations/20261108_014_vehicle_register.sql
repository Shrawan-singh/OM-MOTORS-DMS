-- Apply after 20260914_013. This transaction either installs the entire register or rolls back.
-- Before rollout take a database backup. To roll back after live receipts, restore the backup
-- to a separate DB and reconcile subsequent stock, PDI and component changes before cutover.
BEGIN;
SET LOCAL search_path = public, extensions, pg_catalog;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE OR REPLACE FUNCTION public.vehicle_number_key(value text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path = '' AS $$
  SELECT nullif(regexp_replace(upper(value), '[[:space:]-]+', '', 'g'), '')
$$;

-- Only seed new defaults on first installation. Replaying must respect later staff changes.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = 'public.access_permissions'::regclass
    AND conname = 'access_permissions_vehicle_modules'
  ) THEN
    ALTER TABLE public.access_permissions DROP CONSTRAINT access_permissions_permission_check;
    ALTER TABLE public.access_permissions ADD CONSTRAINT access_permissions_vehicle_modules
      CHECK (permission ~ '^(dashboard\.read|vehicles\.(read|write|export)|(catalogue|customers|inventory|quotations|invoices|service|service_work|service_finance|service_approve|service_reports|pdi|delivery|warranty)\.(read|write))$');
    INSERT INTO public.access_permissions(role, permission)
    SELECT role, 'vehicles.' || action FROM (VALUES
      ('manager', ARRAY['read','write','export']), ('service_manager', ARRAY['read','write']),
      ('salesperson', ARRAY['read','write']), ('inventory', ARRAY['read','write']),
      ('accountant', ARRAY['read','export']), ('pdi', ARRAY['read']), ('mechanic', ARRAY['read'])
    ) defaults(role, actions) CROSS JOIN unnest(actions) action;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.admin_save_permissions(p_role text, p_permissions text[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(20260912);
  IF public.access_role() IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'Administrator access required'; END IF;
  IF p_role IS NULL OR p_role NOT IN ('manager','service_manager','pdi','warranty','salesperson','inventory','mechanic','accountant')
    THEN RAISE EXCEPTION 'Invalid staff role'; END IF;
  IF p_permissions IS NULL THEN RAISE EXCEPTION 'Permissions required'; END IF;
  IF EXISTS (SELECT FROM unnest(p_permissions) p WHERE split_part(p,'.',2) IN ('write','export')
    AND NOT (split_part(p,'.',1) || '.read') = ANY(p_permissions))
    THEN RAISE EXCEPTION 'Edit or export permission requires view permission'; END IF;
  DELETE FROM public.access_permissions WHERE role = p_role;
  INSERT INTO public.access_permissions SELECT DISTINCT p_role, p FROM unnest(p_permissions) p;
  INSERT INTO public.access_audit(actor,action,target,details)
    VALUES (auth.uid(),'save_permissions',p_role,to_jsonb(p_permissions));
END $$;

ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS supplier text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS search_text text NOT NULL DEFAULT '';
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS phone_norm text
  GENERATED ALWAYS AS (right(regexp_replace(phone, '[^0-9]', '', 'g'), 10)) STORED;
CREATE INDEX IF NOT EXISTS customer_phone_norm_idx ON public.customers(phone_norm);
CREATE INDEX IF NOT EXISTS customer_name_trgm_idx ON public.customers USING gin(lower(name) gin_trgm_ops);

-- Rows created before workshop intake have a model_id and blank workshop display fields.
UPDATE public.vehicles v SET model_name=m.model_name,vehicle_type=m.category::text,
  manufacturer=coalesce(nullif(v.manufacturer,''),m.brand),
  lifecycle=CASE WHEN v.lifecycle='received' AND v.status IN ('sold','reserved','delivered')
    THEN v.status::text ELSE v.lifecycle END
FROM public.vehicle_models m WHERE m.id=v.model_id AND v.model_name='';

CREATE TABLE IF NOT EXISTS public.vehicle_components (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vehicle_id uuid NOT NULL REFERENCES public.vehicles,
  component_type text NOT NULL CHECK (component_type IN ('battery','charger','controller','motor','engine','other')),
  serial_no text NOT NULL CHECK (public.vehicle_number_key(serial_no) IS NOT NULL),
  brand text, spec text, installed_on date, removed_on date, removal_reason text, change_reason text,
  created_by uuid REFERENCES auth.users DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (removed_on >= installed_on),
  CHECK (removed_on IS NULL OR nullif(trim(removal_reason),'') IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS component_vehicle_idx ON public.vehicle_components(vehicle_id);
CREATE UNIQUE INDEX IF NOT EXISTS component_active_serial_idx ON public.vehicle_components
  (public.vehicle_number_key(serial_no)) WHERE removed_on IS NULL;

CREATE TABLE IF NOT EXISTS public.vehicle_ownership (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vehicle_id uuid NOT NULL REFERENCES public.vehicles,
  customer_id uuid NOT NULL REFERENCES public.customers, invoice_id uuid REFERENCES public.billing_documents,
  from_date date NOT NULL, to_date date CHECK (to_date >= from_date),
  source text NOT NULL CHECK (source IN ('sale','transfer','manual_link','backfill')),
  created_by uuid REFERENCES auth.users DEFAULT auth.uid(), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ownership_open_idx ON public.vehicle_ownership(vehicle_id) WHERE to_date IS NULL;
CREATE INDEX IF NOT EXISTS ownership_vehicle_idx ON public.vehicle_ownership(vehicle_id,from_date DESC);
CREATE INDEX IF NOT EXISTS ownership_customer_idx ON public.vehicle_ownership(customer_id);
CREATE TABLE IF NOT EXISTS public.vehicle_registrations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), vehicle_id uuid NOT NULL REFERENCES public.vehicles,
  registration_no text NOT NULL CHECK (public.vehicle_number_key(registration_no) IS NOT NULL),
  registration_date date, rto text, notes text, is_current boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES auth.users DEFAULT auth.uid(), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS registration_current_number_idx ON public.vehicle_registrations
  (public.vehicle_number_key(registration_no)) WHERE is_current;
CREATE INDEX IF NOT EXISTS registration_vehicle_idx ON public.vehicle_registrations(vehicle_id,created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS registration_current_vehicle_idx ON public.vehicle_registrations(vehicle_id) WHERE is_current;

-- Abort without changing live records if previously permitted spellings collide.
DO $$
DECLARE conflict record;
BEGIN
  SELECT field, key, string_agg(v.chassis_no || ' (' || v.id || ')', ', ') AS vehicles INTO conflict
  FROM public.vehicles v CROSS JOIN LATERAL (VALUES
    ('Chassis',public.vehicle_number_key(v.chassis_no)),('Engine',public.vehicle_number_key(v.engine_no)),
    ('Motor',public.vehicle_number_key(v.motor_no)),('Battery',public.vehicle_number_key(v.battery_no)),
    ('Registration',public.vehicle_number_key(v.registration_no))
  ) identifiers(field,key) WHERE key IS NOT NULL GROUP BY field,key HAVING count(*) > 1 LIMIT 1;
  IF FOUND THEN RAISE EXCEPTION 'Resolve duplicate % % on vehicles % before upgrading',
    conflict.field, conflict.key, conflict.vehicles; END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_chassis_key ON public.vehicles(public.vehicle_number_key(chassis_no));
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_engine_key ON public.vehicles(public.vehicle_number_key(engine_no));
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_motor_key ON public.vehicles(public.vehicle_number_key(motor_no));

-- Historical imports run without an auth session. Record the migration as the actor role.
ALTER TABLE public.workshop_audit ALTER COLUMN actor DROP NOT NULL;
ALTER TABLE public.workshop_audit DROP CONSTRAINT IF EXISTS workshop_audit_actor_required;
ALTER TABLE public.workshop_audit ADD CONSTRAINT workshop_audit_actor_required
  CHECK (actor IS NOT NULL OR role = 'migration');

CREATE OR REPLACE FUNCTION public.vehicle_history_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  before_row jsonb := to_jsonb(OLD);
  after_row jsonb := to_jsonb(NEW);
  item jsonb := coalesce(after_row,before_row);
  vid uuid := (item->>'vehicle_id')::uuid;
  action text := replace(TG_TABLE_NAME,'_',' ') || ' ' || lower(TG_OP);
  reason text := coalesce(item->>'removal_reason',item->>'change_reason',item->>'notes','');
BEGIN
  IF auth.uid() IS NULL THEN
    INSERT INTO public.workshop_audit(role,entity,record_id,vehicle_id,action,before_record,after_record,reason)
      VALUES ('migration',TG_TABLE_NAME,(item->>'id')::uuid,vid,action,before_row,after_row,reason);
  ELSE
    PERFORM public.ws_audit(TG_TABLE_NAME,(item->>'id')::uuid,NULL,vid,action,before_row,after_row,reason);
  END IF;
  RETURN NULL;
END $$;

DO $$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['vehicle_components','vehicle_registrations','vehicle_ownership'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',tbl);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated',tbl);
    EXECUTE format('DROP POLICY IF EXISTS register_read ON public.%I',tbl);
    EXECUTE format('CREATE POLICY register_read ON public.%I FOR SELECT TO authenticated USING
      (public.has_permission(''vehicles.read'') AND (%L <> ''vehicle_ownership'' OR public.has_permission(''customers.read'')))',tbl,tbl);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated',tbl);
    EXECUTE format('DROP TRIGGER IF EXISTS register_audit ON public.%I',tbl);
    EXECUTE format('CREATE TRIGGER register_audit AFTER INSERT OR UPDATE OR DELETE ON public.%I
      FOR EACH ROW EXECUTE FUNCTION public.vehicle_history_audit()',tbl);
  END LOOP;
END $$;

INSERT INTO public.vehicle_components(vehicle_id, component_type, serial_no)
SELECT v.id,'battery',upper(trim(v.battery_no)) FROM public.vehicles v
WHERE public.vehicle_number_key(v.battery_no) IS NOT NULL
  AND NOT EXISTS (SELECT FROM public.vehicle_components c WHERE c.vehicle_id=v.id AND c.component_type='battery');
INSERT INTO public.vehicle_ownership(vehicle_id,customer_id,invoice_id,from_date,source)
SELECT id,customer_id,purchase_invoice_id,coalesce(purchase_date,received_date,created_at::date),'backfill'
FROM public.vehicles v WHERE customer_id IS NOT NULL
  AND NOT EXISTS (SELECT FROM public.vehicle_ownership o WHERE o.vehicle_id=v.id);
INSERT INTO public.vehicle_registrations(vehicle_id,registration_no)
SELECT id,upper(trim(registration_no)) FROM public.vehicles v WHERE public.vehicle_number_key(registration_no) IS NOT NULL
  AND NOT EXISTS (SELECT FROM public.vehicle_registrations r WHERE r.vehicle_id=v.id);

-- Existing workshop delivery, external vehicle registration and corrections update these two
-- parent fields. Capture those writes here too. Do not infer a historical registration date.
CREATE OR REPLACE FUNCTION public.vehicle_history_sync() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  effective_date date := coalesce(NEW.purchase_date,current_date);
  conflicting public.vehicles;
  index_name text;
BEGIN
  IF NEW.customer_id IS DISTINCT FROM OLD.customer_id AND NOT EXISTS (SELECT FROM public.vehicle_ownership
    WHERE vehicle_id=NEW.id AND to_date IS NULL AND customer_id=NEW.customer_id) THEN
    UPDATE public.vehicle_ownership SET to_date=greatest(from_date,effective_date)
      WHERE vehicle_id=NEW.id AND to_date IS NULL;
    IF NEW.customer_id IS NOT NULL THEN
      INSERT INTO public.vehicle_ownership(vehicle_id,customer_id,invoice_id,from_date,source)
      VALUES(NEW.id,NEW.customer_id,NEW.purchase_invoice_id,effective_date,
        CASE WHEN NEW.purchase_invoice_id IS NULL THEN 'manual_link' ELSE 'sale' END);
    END IF;
  ELSIF NEW.purchase_invoice_id IS DISTINCT FROM OLD.purchase_invoice_id THEN
    UPDATE public.vehicle_ownership SET invoice_id=NEW.purchase_invoice_id WHERE vehicle_id=NEW.id AND to_date IS NULL;
  END IF;
  IF EXISTS (SELECT FROM public.vehicle_registrations WHERE vehicle_id=NEW.id AND is_current
    AND registration_no=NEW.registration_no) THEN RETURN NULL; END IF;
  IF public.vehicle_number_key(NEW.registration_no) IS DISTINCT FROM public.vehicle_number_key(OLD.registration_no) THEN
    UPDATE public.vehicle_registrations SET is_current=false WHERE vehicle_id=NEW.id AND is_current;
    IF public.vehicle_number_key(NEW.registration_no) IS NOT NULL THEN
      BEGIN
        INSERT INTO public.vehicle_registrations(vehicle_id,registration_no) VALUES(NEW.id,NEW.registration_no);
      EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS index_name = CONSTRAINT_NAME;
        IF index_name <> 'registration_current_number_idx' THEN RAISE; END IF;
        SELECT v.* INTO conflicting FROM public.vehicle_registrations r JOIN public.vehicles v ON v.id=r.vehicle_id
          WHERE r.is_current AND public.vehicle_number_key(r.registration_no)=public.vehicle_number_key(NEW.registration_no);
        RAISE EXCEPTION 'Registration % is already on % (chassis %, status %)',NEW.registration_no,
          conflicting.model_name,conflicting.chassis_no,conflicting.lifecycle;
      END;
    END IF;
  ELSIF NEW.registration_no IS DISTINCT FROM OLD.registration_no THEN
    UPDATE public.vehicle_registrations SET registration_no=NEW.registration_no WHERE vehicle_id=NEW.id AND is_current;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS vehicle_history_sync ON public.vehicles;
CREATE TRIGGER vehicle_history_sync AFTER INSERT OR UPDATE OF customer_id,purchase_invoice_id,registration_no
  ON public.vehicles FOR EACH ROW EXECUTE FUNCTION public.vehicle_history_sync();

CREATE OR REPLACE FUNCTION public.vehicle_search_refresh() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  NEW.search_text := lower(concat_ws(' ',NEW.chassis_no,NEW.motor_no,NEW.engine_no,NEW.registration_no,
    public.vehicle_number_key(NEW.chassis_no),public.vehicle_number_key(NEW.motor_no),
    public.vehicle_number_key(NEW.engine_no),public.vehicle_number_key(NEW.registration_no),
    NEW.model_name,NEW.variant,NEW.colour,(SELECT string_agg(c.serial_no || ' ' || public.vehicle_number_key(c.serial_no),' ')
      FROM public.vehicle_components c WHERE c.vehicle_id=NEW.id AND c.removed_on IS NULL)));
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS vehicle_search_refresh ON public.vehicles;
CREATE TRIGGER vehicle_search_refresh BEFORE INSERT OR UPDATE OF chassis_no,engine_no,motor_no,registration_no,
  model_name,variant,colour,battery_no ON public.vehicles FOR EACH ROW EXECUTE FUNCTION public.vehicle_search_refresh();

-- battery_no remains the first active battery for existing workshop screens. New code uses components.
CREATE OR REPLACE FUNCTION public.vehicle_component_refresh() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE vid uuid := coalesce(NEW.vehicle_id,OLD.vehicle_id);
BEGIN
  UPDATE public.vehicles SET battery_no=(SELECT serial_no FROM public.vehicle_components
    WHERE vehicle_id=vid AND component_type='battery' AND removed_on IS NULL ORDER BY created_at,id LIMIT 1),
    updated_at=clock_timestamp() WHERE id=vid;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS vehicle_component_refresh ON public.vehicle_components;
CREATE TRIGGER vehicle_component_refresh AFTER INSERT OR UPDATE OR DELETE ON public.vehicle_components
  FOR EACH ROW EXECUTE FUNCTION public.vehicle_component_refresh();
UPDATE public.vehicles SET registration_no=nullif(upper(trim(registration_no)),''),
  battery_no=nullif(upper(trim(battery_no)),'') WHERE search_text='';
CREATE INDEX IF NOT EXISTS vehicle_search_trgm_idx ON public.vehicles USING gin(search_text gin_trgm_ops);
CREATE INDEX IF NOT EXISTS vehicle_register_order_idx ON public.vehicles(received_date DESC NULLS LAST,id);

-- Shared by the live check and authoritative write paths. Each identifier uses its unique index.
CREATE OR REPLACE FUNCTION public.vehicle_conflicts(p jsonb) RETURNS text[]
LANGUAGE sql STABLE SET search_path = '' AS $$
  WITH matches AS (
    SELECT 'Chassis' AS field, v.chassis_no AS serial, v.id FROM public.vehicles v
      WHERE public.vehicle_number_key(v.chassis_no)=public.vehicle_number_key(p->>'chassis_no')
    UNION ALL
    SELECT 'Motor',v.motor_no,v.id FROM public.vehicles v
      WHERE public.vehicle_number_key(v.motor_no)=public.vehicle_number_key(p->>'motor_no')
    UNION ALL
    SELECT 'Engine',v.engine_no,v.id FROM public.vehicles v
      WHERE public.vehicle_number_key(v.engine_no)=public.vehicle_number_key(p->>'engine_no')
    UNION ALL
    SELECT initcap(c.component_type),c.serial_no,c.vehicle_id FROM jsonb_array_elements(p->'components') item
      JOIN public.vehicle_components c ON public.vehicle_number_key(c.serial_no)=public.vehicle_number_key(item->>'serial_no')
      WHERE c.removed_on IS NULL
  )
  SELECT ARRAY(SELECT format('%s %s is already on %s (chassis %s, status %s)',
    m.field,m.serial,v.model_name,v.chassis_no,v.lifecycle) FROM matches m JOIN public.vehicles v USING(id))
$$;

CREATE OR REPLACE FUNCTION public.vehicle_check_duplicates(p jsonb) RETURNS text[]
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT public.has_permission('vehicles.write') THEN RAISE EXCEPTION 'Vehicle write permission required'; END IF;
  RETURN public.vehicle_conflicts(p);
END $$;

CREATE OR REPLACE FUNCTION public.vehicle_intake_options() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT public.has_permission('vehicles.write') THEN RAISE EXCEPTION 'Vehicle write permission required'; END IF;
  RETURN jsonb_build_object(
    'products',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY brand,model_name,variant)
      FROM (SELECT id,code,brand,model_name,variant,category FROM public.catalog_products
        WHERE category IN ('tractor','e_rickshaw','cng_rickshaw','diesel_rickshaw')) p),'[]'::jsonb),
    'inspectors',ARRAY(SELECT a.email FROM public.access_assignments a WHERE a.active AND (a.role='owner'
      OR EXISTS (SELECT FROM public.access_permissions ap WHERE ap.role=a.role AND ap.permission='pdi.write'))
      ORDER BY a.email));
END $$;

CREATE OR REPLACE FUNCTION public.vehicle_add_component(vid uuid, item jsonb, installed date) RETURNS uuid
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE cid uuid; messages text[];
BEGIN
  IF public.vehicle_number_key(item->>'serial_no') IS NULL OR item->>'component_type' IS NULL OR
    item->>'component_type' NOT IN ('battery','charger','controller','motor','engine','other')
    THEN RAISE EXCEPTION 'Enter a component type and serial number'; END IF;
  BEGIN
    INSERT INTO public.vehicle_components(vehicle_id,component_type,serial_no,brand,spec,installed_on)
      VALUES(vid,item->>'component_type',upper(trim(item->>'serial_no')),nullif(trim(item->>'brand'),''),
        nullif(trim(item->>'spec'),''),installed) RETURNING id INTO cid;
  EXCEPTION WHEN unique_violation THEN
    messages := public.vehicle_conflicts(jsonb_build_object('components',jsonb_build_array(item)));
    RAISE EXCEPTION '%',coalesce(messages[1],'Component serial already in use');
  END;
  RETURN cid;
END $$;

-- Both front doors share the stock movement, reservation and PDI transaction. The workshop
-- wrapper retains its manager-only corrections, optimistic lock and self-assignment rules.
CREATE OR REPLACE FUNCTION public.vehicle_save_internal(p jsonb, register_intake boolean) RETURNS uuid
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
  vid uuid := coalesce(nullif(p->>'id','')::uuid,gen_random_uuid());
  previous public.vehicles; saved public.vehicles; product public.catalog_products;
  intake boolean := coalesce((p->>'intake')::boolean,false);
  inspector text := coalesce(nullif(lower(trim(p->>'inspector_email')),''),public.ws_email());
  stock uuid; checklist jsonb; component jsonb; primary_battery uuid;
  reason text := trim(coalesce(p->>'correction_reason',''));
  messages text[];
BEGIN
  IF register_intake THEN
    IF NOT public.has_permission('vehicles.write') THEN RAISE EXCEPTION 'Vehicle write permission required'; END IF;
  ELSIF NOT (public.has_permission('service.write') OR public.has_permission('pdi.write')) THEN
    RAISE EXCEPTION 'Vehicle intake permission required';
  END IF;
  SELECT * INTO previous FROM public.vehicles WHERE id=vid FOR UPDATE;
  IF length(coalesce(public.vehicle_number_key(p->>'chassis_no'),'')) < 3 THEN
    RAISE EXCEPTION 'Enter a chassis number with at least three characters';
  END IF;
  IF previous.id IS NOT NULL THEN
    IF register_intake OR NOT public.has_permission('service.write') THEN
      RAISE EXCEPTION 'Manager required for vehicle corrections'; END IF;
    IF (p->>'updated_at')::timestamptz IS DISTINCT FROM previous.updated_at THEN
      RAISE EXCEPTION 'Vehicle changed. Reload before saving.'; END IF;
    IF length(reason)<5 THEN RAISE EXCEPTION 'A correction reason is required'; END IF;
    IF length(trim(coalesce(p->>'model_name','')))<2 THEN RAISE EXCEPTION 'Model and chassis required'; END IF;
    UPDATE public.vehicles SET model_name=trim(p->>'model_name'),variant=coalesce(p->>'variant',''),
      chassis_no=upper(trim(p->>'chassis_no')), engine_no=nullif(upper(trim(p->>'engine_no')),''),
      motor_no=nullif(upper(trim(p->>'motor_no')),''),registration_no=nullif(upper(trim(p->>'registration_no')),''),
      colour=coalesce(p->>'colour',''),location=coalesce(p->>'location',''),updated_at=clock_timestamp()
      WHERE id=vid;
    IF public.vehicle_number_key(p->>'battery_no') IS DISTINCT FROM public.vehicle_number_key(previous.battery_no) THEN
      SELECT id INTO primary_battery FROM public.vehicle_components
        WHERE vehicle_id=vid AND component_type='battery' AND removed_on IS NULL ORDER BY created_at,id LIMIT 1;
      UPDATE public.vehicle_components SET removed_on=current_date,removal_reason=reason WHERE id=primary_battery;
      IF public.vehicle_number_key(p->>'battery_no') IS NOT NULL THEN
        PERFORM public.vehicle_add_component(vid,jsonb_build_object('component_type','battery','serial_no',p->>'battery_no'),current_date);
      END IF;
    END IF;
    SELECT * INTO saved FROM public.vehicles WHERE id=vid;
    PERFORM public.ws_audit('vehicle',vid,saved.customer_id,vid,'Vehicle details corrected',to_jsonb(previous),to_jsonb(saved),reason);
    RETURN vid;
  END IF;

  IF NOT intake AND NOT public.has_permission('service.write') THEN
    RAISE EXCEPTION 'Service manager required for customer vehicle registration'; END IF;
  IF NOT intake AND nullif(p->>'customer_id','') IS NULL THEN RAISE EXCEPTION 'Choose the vehicle owner'; END IF;
  IF nullif(p->>'purchase_invoice_id','') IS NOT NULL AND NOT EXISTS (
    SELECT FROM public.billing_documents WHERE id=(p->>'purchase_invoice_id')::uuid AND kind='invoice'
      AND cancelled_at IS NULL AND customer_id=(p->>'customer_id')::uuid
  ) THEN RAISE EXCEPTION 'Purchase invoice does not match customer'; END IF;
  IF intake THEN
    SELECT * INTO product FROM public.catalog_products WHERE id=(p->>'product_id')::uuid FOR SHARE;
    IF NOT FOUND OR product.category NOT IN ('tractor','e_rickshaw','cng_rickshaw','diesel_rickshaw') THEN
      RAISE EXCEPTION 'Choose a vehicle catalogue product'; END IF;
    IF NOT EXISTS (SELECT FROM public.access_assignments a WHERE a.email=inspector AND a.active
      AND (a.role='owner' OR EXISTS (SELECT FROM public.access_permissions ap
        WHERE ap.role=a.role AND ap.permission='pdi.write'))) THEN
      RAISE EXCEPTION 'Select an active inspector with PDI permission'; END IF;
    IF NOT register_intake AND NOT public.has_permission('service.write') AND inspector<>public.ws_email() THEN
      RAISE EXCEPTION 'Only managers can assign another inspector'; END IF;
    IF register_intake THEN
      p := p || jsonb_build_object('model_name',product.model_name,'variant',product.variant,
        'vehicle_type',product.category,'manufacturer',product.brand);
      IF product.category='e_rickshaw' AND public.vehicle_number_key(p->>'motor_no') IS NULL THEN
        RAISE EXCEPTION 'Enter the electric motor number'; END IF;
      IF product.category<>'e_rickshaw' AND public.vehicle_number_key(p->>'engine_no') IS NULL THEN
        RAISE EXCEPTION 'Enter the engine number'; END IF;
    END IF;
    INSERT INTO public.inventory(item_type,item_id,item_name,sku_or_code,qty_available)
      VALUES('vehicle',product.id,product.model_name,product.code,0) ON CONFLICT(item_type,item_id) DO NOTHING;
    SELECT id INTO stock FROM public.inventory WHERE item_id=product.id AND item_type='vehicle' FOR UPDATE;
    PERFORM public.app_move_stock(stock,1,coalesce(nullif(p->>'shipment_ref',''),'Vehicle intake '||(p->>'chassis_no')));
    UPDATE public.inventory SET qty_reserved=qty_reserved+1 WHERE id=stock;
  END IF;
  IF length(trim(coalesce(p->>'model_name','')))<2 THEN RAISE EXCEPTION 'Model and chassis required'; END IF;

  BEGIN
    INSERT INTO public.vehicles(id,product_id,model_name,variant,vehicle_type,chassis_no,engine_no,motor_no,
      registration_no,colour,customer_id,purchase_invoice_id,purchase_date,received_date,location,manufacturer,
      supplier,shipment_ref,supplier_invoice,lifecycle,stock_id)
    VALUES(vid,nullif(p->>'product_id','')::uuid,trim(p->>'model_name'),coalesce(p->>'variant',''),
      coalesce(p->>'vehicle_type','tractor'),upper(trim(p->>'chassis_no')),nullif(upper(trim(p->>'engine_no')),''),
      nullif(upper(trim(p->>'motor_no')),''),nullif(upper(trim(p->>'registration_no')),''),coalesce(p->>'colour',''),
      nullif(p->>'customer_id','')::uuid,nullif(p->>'purchase_invoice_id','')::uuid,nullif(p->>'purchase_date','')::date,
      coalesce(nullif(p->>'received_date','')::date,current_date),coalesce(p->>'location',''),coalesce(p->>'manufacturer',''),
      coalesce(trim(p->>'supplier'),''),coalesce(p->>'shipment_ref',''),coalesce(p->>'supplier_invoice',''),
      CASE WHEN intake THEN 'pdi_pending' ELSE 'delivered' END,stock) RETURNING * INTO saved;
  EXCEPTION WHEN unique_violation THEN
    messages := public.vehicle_conflicts(p);
    IF messages[1] IS NULL THEN RAISE; END IF;
    RAISE EXCEPTION 'Identifier must be unique. %',messages[1];
  END;
  IF intake THEN
    SELECT t.items INTO checklist FROM public.pdi_templates t WHERE t.vehicle_type=saved.vehicle_type;
    IF checklist IS NULL THEN RAISE EXCEPTION 'Configure a PDI template for this vehicle type first'; END IF;
    INSERT INTO public.pdi_checks(vehicle_id,inspector_email,checklist) VALUES(vid,inspector,checklist);
  END IF;
  IF public.vehicle_number_key(p->>'battery_no') IS NOT NULL THEN
    PERFORM public.vehicle_add_component(vid,jsonb_build_object('component_type','battery','serial_no',p->>'battery_no'),saved.received_date);
  END IF;
  IF register_intake THEN
    FOR component IN SELECT value FROM jsonb_array_elements(p->'components') LOOP
      PERFORM public.vehicle_add_component(vid,component,saved.received_date);
    END LOOP;
  END IF;
  SELECT * INTO saved FROM public.vehicles WHERE id=vid;
  PERFORM public.ws_audit('vehicle',vid,saved.customer_id,vid,
    CASE WHEN intake THEN 'Vehicle received and PDI created' ELSE 'Customer vehicle registered' END,NULL,to_jsonb(saved));
  RETURN vid;
END $$;

CREATE OR REPLACE FUNCTION public.ws_save_vehicle(p jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT public.vehicle_save_internal(p,false) $$;

CREATE OR REPLACE FUNCTION public.vehicle_receive(p jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Enter a vehicle record'; END IF;
  IF jsonb_typeof(coalesce(p->'components','[]')) <> 'array' THEN RAISE EXCEPTION 'Components must be a list'; END IF;
  RETURN public.vehicle_save_internal(
    (p - ARRAY['id','customer_id','purchase_invoice_id','purchase_date','registration_no','battery_no'])
    || jsonb_build_object('intake',true),true);
END $$;

CREATE OR REPLACE FUNCTION public.component_save(p jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  vid uuid := (p->>'vehicle_id')::uuid;
  part public.vehicle_components;
  reason text := nullif(trim(p->>'reason'),'');
  effective_date date := coalesce(nullif(p->>'date','')::date,current_date);
BEGIN
  IF NOT public.has_permission('vehicles.write') THEN RAISE EXCEPTION 'Vehicle write permission required'; END IF;
  PERFORM 1 FROM public.vehicles WHERE id=vid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Vehicle not found'; END IF;
  IF p ? 'expected_updated_at' AND (p->>'expected_updated_at')::timestamptz IS DISTINCT FROM
    (SELECT updated_at FROM public.vehicles WHERE id=vid) THEN RAISE EXCEPTION 'Vehicle changed. Reload before saving.'; END IF;
  IF nullif(p->>'id','') IS NULL THEN
    RETURN public.vehicle_add_component(vid,p,coalesce(nullif(p->>'installed_on','')::date,effective_date));
  END IF;
  SELECT * INTO part FROM public.vehicle_components WHERE id=(p->>'id')::uuid AND vehicle_id=vid FOR UPDATE;
  IF NOT FOUND OR part.removed_on IS NOT NULL THEN RAISE EXCEPTION 'Select an active component on this vehicle'; END IF;
  IF reason IS NULL THEN RAISE EXCEPTION 'Enter the reason for this change'; END IF;
  IF p->>'action'='remove' THEN
    IF effective_date<part.installed_on THEN RAISE EXCEPTION 'Removal precedes installation'; END IF;
    UPDATE public.vehicle_components SET removed_on=effective_date,removal_reason=reason WHERE id=part.id;
  ELSE
    IF (p ? 'serial_no' AND public.vehicle_number_key(p->>'serial_no') IS DISTINCT FROM public.vehicle_number_key(part.serial_no))
      OR (p ? 'component_type' AND p->>'component_type' IS DISTINCT FROM part.component_type)
      THEN RAISE EXCEPTION 'Replace the component to change its serial or type'; END IF;
    UPDATE public.vehicle_components SET brand=coalesce(p->>'brand',brand),spec=coalesce(p->>'spec',spec),
      installed_on=coalesce(nullif(p->>'installed_on','')::date,installed_on),change_reason=reason WHERE id=part.id;
  END IF;
  RETURN part.id;
END $$;

CREATE OR REPLACE FUNCTION public.component_replace(p jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE old_id uuid; part public.vehicle_components;
BEGIN
  IF nullif(p->>'id','') IS NULL THEN RAISE EXCEPTION 'Select the component to replace'; END IF;
  old_id := public.component_save(p || '{"action":"remove"}'::jsonb);
  SELECT * INTO STRICT part FROM public.vehicle_components WHERE id=old_id;
  RETURN public.vehicle_add_component(part.vehicle_id,
    jsonb_build_object('component_type',part.component_type) || coalesce(p->'replacement','{}'),part.removed_on);
END $$;

-- Each row has a savepoint. The outer savepoint rolls *all* successful rows back on any
-- validation failure or preview, including their inventory movements, PDI and audit entries.
CREATE OR REPLACE FUNCTION public.vehicle_receive_batch(items jsonb, preview boolean) RETURNS jsonb
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE entry jsonb; row_no int := 0; errors jsonb := '[]'; ids uuid[] := '{}';
BEGIN
  IF NOT public.has_permission('vehicles.write') THEN RAISE EXCEPTION 'Vehicle write permission required'; END IF;
  IF jsonb_typeof(items) IS DISTINCT FROM 'array' OR jsonb_array_length(items) NOT BETWEEN 1 AND 250
    THEN RAISE EXCEPTION 'Import between 1 and 250 vehicle rows'; END IF;
  BEGIN
    FOR entry IN SELECT value FROM jsonb_array_elements(items) LOOP
      row_no := row_no + 1;
      BEGIN
        ids := array_append(ids,public.vehicle_receive(entry));
      EXCEPTION WHEN data_exception OR integrity_constraint_violation OR raise_exception THEN
        errors := errors || jsonb_build_object('row',row_no,'message',SQLERRM);
      END;
    END LOOP;
    IF preview OR jsonb_array_length(errors)>0 THEN RAISE SQLSTATE 'V0001'; END IF;
  EXCEPTION WHEN SQLSTATE 'V0001' THEN ids := '{}';
  END;
  RETURN jsonb_build_object('ids',ids,'errors',errors,'count',row_no);
END $$;
CREATE OR REPLACE FUNCTION public.vehicle_bulk_receive(rows jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT public.vehicle_receive_batch(rows,false) $$;
CREATE OR REPLACE FUNCTION public.vehicle_bulk_preview(rows jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT public.vehicle_receive_batch(rows,true) $$;

CREATE OR REPLACE FUNCTION public.vehicle_register_list(
  q text DEFAULT '', filters jsonb DEFAULT '{}', page_offset integer DEFAULT 0, page_size integer DEFAULT 25
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  term text := lower(trim(coalesce(q,'')));
  customers_allowed boolean := public.has_permission('customers.read');
BEGIN
  IF NOT public.has_permission('vehicles.read') THEN RAISE EXCEPTION 'Vehicle read permission required'; END IF;
  IF NOT customers_allowed AND nullif(filters->>'owner','') IS NOT NULL THEN
    RAISE EXCEPTION 'Customer read permission required'; END IF;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY received_date DESC NULLS LAST,id) FROM (
    SELECT v.id,v.chassis_no,v.motor_no,v.engine_no,v.model_name,v.variant,v.vehicle_type,v.colour,
      v.lifecycle,v.location,v.received_date,v.registration_no,c.name AS owner_name
    FROM public.vehicles v LEFT JOIN public.customers c ON customers_allowed AND c.id=v.customer_id
    WHERE (term='' OR v.search_text LIKE '%' || replace(replace(replace(term,'\','\\'),'%','\%'),'_','\_') || '%'
      OR (public.vehicle_number_key(term) IS NOT NULL AND
        v.search_text LIKE '%' || replace(replace(replace(lower(public.vehicle_number_key(term)),'\','\\'),'%','\%'),'_','\_') || '%'))
      AND (nullif(filters->>'status','') IS NULL OR v.lifecycle=filters->>'status')
      AND (nullif(filters->>'type','') IS NULL OR v.vehicle_type=filters->>'type')
      AND (nullif(filters->>'model','') IS NULL OR strpos(lower(v.model_name),lower(filters->>'model'))>0)
      AND (nullif(filters->>'owner','') IS NULL OR strpos(lower(c.name),lower(filters->>'owner'))>0)
      AND (NOT coalesce((filters->>'unregistered')::boolean,false) OR public.vehicle_number_key(v.registration_no) IS NULL)
      AND (NOT coalesce((filters->>'unsold')::boolean,false) OR (v.customer_id IS NULL AND v.lifecycle NOT IN ('sold','delivered')))
      AND (NOT coalesce((filters->>'pdi')::boolean,false) OR v.lifecycle IN ('pdi_pending','pdi_failed','pdi_issues'))
    ORDER BY v.received_date DESC NULLS LAST,v.id LIMIT least(greatest(page_size,1),101) OFFSET greatest(page_offset,0)
  ) page),'[]'::jsonb);
END $$;

CREATE INDEX IF NOT EXISTS vehicle_register_activity_idx ON public.workshop_audit(vehicle_id,created_at DESC,id DESC);

CREATE OR REPLACE FUNCTION public.vehicle_360(vehicle_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  vid uuid := vehicle_id; v public.vehicles;
  customers_allowed boolean := public.has_permission('customers.read');
  invoices_allowed boolean := public.has_permission('invoices.read');
BEGIN
  IF NOT public.has_permission('vehicles.read') THEN RAISE EXCEPTION 'Vehicle read permission required'; END IF;
  SELECT * INTO v FROM public.vehicles WHERE id=vid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Vehicle not found'; END IF;
  -- Explicit projections prevent customer identity documents, billing snapshots and private
  -- attachment paths from becoming visible when upstream tables gain new columns.
  RETURN jsonb_build_object(
    'vehicle', jsonb_build_object('id',v.id,'updated_at',v.updated_at,'model_name',v.model_name,'variant',v.variant,'vehicle_type',v.vehicle_type,
      'manufacturer',v.manufacturer,'colour',v.colour,'chassis_no',v.chassis_no,'motor_no',v.motor_no,
      'engine_no',v.engine_no,'registration_no',v.registration_no,'lifecycle',v.lifecycle,'location',v.location,
      'received_date',v.received_date,'supplier',v.supplier,'supplier_invoice',v.supplier_invoice,'shipment_ref',v.shipment_ref),
    'specs',coalesce((SELECT specs FROM public.catalog_products WHERE id=v.product_id),
      (SELECT specs FROM public.vehicle_models WHERE id=v.model_id),'{}'),
    'activity',coalesce((SELECT jsonb_agg(to_jsonb(events)) FROM (
      SELECT a.created_at,a.action,a.role AS actor_role,coalesce(u.email,a.actor::text,'Migration') AS actor,
        CASE WHEN a.entity='vehicle_components' THEN coalesce(a.after_record,a.before_record)->>'serial_no'
             WHEN a.entity='vehicle_registrations' THEN coalesce(a.after_record,a.before_record)->>'registration_no' END AS identifier,
        a.reason FROM public.workshop_audit a LEFT JOIN auth.users u ON u.id=a.actor WHERE a.vehicle_id=vid AND
          (a.entity IN ('vehicle_components','vehicle_registrations') OR (customers_allowed AND a.entity='vehicle_ownership'))
      ORDER BY a.created_at DESC,a.id DESC LIMIT 100) events),'[]'),
    'components',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT id,component_type,serial_no,brand,spec,
      installed_on,removed_on,removal_reason FROM public.vehicle_components c WHERE c.vehicle_id=vid ORDER BY c.created_at,c.id) x),'[]'),
    'registrations',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT registration_no,registration_date,rto,notes,is_current
      FROM public.vehicle_registrations r WHERE r.vehicle_id=vid ORDER BY r.created_at DESC,r.id) x),'[]'),
    'ownership',CASE WHEN customers_allowed THEN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT
      c.id AS customer_id,c.name,c.phone,o.from_date,o.to_date,o.source FROM public.vehicle_ownership o JOIN public.customers c ON c.id=o.customer_id
      WHERE o.vehicle_id=vid ORDER BY o.from_date DESC,o.created_at DESC) x),'[]') END,
    'invoice',CASE WHEN invoices_allowed THEN (SELECT jsonb_build_object('id',b.id,'number',b.number,
      'document_date',b.document_date,'total',b.total,'amount_paid',b.amount_paid,'balance',b.total-b.amount_paid)
      FROM public.billing_documents b WHERE b.id=v.purchase_invoice_id) END,
    'payments',CASE WHEN invoices_allowed THEN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT
      paid_at,amount,method FROM public.billing_payments WHERE invoice_id=v.purchase_invoice_id ORDER BY paid_at) x),'[]') END,
    'pdi',CASE WHEN public.has_permission('pdi.read') THEN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT
      number,result,inspected_at FROM public.pdi_checks p WHERE p.vehicle_id=vid AND
      (public.access_role()<>'pdi' OR p.inspector_email=public.ws_email()) ORDER BY created_at DESC) x),'[]') END,
    'delivery',CASE WHEN public.has_permission('delivery.read') THEN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT
      signed_at,assigned_email FROM public.delivery_checklist d WHERE d.vehicle_id=vid AND
      (public.has_permission('service.write') OR d.assigned_email=public.ws_email())) x),'[]') END,
    'warranties',CASE WHEN public.has_permission('warranty.read') THEN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT
      product_name,serial_no,start_date,end_date,status FROM public.warranties w WHERE w.vehicle_id=vid ORDER BY end_date DESC) x),'[]') END,
    'jobs',CASE WHEN public.has_permission('service.read') THEN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT
      number,job_type,status,received_at,next_service_date FROM public.service_jobs j WHERE j.vehicle_id=vid
      AND public.ws_job_access(j.id) ORDER BY j.created_at DESC) x),'[]') END,
    'attachments',CASE WHEN public.has_permission('service.read') THEN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT
      a.entity,a.label,a.created_at FROM public.workshop_attachments a
      WHERE ((a.entity='pdi' AND EXISTS (SELECT FROM public.pdi_checks p WHERE p.id=a.record_id AND p.vehicle_id=vid))
        OR (a.entity='job' AND EXISTS (SELECT FROM public.service_jobs j WHERE j.id=a.record_id AND j.vehicle_id=vid))
        OR (a.entity='claim' AND EXISTS (SELECT FROM public.warranty_claims c JOIN public.warranties w ON w.id=c.warranty_id
          WHERE c.id=a.record_id AND w.vehicle_id=vid))) AND public.ws_attachment_access(a.entity,a.record_id)
      ORDER BY a.created_at DESC) x),'[]') END
  );
END $$;

-- Default Supabase privileges can grant EXECUTE directly to authenticated as well as PUBLIC.
REVOKE ALL ON FUNCTION public.vehicle_save_internal(jsonb,boolean),public.vehicle_conflicts(jsonb),
  public.vehicle_add_component(uuid,jsonb,date),public.vehicle_receive_batch(jsonb,boolean),
  public.vehicle_history_audit(),public.vehicle_history_sync(),public.vehicle_search_refresh(),
  public.vehicle_component_refresh() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.vehicle_check_duplicates(jsonb),public.vehicle_intake_options(),public.vehicle_receive(jsonb),
  public.vehicle_bulk_receive(jsonb),public.vehicle_bulk_preview(jsonb),public.component_save(jsonb),
  public.component_replace(jsonb),public.vehicle_register_list(text,jsonb,integer,integer),public.vehicle_360(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vehicle_check_duplicates(jsonb),public.vehicle_intake_options(),public.vehicle_receive(jsonb),
  public.vehicle_bulk_receive(jsonb),public.vehicle_bulk_preview(jsonb),public.component_save(jsonb),
  public.component_replace(jsonb),public.vehicle_register_list(text,jsonb,integer,integer),public.vehicle_360(uuid)
  TO authenticated;
-- Phase 2. Billing owns quantity movements. Assigning a chassis changes identity and
-- ownership only. Both operations happen in the invoice transaction.
CREATE OR REPLACE FUNCTION public.vehicle_sale_choices(product uuid, q text DEFAULT '')
RETURNS TABLE(id uuid,chassis_no text,motor_no text,engine_no text,colour text,received_date date,stock_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NOT public.has_permission('vehicles.read') THEN RAISE EXCEPTION 'Vehicle access required'; END IF;
  RETURN QUERY SELECT v.id,v.chassis_no,v.motor_no,v.engine_no,v.colour,v.received_date,v.stock_id
    FROM public.vehicles v WHERE v.product_id=product AND v.stock_id IS NOT NULL AND v.customer_id IS NULL
      AND v.lifecycle IN ('available','pdi_issues','pdi_passed') AND (coalesce(trim(q),'')=''
        OR strpos(public.vehicle_number_key(v.chassis_no),public.vehicle_number_key(q))>0)
    ORDER BY public.vehicle_number_key(v.chassis_no)=public.vehicle_number_key(q) DESC,v.received_date,v.id LIMIT 40;
END $$;

CREATE OR REPLACE FUNCTION public.vehicle_release_sale(p jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b public.billing_documents; v public.vehicles; before_row jsonb; draft public.delivery_checklist;
BEGIN
  IF NOT (public.has_permission('vehicles.write') AND public.has_permission('invoices.write')) THEN
    RAISE EXCEPTION 'Invoice and vehicle write permissions required'; END IF;
  SELECT * INTO STRICT b FROM public.billing_documents WHERE id=(p->>'invoice_id')::uuid AND kind='invoice' AND cancelled_at IS NULL FOR UPDATE;
  SELECT * INTO STRICT v FROM public.vehicles WHERE id=(p->>'vehicle_id')::uuid AND purchase_invoice_id=b.id FOR UPDATE;
  IF EXISTS (SELECT FROM public.vehicle_ownership WHERE vehicle_id=v.id AND source='transfer') THEN
    RAISE EXCEPTION 'Sale is locked by an ownership transfer'; END IF;
  SELECT * INTO draft FROM public.delivery_checklist WHERE vehicle_id=v.id FOR UPDATE;
  IF draft.signed_at IS NOT NULL OR v.lifecycle='delivered' THEN
    RAISE EXCEPTION 'A delivered chassis cannot be released'; END IF;
  IF draft.id IS NOT NULL THEN
    PERFORM public.ws_audit('delivery',draft.id,v.customer_id,v.id,'Unsigned delivery withdrawn',
      to_jsonb(draft),NULL,b.number);
    DELETE FROM public.delivery_checklist WHERE id=draft.id;
  END IF;
  before_row:=to_jsonb(v);
  UPDATE public.vehicles SET customer_id=NULL,purchase_invoice_id=NULL,purchase_date=NULL,
    lifecycle='available',status='in_stock',updated_at=clock_timestamp() WHERE id=v.id RETURNING * INTO v;
  UPDATE public.billing_documents SET items=(SELECT jsonb_agg(CASE WHEN x->>'vehicleId'=v.id::text
    THEN x-ARRAY['vehicleId','chassisNo','motorNo','engineNo'] ELSE x END ORDER BY n)
    FROM jsonb_array_elements(b.items) WITH ORDINALITY t(x,n)),updated_at=clock_timestamp() WHERE id=b.id;
  IF EXISTS (SELECT FROM jsonb_array_elements(b.items) x WHERE x->>'vehicleId'=v.id::text) THEN
    INSERT INTO public.billing_audit(document_id,actor,before_record,after_record)
      SELECT b.id,auth.uid(),to_jsonb(b),to_jsonb(current_doc) FROM public.billing_documents current_doc WHERE current_doc.id=b.id;
  END IF;
  PERFORM public.ws_audit('vehicle',v.id,NULL,v.id,'Sale link released',before_row,to_jsonb(v),b.number);
END $$;

CREATE OR REPLACE FUNCTION public.vehicle_link_sale(p jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b public.billing_documents; v public.vehicles; idx integer:=(p->>'line_index')::integer;
  item jsonb; before_row jsonb; transferred boolean;
BEGIN
  IF NOT (public.has_permission('vehicles.write') AND public.has_permission('invoices.write')) THEN
    RAISE EXCEPTION 'Invoice and vehicle write permissions required'; END IF;
  SELECT * INTO STRICT b FROM public.billing_documents WHERE id=(p->>'invoice_id')::uuid
    AND kind='invoice' AND cancelled_at IS NULL AND service_job_id IS NULL FOR UPDATE;
  IF p ? 'customer_id' AND (p->>'customer_id')::uuid IS DISTINCT FROM b.customer_id THEN
    RAISE EXCEPTION 'Customer must match invoice'; END IF;
  SELECT * INTO STRICT v FROM public.vehicles WHERE id=(p->>'vehicle_id')::uuid FOR UPDATE;
  IF idx IS NULL THEN SELECT min(n-1) INTO idx FROM jsonb_array_elements(b.items) WITH ORDINALITY a(x,n)
    WHERE x->>'productId'=v.product_id::text AND (x->>'vehicleId' IS NULL OR x->>'vehicleId'=v.id::text)
    AND (x->>'qty')::numeric=1 AND x->>'inventoryId'=v.stock_id::text; END IF;
  item:=b.items->idx;
  IF idx IS NULL OR idx<0 OR item IS NULL OR v.stock_id IS NULL OR v.product_id IS NULL
    OR item->>'productId' IS DISTINCT FROM v.product_id::text OR item->>'inventoryId' IS DISTINCT FROM v.stock_id::text
    OR (item->>'qty')::numeric IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'Select a matching single-unit stock line'; END IF;
  IF (item->>'vehicleId' IS NOT NULL AND item->>'vehicleId'<>v.id::text) OR EXISTS (
    SELECT FROM jsonb_array_elements(b.items) WITH ORDINALITY a(x,n) WHERE n<>idx+1 AND x->>'vehicleId'=v.id::text)
    THEN RAISE EXCEPTION 'Chassis or invoice line is already linked'; END IF;
  IF v.purchase_invoice_id IS DISTINCT FROM b.id AND (v.purchase_invoice_id IS NOT NULL OR v.customer_id IS NOT NULL
    OR v.lifecycle NOT IN ('available','pdi_issues','pdi_passed')) THEN RAISE EXCEPTION 'Chassis % is unavailable',v.chassis_no; END IF;
  SELECT EXISTS (SELECT FROM public.vehicle_ownership WHERE vehicle_id=v.id AND source='transfer') INTO transferred;
  IF transferred AND NOT EXISTS (SELECT FROM public.vehicle_ownership WHERE vehicle_id=v.id
    AND invoice_id=b.id AND customer_id=b.customer_id AND to_date IS NOT NULL) THEN
    RAISE EXCEPTION 'Original purchaser is locked by an ownership transfer'; END IF;
  IF NOT transferred AND v.customer_id IS DISTINCT FROM b.customer_id AND EXISTS (
    SELECT FROM public.delivery_checklist WHERE vehicle_id=v.id) THEN
    RAISE EXCEPTION 'Customer is locked by delivery history'; END IF;
  before_row:=to_jsonb(v);
  IF NOT transferred AND (v.customer_id IS DISTINCT FROM b.customer_id OR v.purchase_invoice_id IS DISTINCT FROM b.id) THEN
    UPDATE public.vehicles SET customer_id=b.customer_id,purchase_invoice_id=b.id,purchase_date=b.document_date,
      lifecycle='sold',status='sold',updated_at=clock_timestamp() WHERE id=v.id RETURNING * INTO v;
    IF p->>'source'='backfill' THEN UPDATE public.vehicle_ownership SET source='backfill'
      WHERE vehicle_id=v.id AND to_date IS NULL; END IF;
    PERFORM public.ws_audit('vehicle',v.id,b.customer_id,v.id,'Chassis linked to invoice',before_row,to_jsonb(v),b.number);
  END IF;
  IF NOT transferred AND v.purchase_date IS DISTINCT FROM b.document_date THEN
    UPDATE public.vehicles SET purchase_date=b.document_date,updated_at=clock_timestamp() WHERE id=v.id;
    UPDATE public.vehicle_ownership SET from_date=b.document_date WHERE vehicle_id=v.id AND to_date IS NULL AND invoice_id=b.id;
  END IF;
  UPDATE public.billing_documents SET items=jsonb_set(items,ARRAY[idx::text],item||jsonb_build_object(
    'vehicleId',v.id,'chassisNo',v.chassis_no,'motorNo',v.motor_no,'engineNo',v.engine_no)),updated_at=clock_timestamp() WHERE id=b.id;
  IF item->>'vehicleId' IS DISTINCT FROM v.id::text THEN
    INSERT INTO public.billing_audit(document_id,actor,before_record,after_record)
      SELECT b.id,auth.uid(),to_jsonb(b),to_jsonb(current_doc) FROM public.billing_documents current_doc WHERE current_doc.id=b.id;
  END IF;
  IF (SELECT count(*) FROM public.vehicles WHERE purchase_invoice_id=b.id AND product_id=v.product_id AND stock_id=v.stock_id)
    >(SELECT sum((x->>'qty')::integer) FROM jsonb_array_elements(b.items) x WHERE x->>'inventoryId'=v.stock_id::text)
    THEN RAISE EXCEPTION 'Invoice stock lines already allocated'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.app_save_document(p_doc jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE did uuid:=coalesce(nullif(p_doc->>'id','')::uuid,gen_random_uuid()); old public.billing_documents;
  v public.vehicles; entry record; line jsonb; normalized jsonb:='[]'; saved jsonb; linked uuid[]:='{}';
BEGIN
  IF NOT public.has_permission(CASE p_doc->>'kind' WHEN 'invoice' THEN 'invoices.write'
    WHEN 'quotation' THEN 'quotations.write' ELSE '' END) THEN RAISE EXCEPTION 'Document edit permission required'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(did::text,0));
  SELECT * INTO old FROM public.billing_documents WHERE id=did FOR UPDATE;
  IF old.service_job_id IS NOT NULL OR old.cancelled_at IS NOT NULL THEN
    RAISE EXCEPTION 'Use the service job to manage this finalized invoice'; END IF;
  IF old.kind='invoice' AND old.customer_id IS DISTINCT FROM (p_doc->>'customerId')::uuid AND EXISTS (
    SELECT FROM public.vehicles sold JOIN public.vehicle_ownership o ON o.vehicle_id=sold.id
    WHERE sold.purchase_invoice_id=did AND o.source='transfer') THEN
    RAISE EXCEPTION 'The original purchaser is locked by an ownership transfer'; END IF;
  FOR entry IN SELECT x,n FROM jsonb_array_elements(p_doc->'items') WITH ORDINALITY a(x,n) LOOP
    line:=entry.x;
    IF nullif(line->>'vehicleId','') IS NOT NULL OR nullif(trim(line->>'chassisNo'),'') IS NOT NULL THEN
      IF NOT public.has_permission(CASE WHEN p_doc->>'kind'='quotation' THEN 'vehicles.read' ELSE 'vehicles.write' END)
        THEN RAISE EXCEPTION 'Vehicle permission required'; END IF;
      SELECT * INTO v FROM public.vehicles WHERE CASE WHEN nullif(line->>'vehicleId','') IS NOT NULL
        THEN id=(line->>'vehicleId')::uuid ELSE public.vehicle_number_key(chassis_no)=public.vehicle_number_key(line->>'chassisNo') END FOR UPDATE;
      IF NOT FOUND OR v.stock_id IS NULL OR v.product_id IS DISTINCT FROM (line->>'productId')::uuid
        OR (line->>'qty')::numeric IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'Select a matching chassis with quantity 1'; END IF;
      IF v.id=ANY(linked) OR (v.purchase_invoice_id IS DISTINCT FROM did AND
        (v.customer_id IS NOT NULL OR v.lifecycle NOT IN ('available','pdi_passed','pdi_issues'))) THEN RAISE EXCEPTION 'Chassis % is unavailable',v.chassis_no; END IF;
      linked:=array_append(linked,v.id);
      line:=line||jsonb_build_object('vehicleId',v.id,'chassisNo',v.chassis_no,'motorNo',v.motor_no,'engineNo',v.engine_no,'inventoryId',v.stock_id);
    END IF;
    normalized:=normalized||jsonb_build_array(line);
  END LOOP;
  saved:=public.ws_base_save_document(p_doc||jsonb_build_object('id',did,'items',normalized));
  FOR entry IN SELECT x FROM jsonb_array_elements(old.items) x WHERE old.kind='invoice' AND x->>'vehicleId' IS NOT NULL
    AND NOT (x->>'vehicleId')::uuid=ANY(linked) LOOP
    PERFORM public.vehicle_release_sale(jsonb_build_object('invoice_id',did,'vehicle_id',entry.x->>'vehicleId'));
  END LOOP;
  FOR entry IN SELECT x,n FROM jsonb_array_elements(normalized) WITH ORDINALITY a(x,n) WHERE x->>'vehicleId' IS NOT NULL LOOP
    IF saved->>'kind'='invoice' THEN
      PERFORM public.vehicle_link_sale(jsonb_build_object('invoice_id',did,'vehicle_id',entry.x->>'vehicleId','line_index',entry.n-1,
        'source',CASE WHEN old.id IS NULL THEN 'sale' ELSE 'backfill' END));
    ELSE
      UPDATE public.billing_documents SET items=jsonb_set(items,ARRAY[(entry.n-1)::text],
        items->((entry.n-1)::int)||jsonb_build_object('vehicleId',entry.x->>'vehicleId','chassisNo',entry.x->>'chassisNo',
        'motorNo',entry.x->>'motorNo','engineNo',entry.x->>'engineNo')) WHERE id=did;
    END IF;
  END LOOP;
  IF EXISTS (SELECT FROM public.vehicles v2 WHERE v2.purchase_invoice_id=did AND v2.customer_id IS DISTINCT FROM (saved->>'customer_id')::uuid
    AND NOT EXISTS (SELECT FROM public.vehicle_ownership o WHERE o.vehicle_id=v2.id AND o.invoice_id=did
      AND o.customer_id=(saved->>'customer_id')::uuid AND o.to_date IS NOT NULL
      AND EXISTS (SELECT FROM public.vehicle_ownership t WHERE t.vehicle_id=v2.id AND t.source='transfer')))
    OR EXISTS (SELECT FROM public.vehicles v2 WHERE v2.purchase_invoice_id=did GROUP BY v2.stock_id
    HAVING count(*) >
      (SELECT coalesce(sum((x->>'qty')::integer),0) FROM jsonb_array_elements(normalized) x WHERE x->>'inventoryId'=v2.stock_id::text))
    THEN RAISE EXCEPTION 'Invoice change conflicts with allocated vehicles'; END IF;
  RETURN (SELECT to_jsonb(b) FROM public.billing_documents b WHERE b.id=did);
END $$;

CREATE OR REPLACE FUNCTION public.vehicle_cancel_invoice(p jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b public.billing_documents; rec record; reason text:=trim(coalesce(p->>'reason',''));
BEGIN
  IF NOT(public.has_permission('invoices.write') AND public.has_permission('service_approve.write')
    AND public.has_permission('vehicles.write')) OR length(reason)<5 THEN RAISE EXCEPTION 'Manager approval and cancellation reason required'; END IF;
  SELECT * INTO STRICT b FROM public.billing_documents WHERE id=(p->>'invoice_id')::uuid AND kind='invoice' AND service_job_id IS NULL FOR UPDATE;
  IF b.cancelled_at IS NOT NULL THEN RETURN; END IF;
  IF b.amount_paid>0 THEN RAISE EXCEPTION 'Resolve payments before cancelling'; END IF;
  FOR rec IN SELECT id FROM public.vehicles WHERE purchase_invoice_id=b.id ORDER BY id LOOP
    PERFORM public.vehicle_release_sale(jsonb_build_object('invoice_id',b.id,'vehicle_id',rec.id));
  END LOOP;
  FOR rec IN SELECT (x->>'inventoryId')::uuid AS id,sum((x->>'qty')::int)::int AS qty
    FROM jsonb_array_elements(b.items) x WHERE x->>'inventoryId' IS NOT NULL GROUP BY 1 ORDER BY 1 LOOP
    PERFORM public.app_move_stock(rec.id,rec.qty,'Cancel '||b.number||': '||reason);
  END LOOP;
  UPDATE public.billing_documents SET cancelled_at=now(),updated_at=clock_timestamp(),items=b.items WHERE id=b.id;
  INSERT INTO public.billing_audit(document_id,actor,before_record,after_record)
    VALUES(b.id,auth.uid(),to_jsonb(b),jsonb_build_object('status','cancelled','reason',reason));
END $$;
REVOKE ALL ON FUNCTION public.vehicle_sale_choices(uuid,text),public.vehicle_link_sale(jsonb),
  public.vehicle_release_sale(jsonb),public.vehicle_cancel_invoice(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vehicle_sale_choices(uuid,text),public.vehicle_link_sale(jsonb),
  public.vehicle_release_sale(jsonb),public.vehicle_cancel_invoice(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.ws_save_delivery(p jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  previous public.delivery_checklist;
  saved public.delivery_checklist;
  vehicle public.vehicles;
  invoice public.billing_documents;
  delivery_id uuid := coalesce(nullif(p->>'id','')::uuid,gen_random_uuid());
  finish boolean := coalesce((p->>'finish')::boolean,false);
  reason text := trim(coalesce(p->>'override_reason',''));
  approved boolean := public.has_permission('service_approve.write') AND length(reason)>=10;
  checklist_key text;
  unlinked_units integer;
  allocated_units integer;
BEGIN
  IF NOT public.has_permission('delivery.write') THEN RAISE EXCEPTION 'Delivery edit permission required'; END IF;
  SELECT * INTO invoice FROM public.billing_documents WHERE id=(p->>'invoice_id')::uuid
    AND kind='invoice' AND cancelled_at IS NULL AND service_job_id IS NULL FOR UPDATE;
  SELECT * INTO previous FROM public.delivery_checklist WHERE id=delivery_id FOR UPDATE;
  IF previous.signed_at IS NOT NULL THEN RAISE EXCEPTION 'Completed delivery is locked'; END IF;
  IF previous.id IS NOT NULL THEN
    IF previous.updated_at IS DISTINCT FROM (p->>'updated_at')::timestamptz THEN
      RAISE EXCEPTION 'Delivery changed; reload'; END IF;
    IF previous.invoice_id IS DISTINCT FROM invoice.id THEN RAISE EXCEPTION 'Delivery invoice is locked'; END IF;
  END IF;
  IF NOT public.has_permission('service.write') AND
    coalesce(previous.assigned_email,p->>'assigned_email',public.ws_email())<>public.ws_email() THEN
    RAISE EXCEPTION 'Only assigned delivery staff may edit'; END IF;
  SELECT * INTO vehicle FROM public.vehicles
    WHERE id=coalesce(previous.vehicle_id,(p->>'vehicle_id')::uuid) FOR UPDATE;
  IF vehicle.stock_id IS NULL OR invoice.id IS NULL OR vehicle.product_id IS NULL THEN
    RAISE EXCEPTION 'Select a stock vehicle and its sales invoice'; END IF;
  IF vehicle.purchase_invoice_id IS NOT NULL AND vehicle.purchase_invoice_id<>invoice.id THEN
    RAISE EXCEPTION 'Chassis is linked to another invoice'; END IF;
  IF EXISTS (SELECT FROM public.vehicle_ownership WHERE vehicle_id=vehicle.id AND source='transfer') THEN
    RAISE EXCEPTION 'Original delivery is locked by an ownership transfer'; END IF;
  -- Legacy invoices may still have model-only lines. Count allocations for this model only.
  IF NOT EXISTS (SELECT FROM jsonb_array_elements(invoice.items) x WHERE x->>'vehicleId'=vehicle.id::text) THEN
    SELECT coalesce(sum((x->>'qty')::int),0) INTO unlinked_units FROM jsonb_array_elements(invoice.items) x
      WHERE x->>'productId'=vehicle.product_id::text AND x->>'inventoryId'=vehicle.stock_id::text
        AND x->>'vehicleId' IS NULL;
    SELECT count(*) INTO allocated_units FROM public.delivery_checklist dc JOIN public.vehicles v ON v.id=dc.vehicle_id
      WHERE dc.invoice_id=invoice.id AND v.id<>vehicle.id AND v.product_id=vehicle.product_id
        AND NOT EXISTS(SELECT FROM jsonb_array_elements(invoice.items) x WHERE x->>'vehicleId'=v.id::text);
    IF allocated_units>=unlinked_units THEN RAISE EXCEPTION 'Invoice has no unallocated stock vehicle of this model'; END IF;
  END IF;
  IF finish THEN
    IF invoice.amount_paid<invoice.total AND NOT approved THEN
      RAISE EXCEPTION 'Settle the invoice or record a manager credit override reason'; END IF;
    IF NOT approved AND NOT EXISTS (SELECT FROM public.pdi_checks WHERE vehicle_id=vehicle.id AND result IN ('passed','issues')) THEN
      RAISE EXCEPTION 'PDI must pass, or manager must record an override reason'; END IF;
    FOREACH checklist_key IN ARRAY ARRAY['invoice_handed','warranty_explained','manual_given','vehicle_demonstrated'] LOOP
      IF NOT coalesce((p->'checklist'->>checklist_key)::boolean,false) THEN RAISE EXCEPTION 'Complete all delivery checks'; END IF;
    END LOOP;
  END IF;
  INSERT INTO public.delivery_checklist(id,vehicle_id,customer_id,invoice_id,assigned_email,checklist,notes,override_reason,signed_at)
    VALUES(delivery_id,vehicle.id,invoice.customer_id,invoice.id,coalesce(p->>'assigned_email',public.ws_email()),
      coalesce(p->'checklist','{}'),coalesce(p->>'notes',''),reason,CASE WHEN finish THEN now() END)
    ON CONFLICT(id) DO UPDATE SET checklist=excluded.checklist,notes=excluded.notes,override_reason=excluded.override_reason,
      signed_at=excluded.signed_at,updated_at=clock_timestamp() RETURNING * INTO saved;
  UPDATE public.vehicles SET customer_id=invoice.customer_id,purchase_invoice_id=invoice.id,purchase_date=invoice.document_date,
    status=CASE WHEN finish THEN 'delivered'::public.vehicle_status ELSE 'sold'::public.vehicle_status END,
    lifecycle=CASE WHEN finish THEN 'delivered' ELSE 'sold' END,updated_at=clock_timestamp() WHERE id=vehicle.id;
  PERFORM public.ws_audit('delivery',delivery_id,invoice.customer_id,vehicle.id,
    CASE WHEN finish THEN 'Vehicle delivered' ELSE 'Delivery prepared' END,to_jsonb(previous),to_jsonb(saved),reason);
  RETURN delivery_id;
END $$;

CREATE OR REPLACE FUNCTION public.vehicle_set_registration(p jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v public.vehicles;
  previous public.vehicle_registrations;
  number text := public.vehicle_number_key(p->>'registration_no');
  registered date := nullif(p->>'registration_date','')::date;
  office text := nullif(trim(p->>'rto'),'');
  reason text := nullif(trim(p->>'reason'),'');
  result uuid;
  other public.vehicles;
BEGIN
  IF NOT public.has_permission('vehicles.write') THEN RAISE EXCEPTION 'Vehicle write permission required'; END IF;
  SELECT * INTO STRICT v FROM public.vehicles WHERE id=(p->>'vehicle_id')::uuid FOR UPDATE;
  IF p ? 'expected_updated_at' AND v.updated_at IS DISTINCT FROM (p->>'expected_updated_at')::timestamptz THEN
    RAISE EXCEPTION 'Vehicle changed. Reload before saving.'; END IF;
  IF number IS NULL OR number !~ '^[A-Z0-9]+$' THEN RAISE EXCEPTION 'Enter a registration number using letters and numbers'; END IF;
  SELECT * INTO previous FROM public.vehicle_registrations WHERE vehicle_id=v.id AND is_current;
  IF previous.id IS NOT NULL THEN
    IF public.vehicle_number_key(previous.registration_no)=number THEN
      IF NOT (p ? 'registration_date') THEN registered:=previous.registration_date; END IF;
      IF NOT (p ? 'rto') THEN office:=previous.rto; END IF;
    END IF;
    IF public.vehicle_number_key(previous.registration_no)=number AND registered IS NOT DISTINCT FROM previous.registration_date
      AND office IS NOT DISTINCT FROM previous.rto THEN RETURN previous.id; END IF;
    IF reason IS NULL AND (public.vehicle_number_key(previous.registration_no) IS DISTINCT FROM number
      OR (previous.registration_date IS NOT NULL AND registered IS DISTINCT FROM previous.registration_date)
      OR (previous.rto IS NOT NULL AND office IS DISTINCT FROM previous.rto)) THEN
      RAISE EXCEPTION 'Enter a reason for changing the registration'; END IF;
    UPDATE public.vehicle_registrations SET is_current=false WHERE id=previous.id;
  END IF;
  BEGIN
    INSERT INTO public.vehicle_registrations(vehicle_id,registration_no,registration_date,rto,notes)
      VALUES(v.id,number,registered,office,reason) RETURNING id INTO result;
  EXCEPTION WHEN unique_violation THEN
    SELECT x.* INTO other FROM public.vehicle_registrations r JOIN public.vehicles x ON x.id=r.vehicle_id
      WHERE r.is_current AND public.vehicle_number_key(r.registration_no)=number;
    RAISE EXCEPTION 'Registration % is already on % (chassis %, status %)',number,other.model_name,other.chassis_no,other.lifecycle;
  END;
  UPDATE public.vehicles SET registration_no=number,updated_at=clock_timestamp() WHERE id=v.id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.vehicle_transfer_owner(p jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v public.vehicles;
  previous public.vehicle_ownership;
  next_customer uuid := (p->>'customer_id')::uuid;
  effective date := (p->>'from_date')::date;
  reason text := nullif(trim(p->>'reason'),'');
  result uuid;
BEGIN
  IF NOT (public.has_permission('vehicles.write') AND public.has_permission('customers.read')
    AND public.has_permission('service_approve.write')) THEN RAISE EXCEPTION 'Manager approval required for transfer'; END IF;
  SELECT * INTO STRICT v FROM public.vehicles WHERE id=(p->>'vehicle_id')::uuid FOR UPDATE;
  IF p ? 'expected_updated_at' AND v.updated_at IS DISTINCT FROM (p->>'expected_updated_at')::timestamptz THEN
    RAISE EXCEPTION 'Vehicle changed. Reload before transferring.'; END IF;
  SELECT * INTO previous FROM public.vehicle_ownership WHERE vehicle_id=v.id AND to_date IS NULL FOR UPDATE;
  IF previous.id IS NULL OR previous.customer_id IS DISTINCT FROM v.customer_id THEN RAISE EXCEPTION 'Current owner required'; END IF;
  IF next_customer=previous.customer_id OR NOT EXISTS (SELECT FROM public.customers WHERE id=next_customer) THEN
    RAISE EXCEPTION 'Select a different existing customer'; END IF;
  IF effective IS NULL OR effective<previous.from_date OR effective>current_date THEN RAISE EXCEPTION 'Enter a valid transfer date'; END IF;
  IF reason IS NULL THEN RAISE EXCEPTION 'Enter a transfer reason'; END IF;
  IF EXISTS (SELECT FROM public.delivery_checklist WHERE vehicle_id=v.id AND signed_at IS NULL) THEN
    RAISE EXCEPTION 'Complete the open delivery before transferring ownership'; END IF;
  UPDATE public.vehicle_ownership SET to_date=effective WHERE id=previous.id;
  INSERT INTO public.vehicle_ownership(vehicle_id,customer_id,from_date,source)
    VALUES(v.id,next_customer,effective,'transfer') RETURNING id INTO result;
  UPDATE public.vehicles SET customer_id=next_customer,updated_at=clock_timestamp() WHERE id=v.id;
  PERFORM public.ws_audit('vehicle_ownership',result,next_customer,v.id,'Ownership transferred',to_jsonb(previous),
    (SELECT to_jsonb(o) FROM public.vehicle_ownership o WHERE id=result),reason);
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.vehicle_set_registration(jsonb),public.vehicle_transfer_owner(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vehicle_set_registration(jsonb),public.vehicle_transfer_owner(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_match(name text, phone text, q text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
  SELECT CASE WHEN q ~ '^[+0-9 ()-]+$' AND length(regexp_replace(q,'[^0-9]','','g'))>=10
    AND right(regexp_replace(q,'[^0-9]','','g'),10)=right(regexp_replace(phone,'[^0-9]','','g'),10) THEN 'mobile'
    WHEN trim(q)<>'' AND strpos(lower(name),lower(trim(q)))>0 THEN 'customer name' END
$$;

-- Apply the selective text and phone predicates before computing a match explanation.
-- Historical components and registrations remain searchable after replacement.
CREATE OR REPLACE FUNCTION public.register_contains_pattern(value text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path='' AS $$
  SELECT '%' || replace(replace(replace(value,'!','!!'),'%','!%'),'_','!_') || '%'
$$;
CREATE INDEX IF NOT EXISTS component_serial_search_idx ON public.vehicle_components
  USING gin(public.vehicle_number_key(serial_no) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS registration_history_search_idx ON public.vehicle_registrations
  USING gin(public.vehicle_number_key(registration_no) gin_trgm_ops);

CREATE OR REPLACE FUNCTION public.register_matches(q text,f jsonb)
RETURNS TABLE(vid uuid,matched_on text) LANGUAGE sql STABLE SET search_path='' AS $$
  SELECT v.id,m.reason FROM public.vehicles v
  LEFT JOIN public.billing_documents b ON b.id=v.purchase_invoice_id AND public.has_permission('invoices.read')
  CROSS JOIN LATERAL (SELECT coalesce(
    CASE WHEN trim(coalesce(q,''))='' THEN 'register' END,
    (SELECT label FROM (VALUES ('chassis',v.chassis_no),('motor',v.motor_no),('engine',v.engine_no),
      ('registration',v.registration_no)) numbers(label,val)
      WHERE strpos(public.vehicle_number_key(val),public.vehicle_number_key(q))>0 LIMIT 1),
    (SELECT component_type FROM public.vehicle_components c WHERE c.vehicle_id=v.id
      AND strpos(public.vehicle_number_key(c.serial_no),public.vehicle_number_key(q))>0 LIMIT 1),
    (SELECT 'registration' FROM public.vehicle_registrations r WHERE r.vehicle_id=v.id
      AND strpos(public.vehicle_number_key(r.registration_no),public.vehicle_number_key(q))>0 LIMIT 1),
    CASE WHEN public.has_permission('customers.read') THEN (SELECT public.customer_match(c.name,c.phone,q)
      FROM public.vehicle_ownership o JOIN public.customers c ON c.id=o.customer_id WHERE o.vehicle_id=v.id
      AND public.customer_match(c.name,c.phone,q) IS NOT NULL LIMIT 1) END,
    CASE WHEN strpos(lower(b.number),lower(trim(q)))>0 THEN 'invoice'
      WHEN strpos(v.search_text,lower(trim(q)))>0 THEN 'vehicle details' END) reason) m
  WHERE (trim(coalesce(q,''))='' OR v.id IN (
    SELECT lookup.id FROM public.vehicles lookup
      WHERE lookup.search_text LIKE public.register_contains_pattern(lower(trim(q))) ESCAPE '!'
         OR lookup.search_text LIKE public.register_contains_pattern(lower(public.vehicle_number_key(q))) ESCAPE '!'
    UNION ALL SELECT c.vehicle_id FROM public.vehicle_components c
      WHERE public.vehicle_number_key(c.serial_no) LIKE public.register_contains_pattern(public.vehicle_number_key(q)) ESCAPE '!'
    UNION ALL SELECT r.vehicle_id FROM public.vehicle_registrations r
      WHERE public.vehicle_number_key(r.registration_no) LIKE public.register_contains_pattern(public.vehicle_number_key(q)) ESCAPE '!'
    UNION ALL SELECT o.vehicle_id FROM public.customers c JOIN public.vehicle_ownership o ON o.customer_id=c.id
      WHERE public.has_permission('customers.read') AND (lower(c.name) LIKE public.register_contains_pattern(lower(trim(q))) ESCAPE '!'
        OR (q ~ '^[+0-9 ()-]+$' AND length(regexp_replace(q,'[^0-9]','','g'))>=10
          AND c.phone_norm=right(regexp_replace(q,'[^0-9]','','g'),10)))
    UNION ALL SELECT sale.id FROM public.billing_documents invoice JOIN public.vehicles sale ON sale.purchase_invoice_id=invoice.id
      WHERE public.has_permission('invoices.read') AND lower(invoice.number) LIKE public.register_contains_pattern(lower(trim(q))) ESCAPE '!'
  )) AND m.reason IS NOT NULL AND (nullif(f->>'vehicle_id','') IS NULL OR v.id::text=f->>'vehicle_id')
    AND (nullif(f->>'customer_id','') IS NULL OR (public.has_permission('customers.read') AND EXISTS
      (SELECT FROM public.vehicle_ownership o WHERE o.vehicle_id=v.id AND o.customer_id::text=f->>'customer_id')))
    AND (nullif(f->>'owner','') IS NULL OR (public.has_permission('customers.read') AND EXISTS
      (SELECT FROM public.customers c WHERE c.id=v.customer_id AND strpos(lower(c.name),lower(f->>'owner'))>0)))
    AND (nullif(f->>'model','') IS NULL OR strpos(lower(v.model_name),lower(f->>'model'))>0)
    AND (nullif(f->>'type','') IS NULL OR v.vehicle_type=f->>'type')
    AND (nullif(f->>'status','') IS NULL OR v.lifecycle=f->>'status')
    AND (NOT coalesce((f->>'unsold')::boolean,false) OR (v.customer_id IS NULL AND v.lifecycle NOT IN ('sold','delivered')))
    AND (NOT coalesce((f->>'pdi')::boolean,false) OR v.lifecycle IN ('pdi_pending','pdi_failed','pdi_issues'))
    AND (NOT coalesce((f->>'sold')::boolean,false) OR v.lifecycle IN ('sold','delivered'))
    AND (NOT coalesce((f->>'unregistered')::boolean,false) OR nullif(v.registration_no,'') IS NULL)
    AND (NOT coalesce((f->>'registered')::boolean,false) OR nullif(v.registration_no,'') IS NOT NULL)
    AND (NOT coalesce((f->>'balance_due')::boolean,false) OR b.total>b.amount_paid)
    AND (NOT(f?'ids') OR CASE f->>'root_dataset'
      WHEN 'sales' THEN public.has_permission('invoices.read') AND (f->'ids') ? b.id::text
      WHEN 'stock' THEN public.has_permission('inventory.read') AND (f->'ids') ? v.stock_id::text
      ELSE true END)
    AND (nullif(f->>'from','') IS NULL OR (CASE WHEN f->>'root_dataset'='sales' THEN b.document_date ELSE v.received_date END)>=(f->>'from')::date)
    AND (nullif(f->>'to','') IS NULL OR (CASE WHEN f->>'root_dataset'='sales' THEN b.document_date ELSE v.received_date END)<=(f->>'to')::date)
$$;
REVOKE ALL ON FUNCTION public.register_matches(text,jsonb) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.db_search(q text,filters jsonb DEFAULT '{}',lim int DEFAULT 40)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE n int:=least(greatest(lim,1),100); result jsonb;
BEGIN
  IF NOT public.has_permission('vehicles.read') THEN RAISE EXCEPTION 'Vehicle read permission required'; END IF;
  WITH matches AS MATERIALIZED (SELECT * FROM public.register_matches(q,filters)),
  vehicles AS (SELECT v.id,v.chassis_no AS title,v.model_name AS detail,m.matched_on FROM matches m
    JOIN public.vehicles v ON v.id=m.vid ORDER BY v.chassis_no LIMIT n),
  customers AS (SELECT c.id,c.name AS title,c.phone AS detail,coalesce(public.customer_match(c.name,c.phone,q),'linked vehicle') AS matched_on
    FROM public.customers c WHERE public.has_permission('customers.read') AND
    ((filters='{}' AND ((trim(q)<>'' AND lower(c.name) LIKE public.register_contains_pattern(lower(trim(q))) ESCAPE '!')
      OR (q ~ '^[+0-9 ()-]+$' AND length(regexp_replace(q,'[^0-9]','','g'))>=10
        AND c.phone_norm=right(regexp_replace(q,'[^0-9]','','g'),10)))) OR EXISTS
      (SELECT FROM public.vehicle_ownership o JOIN matches m ON m.vid=o.vehicle_id WHERE o.customer_id=c.id)) ORDER BY c.name,c.id LIMIT n),
  invoices AS (SELECT b.id,b.number AS title,b.document_date::text AS detail,
    CASE WHEN q<>'' AND strpos(lower(b.number),lower(q))>0 THEN 'invoice' ELSE 'linked record' END AS matched_on
    FROM public.billing_documents b WHERE public.has_permission('invoices.read') AND b.kind='invoice' AND b.cancelled_at IS NULL
    AND ((filters='{}' AND (strpos(lower(b.number),lower(q))>0 OR EXISTS (SELECT FROM customers c WHERE c.id=b.customer_id)))
      OR EXISTS (SELECT FROM matches m JOIN public.vehicles v ON v.id=m.vid WHERE v.purchase_invoice_id=b.id))
    ORDER BY b.document_date DESC,b.id LIMIT n),
  components AS (SELECT c.id,c.vehicle_id,c.serial_no AS title,c.component_type AS detail,
    CASE WHEN strpos(public.vehicle_number_key(c.serial_no),public.vehicle_number_key(q))>0 THEN c.component_type ELSE 'linked vehicle' END AS matched_on
    FROM matches m JOIN public.vehicle_components c ON c.vehicle_id=m.vid ORDER BY
      (strpos(public.vehicle_number_key(c.serial_no),public.vehicle_number_key(q))>0) DESC,c.serial_no LIMIT n)
  SELECT jsonb_build_object('vehicles',coalesce((SELECT jsonb_agg(vehicles) FROM vehicles),'[]'),
    'customers',coalesce((SELECT jsonb_agg(customers) FROM customers),'[]'),
    'invoices',coalesce((SELECT jsonb_agg(invoices) FROM invoices),'[]'),
    'components',coalesce((SELECT jsonb_agg(components) FROM components),'[]')) INTO result;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.customer_360(customer_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE cid uuid:=customer_id; result jsonb;
BEGIN
  IF NOT(public.has_permission('vehicles.read') AND public.has_permission('customers.read')) THEN RAISE EXCEPTION 'Customer and vehicle access required'; END IF;
  SELECT jsonb_build_object('name',c.name,'mobile',c.phone,'village',c.village,'address',c.address,
    'vehicles',coalesce((SELECT jsonb_agg(public.vehicle_360(v.id)) FROM public.vehicles v WHERE EXISTS
      (SELECT FROM public.vehicle_ownership o WHERE o.vehicle_id=v.id AND o.customer_id=cid)),'[]'),
    'invoices',CASE WHEN public.has_permission('invoices.read') THEN coalesce((SELECT jsonb_agg(jsonb_build_object(
      'id',b.id,'number',b.number,'date',b.document_date,'total',b.total,'balance',b.total-b.amount_paid))
      FROM public.billing_documents b WHERE b.customer_id=cid AND b.kind='invoice' AND b.cancelled_at IS NULL),'[]') END,
    'jobs',coalesce((SELECT jsonb_agg(jsonb_build_object('number',j.number,'status',j.status,'date',j.received_at))
      FROM public.service_jobs j WHERE j.customer_id=cid AND public.has_permission('service.read') AND public.ws_job_access(j.id)),'[]'))
    INTO result FROM public.customers c WHERE c.id=cid;
  IF result IS NULL THEN RAISE EXCEPTION 'Customer not found'; END IF;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.db_search(text,jsonb,int),public.customer_360(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.db_search(text,jsonb,int),public.customer_360(uuid) TO authenticated;
CREATE TABLE IF NOT EXISTS public.export_templates(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 100),
  dataset text NOT NULL CHECK(dataset IN ('vehicles','customers','sales','components','registrations','ownership','stock','full_register')),
  columns jsonb NOT NULL CHECK(jsonb_typeof(columns)='array'),filters jsonb NOT NULL DEFAULT '{}',
  sheet_layout text NOT NULL CHECK(sheet_layout IN ('single','multi')), sheets jsonb NOT NULL DEFAULT '{}',
  owner uuid NOT NULL REFERENCES auth.users,shared boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.export_log(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),actor uuid NOT NULL REFERENCES auth.users,
  dataset text NOT NULL,template_id uuid REFERENCES public.export_templates ON DELETE SET NULL,filters jsonb NOT NULL,
  row_count integer NOT NULL CHECK(row_count>=0),created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.export_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.export_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.export_templates,public.export_log FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.export_templates,public.export_log TO authenticated;
DROP POLICY IF EXISTS template_read ON public.export_templates;
CREATE POLICY template_read ON public.export_templates FOR SELECT TO authenticated USING
  (public.has_permission('vehicles.export') AND (owner=auth.uid() OR shared OR public.access_role()='owner'));
DROP POLICY IF EXISTS export_admin ON public.export_log;
CREATE POLICY export_admin ON public.export_log FOR SELECT TO authenticated USING(public.access_role()='owner');

CREATE OR REPLACE FUNCTION public.export_template_save(p jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE old public.export_templates; saved public.export_templates;
BEGIN
  IF NOT public.has_permission('vehicles.export') THEN RAISE EXCEPTION 'Export permission required'; END IF;
  IF jsonb_typeof(p->'columns') IS DISTINCT FROM 'array' OR jsonb_typeof(coalesce(p->'filters','{}'))<>'object'
    OR jsonb_typeof(coalesce(p->'sheets','{}'))<>'object' THEN RAISE EXCEPTION 'Invalid template layout'; END IF;
  IF EXISTS (SELECT FROM jsonb_each(coalesce(p->'sheets','{}')) WHERE jsonb_typeof(value)<>'array'
    OR key NOT IN ('vehicles','full_register','components','registrations','ownership','sales','customers','stock'))
    THEN RAISE EXCEPTION 'Invalid template sheet'; END IF;
  IF EXISTS (SELECT FROM (SELECT p->'columns' AS cols UNION ALL SELECT value FROM jsonb_each(p->'sheets')) lists
    WHERE jsonb_array_length(cols) NOT BETWEEN 1 AND 100 OR EXISTS (SELECT FROM jsonb_array_elements(cols) col
      WHERE jsonb_typeof(col->'key') IS DISTINCT FROM 'string' OR jsonb_typeof(col->'header') IS DISTINCT FROM 'string'))
    THEN RAISE EXCEPTION 'Choose columns with text headers'; END IF;
  IF nullif(p->>'id','') IS NOT NULL THEN
    SELECT * INTO STRICT old FROM public.export_templates WHERE id=(p->>'id')::uuid FOR UPDATE;
    IF old.owner<>auth.uid() AND public.access_role()<>'owner' THEN RAISE EXCEPTION 'Template owner required'; END IF;
  END IF;
  INSERT INTO public.export_templates(id,name,dataset,columns,filters,sheet_layout,sheets,owner,shared)
    VALUES(coalesce(old.id,gen_random_uuid()),trim(p->>'name'),p->>'dataset',p->'columns',coalesce(p->'filters','{}'),
      p->>'sheet_layout',coalesce(p->'sheets','{}'),coalesce(old.owner,auth.uid()),coalesce((p->>'shared')::boolean,false))
    ON CONFLICT(id) DO UPDATE SET name=excluded.name,dataset=excluded.dataset,columns=excluded.columns,filters=excluded.filters,
      sheet_layout=excluded.sheet_layout,sheets=excluded.sheets,shared=excluded.shared,updated_at=clock_timestamp() RETURNING * INTO saved;
  INSERT INTO public.access_audit(actor,action,target,details) VALUES(auth.uid(),'save_export_template',saved.id::text,
    jsonb_build_object('before',to_jsonb(old),'after',to_jsonb(saved)));
  RETURN saved.id;
END $$;
CREATE OR REPLACE FUNCTION public.export_template_delete(id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE old public.export_templates;
BEGIN
  IF NOT public.has_permission('vehicles.export') THEN RAISE EXCEPTION 'Export permission required'; END IF;
  DELETE FROM public.export_templates t WHERE t.id=$1 AND (t.owner=auth.uid() OR public.access_role()='owner') RETURNING * INTO STRICT old;
  INSERT INTO public.access_audit(actor,action,target,details) VALUES(auth.uid(),'delete_export_template',old.id::text,jsonb_build_object('before',to_jsonb(old)));
END $$;

CREATE OR REPLACE FUNCTION public.export_source(ds text,f jsonb) RETURNS SETOF jsonb LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE term text:=coalesce(f->>'q',''); scoped boolean:=(f-ARRAY['q','root_dataset','from','to','balance_due','ids','template_id']) <> '{}';
  matched_ids jsonb;
BEGIN
  IF f->>'database_results'='true' THEN
    SELECT coalesce(jsonb_agg(hit->'id'),'[]') INTO matched_ids
    FROM jsonb_array_elements(public.db_search(term,f-ARRAY['database_results','q','root_dataset','linked_only','template_id'],50)
      -> (CASE ds WHEN 'components' THEN 'components' WHEN 'customers' THEN 'customers' WHEN 'sales' THEN 'invoices' ELSE 'vehicles' END)) hit;
    f:='{}'; term:=''; scoped:=false;
  END IF;
  IF ds='stock' THEN
    IF NOT public.has_permission('inventory.read') THEN RAISE EXCEPTION 'Inventory read permission required'; END IF;
    RETURN QUERY SELECT jsonb_build_object('model',i.item_name,'sku',i.sku_or_code,'quantity',i.qty_available,'reserved',i.qty_reserved)
      FROM public.inventory i WHERE strpos(lower(concat_ws(' ',i.item_name,i.sku_or_code)),lower(term))>0
      AND (NOT(f?'ids') OR f->>'root_dataset'='sales' OR (f->'ids') ? i.id::text)
      AND (matched_ids IS NULL OR EXISTS (SELECT FROM public.vehicles v WHERE v.stock_id=i.id AND matched_ids ? v.id::text))
      AND (NOT scoped OR EXISTS (SELECT FROM public.register_matches(term,f) m JOIN public.vehicles v ON v.id=m.vid WHERE v.stock_id=i.id))
      ORDER BY i.item_name,i.id;
  ELSIF ds='customers' THEN
    IF NOT public.has_permission('customers.read') THEN RAISE EXCEPTION 'Customer read permission required'; END IF;
    RETURN QUERY SELECT jsonb_build_object('owner',c.name,'mobile',c.phone,'alt_mobile',c.alt_phone,'village',c.village,
      'tehsil',c.tehsil,'district',c.district,'address',c.address,'gstin',c.gstin) FROM public.customers c
      WHERE (matched_ids IS NULL OR matched_ids ? c.id::text) AND (nullif(f->>'customer_id','') IS NULL OR c.id::text=f->>'customer_id') AND
      ((NOT scoped AND NOT(f ?| ARRAY['from','to','balance_due','ids']) AND (term='' OR public.customer_match(c.name,c.phone,term) IS NOT NULL)) OR EXISTS
        (SELECT FROM public.register_matches(term,f) m JOIN public.vehicle_ownership o ON o.vehicle_id=m.vid WHERE o.customer_id=c.id))
      ORDER BY c.name,c.id;
  ELSIF ds='sales' THEN
    IF NOT public.has_permission('invoices.read') THEN RAISE EXCEPTION 'Invoice read permission required'; END IF;
    RETURN QUERY SELECT jsonb_build_object('invoice',b.number,'invoice_date',b.document_date,'amount',b.total,'paid',b.amount_paid,
      'balance',b.total-b.amount_paid,'owner',c.name,'mobile',c.phone,'payment_mode',pay.methods,'payments',pay.details)
      FROM public.billing_documents b LEFT JOIN public.customers c ON c.id=b.customer_id AND public.has_permission('customers.read')
      LEFT JOIN LATERAL (SELECT string_agg(DISTINCT p.method::text,', ') methods,string_agg(concat_ws(' ',p.paid_at::date,p.amount,p.method),' | ' ORDER BY p.paid_at) details
        FROM public.billing_payments p WHERE p.invoice_id=b.id) pay ON true
      WHERE b.kind='invoice' AND b.cancelled_at IS NULL AND (matched_ids IS NULL OR matched_ids ? b.id::text) AND (NOT(f?'ids') OR (f->'ids') ? b.id::text)
      AND (f->>'linked_only'='true' OR nullif(f->>'from','') IS NULL OR b.document_date>=(f->>'from')::date)
      AND (f->>'linked_only'='true' OR nullif(f->>'to','') IS NULL OR b.document_date<=(f->>'to')::date)
      AND (NOT coalesce((f->>'balance_due')::boolean,false) OR b.total>b.amount_paid)
      AND ((NOT scoped AND (term='' OR strpos(lower(b.number),lower(term))>0 OR public.customer_match(c.name,c.phone,term) IS NOT NULL))
        OR (public.has_permission('customers.read') AND f-ARRAY['customer_id','root_dataset','template_id']='{}' AND b.customer_id::text=f->>'customer_id')
        OR EXISTS (SELECT FROM public.register_matches(term,CASE WHEN f->>'linked_only'='true' THEN f ELSE f-ARRAY['from','to'] END) m JOIN public.vehicles v ON v.id=m.vid WHERE v.purchase_invoice_id=b.id))
      ORDER BY b.document_date,b.number;
  ELSE
    RETURN QUERY SELECT to_jsonb(row_data) FROM (
      SELECT v.chassis_no AS chassis,v.motor_no AS motor,v.engine_no AS engine,v.vehicle_type AS type,v.model_name AS model,
        v.variant,v.colour,v.lifecycle AS status,v.location,v.received_date,v.supplier,v.supplier_invoice,v.shipment_ref,
        CASE WHEN ds='registrations' THEN hist.registration_no ELSE v.registration_no END AS registration,
        CASE WHEN ds='registrations' THEN hist.registration_date ELSE reg.registration_date END AS registration_date,
        CASE WHEN ds='registrations' THEN hist.rto ELSE reg.rto END AS rto,hist.is_current,
        part.component_type,part.serial_no AS serial,part.installed_on,part.removed_on,part.removal_reason,
        c.name AS owner,c.phone AS mobile,c.alt_phone AS alt_mobile,c.address,c.village,c.tehsil,c.district,c.gstin,
        o.from_date,o.to_date,o.source,b.number AS invoice,b.document_date AS invoice_date,b.total AS amount,b.amount_paid AS paid,
        b.total-b.amount_paid AS balance,(SELECT string_agg(DISTINCT method::text,', ') FROM public.billing_payments WHERE invoice_id=b.id) AS payment_mode,
        parts.batteries,parts.chargers,parts.controllers,
        (SELECT string_agg(concat_ws(' ',h.name,ow.from_date,ow.to_date),' | ' ORDER BY ow.from_date)
          FROM public.vehicle_ownership ow JOIN public.customers h ON h.id=ow.customer_id WHERE public.has_permission('customers.read') AND ow.vehicle_id=v.id) AS ownership_history,
        d.signed_at::date AS delivery_date,d.assigned_email AS delivered_by,
        (SELECT result FROM public.pdi_checks p WHERE p.vehicle_id=v.id AND public.has_permission('pdi.read')
          AND (public.access_role()<>'pdi' OR p.inspector_email=public.ws_email()) ORDER BY p.created_at DESC LIMIT 1) AS pdi_result,
        (SELECT string_agg(w.end_date::text,', ' ORDER BY w.end_date) FROM public.warranties w WHERE w.vehicle_id=v.id AND public.has_permission('warranty.read')) AS warranty_ends,
        jobs.service_count,jobs.last_service
      FROM public.register_matches(term,f) m JOIN public.vehicles v ON v.id=m.vid
      LEFT JOIN public.vehicle_components part ON ds='components' AND part.vehicle_id=v.id
      LEFT JOIN public.vehicle_registrations hist ON ds='registrations' AND hist.vehicle_id=v.id
      LEFT JOIN public.vehicle_registrations reg ON reg.vehicle_id=v.id AND reg.is_current
      LEFT JOIN public.vehicle_ownership o ON ds='ownership' AND o.vehicle_id=v.id
      LEFT JOIN public.customers c ON c.id=coalesce(o.customer_id,v.customer_id) AND public.has_permission('customers.read')
      LEFT JOIN public.billing_documents b ON b.id=v.purchase_invoice_id AND public.has_permission('invoices.read')
      LEFT JOIN public.delivery_checklist d ON d.vehicle_id=v.id AND public.has_permission('delivery.read')
        AND (public.has_permission('service.write') OR d.assigned_email=public.ws_email())
      LEFT JOIN LATERAL (SELECT string_agg(serial_no,', ' ORDER BY created_at) FILTER(WHERE component_type='battery') batteries,
        string_agg(serial_no,', ' ORDER BY created_at) FILTER(WHERE component_type='charger') chargers,
        string_agg(serial_no,', ' ORDER BY created_at) FILTER(WHERE component_type='controller') controllers
        FROM public.vehicle_components WHERE vehicle_id=v.id AND removed_on IS NULL) parts ON true
      LEFT JOIN LATERAL (SELECT count(*) service_count,max(received_at) last_service FROM public.service_jobs j
        WHERE public.has_permission('service.read') AND j.vehicle_id=v.id AND public.ws_job_access(j.id)) jobs ON true
      WHERE (matched_ids IS NULL OR matched_ids ? (CASE WHEN ds='components' THEN part.id ELSE v.id END)::text)
        AND (ds<>'components' OR part.id IS NOT NULL) AND (ds<>'registrations' OR hist.id IS NOT NULL)
        AND (ds<>'ownership' OR (public.has_permission('customers.read') AND o.id IS NOT NULL))
      ORDER BY v.chassis_no,part.created_at,hist.created_at,o.from_date
    ) row_data;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.export_collect(ds text,cols text[],f jsonb,lim int,preview boolean) RETURNS jsonb
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE allowed text[]; dropped text[]; records jsonb; logged public.export_log;
  cap int:=least(greatest(coalesce(lim,50000),1),50000);
BEGIN
  IF NOT(public.has_permission('vehicles.export') AND public.has_permission('vehicles.read')) THEN RAISE EXCEPTION 'Vehicle export permission required'; END IF;
  IF ds IS NULL OR ds NOT IN ('vehicles','full_register','customers','sales','components','registrations','ownership','stock') THEN RAISE EXCEPTION 'Unknown dataset'; END IF;
  IF ds='ownership' AND NOT public.has_permission('customers.read') THEN RAISE EXCEPTION 'Customer read permission required'; END IF;
  SELECT array_agg(k ORDER BY n) FILTER(WHERE ok),array_agg(k ORDER BY n) FILTER(WHERE NOT ok) INTO allowed,dropped
    FROM unnest(cols) WITH ORDINALITY t(k,n) CROSS JOIN LATERAL (SELECT CASE
      WHEN k=ANY(string_to_array('owner mobile alt_mobile village tehsil district address gstin ownership_history from_date to_date source',' ')) THEN public.has_permission('customers.read')
      WHEN k=ANY(string_to_array('invoice invoice_date amount paid balance payment_mode payments',' ')) THEN public.has_permission('invoices.read')
      WHEN k IN ('delivery_date','delivered_by') THEN public.has_permission('delivery.read')
      WHEN k='pdi_result' THEN public.has_permission('pdi.read')
      WHEN k='warranty_ends' THEN public.has_permission('warranty.read')
      WHEN k IN ('last_service','service_count') THEN public.has_permission('service.read')
      ELSE k=ANY(string_to_array('model sku quantity reserved chassis motor engine type variant colour status location received_date supplier supplier_invoice shipment_ref registration registration_date rto is_current component_type serial installed_on removed_on removal_reason batteries chargers controllers',' ')) END ok) access;
  SELECT coalesce(jsonb_agg(coalesce((SELECT jsonb_object_agg(key,value) FROM jsonb_each(x) WHERE key=ANY(allowed)),'{}')),'[]') INTO records
    FROM (SELECT x FROM public.export_source(ds,f) x LIMIT CASE WHEN preview THEN least(cap,20) ELSE cap+1 END) limited;
  IF jsonb_array_length(records)>cap THEN RAISE EXCEPTION 'Export exceeds % rows. Narrow the filters.',cap; END IF;
  IF NOT preview THEN
    INSERT INTO public.export_log(actor,dataset,template_id,filters,row_count) VALUES(auth.uid(),ds,nullif(f->>'template_id','')::uuid,f,jsonb_array_length(records)) RETURNING * INTO logged;
    INSERT INTO public.access_audit(actor,action,target,details) VALUES(auth.uid(),'export_dataset',ds,to_jsonb(logged));
  END IF;
  RETURN jsonb_build_object('columns',coalesce(allowed,'{}'),'dropped',coalesce(dropped,'{}'),'rows',records);
END $$;
CREATE OR REPLACE FUNCTION public.export_dataset(dataset text,columns text[],filters jsonb,lim int DEFAULT 50000) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT public.export_collect(dataset,columns,filters,lim,false) $$;
CREATE OR REPLACE FUNCTION public.export_preview(dataset text,columns text[],filters jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT public.export_collect(dataset,columns,filters,20,true) $$;
REVOKE ALL ON FUNCTION public.export_source(text,jsonb),public.export_collect(text,text[],jsonb,int,boolean) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.export_dataset(text,text[],jsonb,int),public.export_preview(text,text[],jsonb),public.export_template_save(jsonb),public.export_template_delete(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.export_dataset(text,text[],jsonb,int),public.export_preview(text,text[],jsonb),public.export_template_save(jsonb),public.export_template_delete(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.db_search_export(q text,filters jsonb,lim int) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb; logged public.export_log;
BEGIN
 IF NOT public.has_permission('vehicles.export') THEN RAISE EXCEPTION 'Export permission required'; END IF;
 result:=public.db_search(q,filters,lim);
 INSERT INTO public.export_log(actor,dataset,filters,row_count) SELECT auth.uid(),'database_csv',filters||jsonb_build_object('q',q),
   sum(jsonb_array_length(value)) FROM jsonb_each(result) RETURNING * INTO logged;
 INSERT INTO public.access_audit(actor,action,target,details) VALUES(auth.uid(),'export_dataset','database_csv',to_jsonb(logged));
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.db_search_export(text,jsonb,int) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.db_search_export(text,jsonb,int) TO authenticated;
-- Read all selected sheets under a single RPC transaction. If a sheet exceeds the
-- workbook cap, its siblings and their audit entries roll back together.
CREATE OR REPLACE FUNCTION public.export_workbook(dataset text,sheets jsonb,filters jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE sheet record; report jsonb; result jsonb:='{}'; remaining int:=50000; scope jsonb;
BEGIN
 IF NOT public.has_permission('vehicles.export') THEN RAISE EXCEPTION 'Export permission required'; END IF;
 IF jsonb_typeof(sheets) IS DISTINCT FROM 'object' OR sheets='{}' THEN RAISE EXCEPTION 'Choose at least one sheet'; END IF;
 FOR sheet IN SELECT key,value FROM jsonb_each(sheets) LOOP
   scope:=filters||jsonb_build_object('root_dataset',dataset);
   IF sheet.key<>dataset AND dataset NOT IN ('customers','sales','stock') THEN
     scope:=scope||'{"linked_only":true}'::jsonb;
   END IF;
   report:=public.export_collect(sheet.key,ARRAY(SELECT jsonb_array_elements_text(sheet.value)),scope,remaining,false);
   remaining:=remaining-jsonb_array_length(report->'rows');
   IF remaining<0 THEN RAISE EXCEPTION 'Workbook exceeds 50,000 rows. Narrow the filters.'; END IF;
   IF jsonb_array_length(report->'columns')=0 THEN RAISE EXCEPTION 'No permitted columns for %',sheet.key; END IF;
   result:=result||jsonb_build_object(sheet.key,report);
 END LOOP;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.export_workbook(text,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.export_workbook(text,jsonb,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
