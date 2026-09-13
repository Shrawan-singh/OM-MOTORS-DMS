BEGIN;
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
COMMIT;
