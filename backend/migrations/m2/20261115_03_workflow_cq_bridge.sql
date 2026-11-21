BEGIN;
SET LOCAL lock_timeout='5s';
DO $$ BEGIN
 IF current_setting('project1.m2_bcb_migration_target',true) IS DISTINCT FROM current_database()
 OR nullif(current_setting('project1.m2_bcb_migration_receipt',true),'') IS NULL THEN
 RAISE EXCEPTION 'Explicit migration target and receipt required'; END IF;
END $$;
CREATE OR REPLACE VIEW public.m2_workflow_campaigns WITH (security_invoker=true) AS
 SELECT c.assessment_id,c.owner_user_id,jsonb_agg(jsonb_build_object(
 'campaign_id',c.id,'release_id',c.release_id,'manifest_hash',r.manifest_hash,
 'source_class',r.source_class,'sessions',(SELECT count(*) FROM public.cq_sessions s WHERE s.campaign_id=c.id),
 'receipts',(SELECT count(*) FROM public.cq_submission_receipts t JOIN public.cq_sessions s ON s.id=t.session_id WHERE s.campaign_id=c.id))
 ORDER BY c.id) AS campaigns FROM public.cq_campaigns c JOIN public.cq_manifest_releases r ON r.id=c.release_id GROUP BY c.assessment_id,c.owner_user_id;
CREATE FUNCTION public.m2_workflow_cq_change() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE aid uuid;
BEGIN
 IF TG_TABLE_NAME='cq_campaigns' THEN aid:=NEW.assessment_id;
 ELSIF TG_TABLE_NAME='cq_sessions' THEN SELECT assessment_id INTO aid FROM public.cq_campaigns WHERE id=NEW.campaign_id;
 ELSE SELECT c.assessment_id INTO aid FROM public.cq_campaigns c JOIN public.cq_sessions s ON s.campaign_id=c.id WHERE s.id=NEW.session_id;
 END IF;
 PERFORM public.refresh_m2_workflow(aid);
 RETURN NULL;
END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['cq_campaigns','cq_sessions','cq_submission_receipts'] LOOP
 EXECUTE format('CREATE CONSTRAINT TRIGGER refresh_cq_workflow AFTER INSERT ON public.%I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_cq_change()',t);
 END LOOP;
END $$;
SELECT public.refresh_m2_workflow(assessment_id) FROM public.cq_campaigns GROUP BY assessment_id ORDER BY assessment_id;
REVOKE ALL ON FUNCTION public.m2_workflow_cq_change() FROM PUBLIC;
COMMIT;
