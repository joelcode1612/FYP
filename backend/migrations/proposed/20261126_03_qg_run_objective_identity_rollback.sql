-- ROLLBACK for 20261126_03_qg_run_objective_identity.sql
-- PROPOSAL ONLY — NOT APPLIED.
--
-- Reverses every object the forward migration creates: one index and one
-- nullable column on `project1_ai.runs`.
--
-- What is lost
-- ------------
-- The objective each QG run was created for. No run row is deleted and no
-- attempt, receipt or candidate is touched: the column is provenance, and the
-- executions it names still exist.
--
-- Consequence after rollback
-- --------------------------
-- `runs.has_run_objective_column` starts answering False again, so an
-- objective-scoped status read returns `OBJECTIVE_IDENTITY_NOT_RECORDED`
-- instead of the newest QG attempt. That is the pre-migration behaviour and it
-- fails closed: two objectives stop being able to show each other's progress,
-- but neither can show its own. The rail degrades to "cannot identify this
-- execution", which is true.
--
-- Code does not need to change with this rollback
-- -----------------------------------------------
-- The write path sets `objective_id` only when the column exists, and the read
-- path probes for it per process. Both are already tolerant of its absence, so
-- the rollback is safe to apply under the running application.
--
-- Paired code that becomes dormant
-- --------------------------------
-- `runs.qg_work_identity(..., objective_id=...)` and the objective-scoped branch
-- of `runs.execution_status` keep working; they simply cannot be reached with a
-- non-null objective until the column returns.

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

-- 1. The index.
DROP INDEX IF EXISTS project1_ai.runs_objective_idx;

-- 2. The column.
ALTER TABLE project1_ai.runs DROP COLUMN IF EXISTS objective_id;

COMMIT;
