-- LOCAL POSTGRESQL ONLY (Final_Location_Analysis)
-- Rollback for 20261124_assignment_sync_retirement_local.sql.
-- Restores the local assignment outbox exactly as it existed before retirement:
-- trigger, capture/enqueue functions, outbox table, revision sequence, and the
-- archived events. Run only as the application's DB owner.
--
-- Revision continuity: a freshly created sequence would restart at 1, which
-- any surviving Supabase receipt (revision >= that value) would reject as
-- already_applied. This script therefore reloads the archived events with
-- their original revisions and then advances the sequence beyond the highest
-- archived revision before re-enqueueing the current canonical state, so every
-- post-rollback event has a revision strictly greater than anything recorded
-- before retirement.
--
-- Rollback of the rollback: re-run 20261124_assignment_sync_retirement_local.sql.
-- The archive table is intentionally retained as an audit artifact.

\set ON_ERROR_STOP on

BEGIN;

DO $preflight$
DECLARE trigger_oid oid;
BEGIN
    IF current_database() <> 'Final_Location_Analysis' THEN
        RAISE EXCEPTION 'Run this rollback on Final_Location_Analysis, got %', current_database();
    END IF;
    IF to_regclass('fyp.agent_listing_assignment') IS NULL THEN
        RAISE EXCEPTION 'Canonical fyp.agent_listing_assignment is required';
    END IF;
    IF to_regclass('sitewise_sync.assignment_outbox') IS NOT NULL THEN
        RAISE EXCEPTION 'sitewise_sync.assignment_outbox still exists; retirement has not run';
    END IF;
    IF to_regprocedure('sitewise_sync.capture_assignment_change()') IS NOT NULL THEN
        RAISE EXCEPTION 'capture_assignment_change() still exists; retirement has not run';
    END IF;
    IF to_regclass('sitewise_sync.assignment_outbox_archive_20261124') IS NULL THEN
        RAISE EXCEPTION 'Archive table sitewise_sync.assignment_outbox_archive_20261124 is missing; nothing to restore';
    END IF;
    trigger_oid := to_regprocedure('sitewise_sync.capture_assignment_change()');
    IF trigger_oid IS NOT NULL AND EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'fyp.agent_listing_assignment'::regclass
          AND tgname = 'sitewise_assignment_sync'
          AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION 'sitewise_assignment_sync trigger still present; retirement has not run';
    END IF;
END
$preflight$;

-- 1. Restore the sequence, outbox table, and functions (DDL identical to the
--    20261122 install / database_standardization/migrations/02_local_schema_migration.sql).
CREATE SEQUENCE IF NOT EXISTS sitewise_sync.assignment_revision AS bigint;

CREATE TABLE IF NOT EXISTS sitewise_sync.assignment_outbox (
    listing_id      bigint PRIMARY KEY,
    revision        bigint NOT NULL,
    operation       text NOT NULL CHECK (operation IN ('upsert','delete')),
    snapshot        jsonb,
    attempts        integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    synced_at       timestamptz,
    last_error      text,
    changed_at      timestamptz NOT NULL DEFAULT now(),
    CHECK ((operation='delete' AND snapshot IS NULL) OR (operation='upsert' AND snapshot IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS assignment_outbox_pending_idx
    ON sitewise_sync.assignment_outbox(next_attempt_at) WHERE synced_at IS NULL;

CREATE OR REPLACE FUNCTION sitewise_sync.enqueue_assignment(p_id bigint, p_operation text, p_snapshot jsonb)
RETURNS void LANGUAGE sql SET search_path=pg_catalog,sitewise_sync AS $$
    INSERT INTO sitewise_sync.assignment_outbox(listing_id,revision,operation,snapshot)
    VALUES (p_id,nextval('sitewise_sync.assignment_revision'),p_operation,p_snapshot)
    ON CONFLICT(listing_id) DO UPDATE SET revision=excluded.revision,
        operation=excluded.operation,snapshot=excluded.snapshot,attempts=0,
        next_attempt_at=now(),synced_at=NULL,last_error=NULL,changed_at=now();
$$;

CREATE OR REPLACE FUNCTION sitewise_sync.capture_assignment_change()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,sitewise_sync AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        PERFORM sitewise_sync.enqueue_assignment(OLD.listing_id,'delete',NULL);
        RETURN OLD;
    END IF;
    IF TG_OP='UPDATE' THEN
        IF OLD.listing_id <> NEW.listing_id THEN
            PERFORM sitewise_sync.enqueue_assignment(OLD.listing_id,'delete',NULL);
        END IF;
    END IF;
    PERFORM sitewise_sync.enqueue_assignment(NEW.listing_id,'upsert',to_jsonb(NEW));
    RETURN NEW;
END $$;

-- 2. Restore every archived event with its original revision, attempts, and
--    scheduling state (including the 12 pending events and any pending deletes
--    for rows that no longer exist canonically).
INSERT INTO sitewise_sync.assignment_outbox (
    listing_id, revision, operation, snapshot, attempts, next_attempt_at,
    synced_at, last_error, changed_at
)
SELECT a.listing_id, a.revision, a.operation, a.snapshot, a.attempts,
       a.next_attempt_at, a.synced_at, a.last_error, a.changed_at
FROM sitewise_sync.assignment_outbox_archive_20261124 a
ON CONFLICT (listing_id) DO NOTHING;

DO $restore_check$
DECLARE archived integer; restored integer;
BEGIN
    SELECT count(*) INTO archived FROM sitewise_sync.assignment_outbox_archive_20261124;
    SELECT count(*) INTO restored FROM sitewise_sync.assignment_outbox;
    IF restored < archived THEN
        RAISE EXCEPTION 'Archive restore incomplete: % archived, % restored', archived, restored;
    END IF;
END
$restore_check$;

-- 3. Advance the revision sequence beyond everything archived so post-rollback
--    revisions never collide with receipts recorded before retirement.
SELECT setval('sitewise_sync.assignment_revision',
              GREATEST((SELECT COALESCE(MAX(revision), 0)
                        FROM sitewise_sync.assignment_outbox_archive_20261124), 1));

-- 4. Reinstate the change-capture trigger on the canonical table.
LOCK TABLE fyp.agent_listing_assignment IN SHARE ROW EXCLUSIVE MODE;
DROP TRIGGER IF EXISTS sitewise_assignment_sync ON fyp.agent_listing_assignment;
CREATE TRIGGER sitewise_assignment_sync AFTER INSERT OR UPDATE OR DELETE
    ON fyp.agent_listing_assignment FOR EACH ROW
    EXECUTE FUNCTION sitewise_sync.capture_assignment_change();

-- 5. Any canonical changes made while the trigger was retired were never
--    captured. Re-enqueue the current canonical state at fresh revisions so a
--    restored mirror converges to what is authoritative right now.
INSERT INTO sitewise_sync.assignment_outbox(listing_id, revision, operation, snapshot)
    SELECT a.listing_id, nextval('sitewise_sync.assignment_revision'), 'upsert', to_jsonb(a)
    FROM fyp.agent_listing_assignment a
    ON CONFLICT(listing_id) DO UPDATE SET revision=excluded.revision,
        operation=excluded.operation, snapshot=excluded.snapshot, attempts=0,
        next_attempt_at=now(), synced_at=NULL, last_error=NULL, changed_at=now();

DO $final_check$
BEGIN
    IF to_regclass('sitewise_sync.assignment_outbox') IS NULL
       OR to_regprocedure('sitewise_sync.capture_assignment_change()') IS NULL
       OR to_regprocedure('sitewise_sync.enqueue_assignment(bigint,text,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Rollback verification failed: restored objects missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'fyp.agent_listing_assignment'::regclass
          AND tgname = 'sitewise_assignment_sync'
          AND tgfoid = to_regprocedure('sitewise_sync.capture_assignment_change()')
          AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION 'Rollback verification failed: trigger not reinstated';
    END IF;
    IF (SELECT last_value FROM sitewise_sync.assignment_revision)
       < (SELECT COALESCE(MAX(revision), 0) FROM sitewise_sync.assignment_outbox) THEN
        RAISE EXCEPTION 'Rollback verification failed: sequence behind outbox revisions';
    END IF;
END
$final_check$;

COMMIT;
