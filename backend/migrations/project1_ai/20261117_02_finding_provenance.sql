-- REVIEW CANDIDATE, EXPLICIT OPERATOR EXECUTION ONLY. Never run at startup.
-- Requires a reviewed target and receipt, e.g. SET project1.migration_target='Dss';
-- SET project1.migration_receipt='<actual reviewed change record>';
--
-- CP-03F-04 / D05: link a persisted BDJ finding to the AI attempt ledger.
-- Purely additive: creates one new table. It does not alter public.m2_bdj_findings,
-- does not backfill, and stores no raw prompt, completion or provider payload —
-- only identifiers and digests.
--
-- Status: PROPOSED. Not applied. Dry-run validated inside a rolled-back
-- transaction by backend/scripts/cp03f_d05_migration_dryrun.py.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';
DO $$
BEGIN
  IF current_database() NOT IN ('Dss', 'project1_workflow_tests')
     OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
  -- The ledger this table references must already exist; this migration never
  -- creates it and never recreates it.
  IF to_regclass('project1_ai.runs') IS NULL
     OR to_regclass('project1_ai.attempts') IS NULL THEN
    RAISE EXCEPTION 'project1_ai ledger missing: apply 20261111_01 first';
  END IF;
  IF to_regclass('public.m2_bdj_findings') IS NULL THEN
    RAISE EXCEPTION 'public.m2_bdj_findings missing: no provenance without findings';
  END IF;
  IF to_regclass('project1_ai.finding_provenance') IS NOT NULL THEN
    RAISE EXCEPTION 'finding_provenance exists: reconcile version before migrating';
  END IF;
END $$;

CREATE TABLE project1_ai.finding_provenance (
  finding_id          uuid PRIMARY KEY,
  owner_user_id       uuid NOT NULL,
  assessment_id       uuid NOT NULL REFERENCES public.m2_assessments(id),
  assessment_revision integer NOT NULL CHECK (assessment_revision >= 0),
  -- A finding row must actually exist; provenance is not a parallel store.
  FOREIGN KEY (finding_id) REFERENCES public.m2_bdj_findings(id),
  execution_mode      text NOT NULL CHECK (execution_mode IN ('DETERMINISTIC','CLOUD')),
  -- Cloud rows must name a real attempt; deterministic rows must not.
  run_id              uuid,
  attempt_no          integer CHECK (attempt_no BETWEEN 1 AND 6),
  output_digest       text CHECK (output_digest ~ '^[a-f0-9]{64}$'),
  ruleset_version     text NOT NULL CHECK (length(ruleset_version) BETWEEN 1 AND 32),
  prompt_version      text,
  model_requested     text,
  model_returned      text,
  -- Authority this cloud/deterministic result asserts over the finding. Single
  -- value 'candidate': finding_id is NOT NULL and references
  -- public.m2_bdj_findings, so the finding exists by construction -- a rejected
  -- or held finding has no such row and cannot be recorded here. execution_mode
  -- already says how the finding was produced, so this column is not carrying
  -- provenance; it is asserting authority, and at creation a finding can only be
  -- a candidate. Verification requires independent review and is enforced by BCB
  -- outside this table, never by a value written here.
  authority           text NOT NULL CHECK (authority = 'candidate'),
  source_fingerprint  text NOT NULL CHECK (source_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK ((execution_mode = 'CLOUD') = (run_id IS NOT NULL)),
  -- MATCH SIMPLE: a NULL run_id skips the composite FK, which is exactly the
  -- deterministic case. A non-NULL run_id must pair with its owning attempt.
  FOREIGN KEY (run_id, owner_user_id, attempt_no)
    REFERENCES project1_ai.attempts(run_id, owner_user_id, attempt_no)
);
COMMENT ON TABLE project1_ai.finding_provenance IS
  'Provenance for a persisted BDJ finding. A row asserts that this finding was '
  'produced by this execution, at candidate authority. finding_id is NOT NULL '
  'and references public.m2_bdj_findings, so a rejected or held finding -- which '
  'has no such row -- cannot appear here. Stores identifiers and digests only: '
  'no prompt, completion or provider payload.';
COMMENT ON COLUMN project1_ai.finding_provenance.authority IS
  'Authority asserted over the finding. Single value candidate: a result may '
  'never claim VERIFIED here, which requires independent review (review_state, '
  'finding_hash, confirmation_id, review_event_id) enforced by BCB outside this '
  'schema. execution_mode records how the finding was produced; this column '
  'records what may be claimed about it.';

INSERT INTO project1_ai.schema_versions(version, receipt)
VALUES ('20261117_02_finding_provenance', current_setting('project1.migration_receipt'));

DO $$ BEGIN
  ALTER TABLE project1_ai.finding_provenance OWNER TO p1ai_owner;
  ALTER TABLE project1_ai.finding_provenance ENABLE ROW LEVEL SECURITY;
  ALTER TABLE project1_ai.finding_provenance FORCE ROW LEVEL SECURITY;
  CREATE POLICY owner_scope ON project1_ai.finding_provenance USING
    (owner_user_id = nullif(current_setting('project1.actor_id',true),'')::uuid)
    WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id',true),'')::uuid);
  -- Provenance is historical evidence: insert-only, like the rest of the ledger.
  CREATE TRIGGER immutable_history BEFORE UPDATE OR DELETE ON project1_ai.finding_provenance
    FOR EACH ROW EXECUTE FUNCTION project1_ai.deny_mutation();
  REVOKE ALL ON project1_ai.finding_provenance FROM PUBLIC;
  GRANT SELECT, INSERT ON project1_ai.finding_provenance TO p1ai_runtime;
  CREATE POLICY technical_audit_read ON project1_ai.finding_provenance
    FOR SELECT TO p1ai_audit USING (true);
  GRANT SELECT ON project1_ai.finding_provenance TO p1ai_audit;
END $$;
COMMIT;
