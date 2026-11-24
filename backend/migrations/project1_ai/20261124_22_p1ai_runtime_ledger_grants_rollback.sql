-- Rollback for 20261124_22_p1ai_runtime_ledger_grants.
-- Restores the exact pre-migration privilege set, which was:
--   bdj_results                     : SELECT           (pre-existing, must survive)
--   bdj_authorization_consumptions  : SELECT, INSERT   (pre-existing, untouched here)
--   everything else                 : no privilege
--
-- bdj_results therefore loses only INSERT. A blanket "REVOKE ALL" on it would
-- remove a pre-existing SELECT and leave the cluster less privileged than the
-- baseline, which would be a different change than this one.

BEGIN;

REVOKE ALL ON project1_ai.runs             FROM p1ai_runtime;
REVOKE ALL ON project1_ai.attempts         FROM p1ai_runtime;
REVOKE ALL ON project1_ai.attempt_receipts FROM p1ai_runtime;

REVOKE INSERT ON project1_ai.bdj_results   FROM p1ai_runtime;   -- SELECT is kept

REVOKE ALL ON project1_ai.bdj_result_sources     FROM p1ai_runtime;
REVOKE ALL ON project1_ai.bdj_result_validations FROM p1ai_runtime;
REVOKE ALL ON project1_ai.bdj_result_findings    FROM p1ai_runtime;

REVOKE ALL ON project1_ai.bdj_raw_responses      FROM p1ai_runtime;

COMMIT;
