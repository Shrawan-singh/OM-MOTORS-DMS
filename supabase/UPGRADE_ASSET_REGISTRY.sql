-- Run once AFTER UPGRADE_WORKSHOP.sql. Preserves existing records.
-- Adds Customer Asset Registry: links specific serial-numbered items to customers
-- with full audit trail for warranty tracking and replacements.
BEGIN;

-- ============================================================================
-- 1. customer_assets — The master ownership registry
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.customer_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.customers(id),
  billing_invoice_id uuid REFERENCES public.billing_documents(id),
  vehicle_id uuid REFERENCES public.vehicles(id),
  warranty_id uuid REFERENCES public.warranties(id),

  -- What was sold
  item_type public.item_type NOT NULL,
  product_id uuid REFERENCES public.catalog_products(id),
  product_name text NOT NULL,
  brand text NOT NULL DEFAULT '',

  -- Serial / identification numbers
  chassis_no text NOT NULL DEFAULT '',
  engine_no text NOT NULL DEFAULT '',
  motor_no text NOT NULL DEFAULT '',
  battery_serial text NOT NULL DEFAULT '',
  serial_no text NOT NULL DEFAULT '',  -- generic serial for parts/implements
  registration_no text NOT NULL DEFAULT '',

  -- Warranty coverage
  warranty_months int NOT NULL DEFAULT 0,
  warranty_start date,
  warranty_end date,

  -- Status
  status text NOT NULL DEFAULT 'active' CHECK(status IN ('active','replaced','transferred','returned')),
  replaced_by uuid REFERENCES public.customer_assets(id),  -- points to new asset if replaced
  replaces uuid REFERENCES public.customer_assets(id),      -- points to old asset this replaced

  -- Metadata
  notes text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_customer_assets_customer ON public.customer_assets(customer_id);
CREATE INDEX IF NOT EXISTS idx_customer_assets_invoice ON public.customer_assets(billing_invoice_id);
CREATE INDEX IF NOT EXISTS idx_customer_assets_chassis ON public.customer_assets(lower(chassis_no)) WHERE chassis_no <> '';
CREATE INDEX IF NOT EXISTS idx_customer_assets_battery ON public.customer_assets(lower(battery_serial)) WHERE battery_serial <> '';
CREATE INDEX IF NOT EXISTS idx_customer_assets_serial ON public.customer_assets(lower(serial_no)) WHERE serial_no <> '';

-- ============================================================================
-- 2. customer_asset_history — Full audit trail for every change
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.customer_asset_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  asset_id uuid NOT NULL REFERENCES public.customer_assets(id) ON DELETE CASCADE,
  action text NOT NULL,  -- 'registered', 'warranty_replacement', 'transferred', 'corrected', 'status_changed'
  actor uuid REFERENCES auth.users(id),
  before_record jsonb,
  after_record jsonb,
  reason text NOT NULL DEFAULT '',
  claim_id uuid REFERENCES public.warranty_claims(id),  -- link to warranty claim if replacement
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_asset_history_asset ON public.customer_asset_history(asset_id);

-- ============================================================================
-- 3. Add serials JSON column to billing_documents items
-- ============================================================================
-- The serials are stored per-line inside the items JSONB array.
-- Each line item can optionally have a "serials" object:
-- { "chassisNo": "...", "engineNo": "...", "batterySerial": "...", "serialNo": "...", "motorNo": "...", "registrationNo": "..." }
-- No schema change needed — the items JSONB array is flexible.

-- ============================================================================
-- 4. RPC: Register assets from an invoice
-- ============================================================================
CREATE OR REPLACE FUNCTION public.app_register_invoice_assets(
  p_invoice_id uuid,
  p_assets jsonb  -- array of { lineIndex, chassisNo, engineNo, batterySerial, serialNo, motorNo, registrationNo, warrantyMonths }
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable
DECLARE
  doc public.billing_documents;
  asset_input jsonb;
  line jsonb;
  line_idx int;
  asset_id uuid;
  prod public.catalog_products;
  result jsonb := '[]';
  updated_items jsonb;
  warranty_start date;
  warranty_end_date date;
  new_warranty_id uuid;
BEGIN
  IF NOT public.has_permission('invoices.write') THEN
    RAISE EXCEPTION 'Invoice edit permission required';
  END IF;

  SELECT * INTO doc FROM public.billing_documents WHERE id = p_invoice_id AND kind = 'invoice' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice not found'; END IF;
  IF doc.cancelled_at IS NOT NULL THEN RAISE EXCEPTION 'Invoice is cancelled'; END IF;

  IF jsonb_typeof(p_assets) <> 'array' THEN RAISE EXCEPTION 'Assets must be an array'; END IF;

  updated_items := doc.items;

  FOR asset_input IN SELECT value FROM jsonb_array_elements(p_assets) LOOP
    line_idx := (asset_input->>'lineIndex')::int;
    IF line_idx < 0 OR line_idx >= jsonb_array_length(doc.items) THEN
      RAISE EXCEPTION 'Invalid line index %', line_idx;
    END IF;

    line := doc.items->line_idx;
    asset_id := gen_random_uuid();
    warranty_start := doc.document_date;
    warranty_end_date := CASE
      WHEN coalesce((asset_input->>'warrantyMonths')::int, 0) > 0
      THEN doc.document_date + ((asset_input->>'warrantyMonths')::int || ' months')::interval
      ELSE NULL
    END;

    -- Lookup product if available
    IF line->>'productId' IS NOT NULL THEN
      SELECT * INTO prod FROM public.catalog_products WHERE id = (line->>'productId')::uuid;
    ELSE
      prod := NULL;
    END IF;

    -- Create the customer asset
    INSERT INTO public.customer_assets (
      id, customer_id, billing_invoice_id, item_type,
      product_id, product_name, brand,
      chassis_no, engine_no, motor_no, battery_serial, serial_no, registration_no,
      warranty_months, warranty_start, warranty_end, notes
    ) VALUES (
      asset_id, doc.customer_id, doc.id,
      coalesce(prod.category, 'part')::public.item_type,
      (line->>'productId')::uuid,
      line->>'name',
      coalesce(prod.brand, ''),
      coalesce(asset_input->>'chassisNo', ''),
      coalesce(asset_input->>'engineNo', ''),
      coalesce(asset_input->>'motorNo', ''),
      coalesce(asset_input->>'batterySerial', ''),
      coalesce(asset_input->>'serialNo', ''),
      coalesce(asset_input->>'registrationNo', ''),
      coalesce((asset_input->>'warrantyMonths')::int, 0),
      warranty_start,
      warranty_end_date,
      coalesce(asset_input->>'notes', '')
    );

    -- Create warranty record if warranty months > 0
    IF warranty_end_date IS NOT NULL THEN
      new_warranty_id := gen_random_uuid();

      -- Determine the best serial for warranty
      INSERT INTO public.warranties (
        id, item_type, item_id, serial_no,
        customer_id, invoice_no,
        start_date, end_date,
        billing_invoice_id, product_id,
        product_name, brand, coverage_evidence
      ) VALUES (
        new_warranty_id,
        coalesce(prod.category, 'part')::public.item_type,
        coalesce((line->>'productId')::uuid, asset_id),
        upper(trim(coalesce(
          nullif(asset_input->>'chassisNo', ''),
          nullif(asset_input->>'batterySerial', ''),
          nullif(asset_input->>'serialNo', ''),
          nullif(asset_input->>'engineNo', ''),
          'ASSET-' || asset_id::text
        ))),
        doc.customer_id,
        doc.number,
        warranty_start,
        warranty_end_date,
        doc.id,
        (line->>'productId')::uuid,
        line->>'name',
        coalesce(prod.brand, ''),
        'Auto-registered from invoice ' || doc.number || ' on ' || warranty_start::text
      ) ON CONFLICT ON CONSTRAINT warranty_serial_unique DO NOTHING;

      -- Link warranty to asset
      UPDATE public.customer_assets SET warranty_id = new_warranty_id WHERE customer_assets.id = asset_id;
    END IF;

    -- Record audit entry
    INSERT INTO public.customer_asset_history (asset_id, action, actor, after_record, reason)
    VALUES (asset_id, 'registered', auth.uid(), to_jsonb((SELECT a FROM public.customer_assets a WHERE a.id = asset_id)),
            'Registered from invoice ' || doc.number);

    -- Update the line item with serial info
    updated_items := jsonb_set(
      updated_items,
      ARRAY[line_idx::text],
      line || jsonb_build_object('serials', jsonb_build_object(
        'chassisNo', coalesce(asset_input->>'chassisNo', ''),
        'engineNo', coalesce(asset_input->>'engineNo', ''),
        'motorNo', coalesce(asset_input->>'motorNo', ''),
        'batterySerial', coalesce(asset_input->>'batterySerial', ''),
        'serialNo', coalesce(asset_input->>'serialNo', ''),
        'registrationNo', coalesce(asset_input->>'registrationNo', ''),
        'assetId', asset_id::text,
        'warrantyId', coalesce(new_warranty_id::text, '')
      ))
    );

    -- Add to customer timeline
    INSERT INTO public.customer_timeline (customer_id, event_type, description, reference_id)
    VALUES (doc.customer_id, 'asset_registered',
            'Asset registered: ' || (line->>'name') || coalesce(' · Chassis: ' || nullif(asset_input->>'chassisNo', ''), '') || coalesce(' · Serial: ' || nullif(asset_input->>'batterySerial', nullif(asset_input->>'serialNo', '')), '') || ' from invoice ' || doc.number,
            asset_id::text);

    result := result || jsonb_build_array(jsonb_build_object('assetId', asset_id, 'warrantyId', new_warranty_id, 'lineIndex', line_idx));
    new_warranty_id := NULL;
  END LOOP;

  -- Save the updated items with serials back to the document
  UPDATE public.billing_documents SET items = updated_items, updated_at = clock_timestamp() WHERE id = doc.id;

  RETURN jsonb_build_object('success', true, 'assets', result);
END;
$$;

-- ============================================================================
-- 5. RPC: Record a warranty replacement in the asset registry
-- ============================================================================
CREATE OR REPLACE FUNCTION public.app_asset_warranty_replace(
  p_old_asset_id uuid,
  p_claim_id uuid,
  p_new_serial jsonb  -- { chassisNo, engineNo, batterySerial, serialNo, motorNo, registrationNo, warrantyMonths, notes }
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable
DECLARE
  old_asset public.customer_assets;
  new_asset_id uuid := gen_random_uuid();
  claim public.warranty_claims;
  warranty_end_date date;
BEGIN
  IF NOT public.has_permission('warranty.write') THEN
    RAISE EXCEPTION 'Warranty write permission required';
  END IF;

  SELECT * INTO old_asset FROM public.customer_assets WHERE customer_assets.id = p_old_asset_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Asset not found'; END IF;

  SELECT * INTO claim FROM public.warranty_claims WHERE warranty_claims.id = p_claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Warranty claim not found'; END IF;

  warranty_end_date := CASE
    WHEN coalesce((p_new_serial->>'warrantyMonths')::int, 0) > 0
    THEN current_date + ((p_new_serial->>'warrantyMonths')::int || ' months')::interval
    ELSE old_asset.warranty_end  -- inherit remaining warranty
  END;

  -- Create new asset for the replacement
  INSERT INTO public.customer_assets (
    id, customer_id, billing_invoice_id, item_type,
    product_id, product_name, brand,
    chassis_no, engine_no, motor_no, battery_serial, serial_no, registration_no,
    warranty_months, warranty_start, warranty_end,
    replaces, notes
  ) VALUES (
    new_asset_id, old_asset.customer_id, old_asset.billing_invoice_id, old_asset.item_type,
    coalesce(claim.replacement_product_id, old_asset.product_id),
    old_asset.product_name, old_asset.brand,
    coalesce(p_new_serial->>'chassisNo', ''),
    coalesce(p_new_serial->>'engineNo', ''),
    coalesce(p_new_serial->>'motorNo', ''),
    coalesce(p_new_serial->>'batterySerial', ''),
    coalesce(p_new_serial->>'serialNo', ''),
    coalesce(p_new_serial->>'registrationNo', ''),
    coalesce((p_new_serial->>'warrantyMonths')::int, old_asset.warranty_months),
    current_date, warranty_end_date,
    old_asset.id,
    coalesce(p_new_serial->>'notes', 'Warranty replacement for claim ' || coalesce(claim.number, claim.id::text))
  );

  -- Mark old asset as replaced
  UPDATE public.customer_assets
  SET status = 'replaced', replaced_by = new_asset_id, updated_at = clock_timestamp()
  WHERE customer_assets.id = old_asset.id;

  -- Audit old asset
  INSERT INTO public.customer_asset_history (asset_id, action, actor, before_record, after_record, reason, claim_id)
  VALUES (old_asset.id, 'warranty_replacement', auth.uid(),
          to_jsonb(old_asset),
          (SELECT to_jsonb(a) FROM public.customer_assets a WHERE a.id = old_asset.id),
          'Replaced under warranty claim ' || coalesce(claim.number, claim.id::text),
          claim.id);

  -- Audit new asset
  INSERT INTO public.customer_asset_history (asset_id, action, actor, after_record, reason, claim_id)
  VALUES (new_asset_id, 'registered', auth.uid(),
          (SELECT to_jsonb(a) FROM public.customer_assets a WHERE a.id = new_asset_id),
          'Warranty replacement from claim ' || coalesce(claim.number, claim.id::text),
          claim.id);

  -- Timeline
  INSERT INTO public.customer_timeline (customer_id, event_type, description, reference_id)
  VALUES (old_asset.customer_id, 'warranty_replacement',
          'Warranty replacement: ' || old_asset.product_name || ' replaced under claim ' || coalesce(claim.number, ''),
          new_asset_id::text);

  RETURN new_asset_id;
END;
$$;

-- ============================================================================
-- 6. RPC: Get all assets for a customer (with history)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.app_customer_assets(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_variable
BEGIN
  IF NOT public.has_permission('customers.read') AND NOT public.has_permission('service.read') AND NOT public.has_permission('warranty.read') THEN
    RAISE EXCEPTION 'Read access required';
  END IF;

  RETURN jsonb_build_object(
    'assets', coalesce((
      SELECT jsonb_agg(to_jsonb(a) ORDER BY a.created_at DESC)
      FROM public.customer_assets a
      WHERE a.customer_id = p_customer_id
    ), '[]'),
    'history', coalesce((
      SELECT jsonb_agg(to_jsonb(h) ORDER BY h.created_at DESC)
      FROM public.customer_asset_history h
      JOIN public.customer_assets a ON a.id = h.asset_id
      WHERE a.customer_id = p_customer_id
    ), '[]')
  );
END;
$$;

-- ============================================================================
-- 7. RLS and Permissions
-- ============================================================================
ALTER TABLE public.customer_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_asset_history ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.customer_assets, public.customer_asset_history FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.customer_assets TO authenticated;
GRANT SELECT, INSERT ON public.customer_asset_history TO authenticated;

-- customer_assets uses same access as customers
CREATE POLICY access_read ON public.customer_assets FOR SELECT TO authenticated USING(public.has_permission('customers.read') OR public.has_permission('service.read') OR public.has_permission('warranty.read'));
CREATE POLICY access_insert ON public.customer_assets FOR INSERT TO authenticated WITH CHECK(public.has_permission('invoices.write') OR public.has_permission('warranty.write'));
CREATE POLICY access_update ON public.customer_assets FOR UPDATE TO authenticated USING(public.has_permission('invoices.write') OR public.has_permission('warranty.write'));

CREATE POLICY history_read ON public.customer_asset_history FOR SELECT TO authenticated USING(public.has_permission('customers.read') OR public.has_permission('service.read') OR public.has_permission('warranty.read'));
CREATE POLICY history_insert ON public.customer_asset_history FOR INSERT TO authenticated WITH CHECK(public.has_permission('invoices.write') OR public.has_permission('warranty.write'));

-- Grant execute on new RPCs
REVOKE ALL ON FUNCTION
  public.app_register_invoice_assets(uuid, jsonb),
  public.app_asset_warranty_replace(uuid, uuid, jsonb),
  public.app_customer_assets(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
  public.app_register_invoice_assets(uuid, jsonb),
  public.app_asset_warranty_replace(uuid, uuid, jsonb),
  public.app_customer_assets(uuid)
TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
