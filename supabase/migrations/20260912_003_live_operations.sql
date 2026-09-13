-- Operational persistence upgrade. Apply after the initial schema and access migration.
BEGIN;
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
COMMIT;


