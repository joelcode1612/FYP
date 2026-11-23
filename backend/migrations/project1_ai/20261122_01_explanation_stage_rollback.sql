-- REVIEW CANDIDATE, EXPLICIT OPERATOR EXECUTION ONLY. Never run at startup.
-- Requires the same reviewed target and receipt as the forward migration:
--   SET project1.migration_target='project1_workflow_tests';
--   SET project1.migration_receipt='<actual reviewed change record>';
--
-- Reverts 20261122_01_explanation_stage: narrows the stage CHECK back to the
-- original three values.
--
-- This will FAIL if any EXPLANATION attempt has already been recorded, and that
-- failure is the point. The ledger is append-only: an EXPLANATION row is history,
-- and narrowing the constraint would either delete it or silently relabel it.
-- If the rollback is refused, the correct response is to keep the wider
-- constraint, not to remove the evidence.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '60s';
DO $$
BEGIN
  IF current_database() NOT IN ('Dss', 'project1_workflow_tests',
                                'project1_disposable_app', 'cp08_qg_retry_tests')
     OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM project1_ai.schema_versions
    WHERE version = '20261122_01_explanation_stage'
  ) THEN
    RAISE EXCEPTION '20261122_01_explanation_stage is not applied; nothing to roll back';
  END IF;
  IF EXISTS (SELECT 1 FROM project1_ai.attempts WHERE stage = 'EXPLANATION') THEN
    RAISE EXCEPTION 'EXPLANATION attempts exist: refusing to narrow the constraint over recorded history';
  END IF;
END $$;

ALTER TABLE project1_ai.attempts DROP CONSTRAINT IF EXISTS attempts_stage_check;

ALTER TABLE project1_ai.attempts
  ADD CONSTRAINT attempts_stage_check
  CHECK (stage IN ('BDJ', 'QJ', 'QG'));

DELETE FROM project1_ai.schema_versions
WHERE version = '20261122_01_explanation_stage';

COMMIT;
