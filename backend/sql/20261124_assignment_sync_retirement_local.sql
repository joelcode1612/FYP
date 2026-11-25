-- LOCAL POSTGRESQL ONLY (Final_Location_Analysis)
-- Retire the assignment outbox after the application has been deployed without
-- assignment_sync_worker. DO NOT RUN until that deployment is confirmed.
--
-- Order is intentional: archive events -> drop trigger -> drop capture/enqueue
-- functions -> drop outbox -> drop revision sequence. No DROP ... CASCADE.
-- Rollback: 20261124_assignment_sync_retirement_local_rollback.sql

\set ON_ERROR_STOP on

BEGIN;

DO $preflight$
DECLARE trigger_oid oid;
BEGIN
    IF current_database() <> 'Final_Location_Analysis' THEN
        RAISE EXCEPTION 'Run this migration on Final_Location_Analysis, got %', current_database();
    END IF;
    IF to_regclass('fyp.agent_listing_assignment') IS NULL THEN
        RAISE EXCEPTION 'Canonical fyp.agent_listing_assignment is required';
    END IF;
    IF to_regclass('sitewise_sync.assignment_outbox') IS NULL THEN
        RAISE EXCEPTION 'sitewise_sync.assignment_outbox is absent; already retired?';
    END IF;

    trigger_oid := to_regprocedure('sitewise_sync.capture_assignment_change()');
    IF trigger_oid IS NULL THEN
        RAISE EXCEPTION 'sitewise_sync.capture_assignment_change() is absent';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'fyp.agent_listing_assignment'::regclass
          AND tgname = 'sitewise_assignment_sync'
          AND tgfoid = trigger_oid
          AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION 'Expected sitewise_assignment_sync trigger on the canonical table is absent';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_trigger t
        WHERE t.tgfoid = trigger_oid
          AND t.tgrelid <> 'fyp.agent_listing_assignment'::regclass
          AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION 'capture_assignment_change has an unexpected trigger consumer';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_depend d
        JOIN pg_rewrite r ON r.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
        WHERE d.refobjid = 'sitewise_sync.assignment_outbox'::regclass
          AND d.refclassid = 'pg_class'::regclass
          AND d.deptype IN ('n', 'a')
    ) THEN
        RAISE EXCEPTION 'assignment_outbox has a dependent view or rule; review before retirement';
    END IF;
END
$preflight$;

-- Preserve every outbox event, including the 12 currently pending events.
CREATE TABLE IF NOT EXISTS sitewise_sync.assignment_outbox_archive_20261124 (
    LIKE sitewise_sync.assignment_outbox INCLUDING ALL,
    archived_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO sitewise_sync.assignment_outbox_archive_20261124 (
    listing_id, revision, operation, snapshot, attempts, next_attempt_at,
    synced_at, last_error, changed_at
)
SELECT o.listing_id, o.revision, o.operation, o.snapshot, o.attempts,
       o.next_attempt_at, o.synced_at, o.last_error, o.changed_at
FROM sitewise_sync.assignment_outbox o
WHERE NOT EXISTS (
    SELECT 1 FROM sitewise_sync.assignment_outbox_archive_20261124 a
    WHERE a.listing_id = o.listing_id AND a.revision = o.revision
);

DO $archive_check$
BEGIN
    IF EXISTS (
        SELECT 1 FROM sitewise_sync.assignment_outbox o
        WHERE NOT EXISTS (
            SELECT 1 FROM sitewise_sync.assignment_outbox_archive_20261124 a
            WHERE a.listing_id = o.listing_id AND a.revision = o.revision
        )
    ) THEN
        RAISE EXCEPTION 'Outbox archive verification failed';
    END IF;
END
$archive_check$;

DROP TRIGGER IF EXISTS sitewise_assignment_sync ON fyp.agent_listing_assignment;
DROP FUNCTION IF EXISTS sitewise_sync.capture_assignment_change();
DROP FUNCTION IF EXISTS sitewise_sync.enqueue_assignment(bigint, text, jsonb);
DROP TABLE IF EXISTS sitewise_sync.assignment_outbox;
DROP SEQUENCE IF EXISTS sitewise_sync.assignment_revision;

COMMIT;
