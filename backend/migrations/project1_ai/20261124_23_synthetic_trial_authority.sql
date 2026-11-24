-- DD-021 — provision the objective-trial registry the adapter already expects.
-- Migration: 20261124_23_synthetic_trial_authority
-- Target: disposable / isolated cluster only. Never applied to Dss by tooling.
--
-- Contract source (authoritative, not invented): backend/tests/m2_bcb/
-- test_g1_bdj_connected.py:70-76 and test_g2_bdj_output_connected.py create
-- exactly this shape. PrivateSyntheticTrialRegistry then asserts the runtime
-- principal can SELECT and CANNOT write, and that the login is not the table
-- owner — so the grants below are part of the contract, not decoration.
--
-- Why the table is required at all: the objective route adds
-- RegisteredObjectiveDisclosure for every CloudTokenHarbor provider. That gate
-- reads an operator-provisioned authority row bound to the run. It exists so
-- that enabling a provider can never, by itself, authorise a cloud dispatch:
-- an operator must separately register the exact run. This migration creates
-- the registry; it does NOT create any authority row.
--
-- Deliberately absent: no INSERT/UPDATE/DELETE grant to p1ai_runtime, no
-- writer function, no seed data. Provisioning a row remains a separate,
-- auditable operator act.

BEGIN;

CREATE TABLE IF NOT EXISTS project1_ai.synthetic_trial_authority (
    run_id             uuid PRIMARY KEY REFERENCES project1_ai.runs(id),
    owner_user_id      uuid NOT NULL,
    authorization_json jsonb NOT NULL
);

REVOKE ALL ON project1_ai.synthetic_trial_authority FROM PUBLIC;

GRANT SELECT ON project1_ai.synthetic_trial_authority TO p1ai_runtime;

ALTER TABLE project1_ai.synthetic_trial_authority ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS owner_scope ON project1_ai.synthetic_trial_authority;
CREATE POLICY owner_scope ON project1_ai.synthetic_trial_authority
    FOR SELECT USING (owner_user_id = project1_identity.verified_actor());

COMMIT;
