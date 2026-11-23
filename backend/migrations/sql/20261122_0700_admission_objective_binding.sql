-- PROJECT1 Phase 3B: bind an objective admission to a fixed objective and to
-- the policy decision that permitted it.
-- Migration: 20261122_0700_admission_objective_binding
-- Target: disposable cluster only. Never applied to Dss / Final_Location_Analysis.
--
-- WHY THIS EXISTS
-- ---------------
-- 20261122_0400 introduced m2_bdj_objective_admissions as "a named person, at a
-- named confirmation, decided this gap is worth researching". That record proves
-- *who* decided and *against which source*. It does not say *which* fixed
-- objective was admitted, and it does not record the policy decision that made
-- the gap admissible in the first place.
--
-- Two consequences, both of which this migration closes:
--
--   1. An admission for one proposal could authorise a QG candidate for an
--      unrelated objective, because nothing in the row named an objective.
--      `objective_id` makes the binding explicit and checkable.
--
--   2. 04_BDJ_CLASSIFICATION_AND_OBJECTIVES.md requires that "a true gap still
--      must be customer-survey-suitable before an objective is admitted". With
--      no recorded classification/disposition, a later reader could not tell
--      whether that test had been applied or skipped. The policy columns record
--      the exact policy version and the exact decision, so skipping it is
--      visible rather than silent.
--
-- `objective_id` is NULLABLE on purpose. NULL means "the owner admitted the gap
-- as worth researching but no fixed objective could be bound to it". That is a
-- real and honest state: it is NOT_ADMITTED for QG purposes while still being a
-- recorded owner decision. A NOT NULL column would force a fabricated binding.
--
-- WHAT THIS IS NOT
-- ----------------
--   * Not an approval of any objective.
--   * Not a QG authorization. m2_qg_authorizations remains a separate, single-
--     use, exact-bound row and is never derived from an admission.
--   * Not a change to the append-only discipline. The new columns are written at
--     INSERT time only; the existing UPDATE/DELETE refusal triggers stay.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $guard$
BEGIN
  IF current_database() IN ('Dss', 'dss', 'Final_Location_Analysis', 'sitesense', 'postgres') THEN
    RAISE EXCEPTION 'Refusing to alter admission binding on protected database %',
      current_database();
  END IF;
  IF inet_server_port() = 5432 THEN
    RAISE EXCEPTION 'Refusing to alter admission binding on the protected cluster (port 5432, database %)',
      current_database();
  END IF;
  IF current_database() NOT LIKE 'project1\_%' THEN
    RAISE EXCEPTION 'Unexpected target %: expected a project1_ disposable database on a non-5432 port',
      current_database();
  END IF;
  IF to_regclass('public.m2_bdj_objective_admissions') IS NULL THEN
    RAISE EXCEPTION 'm2_bdj_objective_admissions required (apply 20261122_0400 first)';
  END IF;
END
$guard$;

-- ---------------------------------------------------------------------------
-- 1. The objective binding and the policy decision that permitted it.
-- ---------------------------------------------------------------------------
ALTER TABLE public.m2_bdj_objective_admissions
    ADD COLUMN IF NOT EXISTS objective_id varchar(8)
        CHECK (objective_id IS NULL OR objective_id IN ('O1','O2','O3','O4','O5','O6'));

ALTER TABLE public.m2_bdj_objective_admissions
    ADD COLUMN IF NOT EXISTS policy_version varchar(64);

ALTER TABLE public.m2_bdj_objective_admissions
    ADD COLUMN IF NOT EXISTS policy_classification varchar(48);

ALTER TABLE public.m2_bdj_objective_admissions
    ADD COLUMN IF NOT EXISTS policy_disposition varchar(48);

ALTER TABLE public.m2_bdj_objective_admissions
    ADD COLUMN IF NOT EXISTS policy_resolution varchar(48);

COMMENT ON COLUMN public.m2_bdj_objective_admissions.objective_id IS
  'The fixed objective (O1..O6) this admission binds to, or NULL when no fixed '
  'objective could be bound. NULL is NOT_ADMITTED for QG: an admission that '
  'cannot name its objective cannot authorise a QG candidate.';

COMMENT ON COLUMN public.m2_bdj_objective_admissions.policy_version IS
  'The issue-resolution policy version in force when the admission was '
  'recorded. Recorded so a later policy change is visible rather than '
  'retroactively applied.';

COMMENT ON COLUMN public.m2_bdj_objective_admissions.policy_classification IS
  'Issue classification from that policy (e.g. EXPLICIT_UNCERTAINTY, '
  'PLANNING_UNDECIDED, EVIDENCE_UNAVAILABLE).';

COMMENT ON COLUMN public.m2_bdj_objective_admissions.policy_disposition IS
  'Disposition from that policy (e.g. BUSINESS_DECISION_REQUIRED, '
  'ENTREPRENEUR_CLARIFICATION, LINK_EXISTING_OBJECTIVE_OR_NO_ACTION).';

COMMENT ON COLUMN public.m2_bdj_objective_admissions.policy_resolution IS
  'Five-way candidate resolution from that policy (e.g. '
  'COVERED_BY_FIXED_OBJECTIVE, NOT_CUSTOMER_RESEARCH_SUITABLE).';

-- ---------------------------------------------------------------------------
-- 2. The append-only guard must still hold after the ALTER.
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  n_cols int;
  n_trig int;
BEGIN
  SELECT count(*) INTO n_cols
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'm2_bdj_objective_admissions'
    AND column_name IN ('objective_id', 'policy_version',
                        'policy_classification', 'policy_disposition',
                        'policy_resolution');
  IF n_cols <> 5 THEN
    RAISE EXCEPTION 'POSTCONDITION_FAILED: expected 5 new admission columns, found %', n_cols;
  END IF;

  -- The UPDATE/DELETE refusal triggers from 20261122_0400 must still be there.
  SELECT count(DISTINCT t.tgname) INTO n_trig
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  WHERE c.relname = 'm2_bdj_objective_admissions' AND NOT t.tgisinternal;
  IF n_trig < 1 THEN
    RAISE EXCEPTION 'POSTCONDITION_FAILED: admission append-only trigger is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'm2_bdj_objective_admissions'
      AND policyname = 'owner_scope'
  ) THEN
    RAISE EXCEPTION 'POSTCONDITION_FAILED: owner_scope policy on admissions is missing';
  END IF;
END
$post$;

COMMIT;
