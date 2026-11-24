-- DD-020 correction — restore the ledger privileges p1ai_runtime is supposed to hold.
-- Migration: 20261124_22_p1ai_runtime_ledger_grants
-- Target: disposable / isolated cluster only. Never applied to Dss by tooling.
--
-- Why this exists
--   The grant blocks in 20261111_01 (candidate ledger) and 20261117_03 (BDJ result
--   persistence) were never applied to the isolated PG18 cluster, while later
--   migrations were. The runtime principal therefore held SELECT on bdj_results and
--   SELECT/INSERT on bdj_authorization_consumptions and nothing else, so the first
--   ledger write (INSERT INTO runs) failed with "permission denied for table runs".
--   Because that write precedes the provider call and the spend, a dispatch attempt
--   could not consume its authorization — safe, but unusable.
--
-- What is granted, and only this
--   * SELECT + INSERT on runs/attempts/attempt_receipts and the three BDJ result
--     satellites: the runtime appends rows, it never rewrites them.
--   * UPDATE(id) on runs ONLY: required by "SELECT ... FOR UPDATE" on the run row.
--     Column-scoped, so no other column can be rewritten.
--   * INSERT on bdj_results and bdj_raw_responses: SELECT on bdj_results is already
--     held; bdj_raw_responses stays write-only by design.
--
-- What is deliberately NOT granted
--   * No DELETE, no TRUNCATE, no UPDATE on attempts/receipts/results: append-only
--     protection is preserved by the absence of the privilege, not by convention.
--   * No privilege at all on finding_provenance: nothing in the runtime modules
--     writes it.
--   * No privilege on synthetic_trial_authority: the registry adapter REQUIRES the
--     runtime principal to be unable to write it (SYNTHETIC_AUTHORITY_PERMISSIONS_INVALID).
--   * No SUPERUSER, no BYPASSRLS, no role membership change: RLS stays enforced.
--
-- Idempotent: GRANT is a no-op when already held.
-- Rollback: 20261124_22_p1ai_runtime_ledger_grants_rollback.sql

BEGIN;

GRANT SELECT, INSERT ON project1_ai.runs             TO p1ai_runtime;
GRANT UPDATE(id)     ON project1_ai.runs             TO p1ai_runtime;

GRANT SELECT, INSERT ON project1_ai.attempts         TO p1ai_runtime;
GRANT SELECT, INSERT ON project1_ai.attempt_receipts TO p1ai_runtime;

GRANT INSERT ON project1_ai.bdj_results              TO p1ai_runtime;

GRANT SELECT, INSERT ON project1_ai.bdj_result_sources     TO p1ai_runtime;
GRANT SELECT, INSERT ON project1_ai.bdj_result_validations TO p1ai_runtime;
GRANT SELECT, INSERT ON project1_ai.bdj_result_findings    TO p1ai_runtime;

GRANT INSERT ON project1_ai.bdj_raw_responses        TO p1ai_runtime;

COMMIT;
