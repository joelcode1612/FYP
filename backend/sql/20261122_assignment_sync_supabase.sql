-- SUPABASE ONLY. Run AFTER 20261121_public_panorama_listing_links.sql and
-- AFTER the 03 schema migration (fyp schema live). Installs the assignment
-- mirror RPC in the fyp schema — the worker calls
-- /rest/v1/rpc/sync_agent_assignment with Content-Profile: fyp.
--
-- Post-migration contract (schema migration 03 applied):
-- * The mirror target is fyp.agent_listing_assignment; its listing_id is a
--   FOREIGN KEY to fyp.rental_properties(id). Assignment rows can only ever
--   reference real catalogue properties on both sides.
-- * The verified local->remote property mapping is public.pano_listing_links
--   (admin-created; equal IDs are never assumed). Without a link the RPC
--   reports mapping_required and the worker holds the event for review.
-- * Preserve existing assignment identities: the LOCAL listing_id stays
--   authoritative; the remote row is keyed by the mapped remote id and
--   revisioned receipts make replays idempotent.
BEGIN;
DO $$
DECLARE missing text;
BEGIN
 IF to_regclass('fyp.agent_listing_assignment') IS NULL THEN
  RAISE EXCEPTION 'Existing fyp.agent_listing_assignment required';
 END IF;
 IF to_regclass('public.pano_listing_links') IS NULL THEN
  RAISE EXCEPTION 'Run 20261121_public_panorama_listing_links.sql first';
 END IF;
 IF EXISTS (
   SELECT 1 FROM pg_constraint c
   JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=ANY(c.conkey)
   WHERE c.conrelid='fyp.agent_listing_assignment'::regclass AND c.contype='f'
     AND a.attname='listing_id' AND c.confrelid <> 'fyp.rental_properties'::regclass
 ) THEN RAISE EXCEPTION 'listing_id references a different table; review mapping before installation'; END IF;
 SELECT string_agg(v.name,', ') INTO missing FROM unnest(ARRAY[
 'listing_id','agent_id','assigned_by_user_id','workflow_status','requested_at','responded_at',
 'inspection_data','inspection_updated_at','panorama_id','panorama_tour_id','panorama_job_id',
 'panorama_uploaded_at','submitted_at','decline_reason','created_at','updated_at']) v(name)
 WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c WHERE c.table_schema='fyp'
 AND c.table_name='agent_listing_assignment' AND c.column_name=v.name);
 IF missing IS NOT NULL THEN RAISE EXCEPTION 'Missing assignment columns: %',missing; END IF;
END $$;
-- Revisioned receipts make every replay idempotent. They live beside the
-- mirror target in the service_role-only fyp schema (locked down by the 03
-- migration; explicit grants below re-assert for this new table).
CREATE TABLE IF NOT EXISTS fyp.assignment_sync_receipts (
 local_listing_id bigint PRIMARY KEY,
 remote_listing_id bigint NOT NULL UNIQUE,
 revision bigint NOT NULL,
 operation text NOT NULL CHECK(operation IN ('upsert','delete')),
 synced_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE fyp.assignment_sync_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON fyp.assignment_sync_receipts FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON fyp.assignment_sync_receipts TO service_role;
-- Mirror is backend-owned; existing RLS policies must not grant client writes.
ALTER TABLE fyp.agent_listing_assignment ENABLE ROW LEVEL SECURITY;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON fyp.agent_listing_assignment FROM PUBLIC,anon,authenticated;
-- Inspection records are private. Both FYP viewers and staff read through FastAPI.
REVOKE SELECT ON fyp.agent_listing_assignment FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON fyp.agent_listing_assignment TO service_role;
CREATE OR REPLACE FUNCTION fyp.sync_agent_assignment(p_listing_id bigint,p_revision bigint,p_operation text,p_snapshot jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public,fyp AS $$
DECLARE
 remote_id bigint; receipt fyp.assignment_sync_receipts%ROWTYPE;
 incoming fyp.agent_listing_assignment%ROWTYPE;
BEGIN
 IF p_listing_id IS NULL OR p_listing_id <= 0 OR p_revision IS NULL OR p_revision <= 0
 OR p_operation IS NULL OR p_operation NOT IN ('upsert','delete') THEN
   RAISE EXCEPTION 'invalid sync event';
 END IF;
 -- Serialise all versions for this source ID, including concurrent retries.
 PERFORM pg_advisory_xact_lock(hashtextextended('sitewise_assignment:'||p_listing_id::text,0));
 SELECT * INTO receipt FROM fyp.assignment_sync_receipts WHERE local_listing_id=p_listing_id;
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
 IF EXISTS (SELECT 1 FROM fyp.assignment_sync_receipts WHERE remote_listing_id=remote_id AND local_listing_id<>p_listing_id) THEN
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
   IF NOT EXISTS(SELECT 1 FROM fyp.rental_properties WHERE id=remote_id) THEN
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
 INSERT INTO fyp.assignment_sync_receipts(local_listing_id,remote_listing_id,revision,operation)
 VALUES(p_listing_id,remote_id,p_revision,p_operation)
 ON CONFLICT(local_listing_id) DO UPDATE SET revision=excluded.revision,operation=excluded.operation,synced_at=now();
 RETURN jsonb_build_object('status','applied','revision',p_revision);
END $$;
REVOKE ALL ON FUNCTION fyp.sync_agent_assignment(bigint,bigint,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION fyp.sync_agent_assignment(bigint,bigint,text,jsonb) TO service_role;
NOTIFY pgrst, 'reload schema';
COMMIT;
