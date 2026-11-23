-- PROJECT1 BDJ objective proposals: reconcile the review_state CHECK invariant.
-- Migration: 20261122_0500_m2_bdj_objective_review_state_reconcile
--
-- Why this exists
-- ---------------
-- The review_state vocabulary is defined in two places:
--
--   * 20261121_0100 declares it INLINE on the column
--     (CANDIDATE, REVIEWED, WITHDRAWN) — PostgreSQL auto-names that constraint
--     m2_bdj_objective_proposals_review_state_check;
--   * 20261121_0200 drops whatever auto-named check guarded review_state and
--     installs one explicit ck_proposal_review_state
--     (CANDIDATE, APPROVED, REJECTED, REVIEWED, WITHDRAWN).
--
-- On a database built by running the two files in order, the result is correct:
-- exactly one constraint, admitting all five states.
--
-- But the outcome depends on the ORDER and on whether 0200's drop loop actually
-- ran. A database created by an earlier revision of 0100, or one where the
-- named constraint was added by hand, can end up holding BOTH constraints. The
-- narrow one then silently forbids APPROVED and REJECTED, which are exactly the
-- states the decision workflow needs — the failure surfaces as a constraint
-- violation in the middle of an approval, far from the cause.
--
-- This migration makes the invariant explicit and re-runnable: exactly one
-- review_state check constraint, named ck_proposal_review_state, admitting all
-- five states. It is safe to run on a database that is already correct.
--
-- What this migration does NOT do
-- -------------------------------
-- * No data is read or written. Only constraint DDL. Row counts are captured
--   before and after and reported, to prove it.
-- * RLS policies are not touched. Enablement is asserted, not changed.
-- * It does not run against a protected database: the guard below refuses
--   Dss, Final_Location_Analysis, sitesense, postgres and the 5432 cluster.
--
-- Idempotent: applying it twice is a no-op the second time.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $guard$
BEGIN
  IF current_database() IN ('Dss', 'dss', 'Final_Location_Analysis', 'sitesense', 'postgres') THEN
    RAISE EXCEPTION 'REFUSED: % is a protected database', current_database();
  END IF;
  IF inet_server_port() = 5432 THEN
    RAISE EXCEPTION 'REFUSED: port 5432 is the protected cluster (current_database=%)',
      current_database();
  END IF;
  IF current_database() NOT LIKE 'project1\_%' THEN
    RAISE EXCEPTION 'REFUSED: disposable-only migration (current_database=%, port=%)',
      current_database(), inet_server_port();
  END IF;
  IF to_regclass('public.m2_bdj_objective_proposals') IS NULL THEN
    RAISE EXCEPTION 'public.m2_bdj_objective_proposals is required';
  END IF;
END
$guard$;

DO $reconcile$
DECLARE
  c              record;
  rows_before    bigint;
  rows_after     bigint;
  kept           text;
  dropped        text[] := ARRAY[]::text[];
  review_checks  int;
BEGIN
  SELECT count(*) INTO rows_before FROM public.m2_bdj_objective_proposals;

  -- 1. Drop every review_state check that does not admit the decision states.
  --    Detection is by constraint DEFINITION, not by name: the offending
  --    constraint is usually auto-named and its name varies with the PostgreSQL
  --    version that created it.
  FOR c IN
      SELECT conname, pg_get_constraintdef(oid) AS def
        FROM pg_constraint
       WHERE conrelid = 'public.m2_bdj_objective_proposals'::regclass
         AND contype = 'c'
         AND pg_get_constraintdef(oid) LIKE '%review_state%'
  LOOP
    IF position('''APPROVED''' IN c.def) = 0
       OR position('''REJECTED''' IN c.def) = 0 THEN
      EXECUTE format(
        'ALTER TABLE public.m2_bdj_objective_proposals DROP CONSTRAINT %I', c.conname);
      dropped := dropped || c.conname;
    END IF;
  END LOOP;

  -- 2. If more than one compliant constraint survived, keep the canonical name
  --    and drop the duplicates, so the invariant is "exactly one" rather than
  --    "at least one".
  SELECT count(*) INTO review_checks
    FROM pg_constraint
   WHERE conrelid = 'public.m2_bdj_objective_proposals'::regclass
     AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%review_state%';

  IF review_checks > 1 THEN
    FOR c IN
        SELECT conname
          FROM pg_constraint
         WHERE conrelid = 'public.m2_bdj_objective_proposals'::regclass
           AND contype = 'c'
           AND pg_get_constraintdef(oid) LIKE '%review_state%'
           AND conname <> 'ck_proposal_review_state'
    LOOP
      EXECUTE format(
        'ALTER TABLE public.m2_bdj_objective_proposals DROP CONSTRAINT %I', c.conname);
      dropped := dropped || c.conname;
    END LOOP;
  END IF;

  -- 3. Install the canonical constraint if nothing compliant remains.
  SELECT count(*) INTO review_checks
    FROM pg_constraint
   WHERE conrelid = 'public.m2_bdj_objective_proposals'::regclass
     AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%review_state%';

  IF review_checks = 0 THEN
    ALTER TABLE public.m2_bdj_objective_proposals
      ADD CONSTRAINT ck_proposal_review_state
      CHECK (review_state IN ('CANDIDATE', 'APPROVED', 'REJECTED',
                              'REVIEWED', 'WITHDRAWN'));
    kept := 'ck_proposal_review_state (added)';
  ELSE
    SELECT conname INTO kept
      FROM pg_constraint
     WHERE conrelid = 'public.m2_bdj_objective_proposals'::regclass
       AND contype = 'c'
       AND pg_get_constraintdef(oid) LIKE '%review_state%';
  END IF;

  -- 4. Verify the invariant rather than assuming the DDL above achieved it.
  SELECT count(*) INTO review_checks
    FROM pg_constraint
   WHERE conrelid = 'public.m2_bdj_objective_proposals'::regclass
     AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%review_state%';
  IF review_checks <> 1 THEN
    RAISE EXCEPTION 'review_state invariant not reached: % constraints remain', review_checks;
  END IF;

  IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.m2_bdj_objective_proposals'::regclass
         AND conname = 'ck_proposal_review_state'
         AND position('''APPROVED''' IN pg_get_constraintdef(oid)) > 0
         AND position('''REJECTED''' IN pg_get_constraintdef(oid)) > 0
  ) THEN
    RAISE EXCEPTION 'ck_proposal_review_state must admit APPROVED and REJECTED';
  END IF;

  SELECT count(*) INTO rows_after FROM public.m2_bdj_objective_proposals;
  IF rows_after <> rows_before THEN
    RAISE EXCEPTION 'row count changed: % -> % (this migration must not touch data)',
      rows_before, rows_after;
  END IF;

  -- 5. RLS is asserted, never altered here. If a caller has disabled it, that is
  --    a separate finding and must not be silently "fixed" by a constraint
  --    migration.
  IF NOT EXISTS (
      SELECT 1 FROM pg_class
       WHERE oid = 'public.m2_bdj_objective_proposals'::regclass AND relrowsecurity
  ) THEN
    RAISE NOTICE 'WARNING: RLS is disabled on m2_bdj_objective_proposals (not changed here)';
  END IF;

  RAISE NOTICE 'review_state reconcile: kept=%, dropped=%, rows=%',
    kept, coalesce(array_to_string(dropped, ','), '(none)'), rows_after;
END
$reconcile$;

COMMIT;
