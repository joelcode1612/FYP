-- Execution-mode axis: record WHO evaluated, not just what was produced.
--
-- WHY THIS EXISTS
-- A BDJ result row could not say whether it came from the rule engine, a mocked
-- transport, or a real provider. The attempt ledger records that an attempt was
-- RESERVED, which reads like a model call and is not one. This migration makes
-- the distinction a property of the row, so it cannot be inferred wrongly.
--
-- THREE VALUES, ONE PER EVALUATION
--   DETERMINISTIC_RULE_EVALUATION  the rules module produced it
--   MOCKED_PROVIDER_TEST           a transport double stood in for the provider
--   LIVE_PROVIDER_EXECUTION        a real socket opened and a response returned
--
-- provider_dispatched is the antidote to the ledger trap: only the transport
-- knows whether a connection was opened, so only it may set this. model_called
-- is DERIVED from it, never inferred from project1_ai.attempts.
--
-- LEGACY BACKFILL, AND ITS HONEST LIMIT
-- Rows written before this column cannot be classified with certainty: a mocked
-- run that recorded a model identity looks identical to a live one. They are
-- backfilled as DETERMINISTIC_RULE_EVALUATION when no model was recorded and
-- MOCKED_PROVIDER_TEST otherwise. NO legacy row is ever LIVE_PROVIDER_EXECUTION,
-- because none of them opened a real connection. That is the point of adding
-- the column: from here on the value is written by the transport.
--
-- STATUS: PROPOSED. NOT APPLIED. Refuses the protected database by name.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required';
  END IF;

  IF current_database() = 'Dss' THEN
    RAISE EXCEPTION 'Refusing to add execution mode on protected database %', current_database();
  END IF;

  IF to_regclass('project1_ai.bdj_results') IS NULL THEN
    RAISE EXCEPTION 'project1_ai.bdj_results missing; apply the result persistence migration first';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'project1_ai' AND table_name = 'bdj_results'
               AND column_name = 'execution_mode') THEN
    RAISE EXCEPTION 'execution_mode already exists: reconcile version before migrating';
  END IF;
END
$guard$;

ALTER TABLE project1_ai.bdj_results
  ADD COLUMN execution_mode text,
  ADD COLUMN provider_dispatched boolean,
  ADD COLUMN provider_response_status integer;

UPDATE project1_ai.bdj_results
   SET execution_mode = CASE WHEN model_returned IS NULL
                             THEN 'DETERMINISTIC_RULE_EVALUATION'
                             ELSE 'MOCKED_PROVIDER_TEST' END,
       provider_dispatched = false,
       provider_response_status = NULL;

ALTER TABLE project1_ai.bdj_results
  ALTER COLUMN execution_mode SET NOT NULL,
  ALTER COLUMN provider_dispatched SET NOT NULL,
  ALTER COLUMN provider_dispatched SET DEFAULT false,
  ADD CONSTRAINT ck_bdj_execution_mode CHECK (execution_mode IN (
        'DETERMINISTIC_RULE_EVALUATION',
        'MOCKED_PROVIDER_TEST',
        'LIVE_PROVIDER_EXECUTION')),
  -- A live execution must have dispatched; a non-live one must not claim it.
  ADD CONSTRAINT ck_bdj_execution_dispatch CHECK (
        (execution_mode = 'LIVE_PROVIDER_EXECUTION') = provider_dispatched),
  ADD CONSTRAINT ck_bdj_execution_status CHECK (
        provider_response_status IS NULL
        OR (provider_response_status BETWEEN 100 AND 599));

COMMENT ON COLUMN project1_ai.bdj_results.execution_mode IS
  'Who evaluated: rule engine, mocked transport, or a real provider. Written by '
  'the execution path, never inferred by a report.';
COMMENT ON COLUMN project1_ai.bdj_results.provider_dispatched IS
  'True only if the transport actually opened a connection. This, not the '
  'attempt ledger, is what decides model_called.';
COMMENT ON COLUMN project1_ai.bdj_results.provider_response_status IS
  'HTTP status returned by the provider, when a response was received.';

COMMIT;
