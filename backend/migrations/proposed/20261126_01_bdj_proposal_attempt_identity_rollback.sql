-- ROLLBACK for 20261126_01_bdj_proposal_attempt_identity.sql
-- PROPOSAL ONLY — NOT APPLIED.
--
-- Reverses every object the forward migration creates, in dependency order.
-- Nothing governed is lost: the columns are provenance, and the ledger rows
-- they point at are untouched by either direction.
--
-- Historical rows are preserved exactly. A row that was written with an
-- identity simply loses that identity; it does not lose its content, its review
-- state, or its assessment binding. After rollback those rows become
-- unattributable again, which is the honest state the code already handles.

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '60s';

DO $$
BEGIN
  IF current_setting('project1.migration_target', true)
       IS DISTINCT FROM current_database()
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
END $$;

-- 1. The trigger and its function.
DROP TRIGGER IF EXISTS m2_bdj_proposal_source_binding_trg
  ON public.m2_bdj_objective_proposals;
DROP FUNCTION IF EXISTS public.m2_bdj_proposal_source_binding();

-- 2. Constraints that depend on the new columns, before the columns go.
ALTER TABLE public.m2_bdj_objective_proposals
  DROP CONSTRAINT IF EXISTS m2_bdj_objective_proposals_attempt_fkey,
  DROP CONSTRAINT IF EXISTS m2_bdj_objective_proposals_owner_fkey,
  DROP CONSTRAINT IF EXISTS m2_bdj_objective_proposals_assessment_fkey,
  DROP CONSTRAINT IF EXISTS m2_bdj_objective_proposals_revision_fkey,
  DROP CONSTRAINT IF EXISTS m2_bdj_objective_proposals_attempt_pair_chk;

DROP INDEX IF EXISTS public.m2_bdj_objective_proposals_attempt_idx;

-- 3. The columns.
ALTER TABLE public.m2_bdj_objective_proposals
  DROP COLUMN IF EXISTS attempt_stage,
  DROP COLUMN IF EXISTS attempt_no,
  DROP COLUMN IF EXISTS run_id;

-- 4. Referenced uniqueness added by the forward migration.
DROP INDEX IF EXISTS project1_ai.attempts_run_attempt_stage_key;

ALTER TABLE project1_ai.runs
  DROP CONSTRAINT IF EXISTS runs_id_assessment_revision_key,
  DROP CONSTRAINT IF EXISTS runs_id_assessment_id_key;

COMMIT;
