-- REVIEW CANDIDATE, EXPLICIT OPERATOR EXECUTION ONLY. Never run at startup.
-- Rollback for 20261122_02_explanation_results.
--
-- Drops only what that migration created. It does not touch the ledger, does not
-- touch ai_explanation and does not remove the schema_versions row for any other
-- migration.
--
-- DESTRUCTIVE: dropping explanation_results discards every stored explanation and
-- its validation findings. There is no copy of that content elsewhere -- the
-- execution ledger records only attempt and receipt facts. Run this only after
-- the stored results have been exported or the loss has been accepted in writing.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '60s';
DO $$
BEGIN
  IF current_database() NOT IN ('Dss', 'project1_workflow_tests', 'project1_disposable_app')
     OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
  IF to_regclass('project1_ai.explanation_results') IS NULL THEN
    RAISE EXCEPTION 'explanation_results does not exist: nothing to roll back';
  END IF;
END $$;

DROP TABLE project1_ai.explanation_result_validations;
DROP TABLE project1_ai.explanation_results;

DELETE FROM project1_ai.schema_versions
WHERE version = '20261122_02_explanation_results';
COMMIT;
