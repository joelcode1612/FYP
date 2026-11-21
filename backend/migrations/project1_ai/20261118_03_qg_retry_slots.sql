-- REVIEW CANDIDATE, EXPLICIT OPERATOR EXECUTION ONLY. Never run at startup.
-- Requires a reviewed target and receipt, e.g. SET project1.migration_target='Dss';
-- SET project1.migration_receipt='<actual reviewed change record>';
--
-- CP-08 item 6: allow more than one QG attempt in a single run.
--
-- The original ledger used UNIQUE(run_id, stage), which permits only one
-- attempt per stage per run and is what currently blocks a reviewed QG retry.
-- This migration replaces that single uniqueness rule with
-- UNIQUE(run_id, stage, attempt_slot): one attempt per (stage, slot), with up
-- to three slots. Uniqueness is NARROWED, never dropped -- the new constraint
-- is installed immediately after the old one is removed, in the same
-- transaction. It does not silently weaken the rule to "no constraint".
--
-- Purely structural and history-preserving: every existing row keeps its
-- identity and gets attempt_slot = 1 (the constant DEFAULT, so no row is
-- rewritten and the append-only UPDATE/DELETE trigger is not fired). Nothing
-- is deleted, no stage is re-labelled, and no prior attempt is discarded.
--
-- Only Dss, the disposable project1_workflow_tests database, and one named
-- private test database are valid targets. This script is never applied to a
-- database implicitly and never touches any other database.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '60s';
DO $$
BEGIN
  IF current_database() NOT IN ('Dss', 'project1_workflow_tests', 'cp08_qg_retry_tests')
     OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
  IF to_regclass('project1_ai.runs') IS NULL
     OR to_regclass('project1_ai.attempts') IS NULL
     OR to_regproc('project1_ai.deny_mutation') IS NULL THEN
    RAISE EXCEPTION 'project1_ai ledger missing: apply 20261111_01 first';
  END IF;
  -- This migration is defined in terms of the exact legacy constraint. If it
  -- is absent, the database is in an unreviewed state: stop rather than guess.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'project1_ai.attempts'::regclass
      AND conname = 'attempts_run_id_stage_key'
      AND contype = 'u'
  ) THEN
    RAISE EXCEPTION 'attempts_run_id_stage_key missing: reconcile version before migrating';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'project1_ai'
      AND table_name = 'attempts'
      AND column_name = 'attempt_slot'
  ) THEN
    RAISE EXCEPTION 'attempt_slot already present: 20261118_03 applied; reconcile before re-running';
  END IF;
END $$;

ALTER TABLE project1_ai.attempts
  ADD COLUMN attempt_slot integer NOT NULL DEFAULT 1
  CHECK (attempt_slot BETWEEN 1 AND 3);

ALTER TABLE project1_ai.attempts
  DROP CONSTRAINT attempts_run_id_stage_key;

ALTER TABLE project1_ai.attempts
  ADD CONSTRAINT attempts_run_stage_slot_key UNIQUE (run_id, stage, attempt_slot);

INSERT INTO project1_ai.schema_versions(version, receipt)
VALUES ('20261118_03_qg_retry_slots', current_setting('project1.migration_receipt'));

COMMIT;
