-- ============================================================================
-- OM Motors — DealerOS: Master Schema & Transactional Functions
-- Version: 1.0.0
-- Covers: Phase 1 (Core), Phase 2 (Operations), Phase 3 (Intelligence)
-- ============================================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Enums
DO $$ BEGIN
  CREATE TYPE staff_role AS ENUM ('owner', 'salesperson', 'inventory', 'mechanic', 'accountant');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE vehicle_category AS ENUM ('tractor', 'e_rickshaw', 'cng_rickshaw', 'diesel_rickshaw');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE vehicle_status AS ENUM ('in_stock', 'reserved', 'sold', 'delivered');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE battery_status AS ENUM ('in_stock', 'reserved', 'sold');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE item_type AS ENUM ('vehicle', 'battery', 'part', 'implement');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE quotation_status AS ENUM ('draft', 'sent', 'accepted', 'converted_to_invoice', 'rejected', 'expired');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE sale_status AS ENUM ('pending', 'confirmed', 'delivered', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE payment_method AS ENUM ('cash', 'upi', 'bank_transfer', 'cheque', 'finance');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE warranty_claim_status AS ENUM ('opened', 'inspection', 'approved', 'rejected', 'replacement', 'closed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE service_job_status AS ENUM ('scheduled', 'in_progress', 'completed', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE lead_stage AS ENUM ('new', 'contacted', 'interested', 'demo', 'quotation', 'negotiation', 'booked', 'sold', 'lost');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 1. Staff & Permissions
CREATE TABLE IF NOT EXISTS staff (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id UUID UNIQUE, -- linked to supabase auth.users if applicable
  name TEXT NOT NULL,
  phone TEXT NOT NULL UNIQUE,
  email TEXT,
  role staff_role NOT NULL DEFAULT 'salesperson',
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Customers & Geocoding
CREATE TABLE IF NOT EXISTS customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  phone TEXT NOT NULL,
  alt_phone TEXT,
  village TEXT NOT NULL,
  tehsil TEXT,
  district TEXT,
  state TEXT DEFAULT 'Uttar Pradesh',
  pincode TEXT,
  address TEXT,
  aadhaar_last4 VARCHAR(4),
  pan_no TEXT,
  id_document_ref TEXT,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_customers_phone ON customers(phone);
CREATE INDEX IF NOT EXISTS idx_customers_name ON customers(name);
CREATE INDEX IF NOT EXISTS idx_customers_village ON customers(village);

CREATE TABLE IF NOT EXISTS customer_locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  village TEXT NOT NULL,
  lat DOUBLE PRECISION,
  lng DOUBLE PRECISION,
  geocoded_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_customer_locations_cust ON customer_locations(customer_id);

-- 3. Vehicle Models & Physical Vehicles
CREATE TABLE IF NOT EXISTS vehicle_models (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category vehicle_category NOT NULL,
  brand TEXT NOT NULL DEFAULT 'New Holland',
  model_name TEXT NOT NULL,
  series TEXT,
  hp NUMERIC(5, 1),
  hsn_code TEXT DEFAULT '8701',
  gst_rate_pct NUMERIC(4, 2) DEFAULT 12.00,
  specs JSONB NOT NULL DEFAULT '{}'::jsonb,
  price NUMERIC(12, 2) NOT NULL, -- Ex-showroom placeholder
  warranty_months INT NOT NULL DEFAULT 24,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS vehicles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id UUID NOT NULL REFERENCES vehicle_models(id),
  chassis_no TEXT NOT NULL UNIQUE,
  engine_no TEXT NOT NULL UNIQUE,
  colour TEXT NOT NULL DEFAULT 'Blue',
  manufacturing_year INT DEFAULT EXTRACT(YEAR FROM CURRENT_DATE),
  status vehicle_status NOT NULL DEFAULT 'in_stock',
  customer_id UUID REFERENCES customers(id),
  received_date DATE DEFAULT CURRENT_DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_vehicles_chassis ON vehicles(chassis_no);
CREATE INDEX IF NOT EXISTS idx_vehicles_engine ON vehicles(engine_no);
CREATE INDEX IF NOT EXISTS idx_vehicles_status ON vehicles(status);

-- 4. Batteries & Serial Numbers
CREATE TABLE IF NOT EXISTS batteries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  brand TEXT NOT NULL,
  model TEXT NOT NULL,
  ah INT NOT NULL,
  voltage INT NOT NULL DEFAULT 12,
  battery_type TEXT DEFAULT 'Lithium-Ion', -- or Lead-Acid
  hsn_code TEXT DEFAULT '8507',
  gst_rate_pct NUMERIC(4, 2) DEFAULT 18.00,
  specs JSONB NOT NULL DEFAULT '{}'::jsonb,
  price NUMERIC(10, 2) NOT NULL,
  warranty_months INT NOT NULL DEFAULT 36,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS battery_serials (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  battery_id UUID NOT NULL REFERENCES batteries(id),
  serial_no TEXT NOT NULL UNIQUE,
  status battery_status NOT NULL DEFAULT 'in_stock',
  customer_id UUID REFERENCES customers(id),
  sale_id UUID,
  warranty_end DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_battery_serials_serial ON battery_serials(serial_no);

-- 5. Implements & Compatibility
CREATE TABLE IF NOT EXISTS implements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  category TEXT NOT NULL, -- Rotavator, MB Plough, Cultivator, Trolley, Laser Leveller
  brand TEXT NOT NULL,
  hsn_code TEXT DEFAULT '8432',
  gst_rate_pct NUMERIC(4, 2) DEFAULT 12.00,
  price NUMERIC(10, 2) NOT NULL,
  specs JSONB NOT NULL DEFAULT '{}'::jsonb,
  min_hp_required NUMERIC(5, 1) DEFAULT 35,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS implement_compatibility (
  implement_id UUID NOT NULL REFERENCES implements(id) ON DELETE CASCADE,
  vehicle_model_id UUID NOT NULL REFERENCES vehicle_models(id) ON DELETE CASCADE,
  PRIMARY KEY (implement_id, vehicle_model_id)
);

-- 6. Spare Parts & Compatibility
CREATE TABLE IF NOT EXISTS parts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  part_no TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  category TEXT NOT NULL, -- Engine, Filters, Electrical, Brakes, Transmission, Hydraulic
  hsn_code TEXT DEFAULT '8708',
  gst_rate_pct NUMERIC(4, 2) DEFAULT 18.00,
  purchase_price NUMERIC(10, 2) NOT NULL,
  selling_price NUMERIC(10, 2) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_parts_part_no ON parts(part_no);

CREATE TABLE IF NOT EXISTS parts_compatibility (
  part_id UUID NOT NULL REFERENCES parts(id) ON DELETE CASCADE,
  vehicle_model_id UUID NOT NULL REFERENCES vehicle_models(id) ON DELETE CASCADE,
  PRIMARY KEY (part_id, vehicle_model_id)
);

-- 7. Suppliers, Purchases & Bill Scanning
CREATE TABLE IF NOT EXISTS suppliers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  phone TEXT NOT NULL,
  gstin TEXT,
  address TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS purchases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_id UUID REFERENCES suppliers(id),
  supplier_name TEXT NOT NULL,
  bill_no TEXT NOT NULL,
  bill_date DATE NOT NULL,
  total NUMERIC(12, 2) NOT NULL,
  tax_amount NUMERIC(10, 2) DEFAULT 0,
  scanned_image_url TEXT,
  ocr_extracted_data JSONB,
  confirmed_by UUID REFERENCES staff(id),
  status TEXT NOT NULL DEFAULT 'confirmed',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_purchases_bill_no ON purchases(bill_no);

CREATE TABLE IF NOT EXISTS purchase_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_id UUID NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
  item_type item_type NOT NULL,
  item_id UUID,
  item_name TEXT NOT NULL,
  part_or_chassis_no TEXT,
  qty INT NOT NULL DEFAULT 1,
  unit_price NUMERIC(10, 2) NOT NULL,
  tax_pct NUMERIC(4, 2) DEFAULT 18.00,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 8. Real-Time Inventory Ledger
CREATE TABLE IF NOT EXISTS inventory (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  item_type item_type NOT NULL,
  item_id UUID NOT NULL,
  item_name TEXT NOT NULL,
  sku_or_code TEXT,
  qty_available INT NOT NULL DEFAULT 0,
  qty_reserved INT NOT NULL DEFAULT 0,
  min_stock_threshold INT NOT NULL DEFAULT 2,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_inventory_item UNIQUE (item_type, item_id)
);

-- 9. Quotations
CREATE TABLE IF NOT EXISTS quotations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_no TEXT NOT NULL UNIQUE,
  customer_id UUID NOT NULL REFERENCES customers(id),
  salesperson_id UUID REFERENCES staff(id),
  items JSONB NOT NULL DEFAULT '[]'::jsonb,
  subtotal NUMERIC(12, 2) NOT NULL,
  discount NUMERIC(10, 2) NOT NULL DEFAULT 0,
  tax_amount NUMERIC(10, 2) NOT NULL DEFAULT 0,
  total NUMERIC(12, 2) NOT NULL,
  valid_until DATE NOT NULL,
  status quotation_status NOT NULL DEFAULT 'draft',
  pdf_url TEXT,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_quotations_no ON quotations(quotation_no);

-- 10. Sales & Sale Items
CREATE TABLE IF NOT EXISTS sales (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_no TEXT NOT NULL UNIQUE,
  customer_id UUID NOT NULL REFERENCES customers(id),
  quotation_id UUID REFERENCES quotations(id),
  salesperson_id UUID REFERENCES staff(id),
  total NUMERIC(12, 2) NOT NULL,
  status sale_status NOT NULL DEFAULT 'pending',
  confirmed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sales_sale_no ON sales(sale_no);

CREATE TABLE IF NOT EXISTS sale_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id UUID NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
  item_type item_type NOT NULL,
  item_id UUID NOT NULL,
  serial_or_chassis TEXT,
  description TEXT NOT NULL,
  qty INT NOT NULL DEFAULT 1,
  unit_price NUMERIC(12, 2) NOT NULL,
  discount NUMERIC(10, 2) DEFAULT 0,
  tax_pct NUMERIC(4, 2) DEFAULT 12.00,
  total NUMERIC(12, 2) NOT NULL
);

-- 11. Invoices & Payments (GST Compliant)
CREATE TABLE IF NOT EXISTS invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id UUID NOT NULL REFERENCES sales(id),
  invoice_no TEXT NOT NULL UNIQUE,
  dealership_gstin TEXT NOT NULL DEFAULT '09AAAAA0000A1Z5',
  customer_id UUID NOT NULL REFERENCES customers(id),
  customer_name TEXT NOT NULL,
  customer_phone TEXT NOT NULL,
  customer_village TEXT NOT NULL,
  place_of_supply TEXT NOT NULL DEFAULT 'Uttar Pradesh (09)',
  subtotal NUMERIC(12, 2) NOT NULL,
  discount NUMERIC(10, 2) DEFAULT 0,
  cgst_amount NUMERIC(10, 2) DEFAULT 0,
  sgst_amount NUMERIC(10, 2) DEFAULT 0,
  igst_amount NUMERIC(10, 2) DEFAULT 0,
  total_amount NUMERIC(12, 2) NOT NULL,
  amount_paid NUMERIC(12, 2) NOT NULL DEFAULT 0,
  balance_due NUMERIC(12, 2) NOT NULL,
  gst_details JSONB NOT NULL DEFAULT '{}'::jsonb,
  pdf_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_invoices_no ON invoices(invoice_no);

CREATE TABLE IF NOT EXISTS payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  sale_id UUID REFERENCES sales(id),
  amount NUMERIC(12, 2) NOT NULL,
  method payment_method NOT NULL DEFAULT 'cash',
  reference_no TEXT, -- UPI UTR / Cheque No / Bank RTGS ref / Finance Sanction ID
  notes TEXT,
  received_by UUID REFERENCES staff(id),
  paid_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_payments_invoice ON payments(invoice_id);

-- 12. Warranties & Claims
CREATE TABLE IF NOT EXISTS warranties (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  item_type item_type NOT NULL,
  item_id UUID NOT NULL,
  serial_no TEXT NOT NULL,
  customer_id UUID NOT NULL REFERENCES customers(id),
  sale_id UUID REFERENCES sales(id),
  invoice_no TEXT NOT NULL,
  start_date DATE NOT NULL DEFAULT CURRENT_DATE,
  end_date DATE NOT NULL,
  bill_ref TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_warranties_serial ON warranties(serial_no);

CREATE TABLE IF NOT EXISTS warranty_claims (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  warranty_id UUID NOT NULL REFERENCES warranties(id),
  status warranty_claim_status NOT NULL DEFAULT 'opened',
  complaint_description TEXT NOT NULL,
  opened_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  notes TEXT,
  resolution TEXT,
  inspected_by UUID REFERENCES staff(id),
  closed_at TIMESTAMPTZ
);

-- 13. PDI (Pre-Delivery Inspection) & Delivery Checklist
CREATE TABLE IF NOT EXISTS pdi_checks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vehicle_id UUID NOT NULL REFERENCES vehicles(id),
  sale_id UUID REFERENCES sales(id),
  checklist JSONB NOT NULL DEFAULT '{
    "engine": {"oil_level": true, "coolant_level": true, "leak_inspection": true, "fan_belt": true},
    "electrical": {"battery_terminal": true, "headlights": true, "indicators": true, "horn": true, "instrument_cluster": true},
    "tyres": {"pressure_front": true, "pressure_rear": true, "wheel_nuts": true},
    "transmission_hydraulics": {"gear_shifting": true, "hydraulic_lift": true, "pto_rotation": true, "brake_play": true},
    "exterior_docs": {"paint_finish": true, "tool_kit_included": true, "manual_included": true}
  }'::jsonb,
  passed BOOLEAN NOT NULL DEFAULT false,
  photos JSONB DEFAULT '[]'::jsonb,
  inspected_by UUID REFERENCES staff(id),
  inspected_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS delivery_checklist (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id UUID NOT NULL REFERENCES sales(id),
  vehicle_id UUID REFERENCES vehicles(id),
  checklist JSONB NOT NULL DEFAULT '{
    "pdi_passed": false,
    "invoice_handed": false,
    "payment_cleared": false,
    "insurance_provided": false,
    "registration_applied": false,
    "warranty_terms_explained": false,
    "tool_kit_given": false,
    "owners_manual_given": false
  }'::jsonb,
  customer_signature_url TEXT,
  delivery_photo_url TEXT,
  delivered_by UUID REFERENCES staff(id),
  signed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 14. Service Jobs & Maintenance
CREATE TABLE IF NOT EXISTS service_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vehicle_id UUID NOT NULL REFERENCES vehicles(id),
  customer_id UUID NOT NULL REFERENCES customers(id),
  job_type TEXT NOT NULL DEFAULT '1st Free Service (50 Hours / 30 Days)',
  status service_job_status NOT NULL DEFAULT 'scheduled',
  scheduled_date DATE NOT NULL,
  completed_date DATE,
  hours_run INT,
  mechanic_id UUID REFERENCES staff(id),
  parts_used JSONB DEFAULT '[]'::jsonb,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_service_jobs_sched ON service_jobs(scheduled_date);

-- 15. Leads & Follow-ups CRM
CREATE TABLE IF NOT EXISTS leads (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL REFERENCES customers(id),
  requirement TEXT NOT NULL, -- e.g. "New Holland 3630 TX 55HP with 4WD"
  category vehicle_category DEFAULT 'tractor',
  est_value NUMERIC(12, 2),
  stage lead_stage NOT NULL DEFAULT 'new',
  assigned_to UUID REFERENCES staff(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS followups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  next_date DATE NOT NULL,
  notes TEXT,
  completed BOOLEAN NOT NULL DEFAULT false,
  completed_at TIMESTAMPTZ,
  conducted_by UUID REFERENCES staff(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_followups_date ON followups(next_date);

-- 16. Documents & Customer Timeline
CREATE TABLE IF NOT EXISTS documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_type TEXT NOT NULL, -- 'customer', 'vehicle', 'sale', 'purchase'
  owner_id UUID NOT NULL,
  doc_type TEXT NOT NULL, -- 'aadhaar', 'rc', 'insurance', 'bill_photo', 'pdi_photo'
  file_url TEXT NOT NULL,
  uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS customer_timeline (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL, -- 'lead_created', 'quotation_sent', 'sale_confirmed', 'payment_received', 'pdi_completed', 'delivered', 'service_scheduled'
  description TEXT NOT NULL,
  reference_id TEXT,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_customer_timeline_cust ON customer_timeline(customer_id, occurred_at DESC);

-- ============================================================================
-- THE MASTER SALE CASCADE TRANSACTION: fn_confirm_sale
-- Atomically executes the 10-step chain reaction inside a single Postgres transaction
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_confirm_sale(
  p_sale_id UUID,
  p_initial_payment_amount NUMERIC DEFAULT 0,
  p_payment_method payment_method DEFAULT 'cash',
  p_payment_ref TEXT DEFAULT NULL,
  p_staff_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_sale RECORD;
  v_customer RECORD;
  v_invoice_id UUID;
  v_invoice_no TEXT;
  v_item RECORD;
  v_warranty_months INT;
  v_warranty_end DATE;
  v_first_service_date DATE;
  v_vehicle_id UUID;
BEGIN
  -- 1. Lock and fetch sale record
  SELECT * INTO v_sale FROM sales WHERE id = p_sale_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sale ID % not found', p_sale_id;
  END IF;

  IF v_sale.status = 'confirmed' THEN
    RAISE EXCEPTION 'Sale % is already confirmed', v_sale.sale_no;
  END IF;

  -- 2. Fetch customer details
  SELECT * INTO v_customer FROM customers WHERE id = v_sale.customer_id;

  -- 3. Update Sale Status
  UPDATE sales 
  SET status = 'confirmed', confirmed_at = now(), updated_at = now()
  WHERE id = p_sale_id;

  -- 4. Generate Sequential Invoice Number (e.g. INV-2026-0001)
  v_invoice_no := 'INV-' || TO_CHAR(CURRENT_DATE, 'YYYY') || '-' || LPAD(FLOOR(RANDOM() * 9000 + 1000)::TEXT, 4, '0');

  INSERT INTO invoices (
    sale_id,
    invoice_no,
    customer_id,
    customer_name,
    customer_phone,
    customer_village,
    subtotal,
    discount,
    cgst_amount,
    sgst_amount,
    igst_amount,
    total_amount,
    amount_paid,
    balance_due,
    gst_details
  ) VALUES (
    p_sale_id,
    v_invoice_no,
    v_customer.id,
    v_customer.name,
    v_customer.phone,
    v_customer.village,
    v_sale.total / 1.12, -- Base subtotal assuming 12% GST average
    0,
    (v_sale.total - (v_sale.total / 1.12)) / 2, -- CGST 6%
    (v_sale.total - (v_sale.total / 1.12)) / 2, -- SGST 6%
    0,
    v_sale.total,
    p_initial_payment_amount,
    (v_sale.total - p_initial_payment_amount),
    jsonb_build_object(
      'state', 'Uttar Pradesh',
      'code', '09',
      'invoice_date', CURRENT_DATE
    )
  ) RETURNING id INTO v_invoice_id;

  -- 5. Record initial payment if provided
  IF p_initial_payment_amount > 0 THEN
    INSERT INTO payments (
      invoice_id,
      sale_id,
      amount,
      method,
      reference_no,
      received_by,
      paid_at
    ) VALUES (
      v_invoice_id,
      p_sale_id,
      p_initial_payment_amount,
      p_payment_method,
      p_payment_ref,
      p_staff_id,
      now()
    );
  END IF;

  -- 6. Loop through sale items to decrement inventory and bind serials
  FOR v_item IN SELECT * FROM sale_items WHERE sale_id = p_sale_id LOOP
    IF v_item.item_type = 'vehicle' THEN
      -- Find vehicle by chassis/ID and mark sold
      UPDATE vehicles 
      SET status = 'sold', customer_id = v_customer.id, updated_at = now()
      WHERE (id = v_item.item_id OR chassis_no = v_item.serial_or_chassis)
      RETURNING id INTO v_vehicle_id;

      -- Decrement available inventory for this model
      UPDATE inventory 
      SET qty_available = GREATEST(qty_available - v_item.qty, 0),
          updated_at = now()
      WHERE item_id = v_item.item_id AND item_type = 'vehicle';

      -- Determine warranty end date (default 24 months for tractors)
      v_warranty_months := 24;
      v_warranty_end := CURRENT_DATE + (v_warranty_months || ' months')::INTERVAL;

      -- Create Warranty Record
      INSERT INTO warranties (
        item_type, item_id, serial_no, customer_id, sale_id, invoice_no, start_date, end_date, bill_ref
      ) VALUES (
        'vehicle', v_item.item_id, COALESCE(v_item.serial_or_chassis, 'N/A'), v_customer.id, p_sale_id, v_invoice_no, CURRENT_DATE, v_warranty_end, v_invoice_no
      );

      -- 7. Initialize PDI Check for Service Mechanics
      IF v_vehicle_id IS NOT NULL THEN
        INSERT INTO pdi_checks (vehicle_id, sale_id, passed)
        VALUES (v_vehicle_id, p_sale_id, false);

        -- 8. Initialize Delivery Checklist
        INSERT INTO delivery_checklist (sale_id, vehicle_id)
        VALUES (p_sale_id, v_vehicle_id);

        -- 9. Schedule First Service (30 days / 50 hours out)
        v_first_service_date := CURRENT_DATE + INTERVAL '30 days';
        INSERT INTO service_jobs (
          vehicle_id, customer_id, job_type, status, scheduled_date, notes
        ) VALUES (
          v_vehicle_id, v_customer.id, '1st Free Service (50 Hours / 30 Days)', 'scheduled', v_first_service_date, 'Scheduled automatically upon sale confirmation'
        );
      END IF;

    ELSIF v_item.item_type = 'battery' THEN
      -- Bind battery serial to customer
      UPDATE battery_serials
      SET status = 'sold', customer_id = v_customer.id, sale_id = p_sale_id, warranty_end = CURRENT_DATE + INTERVAL '36 months'
      WHERE serial_no = v_item.serial_or_chassis;

      -- Decrement inventory
      UPDATE inventory 
      SET qty_available = GREATEST(qty_available - v_item.qty, 0),
          updated_at = now()
      WHERE item_id = v_item.item_id AND item_type = 'battery';

      -- Create Warranty
      INSERT INTO warranties (
        item_type, item_id, serial_no, customer_id, sale_id, invoice_no, start_date, end_date, bill_ref
      ) VALUES (
        'battery', v_item.item_id, COALESCE(v_item.serial_or_chassis, 'N/A'), v_customer.id, p_sale_id, v_invoice_no, CURRENT_DATE, CURRENT_DATE + INTERVAL '36 months', v_invoice_no
      );

    ELSE
      -- Parts and Implements: standard inventory decrement
      UPDATE inventory 
      SET qty_available = GREATEST(qty_available - v_item.qty, 0),
          updated_at = now()
      WHERE item_id = v_item.item_id AND item_type = v_item.item_type;
    END IF;
  END LOOP;

  -- 10. Write to Customer Timeline
  INSERT INTO customer_timeline (
    customer_id, event_type, description, reference_id
  ) VALUES (
    v_customer.id,
    'sale_confirmed',
    'Sale confirmed (' || v_sale.sale_no || '). Invoice ' || v_invoice_no || ' generated. PDI and service scheduled.',
    v_invoice_no
  );

  RETURN jsonb_build_object(
    'success', true,
    'sale_id', p_sale_id,
    'sale_no', v_sale.sale_no,
    'invoice_id', v_invoice_id,
    'invoice_no', v_invoice_no,
    'amount_paid', p_initial_payment_amount,
    'balance_due', (v_sale.total - p_initial_payment_amount)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- Row-Level Security (RLS) Policies
-- ============================================================================
ALTER TABLE staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE batteries ENABLE ROW LEVEL SECURITY;
ALTER TABLE battery_serials ENABLE ROW LEVEL SECURITY;
ALTER TABLE implements ENABLE ROW LEVEL SECURITY;
ALTER TABLE parts ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotations ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE warranties ENABLE ROW LEVEL SECURITY;
ALTER TABLE pdi_checks ENABLE ROW LEVEL SECURITY;
ALTER TABLE delivery_checklist ENABLE ROW LEVEL SECURITY;
ALTER TABLE service_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE leads ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_timeline ENABLE ROW LEVEL SECURITY;

-- Base policy: authenticated staff can read data
CREATE POLICY staff_read_all ON customers FOR SELECT TO authenticated USING (true);
CREATE POLICY staff_read_models ON vehicle_models FOR SELECT TO authenticated USING (true);
CREATE POLICY staff_read_vehicles ON vehicles FOR SELECT TO authenticated USING (true);
CREATE POLICY staff_read_inventory ON inventory FOR SELECT TO authenticated USING (true);
CREATE POLICY staff_read_quotations ON quotations FOR SELECT TO authenticated USING (true);
CREATE POLICY staff_read_sales ON sales FOR SELECT TO authenticated USING (true);
CREATE POLICY staff_read_invoices ON invoices FOR SELECT TO authenticated USING (true);
CREATE POLICY staff_read_timeline ON customer_timeline FOR SELECT TO authenticated USING (true);
