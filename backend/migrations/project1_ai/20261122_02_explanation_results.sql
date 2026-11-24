-- REVIEW CANDIDATE, EXPLICIT OPERATOR EXECUTION ONLY. Never run at startup.
-- Requires a reviewed target and receipt, e.g.
--   SET project1.migration_target='project1_workflow_tests';
--   SET project1.migration_receipt='<actual reviewed change record>';
--
-- EX-02/EX-03: durable persistence of explanation results.
--
-- WHY THIS EXISTS
-- The execution ledger (project1_ai.runs / attempts / attempt_receipts) records
-- that an attempt happened and what its output hashed to. It stores no
-- explanation text, no validation finding, no report-section linkage and no
-- history, so an explanation cannot be reconstructed from it. project1_ai has
-- already separated execution from result once, for BDJ (20261117_03); this
-- follows that pattern rather than inventing a second mechanism.
--
-- WHAT THIS ADDS
--   explanation_results            one explanation per (snapshot, item, producer)
--   explanation_result_validations the individual V01-V09 checks and their outcome
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   * it does not create a new ledger, provider framework or report design;
--   * it does not alter attempts, attempt_receipts or runs;
--   * it does not backfill and does not touch ai_explanation (legacy,
--     property-scoped, and a different subject entirely);
--   * it grants no authority. admitted is fixed false and authority is fixed
--     'CANDIDATE_UNVERIFIED', so a row can never assert publication.
--
-- DETERMINISTIC ROWS ARE FIRST-CLASS
-- A deterministic explanation has run_id NULL, attempt_no NULL and
-- execution_kind='DETERMINISTIC_ONLY'. No attempt row is fabricated to make the
-- table uniform: fabricating one would misreport the ledger, which is the one
-- thing an audit trail must never do. The CHECK pair below makes both
-- misrepresentations unrepresentable.
--
-- Status: PROPOSED. NOT APPLIED. The only execution so far is the in-memory
-- store exercised by tests/project1/test_explanation_store.py.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '60s';
DO $$
BEGIN
  IF current_database() NOT IN ('Dss', 'project1_workflow_tests', 'project1_disposable_app')
     OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
  IF to_regclass('project1_ai.attempts') IS NULL THEN
    RAISE EXCEPTION 'project1_ai.attempts missing: apply 20261111_01 first';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM project1_ai.schema_versions
                 WHERE version = '20261122_01_explanation_stage') THEN
    RAISE EXCEPTION '20261122_01_explanation_stage missing: the EXPLANATION stage must exist first';
  END IF;
  IF to_regclass('project1_ai.explanation_results') IS NOT NULL THEN
    RAISE EXCEPTION 'explanation_results already exists: reconcile version before migrating';
  END IF;
END $$;

CREATE TABLE project1_ai.explanation_results (
  result_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id        uuid NOT NULL,
  assessment_id        uuid NOT NULL,
  campaign_id          uuid NOT NULL,
  -- The measurement this explanation is about. Never a property, never a
  -- free-text subject: an explanation without a snapshot has no evidence.
  snapshot_id          uuid NOT NULL,
  question_id          text CHECK (question_id IS NULL OR length(question_id) BETWEEN 1 AND 16),
  -- The input the explanation was computed over. A mismatch means it is stale.
  source_fingerprint   text NOT NULL CHECK (source_fingerprint ~ '^[a-f0-9]{64}$'),
  context_id           text NOT NULL CHECK (context_id ~ '^[a-f0-9]{64}$'),
  -- The explanation rules and the measurement rules it was rendered under.
  registry_version     text NOT NULL CHECK (length(registry_version) BETWEEN 1 AND 64),
  registry_sha256      text NOT NULL CHECK (registry_sha256 ~ '^[a-f0-9]{64}$'),
  ruleset_version      text NOT NULL CHECK (length(ruleset_version) BETWEEN 1 AND 128),
  task_mode            text NOT NULL CHECK (task_mode IN ('CLAIM_EXPLANATION','REPORT_SYNTHESIS')),
  -- D1: which producer ran. Says nothing about acceptance.
  execution_kind       text NOT NULL CHECK (execution_kind IN ('DETERMINISTIC_ONLY','AI_ATTEMPTED')),
  -- D2: the fallback outcome, from the service's own vocabulary.
  outcome              text NOT NULL CHECK (outcome IN (
                         'DETERMINISTIC_ONLY','AI_VALIDATED','AI_REJECTED_FELL_BACK',
                         'AI_UNAVAILABLE_FELL_BACK','AI_OUTCOME_UNKNOWN',
                         'HELD_INVALID_EVIDENCE','HELD_UNSUPPORTED_RULE','WITHHELD_ADMISSION')),
  -- Ledger linkage. NULL for a deterministic explanation, NOT NULL for an AI one.
  run_id               uuid,
  attempt_no           integer CHECK (attempt_no IS NULL OR attempt_no BETWEEN 1 AND 6),
  prompt_version       text CHECK (prompt_version IS NULL OR length(prompt_version) BETWEEN 1 AND 64),
  prompt_sha256        text CHECK (prompt_sha256 IS NULL OR prompt_sha256 ~ '^[a-f0-9]{64}$'),
  request_sha256       text CHECK (request_sha256 IS NULL OR request_sha256 ~ '^[a-f0-9]{64}$'),
  model_requested      text CHECK (model_requested IS NULL OR length(model_requested) BETWEEN 1 AND 128),
  model_returned       text CHECK (model_returned IS NULL OR length(model_returned) BETWEEN 1 AND 128),
  -- D3: validation outcome, in the vocabulary the ledger already uses.
  validation_status    text NOT NULL CHECK (validation_status IN ('not_validated','valid','invalid')),
  rejection_code       text CHECK (rejection_code IS NULL OR length(rejection_code) BETWEEN 1 AND 64),
  fallback_reason      text CHECK (fallback_reason IS NULL OR length(fallback_reason) BETWEEN 1 AND 256),
  retry_authorized     boolean NOT NULL DEFAULT false,
  -- The explanation content. Six fields, matching ExplanationOutput.
  headline                  text NOT NULL CHECK (length(headline) BETWEEN 1 AND 300),
  observation_interpretation text NOT NULL CHECK (length(observation_interpretation) BETWEEN 1 AND 2000),
  research_interpretation    text NOT NULL CHECK (length(research_interpretation) BETWEEN 1 AND 2000),
  planning_implication       text NOT NULL CHECK (length(planning_implication) BETWEEN 1 AND 2000),
  limitations                text NOT NULL CHECK (length(limitations) BETWEEN 1 AND 2000),
  summary                    text NOT NULL CHECK (length(summary) BETWEEN 1 AND 2000),
  insufficient_evidence      boolean NOT NULL,
  missing_evidence_references text[] NOT NULL DEFAULT '{}',
  report_sections            text[] NOT NULL DEFAULT '{}',
  -- D4: authority. Fixed, so no writer can assert publication from this table.
  authority            text NOT NULL CHECK (authority = 'CANDIDATE_UNVERIFIED'),
  admitted             boolean NOT NULL CHECK (admitted = false),
  -- D5: staleness. A reason, never a delete: history must stay reconstructible.
  stale_reason         text CHECK (stale_reason IS NULL OR length(stale_reason) BETWEEN 1 AND 128),
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT explanation_results_attempt_fk
    FOREIGN KEY (run_id, owner_user_id, attempt_no)
    REFERENCES project1_ai.attempts(run_id, owner_user_id, attempt_no),
  -- The fabrication rule, in both directions. A deterministic explanation may
  -- not name a run, and an AI explanation may not omit the one that produced it.
  CONSTRAINT explanation_results_deterministic_has_no_run
    CHECK (execution_kind <> 'DETERMINISTIC_ONLY'
           OR (run_id IS NULL AND attempt_no IS NULL AND prompt_version IS NULL)),
  CONSTRAINT explanation_results_ai_names_its_run
    CHECK (execution_kind <> 'AI_ATTEMPTED'
           OR (run_id IS NOT NULL AND attempt_no IS NOT NULL AND prompt_version IS NOT NULL)),
  -- A validated row must have run all nine rules; an invalid one must say which
  -- failed. This makes "invalid with no reason" unrepresentable.
  CONSTRAINT explanation_results_invalid_names_a_reason
    CHECK (validation_status <> 'invalid' OR rejection_code IS NOT NULL),
  -- An unknown outcome may never be retried from this record.
  CONSTRAINT explanation_results_unknown_outcome_not_retryable
    CHECK (outcome <> 'AI_OUTCOME_UNKNOWN' OR retry_authorized = false)
);

COMMENT ON TABLE project1_ai.explanation_results IS
  'Versioned EE-01 explanation result at candidate authority. One row per '
  'explanation; a revalidation is a new row, never an overwrite. Holds the six '
  'ExplanationOutput prose fields and their validation outcome, and links to the '
  'execution ledger only when an AI attempt actually ran. admitted is fixed '
  'false and authority is fixed CANDIDATE_UNVERIFIED: publication is decided by '
  'A10 outside this table and is not representable here.';

COMMENT ON COLUMN project1_ai.explanation_results.execution_kind IS
  'Which producer ran. DETERMINISTIC_ONLY carries no run/attempt/prompt and is '
  'the authoritative baseline; AI_ATTEMPTED must name the ledger attempt that '
  'produced it. A deterministic explanation is never dressed as a cloud run.';

COMMENT ON COLUMN project1_ai.explanation_results.outcome IS
  'Fallback outcome. AI_OUTCOME_UNKNOWN means the provider may have run and may '
  'have billed; it is not a definite failure and is never auto-retried '
  '(enforced by explanation_results_unknown_outcome_not_retryable).';

COMMENT ON COLUMN project1_ai.explanation_results.stale_reason IS
  'Why this result may no longer be used: SOURCE_FINGERPRINT_CHANGED, '
  'EXPLANATION_REGISTRY_CHANGED or MEASUREMENT_RULESET_CHANGED. Rows are marked, '
  'never deleted, so a historical explanation and its validation stay '
  'reconstructible.';

CREATE INDEX explanation_results_current_idx
  ON project1_ai.explanation_results
     (assessment_id, snapshot_id, question_id, created_at DESC)
  WHERE stale_reason IS NULL;
CREATE INDEX explanation_results_owner_idx
  ON project1_ai.explanation_results (owner_user_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- V01-V09 findings for one result
-- ---------------------------------------------------------------------------
CREATE TABLE project1_ai.explanation_result_validations (
  result_id     uuid NOT NULL
                  REFERENCES project1_ai.explanation_results(result_id) ON DELETE RESTRICT,
  owner_user_id uuid NOT NULL,
  rule_id       text NOT NULL CHECK (rule_id IN ('V01','V02','V03','V04','V05','V06','V07','V08','V09')),
  passed        boolean NOT NULL,
  code          text CHECK (code IS NULL OR length(code) BETWEEN 1 AND 64),
  detail        text CHECK (detail IS NULL OR length(detail) BETWEEN 1 AND 512),
  PRIMARY KEY (result_id, rule_id)
);
COMMENT ON TABLE project1_ai.explanation_result_validations IS
  'One row per V-rule per result. detail may describe WHY a rule failed; it must '
  'never reproduce the candidate prose, the prompt or the provider body. Writers '
  'select from a fixed catalogue rather than interpolating content.';

ALTER TABLE project1_ai.explanation_results OWNER TO p1ai_owner;
ALTER TABLE project1_ai.explanation_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE project1_ai.explanation_results FORCE ROW LEVEL SECURITY;
REVOKE ALL ON project1_ai.explanation_results FROM PUBLIC;
CREATE POLICY owner_scope ON project1_ai.explanation_results
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);
CREATE POLICY technical_audit_read ON project1_ai.explanation_results
  FOR SELECT TO p1ai_audit USING (true);
CREATE TRIGGER immutable_history BEFORE UPDATE OR DELETE ON project1_ai.explanation_results
  FOR EACH ROW EXECUTE FUNCTION project1_ai.deny_mutation();

ALTER TABLE project1_ai.explanation_result_validations OWNER TO p1ai_owner;
ALTER TABLE project1_ai.explanation_result_validations ENABLE ROW LEVEL SECURITY;
ALTER TABLE project1_ai.explanation_result_validations FORCE ROW LEVEL SECURITY;
REVOKE ALL ON project1_ai.explanation_result_validations FROM PUBLIC;
CREATE POLICY owner_scope ON project1_ai.explanation_result_validations
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);
CREATE POLICY technical_audit_read ON project1_ai.explanation_result_validations
  FOR SELECT TO p1ai_audit USING (true);
CREATE TRIGGER immutable_history BEFORE UPDATE OR DELETE ON project1_ai.explanation_result_validations
  FOR EACH ROW EXECUTE FUNCTION project1_ai.deny_mutation();

-- The immutability trigger forbids UPDATE, so staleness is recorded by
-- INSERTing a superseding row with the stale_reason set on the new row rather
-- than by mutating the old one. A reader treats the newest non-stale row as
-- current; the older row remains as history. See explanation_store.py.

GRANT SELECT, INSERT ON project1_ai.explanation_results            TO p1ai_runtime;
GRANT SELECT, INSERT ON project1_ai.explanation_result_validations TO p1ai_runtime;
GRANT SELECT ON project1_ai.explanation_results            TO p1ai_audit;
GRANT SELECT ON project1_ai.explanation_result_validations TO p1ai_audit;

INSERT INTO project1_ai.schema_versions(version, receipt)
VALUES ('20261122_02_explanation_results',
        current_setting('project1.migration_receipt'));
COMMIT;
