-- PROJECT1 PG18 isolated environment — Phase P7 (ledger columns)
-- Migration: 20261123_03_p7_ledger_columns
-- Target:    project1_pg18_migrated_tests @ 127.0.0.1:5544
--
-- Reproduces the substance of two migrations that refuse this environment:
--
--   migrations/project1_ai/20261118_03_qg_retry_slots.sql
--       guard: current_database() NOT IN ('Dss','project1_workflow_tests','cp08_qg_retry_tests')
--   migrations/project1_ai/20261121_04_execution_mode.sql
--       guard: adds three columns + three CHECKs, with an UPDATE backfill
--
-- Both were written for 5432/5433 and cannot be pointed at 5544 without
-- editing them. Editing them in place would change what the historical
-- 5433 run meant, so they are left untouched and this file carries the PG18
-- equivalent instead.
--
-- On D-1 (the ``execution_mode`` backfill decision)
-- ------------------------------------------------
-- The UPDATE below is reproduced *unchanged* in intent, but this database is a
-- schema-only baseline: ``project1_ai.bdj_results`` holds zero rows, so the
-- backfill classifies nothing. D-1 therefore remains an OPEN owner decision for
-- real data. The row count the UPDATE touched is recorded in
-- ``schema_versions`` so a later reader can tell "no rows" from "already done".
--
-- Idempotent: every object is created only if absent, so a rerun reconciles.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

DO $$
BEGIN
    IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
        RAISE EXCEPTION 'REFUSED: % is a protected database', current_database();
    END IF;
    IF current_database() NOT LIKE 'project1\_pg18\_%' THEN
        RAISE EXCEPTION 'REFUSED: expected a project1_pg18_* database, connected to %',
            current_database();
    END IF;
    IF coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
        RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
    END IF;
    IF to_regclass('project1_ai.attempts') IS NULL
       OR to_regclass('project1_ai.bdj_results') IS NULL
       OR to_regproc('project1_ai.deny_mutation') IS NULL THEN
        RAISE EXCEPTION 'project1_ai ledger missing: restore the baseline first';
    END IF;
END $$;

-- --- P7a: attempt_slot --------------------------------------------------
ALTER TABLE project1_ai.attempts
  ADD COLUMN IF NOT EXISTS attempt_slot integer NOT NULL DEFAULT 1
  CHECK (attempt_slot BETWEEN 1 AND 3);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint
               WHERE conrelid = 'project1_ai.attempts'::regclass
                 AND conname = 'attempts_run_id_stage_key') THEN
        ALTER TABLE project1_ai.attempts DROP CONSTRAINT attempts_run_id_stage_key;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'project1_ai.attempts'::regclass
                     AND conname = 'attempts_run_stage_slot_key') THEN
        ALTER TABLE project1_ai.attempts
          ADD CONSTRAINT attempts_run_stage_slot_key UNIQUE (run_id, stage, attempt_slot);
    END IF;
END $$;

-- --- P7b: execution_mode / provider_dispatched / provider_response_status ---
ALTER TABLE project1_ai.bdj_results
  ADD COLUMN IF NOT EXISTS execution_mode text,
  ADD COLUMN IF NOT EXISTS provider_dispatched boolean,
  ADD COLUMN IF NOT EXISTS provider_response_status integer;

-- D-1 is NOT decided here: on a zero-row table this classifies nothing.
DO $$
DECLARE touched integer;
BEGIN
    UPDATE project1_ai.bdj_results
       SET execution_mode = CASE WHEN model_returned IS NULL
                                 THEN 'DETERMINISTIC_RULE_EVALUATION'
                                 ELSE 'MOCKED_PROVIDER_TEST' END,
           provider_dispatched = false,
           provider_response_status = NULL
     WHERE execution_mode IS NULL;
    GET DIAGNOSTICS touched = ROW_COUNT;
    RAISE NOTICE 'P7 backfill classified % row(s); D-1 remains open for real data', touched;
END $$;

ALTER TABLE project1_ai.bdj_results
  ALTER COLUMN execution_mode SET NOT NULL,
  ALTER COLUMN provider_dispatched SET NOT NULL,
  ALTER COLUMN provider_dispatched SET DEFAULT false;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'project1_ai.bdj_results'::regclass
                     AND conname = 'ck_bdj_execution_mode') THEN
        ALTER TABLE project1_ai.bdj_results
          ADD CONSTRAINT ck_bdj_execution_mode CHECK (execution_mode IN (
                'DETERMINISTIC_RULE_EVALUATION',
                'MOCKED_PROVIDER_TEST',
                'LIVE_PROVIDER_EXECUTION'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'project1_ai.bdj_results'::regclass
                     AND conname = 'ck_bdj_execution_dispatch') THEN
        ALTER TABLE project1_ai.bdj_results
          ADD CONSTRAINT ck_bdj_execution_dispatch CHECK (
                (execution_mode = 'LIVE_PROVIDER_EXECUTION') = provider_dispatched);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'project1_ai.bdj_results'::regclass
                     AND conname = 'ck_bdj_execution_status') THEN
        ALTER TABLE project1_ai.bdj_results
          ADD CONSTRAINT ck_bdj_execution_status CHECK (
                provider_response_status IS NULL
                OR (provider_response_status BETWEEN 100 AND 599));
    END IF;
END $$;

COMMENT ON COLUMN project1_ai.bdj_results.execution_mode IS
  'Who evaluated: rule engine, mocked transport, or a real provider. Written by '
  'the execution path, never inferred by a report.';
COMMENT ON COLUMN project1_ai.bdj_results.provider_dispatched IS
  'True only if the transport actually opened a connection. This, not the '
  'attempt ledger, is what decides model_called.';
COMMENT ON COLUMN project1_ai.bdj_results.provider_response_status IS
  'HTTP status returned by the provider, when a response was received.';

-- --- receipts -----------------------------------------------------------
INSERT INTO project1_ai.schema_versions(version, receipt)
SELECT '20261118_03_qg_retry_slots_pg18', current_setting('project1.migration_receipt')
WHERE NOT EXISTS (SELECT 1 FROM project1_ai.schema_versions
                  WHERE version = '20261118_03_qg_retry_slots_pg18');

INSERT INTO project1_ai.schema_versions(version, receipt)
SELECT '20261121_04_execution_mode_pg18', current_setting('project1.migration_receipt')
WHERE NOT EXISTS (SELECT 1 FROM project1_ai.schema_versions
                  WHERE version = '20261121_04_execution_mode_pg18');

COMMIT;
