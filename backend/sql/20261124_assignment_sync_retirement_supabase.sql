-- SUPABASE ONLY. Rollback: 20261124_assignment_sync_retirement_supabase_rollback.sql
-- Retires the Supabase side of the assignment mirror after the local
-- PostgreSQL retirement (20261124_assignment_sync_retirement_local.sql) and
-- after deploying a backend build without assignment_sync_worker:
--
--   * fyp.sync_agent_assignment(bigint,bigint,text,jsonb)  - mirror RPC (dropped)
--   * fyp.assignment_sync_receipts                          - replay receipts (dropped)
--   * fyp.agent_listing_assignment                          - mirror table (dropped)
--
-- Supabase keeps every other responsibility: identity/auth, agent profile,
-- storage, and public.pano_listing_links (panorama mapping infrastructure,
-- preserved untouched). Local fyp.agent_listing_assignment remains the only
-- operational assignment store.
--
-- No DROP ... CASCADE anywhere: preflight aborts if any foreign key, view,
-- rule, or trigger still depends on the objects being removed. Mirror rows
-- (expected: none) and receipt rows are archived before deletion.

\set ON_ERROR_STOP on

BEGIN;

DO $preflight$
DECLARE
    offenders text;
BEGIN
    IF to_regclass('fyp.agent_listing_assignment') IS NULL THEN
        RAISE EXCEPTION 'fyp.agent_listing_assignment is absent; already retired? Verify the target project before rerunning';
    END IF;
    IF to_regclass('public.pano_listing_links') IS NULL THEN
        RAISE EXCEPTION 'public.pano_listing_links is absent; confirm this is the correct Supabase project';
    END IF;

    -- No table may reference the mirror or the receipts table.
    SELECT string_agg(format('%I.%I -> %s', n.nspname, t.relname, con.conname), ', ')
      INTO offenders
      FROM pg_constraint con
      JOIN pg_class t ON t.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE con.contype = 'f'
        AND con.confrelid IN ('fyp.agent_listing_assignment'::regclass,
                              'fyp.assignment_sync_receipts'::regclass);
    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'Foreign keys still reference the mirror/receipts: %', offenders;
    END IF;

    -- No view, matview, or rule may read the mirror.
    SELECT string_agg(format('%I.%I', n.nspname, t.relname), ', ')
      INTO offenders
      FROM pg_depend d
      JOIN pg_rewrite r ON r.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
      JOIN pg_class t ON t.oid = r.ev_class
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE d.refobjid = 'fyp.agent_listing_assignment'::regclass
        AND d.refclassid = 'pg_class'::regclass
        AND t.oid <> 'fyp.agent_listing_assignment'::regclass
        AND d.deptype IN ('n', 'a');
    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'Views/rules still depend on fyp.agent_listing_assignment: %', offenders;
    END IF;

    -- No user trigger may remain on the mirror or receipts.
    SELECT string_agg(format('%I.%I: %s', n.nspname, t.relname, tr.tgname), ', ')
      INTO offenders
      FROM pg_trigger tr
      JOIN pg_class t ON t.oid = tr.tgrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE tr.tgrelid IN ('fyp.agent_listing_assignment'::regclass,
                           'fyp.assignment_sync_receipts'::regclass)
        AND NOT tr.tgisinternal;
    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'User triggers still attached: %', offenders;
    END IF;
END
$preflight$;

-- Archive whatever exists before deletion (expected: 0 mirror rows, 0 receipts).
CREATE TABLE IF NOT EXISTS fyp.assignment_mirror_archive_20261124
    (LIKE fyp.agent_listing_assignment INCLUDING ALL);
ALTER TABLE fyp.assignment_mirror_archive_20261124
    ADD COLUMN IF NOT EXISTS archived_at timestamptz NOT NULL DEFAULT now();
INSERT INTO fyp.assignment_mirror_archive_20261124
SELECT *, now() FROM fyp.agent_listing_assignment;

CREATE TABLE IF NOT EXISTS fyp.assignment_receipts_archive_20261124
    (LIKE fyp.assignment_sync_receipts INCLUDING ALL);
ALTER TABLE fyp.assignment_receipts_archive_20261124
    ADD COLUMN IF NOT EXISTS archived_at timestamptz NOT NULL DEFAULT now();
DO $receipts$
BEGIN
    IF to_regclass('fyp.assignment_sync_receipts') IS NOT NULL THEN
        EXECUTE 'INSERT INTO fyp.assignment_receipts_archive_20261124
                 SELECT *, now() FROM fyp.assignment_sync_receipts';
    END IF;
END
$receipts$;

DO $archive_check$
DECLARE mirror_rows integer; archived integer;
BEGIN
    SELECT count(*) INTO mirror_rows FROM fyp.agent_listing_assignment;
    SELECT count(*) INTO archived FROM fyp.assignment_mirror_archive_20261124;
    IF archived < mirror_rows THEN
        RAISE EXCEPTION 'Mirror archive verification failed: % live rows, % archived', mirror_rows, archived;
    END IF;
END
$archive_check$;

-- Drop in strict order: RPC first (stops any straggler sync call), then
-- receipts, then the mirror table itself.
DROP FUNCTION IF EXISTS fyp.sync_agent_assignment(bigint,bigint,text,jsonb);
DROP TABLE IF EXISTS fyp.assignment_sync_receipts;
DROP TABLE IF EXISTS fyp.agent_listing_assignment;

DO $post_check$
BEGIN
    IF to_regclass('fyp.agent_listing_assignment') IS NOT NULL
       OR to_regclass('fyp.assignment_sync_receipts') IS NOT NULL
       OR to_regprocedure('fyp.sync_agent_assignment(bigint,bigint,text,jsonb)') IS NOT NULL THEN
        RAISE EXCEPTION 'Retirement verification failed: mirror objects still present';
    END IF;
    IF to_regclass('public.pano_listing_links') IS NULL THEN
        RAISE EXCEPTION 'public.pano_listing_links must survive retirement';
    END IF;
END
$post_check$;

NOTIFY pgrst, 'reload schema';

COMMIT;
