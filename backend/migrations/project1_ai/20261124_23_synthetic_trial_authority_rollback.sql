-- Rollback for 20261124_23_synthetic_trial_authority.
-- The table is created by this migration only, so dropping it restores the
-- pre-migration state exactly. Refuses nothing: an authority row is an operator
-- artefact and would be destroyed with it, so run this only when no registered
-- trial is meant to survive.

BEGIN;

DROP POLICY IF EXISTS owner_scope ON project1_ai.synthetic_trial_authority;
DROP TABLE IF EXISTS project1_ai.synthetic_trial_authority;

COMMIT;
