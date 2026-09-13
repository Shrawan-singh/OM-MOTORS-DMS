BEGIN;
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
COMMIT;
