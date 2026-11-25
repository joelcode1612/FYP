-- SUPABASE ONLY. Rollback for 20261124_assignment_sync_retirement_supabase.sql.
-- Restores the Supabase mirror surface exactly as the pre-retirement install
-- created it: fyp.agent_listing_assignment (canonical column contract),
-- fyp.assignment_sync_receipts, and the fyp.sync_agent_assignment RPC with its
-- original idempotency, mapping, and security behaviour. Rows archived by the
-- retirement are restored when the archive tables exist.
--
-- Identity and revision continuity: receipts are restored with their original
-- revisions. Post-rollback events emitted by the restored local outbox carry
-- revisions strictly greater than anything archived (the local rollback
-- advances sitewise_sync.assignment_revision past the archived maximum), so
-- no restored receipt can mask a new event as already_applied.
--
-- Run as DB owner / migration editor (service_role equivalent).

\set ON_ERROR_STOP on

BEGIN;

DO $preflight$
BEGIN
    IF to_regclass('fyp.agent_listing_assignment') IS NOT NULL THEN
        RAISE EXCEPTION 'fyp.agent_listing_assignment still exists; retirement has not run';
    END IF;
    IF to_regprocedure('fyp.sync_agent_assignment(bigint,bigint,text,jsonb)') IS NOT NULL THEN
        RAISE EXCEPTION 'fyp.sync_agent_assignment still exists; retirement has not run';
    END IF;
    IF to_regclass('public.pano_listing_links') IS NULL THEN
        RAISE EXCEPTION 'public.pano_listing_links is absent; confirm this is the correct Supabase project';
    END IF;
END
$preflight$;

-- 1. Recreate the mirror table on the canonical column contract (identical to
--    local fyp.agent_listing_assignment; listing_id stays the LOCAL id).
CREATE TABLE IF NOT EXISTS fyp.agent_listing_assignment (
    listing_id          bigint NOT NULL,
    agent_id            integer NOT NULL,
    assigned_by_user_id uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    workflow_status     text DEFAULT 'requested',
    requested_at        timestamptz DEFAULT now(),
    responded_at        timestamptz,
    inspection_data     jsonb DEFAULT '{}'::jsonb,
    inspection_updated_at timestamptz,
    panorama_id         uuid,
    panorama_tour_id    uuid,
    panorama_job_id     text,
    panorama_uploaded_at timestamptz,
    submitted_at        timestamptz,
    decline_reason      text,
    CONSTRAINT agent_listing_assignment_pkey PRIMARY KEY (listing_id),
    CONSTRAINT agent_listing_assignment_listing_id_fkey
        FOREIGN KEY (listing_id) REFERENCES fyp.rental_properties(id)
        ON DELETE CASCADE
);

-- 2. Restore archived mirror rows (archive holds the pre-retirement state).
DO $restore_mirror$
BEGIN
    IF to_regclass('fyp.assignment_mirror_archive_20261124') IS NOT NULL THEN
        EXECUTE '
            INSERT INTO fyp.agent_listing_assignment (
                listing_id, agent_id, assigned_by_user_id, created_at, updated_at,
                workflow_status, requested_at, responded_at, inspection_data,
                inspection_updated_at, panorama_id, panorama_tour_id, panorama_job_id,
                panorama_uploaded_at, submitted_at, decline_reason)
            SELECT listing_id, agent_id, assigned_by_user_id, created_at, updated_at,
                workflow_status, requested_at, responded_at, inspection_data,
                inspection_updated_at, panorama_id, panorama_tour_id, panorama_job_id,
                panorama_uploaded_at, submitted_at, decline_reason
            FROM fyp.assignment_mirror_archive_20261124
            ON CONFLICT (listing_id) DO NOTHING';
    END IF;
END
$restore_mirror$;

-- 3. Mirror security posture: backend-owned, service_role only.
ALTER TABLE fyp.agent_listing_assignment ENABLE ROW LEVEL SECURITY;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON fyp.agent_listing_assignment FROM PUBLIC,anon,authenticated;
REVOKE SELECT ON fyp.agent_listing_assignment FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON fyp.agent_listing_assignment TO service_role;

-- 4. Recreate the receipts table (revisioned, idempotent replays).
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

DO $restore_receipts$
BEGIN
    IF to_regclass('fyp.assignment_receipts_archive_20261124') IS NOT NULL THEN
        EXECUTE '
            INSERT INTO fyp.assignment_sync_receipts (
                local_listing_id, remote_listing_id, revision, operation, synced_at)
            SELECT local_listing_id, remote_listing_id, revision, operation, synced_at
            FROM fyp.assignment_receipts_archive_20261124
            ON CONFLICT (local_listing_id) DO NOTHING';
    END IF;
END
$restore_receipts$;

-- 5. Recreate the mirror RPC verbatim (original install contract).
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

DO $final_check$
BEGIN
    IF to_regclass('fyp.agent_listing_assignment') IS NULL
       OR to_regclass('fyp.assignment_sync_receipts') IS NULL
       OR to_regprocedure('fyp.sync_agent_assignment(bigint,bigint,text,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Rollback verification failed: restored mirror objects missing';
    END IF;
    IF to_regclass('public.pano_listing_links') IS NULL THEN
        RAISE EXCEPTION 'Rollback verification failed: pano_listing_links missing';
    END IF;
END
$final_check$;

NOTIFY pgrst, 'reload schema';

COMMIT;
