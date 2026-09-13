-- Run ONCE on the existing OM Motors project after the original setup.
-- Adds operational tables, transactional billing and the supplied product catalogue.
-- Does not delete existing database records or grant new staff roles.
BEGIN;
-- Operational persistence upgrade. Apply after the initial schema and access migration.

ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS gstin text;
CREATE TABLE IF NOT EXISTS public.catalog_products (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text NOT NULL UNIQUE, brand text NOT NULL, family text NOT NULL,
 model_name text NOT NULL, variant text NOT NULL DEFAULT '', category text NOT NULL, status text NOT NULL DEFAULT 'active',
 specs jsonb NOT NULL DEFAULT '{}', selling_price numeric(12,2) CHECK(selling_price>=0), gst_rate_pct numeric(5,2) CHECK(gst_rate_pct BETWEEN 0 AND 100), hsn_code text,
 source_urls jsonb NOT NULL DEFAULT '[]', source_type text NOT NULL, source_checked_on date NOT NULL, verification_status text NOT NULL,
 source_excerpt text NOT NULL, notes text NOT NULL DEFAULT '', price_effective_from date, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.business_profile (
 id boolean PRIMARY KEY DEFAULT true CHECK(id), name text NOT NULL DEFAULT 'OM Motors', address text NOT NULL DEFAULT '', phone text NOT NULL DEFAULT '',
 email text NOT NULL DEFAULT '', gstin text NOT NULL DEFAULT '', bank_details text NOT NULL DEFAULT '', terms text NOT NULL DEFAULT ''
);
INSERT INTO public.business_profile(id) VALUES(true) ON CONFLICT DO NOTHING;
CREATE SEQUENCE IF NOT EXISTS public.billing_number_seq;
CREATE TABLE IF NOT EXISTS public.billing_documents (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), kind text NOT NULL CHECK(kind IN ('quotation','invoice')), number text NOT NULL CHECK(length(trim(number)) BETWEEN 1 AND 50),
 customer_id uuid NOT NULL REFERENCES public.customers(id), customer_snapshot jsonb NOT NULL, seller_snapshot jsonb NOT NULL,
 document_date date NOT NULL, valid_until date, items jsonb NOT NULL, subtotal numeric(14,2) NOT NULL CHECK(subtotal>=0), tax_amount numeric(14,2) NOT NULL CHECK(tax_amount>=0),
 total numeric(14,2) NOT NULL CHECK(total>=0), amount_paid numeric(14,2) NOT NULL DEFAULT 0 CHECK(amount_paid>=0 AND amount_paid<=total),
 tax_mode text NOT NULL CHECK(tax_mode IN ('cgst_sgst','igst')), notes text NOT NULL DEFAULT '', source_quotation_id uuid REFERENCES public.billing_documents(id),
 created_by uuid NOT NULL REFERENCES auth.users(id), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(kind,number)
);
CREATE UNIQUE INDEX IF NOT EXISTS billing_conversion_once ON public.billing_documents(source_quotation_id) WHERE source_quotation_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS public.billing_payments (
 id uuid PRIMARY KEY, invoice_id uuid NOT NULL REFERENCES public.billing_documents(id), amount numeric(14,2) NOT NULL CHECK(amount>0),
 method public.payment_method NOT NULL, reference_no text NOT NULL DEFAULT '', paid_at timestamptz NOT NULL DEFAULT now(), received_by uuid NOT NULL REFERENCES auth.users(id)
);
CREATE TABLE IF NOT EXISTS public.stock_movements (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, inventory_id uuid NOT NULL REFERENCES public.inventory(id), delta integer NOT NULL CHECK(delta<>0),
 before_qty integer NOT NULL, after_qty integer NOT NULL CHECK(after_qty>=0), reference text NOT NULL, actor uuid NOT NULL REFERENCES auth.users(id), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.billing_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, document_id uuid NOT NULL REFERENCES public.billing_documents(id), actor uuid NOT NULL REFERENCES auth.users(id),
 before_record jsonb, after_record jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.catalog_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY catalogue_read ON public.catalog_products FOR SELECT TO authenticated USING(public.has_permission('catalogue.read') OR public.has_permission('quotations.write') OR public.has_permission('invoices.write') OR public.has_permission('inventory.read'));
CREATE POLICY profile_read ON public.business_profile FOR SELECT TO authenticated USING(public.access_role() IS NOT NULL);
CREATE POLICY profile_update ON public.business_profile FOR UPDATE TO authenticated USING(public.access_role()='owner') WITH CHECK(public.access_role()='owner');
CREATE POLICY billing_read ON public.billing_documents FOR SELECT TO authenticated USING(public.has_permission(CASE kind WHEN 'invoice' THEN 'invoices.read' ELSE 'quotations.read' END));
CREATE POLICY payment_read ON public.billing_payments FOR SELECT TO authenticated USING(public.has_permission('invoices.read'));
CREATE POLICY movement_read ON public.stock_movements FOR SELECT TO authenticated USING(public.has_permission('inventory.read'));
CREATE POLICY billing_audit_read ON public.billing_audit FOR SELECT TO authenticated USING(public.access_role()='owner');
REVOKE ALL ON public.catalog_products,public.business_profile,public.billing_documents,public.billing_payments,public.stock_movements,public.billing_audit FROM anon,authenticated;
GRANT SELECT ON public.catalog_products,public.business_profile,public.billing_documents,public.billing_payments,public.stock_movements,public.billing_audit TO authenticated;
GRANT UPDATE ON public.business_profile TO authenticated;
-- Stock can only be changed through the audited transaction functions below.
REVOKE INSERT,UPDATE,DELETE ON public.inventory FROM authenticated;
CREATE OR REPLACE FUNCTION public.app_move_stock(p_id uuid,p_delta integer,p_reference text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE stock public.inventory;
BEGIN
 IF p_delta=0 THEN RETURN; END IF;
 SELECT * INTO stock FROM public.inventory WHERE id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Stock record not found'; END IF;
 IF stock.qty_available+p_delta<stock.qty_reserved THEN RAISE EXCEPTION 'Insufficient unreserved stock for %',stock.item_name; END IF;
 UPDATE public.inventory SET qty_available=qty_available+p_delta,updated_at=now() WHERE id=p_id;
 INSERT INTO public.stock_movements(inventory_id,delta,before_qty,after_qty,reference,actor) VALUES(p_id,p_delta,stock.qty_available,stock.qty_available+p_delta,p_reference,auth.uid());
END $$;
CREATE OR REPLACE FUNCTION public.app_adjust_stock(p_id uuid,p_delta integer,p_reason text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.has_permission('inventory.write') THEN RAISE EXCEPTION 'Inventory edit permission required'; END IF;
 IF p_delta IS NULL OR p_delta=0 OR length(trim(p_reason))<3 OR p_reason IS NULL THEN RAISE EXCEPTION 'Enter a stock quantity and reason'; END IF;
 PERFORM public.app_move_stock(p_id,p_delta,trim(p_reason));
END $$;
CREATE OR REPLACE FUNCTION public.app_product_pricing(p_id uuid,p_price numeric,p_gst numeric,p_hsn text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.has_permission('catalogue.write') THEN RAISE EXCEPTION 'Catalogue edit permission required'; END IF;
 UPDATE public.catalog_products SET selling_price=p_price,gst_rate_pct=p_gst,hsn_code=nullif(trim(p_hsn),''),price_effective_from=current_date,updated_at=now() WHERE id=p_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Product not found'; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.app_save_document(p_doc jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE old public.billing_documents; saved public.billing_documents; customer public.customers; seller public.business_profile;
 doc_id uuid; doc_kind text:=p_doc->>'kind'; doc_number text; row jsonb; normalized jsonb:='[]'; qty numeric; price numeric; discount numeric; gst numeric; taxable numeric; tax numeric;
 net numeric:=0; taxes numeric:=0; inventory_id uuid; product_id uuid; change record; source_id uuid; source_doc public.billing_documents;
BEGIN
 IF doc_kind NOT IN ('quotation','invoice') OR doc_kind IS NULL THEN RAISE EXCEPTION 'Invalid document type'; END IF;
 IF NOT public.has_permission(CASE doc_kind WHEN 'invoice' THEN 'invoices.write' ELSE 'quotations.write' END) THEN RAISE EXCEPTION 'Document edit permission required'; END IF;
 doc_id:=coalesce(nullif(p_doc->>'id','')::uuid,gen_random_uuid());
 -- Serialize a document's create/update, including repeated submissions with the same UUID.
 PERFORM pg_advisory_xact_lock(hashtextextended(doc_id::text,0));
 SELECT * INTO old FROM public.billing_documents WHERE id=doc_id FOR UPDATE;
 IF FOUND THEN
  IF old.kind<>doc_kind THEN RAISE EXCEPTION 'Cannot change document type'; END IF;
  IF (p_doc->>'expectedUpdatedAt') IS NULL OR (p_doc->>'expectedUpdatedAt')::timestamptz<>old.updated_at THEN RAISE EXCEPTION 'Document changed. Reload before editing.'; END IF;
 END IF;
 SELECT * INTO customer FROM public.customers WHERE id=(p_doc->>'customerId')::uuid;
 IF NOT FOUND THEN RAISE EXCEPTION 'Select an existing customer'; END IF;
 IF NOT public.has_permission('customers.read') AND (old.id IS NULL OR old.customer_id<>customer.id) THEN RAISE EXCEPTION 'Customer view permission required'; END IF;
 IF old.amount_paid>0 AND old.customer_id<>customer.id THEN RAISE EXCEPTION 'Cannot change customer after a payment'; END IF;
 SELECT * INTO seller FROM public.business_profile WHERE id=true;
 IF NOT FOUND OR trim(seller.name)='' THEN RAISE EXCEPTION 'Business profile is missing'; END IF;
 IF (p_doc->>'date') IS NULL THEN RAISE EXCEPTION 'Document date required'; END IF;
 IF doc_kind='quotation' AND ((p_doc->>'validUntil') IS NULL OR (p_doc->>'validUntil')::date<(p_doc->>'date')::date) THEN RAISE EXCEPTION 'Quotation expiry must be on or after its date'; END IF;
 IF jsonb_typeof(p_doc->'items') IS DISTINCT FROM 'array' OR jsonb_array_length(p_doc->'items') NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'Add 1 to 200 items'; END IF;
 FOR row IN SELECT value FROM jsonb_array_elements(p_doc->'items') LOOP
  qty:=(row->>'qty')::numeric; price:=(row->>'unitPrice')::numeric; discount:=(row->>'discount')::numeric; gst:=(row->>'gstRatePct')::numeric;
  IF length(trim(coalesce(row->>'name',''))) NOT BETWEEN 1 AND 300 OR qty IS NULL OR qty<=0 OR qty<>trunc(qty) OR qty>100000 OR price IS NULL OR price<0 OR price>100000000 OR discount IS NULL OR discount<0 OR discount>qty*price OR gst IS NULL OR gst<0 OR gst>100 OR qty::text='NaN' OR price::text='NaN' OR discount::text='NaN' OR gst::text='NaN' THEN RAISE EXCEPTION 'Invalid item name, quantity, price, discount or GST'; END IF;
  inventory_id:=nullif(row->>'inventoryId','')::uuid; product_id:=nullif(row->>'productId','')::uuid;
  IF product_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.catalog_products WHERE id=product_id) THEN RAISE EXCEPTION 'Product not found'; END IF;
  IF inventory_id IS NOT NULL AND (product_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.inventory WHERE id=inventory_id AND item_id=product_id)) THEN RAISE EXCEPTION 'Stock does not match product'; END IF;
  taxable:=round(qty*round(price,2)-round(discount,2),2); tax:=round(taxable*round(gst,2)/100,2);
  net:=net+taxable; taxes:=taxes+tax;
  normalized:=normalized||jsonb_build_array(jsonb_build_object('productId',product_id,'inventoryId',inventory_id,'name',trim(row->>'name'),'hsnCode',coalesce(row->>'hsnCode',''),'qty',qty,'unitPrice',round(price,2),'discount',round(discount,2),'gstRatePct',round(gst,2),'taxable',taxable,'tax',tax,'total',taxable+tax));
 END LOOP;
 IF net+taxes<coalesce(old.amount_paid,0) THEN RAISE EXCEPTION 'Total cannot be below payments already received'; END IF;
 doc_number:=coalesce(nullif(trim(p_doc->>'number'),''),old.number,CASE doc_kind WHEN 'invoice' THEN 'INV-' ELSE 'QT-' END||extract(year from current_date)::text||'-'||lpad(nextval('public.billing_number_seq')::text,6,'0'));
 source_id:=nullif(p_doc->>'sourceQuotationId','')::uuid;
 IF old.id IS NOT NULL AND source_id IS DISTINCT FROM old.source_quotation_id THEN RAISE EXCEPTION 'Cannot change the source quotation'; END IF;
 IF source_id IS NOT NULL THEN
  IF doc_kind<>'invoice' OR NOT public.has_permission('quotations.read') THEN RAISE EXCEPTION 'Quotation view access required for conversion'; END IF;
  SELECT * INTO source_doc FROM public.billing_documents WHERE id=source_id FOR UPDATE;
  IF NOT FOUND OR source_doc.kind<>'quotation' OR source_doc.customer_id<>customer.id THEN RAISE EXCEPTION 'Invalid source quotation'; END IF;
 END IF;
 IF doc_kind='invoice' THEN
  -- Lock in stable UUID order, then apply only the difference on edits.
  FOR change IN WITH new_qty AS (SELECT (v->>'inventoryId')::uuid id,sum((v->>'qty')::integer) qty FROM jsonb_array_elements(normalized) v WHERE v->>'inventoryId' IS NOT NULL GROUP BY 1),
  old_qty AS (SELECT (v->>'inventoryId')::uuid id,sum((v->>'qty')::integer) qty FROM jsonb_array_elements(coalesce(old.items,'[]')) v WHERE v->>'inventoryId' IS NOT NULL GROUP BY 1)
  SELECT coalesce(n.id,o.id) id,(coalesce(o.qty,0)-coalesce(n.qty,0))::integer delta FROM new_qty n FULL JOIN old_qty o USING(id) ORDER BY 1 LOOP
   PERFORM public.app_move_stock(change.id,change.delta,doc_number);
  END LOOP;
 END IF;
 INSERT INTO public.billing_documents(id,kind,number,customer_id,customer_snapshot,seller_snapshot,document_date,valid_until,items,subtotal,tax_amount,total,amount_paid,tax_mode,notes,source_quotation_id,created_by)
 VALUES(doc_id,doc_kind,doc_number,customer.id,jsonb_build_object('name',customer.name,'phone',customer.phone,'village',customer.village,'address',customer.address,'gstin',customer.gstin),to_jsonb(seller),(p_doc->>'date')::date,CASE WHEN doc_kind='quotation' THEN nullif(p_doc->>'validUntil','')::date ELSE NULL END,normalized,net,taxes,net+taxes,coalesce(old.amount_paid,0),p_doc->>'taxMode',coalesce(p_doc->>'notes',''),source_id,auth.uid())
 ON CONFLICT(id) DO UPDATE SET number=excluded.number,customer_id=excluded.customer_id,customer_snapshot=excluded.customer_snapshot,seller_snapshot=excluded.seller_snapshot,document_date=excluded.document_date,valid_until=excluded.valid_until,items=excluded.items,subtotal=excluded.subtotal,tax_amount=excluded.tax_amount,total=excluded.total,tax_mode=excluded.tax_mode,notes=excluded.notes,updated_at=clock_timestamp() RETURNING * INTO saved;
 INSERT INTO public.billing_audit(document_id,actor,before_record,after_record) VALUES(saved.id,auth.uid(),CASE WHEN old.id IS NULL THEN NULL ELSE to_jsonb(old) END,to_jsonb(saved));
 RETURN to_jsonb(saved);
END $$;
CREATE OR REPLACE FUNCTION public.app_record_payment(p_id uuid,p_invoice uuid,p_amount numeric,p_method public.payment_method,p_reference text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE invoice public.billing_documents; existing public.billing_payments;
BEGIN
 IF NOT public.has_permission('invoices.write') THEN RAISE EXCEPTION 'Invoice edit permission required'; END IF;
 IF p_id IS NULL OR p_amount IS NULL OR p_amount<=0 OR p_amount::text='NaN' THEN RAISE EXCEPTION 'Enter a positive payment'; END IF;
 SELECT * INTO invoice FROM public.billing_documents WHERE id=p_invoice FOR UPDATE;
 IF NOT FOUND OR invoice.kind<>'invoice' THEN RAISE EXCEPTION 'Invoice not found'; END IF;
 SELECT * INTO existing FROM public.billing_payments WHERE id=p_id;
 IF FOUND THEN
  IF existing.invoice_id<>p_invoice OR existing.amount<>round(p_amount,2) OR existing.method<>p_method OR existing.reference_no<>coalesce(p_reference,'') THEN RAISE EXCEPTION 'Payment reference reused with different details'; END IF;
  RETURN;
 END IF;
 IF round(p_amount,2)<=0 OR round(p_amount,2)>invoice.total-invoice.amount_paid THEN RAISE EXCEPTION 'Payment exceeds the outstanding balance or rounds to zero'; END IF;
 INSERT INTO public.billing_payments(id,invoice_id,amount,method,reference_no,received_by) VALUES(p_id,p_invoice,round(p_amount,2),p_method,coalesce(p_reference,''),auth.uid());
 UPDATE public.billing_documents SET amount_paid=amount_paid+round(p_amount,2),updated_at=clock_timestamp() WHERE id=p_invoice;
END $$;
CREATE OR REPLACE FUNCTION public.app_receive_stock(p_product uuid,p_qty integer,p_reference text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE product public.catalog_products; stock_id uuid; kind public.item_type;
BEGIN
 IF NOT public.has_permission('inventory.write') THEN RAISE EXCEPTION 'Inventory edit permission required'; END IF;
 IF p_qty IS NULL OR p_qty<=0 OR p_reference IS NULL OR length(trim(p_reference))<3 THEN RAISE EXCEPTION 'Positive quantity and purchase/reference number required'; END IF;
 SELECT * INTO product FROM public.catalog_products WHERE id=p_product;
 IF NOT FOUND THEN RAISE EXCEPTION 'Product not found'; END IF;
 kind:=CASE product.category WHEN 'battery' THEN 'battery'::public.item_type WHEN 'part' THEN 'part'::public.item_type WHEN 'implement' THEN 'implement'::public.item_type ELSE 'vehicle'::public.item_type END;
 INSERT INTO public.inventory(item_type,item_id,item_name,sku_or_code,qty_available) VALUES(kind,product.id,product.model_name||' '||product.variant,product.code,0) ON CONFLICT(item_type,item_id) DO NOTHING;
 SELECT id INTO stock_id FROM public.inventory WHERE item_type=kind AND item_id=product.id;
 PERFORM public.app_move_stock(stock_id,p_qty,p_reference);
END $$;
REVOKE ALL ON FUNCTION public.app_move_stock(uuid,integer,text),public.app_adjust_stock(uuid,integer,text),public.app_product_pricing(uuid,numeric,numeric,text),public.app_save_document(jsonb),public.app_record_payment(uuid,uuid,numeric,public.payment_method,text),public.app_receive_stock(uuid,integer,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.app_adjust_stock(uuid,integer,text),public.app_product_pricing(uuid,numeric,numeric,text),public.app_save_document(jsonb),public.app_record_payment(uuid,uuid,numeric,public.payment_method,text),public.app_receive_stock(uuid,integer,text) TO authenticated;
NOTIFY pgrst,'reload schema';




-- Product seed from supplied data pack, checked 2026-09-12. No stock, GST or dealership prices are invented.

INSERT INTO public.catalog_products(code,brand,family,model_name,variant,category,status,specs,source_urls,source_type,source_checked_on,verification_status,source_excerpt,notes) VALUES
('NEW_HOLLAND_3600_TX_SUPER_HERITAGE_EDITION_2WD','New Holland','3600','3600 TX Super Heritage Edition','2WD','tractor','active','{"Engine power":"47 HP","Engine":"FPT 8035.05D.943","Lift":"1800 kg","Gearbox":"8F+2R / optional 8F+8R / 16F+4R SpeedTech","PTO":"EPTRA PTO"}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-tx-super-heritage-edition","https://www.newhollandtractorindia.com/CorporateBrochurePresentation.pdf","https://www.91tractors.com/tractors/new-holland/3600-tx"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3600 TX / 3600 TX Super Heritage Edition

### Naming note
The exact historical name “3600 TX” is still found in market/catalogue records. New Holland''s current India site lists **3600 TX Super Heritage Edition** as the active/current product page. The current page shows 2WD and 4WD models.

### Manufacturer-published current 3600 TX Super Heritage Edition highlights
- Highest useful power: **42.5 HP** (manufacturer headline)
- Current listed engine: **FPT 8035.05D.943**
- Engine power on page: **35.1 kW / 47 HP**
- Gearbox options: **8F+2R**, **8F+8R***, **16F+4R (SpeedTech)***
- PTO: **EPTRA PTO**
- Hydraulic lifting capacity: **1800 kg**
- Independent PTO clutch lever
- Straight axle planetary drive
- Paddy-special double metal face sealing (optional)
- Potato/onion track width: **48 in**
- 4WD available with MHD axle (optional)
- Variants: **2WD and 4WD**

### Historical/market specification data found for 3600 TX / Heritage Edition
- Cylinders: **3**
- Displacement: **2931 cc** (third-party specification source)
- Fuel tank: **46 L** (third-party comparison source)
- Transmission: Constant Mesh / available Synchro Shuttle depending variant
- Ground clearance: **445 mm** appears in some variant records; verify against the exact VIN/variant before putting on a customer quotation
- Warranty: **6 years / 6000 hours** is manufacturer/marketing material for this family

### App record guidance
Use separate records for:
- `3600_TX_HERITAGE_2WD`
- `3600_TX_HERITAGE_4WD`
- historical `3600_TX`

### Sources
- Official New Holland product page: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-tx-super-heritage-edition
- New Holland corporate brochure/PDF record: https://www.newhollandtractorindia.com/CorporateBrochurePresentation.pdf
- Third-party current market record: https://www.91tractors.com/tractors/new-holland/3600-tx

Verification: **Manufacturer verified for headline/current variant fields; selected dimensions/capacities require variant-level brochure verification.**

---

',''),
('NEW_HOLLAND_3600_TX_SUPER_HERITAGE_EDITION_4WD','New Holland','3600','3600 TX Super Heritage Edition','4WD','tractor','active','{"Engine power":"47 HP","Engine":"FPT 8035.05D.943","Lift":"1800 kg","Gearbox":"8F+2R / optional 8F+8R / 16F+4R SpeedTech","PTO":"EPTRA PTO"}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-tx-super-heritage-edition","https://www.newhollandtractorindia.com/CorporateBrochurePresentation.pdf","https://www.91tractors.com/tractors/new-holland/3600-tx"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3600 TX / 3600 TX Super Heritage Edition

### Naming note
The exact historical name “3600 TX” is still found in market/catalogue records. New Holland''s current India site lists **3600 TX Super Heritage Edition** as the active/current product page. The current page shows 2WD and 4WD models.

### Manufacturer-published current 3600 TX Super Heritage Edition highlights
- Highest useful power: **42.5 HP** (manufacturer headline)
- Current listed engine: **FPT 8035.05D.943**
- Engine power on page: **35.1 kW / 47 HP**
- Gearbox options: **8F+2R**, **8F+8R***, **16F+4R (SpeedTech)***
- PTO: **EPTRA PTO**
- Hydraulic lifting capacity: **1800 kg**
- Independent PTO clutch lever
- Straight axle planetary drive
- Paddy-special double metal face sealing (optional)
- Potato/onion track width: **48 in**
- 4WD available with MHD axle (optional)
- Variants: **2WD and 4WD**

### Historical/market specification data found for 3600 TX / Heritage Edition
- Cylinders: **3**
- Displacement: **2931 cc** (third-party specification source)
- Fuel tank: **46 L** (third-party comparison source)
- Transmission: Constant Mesh / available Synchro Shuttle depending variant
- Ground clearance: **445 mm** appears in some variant records; verify against the exact VIN/variant before putting on a customer quotation
- Warranty: **6 years / 6000 hours** is manufacturer/marketing material for this family

### App record guidance
Use separate records for:
- `3600_TX_HERITAGE_2WD`
- `3600_TX_HERITAGE_4WD`
- historical `3600_TX`

### Sources
- Official New Holland product page: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-tx-super-heritage-edition
- New Holland corporate brochure/PDF record: https://www.newhollandtractorindia.com/CorporateBrochurePresentation.pdf
- Third-party current market record: https://www.91tractors.com/tractors/new-holland/3600-tx

Verification: **Manufacturer verified for headline/current variant fields; selected dimensions/capacities require variant-level brochure verification.**

---

',''),
('NEW_HOLLAND_3600_TX_HISTORICAL','New Holland','3600','3600 TX','Historical','tractor','legacy','{}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-tx-super-heritage-edition","https://www.newhollandtractorindia.com/CorporateBrochurePresentation.pdf","https://www.91tractors.com/tractors/new-holland/3600-tx"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3600 TX / 3600 TX Super Heritage Edition

### Naming note
The exact historical name “3600 TX” is still found in market/catalogue records. New Holland''s current India site lists **3600 TX Super Heritage Edition** as the active/current product page. The current page shows 2WD and 4WD models.

### Manufacturer-published current 3600 TX Super Heritage Edition highlights
- Highest useful power: **42.5 HP** (manufacturer headline)
- Current listed engine: **FPT 8035.05D.943**
- Engine power on page: **35.1 kW / 47 HP**
- Gearbox options: **8F+2R**, **8F+8R***, **16F+4R (SpeedTech)***
- PTO: **EPTRA PTO**
- Hydraulic lifting capacity: **1800 kg**
- Independent PTO clutch lever
- Straight axle planetary drive
- Paddy-special double metal face sealing (optional)
- Potato/onion track width: **48 in**
- 4WD available with MHD axle (optional)
- Variants: **2WD and 4WD**

### Historical/market specification data found for 3600 TX / Heritage Edition
- Cylinders: **3**
- Displacement: **2931 cc** (third-party specification source)
- Fuel tank: **46 L** (third-party comparison source)
- Transmission: Constant Mesh / available Synchro Shuttle depending variant
- Ground clearance: **445 mm** appears in some variant records; verify against the exact VIN/variant before putting on a customer quotation
- Warranty: **6 years / 6000 hours** is manufacturer/marketing material for this family

### App record guidance
Use separate records for:
- `3600_TX_HERITAGE_2WD`
- `3600_TX_HERITAGE_4WD`
- historical `3600_TX`

### Sources
- Official New Holland product page: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-tx-super-heritage-edition
- New Holland corporate brochure/PDF record: https://www.newhollandtractorindia.com/CorporateBrochurePresentation.pdf
- Third-party current market record: https://www.91tractors.com/tractors/new-holland/3600-tx

Verification: **Manufacturer verified for headline/current variant fields; selected dimensions/capacities require variant-level brochure verification.**

---

','Historical model. Verify exact unit specifications.'),
('NEW_HOLLAND_3600_2_TX_2WD','New Holland','3600','3600-2 TX','2WD','tractor','active','{"Engine power":"49.5 HP","Engine":"FPT S8000","Lift":"1700 kg with Assist RAM","Gearbox":"8F+2R / optional 12F+3R Creeper","Fuel tank":"60 L (brochure cross-check)"}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-2-tx","https://s3.ap-southeast-1.amazonaws.com/delen/uploads/3bd6ccf9-e6aa-447f-9372-21819ac46900-New%20Holland%203600-2%20TX%20Brochure.pdf","https://tractorguru.in/tractor/new-holland-3600-2-tx","https://tractorkarvan.com/tractor/new-holland-3600-2-tx"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3600-2 TX

### Manufacturer-published facts
- Engine family: **FPT S8000**
- Engine power: **36.94 kW / 49.5 HP** on the current manufacturer page
- Double clutch with independent PTO lever
- Gearbox: **8F+2R / 12F+3R Creeper***
- Sensomatic24 hydraulic lift with **24 sensing points**
- Lifting capacity: **1700 kg with Assist RAM** (manufacturer headline)
- Lift-O-Matic with height limiter
- DRC valve and isolator valve
- Current page identifies the model as **3600-2 TX**

### Detailed brochure/specification data cross-checked
- Cylinders: **3**
- Displacement: **2931 cc**
- Rated RPM: **2500 RPM**
- Cooling: **Water cooled / liquid cooled**
- Air filter: **Oil bath with pre-cleaner**
- Fuel: **Diesel**
- Transmission: **Fully constant mesh / side shift**
- Gears: **8 Forward + 2 Reverse**; creeper configuration available
- PTO: **46 HP**, 540 RPM / GSPTO (source wording varies by record)
- Fuel tank: **60 L**
- Hydraulics: **1700 kg**, Sensomatic24, ADDC; Cat-II 3-point linkage
- Steering: **Power steering**
- Brakes: **Real oil immersed multi-disc brakes**
- Front tyres: **7.50-16**
- Rear tyres: **14.9-28**
- Overall length: **3450 mm**
- Width: **1815 mm**
- Height: **2375 mm**
- Wheelbase: **2045 mm**
- Ground clearance: **445 mm**
- Weight: **2060 kg**
- Battery: **88 Ah** in brochure/third-party records; some market pages show 100 Ah. Do not hard-code one value for all variants.
- Alternator: **45/55 A depending source/variant**
- Warranty: **6 years / 6000 hours**
- Drive: **2WD** for this exact base 3600-2 TX record

### Known compatible/application references from manufacturer brochure
- Cultivator
- MB plough
- Sugarcane haulage
- Straw reaper
- Rotavator
- Laser leveller

### Sources
- Official New Holland page: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-2-tx
- Brochure/specification PDF: https://s3.ap-southeast-1.amazonaws.com/delen/uploads/3bd6ccf9-e6aa-447f-9372-21819ac46900-New%20Holland%203600-2%20TX%20Brochure.pdf
- TractorGuru detailed record: https://tractorguru.in/tractor/new-holland-3600-2-tx
- TractorKarvan detailed record: https://tractorkarvan.com/tractor/new-holland-3600-2-tx

Verification: **Manufacturer headline verified; detailed dimensions/specs cross-checked against brochure/secondary records.**

---

',''),
('NEW_HOLLAND_3600_2_TX_ALL_ROUNDER_PLUS_PLUS_2WD','New Holland','3600','3600-2 TX All Rounder Plus+','2WD','tractor','active','{"Engine power":"49.5 HP","Engine":"FPT S8000","Lift":"1700 kg / optional 2000 kg","Gearbox":"8F+2R / optional 12F+3R Creeper / UG"}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-2-tx-all-rounder-plus","https://tractorguru.in/tractor/new-holland-3600-2-tx-all-rounder-plus","https://tractorgyan.com/tractor/new-holland/3600-2-tx-all-rounder-plus-2wd"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3600-2 TX All Rounder Plus+

### Manufacturer-published facts
- Engine: **FPT S8000**
- Engine power: **49.5 HP**
- Double clutch with independent PTO lever
- Gearboxes: **8F+2R, 12F+3R Creeper*, 12F+3R UG***
- Sensomatic24 hydraulic lift with 24 sensing points
- Lifting capacity: **1700 kg / 2000 kg***
- Lift-O-Matic with height limiter
- DRC valve and isolator valve
- Variants: **2WD and 4WD**

### Cross-checked detailed fields for the common 2WD record
- Cylinders: **3** (some third-party pages incorrectly list 4; retain 3 unless exact variant brochure proves otherwise)
- Displacement: **3070 cc** in third-party current records
- Rated RPM: **2100 RPM**
- Air filter: Oil bath with pre-cleaner
- Cooling: Water cooled
- Gearbox: Fully Constant Mesh / Partial Synchromesh depending configuration
- Forward speed range: **1.87–33.83 km/h** in one current detailed record
- Reverse speed range: **2.71–15.16 km/h**
- PTO: **46 HP**, GSPTO/RPTO*, 540 @ 1800 ERPM
- Fuel tank: **60 L**
- Hydraulics: **1700/2000 kg**, DRC valve and isolator valve
- Tyres: **6.5x16 / 7.5x16 front; 14.9x28 / 16.9x28 rear depending variant**
- Wheelbase: **2040 mm**
- Length: **3465 mm**
- Width: **1815 mm**
- Weight: **~2100 kg** in one current detailed record
- Ground clearance: **445 mm**
- Warranty: **6 years / 6000 hours**

### Sources
- Official New Holland page: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-2-tx-all-rounder-plus
- TractorGuru: https://tractorguru.in/tractor/new-holland-3600-2-tx-all-rounder-plus
- TractorGyan: https://tractorgyan.com/tractor/new-holland/3600-2-tx-all-rounder-plus-2wd

Verification: **Manufacturer verified for model headline; detailed field set must remain variant-aware.**

---

','Detailed dimensions in the source are for the common 2WD configuration; verify exact variant.'),
('NEW_HOLLAND_3600_2_TX_ALL_ROUNDER_PLUS_PLUS_4WD','New Holland','3600','3600-2 TX All Rounder Plus+','4WD','tractor','active','{"Engine power":"49.5 HP","Engine":"FPT S8000","Lift":"1700 kg / optional 2000 kg","Gearbox":"8F+2R / optional 12F+3R Creeper / UG"}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-2-tx-all-rounder-plus","https://tractorguru.in/tractor/new-holland-3600-2-tx-all-rounder-plus","https://tractorgyan.com/tractor/new-holland/3600-2-tx-all-rounder-plus-2wd"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3600-2 TX All Rounder Plus+

### Manufacturer-published facts
- Engine: **FPT S8000**
- Engine power: **49.5 HP**
- Double clutch with independent PTO lever
- Gearboxes: **8F+2R, 12F+3R Creeper*, 12F+3R UG***
- Sensomatic24 hydraulic lift with 24 sensing points
- Lifting capacity: **1700 kg / 2000 kg***
- Lift-O-Matic with height limiter
- DRC valve and isolator valve
- Variants: **2WD and 4WD**

### Cross-checked detailed fields for the common 2WD record
- Cylinders: **3** (some third-party pages incorrectly list 4; retain 3 unless exact variant brochure proves otherwise)
- Displacement: **3070 cc** in third-party current records
- Rated RPM: **2100 RPM**
- Air filter: Oil bath with pre-cleaner
- Cooling: Water cooled
- Gearbox: Fully Constant Mesh / Partial Synchromesh depending configuration
- Forward speed range: **1.87–33.83 km/h** in one current detailed record
- Reverse speed range: **2.71–15.16 km/h**
- PTO: **46 HP**, GSPTO/RPTO*, 540 @ 1800 ERPM
- Fuel tank: **60 L**
- Hydraulics: **1700/2000 kg**, DRC valve and isolator valve
- Tyres: **6.5x16 / 7.5x16 front; 14.9x28 / 16.9x28 rear depending variant**
- Wheelbase: **2040 mm**
- Length: **3465 mm**
- Width: **1815 mm**
- Weight: **~2100 kg** in one current detailed record
- Ground clearance: **445 mm**
- Warranty: **6 years / 6000 hours**

### Sources
- Official New Holland page: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-2-tx-all-rounder-plus
- TractorGuru: https://tractorguru.in/tractor/new-holland-3600-2-tx-all-rounder-plus
- TractorGyan: https://tractorgyan.com/tractor/new-holland/3600-2-tx-all-rounder-plus-2wd

Verification: **Manufacturer verified for model headline; detailed field set must remain variant-aware.**

---

','Detailed dimensions in the source are for the common 2WD configuration; verify exact variant.'),
('NEW_HOLLAND_3630_TX_SUPER_PLUS_PLUS_2WD','New Holland','3630','3630 TX Super Plus+','2WD','tractor','active','{"Engine":"FPT S8000","Lift":"2000 kg / optional 1700 kg","Hydraulics":"Sensomatic24"}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition","https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus","https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3630 TX

### Naming note
The historical **3630 TX Plus / 3630 TX Plus+** is now represented by newer current variants on New Holland India''s site, notably:
- **3630 TX Super Plus+ 2WD / 4WD**
- **3630 TX Super**
- **3630 TX Special Edition**

Legacy models should remain in the app for historical invoices, old customer vehicles, and parts lookup.

### Current 3630 TX Super Plus+ manufacturer facts
- Engine: **FPT S8000**
- Double clutch with independent PTO lever
- Gearboxes: **12F+3R UG, 12F+3R Creeper*, 8F+2R UG***
- Sensomatic24 with 24 sensing points
- Lift capacity: **2000 kg / 1700 kg***
- Lift-O-Matic with height limiter
- DRC valve and isolator valve
- Current variants: **2WD and 4WD**

### Cross-checked legacy 3630 TX Plus+ detailed data
- Cylinders: **3**
- HP: **55 HP** in the legacy 3630 TX Plus+ record; other newer 3630 TX records may be 50 HP. Never mix these as one model.
- Engine: **FPT S8000**, turbo-charged in the legacy Plus+ source
- Displacement: **2991 cc** appears in third-party records
- Rated RPM: **2300 RPM** in the legacy 55 HP record
- Clutch: Double clutch with independent PTO clutch lever
- Gearbox: Fully constant mesh / partial synchromesh depending configuration
- Gear speeds: **8F+2R / 12F+3R Creeper / 12F+3R UG**
- PTO: **540 RPM & GSPTO / RPTO**
- Fuel tank: **60 L**
- Lifting capacity: **1700/2000 kg**
- Front tyre: **7.50x16**
- Rear tyre: **16.9x28** on one legacy record; 14.9x28 appears in other variants
- Wheelbase: **~2040–2045 mm depending variant/source**
- Ground clearance: **445 mm**
- Weight: **~2080–2180 kg depending exact variant/source**
- Battery: **88 Ah** in legacy records
- Alternator: **55 A** in legacy records
- Warranty: **6 years / 6000 hours**

### Current 3630 TX Special Edition manufacturer highlights
- FPT S8000
- Double clutch with independent PTO lever
- 12F+3R UG / 12F+3R Creeper* / 8F+2R UG*
- Sensomatic24
- 2000 kg / 1700 kg* lift
- Lift-O-Matic height limiter
- DRC valve & isolator valve
- ROPS & fibre canopy
- Clear-lens headlamp with DRL signature light
- LED fender lamp
- 2WD and 4WD

### Sources
- Official 3630 TX Super Plus+: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus
- Official 3630 TX Super: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super
- Official 3630 TX Special Edition: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition
- Legacy detailed record: https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus
- Legacy 4WD record: https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd

Verification: **Current family verified by manufacturer; legacy detailed records are variant-specific and must not be combined.**

---

','Engine HP not verified for this exact current variant; do not inherit legacy 55 HP.'),
('NEW_HOLLAND_3630_TX_SUPER_PLUS_PLUS_4WD','New Holland','3630','3630 TX Super Plus+','4WD','tractor','active','{"Engine":"FPT S8000","Lift":"2000 kg / optional 1700 kg","Hydraulics":"Sensomatic24"}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition","https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus","https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3630 TX

### Naming note
The historical **3630 TX Plus / 3630 TX Plus+** is now represented by newer current variants on New Holland India''s site, notably:
- **3630 TX Super Plus+ 2WD / 4WD**
- **3630 TX Super**
- **3630 TX Special Edition**

Legacy models should remain in the app for historical invoices, old customer vehicles, and parts lookup.

### Current 3630 TX Super Plus+ manufacturer facts
- Engine: **FPT S8000**
- Double clutch with independent PTO lever
- Gearboxes: **12F+3R UG, 12F+3R Creeper*, 8F+2R UG***
- Sensomatic24 with 24 sensing points
- Lift capacity: **2000 kg / 1700 kg***
- Lift-O-Matic with height limiter
- DRC valve and isolator valve
- Current variants: **2WD and 4WD**

### Cross-checked legacy 3630 TX Plus+ detailed data
- Cylinders: **3**
- HP: **55 HP** in the legacy 3630 TX Plus+ record; other newer 3630 TX records may be 50 HP. Never mix these as one model.
- Engine: **FPT S8000**, turbo-charged in the legacy Plus+ source
- Displacement: **2991 cc** appears in third-party records
- Rated RPM: **2300 RPM** in the legacy 55 HP record
- Clutch: Double clutch with independent PTO clutch lever
- Gearbox: Fully constant mesh / partial synchromesh depending configuration
- Gear speeds: **8F+2R / 12F+3R Creeper / 12F+3R UG**
- PTO: **540 RPM & GSPTO / RPTO**
- Fuel tank: **60 L**
- Lifting capacity: **1700/2000 kg**
- Front tyre: **7.50x16**
- Rear tyre: **16.9x28** on one legacy record; 14.9x28 appears in other variants
- Wheelbase: **~2040–2045 mm depending variant/source**
- Ground clearance: **445 mm**
- Weight: **~2080–2180 kg depending exact variant/source**
- Battery: **88 Ah** in legacy records
- Alternator: **55 A** in legacy records
- Warranty: **6 years / 6000 hours**

### Current 3630 TX Special Edition manufacturer highlights
- FPT S8000
- Double clutch with independent PTO lever
- 12F+3R UG / 12F+3R Creeper* / 8F+2R UG*
- Sensomatic24
- 2000 kg / 1700 kg* lift
- Lift-O-Matic height limiter
- DRC valve & isolator valve
- ROPS & fibre canopy
- Clear-lens headlamp with DRL signature light
- LED fender lamp
- 2WD and 4WD

### Sources
- Official 3630 TX Super Plus+: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus
- Official 3630 TX Super: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super
- Official 3630 TX Special Edition: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition
- Legacy detailed record: https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus
- Legacy 4WD record: https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd

Verification: **Current family verified by manufacturer; legacy detailed records are variant-specific and must not be combined.**

---

','Engine HP not verified for this exact current variant; do not inherit legacy 55 HP.'),
('NEW_HOLLAND_3630_TX_SPECIAL_EDITION_2WD','New Holland','3630','3630 TX Special Edition','2WD','tractor','active','{"Engine":"FPT S8000","Lift":"2000 kg / optional 1700 kg","Hydraulics":"Sensomatic24"}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super","https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus","https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3630 TX

### Naming note
The historical **3630 TX Plus / 3630 TX Plus+** is now represented by newer current variants on New Holland India''s site, notably:
- **3630 TX Super Plus+ 2WD / 4WD**
- **3630 TX Super**
- **3630 TX Special Edition**

Legacy models should remain in the app for historical invoices, old customer vehicles, and parts lookup.

### Current 3630 TX Super Plus+ manufacturer facts
- Engine: **FPT S8000**
- Double clutch with independent PTO lever
- Gearboxes: **12F+3R UG, 12F+3R Creeper*, 8F+2R UG***
- Sensomatic24 with 24 sensing points
- Lift capacity: **2000 kg / 1700 kg***
- Lift-O-Matic with height limiter
- DRC valve and isolator valve
- Current variants: **2WD and 4WD**

### Cross-checked legacy 3630 TX Plus+ detailed data
- Cylinders: **3**
- HP: **55 HP** in the legacy 3630 TX Plus+ record; other newer 3630 TX records may be 50 HP. Never mix these as one model.
- Engine: **FPT S8000**, turbo-charged in the legacy Plus+ source
- Displacement: **2991 cc** appears in third-party records
- Rated RPM: **2300 RPM** in the legacy 55 HP record
- Clutch: Double clutch with independent PTO clutch lever
- Gearbox: Fully constant mesh / partial synchromesh depending configuration
- Gear speeds: **8F+2R / 12F+3R Creeper / 12F+3R UG**
- PTO: **540 RPM & GSPTO / RPTO**
- Fuel tank: **60 L**
- Lifting capacity: **1700/2000 kg**
- Front tyre: **7.50x16**
- Rear tyre: **16.9x28** on one legacy record; 14.9x28 appears in other variants
- Wheelbase: **~2040–2045 mm depending variant/source**
- Ground clearance: **445 mm**
- Weight: **~2080–2180 kg depending exact variant/source**
- Battery: **88 Ah** in legacy records
- Alternator: **55 A** in legacy records
- Warranty: **6 years / 6000 hours**

### Current 3630 TX Special Edition manufacturer highlights
- FPT S8000
- Double clutch with independent PTO lever
- 12F+3R UG / 12F+3R Creeper* / 8F+2R UG*
- Sensomatic24
- 2000 kg / 1700 kg* lift
- Lift-O-Matic height limiter
- DRC valve & isolator valve
- ROPS & fibre canopy
- Clear-lens headlamp with DRL signature light
- LED fender lamp
- 2WD and 4WD

### Sources
- Official 3630 TX Super Plus+: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus
- Official 3630 TX Super: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super
- Official 3630 TX Special Edition: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition
- Legacy detailed record: https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus
- Legacy 4WD record: https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd

Verification: **Current family verified by manufacturer; legacy detailed records are variant-specific and must not be combined.**

---

','Engine HP not verified for this exact current variant; do not inherit legacy 55 HP.'),
('NEW_HOLLAND_3630_TX_SPECIAL_EDITION_4WD','New Holland','3630','3630 TX Special Edition','4WD','tractor','active','{"Engine":"FPT S8000","Lift":"2000 kg / optional 1700 kg","Hydraulics":"Sensomatic24"}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super","https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus","https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3630 TX

### Naming note
The historical **3630 TX Plus / 3630 TX Plus+** is now represented by newer current variants on New Holland India''s site, notably:
- **3630 TX Super Plus+ 2WD / 4WD**
- **3630 TX Super**
- **3630 TX Special Edition**

Legacy models should remain in the app for historical invoices, old customer vehicles, and parts lookup.

### Current 3630 TX Super Plus+ manufacturer facts
- Engine: **FPT S8000**
- Double clutch with independent PTO lever
- Gearboxes: **12F+3R UG, 12F+3R Creeper*, 8F+2R UG***
- Sensomatic24 with 24 sensing points
- Lift capacity: **2000 kg / 1700 kg***
- Lift-O-Matic with height limiter
- DRC valve and isolator valve
- Current variants: **2WD and 4WD**

### Cross-checked legacy 3630 TX Plus+ detailed data
- Cylinders: **3**
- HP: **55 HP** in the legacy 3630 TX Plus+ record; other newer 3630 TX records may be 50 HP. Never mix these as one model.
- Engine: **FPT S8000**, turbo-charged in the legacy Plus+ source
- Displacement: **2991 cc** appears in third-party records
- Rated RPM: **2300 RPM** in the legacy 55 HP record
- Clutch: Double clutch with independent PTO clutch lever
- Gearbox: Fully constant mesh / partial synchromesh depending configuration
- Gear speeds: **8F+2R / 12F+3R Creeper / 12F+3R UG**
- PTO: **540 RPM & GSPTO / RPTO**
- Fuel tank: **60 L**
- Lifting capacity: **1700/2000 kg**
- Front tyre: **7.50x16**
- Rear tyre: **16.9x28** on one legacy record; 14.9x28 appears in other variants
- Wheelbase: **~2040–2045 mm depending variant/source**
- Ground clearance: **445 mm**
- Weight: **~2080–2180 kg depending exact variant/source**
- Battery: **88 Ah** in legacy records
- Alternator: **55 A** in legacy records
- Warranty: **6 years / 6000 hours**

### Current 3630 TX Special Edition manufacturer highlights
- FPT S8000
- Double clutch with independent PTO lever
- 12F+3R UG / 12F+3R Creeper* / 8F+2R UG*
- Sensomatic24
- 2000 kg / 1700 kg* lift
- Lift-O-Matic height limiter
- DRC valve & isolator valve
- ROPS & fibre canopy
- Clear-lens headlamp with DRL signature light
- LED fender lamp
- 2WD and 4WD

### Sources
- Official 3630 TX Super Plus+: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus
- Official 3630 TX Super: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super
- Official 3630 TX Special Edition: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition
- Legacy detailed record: https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus
- Legacy 4WD record: https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd

Verification: **Current family verified by manufacturer; legacy detailed records are variant-specific and must not be combined.**

---

','Engine HP not verified for this exact current variant; do not inherit legacy 55 HP.'),
('NEW_HOLLAND_3630_TX_SUPER','New Holland','3630','3630 TX Super','','tractor','active','{}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition","https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus","https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3630 TX

### Naming note
The historical **3630 TX Plus / 3630 TX Plus+** is now represented by newer current variants on New Holland India''s site, notably:
- **3630 TX Super Plus+ 2WD / 4WD**
- **3630 TX Super**
- **3630 TX Special Edition**

Legacy models should remain in the app for historical invoices, old customer vehicles, and parts lookup.

### Current 3630 TX Super Plus+ manufacturer facts
- Engine: **FPT S8000**
- Double clutch with independent PTO lever
- Gearboxes: **12F+3R UG, 12F+3R Creeper*, 8F+2R UG***
- Sensomatic24 with 24 sensing points
- Lift capacity: **2000 kg / 1700 kg***
- Lift-O-Matic with height limiter
- DRC valve and isolator valve
- Current variants: **2WD and 4WD**

### Cross-checked legacy 3630 TX Plus+ detailed data
- Cylinders: **3**
- HP: **55 HP** in the legacy 3630 TX Plus+ record; other newer 3630 TX records may be 50 HP. Never mix these as one model.
- Engine: **FPT S8000**, turbo-charged in the legacy Plus+ source
- Displacement: **2991 cc** appears in third-party records
- Rated RPM: **2300 RPM** in the legacy 55 HP record
- Clutch: Double clutch with independent PTO clutch lever
- Gearbox: Fully constant mesh / partial synchromesh depending configuration
- Gear speeds: **8F+2R / 12F+3R Creeper / 12F+3R UG**
- PTO: **540 RPM & GSPTO / RPTO**
- Fuel tank: **60 L**
- Lifting capacity: **1700/2000 kg**
- Front tyre: **7.50x16**
- Rear tyre: **16.9x28** on one legacy record; 14.9x28 appears in other variants
- Wheelbase: **~2040–2045 mm depending variant/source**
- Ground clearance: **445 mm**
- Weight: **~2080–2180 kg depending exact variant/source**
- Battery: **88 Ah** in legacy records
- Alternator: **55 A** in legacy records
- Warranty: **6 years / 6000 hours**

### Current 3630 TX Special Edition manufacturer highlights
- FPT S8000
- Double clutch with independent PTO lever
- 12F+3R UG / 12F+3R Creeper* / 8F+2R UG*
- Sensomatic24
- 2000 kg / 1700 kg* lift
- Lift-O-Matic height limiter
- DRC valve & isolator valve
- ROPS & fibre canopy
- Clear-lens headlamp with DRL signature light
- LED fender lamp
- 2WD and 4WD

### Sources
- Official 3630 TX Super Plus+: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus
- Official 3630 TX Super: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super
- Official 3630 TX Special Edition: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition
- Legacy detailed record: https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus
- Legacy 4WD record: https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd

Verification: **Current family verified by manufacturer; legacy detailed records are variant-specific and must not be combined.**

---

','Exact specifications require variant brochure.'),
('NEW_HOLLAND_3630_TX_PLUS_PLUS_LEGACY_55_HP','New Holland','3630','3630 TX Plus+','Legacy 55 HP','tractor','legacy','{"Engine power":"55 HP (legacy source)","Engine":"FPT S8000","Cylinders":3}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition","https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus","https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Legacy variant; secondary-source details','New Holland 3630 TX

### Naming note
The historical **3630 TX Plus / 3630 TX Plus+** is now represented by newer current variants on New Holland India''s site, notably:
- **3630 TX Super Plus+ 2WD / 4WD**
- **3630 TX Super**
- **3630 TX Special Edition**

Legacy models should remain in the app for historical invoices, old customer vehicles, and parts lookup.

### Current 3630 TX Super Plus+ manufacturer facts
- Engine: **FPT S8000**
- Double clutch with independent PTO lever
- Gearboxes: **12F+3R UG, 12F+3R Creeper*, 8F+2R UG***
- Sensomatic24 with 24 sensing points
- Lift capacity: **2000 kg / 1700 kg***
- Lift-O-Matic with height limiter
- DRC valve and isolator valve
- Current variants: **2WD and 4WD**

### Cross-checked legacy 3630 TX Plus+ detailed data
- Cylinders: **3**
- HP: **55 HP** in the legacy 3630 TX Plus+ record; other newer 3630 TX records may be 50 HP. Never mix these as one model.
- Engine: **FPT S8000**, turbo-charged in the legacy Plus+ source
- Displacement: **2991 cc** appears in third-party records
- Rated RPM: **2300 RPM** in the legacy 55 HP record
- Clutch: Double clutch with independent PTO clutch lever
- Gearbox: Fully constant mesh / partial synchromesh depending configuration
- Gear speeds: **8F+2R / 12F+3R Creeper / 12F+3R UG**
- PTO: **540 RPM & GSPTO / RPTO**
- Fuel tank: **60 L**
- Lifting capacity: **1700/2000 kg**
- Front tyre: **7.50x16**
- Rear tyre: **16.9x28** on one legacy record; 14.9x28 appears in other variants
- Wheelbase: **~2040–2045 mm depending variant/source**
- Ground clearance: **445 mm**
- Weight: **~2080–2180 kg depending exact variant/source**
- Battery: **88 Ah** in legacy records
- Alternator: **55 A** in legacy records
- Warranty: **6 years / 6000 hours**

### Current 3630 TX Special Edition manufacturer highlights
- FPT S8000
- Double clutch with independent PTO lever
- 12F+3R UG / 12F+3R Creeper* / 8F+2R UG*
- Sensomatic24
- 2000 kg / 1700 kg* lift
- Lift-O-Matic height limiter
- DRC valve & isolator valve
- ROPS & fibre canopy
- Clear-lens headlamp with DRL signature light
- LED fender lamp
- 2WD and 4WD

### Sources
- Official 3630 TX Super Plus+: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus
- Official 3630 TX Super: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super
- Official 3630 TX Special Edition: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition
- Legacy detailed record: https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus
- Legacy 4WD record: https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd

Verification: **Current family verified by manufacturer; legacy detailed records are variant-specific and must not be combined.**

---

','Legacy specifications from third-party records.'),
('NEW_HOLLAND_3230_TX_2WD','New Holland','3230','3230 TX','2WD','tractor','active','{"Engine power":"42 HP","PTO power":"39 HP","Torque":"166 Nm","Engine":"T-IIIA S 325","Gearbox":"Fully Constant Mesh Side Shift AFD"}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx-super","https://tractorgyan.com/tractor/new-holland-3230-tx/1444"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3230 TX

### Manufacturer-published facts
- Maximum PTO power: **39 HP**
- Maximum torque: **166 Nm**
- Gearbox: **Fully Constant Mesh Side Shift AFD**
- DRC valve with Lift-O-Matic
- Multi-speed and Reverse PTO
- SOFTEK clutch
- Neutral safety switch
- Real OIB / oil-immersed braking system
- Clutch safety lock
- Engine: **T-IIIA, S 325**
- Engine power: **31.32 kW / 42 HP**

### Cross-checked detailed fields
- Cylinders: **3**
- Rated RPM: **2000 RPM**
- Torque: **166 Nm**
- Gearbox: **8F+8R Synchro Shuttle** / side-shift AFD
- PTO: **39 HP**, MultiSpeed & Reverse PTO with independent PTO clutch lever
- Brakes: Oil immersed multi-disc
- Steering: Power steering
- Fuel tank: **42 L**
- Overall length: **3595 mm**
- Overall width: **1790 mm**
- Overall height: **2290 mm**
- Wheelbase: **1920 mm**
- Weight: **1770 kg**
- Ground clearance: **385 mm**
- Lifting capacity: **1800 kg**, Lift-O-Matic
- Tyres: **6x16 front / 13.6x28 rear**
- Drive: **2WD** in the detailed base record
- Warranty: **6 years T-warranty** in third-party current records
- Battery: **75 Ah** and alternator **35 A** in one detailed record

### Current successor / related model
New Holland''s current website also lists **3230 TX Super** (2WD and 4WD), with 45 HP on the current Hindi page and 41 HP PTO headline. Treat it as a separate model/variant, not as the same record.

### Sources
- Official current 3230 TX: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx
- Official 3230 TX Super: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx-super
- Detailed specification record: https://tractorgyan.com/tractor/new-holland-3230-tx/1444

Verification: **Manufacturer verified for current headline values; detailed fields cross-checked.**

---

',''),
('NEW_HOLLAND_3230_TX_SUPER_2WD','New Holland','3230','3230 TX Super','2WD','tractor','active','{"Engine power":"45 HP (current Hindi page cited)","PTO power":"41 HP"}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx-super","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx","https://tractorgyan.com/tractor/new-holland-3230-tx/1444"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3230 TX

### Manufacturer-published facts
- Maximum PTO power: **39 HP**
- Maximum torque: **166 Nm**
- Gearbox: **Fully Constant Mesh Side Shift AFD**
- DRC valve with Lift-O-Matic
- Multi-speed and Reverse PTO
- SOFTEK clutch
- Neutral safety switch
- Real OIB / oil-immersed braking system
- Clutch safety lock
- Engine: **T-IIIA, S 325**
- Engine power: **31.32 kW / 42 HP**

### Cross-checked detailed fields
- Cylinders: **3**
- Rated RPM: **2000 RPM**
- Torque: **166 Nm**
- Gearbox: **8F+8R Synchro Shuttle** / side-shift AFD
- PTO: **39 HP**, MultiSpeed & Reverse PTO with independent PTO clutch lever
- Brakes: Oil immersed multi-disc
- Steering: Power steering
- Fuel tank: **42 L**
- Overall length: **3595 mm**
- Overall width: **1790 mm**
- Overall height: **2290 mm**
- Wheelbase: **1920 mm**
- Weight: **1770 kg**
- Ground clearance: **385 mm**
- Lifting capacity: **1800 kg**, Lift-O-Matic
- Tyres: **6x16 front / 13.6x28 rear**
- Drive: **2WD** in the detailed base record
- Warranty: **6 years T-warranty** in third-party current records
- Battery: **75 Ah** and alternator **35 A** in one detailed record

### Current successor / related model
New Holland''s current website also lists **3230 TX Super** (2WD and 4WD), with 45 HP on the current Hindi page and 41 HP PTO headline. Treat it as a separate model/variant, not as the same record.

### Sources
- Official current 3230 TX: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx
- Official 3230 TX Super: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx-super
- Detailed specification record: https://tractorgyan.com/tractor/new-holland-3230-tx/1444

Verification: **Manufacturer verified for current headline values; detailed fields cross-checked.**

---

','Separate model from the 42 HP 3230 TX.'),
('NEW_HOLLAND_3230_TX_SUPER_4WD','New Holland','3230','3230 TX Super','4WD','tractor','active','{"Engine power":"45 HP (current Hindi page cited)","PTO power":"41 HP"}','["https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx-super","https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx","https://tractorgyan.com/tractor/new-holland-3230-tx/1444"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','New Holland 3230 TX

### Manufacturer-published facts
- Maximum PTO power: **39 HP**
- Maximum torque: **166 Nm**
- Gearbox: **Fully Constant Mesh Side Shift AFD**
- DRC valve with Lift-O-Matic
- Multi-speed and Reverse PTO
- SOFTEK clutch
- Neutral safety switch
- Real OIB / oil-immersed braking system
- Clutch safety lock
- Engine: **T-IIIA, S 325**
- Engine power: **31.32 kW / 42 HP**

### Cross-checked detailed fields
- Cylinders: **3**
- Rated RPM: **2000 RPM**
- Torque: **166 Nm**
- Gearbox: **8F+8R Synchro Shuttle** / side-shift AFD
- PTO: **39 HP**, MultiSpeed & Reverse PTO with independent PTO clutch lever
- Brakes: Oil immersed multi-disc
- Steering: Power steering
- Fuel tank: **42 L**
- Overall length: **3595 mm**
- Overall width: **1790 mm**
- Overall height: **2290 mm**
- Wheelbase: **1920 mm**
- Weight: **1770 kg**
- Ground clearance: **385 mm**
- Lifting capacity: **1800 kg**, Lift-O-Matic
- Tyres: **6x16 front / 13.6x28 rear**
- Drive: **2WD** in the detailed base record
- Warranty: **6 years T-warranty** in third-party current records
- Battery: **75 Ah** and alternator **35 A** in one detailed record

### Current successor / related model
New Holland''s current website also lists **3230 TX Super** (2WD and 4WD), with 45 HP on the current Hindi page and 41 HP PTO headline. Treat it as a separate model/variant, not as the same record.

### Sources
- Official current 3230 TX: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx
- Official 3230 TX Super: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx-super
- Detailed specification record: https://tractorgyan.com/tractor/new-holland-3230-tx/1444

Verification: **Manufacturer verified for current headline values; detailed fields cross-checked.**

---

','Separate model from the 42 HP 3230 TX.'),
('CITYLIFE_XV_850','CityLife','XV-850 / LI-PRIMA','XV-850','','e_rickshaw','active','{"Seating":"Driver + 4 passengers","Approximate load":"400 kg","Battery":"Lead acid, 100–135 Ah","Dimensions":"2770 × 985 × 1730 mm","Wheelbase":"2100 mm","Controller voltage":"48W as published — unverified unit"}','["https://www.citylifeev.com/butterfly2020","https://www.citylifeev.com/","https://www.citylifeev.com/about","https://www.citylifeev.com/electric-vehicles-erickshaw","https://www.citylifeev.com/li-prima2020","https://www.citylifeev.com/butterflydelux","https://www.citylifeev.com/butterflysuperdeluxe","https://www.citylifeev.com/standard","https://www.citylifeev.com/standardplus","https://www.citylifeev.com/schooltype","https://www.citylifeev.com/xv-maxclosedbody","https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications","https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer''s primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

','Performance cross-checks and incomplete units are retained in source notes; verify exact model before quoting.'),
('CITYLIFE_LI_PRIMA_2022','CityLife','XV-850 / LI-PRIMA','LI-PRIMA 2022','','e_rickshaw','active','{"Seating":"Driver + 4 passengers","Approximate load":"400 kg","Battery":"Lead acid, 100–135 Ah","Dimensions":"2770 × 985 × 1730 mm","Wheelbase":"2100 mm","Controller voltage":"48W as published — unverified unit"}','["https://www.citylifeev.com/li-prima2020","https://www.citylifeev.com/","https://www.citylifeev.com/about","https://www.citylifeev.com/electric-vehicles-erickshaw","https://www.citylifeev.com/butterfly2020","https://www.citylifeev.com/butterflydelux","https://www.citylifeev.com/butterflysuperdeluxe","https://www.citylifeev.com/standard","https://www.citylifeev.com/standardplus","https://www.citylifeev.com/schooltype","https://www.citylifeev.com/xv-maxclosedbody","https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications","https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer''s primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

','Performance cross-checks and incomplete units are retained in source notes; verify exact model before quoting.'),
('CITYLIFE_BUTTERFLY_DELUXE_XV_850','CityLife','XV-850 / LI-PRIMA','Butterfly Deluxe XV-850','','e_rickshaw','active','{}','["https://www.citylifeev.com/butterflydelux","https://www.citylifeev.com/","https://www.citylifeev.com/about","https://www.citylifeev.com/electric-vehicles-erickshaw","https://www.citylifeev.com/butterfly2020","https://www.citylifeev.com/li-prima2020","https://www.citylifeev.com/butterflysuperdeluxe","https://www.citylifeev.com/standard","https://www.citylifeev.com/standardplus","https://www.citylifeev.com/schooltype","https://www.citylifeev.com/xv-maxclosedbody","https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications","https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer''s primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

','Performance cross-checks and incomplete units are retained in source notes; verify exact model before quoting.'),
('CITYLIFE_BUTTERFLY_SUPER_DELUXE_XV_850','CityLife','XV-850 / LI-PRIMA','Butterfly Super Deluxe XV-850','','e_rickshaw','active','{}','["https://www.citylifeev.com/butterflysuperdeluxe","https://www.citylifeev.com/","https://www.citylifeev.com/about","https://www.citylifeev.com/electric-vehicles-erickshaw","https://www.citylifeev.com/butterfly2020","https://www.citylifeev.com/li-prima2020","https://www.citylifeev.com/butterflydelux","https://www.citylifeev.com/standard","https://www.citylifeev.com/standardplus","https://www.citylifeev.com/schooltype","https://www.citylifeev.com/xv-maxclosedbody","https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications","https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer''s primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

','Performance cross-checks and incomplete units are retained in source notes; verify exact model before quoting.'),
('CITYLIFE_STANDARD_XV_850','CityLife','XV-850 / LI-PRIMA','Standard XV-850','','e_rickshaw','active','{}','["https://www.citylifeev.com/standard","https://www.citylifeev.com/","https://www.citylifeev.com/about","https://www.citylifeev.com/electric-vehicles-erickshaw","https://www.citylifeev.com/butterfly2020","https://www.citylifeev.com/li-prima2020","https://www.citylifeev.com/butterflydelux","https://www.citylifeev.com/butterflysuperdeluxe","https://www.citylifeev.com/standardplus","https://www.citylifeev.com/schooltype","https://www.citylifeev.com/xv-maxclosedbody","https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications","https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer''s primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

','Performance cross-checks and incomplete units are retained in source notes; verify exact model before quoting.'),
('CITYLIFE_STANDARD_PLUS_XV_850','CityLife','XV-850 / LI-PRIMA','Standard+ XV-850','','e_rickshaw','active','{}','["https://www.citylifeev.com/standardplus","https://www.citylifeev.com/","https://www.citylifeev.com/about","https://www.citylifeev.com/electric-vehicles-erickshaw","https://www.citylifeev.com/butterfly2020","https://www.citylifeev.com/li-prima2020","https://www.citylifeev.com/butterflydelux","https://www.citylifeev.com/butterflysuperdeluxe","https://www.citylifeev.com/standard","https://www.citylifeev.com/schooltype","https://www.citylifeev.com/xv-maxclosedbody","https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications","https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer''s primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

','Performance cross-checks and incomplete units are retained in source notes; verify exact model before quoting.'),
('CITYLIFE_SCHOOL_TYPE_XV_850','CityLife','XV-850 / LI-PRIMA','School Type XV-850','','e_rickshaw','active','{}','["https://www.citylifeev.com/schooltype","https://www.citylifeev.com/","https://www.citylifeev.com/about","https://www.citylifeev.com/electric-vehicles-erickshaw","https://www.citylifeev.com/butterfly2020","https://www.citylifeev.com/li-prima2020","https://www.citylifeev.com/butterflydelux","https://www.citylifeev.com/butterflysuperdeluxe","https://www.citylifeev.com/standard","https://www.citylifeev.com/standardplus","https://www.citylifeev.com/xv-maxclosedbody","https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications","https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer''s primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

','Performance cross-checks and incomplete units are retained in source notes; verify exact model before quoting.'),
('CITYLIFE_LOADER_XV_MAX','CityLife','Loader','Loader XV-MAX','','e_rickshaw','active','{}','["https://www.citylifeev.com/electric-vehicles-erickshaw","https://www.citylifeev.com/","https://www.citylifeev.com/about","https://www.citylifeev.com/butterfly2020","https://www.citylifeev.com/li-prima2020","https://www.citylifeev.com/butterflydelux","https://www.citylifeev.com/butterflysuperdeluxe","https://www.citylifeev.com/standard","https://www.citylifeev.com/standardplus","https://www.citylifeev.com/schooltype","https://www.citylifeev.com/xv-maxclosedbody","https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications","https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Model range verified; exact specifications require verification','CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer''s primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

','Model listing only. Loader seating/payload claims in source require exact-variant confirmation.'),
('CITYLIFE_OPEN_BODY_LOADER_XV_MAX','CityLife','Loader','Open Body Loader XV-MAX','','e_rickshaw','active','{}','["https://www.citylifeev.com/electric-vehicles-erickshaw","https://www.citylifeev.com/","https://www.citylifeev.com/about","https://www.citylifeev.com/butterfly2020","https://www.citylifeev.com/li-prima2020","https://www.citylifeev.com/butterflydelux","https://www.citylifeev.com/butterflysuperdeluxe","https://www.citylifeev.com/standard","https://www.citylifeev.com/standardplus","https://www.citylifeev.com/schooltype","https://www.citylifeev.com/xv-maxclosedbody","https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications","https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Model range verified; exact specifications require verification','CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer''s primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

','Model listing only. Loader seating/payload claims in source require exact-variant confirmation.'),
('CITYLIFE_CLOSED_BODY_LOADER_LI_MAX','CityLife','Loader','Closed Body Loader LI-MAX','','e_rickshaw','active','{}','["https://www.citylifeev.com/xv-maxclosedbody","https://www.citylifeev.com/","https://www.citylifeev.com/about","https://www.citylifeev.com/electric-vehicles-erickshaw","https://www.citylifeev.com/butterfly2020","https://www.citylifeev.com/li-prima2020","https://www.citylifeev.com/butterflydelux","https://www.citylifeev.com/butterflysuperdeluxe","https://www.citylifeev.com/standard","https://www.citylifeev.com/standardplus","https://www.citylifeev.com/schooltype","https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications","https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Model range verified; exact specifications require verification','CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer''s primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

','Model listing only. Loader seating/payload claims in source require exact-variant confirmation.'),
('CITYLIFE_CLOSED_BODY_LOADER_XV_MAX','CityLife','Loader','Closed Body Loader XV-MAX','','e_rickshaw','active','{}','["https://www.citylifeev.com/electric-vehicles-erickshaw","https://www.citylifeev.com/","https://www.citylifeev.com/about","https://www.citylifeev.com/butterfly2020","https://www.citylifeev.com/li-prima2020","https://www.citylifeev.com/butterflydelux","https://www.citylifeev.com/butterflysuperdeluxe","https://www.citylifeev.com/standard","https://www.citylifeev.com/standardplus","https://www.citylifeev.com/schooltype","https://www.citylifeev.com/xv-maxclosedbody","https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications","https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Model range verified; exact specifications require verification','CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer''s primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

','Model listing only. Loader seating/payload claims in source require exact-variant confirmation.'),
('CITYLIFE_GARBAGE_LOADER_XV_MAX','CityLife','Loader','Garbage Loader XV MAX','','e_rickshaw','active','{}','["https://www.citylifeev.com/electric-vehicles-erickshaw","https://www.citylifeev.com/","https://www.citylifeev.com/about","https://www.citylifeev.com/butterfly2020","https://www.citylifeev.com/li-prima2020","https://www.citylifeev.com/butterflydelux","https://www.citylifeev.com/butterflysuperdeluxe","https://www.citylifeev.com/standard","https://www.citylifeev.com/standardplus","https://www.citylifeev.com/schooltype","https://www.citylifeev.com/xv-maxclosedbody","https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications","https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications","https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Model range verified; exact specifications require verification','CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer''s primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

','Model listing only. Loader seating/payload claims in source require exact-variant confirmation.'),
('GREAVES_ELTRA_CITY_XTRA_CURRENT_PASSENGER','Greaves','Eltra','Eltra City XTRA','Current passenger','e_rickshaw','active','{"True range":"Up to 170 km","Top speed":"60 km/h in Power Mode","Battery":"10.75 kWh LFP","Motor":"9.5 kW PMS","Battery warranty":"5 years","0–30 km/h":"6.4 seconds"}','["https://3wheelers.greaveselectricmobility.com/eltra","https://3wheelers.greaveselectricmobility.com/","https://greaveselectricmobility.com/press-release/greaves-electric-mobility-rolls-out-festive-offers-across-india-for-nexus-and-magnus-neo","https://greaveselectricmobility.com/press-release/greaves-electric-mobility-s-newly-launched-eltra-city-xtra-does-the-unbelievable-324-km-on-a-single-charge-sets-new-national-record","https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','GREAVES ELECTRIC 3-WHEELERS

Manufacturer: **Greaves Electric Mobility Limited**
Official 3W site: https://3wheelers.greaveselectricmobility.com/

## 3.1 Greaves Eltra City XTRA — current electric passenger model

### Manufacturer-published current facts
- Variant: **Eltra City XTRA**
- True range: **up to 170 km** (manufacturer press release)
- Top speed: **60 km/h in Power Mode**
- Battery: **10.75 kWh LFP** according to current manufacturer product page/press material
- Motor: **9.5 kW PMS motor**
- 0–30 km/h: **6.4 seconds** (manufacturer product page)
- Digital cluster: **6.2-inch PMVA digital cluster** with DTE/navigation
- Mobile application / fleet management / remote diagnostics are marketed features
- Battery warranty: **5 years** advertised for the Eltra City XTRA
- Greaves 3W claims a national record of **324 km** on a single charge for a record-setting run; this is a record demonstration, **not the normal rated range**, and must never be shown in the app as customer range.
- Launch price announcement: **₹3,57,000 onwards** in the 17 October 2025 announcement. Do not use as today''s OM Motors selling price.

### General Eltra family data from manufacturer brochure/current product page
- Peak power: **9.5 kW**
- Max torque: **49 Nm**
- Gearbox: **Single speed**
- Earlier brochure range: **105 km** for the Eltra family, while the current Eltra City XTRA is rated higher. Store each generation separately.
- Different Eltra cargo variants have different payloads; do not apply cargo payload to the passenger City variant.

### Current product page technical data exposed in the page for Eltra variants
The current Eltra page contains variant-level data including:
- Battery type: **LFP**
- Battery voltage: **51.2 V**
- Peak power: **9.5 kW**
- Charger: **2 kW**
- Transmission: **Single**
- Typical charging time on listed variants: **5–6 hours**
- Hydraulic drum brakes / drum depending variant
- Passenger/cargo variants have different dimensions, kerb weight and payload; use the exact sub-variant record.

### Sources
- Current Eltra page: https://3wheelers.greaveselectricmobility.com/eltra
- Greaves official press release (17 Aug 2026): https://greaveselectricmobility.com/press-release/greaves-electric-mobility-rolls-out-festive-offers-across-india-for-nexus-and-magnus-neo
- Greaves record announcement: https://greaveselectricmobility.com/press-release/greaves-electric-mobility-s-newly-launched-eltra-city-xtra-does-the-unbelievable-324-km-on-a-single-charge-sets-new-national-record
- Older official brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf

Verification: **Manufacturer verified.**

---

','The 324 km demonstration is not normal range. Launch price is not a dealership selling price.'),
('GREAVES_ELTRA_EARLIER_GENERATION','Greaves','Eltra','Eltra','Earlier generation','e_rickshaw','legacy','{"Brochure range":"105 km","Peak power":"9.5 kW","Torque":"49 Nm","Transmission":"Single speed"}','["https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf","https://3wheelers.greaveselectricmobility.com/","https://3wheelers.greaveselectricmobility.com/eltra","https://greaveselectricmobility.com/press-release/greaves-electric-mobility-rolls-out-festive-offers-across-india-for-nexus-and-magnus-neo","https://greaveselectricmobility.com/press-release/greaves-electric-mobility-s-newly-launched-eltra-city-xtra-does-the-unbelievable-324-km-on-a-single-charge-sets-new-national-record"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','GREAVES ELECTRIC 3-WHEELERS

Manufacturer: **Greaves Electric Mobility Limited**
Official 3W site: https://3wheelers.greaveselectricmobility.com/

## 3.1 Greaves Eltra City XTRA — current electric passenger model

### Manufacturer-published current facts
- Variant: **Eltra City XTRA**
- True range: **up to 170 km** (manufacturer press release)
- Top speed: **60 km/h in Power Mode**
- Battery: **10.75 kWh LFP** according to current manufacturer product page/press material
- Motor: **9.5 kW PMS motor**
- 0–30 km/h: **6.4 seconds** (manufacturer product page)
- Digital cluster: **6.2-inch PMVA digital cluster** with DTE/navigation
- Mobile application / fleet management / remote diagnostics are marketed features
- Battery warranty: **5 years** advertised for the Eltra City XTRA
- Greaves 3W claims a national record of **324 km** on a single charge for a record-setting run; this is a record demonstration, **not the normal rated range**, and must never be shown in the app as customer range.
- Launch price announcement: **₹3,57,000 onwards** in the 17 October 2025 announcement. Do not use as today''s OM Motors selling price.

### General Eltra family data from manufacturer brochure/current product page
- Peak power: **9.5 kW**
- Max torque: **49 Nm**
- Gearbox: **Single speed**
- Earlier brochure range: **105 km** for the Eltra family, while the current Eltra City XTRA is rated higher. Store each generation separately.
- Different Eltra cargo variants have different payloads; do not apply cargo payload to the passenger City variant.

### Current product page technical data exposed in the page for Eltra variants
The current Eltra page contains variant-level data including:
- Battery type: **LFP**
- Battery voltage: **51.2 V**
- Peak power: **9.5 kW**
- Charger: **2 kW**
- Transmission: **Single**
- Typical charging time on listed variants: **5–6 hours**
- Hydraulic drum brakes / drum depending variant
- Passenger/cargo variants have different dimensions, kerb weight and payload; use the exact sub-variant record.

### Sources
- Current Eltra page: https://3wheelers.greaveselectricmobility.com/eltra
- Greaves official press release (17 Aug 2026): https://greaveselectricmobility.com/press-release/greaves-electric-mobility-rolls-out-festive-offers-across-india-for-nexus-and-magnus-neo
- Greaves record announcement: https://greaveselectricmobility.com/press-release/greaves-electric-mobility-s-newly-launched-eltra-city-xtra-does-the-unbelievable-324-km-on-a-single-charge-sets-new-national-record
- Older official brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf

Verification: **Manufacturer verified.**

---

','Historical family record; do not combine with City XTRA.'),
('GREAVES_TEJA_SUPER_CITY_EX','Greaves','Teja','Teja Super City EX','','cng_rickshaw','active','{"Engine":"395 cc water-cooled single-cylinder","Power":"7.25 kW","Torque":"24.5 Nm","Claimed mileage":"39 km/kg*","Gearbox":"4F+1R","Wheelbase":"1930 mm","Warranty":"36 months / 1 lakh km*","Payload":"334 kg","Dimensions":"2950 × 1500 × 1988 mm","Kerb weight":"507 kg","GVW":"841 kg"}','["https://3wheelers.greaveselectricmobility.com/download-brochure","https://ampere.sgp1.cdn.digitaloceanspaces.com/website/brochure/L5%20Combined%20Leaflet%20-%2025-09.pdf","https://www.scribd.com/document/972843733/Greaves-CNG-Teja-NEW-Super-Cargo-LB","https://vardhmanauto.com/greaves-teja-cng-passenger/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','GREAVES CNG 3-WHEELERS

Current Greaves official brochure page lists the following CNG variants in its range:
- **Teja Super City EX**
- **Teja Super City**
- **Teja Super Cargo LB**
- **Teja Super Cargo**

## 4.1 Teja Super City EX — passenger CNG
### Manufacturer brochure / current product material
- Engine: **395 cc, 4S-SI, single-cylinder, water-cooled**
- Engine power: **7.25 kW**
- Maximum torque: **24.5 Nm**
- Claimed mileage: **39 km/kg***
- Fuel tank: **CNG 40 L + petrol 3 L**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- Gradeability: **18% / 10.2°**
- Wheelbase: **1930 mm** in the current combined brochure
- Tyre: **120/80 R12 tubeless**
- Payload: **334 kg**
- Warranty: **36 months / 1 lakh km***
- Current combined leaflet dimensions for Teja Super City EX: **2950 x 1500 x 1988 mm**
- Current combined leaflet kerb weight: **507 kg**
- Current combined leaflet GVW: **841 kg**

### Important source conflict
A dealer/third-party page published **2980 x 1500 x 1988 mm**, wheelbase **1890 mm**, kerb **267 kg**, GVW **601 kg**, which conflicts materially with the newer Greaves combined brochure. For the app, use the **newer manufacturer brochure values** and retain the third-party values only in source history.

## 4.2 Teja Super City — passenger CNG
Current Greaves combined brochure lists:
- Engine: **395 cc, 4S-SI, single-cylinder, water cooled**
- Power: **7.25 kW**
- Torque: **24.5 Nm**
- Mileage: **39 km/kg***
- Fuel tank: **CNG 40 L + petrol 3 L**
- Wheelbase: **1930 mm**
- Gradeability: **18% / 10.2°**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- GVW: **839 kg**
- Kerb: **509 kg**
- Payload: **330 kg**
- Tyre: **120/80 R12 tubeless**
- Warranty: **36 months / 1 lakh km***
- Dimensions: **2950 x 1484 x 1833 mm**

## 4.3 Teja Super Cargo LB
A Greaves brochure record gives:
- Engine: **395 cc, 4S-SI, single-cylinder, water cooled**
- Power: **7.25 kW**
- Torque: **24.5 Nm**
- Claimed mileage: **37 km/kg***
- Wheelbase: **2100 mm**
- Gradeability: **18% / 10.2°**
- Fuel tank: **40 L CNG**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- GVW: **997 kg**
- Kerb weight: **523 kg**
- Payload: **474+ kg** in the brochure record; another textual summary says 483 kg. Store **474+ kg** as the exact brochure field and flag payload summary conflicts for dealer verification.
- Tyre: **120/80 R12 tubeless**
- Deck length: **6 ft**
- Cargo box: **1896 x 1472 x 364 mm**
- Warranty: **36 months / 1 lakh km***

### Sources
- Current Greaves 3W brochure page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Combined 2025 leaflet: https://ampere.sgp1.cdn.digitaloceanspaces.com/website/brochure/L5%20Combined%20Leaflet%20-%2025-09.pdf
- Teja Super Cargo LB source record: https://www.scribd.com/document/972843733/Greaves-CNG-Teja-NEW-Super-Cargo-LB
- Teja passenger cross-check: https://vardhmanauto.com/greaves-teja-cng-passenger/

Verification: **Manufacturer brochure verified for core fields; older dealer records contain conflicts and should not overwrite current manufacturer data.**

---

','Use current manufacturer brochure values; conflicting older dealer claims remain in source history.'),
('GREAVES_TEJA_SUPER_CITY','Greaves','Teja','Teja Super City','','cng_rickshaw','active','{"Engine":"395 cc water-cooled single-cylinder","Power":"7.25 kW","Torque":"24.5 Nm","Claimed mileage":"39 km/kg*","Gearbox":"4F+1R","Wheelbase":"1930 mm","Warranty":"36 months / 1 lakh km*","Payload":"330 kg","Dimensions":"2950 × 1484 × 1833 mm","Kerb weight":"509 kg","GVW":"839 kg"}','["https://3wheelers.greaveselectricmobility.com/download-brochure","https://ampere.sgp1.cdn.digitaloceanspaces.com/website/brochure/L5%20Combined%20Leaflet%20-%2025-09.pdf","https://www.scribd.com/document/972843733/Greaves-CNG-Teja-NEW-Super-Cargo-LB","https://vardhmanauto.com/greaves-teja-cng-passenger/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','GREAVES CNG 3-WHEELERS

Current Greaves official brochure page lists the following CNG variants in its range:
- **Teja Super City EX**
- **Teja Super City**
- **Teja Super Cargo LB**
- **Teja Super Cargo**

## 4.1 Teja Super City EX — passenger CNG
### Manufacturer brochure / current product material
- Engine: **395 cc, 4S-SI, single-cylinder, water-cooled**
- Engine power: **7.25 kW**
- Maximum torque: **24.5 Nm**
- Claimed mileage: **39 km/kg***
- Fuel tank: **CNG 40 L + petrol 3 L**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- Gradeability: **18% / 10.2°**
- Wheelbase: **1930 mm** in the current combined brochure
- Tyre: **120/80 R12 tubeless**
- Payload: **334 kg**
- Warranty: **36 months / 1 lakh km***
- Current combined leaflet dimensions for Teja Super City EX: **2950 x 1500 x 1988 mm**
- Current combined leaflet kerb weight: **507 kg**
- Current combined leaflet GVW: **841 kg**

### Important source conflict
A dealer/third-party page published **2980 x 1500 x 1988 mm**, wheelbase **1890 mm**, kerb **267 kg**, GVW **601 kg**, which conflicts materially with the newer Greaves combined brochure. For the app, use the **newer manufacturer brochure values** and retain the third-party values only in source history.

## 4.2 Teja Super City — passenger CNG
Current Greaves combined brochure lists:
- Engine: **395 cc, 4S-SI, single-cylinder, water cooled**
- Power: **7.25 kW**
- Torque: **24.5 Nm**
- Mileage: **39 km/kg***
- Fuel tank: **CNG 40 L + petrol 3 L**
- Wheelbase: **1930 mm**
- Gradeability: **18% / 10.2°**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- GVW: **839 kg**
- Kerb: **509 kg**
- Payload: **330 kg**
- Tyre: **120/80 R12 tubeless**
- Warranty: **36 months / 1 lakh km***
- Dimensions: **2950 x 1484 x 1833 mm**

## 4.3 Teja Super Cargo LB
A Greaves brochure record gives:
- Engine: **395 cc, 4S-SI, single-cylinder, water cooled**
- Power: **7.25 kW**
- Torque: **24.5 Nm**
- Claimed mileage: **37 km/kg***
- Wheelbase: **2100 mm**
- Gradeability: **18% / 10.2°**
- Fuel tank: **40 L CNG**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- GVW: **997 kg**
- Kerb weight: **523 kg**
- Payload: **474+ kg** in the brochure record; another textual summary says 483 kg. Store **474+ kg** as the exact brochure field and flag payload summary conflicts for dealer verification.
- Tyre: **120/80 R12 tubeless**
- Deck length: **6 ft**
- Cargo box: **1896 x 1472 x 364 mm**
- Warranty: **36 months / 1 lakh km***

### Sources
- Current Greaves 3W brochure page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Combined 2025 leaflet: https://ampere.sgp1.cdn.digitaloceanspaces.com/website/brochure/L5%20Combined%20Leaflet%20-%2025-09.pdf
- Teja Super Cargo LB source record: https://www.scribd.com/document/972843733/Greaves-CNG-Teja-NEW-Super-Cargo-LB
- Teja passenger cross-check: https://vardhmanauto.com/greaves-teja-cng-passenger/

Verification: **Manufacturer brochure verified for core fields; older dealer records contain conflicts and should not overwrite current manufacturer data.**

---

','Use current manufacturer brochure values; conflicting older dealer claims remain in source history.'),
('GREAVES_TEJA_SUPER_CARGO_LB','Greaves','Teja','Teja Super Cargo LB','','cng_rickshaw','active','{"Engine":"395 cc","Power":"7.25 kW","Torque":"24.5 Nm","Payload":"474+ kg (brochure); conflicting summary 483 kg","Wheelbase":"2100 mm","Deck":"6 ft","Warranty":"36 months / 1 lakh km*"}','["https://3wheelers.greaveselectricmobility.com/download-brochure","https://ampere.sgp1.cdn.digitaloceanspaces.com/website/brochure/L5%20Combined%20Leaflet%20-%2025-09.pdf","https://www.scribd.com/document/972843733/Greaves-CNG-Teja-NEW-Super-Cargo-LB","https://vardhmanauto.com/greaves-teja-cng-passenger/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','GREAVES CNG 3-WHEELERS

Current Greaves official brochure page lists the following CNG variants in its range:
- **Teja Super City EX**
- **Teja Super City**
- **Teja Super Cargo LB**
- **Teja Super Cargo**

## 4.1 Teja Super City EX — passenger CNG
### Manufacturer brochure / current product material
- Engine: **395 cc, 4S-SI, single-cylinder, water-cooled**
- Engine power: **7.25 kW**
- Maximum torque: **24.5 Nm**
- Claimed mileage: **39 km/kg***
- Fuel tank: **CNG 40 L + petrol 3 L**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- Gradeability: **18% / 10.2°**
- Wheelbase: **1930 mm** in the current combined brochure
- Tyre: **120/80 R12 tubeless**
- Payload: **334 kg**
- Warranty: **36 months / 1 lakh km***
- Current combined leaflet dimensions for Teja Super City EX: **2950 x 1500 x 1988 mm**
- Current combined leaflet kerb weight: **507 kg**
- Current combined leaflet GVW: **841 kg**

### Important source conflict
A dealer/third-party page published **2980 x 1500 x 1988 mm**, wheelbase **1890 mm**, kerb **267 kg**, GVW **601 kg**, which conflicts materially with the newer Greaves combined brochure. For the app, use the **newer manufacturer brochure values** and retain the third-party values only in source history.

## 4.2 Teja Super City — passenger CNG
Current Greaves combined brochure lists:
- Engine: **395 cc, 4S-SI, single-cylinder, water cooled**
- Power: **7.25 kW**
- Torque: **24.5 Nm**
- Mileage: **39 km/kg***
- Fuel tank: **CNG 40 L + petrol 3 L**
- Wheelbase: **1930 mm**
- Gradeability: **18% / 10.2°**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- GVW: **839 kg**
- Kerb: **509 kg**
- Payload: **330 kg**
- Tyre: **120/80 R12 tubeless**
- Warranty: **36 months / 1 lakh km***
- Dimensions: **2950 x 1484 x 1833 mm**

## 4.3 Teja Super Cargo LB
A Greaves brochure record gives:
- Engine: **395 cc, 4S-SI, single-cylinder, water cooled**
- Power: **7.25 kW**
- Torque: **24.5 Nm**
- Claimed mileage: **37 km/kg***
- Wheelbase: **2100 mm**
- Gradeability: **18% / 10.2°**
- Fuel tank: **40 L CNG**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- GVW: **997 kg**
- Kerb weight: **523 kg**
- Payload: **474+ kg** in the brochure record; another textual summary says 483 kg. Store **474+ kg** as the exact brochure field and flag payload summary conflicts for dealer verification.
- Tyre: **120/80 R12 tubeless**
- Deck length: **6 ft**
- Cargo box: **1896 x 1472 x 364 mm**
- Warranty: **36 months / 1 lakh km***

### Sources
- Current Greaves 3W brochure page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Combined 2025 leaflet: https://ampere.sgp1.cdn.digitaloceanspaces.com/website/brochure/L5%20Combined%20Leaflet%20-%2025-09.pdf
- Teja Super Cargo LB source record: https://www.scribd.com/document/972843733/Greaves-CNG-Teja-NEW-Super-Cargo-LB
- Teja passenger cross-check: https://vardhmanauto.com/greaves-teja-cng-passenger/

Verification: **Manufacturer brochure verified for core fields; older dealer records contain conflicts and should not overwrite current manufacturer data.**

---

','Payload conflict requires dealer verification.'),
('GREAVES_TEJA_SUPER_CARGO','Greaves','Teja','Teja Super Cargo','','cng_rickshaw','active','{}','["https://3wheelers.greaveselectricmobility.com/download-brochure","https://ampere.sgp1.cdn.digitaloceanspaces.com/website/brochure/L5%20Combined%20Leaflet%20-%2025-09.pdf","https://www.scribd.com/document/972843733/Greaves-CNG-Teja-NEW-Super-Cargo-LB","https://vardhmanauto.com/greaves-teja-cng-passenger/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','GREAVES CNG 3-WHEELERS

Current Greaves official brochure page lists the following CNG variants in its range:
- **Teja Super City EX**
- **Teja Super City**
- **Teja Super Cargo LB**
- **Teja Super Cargo**

## 4.1 Teja Super City EX — passenger CNG
### Manufacturer brochure / current product material
- Engine: **395 cc, 4S-SI, single-cylinder, water-cooled**
- Engine power: **7.25 kW**
- Maximum torque: **24.5 Nm**
- Claimed mileage: **39 km/kg***
- Fuel tank: **CNG 40 L + petrol 3 L**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- Gradeability: **18% / 10.2°**
- Wheelbase: **1930 mm** in the current combined brochure
- Tyre: **120/80 R12 tubeless**
- Payload: **334 kg**
- Warranty: **36 months / 1 lakh km***
- Current combined leaflet dimensions for Teja Super City EX: **2950 x 1500 x 1988 mm**
- Current combined leaflet kerb weight: **507 kg**
- Current combined leaflet GVW: **841 kg**

### Important source conflict
A dealer/third-party page published **2980 x 1500 x 1988 mm**, wheelbase **1890 mm**, kerb **267 kg**, GVW **601 kg**, which conflicts materially with the newer Greaves combined brochure. For the app, use the **newer manufacturer brochure values** and retain the third-party values only in source history.

## 4.2 Teja Super City — passenger CNG
Current Greaves combined brochure lists:
- Engine: **395 cc, 4S-SI, single-cylinder, water cooled**
- Power: **7.25 kW**
- Torque: **24.5 Nm**
- Mileage: **39 km/kg***
- Fuel tank: **CNG 40 L + petrol 3 L**
- Wheelbase: **1930 mm**
- Gradeability: **18% / 10.2°**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- GVW: **839 kg**
- Kerb: **509 kg**
- Payload: **330 kg**
- Tyre: **120/80 R12 tubeless**
- Warranty: **36 months / 1 lakh km***
- Dimensions: **2950 x 1484 x 1833 mm**

## 4.3 Teja Super Cargo LB
A Greaves brochure record gives:
- Engine: **395 cc, 4S-SI, single-cylinder, water cooled**
- Power: **7.25 kW**
- Torque: **24.5 Nm**
- Claimed mileage: **37 km/kg***
- Wheelbase: **2100 mm**
- Gradeability: **18% / 10.2°**
- Fuel tank: **40 L CNG**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- GVW: **997 kg**
- Kerb weight: **523 kg**
- Payload: **474+ kg** in the brochure record; another textual summary says 483 kg. Store **474+ kg** as the exact brochure field and flag payload summary conflicts for dealer verification.
- Tyre: **120/80 R12 tubeless**
- Deck length: **6 ft**
- Cargo box: **1896 x 1472 x 364 mm**
- Warranty: **36 months / 1 lakh km***

### Sources
- Current Greaves 3W brochure page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Combined 2025 leaflet: https://ampere.sgp1.cdn.digitaloceanspaces.com/website/brochure/L5%20Combined%20Leaflet%20-%2025-09.pdf
- Teja Super Cargo LB source record: https://www.scribd.com/document/972843733/Greaves-CNG-Teja-NEW-Super-Cargo-LB
- Teja passenger cross-check: https://vardhmanauto.com/greaves-teja-cng-passenger/

Verification: **Manufacturer brochure verified for core fields; older dealer records contain conflicts and should not overwrite current manufacturer data.**

---

','Model listing only; exact specifications not verified.'),
('GREAVES_D435_SUPER_CITY_EX_CURRENT_RANGE','Greaves','D435','D435 Super City EX','Current range','diesel_rickshaw','active','{}','["https://3wheelers.greaveselectricmobility.com/download-brochure","https://3wheelers.greaveselectricmobility.com/","https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf","https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf","https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Range listing verified; exact variant specifications require verification','GREAVES DIESEL 3-WHEELERS

Current Greaves brochure page lists:
- D435 Super City EX
- D435 City EX
- D435 Super Cargo LB
- D435 Cargo LB
- D435 Super Cargo

## 5.1 D435 Passenger / D435 City family
Cross-checked published data for the D435 passenger/city family:
- Engine: **435 cc, single-cylinder diesel**
- Max power: **5.7 kW @ 3600 RPM**
- Max torque: **19 Nm @ 2200–2400 RPM**
- Gears: **4 forward + 1 reverse**
- Fuel tank: **10.5 L**
- Top speed: **55 km/h**
- D435 Passenger kerb weight: **456 kg** in the official/Greaves brochure source
- Passenger D435 GVW: **786 kg** in the official brochure source
- Passenger payload: **330 kg** in the official brochure source

### D435 City EX current market cross-check
A current market record for D435 City reports:
- Power: **7.6 HP**
- GVW: **786 kg**
- Wheelbase: **1930 mm**
- Fuel tank: **10.5 L**
- Payload: **330 kg**
- Mileage: **20–25 km/l** (third-party claim; do not present as Greaves official mileage)

Use the exact Greaves variant/brochure for your dealership inventory record.

## 5.2 D435 Cargo / Super Cargo
Greaves'' older official all-brochure record includes a D435 cargo variant with:
- Engine: **435 cc single-cylinder diesel, air cooled**
- Power: **5.7 kW @ 3600 RPM**
- Torque: **19 Nm @ 2200–2400 RPM**
- Gear: **4F+1R**
- GVW: **997 kg**
- Payload: **462 kg**
- Max speed: **45 km/h**
- Fuel tank: **10.5 L**

A newer D435 Super Cargo LB may differ. Record it as a separate variant rather than inheriting these values.

## 5.3 Greaves D599+ Diesel variants
The manufacturer brochure/search material also records D599+:

### Passenger
- Engine: **599 cc, single-cylinder diesel, water cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **790 kg**
- Payload: **310 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Pickup/Cargo
- Engine: **599 cc, single-cylinder diesel, air cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **980 kg**
- Payload: **500 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Sources
- Greaves current 3W range: https://3wheelers.greaveselectricmobility.com/
- Current brochure download page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Official all-brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf
- D435 passenger brochure record: https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf
- D435 City third-party cross-check: https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/

Verification: **Core D435/D599 data sourced from Greaves brochure material; current Super variants need exact dealer/OEM brochure attachment before final stock/master-data publication.**

---

','Do not inherit older D435 family specifications without exact-variant verification.'),
('GREAVES_D435_CITY_EX_CURRENT_RANGE','Greaves','D435','D435 City EX','Current range','diesel_rickshaw','active','{}','["https://3wheelers.greaveselectricmobility.com/download-brochure","https://3wheelers.greaveselectricmobility.com/","https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf","https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf","https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Range listing verified; exact variant specifications require verification','GREAVES DIESEL 3-WHEELERS

Current Greaves brochure page lists:
- D435 Super City EX
- D435 City EX
- D435 Super Cargo LB
- D435 Cargo LB
- D435 Super Cargo

## 5.1 D435 Passenger / D435 City family
Cross-checked published data for the D435 passenger/city family:
- Engine: **435 cc, single-cylinder diesel**
- Max power: **5.7 kW @ 3600 RPM**
- Max torque: **19 Nm @ 2200–2400 RPM**
- Gears: **4 forward + 1 reverse**
- Fuel tank: **10.5 L**
- Top speed: **55 km/h**
- D435 Passenger kerb weight: **456 kg** in the official/Greaves brochure source
- Passenger D435 GVW: **786 kg** in the official brochure source
- Passenger payload: **330 kg** in the official brochure source

### D435 City EX current market cross-check
A current market record for D435 City reports:
- Power: **7.6 HP**
- GVW: **786 kg**
- Wheelbase: **1930 mm**
- Fuel tank: **10.5 L**
- Payload: **330 kg**
- Mileage: **20–25 km/l** (third-party claim; do not present as Greaves official mileage)

Use the exact Greaves variant/brochure for your dealership inventory record.

## 5.2 D435 Cargo / Super Cargo
Greaves'' older official all-brochure record includes a D435 cargo variant with:
- Engine: **435 cc single-cylinder diesel, air cooled**
- Power: **5.7 kW @ 3600 RPM**
- Torque: **19 Nm @ 2200–2400 RPM**
- Gear: **4F+1R**
- GVW: **997 kg**
- Payload: **462 kg**
- Max speed: **45 km/h**
- Fuel tank: **10.5 L**

A newer D435 Super Cargo LB may differ. Record it as a separate variant rather than inheriting these values.

## 5.3 Greaves D599+ Diesel variants
The manufacturer brochure/search material also records D599+:

### Passenger
- Engine: **599 cc, single-cylinder diesel, water cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **790 kg**
- Payload: **310 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Pickup/Cargo
- Engine: **599 cc, single-cylinder diesel, air cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **980 kg**
- Payload: **500 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Sources
- Greaves current 3W range: https://3wheelers.greaveselectricmobility.com/
- Current brochure download page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Official all-brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf
- D435 passenger brochure record: https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf
- D435 City third-party cross-check: https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/

Verification: **Core D435/D599 data sourced from Greaves brochure material; current Super variants need exact dealer/OEM brochure attachment before final stock/master-data publication.**

---

','Do not inherit older D435 family specifications without exact-variant verification.'),
('GREAVES_D435_SUPER_CARGO_LB_CURRENT_RANGE','Greaves','D435','D435 Super Cargo LB','Current range','diesel_rickshaw','active','{}','["https://3wheelers.greaveselectricmobility.com/download-brochure","https://3wheelers.greaveselectricmobility.com/","https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf","https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf","https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Range listing verified; exact variant specifications require verification','GREAVES DIESEL 3-WHEELERS

Current Greaves brochure page lists:
- D435 Super City EX
- D435 City EX
- D435 Super Cargo LB
- D435 Cargo LB
- D435 Super Cargo

## 5.1 D435 Passenger / D435 City family
Cross-checked published data for the D435 passenger/city family:
- Engine: **435 cc, single-cylinder diesel**
- Max power: **5.7 kW @ 3600 RPM**
- Max torque: **19 Nm @ 2200–2400 RPM**
- Gears: **4 forward + 1 reverse**
- Fuel tank: **10.5 L**
- Top speed: **55 km/h**
- D435 Passenger kerb weight: **456 kg** in the official/Greaves brochure source
- Passenger D435 GVW: **786 kg** in the official brochure source
- Passenger payload: **330 kg** in the official brochure source

### D435 City EX current market cross-check
A current market record for D435 City reports:
- Power: **7.6 HP**
- GVW: **786 kg**
- Wheelbase: **1930 mm**
- Fuel tank: **10.5 L**
- Payload: **330 kg**
- Mileage: **20–25 km/l** (third-party claim; do not present as Greaves official mileage)

Use the exact Greaves variant/brochure for your dealership inventory record.

## 5.2 D435 Cargo / Super Cargo
Greaves'' older official all-brochure record includes a D435 cargo variant with:
- Engine: **435 cc single-cylinder diesel, air cooled**
- Power: **5.7 kW @ 3600 RPM**
- Torque: **19 Nm @ 2200–2400 RPM**
- Gear: **4F+1R**
- GVW: **997 kg**
- Payload: **462 kg**
- Max speed: **45 km/h**
- Fuel tank: **10.5 L**

A newer D435 Super Cargo LB may differ. Record it as a separate variant rather than inheriting these values.

## 5.3 Greaves D599+ Diesel variants
The manufacturer brochure/search material also records D599+:

### Passenger
- Engine: **599 cc, single-cylinder diesel, water cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **790 kg**
- Payload: **310 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Pickup/Cargo
- Engine: **599 cc, single-cylinder diesel, air cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **980 kg**
- Payload: **500 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Sources
- Greaves current 3W range: https://3wheelers.greaveselectricmobility.com/
- Current brochure download page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Official all-brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf
- D435 passenger brochure record: https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf
- D435 City third-party cross-check: https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/

Verification: **Core D435/D599 data sourced from Greaves brochure material; current Super variants need exact dealer/OEM brochure attachment before final stock/master-data publication.**

---

','Do not inherit older D435 family specifications without exact-variant verification.'),
('GREAVES_D435_CARGO_LB_CURRENT_RANGE','Greaves','D435','D435 Cargo LB','Current range','diesel_rickshaw','active','{}','["https://3wheelers.greaveselectricmobility.com/download-brochure","https://3wheelers.greaveselectricmobility.com/","https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf","https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf","https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Range listing verified; exact variant specifications require verification','GREAVES DIESEL 3-WHEELERS

Current Greaves brochure page lists:
- D435 Super City EX
- D435 City EX
- D435 Super Cargo LB
- D435 Cargo LB
- D435 Super Cargo

## 5.1 D435 Passenger / D435 City family
Cross-checked published data for the D435 passenger/city family:
- Engine: **435 cc, single-cylinder diesel**
- Max power: **5.7 kW @ 3600 RPM**
- Max torque: **19 Nm @ 2200–2400 RPM**
- Gears: **4 forward + 1 reverse**
- Fuel tank: **10.5 L**
- Top speed: **55 km/h**
- D435 Passenger kerb weight: **456 kg** in the official/Greaves brochure source
- Passenger D435 GVW: **786 kg** in the official brochure source
- Passenger payload: **330 kg** in the official brochure source

### D435 City EX current market cross-check
A current market record for D435 City reports:
- Power: **7.6 HP**
- GVW: **786 kg**
- Wheelbase: **1930 mm**
- Fuel tank: **10.5 L**
- Payload: **330 kg**
- Mileage: **20–25 km/l** (third-party claim; do not present as Greaves official mileage)

Use the exact Greaves variant/brochure for your dealership inventory record.

## 5.2 D435 Cargo / Super Cargo
Greaves'' older official all-brochure record includes a D435 cargo variant with:
- Engine: **435 cc single-cylinder diesel, air cooled**
- Power: **5.7 kW @ 3600 RPM**
- Torque: **19 Nm @ 2200–2400 RPM**
- Gear: **4F+1R**
- GVW: **997 kg**
- Payload: **462 kg**
- Max speed: **45 km/h**
- Fuel tank: **10.5 L**

A newer D435 Super Cargo LB may differ. Record it as a separate variant rather than inheriting these values.

## 5.3 Greaves D599+ Diesel variants
The manufacturer brochure/search material also records D599+:

### Passenger
- Engine: **599 cc, single-cylinder diesel, water cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **790 kg**
- Payload: **310 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Pickup/Cargo
- Engine: **599 cc, single-cylinder diesel, air cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **980 kg**
- Payload: **500 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Sources
- Greaves current 3W range: https://3wheelers.greaveselectricmobility.com/
- Current brochure download page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Official all-brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf
- D435 passenger brochure record: https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf
- D435 City third-party cross-check: https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/

Verification: **Core D435/D599 data sourced from Greaves brochure material; current Super variants need exact dealer/OEM brochure attachment before final stock/master-data publication.**

---

','Do not inherit older D435 family specifications without exact-variant verification.'),
('GREAVES_D435_SUPER_CARGO_CURRENT_RANGE','Greaves','D435','D435 Super Cargo','Current range','diesel_rickshaw','active','{}','["https://3wheelers.greaveselectricmobility.com/download-brochure","https://3wheelers.greaveselectricmobility.com/","https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf","https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf","https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Range listing verified; exact variant specifications require verification','GREAVES DIESEL 3-WHEELERS

Current Greaves brochure page lists:
- D435 Super City EX
- D435 City EX
- D435 Super Cargo LB
- D435 Cargo LB
- D435 Super Cargo

## 5.1 D435 Passenger / D435 City family
Cross-checked published data for the D435 passenger/city family:
- Engine: **435 cc, single-cylinder diesel**
- Max power: **5.7 kW @ 3600 RPM**
- Max torque: **19 Nm @ 2200–2400 RPM**
- Gears: **4 forward + 1 reverse**
- Fuel tank: **10.5 L**
- Top speed: **55 km/h**
- D435 Passenger kerb weight: **456 kg** in the official/Greaves brochure source
- Passenger D435 GVW: **786 kg** in the official brochure source
- Passenger payload: **330 kg** in the official brochure source

### D435 City EX current market cross-check
A current market record for D435 City reports:
- Power: **7.6 HP**
- GVW: **786 kg**
- Wheelbase: **1930 mm**
- Fuel tank: **10.5 L**
- Payload: **330 kg**
- Mileage: **20–25 km/l** (third-party claim; do not present as Greaves official mileage)

Use the exact Greaves variant/brochure for your dealership inventory record.

## 5.2 D435 Cargo / Super Cargo
Greaves'' older official all-brochure record includes a D435 cargo variant with:
- Engine: **435 cc single-cylinder diesel, air cooled**
- Power: **5.7 kW @ 3600 RPM**
- Torque: **19 Nm @ 2200–2400 RPM**
- Gear: **4F+1R**
- GVW: **997 kg**
- Payload: **462 kg**
- Max speed: **45 km/h**
- Fuel tank: **10.5 L**

A newer D435 Super Cargo LB may differ. Record it as a separate variant rather than inheriting these values.

## 5.3 Greaves D599+ Diesel variants
The manufacturer brochure/search material also records D599+:

### Passenger
- Engine: **599 cc, single-cylinder diesel, water cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **790 kg**
- Payload: **310 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Pickup/Cargo
- Engine: **599 cc, single-cylinder diesel, air cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **980 kg**
- Payload: **500 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Sources
- Greaves current 3W range: https://3wheelers.greaveselectricmobility.com/
- Current brochure download page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Official all-brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf
- D435 passenger brochure record: https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf
- D435 City third-party cross-check: https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/

Verification: **Core D435/D599 data sourced from Greaves brochure material; current Super variants need exact dealer/OEM brochure attachment before final stock/master-data publication.**

---

','Do not inherit older D435 family specifications without exact-variant verification.'),
('GREAVES_D435_PASSENGER_BROCHURE_GENERATION','Greaves','D435','D435 Passenger','Brochure generation','diesel_rickshaw','legacy','{"Engine":"435 cc single-cylinder diesel","Power":"5.7 kW @ 3600 RPM","Torque":"19 Nm @ 2200–2400 RPM","Gearbox":"4F+1R","Fuel tank":"10.5 L","Payload":"330 kg","Kerb weight":"456 kg","GVW":"786 kg","Top speed":"55 km/h"}','["https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf","https://3wheelers.greaveselectricmobility.com/","https://3wheelers.greaveselectricmobility.com/download-brochure","https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf","https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','GREAVES DIESEL 3-WHEELERS

Current Greaves brochure page lists:
- D435 Super City EX
- D435 City EX
- D435 Super Cargo LB
- D435 Cargo LB
- D435 Super Cargo

## 5.1 D435 Passenger / D435 City family
Cross-checked published data for the D435 passenger/city family:
- Engine: **435 cc, single-cylinder diesel**
- Max power: **5.7 kW @ 3600 RPM**
- Max torque: **19 Nm @ 2200–2400 RPM**
- Gears: **4 forward + 1 reverse**
- Fuel tank: **10.5 L**
- Top speed: **55 km/h**
- D435 Passenger kerb weight: **456 kg** in the official/Greaves brochure source
- Passenger D435 GVW: **786 kg** in the official brochure source
- Passenger payload: **330 kg** in the official brochure source

### D435 City EX current market cross-check
A current market record for D435 City reports:
- Power: **7.6 HP**
- GVW: **786 kg**
- Wheelbase: **1930 mm**
- Fuel tank: **10.5 L**
- Payload: **330 kg**
- Mileage: **20–25 km/l** (third-party claim; do not present as Greaves official mileage)

Use the exact Greaves variant/brochure for your dealership inventory record.

## 5.2 D435 Cargo / Super Cargo
Greaves'' older official all-brochure record includes a D435 cargo variant with:
- Engine: **435 cc single-cylinder diesel, air cooled**
- Power: **5.7 kW @ 3600 RPM**
- Torque: **19 Nm @ 2200–2400 RPM**
- Gear: **4F+1R**
- GVW: **997 kg**
- Payload: **462 kg**
- Max speed: **45 km/h**
- Fuel tank: **10.5 L**

A newer D435 Super Cargo LB may differ. Record it as a separate variant rather than inheriting these values.

## 5.3 Greaves D599+ Diesel variants
The manufacturer brochure/search material also records D599+:

### Passenger
- Engine: **599 cc, single-cylinder diesel, water cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **790 kg**
- Payload: **310 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Pickup/Cargo
- Engine: **599 cc, single-cylinder diesel, air cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **980 kg**
- Payload: **500 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Sources
- Greaves current 3W range: https://3wheelers.greaveselectricmobility.com/
- Current brochure download page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Official all-brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf
- D435 passenger brochure record: https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf
- D435 City third-party cross-check: https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/

Verification: **Core D435/D599 data sourced from Greaves brochure material; current Super variants need exact dealer/OEM brochure attachment before final stock/master-data publication.**

---

','Brochure generation, distinct from current Super variants.'),
('GREAVES_D435_CARGO_OLDER_BROCHURE','Greaves','D435','D435 Cargo','Older brochure','diesel_rickshaw','legacy','{"Engine":"435 cc air-cooled diesel","Power":"5.7 kW","Payload":"462 kg","GVW":"997 kg","Top speed":"45 km/h","Fuel tank":"10.5 L"}','["https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf","https://3wheelers.greaveselectricmobility.com/","https://3wheelers.greaveselectricmobility.com/download-brochure","https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf","https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','GREAVES DIESEL 3-WHEELERS

Current Greaves brochure page lists:
- D435 Super City EX
- D435 City EX
- D435 Super Cargo LB
- D435 Cargo LB
- D435 Super Cargo

## 5.1 D435 Passenger / D435 City family
Cross-checked published data for the D435 passenger/city family:
- Engine: **435 cc, single-cylinder diesel**
- Max power: **5.7 kW @ 3600 RPM**
- Max torque: **19 Nm @ 2200–2400 RPM**
- Gears: **4 forward + 1 reverse**
- Fuel tank: **10.5 L**
- Top speed: **55 km/h**
- D435 Passenger kerb weight: **456 kg** in the official/Greaves brochure source
- Passenger D435 GVW: **786 kg** in the official brochure source
- Passenger payload: **330 kg** in the official brochure source

### D435 City EX current market cross-check
A current market record for D435 City reports:
- Power: **7.6 HP**
- GVW: **786 kg**
- Wheelbase: **1930 mm**
- Fuel tank: **10.5 L**
- Payload: **330 kg**
- Mileage: **20–25 km/l** (third-party claim; do not present as Greaves official mileage)

Use the exact Greaves variant/brochure for your dealership inventory record.

## 5.2 D435 Cargo / Super Cargo
Greaves'' older official all-brochure record includes a D435 cargo variant with:
- Engine: **435 cc single-cylinder diesel, air cooled**
- Power: **5.7 kW @ 3600 RPM**
- Torque: **19 Nm @ 2200–2400 RPM**
- Gear: **4F+1R**
- GVW: **997 kg**
- Payload: **462 kg**
- Max speed: **45 km/h**
- Fuel tank: **10.5 L**

A newer D435 Super Cargo LB may differ. Record it as a separate variant rather than inheriting these values.

## 5.3 Greaves D599+ Diesel variants
The manufacturer brochure/search material also records D599+:

### Passenger
- Engine: **599 cc, single-cylinder diesel, water cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **790 kg**
- Payload: **310 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Pickup/Cargo
- Engine: **599 cc, single-cylinder diesel, air cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **980 kg**
- Payload: **500 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Sources
- Greaves current 3W range: https://3wheelers.greaveselectricmobility.com/
- Current brochure download page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Official all-brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf
- D435 passenger brochure record: https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf
- D435 City third-party cross-check: https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/

Verification: **Core D435/D599 data sourced from Greaves brochure material; current Super variants need exact dealer/OEM brochure attachment before final stock/master-data publication.**

---

','Older cargo specifications.'),
('GREAVES_D599_PLUS_PASSENGER','Greaves','D599+','D599+','Passenger','diesel_rickshaw','active','{"Engine":"599 cc single-cylinder diesel, Water cooled","Power":"7.0 kW @ 3600 RPM","Torque":"23.5 Nm @ 2200 ± 200 RPM","Gearbox":"4F+1R","Payload":"310 kg","GVW":"790 kg","Kerb weight":"480 kg","Top speed":"55 km/h","Fuel tank":"10.5 L"}','["https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf","https://3wheelers.greaveselectricmobility.com/","https://3wheelers.greaveselectricmobility.com/download-brochure","https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf","https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','GREAVES DIESEL 3-WHEELERS

Current Greaves brochure page lists:
- D435 Super City EX
- D435 City EX
- D435 Super Cargo LB
- D435 Cargo LB
- D435 Super Cargo

## 5.1 D435 Passenger / D435 City family
Cross-checked published data for the D435 passenger/city family:
- Engine: **435 cc, single-cylinder diesel**
- Max power: **5.7 kW @ 3600 RPM**
- Max torque: **19 Nm @ 2200–2400 RPM**
- Gears: **4 forward + 1 reverse**
- Fuel tank: **10.5 L**
- Top speed: **55 km/h**
- D435 Passenger kerb weight: **456 kg** in the official/Greaves brochure source
- Passenger D435 GVW: **786 kg** in the official brochure source
- Passenger payload: **330 kg** in the official brochure source

### D435 City EX current market cross-check
A current market record for D435 City reports:
- Power: **7.6 HP**
- GVW: **786 kg**
- Wheelbase: **1930 mm**
- Fuel tank: **10.5 L**
- Payload: **330 kg**
- Mileage: **20–25 km/l** (third-party claim; do not present as Greaves official mileage)

Use the exact Greaves variant/brochure for your dealership inventory record.

## 5.2 D435 Cargo / Super Cargo
Greaves'' older official all-brochure record includes a D435 cargo variant with:
- Engine: **435 cc single-cylinder diesel, air cooled**
- Power: **5.7 kW @ 3600 RPM**
- Torque: **19 Nm @ 2200–2400 RPM**
- Gear: **4F+1R**
- GVW: **997 kg**
- Payload: **462 kg**
- Max speed: **45 km/h**
- Fuel tank: **10.5 L**

A newer D435 Super Cargo LB may differ. Record it as a separate variant rather than inheriting these values.

## 5.3 Greaves D599+ Diesel variants
The manufacturer brochure/search material also records D599+:

### Passenger
- Engine: **599 cc, single-cylinder diesel, water cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **790 kg**
- Payload: **310 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Pickup/Cargo
- Engine: **599 cc, single-cylinder diesel, air cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **980 kg**
- Payload: **500 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Sources
- Greaves current 3W range: https://3wheelers.greaveselectricmobility.com/
- Current brochure download page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Official all-brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf
- D435 passenger brochure record: https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf
- D435 City third-party cross-check: https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/

Verification: **Core D435/D599 data sourced from Greaves brochure material; current Super variants need exact dealer/OEM brochure attachment before final stock/master-data publication.**

---

','Verify exact brochure generation for stocked units.'),
('GREAVES_D599_PLUS_PICKUP_CARGO','Greaves','D599+','D599+','Pickup / Cargo','diesel_rickshaw','active','{"Engine":"599 cc single-cylinder diesel, Air cooled","Power":"7.0 kW @ 3600 RPM","Torque":"23.5 Nm @ 2200 ± 200 RPM","Gearbox":"4F+1R","Payload":"500 kg","GVW":"980 kg","Kerb weight":"480 kg","Top speed":"55 km/h","Fuel tank":"10.5 L"}','["https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf","https://3wheelers.greaveselectricmobility.com/","https://3wheelers.greaveselectricmobility.com/download-brochure","https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf","https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','GREAVES DIESEL 3-WHEELERS

Current Greaves brochure page lists:
- D435 Super City EX
- D435 City EX
- D435 Super Cargo LB
- D435 Cargo LB
- D435 Super Cargo

## 5.1 D435 Passenger / D435 City family
Cross-checked published data for the D435 passenger/city family:
- Engine: **435 cc, single-cylinder diesel**
- Max power: **5.7 kW @ 3600 RPM**
- Max torque: **19 Nm @ 2200–2400 RPM**
- Gears: **4 forward + 1 reverse**
- Fuel tank: **10.5 L**
- Top speed: **55 km/h**
- D435 Passenger kerb weight: **456 kg** in the official/Greaves brochure source
- Passenger D435 GVW: **786 kg** in the official brochure source
- Passenger payload: **330 kg** in the official brochure source

### D435 City EX current market cross-check
A current market record for D435 City reports:
- Power: **7.6 HP**
- GVW: **786 kg**
- Wheelbase: **1930 mm**
- Fuel tank: **10.5 L**
- Payload: **330 kg**
- Mileage: **20–25 km/l** (third-party claim; do not present as Greaves official mileage)

Use the exact Greaves variant/brochure for your dealership inventory record.

## 5.2 D435 Cargo / Super Cargo
Greaves'' older official all-brochure record includes a D435 cargo variant with:
- Engine: **435 cc single-cylinder diesel, air cooled**
- Power: **5.7 kW @ 3600 RPM**
- Torque: **19 Nm @ 2200–2400 RPM**
- Gear: **4F+1R**
- GVW: **997 kg**
- Payload: **462 kg**
- Max speed: **45 km/h**
- Fuel tank: **10.5 L**

A newer D435 Super Cargo LB may differ. Record it as a separate variant rather than inheriting these values.

## 5.3 Greaves D599+ Diesel variants
The manufacturer brochure/search material also records D599+:

### Passenger
- Engine: **599 cc, single-cylinder diesel, water cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **790 kg**
- Payload: **310 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Pickup/Cargo
- Engine: **599 cc, single-cylinder diesel, air cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **980 kg**
- Payload: **500 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Sources
- Greaves current 3W range: https://3wheelers.greaveselectricmobility.com/
- Current brochure download page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Official all-brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf
- D435 passenger brochure record: https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf
- D435 City third-party cross-check: https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/

Verification: **Core D435/D599 data sourced from Greaves brochure material; current Super variants need exact dealer/OEM brochure attachment before final stock/master-data publication.**

---

','Verify exact brochure generation for stocked units.'),
('OKAYA_OPERT13507_ECO_RIDER','Okaya','E-rickshaw tubular','OPERT13507','ECO Rider','battery','active','{"Capacity C20":"120 Ah","Voltage":"12 V","Technology":"Tubular lead acid","Warranty":"7 months","Dimensions":"410 × 172 × 235 mm ±2 mm"}','["https://www.okaya.in/product/opert13507","https://www.okaya.in/","https://www.okaya.in/product-listing/e-rickshaw-battery","https://www.okaya.in/product/opert13509","https://www.okaya.in/product/opert14012","https://www.okaya.in/product/opert15012-135ah","https://www.okaya.in/product/opert16015","https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery","https://www.okaya.in/faqs","https://www.okaya.in/storage/images/gallery/1685434338.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','OKAYA E-RICKSHAW BATTERIES

Brand: **OKAYA**
Official site: https://www.okaya.in/

## 6.1 Current official e-rickshaw battery range found
The current Okaya product listing publishes:

| SKU / Model | Capacity | Technology | Nominal Voltage | Published Warranty | Current website retail price* |
|---|---:|---|---:|---:|---:|
| OPERT13507 ECO Rider | 120 Ah | Tubular | 12 V | 7 months | ₹11,390 incl. taxes |
| OPERT13509 PRO Rider | 120 Ah | Tubular | 12 V | 9 months | ₹11,490 incl. taxes |
| OPERT14012 PRO+ Rider | 125 Ah | Tubular | 12 V | 12 months | ₹13,490 incl. taxes |
| OPERT15012 PRO+ Rider | 135 Ah | Tubular | 12 V | 12 months | ₹13,990 incl. taxes |
| OPERT16015 MAX Rider | 145 Ah | Tubular | 12 V on listing; 15 months on product page | 15 months | ₹15,490 incl. taxes |

`*Website retail prices are dynamic online prices, not OM Motors selling prices. Do not hardcode them as dealership prices.`

### Official product details
#### OPERT13507
- Capacity @ C20: **120 Ah**
- Dimensions (L x W x H up to terminal): **410 x 172 x 235 mm ±2 mm**
- Warranty: **7 months**
- Nominal voltage: **12 V**
- Tubular lead-acid design
- Product line: **ECO Rider**
- Manufacturer feature claims: extra mileage, longer life, faster recharge, 99.98% pure lead, special paste formulation, low-antimony alloy, factory charged, paperless warranty

#### OPERT13509
- Capacity @ C20: **120 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **9 months**
- Nominal voltage: **12 V**
- Product line: **PRO Rider**

#### OPERT14012
- Capacity @ C20: **125 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT15012
- Capacity @ C20: **135 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT16015
- Capacity @ C20: **145 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **15 months**
- Nominal voltage: **12 V**
- Product line: **MAX Rider**

### General Okaya e-rickshaw facts published by Okaya
- Most e-rickshaws use **four 12 V batteries in series** for a 48 V system.
- Okaya states e-rickshaw battery capacity offerings include 120 Ah, 125 Ah, 135 Ah and 145 Ah.
- Okaya states typical real-world battery life can be **12–18 months** depending on use, charging and maintenance; this is a general consumer guidance statement, **not the warranty period**.
- Okaya FAQ says full-charge range can be **70–120 km**, depending on capacity and driving conditions; do not attach this range automatically to every battery SKU.

### Additional legacy Okaya record
An older Okaya drawing for **OTER 16012** states:
- Type: lead-acid tubular
- Nominal voltage: **12 V**
- Capacity: **90 Ah C5 corrected at 30°C**
- Vehicle application: electric vehicle
- Dimensions: **408±3 x 172±3 x 234±3 mm overall**
- Warranty printed on drawing: **12 months**
This is a historical technical drawing and should be stored as `legacy_model=true`, not mixed with the current OPERT range.

### Sources
- Current Okaya e-rickshaw listing: https://www.okaya.in/product-listing/e-rickshaw-battery
- OPERT13507: https://www.okaya.in/product/opert13507
- OPERT13509: https://www.okaya.in/product/opert13509
- OPERT14012: https://www.okaya.in/product/opert14012
- OPERT15012: https://www.okaya.in/product/opert15012-135ah
- OPERT16015: https://www.okaya.in/product/opert16015
- Okaya mobility page: https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery
- Okaya FAQ: https://www.okaya.in/faqs
- Legacy technical drawing: https://www.okaya.in/storage/images/gallery/1685434338.pdf

Verification: **Manufacturer verified.**

---

','Website retail price is not the OM Motors selling price.'),
('OKAYA_OPERT13509_PRO_RIDER','Okaya','E-rickshaw tubular','OPERT13509','PRO Rider','battery','active','{"Capacity C20":"120 Ah","Voltage":"12 V","Technology":"Tubular lead acid","Warranty":"9 months","Dimensions":"410 × 172 × 275 mm ±2 mm"}','["https://www.okaya.in/product/opert13509","https://www.okaya.in/","https://www.okaya.in/product-listing/e-rickshaw-battery","https://www.okaya.in/product/opert13507","https://www.okaya.in/product/opert14012","https://www.okaya.in/product/opert15012-135ah","https://www.okaya.in/product/opert16015","https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery","https://www.okaya.in/faqs","https://www.okaya.in/storage/images/gallery/1685434338.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','OKAYA E-RICKSHAW BATTERIES

Brand: **OKAYA**
Official site: https://www.okaya.in/

## 6.1 Current official e-rickshaw battery range found
The current Okaya product listing publishes:

| SKU / Model | Capacity | Technology | Nominal Voltage | Published Warranty | Current website retail price* |
|---|---:|---|---:|---:|---:|
| OPERT13507 ECO Rider | 120 Ah | Tubular | 12 V | 7 months | ₹11,390 incl. taxes |
| OPERT13509 PRO Rider | 120 Ah | Tubular | 12 V | 9 months | ₹11,490 incl. taxes |
| OPERT14012 PRO+ Rider | 125 Ah | Tubular | 12 V | 12 months | ₹13,490 incl. taxes |
| OPERT15012 PRO+ Rider | 135 Ah | Tubular | 12 V | 12 months | ₹13,990 incl. taxes |
| OPERT16015 MAX Rider | 145 Ah | Tubular | 12 V on listing; 15 months on product page | 15 months | ₹15,490 incl. taxes |

`*Website retail prices are dynamic online prices, not OM Motors selling prices. Do not hardcode them as dealership prices.`

### Official product details
#### OPERT13507
- Capacity @ C20: **120 Ah**
- Dimensions (L x W x H up to terminal): **410 x 172 x 235 mm ±2 mm**
- Warranty: **7 months**
- Nominal voltage: **12 V**
- Tubular lead-acid design
- Product line: **ECO Rider**
- Manufacturer feature claims: extra mileage, longer life, faster recharge, 99.98% pure lead, special paste formulation, low-antimony alloy, factory charged, paperless warranty

#### OPERT13509
- Capacity @ C20: **120 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **9 months**
- Nominal voltage: **12 V**
- Product line: **PRO Rider**

#### OPERT14012
- Capacity @ C20: **125 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT15012
- Capacity @ C20: **135 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT16015
- Capacity @ C20: **145 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **15 months**
- Nominal voltage: **12 V**
- Product line: **MAX Rider**

### General Okaya e-rickshaw facts published by Okaya
- Most e-rickshaws use **four 12 V batteries in series** for a 48 V system.
- Okaya states e-rickshaw battery capacity offerings include 120 Ah, 125 Ah, 135 Ah and 145 Ah.
- Okaya states typical real-world battery life can be **12–18 months** depending on use, charging and maintenance; this is a general consumer guidance statement, **not the warranty period**.
- Okaya FAQ says full-charge range can be **70–120 km**, depending on capacity and driving conditions; do not attach this range automatically to every battery SKU.

### Additional legacy Okaya record
An older Okaya drawing for **OTER 16012** states:
- Type: lead-acid tubular
- Nominal voltage: **12 V**
- Capacity: **90 Ah C5 corrected at 30°C**
- Vehicle application: electric vehicle
- Dimensions: **408±3 x 172±3 x 234±3 mm overall**
- Warranty printed on drawing: **12 months**
This is a historical technical drawing and should be stored as `legacy_model=true`, not mixed with the current OPERT range.

### Sources
- Current Okaya e-rickshaw listing: https://www.okaya.in/product-listing/e-rickshaw-battery
- OPERT13507: https://www.okaya.in/product/opert13507
- OPERT13509: https://www.okaya.in/product/opert13509
- OPERT14012: https://www.okaya.in/product/opert14012
- OPERT15012: https://www.okaya.in/product/opert15012-135ah
- OPERT16015: https://www.okaya.in/product/opert16015
- Okaya mobility page: https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery
- Okaya FAQ: https://www.okaya.in/faqs
- Legacy technical drawing: https://www.okaya.in/storage/images/gallery/1685434338.pdf

Verification: **Manufacturer verified.**

---

','Website retail price is not the OM Motors selling price.'),
('OKAYA_OPERT14012_PRO_PLUS_RIDER','Okaya','E-rickshaw tubular','OPERT14012','PRO+ Rider','battery','active','{"Capacity C20":"125 Ah","Voltage":"12 V","Technology":"Tubular lead acid","Warranty":"12 months","Dimensions":"410 × 172 × 275 mm ±2 mm"}','["https://www.okaya.in/product/opert14012","https://www.okaya.in/","https://www.okaya.in/product-listing/e-rickshaw-battery","https://www.okaya.in/product/opert13507","https://www.okaya.in/product/opert13509","https://www.okaya.in/product/opert15012-135ah","https://www.okaya.in/product/opert16015","https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery","https://www.okaya.in/faqs","https://www.okaya.in/storage/images/gallery/1685434338.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','OKAYA E-RICKSHAW BATTERIES

Brand: **OKAYA**
Official site: https://www.okaya.in/

## 6.1 Current official e-rickshaw battery range found
The current Okaya product listing publishes:

| SKU / Model | Capacity | Technology | Nominal Voltage | Published Warranty | Current website retail price* |
|---|---:|---|---:|---:|---:|
| OPERT13507 ECO Rider | 120 Ah | Tubular | 12 V | 7 months | ₹11,390 incl. taxes |
| OPERT13509 PRO Rider | 120 Ah | Tubular | 12 V | 9 months | ₹11,490 incl. taxes |
| OPERT14012 PRO+ Rider | 125 Ah | Tubular | 12 V | 12 months | ₹13,490 incl. taxes |
| OPERT15012 PRO+ Rider | 135 Ah | Tubular | 12 V | 12 months | ₹13,990 incl. taxes |
| OPERT16015 MAX Rider | 145 Ah | Tubular | 12 V on listing; 15 months on product page | 15 months | ₹15,490 incl. taxes |

`*Website retail prices are dynamic online prices, not OM Motors selling prices. Do not hardcode them as dealership prices.`

### Official product details
#### OPERT13507
- Capacity @ C20: **120 Ah**
- Dimensions (L x W x H up to terminal): **410 x 172 x 235 mm ±2 mm**
- Warranty: **7 months**
- Nominal voltage: **12 V**
- Tubular lead-acid design
- Product line: **ECO Rider**
- Manufacturer feature claims: extra mileage, longer life, faster recharge, 99.98% pure lead, special paste formulation, low-antimony alloy, factory charged, paperless warranty

#### OPERT13509
- Capacity @ C20: **120 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **9 months**
- Nominal voltage: **12 V**
- Product line: **PRO Rider**

#### OPERT14012
- Capacity @ C20: **125 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT15012
- Capacity @ C20: **135 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT16015
- Capacity @ C20: **145 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **15 months**
- Nominal voltage: **12 V**
- Product line: **MAX Rider**

### General Okaya e-rickshaw facts published by Okaya
- Most e-rickshaws use **four 12 V batteries in series** for a 48 V system.
- Okaya states e-rickshaw battery capacity offerings include 120 Ah, 125 Ah, 135 Ah and 145 Ah.
- Okaya states typical real-world battery life can be **12–18 months** depending on use, charging and maintenance; this is a general consumer guidance statement, **not the warranty period**.
- Okaya FAQ says full-charge range can be **70–120 km**, depending on capacity and driving conditions; do not attach this range automatically to every battery SKU.

### Additional legacy Okaya record
An older Okaya drawing for **OTER 16012** states:
- Type: lead-acid tubular
- Nominal voltage: **12 V**
- Capacity: **90 Ah C5 corrected at 30°C**
- Vehicle application: electric vehicle
- Dimensions: **408±3 x 172±3 x 234±3 mm overall**
- Warranty printed on drawing: **12 months**
This is a historical technical drawing and should be stored as `legacy_model=true`, not mixed with the current OPERT range.

### Sources
- Current Okaya e-rickshaw listing: https://www.okaya.in/product-listing/e-rickshaw-battery
- OPERT13507: https://www.okaya.in/product/opert13507
- OPERT13509: https://www.okaya.in/product/opert13509
- OPERT14012: https://www.okaya.in/product/opert14012
- OPERT15012: https://www.okaya.in/product/opert15012-135ah
- OPERT16015: https://www.okaya.in/product/opert16015
- Okaya mobility page: https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery
- Okaya FAQ: https://www.okaya.in/faqs
- Legacy technical drawing: https://www.okaya.in/storage/images/gallery/1685434338.pdf

Verification: **Manufacturer verified.**

---

','Website retail price is not the OM Motors selling price.'),
('OKAYA_OPERT15012_PRO_PLUS_RIDER','Okaya','E-rickshaw tubular','OPERT15012','PRO+ Rider','battery','active','{"Capacity C20":"135 Ah","Voltage":"12 V","Technology":"Tubular lead acid","Warranty":"12 months","Dimensions":"410 × 172 × 275 mm ±2 mm"}','["https://www.okaya.in/product/opert15012-135ah","https://www.okaya.in/","https://www.okaya.in/product-listing/e-rickshaw-battery","https://www.okaya.in/product/opert13507","https://www.okaya.in/product/opert13509","https://www.okaya.in/product/opert14012","https://www.okaya.in/product/opert16015","https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery","https://www.okaya.in/faqs","https://www.okaya.in/storage/images/gallery/1685434338.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','OKAYA E-RICKSHAW BATTERIES

Brand: **OKAYA**
Official site: https://www.okaya.in/

## 6.1 Current official e-rickshaw battery range found
The current Okaya product listing publishes:

| SKU / Model | Capacity | Technology | Nominal Voltage | Published Warranty | Current website retail price* |
|---|---:|---|---:|---:|---:|
| OPERT13507 ECO Rider | 120 Ah | Tubular | 12 V | 7 months | ₹11,390 incl. taxes |
| OPERT13509 PRO Rider | 120 Ah | Tubular | 12 V | 9 months | ₹11,490 incl. taxes |
| OPERT14012 PRO+ Rider | 125 Ah | Tubular | 12 V | 12 months | ₹13,490 incl. taxes |
| OPERT15012 PRO+ Rider | 135 Ah | Tubular | 12 V | 12 months | ₹13,990 incl. taxes |
| OPERT16015 MAX Rider | 145 Ah | Tubular | 12 V on listing; 15 months on product page | 15 months | ₹15,490 incl. taxes |

`*Website retail prices are dynamic online prices, not OM Motors selling prices. Do not hardcode them as dealership prices.`

### Official product details
#### OPERT13507
- Capacity @ C20: **120 Ah**
- Dimensions (L x W x H up to terminal): **410 x 172 x 235 mm ±2 mm**
- Warranty: **7 months**
- Nominal voltage: **12 V**
- Tubular lead-acid design
- Product line: **ECO Rider**
- Manufacturer feature claims: extra mileage, longer life, faster recharge, 99.98% pure lead, special paste formulation, low-antimony alloy, factory charged, paperless warranty

#### OPERT13509
- Capacity @ C20: **120 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **9 months**
- Nominal voltage: **12 V**
- Product line: **PRO Rider**

#### OPERT14012
- Capacity @ C20: **125 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT15012
- Capacity @ C20: **135 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT16015
- Capacity @ C20: **145 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **15 months**
- Nominal voltage: **12 V**
- Product line: **MAX Rider**

### General Okaya e-rickshaw facts published by Okaya
- Most e-rickshaws use **four 12 V batteries in series** for a 48 V system.
- Okaya states e-rickshaw battery capacity offerings include 120 Ah, 125 Ah, 135 Ah and 145 Ah.
- Okaya states typical real-world battery life can be **12–18 months** depending on use, charging and maintenance; this is a general consumer guidance statement, **not the warranty period**.
- Okaya FAQ says full-charge range can be **70–120 km**, depending on capacity and driving conditions; do not attach this range automatically to every battery SKU.

### Additional legacy Okaya record
An older Okaya drawing for **OTER 16012** states:
- Type: lead-acid tubular
- Nominal voltage: **12 V**
- Capacity: **90 Ah C5 corrected at 30°C**
- Vehicle application: electric vehicle
- Dimensions: **408±3 x 172±3 x 234±3 mm overall**
- Warranty printed on drawing: **12 months**
This is a historical technical drawing and should be stored as `legacy_model=true`, not mixed with the current OPERT range.

### Sources
- Current Okaya e-rickshaw listing: https://www.okaya.in/product-listing/e-rickshaw-battery
- OPERT13507: https://www.okaya.in/product/opert13507
- OPERT13509: https://www.okaya.in/product/opert13509
- OPERT14012: https://www.okaya.in/product/opert14012
- OPERT15012: https://www.okaya.in/product/opert15012-135ah
- OPERT16015: https://www.okaya.in/product/opert16015
- Okaya mobility page: https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery
- Okaya FAQ: https://www.okaya.in/faqs
- Legacy technical drawing: https://www.okaya.in/storage/images/gallery/1685434338.pdf

Verification: **Manufacturer verified.**

---

','Website retail price is not the OM Motors selling price.'),
('OKAYA_OPERT16015_MAX_RIDER','Okaya','E-rickshaw tubular','OPERT16015','MAX Rider','battery','active','{"Capacity C20":"145 Ah","Voltage":"12 V","Technology":"Tubular lead acid","Warranty":"15 months","Dimensions":"410 × 172 × 275 mm ±2 mm"}','["https://www.okaya.in/product/opert16015","https://www.okaya.in/","https://www.okaya.in/product-listing/e-rickshaw-battery","https://www.okaya.in/product/opert13507","https://www.okaya.in/product/opert13509","https://www.okaya.in/product/opert14012","https://www.okaya.in/product/opert15012-135ah","https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery","https://www.okaya.in/faqs","https://www.okaya.in/storage/images/gallery/1685434338.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','OKAYA E-RICKSHAW BATTERIES

Brand: **OKAYA**
Official site: https://www.okaya.in/

## 6.1 Current official e-rickshaw battery range found
The current Okaya product listing publishes:

| SKU / Model | Capacity | Technology | Nominal Voltage | Published Warranty | Current website retail price* |
|---|---:|---|---:|---:|---:|
| OPERT13507 ECO Rider | 120 Ah | Tubular | 12 V | 7 months | ₹11,390 incl. taxes |
| OPERT13509 PRO Rider | 120 Ah | Tubular | 12 V | 9 months | ₹11,490 incl. taxes |
| OPERT14012 PRO+ Rider | 125 Ah | Tubular | 12 V | 12 months | ₹13,490 incl. taxes |
| OPERT15012 PRO+ Rider | 135 Ah | Tubular | 12 V | 12 months | ₹13,990 incl. taxes |
| OPERT16015 MAX Rider | 145 Ah | Tubular | 12 V on listing; 15 months on product page | 15 months | ₹15,490 incl. taxes |

`*Website retail prices are dynamic online prices, not OM Motors selling prices. Do not hardcode them as dealership prices.`

### Official product details
#### OPERT13507
- Capacity @ C20: **120 Ah**
- Dimensions (L x W x H up to terminal): **410 x 172 x 235 mm ±2 mm**
- Warranty: **7 months**
- Nominal voltage: **12 V**
- Tubular lead-acid design
- Product line: **ECO Rider**
- Manufacturer feature claims: extra mileage, longer life, faster recharge, 99.98% pure lead, special paste formulation, low-antimony alloy, factory charged, paperless warranty

#### OPERT13509
- Capacity @ C20: **120 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **9 months**
- Nominal voltage: **12 V**
- Product line: **PRO Rider**

#### OPERT14012
- Capacity @ C20: **125 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT15012
- Capacity @ C20: **135 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT16015
- Capacity @ C20: **145 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **15 months**
- Nominal voltage: **12 V**
- Product line: **MAX Rider**

### General Okaya e-rickshaw facts published by Okaya
- Most e-rickshaws use **four 12 V batteries in series** for a 48 V system.
- Okaya states e-rickshaw battery capacity offerings include 120 Ah, 125 Ah, 135 Ah and 145 Ah.
- Okaya states typical real-world battery life can be **12–18 months** depending on use, charging and maintenance; this is a general consumer guidance statement, **not the warranty period**.
- Okaya FAQ says full-charge range can be **70–120 km**, depending on capacity and driving conditions; do not attach this range automatically to every battery SKU.

### Additional legacy Okaya record
An older Okaya drawing for **OTER 16012** states:
- Type: lead-acid tubular
- Nominal voltage: **12 V**
- Capacity: **90 Ah C5 corrected at 30°C**
- Vehicle application: electric vehicle
- Dimensions: **408±3 x 172±3 x 234±3 mm overall**
- Warranty printed on drawing: **12 months**
This is a historical technical drawing and should be stored as `legacy_model=true`, not mixed with the current OPERT range.

### Sources
- Current Okaya e-rickshaw listing: https://www.okaya.in/product-listing/e-rickshaw-battery
- OPERT13507: https://www.okaya.in/product/opert13507
- OPERT13509: https://www.okaya.in/product/opert13509
- OPERT14012: https://www.okaya.in/product/opert14012
- OPERT15012: https://www.okaya.in/product/opert15012-135ah
- OPERT16015: https://www.okaya.in/product/opert16015
- Okaya mobility page: https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery
- Okaya FAQ: https://www.okaya.in/faqs
- Legacy technical drawing: https://www.okaya.in/storage/images/gallery/1685434338.pdf

Verification: **Manufacturer verified.**

---

','Website retail price is not the OM Motors selling price.'),
('OKAYA_OTER_16012_HISTORICAL_DRAWING','Okaya','E-rickshaw tubular','OTER 16012','Historical drawing','battery','legacy','{"Capacity":"90 Ah C5 corrected at 30°C","Voltage":"12 V","Warranty":"12 months","Dimensions":"408±3 × 172±3 × 234±3 mm"}','["https://www.okaya.in/storage/images/gallery/1685434338.pdf","https://www.okaya.in/","https://www.okaya.in/product-listing/e-rickshaw-battery","https://www.okaya.in/product/opert13507","https://www.okaya.in/product/opert13509","https://www.okaya.in/product/opert14012","https://www.okaya.in/product/opert15012-135ah","https://www.okaya.in/product/opert16015","https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery","https://www.okaya.in/faqs"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','OKAYA E-RICKSHAW BATTERIES

Brand: **OKAYA**
Official site: https://www.okaya.in/

## 6.1 Current official e-rickshaw battery range found
The current Okaya product listing publishes:

| SKU / Model | Capacity | Technology | Nominal Voltage | Published Warranty | Current website retail price* |
|---|---:|---|---:|---:|---:|
| OPERT13507 ECO Rider | 120 Ah | Tubular | 12 V | 7 months | ₹11,390 incl. taxes |
| OPERT13509 PRO Rider | 120 Ah | Tubular | 12 V | 9 months | ₹11,490 incl. taxes |
| OPERT14012 PRO+ Rider | 125 Ah | Tubular | 12 V | 12 months | ₹13,490 incl. taxes |
| OPERT15012 PRO+ Rider | 135 Ah | Tubular | 12 V | 12 months | ₹13,990 incl. taxes |
| OPERT16015 MAX Rider | 145 Ah | Tubular | 12 V on listing; 15 months on product page | 15 months | ₹15,490 incl. taxes |

`*Website retail prices are dynamic online prices, not OM Motors selling prices. Do not hardcode them as dealership prices.`

### Official product details
#### OPERT13507
- Capacity @ C20: **120 Ah**
- Dimensions (L x W x H up to terminal): **410 x 172 x 235 mm ±2 mm**
- Warranty: **7 months**
- Nominal voltage: **12 V**
- Tubular lead-acid design
- Product line: **ECO Rider**
- Manufacturer feature claims: extra mileage, longer life, faster recharge, 99.98% pure lead, special paste formulation, low-antimony alloy, factory charged, paperless warranty

#### OPERT13509
- Capacity @ C20: **120 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **9 months**
- Nominal voltage: **12 V**
- Product line: **PRO Rider**

#### OPERT14012
- Capacity @ C20: **125 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT15012
- Capacity @ C20: **135 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT16015
- Capacity @ C20: **145 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **15 months**
- Nominal voltage: **12 V**
- Product line: **MAX Rider**

### General Okaya e-rickshaw facts published by Okaya
- Most e-rickshaws use **four 12 V batteries in series** for a 48 V system.
- Okaya states e-rickshaw battery capacity offerings include 120 Ah, 125 Ah, 135 Ah and 145 Ah.
- Okaya states typical real-world battery life can be **12–18 months** depending on use, charging and maintenance; this is a general consumer guidance statement, **not the warranty period**.
- Okaya FAQ says full-charge range can be **70–120 km**, depending on capacity and driving conditions; do not attach this range automatically to every battery SKU.

### Additional legacy Okaya record
An older Okaya drawing for **OTER 16012** states:
- Type: lead-acid tubular
- Nominal voltage: **12 V**
- Capacity: **90 Ah C5 corrected at 30°C**
- Vehicle application: electric vehicle
- Dimensions: **408±3 x 172±3 x 234±3 mm overall**
- Warranty printed on drawing: **12 months**
This is a historical technical drawing and should be stored as `legacy_model=true`, not mixed with the current OPERT range.

### Sources
- Current Okaya e-rickshaw listing: https://www.okaya.in/product-listing/e-rickshaw-battery
- OPERT13507: https://www.okaya.in/product/opert13507
- OPERT13509: https://www.okaya.in/product/opert13509
- OPERT14012: https://www.okaya.in/product/opert14012
- OPERT15012: https://www.okaya.in/product/opert15012-135ah
- OPERT16015: https://www.okaya.in/product/opert16015
- Okaya mobility page: https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery
- Okaya FAQ: https://www.okaya.in/faqs
- Legacy technical drawing: https://www.okaya.in/storage/images/gallery/1685434338.pdf

Verification: **Manufacturer verified.**

---

','Legacy drawing; do not mix with current OPERT models.'),
('TRONTEK_51V_105AH_LFP','Trontek','E-rickshaw lithium','51V 105Ah','LFP','battery','active','{"Voltage":"51 V","Capacity":"105 Ah","Energy":"5.376 kWh","Chemistry":"LiFePO4 / LFP"}','["https://trontek.com/products/e-rickshaw-lithium-battery/","https://trontek.com/","https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/","https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','TRONTEK E-RICKSHAW LITHIUM BATTERIES

## Important naming note
The manufacturer currently uses the spelling **Trontek Electronics Ltd / Trontek**, not “Trontec”. For the app, store:
- `brand_display_name = Trontek`
- `alternate_search_terms = Trontec, TronTek`

Official site: https://trontek.com/
Official e-rickshaw battery page: https://trontek.com/products/e-rickshaw-lithium-battery/

## 7.1 Current published Trontek e-rickshaw lithium variants
The official page currently exposes the following electrical variants:

| Model | Nominal Voltage | Capacity | Energy |
|---|---:|---:|---:|
| 51V 105Ah | 51 V | 105 Ah | 5.376 kWh |
| 51V 132Ah | 51 V | 132 Ah | 6.758 kWh |
| 51V 153Ah | 51 V | 153 Ah | 7.834 kWh |
| 51V 232Ah | 51 V | 232 Ah | 11.878 kWh |
| 61V 105Ah | 61 V | 105 Ah | 6.405 kWh |
| 61V 132Ah | 61 V | 132 Ah | 8.052 kWh |
| 61V 153Ah | 61 V | 153 Ah | 9.333 kWh |
| 61V 232Ah | 61 V | 232 Ah | 14.152 kWh |
| 64V 105Ah | 64 V | 105 Ah | 6.72 kWh |
| 64V 132Ah | 64 V | 132 Ah | 8.448 kWh |
| 72V 232Ah | 72 V | 232 Ah | 16.704 kWh |

### Technology / safety claims published by Trontek
- Chemistry: **LiFePO4 / LFP** for the e-rickshaw lithium battery range
- Smart/BMS-style protection against over-charge and over-discharge
- Short-circuit protection
- Acupuncture test resistance claim
- Thermal shock resistance claim
- Vibration and shock resistance claim
- Steady output voltage
- Low self-discharge
- High temperature performance claims
- Official page describes these as suitable for commercial e-rickshaw operation

### What is NOT safe to hardcode yet
The currently indexed product page exposes voltage/capacity/energy, but does not consistently expose for every SKU:
- dimensions
- weight
- charge current
- discharge current
- cycle count
- warranty months
- exact BMS communications
- price
Therefore those fields should be `null` until the exact Trontek datasheet used by OM Motors is uploaded/verified.

### Separate research note
A government/public-sector industry document references Trontec/Trontek among Indian lithium battery pack assemblers, but this does not substitute for an individual product datasheet.

### Sources
- Trontek official home: https://trontek.com/
- Official e-rickshaw lithium page: https://trontek.com/products/e-rickshaw-lithium-battery/
- Trontek e-rickshaw battery technology article: https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/
- Public-sector industry study referencing Trontek: https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf

Verification: **Manufacturer verified for the published electrical range; missing mechanical/warranty/price fields intentionally left unpopulated.**

---

','Alternate spellings: Trontec, TronTek. Warranty, dimensions and price are not published / not verified.'),
('TRONTEK_51V_132AH_LFP','Trontek','E-rickshaw lithium','51V 132Ah','LFP','battery','active','{"Voltage":"51 V","Capacity":"132 Ah","Energy":"6.758 kWh","Chemistry":"LiFePO4 / LFP"}','["https://trontek.com/products/e-rickshaw-lithium-battery/","https://trontek.com/","https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/","https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','TRONTEK E-RICKSHAW LITHIUM BATTERIES

## Important naming note
The manufacturer currently uses the spelling **Trontek Electronics Ltd / Trontek**, not “Trontec”. For the app, store:
- `brand_display_name = Trontek`
- `alternate_search_terms = Trontec, TronTek`

Official site: https://trontek.com/
Official e-rickshaw battery page: https://trontek.com/products/e-rickshaw-lithium-battery/

## 7.1 Current published Trontek e-rickshaw lithium variants
The official page currently exposes the following electrical variants:

| Model | Nominal Voltage | Capacity | Energy |
|---|---:|---:|---:|
| 51V 105Ah | 51 V | 105 Ah | 5.376 kWh |
| 51V 132Ah | 51 V | 132 Ah | 6.758 kWh |
| 51V 153Ah | 51 V | 153 Ah | 7.834 kWh |
| 51V 232Ah | 51 V | 232 Ah | 11.878 kWh |
| 61V 105Ah | 61 V | 105 Ah | 6.405 kWh |
| 61V 132Ah | 61 V | 132 Ah | 8.052 kWh |
| 61V 153Ah | 61 V | 153 Ah | 9.333 kWh |
| 61V 232Ah | 61 V | 232 Ah | 14.152 kWh |
| 64V 105Ah | 64 V | 105 Ah | 6.72 kWh |
| 64V 132Ah | 64 V | 132 Ah | 8.448 kWh |
| 72V 232Ah | 72 V | 232 Ah | 16.704 kWh |

### Technology / safety claims published by Trontek
- Chemistry: **LiFePO4 / LFP** for the e-rickshaw lithium battery range
- Smart/BMS-style protection against over-charge and over-discharge
- Short-circuit protection
- Acupuncture test resistance claim
- Thermal shock resistance claim
- Vibration and shock resistance claim
- Steady output voltage
- Low self-discharge
- High temperature performance claims
- Official page describes these as suitable for commercial e-rickshaw operation

### What is NOT safe to hardcode yet
The currently indexed product page exposes voltage/capacity/energy, but does not consistently expose for every SKU:
- dimensions
- weight
- charge current
- discharge current
- cycle count
- warranty months
- exact BMS communications
- price
Therefore those fields should be `null` until the exact Trontek datasheet used by OM Motors is uploaded/verified.

### Separate research note
A government/public-sector industry document references Trontec/Trontek among Indian lithium battery pack assemblers, but this does not substitute for an individual product datasheet.

### Sources
- Trontek official home: https://trontek.com/
- Official e-rickshaw lithium page: https://trontek.com/products/e-rickshaw-lithium-battery/
- Trontek e-rickshaw battery technology article: https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/
- Public-sector industry study referencing Trontek: https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf

Verification: **Manufacturer verified for the published electrical range; missing mechanical/warranty/price fields intentionally left unpopulated.**

---

','Alternate spellings: Trontec, TronTek. Warranty, dimensions and price are not published / not verified.'),
('TRONTEK_51V_153AH_LFP','Trontek','E-rickshaw lithium','51V 153Ah','LFP','battery','active','{"Voltage":"51 V","Capacity":"153 Ah","Energy":"7.834 kWh","Chemistry":"LiFePO4 / LFP"}','["https://trontek.com/products/e-rickshaw-lithium-battery/","https://trontek.com/","https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/","https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','TRONTEK E-RICKSHAW LITHIUM BATTERIES

## Important naming note
The manufacturer currently uses the spelling **Trontek Electronics Ltd / Trontek**, not “Trontec”. For the app, store:
- `brand_display_name = Trontek`
- `alternate_search_terms = Trontec, TronTek`

Official site: https://trontek.com/
Official e-rickshaw battery page: https://trontek.com/products/e-rickshaw-lithium-battery/

## 7.1 Current published Trontek e-rickshaw lithium variants
The official page currently exposes the following electrical variants:

| Model | Nominal Voltage | Capacity | Energy |
|---|---:|---:|---:|
| 51V 105Ah | 51 V | 105 Ah | 5.376 kWh |
| 51V 132Ah | 51 V | 132 Ah | 6.758 kWh |
| 51V 153Ah | 51 V | 153 Ah | 7.834 kWh |
| 51V 232Ah | 51 V | 232 Ah | 11.878 kWh |
| 61V 105Ah | 61 V | 105 Ah | 6.405 kWh |
| 61V 132Ah | 61 V | 132 Ah | 8.052 kWh |
| 61V 153Ah | 61 V | 153 Ah | 9.333 kWh |
| 61V 232Ah | 61 V | 232 Ah | 14.152 kWh |
| 64V 105Ah | 64 V | 105 Ah | 6.72 kWh |
| 64V 132Ah | 64 V | 132 Ah | 8.448 kWh |
| 72V 232Ah | 72 V | 232 Ah | 16.704 kWh |

### Technology / safety claims published by Trontek
- Chemistry: **LiFePO4 / LFP** for the e-rickshaw lithium battery range
- Smart/BMS-style protection against over-charge and over-discharge
- Short-circuit protection
- Acupuncture test resistance claim
- Thermal shock resistance claim
- Vibration and shock resistance claim
- Steady output voltage
- Low self-discharge
- High temperature performance claims
- Official page describes these as suitable for commercial e-rickshaw operation

### What is NOT safe to hardcode yet
The currently indexed product page exposes voltage/capacity/energy, but does not consistently expose for every SKU:
- dimensions
- weight
- charge current
- discharge current
- cycle count
- warranty months
- exact BMS communications
- price
Therefore those fields should be `null` until the exact Trontek datasheet used by OM Motors is uploaded/verified.

### Separate research note
A government/public-sector industry document references Trontec/Trontek among Indian lithium battery pack assemblers, but this does not substitute for an individual product datasheet.

### Sources
- Trontek official home: https://trontek.com/
- Official e-rickshaw lithium page: https://trontek.com/products/e-rickshaw-lithium-battery/
- Trontek e-rickshaw battery technology article: https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/
- Public-sector industry study referencing Trontek: https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf

Verification: **Manufacturer verified for the published electrical range; missing mechanical/warranty/price fields intentionally left unpopulated.**

---

','Alternate spellings: Trontec, TronTek. Warranty, dimensions and price are not published / not verified.'),
('TRONTEK_51V_232AH_LFP','Trontek','E-rickshaw lithium','51V 232Ah','LFP','battery','active','{"Voltage":"51 V","Capacity":"232 Ah","Energy":"11.878 kWh","Chemistry":"LiFePO4 / LFP"}','["https://trontek.com/products/e-rickshaw-lithium-battery/","https://trontek.com/","https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/","https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','TRONTEK E-RICKSHAW LITHIUM BATTERIES

## Important naming note
The manufacturer currently uses the spelling **Trontek Electronics Ltd / Trontek**, not “Trontec”. For the app, store:
- `brand_display_name = Trontek`
- `alternate_search_terms = Trontec, TronTek`

Official site: https://trontek.com/
Official e-rickshaw battery page: https://trontek.com/products/e-rickshaw-lithium-battery/

## 7.1 Current published Trontek e-rickshaw lithium variants
The official page currently exposes the following electrical variants:

| Model | Nominal Voltage | Capacity | Energy |
|---|---:|---:|---:|
| 51V 105Ah | 51 V | 105 Ah | 5.376 kWh |
| 51V 132Ah | 51 V | 132 Ah | 6.758 kWh |
| 51V 153Ah | 51 V | 153 Ah | 7.834 kWh |
| 51V 232Ah | 51 V | 232 Ah | 11.878 kWh |
| 61V 105Ah | 61 V | 105 Ah | 6.405 kWh |
| 61V 132Ah | 61 V | 132 Ah | 8.052 kWh |
| 61V 153Ah | 61 V | 153 Ah | 9.333 kWh |
| 61V 232Ah | 61 V | 232 Ah | 14.152 kWh |
| 64V 105Ah | 64 V | 105 Ah | 6.72 kWh |
| 64V 132Ah | 64 V | 132 Ah | 8.448 kWh |
| 72V 232Ah | 72 V | 232 Ah | 16.704 kWh |

### Technology / safety claims published by Trontek
- Chemistry: **LiFePO4 / LFP** for the e-rickshaw lithium battery range
- Smart/BMS-style protection against over-charge and over-discharge
- Short-circuit protection
- Acupuncture test resistance claim
- Thermal shock resistance claim
- Vibration and shock resistance claim
- Steady output voltage
- Low self-discharge
- High temperature performance claims
- Official page describes these as suitable for commercial e-rickshaw operation

### What is NOT safe to hardcode yet
The currently indexed product page exposes voltage/capacity/energy, but does not consistently expose for every SKU:
- dimensions
- weight
- charge current
- discharge current
- cycle count
- warranty months
- exact BMS communications
- price
Therefore those fields should be `null` until the exact Trontek datasheet used by OM Motors is uploaded/verified.

### Separate research note
A government/public-sector industry document references Trontec/Trontek among Indian lithium battery pack assemblers, but this does not substitute for an individual product datasheet.

### Sources
- Trontek official home: https://trontek.com/
- Official e-rickshaw lithium page: https://trontek.com/products/e-rickshaw-lithium-battery/
- Trontek e-rickshaw battery technology article: https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/
- Public-sector industry study referencing Trontek: https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf

Verification: **Manufacturer verified for the published electrical range; missing mechanical/warranty/price fields intentionally left unpopulated.**

---

','Alternate spellings: Trontec, TronTek. Warranty, dimensions and price are not published / not verified.'),
('TRONTEK_61V_105AH_LFP','Trontek','E-rickshaw lithium','61V 105Ah','LFP','battery','active','{"Voltage":"61 V","Capacity":"105 Ah","Energy":"6.405 kWh","Chemistry":"LiFePO4 / LFP"}','["https://trontek.com/products/e-rickshaw-lithium-battery/","https://trontek.com/","https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/","https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','TRONTEK E-RICKSHAW LITHIUM BATTERIES

## Important naming note
The manufacturer currently uses the spelling **Trontek Electronics Ltd / Trontek**, not “Trontec”. For the app, store:
- `brand_display_name = Trontek`
- `alternate_search_terms = Trontec, TronTek`

Official site: https://trontek.com/
Official e-rickshaw battery page: https://trontek.com/products/e-rickshaw-lithium-battery/

## 7.1 Current published Trontek e-rickshaw lithium variants
The official page currently exposes the following electrical variants:

| Model | Nominal Voltage | Capacity | Energy |
|---|---:|---:|---:|
| 51V 105Ah | 51 V | 105 Ah | 5.376 kWh |
| 51V 132Ah | 51 V | 132 Ah | 6.758 kWh |
| 51V 153Ah | 51 V | 153 Ah | 7.834 kWh |
| 51V 232Ah | 51 V | 232 Ah | 11.878 kWh |
| 61V 105Ah | 61 V | 105 Ah | 6.405 kWh |
| 61V 132Ah | 61 V | 132 Ah | 8.052 kWh |
| 61V 153Ah | 61 V | 153 Ah | 9.333 kWh |
| 61V 232Ah | 61 V | 232 Ah | 14.152 kWh |
| 64V 105Ah | 64 V | 105 Ah | 6.72 kWh |
| 64V 132Ah | 64 V | 132 Ah | 8.448 kWh |
| 72V 232Ah | 72 V | 232 Ah | 16.704 kWh |

### Technology / safety claims published by Trontek
- Chemistry: **LiFePO4 / LFP** for the e-rickshaw lithium battery range
- Smart/BMS-style protection against over-charge and over-discharge
- Short-circuit protection
- Acupuncture test resistance claim
- Thermal shock resistance claim
- Vibration and shock resistance claim
- Steady output voltage
- Low self-discharge
- High temperature performance claims
- Official page describes these as suitable for commercial e-rickshaw operation

### What is NOT safe to hardcode yet
The currently indexed product page exposes voltage/capacity/energy, but does not consistently expose for every SKU:
- dimensions
- weight
- charge current
- discharge current
- cycle count
- warranty months
- exact BMS communications
- price
Therefore those fields should be `null` until the exact Trontek datasheet used by OM Motors is uploaded/verified.

### Separate research note
A government/public-sector industry document references Trontec/Trontek among Indian lithium battery pack assemblers, but this does not substitute for an individual product datasheet.

### Sources
- Trontek official home: https://trontek.com/
- Official e-rickshaw lithium page: https://trontek.com/products/e-rickshaw-lithium-battery/
- Trontek e-rickshaw battery technology article: https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/
- Public-sector industry study referencing Trontek: https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf

Verification: **Manufacturer verified for the published electrical range; missing mechanical/warranty/price fields intentionally left unpopulated.**

---

','Alternate spellings: Trontec, TronTek. Warranty, dimensions and price are not published / not verified.'),
('TRONTEK_61V_132AH_LFP','Trontek','E-rickshaw lithium','61V 132Ah','LFP','battery','active','{"Voltage":"61 V","Capacity":"132 Ah","Energy":"8.052 kWh","Chemistry":"LiFePO4 / LFP"}','["https://trontek.com/products/e-rickshaw-lithium-battery/","https://trontek.com/","https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/","https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','TRONTEK E-RICKSHAW LITHIUM BATTERIES

## Important naming note
The manufacturer currently uses the spelling **Trontek Electronics Ltd / Trontek**, not “Trontec”. For the app, store:
- `brand_display_name = Trontek`
- `alternate_search_terms = Trontec, TronTek`

Official site: https://trontek.com/
Official e-rickshaw battery page: https://trontek.com/products/e-rickshaw-lithium-battery/

## 7.1 Current published Trontek e-rickshaw lithium variants
The official page currently exposes the following electrical variants:

| Model | Nominal Voltage | Capacity | Energy |
|---|---:|---:|---:|
| 51V 105Ah | 51 V | 105 Ah | 5.376 kWh |
| 51V 132Ah | 51 V | 132 Ah | 6.758 kWh |
| 51V 153Ah | 51 V | 153 Ah | 7.834 kWh |
| 51V 232Ah | 51 V | 232 Ah | 11.878 kWh |
| 61V 105Ah | 61 V | 105 Ah | 6.405 kWh |
| 61V 132Ah | 61 V | 132 Ah | 8.052 kWh |
| 61V 153Ah | 61 V | 153 Ah | 9.333 kWh |
| 61V 232Ah | 61 V | 232 Ah | 14.152 kWh |
| 64V 105Ah | 64 V | 105 Ah | 6.72 kWh |
| 64V 132Ah | 64 V | 132 Ah | 8.448 kWh |
| 72V 232Ah | 72 V | 232 Ah | 16.704 kWh |

### Technology / safety claims published by Trontek
- Chemistry: **LiFePO4 / LFP** for the e-rickshaw lithium battery range
- Smart/BMS-style protection against over-charge and over-discharge
- Short-circuit protection
- Acupuncture test resistance claim
- Thermal shock resistance claim
- Vibration and shock resistance claim
- Steady output voltage
- Low self-discharge
- High temperature performance claims
- Official page describes these as suitable for commercial e-rickshaw operation

### What is NOT safe to hardcode yet
The currently indexed product page exposes voltage/capacity/energy, but does not consistently expose for every SKU:
- dimensions
- weight
- charge current
- discharge current
- cycle count
- warranty months
- exact BMS communications
- price
Therefore those fields should be `null` until the exact Trontek datasheet used by OM Motors is uploaded/verified.

### Separate research note
A government/public-sector industry document references Trontec/Trontek among Indian lithium battery pack assemblers, but this does not substitute for an individual product datasheet.

### Sources
- Trontek official home: https://trontek.com/
- Official e-rickshaw lithium page: https://trontek.com/products/e-rickshaw-lithium-battery/
- Trontek e-rickshaw battery technology article: https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/
- Public-sector industry study referencing Trontek: https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf

Verification: **Manufacturer verified for the published electrical range; missing mechanical/warranty/price fields intentionally left unpopulated.**

---

','Alternate spellings: Trontec, TronTek. Warranty, dimensions and price are not published / not verified.'),
('TRONTEK_61V_153AH_LFP','Trontek','E-rickshaw lithium','61V 153Ah','LFP','battery','active','{"Voltage":"61 V","Capacity":"153 Ah","Energy":"9.333 kWh","Chemistry":"LiFePO4 / LFP"}','["https://trontek.com/products/e-rickshaw-lithium-battery/","https://trontek.com/","https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/","https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','TRONTEK E-RICKSHAW LITHIUM BATTERIES

## Important naming note
The manufacturer currently uses the spelling **Trontek Electronics Ltd / Trontek**, not “Trontec”. For the app, store:
- `brand_display_name = Trontek`
- `alternate_search_terms = Trontec, TronTek`

Official site: https://trontek.com/
Official e-rickshaw battery page: https://trontek.com/products/e-rickshaw-lithium-battery/

## 7.1 Current published Trontek e-rickshaw lithium variants
The official page currently exposes the following electrical variants:

| Model | Nominal Voltage | Capacity | Energy |
|---|---:|---:|---:|
| 51V 105Ah | 51 V | 105 Ah | 5.376 kWh |
| 51V 132Ah | 51 V | 132 Ah | 6.758 kWh |
| 51V 153Ah | 51 V | 153 Ah | 7.834 kWh |
| 51V 232Ah | 51 V | 232 Ah | 11.878 kWh |
| 61V 105Ah | 61 V | 105 Ah | 6.405 kWh |
| 61V 132Ah | 61 V | 132 Ah | 8.052 kWh |
| 61V 153Ah | 61 V | 153 Ah | 9.333 kWh |
| 61V 232Ah | 61 V | 232 Ah | 14.152 kWh |
| 64V 105Ah | 64 V | 105 Ah | 6.72 kWh |
| 64V 132Ah | 64 V | 132 Ah | 8.448 kWh |
| 72V 232Ah | 72 V | 232 Ah | 16.704 kWh |

### Technology / safety claims published by Trontek
- Chemistry: **LiFePO4 / LFP** for the e-rickshaw lithium battery range
- Smart/BMS-style protection against over-charge and over-discharge
- Short-circuit protection
- Acupuncture test resistance claim
- Thermal shock resistance claim
- Vibration and shock resistance claim
- Steady output voltage
- Low self-discharge
- High temperature performance claims
- Official page describes these as suitable for commercial e-rickshaw operation

### What is NOT safe to hardcode yet
The currently indexed product page exposes voltage/capacity/energy, but does not consistently expose for every SKU:
- dimensions
- weight
- charge current
- discharge current
- cycle count
- warranty months
- exact BMS communications
- price
Therefore those fields should be `null` until the exact Trontek datasheet used by OM Motors is uploaded/verified.

### Separate research note
A government/public-sector industry document references Trontec/Trontek among Indian lithium battery pack assemblers, but this does not substitute for an individual product datasheet.

### Sources
- Trontek official home: https://trontek.com/
- Official e-rickshaw lithium page: https://trontek.com/products/e-rickshaw-lithium-battery/
- Trontek e-rickshaw battery technology article: https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/
- Public-sector industry study referencing Trontek: https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf

Verification: **Manufacturer verified for the published electrical range; missing mechanical/warranty/price fields intentionally left unpopulated.**

---

','Alternate spellings: Trontec, TronTek. Warranty, dimensions and price are not published / not verified.'),
('TRONTEK_61V_232AH_LFP','Trontek','E-rickshaw lithium','61V 232Ah','LFP','battery','active','{"Voltage":"61 V","Capacity":"232 Ah","Energy":"14.152 kWh","Chemistry":"LiFePO4 / LFP"}','["https://trontek.com/products/e-rickshaw-lithium-battery/","https://trontek.com/","https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/","https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','TRONTEK E-RICKSHAW LITHIUM BATTERIES

## Important naming note
The manufacturer currently uses the spelling **Trontek Electronics Ltd / Trontek**, not “Trontec”. For the app, store:
- `brand_display_name = Trontek`
- `alternate_search_terms = Trontec, TronTek`

Official site: https://trontek.com/
Official e-rickshaw battery page: https://trontek.com/products/e-rickshaw-lithium-battery/

## 7.1 Current published Trontek e-rickshaw lithium variants
The official page currently exposes the following electrical variants:

| Model | Nominal Voltage | Capacity | Energy |
|---|---:|---:|---:|
| 51V 105Ah | 51 V | 105 Ah | 5.376 kWh |
| 51V 132Ah | 51 V | 132 Ah | 6.758 kWh |
| 51V 153Ah | 51 V | 153 Ah | 7.834 kWh |
| 51V 232Ah | 51 V | 232 Ah | 11.878 kWh |
| 61V 105Ah | 61 V | 105 Ah | 6.405 kWh |
| 61V 132Ah | 61 V | 132 Ah | 8.052 kWh |
| 61V 153Ah | 61 V | 153 Ah | 9.333 kWh |
| 61V 232Ah | 61 V | 232 Ah | 14.152 kWh |
| 64V 105Ah | 64 V | 105 Ah | 6.72 kWh |
| 64V 132Ah | 64 V | 132 Ah | 8.448 kWh |
| 72V 232Ah | 72 V | 232 Ah | 16.704 kWh |

### Technology / safety claims published by Trontek
- Chemistry: **LiFePO4 / LFP** for the e-rickshaw lithium battery range
- Smart/BMS-style protection against over-charge and over-discharge
- Short-circuit protection
- Acupuncture test resistance claim
- Thermal shock resistance claim
- Vibration and shock resistance claim
- Steady output voltage
- Low self-discharge
- High temperature performance claims
- Official page describes these as suitable for commercial e-rickshaw operation

### What is NOT safe to hardcode yet
The currently indexed product page exposes voltage/capacity/energy, but does not consistently expose for every SKU:
- dimensions
- weight
- charge current
- discharge current
- cycle count
- warranty months
- exact BMS communications
- price
Therefore those fields should be `null` until the exact Trontek datasheet used by OM Motors is uploaded/verified.

### Separate research note
A government/public-sector industry document references Trontec/Trontek among Indian lithium battery pack assemblers, but this does not substitute for an individual product datasheet.

### Sources
- Trontek official home: https://trontek.com/
- Official e-rickshaw lithium page: https://trontek.com/products/e-rickshaw-lithium-battery/
- Trontek e-rickshaw battery technology article: https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/
- Public-sector industry study referencing Trontek: https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf

Verification: **Manufacturer verified for the published electrical range; missing mechanical/warranty/price fields intentionally left unpopulated.**

---

','Alternate spellings: Trontec, TronTek. Warranty, dimensions and price are not published / not verified.'),
('TRONTEK_64V_105AH_LFP','Trontek','E-rickshaw lithium','64V 105Ah','LFP','battery','active','{"Voltage":"64 V","Capacity":"105 Ah","Energy":"6.72 kWh","Chemistry":"LiFePO4 / LFP"}','["https://trontek.com/products/e-rickshaw-lithium-battery/","https://trontek.com/","https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/","https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','TRONTEK E-RICKSHAW LITHIUM BATTERIES

## Important naming note
The manufacturer currently uses the spelling **Trontek Electronics Ltd / Trontek**, not “Trontec”. For the app, store:
- `brand_display_name = Trontek`
- `alternate_search_terms = Trontec, TronTek`

Official site: https://trontek.com/
Official e-rickshaw battery page: https://trontek.com/products/e-rickshaw-lithium-battery/

## 7.1 Current published Trontek e-rickshaw lithium variants
The official page currently exposes the following electrical variants:

| Model | Nominal Voltage | Capacity | Energy |
|---|---:|---:|---:|
| 51V 105Ah | 51 V | 105 Ah | 5.376 kWh |
| 51V 132Ah | 51 V | 132 Ah | 6.758 kWh |
| 51V 153Ah | 51 V | 153 Ah | 7.834 kWh |
| 51V 232Ah | 51 V | 232 Ah | 11.878 kWh |
| 61V 105Ah | 61 V | 105 Ah | 6.405 kWh |
| 61V 132Ah | 61 V | 132 Ah | 8.052 kWh |
| 61V 153Ah | 61 V | 153 Ah | 9.333 kWh |
| 61V 232Ah | 61 V | 232 Ah | 14.152 kWh |
| 64V 105Ah | 64 V | 105 Ah | 6.72 kWh |
| 64V 132Ah | 64 V | 132 Ah | 8.448 kWh |
| 72V 232Ah | 72 V | 232 Ah | 16.704 kWh |

### Technology / safety claims published by Trontek
- Chemistry: **LiFePO4 / LFP** for the e-rickshaw lithium battery range
- Smart/BMS-style protection against over-charge and over-discharge
- Short-circuit protection
- Acupuncture test resistance claim
- Thermal shock resistance claim
- Vibration and shock resistance claim
- Steady output voltage
- Low self-discharge
- High temperature performance claims
- Official page describes these as suitable for commercial e-rickshaw operation

### What is NOT safe to hardcode yet
The currently indexed product page exposes voltage/capacity/energy, but does not consistently expose for every SKU:
- dimensions
- weight
- charge current
- discharge current
- cycle count
- warranty months
- exact BMS communications
- price
Therefore those fields should be `null` until the exact Trontek datasheet used by OM Motors is uploaded/verified.

### Separate research note
A government/public-sector industry document references Trontec/Trontek among Indian lithium battery pack assemblers, but this does not substitute for an individual product datasheet.

### Sources
- Trontek official home: https://trontek.com/
- Official e-rickshaw lithium page: https://trontek.com/products/e-rickshaw-lithium-battery/
- Trontek e-rickshaw battery technology article: https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/
- Public-sector industry study referencing Trontek: https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf

Verification: **Manufacturer verified for the published electrical range; missing mechanical/warranty/price fields intentionally left unpopulated.**

---

','Alternate spellings: Trontec, TronTek. Warranty, dimensions and price are not published / not verified.'),
('TRONTEK_64V_132AH_LFP','Trontek','E-rickshaw lithium','64V 132Ah','LFP','battery','active','{"Voltage":"64 V","Capacity":"132 Ah","Energy":"8.448 kWh","Chemistry":"LiFePO4 / LFP"}','["https://trontek.com/products/e-rickshaw-lithium-battery/","https://trontek.com/","https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/","https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','TRONTEK E-RICKSHAW LITHIUM BATTERIES

## Important naming note
The manufacturer currently uses the spelling **Trontek Electronics Ltd / Trontek**, not “Trontec”. For the app, store:
- `brand_display_name = Trontek`
- `alternate_search_terms = Trontec, TronTek`

Official site: https://trontek.com/
Official e-rickshaw battery page: https://trontek.com/products/e-rickshaw-lithium-battery/

## 7.1 Current published Trontek e-rickshaw lithium variants
The official page currently exposes the following electrical variants:

| Model | Nominal Voltage | Capacity | Energy |
|---|---:|---:|---:|
| 51V 105Ah | 51 V | 105 Ah | 5.376 kWh |
| 51V 132Ah | 51 V | 132 Ah | 6.758 kWh |
| 51V 153Ah | 51 V | 153 Ah | 7.834 kWh |
| 51V 232Ah | 51 V | 232 Ah | 11.878 kWh |
| 61V 105Ah | 61 V | 105 Ah | 6.405 kWh |
| 61V 132Ah | 61 V | 132 Ah | 8.052 kWh |
| 61V 153Ah | 61 V | 153 Ah | 9.333 kWh |
| 61V 232Ah | 61 V | 232 Ah | 14.152 kWh |
| 64V 105Ah | 64 V | 105 Ah | 6.72 kWh |
| 64V 132Ah | 64 V | 132 Ah | 8.448 kWh |
| 72V 232Ah | 72 V | 232 Ah | 16.704 kWh |

### Technology / safety claims published by Trontek
- Chemistry: **LiFePO4 / LFP** for the e-rickshaw lithium battery range
- Smart/BMS-style protection against over-charge and over-discharge
- Short-circuit protection
- Acupuncture test resistance claim
- Thermal shock resistance claim
- Vibration and shock resistance claim
- Steady output voltage
- Low self-discharge
- High temperature performance claims
- Official page describes these as suitable for commercial e-rickshaw operation

### What is NOT safe to hardcode yet
The currently indexed product page exposes voltage/capacity/energy, but does not consistently expose for every SKU:
- dimensions
- weight
- charge current
- discharge current
- cycle count
- warranty months
- exact BMS communications
- price
Therefore those fields should be `null` until the exact Trontek datasheet used by OM Motors is uploaded/verified.

### Separate research note
A government/public-sector industry document references Trontec/Trontek among Indian lithium battery pack assemblers, but this does not substitute for an individual product datasheet.

### Sources
- Trontek official home: https://trontek.com/
- Official e-rickshaw lithium page: https://trontek.com/products/e-rickshaw-lithium-battery/
- Trontek e-rickshaw battery technology article: https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/
- Public-sector industry study referencing Trontek: https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf

Verification: **Manufacturer verified for the published electrical range; missing mechanical/warranty/price fields intentionally left unpopulated.**

---

','Alternate spellings: Trontec, TronTek. Warranty, dimensions and price are not published / not verified.'),
('TRONTEK_72V_232AH_LFP','Trontek','E-rickshaw lithium','72V 232Ah','LFP','battery','active','{"Voltage":"72 V","Capacity":"232 Ah","Energy":"16.704 kWh","Chemistry":"LiFePO4 / LFP"}','["https://trontek.com/products/e-rickshaw-lithium-battery/","https://trontek.com/","https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/","https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf"]','User-supplied research pack; manufacturer and secondary claims distinguished in source excerpt','2026-09-12','Manufacturer-backed fields in supplied data pack','TRONTEK E-RICKSHAW LITHIUM BATTERIES

## Important naming note
The manufacturer currently uses the spelling **Trontek Electronics Ltd / Trontek**, not “Trontec”. For the app, store:
- `brand_display_name = Trontek`
- `alternate_search_terms = Trontec, TronTek`

Official site: https://trontek.com/
Official e-rickshaw battery page: https://trontek.com/products/e-rickshaw-lithium-battery/

## 7.1 Current published Trontek e-rickshaw lithium variants
The official page currently exposes the following electrical variants:

| Model | Nominal Voltage | Capacity | Energy |
|---|---:|---:|---:|
| 51V 105Ah | 51 V | 105 Ah | 5.376 kWh |
| 51V 132Ah | 51 V | 132 Ah | 6.758 kWh |
| 51V 153Ah | 51 V | 153 Ah | 7.834 kWh |
| 51V 232Ah | 51 V | 232 Ah | 11.878 kWh |
| 61V 105Ah | 61 V | 105 Ah | 6.405 kWh |
| 61V 132Ah | 61 V | 132 Ah | 8.052 kWh |
| 61V 153Ah | 61 V | 153 Ah | 9.333 kWh |
| 61V 232Ah | 61 V | 232 Ah | 14.152 kWh |
| 64V 105Ah | 64 V | 105 Ah | 6.72 kWh |
| 64V 132Ah | 64 V | 132 Ah | 8.448 kWh |
| 72V 232Ah | 72 V | 232 Ah | 16.704 kWh |

### Technology / safety claims published by Trontek
- Chemistry: **LiFePO4 / LFP** for the e-rickshaw lithium battery range
- Smart/BMS-style protection against over-charge and over-discharge
- Short-circuit protection
- Acupuncture test resistance claim
- Thermal shock resistance claim
- Vibration and shock resistance claim
- Steady output voltage
- Low self-discharge
- High temperature performance claims
- Official page describes these as suitable for commercial e-rickshaw operation

### What is NOT safe to hardcode yet
The currently indexed product page exposes voltage/capacity/energy, but does not consistently expose for every SKU:
- dimensions
- weight
- charge current
- discharge current
- cycle count
- warranty months
- exact BMS communications
- price
Therefore those fields should be `null` until the exact Trontek datasheet used by OM Motors is uploaded/verified.

### Separate research note
A government/public-sector industry document references Trontec/Trontek among Indian lithium battery pack assemblers, but this does not substitute for an individual product datasheet.

### Sources
- Trontek official home: https://trontek.com/
- Official e-rickshaw lithium page: https://trontek.com/products/e-rickshaw-lithium-battery/
- Trontek e-rickshaw battery technology article: https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/
- Public-sector industry study referencing Trontek: https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf

Verification: **Manufacturer verified for the published electrical range; missing mechanical/warranty/price fields intentionally left unpopulated.**

---

','Alternate spellings: Trontec, TronTek. Warranty, dimensions and price are not published / not verified.')
ON CONFLICT(code) DO UPDATE SET specs=excluded.specs,source_urls=excluded.source_urls,source_type=excluded.source_type,source_checked_on=excluded.source_checked_on,verification_status=excluded.verification_status,source_excerpt=excluded.source_excerpt,notes=excluded.notes;


NOTIFY pgrst, 'reload schema';
COMMIT;
