-- Rollback for 20261118_03_qg_retry_slots.sql.
--
-- Restores the original UNIQUE(run_id, stage) rule named
-- attempts_run_id_stage_key, removes the new column and its constraint, and
-- removes the schema_versions marker.
--
-- This rollback REFUSES to run while any row has attempt_slot > 1. Restoring
-- the old unique rule would either fail on such a run, or (if the slot column
-- were simply dropped first) silently collapse distinct retries onto one row
-- identity. Losing the record of a reviewed retry is worse than leaving the
-- migration in place, so an operator must decide deliberately.
--
-- Explicit operator execution only; never run at startup, never implicit.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '60s';
DO $guard$
BEGIN
  IF current_database() NOT IN ('Dss', 'project1_workflow_tests', 'cp08_qg_retry_tests')
     OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
  IF to_regclass('project1_ai.attempts') IS NULL THEN
    RAISE EXCEPTION 'project1_ai.attempts is missing; nothing to roll back';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'project1_ai'
      AND table_name = 'attempts'
      AND column_name = 'attempt_slot'
  ) THEN
    RAISE EXCEPTION 'attempt_slot absent; 20261118_03 is not applied';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'project1_ai.attempts'::regclass
      AND conname = 'attempts_run_stage_slot_key'
      AND contype = 'u'
  ) THEN
    RAISE EXCEPTION 'attempts_run_stage_slot_key absent; reconcile version before rollback';
  END IF;
  IF EXISTS (
    SELECT 1 FROM project1_ai.attempts WHERE attempt_slot > 1
  ) THEN
    RAISE EXCEPTION 'attempt_slot > 1 rows exist; restoring UNIQUE(run_id, stage) '
                    'would discard retry history. Refusing.';
  END IF;
END
$guard$;

ALTER TABLE project1_ai.attempts
  DROP CONSTRAINT attempts_run_stage_slot_key;
ALTER TABLE project1_ai.attempts
  DROP COLUMN attempt_slot;
ALTER TABLE project1_ai.attempts
  ADD CONSTRAINT attempts_run_id_stage_key UNIQUE (run_id, stage);

DELETE FROM project1_ai.schema_versions
WHERE version = '20261118_03_qg_retry_slots';

DO $verify$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'project1_ai'
      AND table_name = 'attempts'
      AND column_name = 'attempt_slot'
  ) THEN
    RAISE EXCEPTION 'attempt_slot still present after rollback';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'project1_ai.attempts'::regclass
      AND conname = 'attempts_run_id_stage_key'
      AND contype = 'u'
  ) THEN
    RAISE EXCEPTION 'attempts_run_id_stage_key was not restored';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'project1_ai.attempts'::regclass
      AND conname = 'attempts_run_stage_slot_key'
  ) THEN
    RAISE EXCEPTION 'attempts_run_stage_slot_key still present after rollback';
  END IF;
END
$verify$;

COMMIT;
