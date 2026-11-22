-- SUPABASE ONLY. Inspect the existing assignment foreign keys before running.
-- Local listing_id maps explicitly to public.property.property_id using the
-- existing panorama mapping table. No equal-ID assumption.
BEGIN;
DO $$
DECLARE missing text;
BEGIN
 IF to_regclass('fyp.agent_listing_assignment') IS NULL OR to_regclass('public.property') IS NULL THEN
  RAISE EXCEPTION 'Existing fyp.agent_listing_assignment and public.property required';
 END IF;
 IF EXISTS (
   SELECT 1 FROM pg_constraint c
   JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=ANY(c.conkey)
   WHERE c.conrelid='fyp.agent_listing_assignment'::regclass AND c.contype='f'
     AND a.attname='listing_id' AND c.confrelid <> 'public.property'::regclass
 ) THEN RAISE EXCEPTION 'listing_id references a different table; review mapping before installation'; END IF;
 SELECT string_agg(v.name,', ') INTO missing FROM unnest(ARRAY[
 'listing_id','agent_id','assigned_by_user_id','workflow_status','requested_at','responded_at',
 'inspection_data','inspection_updated_at','panorama_id','panorama_tour_id','panorama_job_id',
 'panorama_uploaded_at','submitted_at','decline_reason','created_at','updated_at']) v(name)
 WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c WHERE c.table_schema='public'
 AND c.table_name='agent_listing_assignment' AND c.column_name=v.name);
 IF missing IS NOT NULL THEN RAISE EXCEPTION 'Missing assignment columns: %',missing; END IF;
END $$;
-- Reuse the existing admin-verified panorama link if installed. If absent,
-- local listing IDs are external references, not a foreign key in this DB.
CREATE TABLE IF NOT EXISTS public.pano_listing_links (
 listing_id bigint PRIMARY KEY,
 public_property_id bigint NOT NULL UNIQUE REFERENCES public.property(property_id) ON DELETE RESTRICT,
 linked_by uuid NOT NULL REFERENCES public.users(user_id),
 linked_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pano_listing_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pano_listing_links FROM anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.pano_listing_links TO service_role;
CREATE TABLE IF NOT EXISTS public.assignment_sync_receipts (
 local_listing_id bigint PRIMARY KEY,
 remote_listing_id bigint NOT NULL UNIQUE,
 revision bigint NOT NULL,
 operation text NOT NULL CHECK(operation IN ('upsert','delete')),
 synced_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.assignment_sync_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.assignment_sync_receipts FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.assignment_sync_receipts TO service_role;
-- Mirror is backend-owned; existing RLS policies must not grant client writes.
ALTER TABLE fyp.agent_listing_assignment ENABLE ROW LEVEL SECURITY;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON fyp.agent_listing_assignment FROM PUBLIC,anon,authenticated;
-- Inspection records are private. Both FYP viewers and staff read through FastAPI.
REVOKE SELECT ON fyp.agent_listing_assignment FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON fyp.agent_listing_assignment TO service_role;
CREATE OR REPLACE FUNCTION public.sync_agent_assignment(p_listing_id bigint,p_revision bigint,p_operation text,p_snapshot jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public AS $$
DECLARE
 remote_id bigint; receipt public.assignment_sync_receipts%ROWTYPE;
 incoming fyp.agent_listing_assignment%ROWTYPE;
BEGIN
 IF p_listing_id IS NULL OR p_listing_id <= 0 OR p_revision IS NULL OR p_revision <= 0
 OR p_operation IS NULL OR p_operation NOT IN ('upsert','delete') THEN
   RAISE EXCEPTION 'invalid sync event';
 END IF;
 -- Serialise all versions for this source ID, including concurrent retries.
 PERFORM pg_advisory_xact_lock(hashtextextended('sitewise_assignment:'||p_listing_id::text,0));
 SELECT * INTO receipt FROM public.assignment_sync_receipts WHERE local_listing_id=p_listing_id;
 IF FOUND AND receipt.revision >= p_revision THEN
   RETURN jsonb_build_object('status','already_applied','revision',receipt.revision);
 END IF;
 -- For a previously mirrored assignment, keep the original identity for deletion.
 IF p_operation='delete' AND receipt.local_listing_id IS NOT NULL THEN
   remote_id := receipt.remote_listing_id;
 ELSE
   SELECT public_property_id INTO remote_id FROM public.pano_listing_links WHERE listing_id=p_listing_id;
 END IF;
 IF remote_id IS NULL THEN RETURN jsonb_build_object('status','mapping_required'); END IF;
 IF receipt.local_listing_id IS NOT NULL AND receipt.remote_listing_id <> remote_id THEN
   RETURN jsonb_build_object('status','mapping_changed');
 END IF;
 IF EXISTS (SELECT 1 FROM public.assignment_sync_receipts WHERE remote_listing_id=remote_id AND local_listing_id<>p_listing_id) THEN
   RETURN jsonb_build_object('status','mapping_conflict');
 END IF;
 IF p_operation='delete' THEN
   -- Never remove an independently created row without a prior sync receipt.
   IF receipt.local_listing_id IS NULL AND EXISTS(SELECT 1 FROM fyp.agent_listing_assignment WHERE listing_id=remote_id) THEN
     RETURN jsonb_build_object('status','unowned_remote_row');
   END IF;
   DELETE FROM fyp.agent_listing_assignment WHERE listing_id=remote_id;
 ELSE
   IF jsonb_typeof(p_snapshot) IS DISTINCT FROM 'object' OR (p_snapshot->>'listing_id')::bigint IS DISTINCT FROM p_listing_id THEN
     RAISE EXCEPTION 'invalid assignment snapshot';
   END IF;
   IF NOT EXISTS(SELECT 1 FROM public.property WHERE property_id=remote_id) THEN
     RETURN jsonb_build_object('status','property_missing');
   END IF;
   incoming := jsonb_populate_record(NULL::fyp.agent_listing_assignment,p_snapshot || jsonb_build_object('listing_id',remote_id));
   IF NOT EXISTS(SELECT 1 FROM public.agent WHERE agent_id=incoming.agent_id AND user_id IS NOT NULL) THEN
     RETURN jsonb_build_object('status','agent_missing');
   END IF;
   -- Local is authoritative; explicit link identifies the target row. Do not
   -- remap remote panorama references: FK rejection stays pending for review.
   INSERT INTO fyp.agent_listing_assignment(listing_id,agent_id,assigned_by_user_id,workflow_status,requested_at,responded_at,
    inspection_data,inspection_updated_at,panorama_id,panorama_tour_id,panorama_job_id,panorama_uploaded_at,submitted_at,decline_reason,created_at,updated_at)
   VALUES(remote_id,incoming.agent_id,incoming.assigned_by_user_id,incoming.workflow_status,incoming.requested_at,incoming.responded_at,
    incoming.inspection_data,incoming.inspection_updated_at,incoming.panorama_id,incoming.panorama_tour_id,incoming.panorama_job_id,incoming.panorama_uploaded_at,
    incoming.submitted_at,incoming.decline_reason,incoming.created_at,incoming.updated_at)
   ON CONFLICT(listing_id) DO UPDATE SET agent_id=excluded.agent_id,assigned_by_user_id=excluded.assigned_by_user_id,
    workflow_status=excluded.workflow_status,requested_at=excluded.requested_at,responded_at=excluded.responded_at,
    inspection_data=excluded.inspection_data,inspection_updated_at=excluded.inspection_updated_at,panorama_id=excluded.panorama_id,
    panorama_tour_id=excluded.panorama_tour_id,panorama_job_id=excluded.panorama_job_id,panorama_uploaded_at=excluded.panorama_uploaded_at,
    submitted_at=excluded.submitted_at,decline_reason=excluded.decline_reason,created_at=excluded.created_at,updated_at=excluded.updated_at;
 END IF;
 INSERT INTO public.assignment_sync_receipts(local_listing_id,remote_listing_id,revision,operation)
 VALUES(p_listing_id,remote_id,p_revision,p_operation)
 ON CONFLICT(local_listing_id) DO UPDATE SET revision=excluded.revision,operation=excluded.operation,synced_at=now();
 RETURN jsonb_build_object('status','applied','revision',p_revision);
END $$;
REVOKE ALL ON FUNCTION public.sync_agent_assignment(bigint,bigint,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sync_agent_assignment(bigint,bigint,text,jsonb) TO service_role;
NOTIFY pgrst, 'reload schema';
COMMIT;
