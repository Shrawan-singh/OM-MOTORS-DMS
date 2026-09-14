-- ============================================================================
-- Migration: Receivables & Collections Management
-- Version: 20260914_013
-- Adds invoice due dates, customer credit parameters, and collection follow-ups
-- ============================================================================

BEGIN;

-- 1. Extend billing_documents with due_date
ALTER TABLE public.billing_documents ADD COLUMN IF NOT EXISTS due_date date;
UPDATE public.billing_documents
SET due_date = coalesce(due_date, document_date)
WHERE kind = 'invoice' AND due_date IS NULL;

-- 2. Extend customers with credit and collection fields
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS credit_limit numeric(12,2) NOT NULL DEFAULT 0;
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS payment_terms_days integer NOT NULL DEFAULT 15;
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS collection_priority text NOT NULL DEFAULT 'normal' CHECK (collection_priority IN ('low','normal','high','critical'));

-- 3. Create collection_followups table
CREATE TABLE IF NOT EXISTS public.collection_followups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  invoice_id uuid REFERENCES public.billing_documents(id) ON DELETE SET NULL,
  contact_method text NOT NULL CHECK (contact_method IN ('phone', 'whatsapp', 'in_person', 'notice')),
  contacted_at timestamptz NOT NULL DEFAULT now(),
  notes text NOT NULL CHECK (length(trim(notes)) >= 2),
  ptp_date date,
  ptp_amount numeric(12,2) CHECK (ptp_amount IS NULL OR ptp_amount >= 0),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'honoured', 'broken', 'cancelled')),
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_collection_followups_cust ON public.collection_followups(customer_id);
CREATE INDEX IF NOT EXISTS idx_collection_followups_inv ON public.collection_followups(invoice_id);
CREATE INDEX IF NOT EXISTS idx_collection_followups_ptp ON public.collection_followups(ptp_date) WHERE status = 'pending';

-- 4. Enable Row Level Security on collection_followups
ALTER TABLE public.collection_followups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS collection_followups_read ON public.collection_followups;
CREATE POLICY collection_followups_read ON public.collection_followups
  FOR SELECT TO authenticated
  USING (public.has_permission('invoices.read') OR public.has_permission('customers.read'));

DROP POLICY IF EXISTS collection_followups_insert ON public.collection_followups;
CREATE POLICY collection_followups_insert ON public.collection_followups
  FOR INSERT TO authenticated
  WITH CHECK (public.has_permission('invoices.write') OR public.has_permission('customers.write'));

DROP POLICY IF EXISTS collection_followups_update ON public.collection_followups;
CREATE POLICY collection_followups_update ON public.collection_followups
  FOR UPDATE TO authenticated
  USING (public.has_permission('invoices.write') OR public.has_permission('customers.write'))
  WITH CHECK (public.has_permission('invoices.write') OR public.has_permission('customers.write'));

REVOKE ALL ON public.collection_followups FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.collection_followups TO authenticated;

-- 5. Update ws_base_save_document to save due_date for invoices
CREATE OR REPLACE FUNCTION public.ws_base_save_document(p_doc jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE old public.billing_documents; saved public.billing_documents; customer public.customers; seller public.business_profile;
 doc_id uuid; doc_kind text:=p_doc->>'kind'; doc_number text; row jsonb; normalized jsonb:='[]'; qty numeric; price numeric; discount numeric; gst numeric; taxable numeric; tax numeric;
 net numeric:=0; taxes numeric:=0; inventory_id uuid; product_id uuid; change record; source_id uuid; source_doc public.billing_documents;
 doc_due_date date := NULL;
BEGIN
 IF doc_kind NOT IN ('quotation','invoice') OR doc_kind IS NULL THEN RAISE EXCEPTION 'Invalid document type'; END IF;
 IF NOT public.has_permission(CASE doc_kind WHEN 'invoice' THEN 'invoices.write' ELSE 'quotations.write' END) THEN RAISE EXCEPTION 'Document edit permission required'; END IF;
 doc_id:=coalesce(nullif(p_doc->>'id','')::uuid,gen_random_uuid());
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
 IF doc_kind='invoice' THEN
  doc_due_date := coalesce(nullif(p_doc->>'dueDate','')::date, ((p_doc->>'date')::date + ((customer.payment_terms_days || ' days')::interval))::date);
 END IF;
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
  FOR change IN WITH new_qty AS (SELECT (v->>'inventoryId')::uuid id,sum((v->>'qty')::integer) qty FROM jsonb_array_elements(normalized) v WHERE v->>'inventoryId' IS NOT NULL GROUP BY 1),
  old_qty AS (SELECT (v->>'inventoryId')::uuid id,sum((v->>'qty')::integer) qty FROM jsonb_array_elements(coalesce(old.items,'[]')) v WHERE v->>'inventoryId' IS NOT NULL GROUP BY 1)
  SELECT coalesce(n.id,o.id) id,(coalesce(o.qty,0)-coalesce(n.qty,0))::integer delta FROM new_qty n FULL JOIN old_qty o USING(id) ORDER BY 1 LOOP
   PERFORM public.app_move_stock(change.id,change.delta,doc_number);
  END LOOP;
 END IF;
 INSERT INTO public.billing_documents(id,kind,number,customer_id,customer_snapshot,seller_snapshot,document_date,valid_until,due_date,items,subtotal,tax_amount,total,amount_paid,tax_mode,notes,source_quotation_id,created_by)
 VALUES(doc_id,doc_kind,doc_number,customer.id,jsonb_build_object('name',customer.name,'phone',customer.phone,'village',customer.village,'address',customer.address,'gstin',customer.gstin),to_jsonb(seller),(p_doc->>'date')::date,CASE WHEN doc_kind='quotation' THEN nullif(p_doc->>'validUntil','')::date ELSE NULL END,doc_due_date,normalized,net,taxes,net+taxes,coalesce(old.amount_paid,0),p_doc->>'taxMode',coalesce(p_doc->>'notes',''),source_id,auth.uid())
 ON CONFLICT(id) DO UPDATE SET number=excluded.number,customer_id=excluded.customer_id,customer_snapshot=excluded.customer_snapshot,seller_snapshot=excluded.seller_snapshot,document_date=excluded.document_date,valid_until=excluded.valid_until,due_date=coalesce(excluded.due_date, billing_documents.due_date),items=excluded.items,subtotal=excluded.subtotal,tax_amount=excluded.tax_amount,total=excluded.total,tax_mode=excluded.tax_mode,notes=excluded.notes,updated_at=clock_timestamp() RETURNING * INTO saved;
 INSERT INTO public.billing_audit(document_id,actor,before_record,after_record) VALUES(saved.id,auth.uid(),CASE WHEN old.id IS NULL THEN NULL ELSE to_jsonb(old) END,to_jsonb(saved));
 RETURN to_jsonb(saved);
END $$;

-- 6. RPC to log a follow-up / Promise to Pay
CREATE OR REPLACE FUNCTION public.app_log_collection_followup(
  p_customer uuid,
  p_invoice uuid,
  p_method text,
  p_notes text,
  p_ptp_date date,
  p_ptp_amount numeric
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_rec public.collection_followups;
  v_cust public.customers;
  v_inv_num text := '';
BEGIN
  IF NOT (public.has_permission('invoices.write') OR public.has_permission('customers.write')) THEN
    RAISE EXCEPTION 'Permission required to log collection follow-up';
  END IF;

  SELECT * INTO v_cust FROM public.customers WHERE id = p_customer;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Customer not found';
  END IF;

  IF p_invoice IS NOT NULL THEN
    SELECT number INTO v_inv_num FROM public.billing_documents WHERE id = p_invoice AND customer_id = p_customer;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Invoice does not match customer';
    END IF;
  END IF;

  INSERT INTO public.collection_followups(customer_id, invoice_id, contact_method, notes, ptp_date, ptp_amount, created_by)
  VALUES (p_customer, p_invoice, p_method, trim(p_notes), p_ptp_date, p_ptp_amount, auth.uid())
  RETURNING * INTO v_rec;

  -- Insert timeline entry
  INSERT INTO public.customer_timeline(customer_id, event_type, description, reference_id)
  VALUES (
    p_customer,
    'collection_followup',
    'Follow-up via ' || upper(p_method) || ': ' || trim(p_notes) ||
      CASE WHEN p_ptp_date IS NOT NULL THEN ' (PTP: ' || p_ptp_date::text || ' ₹' || coalesce(p_ptp_amount, 0)::text || ')' ELSE '' END,
    coalesce(v_inv_num, v_rec.id::text)
  );

  RETURN to_jsonb(v_rec);
END;
$$;

-- 7. RPC to update followup status
CREATE OR REPLACE FUNCTION public.app_update_followup_status(
  p_id uuid,
  p_status text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT (public.has_permission('invoices.write') OR public.has_permission('customers.write')) THEN
    RAISE EXCEPTION 'Permission required to update collection follow-up';
  END IF;

  IF p_status NOT IN ('pending', 'honoured', 'broken', 'cancelled') THEN
    RAISE EXCEPTION 'Invalid follow-up status';
  END IF;

  UPDATE public.collection_followups
  SET status = p_status
  WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Follow-up not found';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.app_log_collection_followup(uuid,uuid,text,text,date,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_update_followup_status(uuid,text) TO authenticated;

COMMIT;
