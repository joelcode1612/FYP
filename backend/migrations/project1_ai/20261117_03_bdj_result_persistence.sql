-- REVIEW CANDIDATE, EXPLICIT OPERATOR EXECUTION ONLY. Never run at startup.
-- Requires a reviewed target and receipt, e.g. SET project1.migration_target='Dss';
-- SET project1.migration_receipt='<actual reviewed change record>';
--
-- CP-04A: durable persistence of validated cloud-BDJ results.
--
-- WHY THIS EXISTS
-- The execution ledger (project1_ai.runs / attempts / attempt_receipts) records
-- that an attempt happened and what its output hashed to. It does not store the
-- structured result, the validation findings, the source references or the
-- review verdict, and it stores no original model output at all. Activity
-- History therefore cannot show a result — only a receipt.
--
-- WHAT THIS ADDS
--   bdj_results            one validated (or rejected) result per attempt
--   bdj_result_sources     the source references the result depends on
--   bdj_result_validations the individual schema/rule checks and their outcome
--   bdj_result_findings    which findings a result produced, at candidate authority
--   bdj_raw_responses      the original model output, encrypted, separately granted
--
-- Purely additive. Creates five new tables in project1_ai. It does not alter any
-- existing table, does not backfill, and does not change RLS on anything that
-- already exists. No raw prompt and no completion text is copied here:
-- result_payload holds the structured BDJ result only. That result does contain
-- the finding evidence spans (Finding.source_refs[].quote), which are verbatim
-- substrings of the declarations they cite -- so this table does hold quoted
-- answer text, by design, and must be protected accordingly.
--
-- VOCABULARY (CP-04A A1 reconciliation, see
-- docs/cp00_integration/CP04A_VOCAB_RECONCILIATION_SPEC.md).
-- This migration stores four INDEPENDENT dimensions. Three of them already had
-- an owner before this file existed and are reused verbatim, in the owner's
-- spelling. No dimension is translated into another and no fifth value is
-- invented:
--   D1 execution_outcome  lowercase triple owned by project1_ai.attempts.outcome
--                         and written by ledger.finish(). Must equal the
--                         attempt receipt's outcome (C5).
--   D2 validation_status  generated from D3; never written by an application.
--   D3 review_outcome     the BDJEngine.review() verdict, lowercase, nullable.
--   D4 finding_authority  single value; a cloud result may never claim authority.
-- An earlier draft of this file used an uppercase vocabulary (ADMITTED / HELD /
-- NO_ADMISSIBLE_FINDING / TIMED_OUT) that duplicated and contradicted the
-- application's. That draft was never applied to Dss and is withdrawn here.
--
-- Status: PROPOSED. NOT APPLIED to Dss. Application to a real database requires
-- the DBA procedure in docs/cp00_integration/ (MIG-AUTH-01); the only execution
-- so far is against the isolated clone `project1_workflow_tests`.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '60s';
DO $$
BEGIN
  IF current_database() NOT IN ('Dss', 'project1_workflow_tests')
     OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
  -- Dependencies this migration references but never creates.
  IF to_regclass('project1_ai.runs') IS NULL
     OR to_regclass('project1_ai.attempts') IS NULL THEN
    RAISE EXCEPTION 'project1_ai ledger missing: apply 20261111_01 first';
  END IF;
  -- deny_mutation() is a FUNCTION, not a relation: to_regclass would return
  -- NULL for a valid function and the guard would refuse a correct database.
  IF to_regproc('project1_ai.deny_mutation') IS NULL THEN
    RAISE EXCEPTION 'project1_ai.deny_mutation() missing: apply 20261111_01 first';
  END IF;
  IF to_regclass('public.m2_assessments') IS NULL
     OR to_regclass('public.m2_bdj_findings') IS NULL THEN
    RAISE EXCEPTION 'M2 assessment/finding tables missing: no result without a subject';
  END IF;
  -- Refuse to re-run. A partial state must be reconciled by a human, never by
  -- dropping the evidence that a previous attempt created.
  IF to_regclass('project1_ai.bdj_results') IS NOT NULL
     OR to_regclass('project1_ai.bdj_raw_responses') IS NOT NULL THEN
    RAISE EXCEPTION 'bdj result tables already exist: reconcile version before migrating';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1. Execution provenance + validated structured result
-- ---------------------------------------------------------------------------
CREATE TABLE project1_ai.bdj_results (
  result_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id                uuid NOT NULL,
  owner_user_id         uuid NOT NULL,
  attempt_no            integer NOT NULL CHECK (attempt_no BETWEEN 1 AND 6),
  assessment_id         uuid NOT NULL REFERENCES public.m2_assessments(id),
  assessment_revision   integer NOT NULL CHECK (assessment_revision >= 0),
  -- The input the run was computed over. A mismatch means the result is stale.
  source_fingerprint    text NOT NULL CHECK (source_fingerprint ~ '^[a-f0-9]{64}$'),
  ruleset_version       text NOT NULL CHECK (length(ruleset_version) BETWEEN 1 AND 64),
  prompt_version        text NOT NULL CHECK (length(prompt_version) BETWEEN 1 AND 64),
  model_requested       text NOT NULL CHECK (length(model_requested) BETWEEN 1 AND 128),
  -- The provider may serve a different snapshot than the one requested; record
  -- both rather than assuming they agree.
  model_returned        text CHECK (model_returned IS NULL
                                    OR length(model_returned) BETWEEN 1 AND 128),
  -- D1. Same three values, same spelling as project1_ai.attempts.outcome, which
  -- ledger.finish() already owns and hard-rejects anything outside. 'TIMED_OUT'
  -- is deliberately absent: a provider timeout means the outcome is UNKNOWN
  -- (provider.py maps E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN to unknown_outcome),
  -- and asserting "did not complete" could be false and may still be billed.
  execution_outcome     text NOT NULL CHECK (execution_outcome IN
                          ('returned','rejected','unknown_outcome')),
  output_digest         text CHECK (output_digest ~ '^[a-f0-9]{64}$'),
  result_schema_version text NOT NULL CHECK (length(result_schema_version) BETWEEN 1 AND 64),
  -- The structured BDJ result (the findings array). Not the raw completion.
  result_payload        jsonb,
  -- D3. The engine's verdict. NULL is a real state: the attempt was reserved and
  -- the provider failed, so nothing was ever reviewed. NULL is NOT 'not yet
  -- filled in' and must never be read as success.
  review_outcome        text CHECK (review_outcome IS NULL OR review_outcome IN
                          ('reviewed','rejected','stale')),
  -- D2. Functionally determined by D3 in this engine: review() validates if and
  -- only if it dispatched. Stored as a generated column so it cannot drift.
  validation_status     text GENERATED ALWAYS AS (
                          CASE WHEN review_outcome IS NULL      THEN 'not_validated'
                               WHEN review_outcome = 'rejected' THEN 'invalid'
                               ELSE 'valid' END) STORED,
  -- D4. The only authority a cloud-model result may hold. BCB requires
  -- independent review (review_state='VERIFIED' plus finding_hash,
  -- confirmation_id and review_event_id) before a finding can become a business
  -- finding; that is not reachable from this table, and the single-value CHECK
  -- makes the schema itself refuse the attempt rather than relying on convention.
  finding_authority     text NOT NULL CHECK (finding_authority = 'candidate_only'),
  -- Makes NO_ADMISSIBLE_FINDING derivable without reading the JSONB payload.
  finding_count         integer NOT NULL CHECK (finding_count >= 0),
  review_reason         text CHECK (review_reason IS NULL
                                    OR length(review_reason) BETWEEN 1 AND 512),
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bdj_results_attempt_fk
    FOREIGN KEY (run_id, owner_user_id, attempt_no)
    REFERENCES project1_ai.attempts(run_id, owner_user_id, attempt_no),
  -- One result per attempt. A retry is a new attempt, never an overwrite.
  CONSTRAINT bdj_results_one_per_attempt UNIQUE (run_id, attempt_no),
  -- C1. A returned response has a digest; anything else must not claim one.
  -- (ledger.finish() passes NULL for both failure outcomes.)
  CONSTRAINT bdj_results_digest_matches_outcome
    CHECK ((execution_outcome = 'returned') = (output_digest IS NOT NULL)),
  -- C2. A validated result always has a payload, even when it admits no finding
  -- (that case is the empty-findings object, not NULL). An invalid result has none.
  CONSTRAINT bdj_results_payload_requires_valid
    CHECK ((validation_status = 'valid') = (result_payload IS NOT NULL)),
  -- C3. Nothing may be recorded as reviewed unless it passed validation. With
  -- C2 this also forces review_outcome='reviewed' to carry a payload: a review
  -- that produced nothing to store is not representable.
  CONSTRAINT bdj_results_review_requires_validation
    CHECK (review_outcome <> 'reviewed' OR validation_status = 'valid'),
  -- C7. Nothing was validated without a review, so nothing can be stored.
  -- Redundant with C2 (validation_status is generated) but stated explicitly so
  -- the rule survives a future change to the generation expression.
  CONSTRAINT bdj_results_unreviewed_has_no_payload
    CHECK (review_outcome IS NOT NULL OR result_payload IS NULL),
  -- C8. A returned response is always judged. The forced-combination contract
  -- has no row for "came back but was never reviewed": if the provider returned,
  -- review() ran. This constraint is what makes that state unrepresentable, so a
  -- future writer cannot create a row no reader handles. result_contracts.
  -- classify() also refuses to produce it -- defence in depth, not a substitute.
  CONSTRAINT bdj_results_returned_requires_review
    CHECK (execution_outcome <> 'returned' OR review_outcome IS NOT NULL),
  -- C9. Only a review that actually produced findings may count any. NULL is
  -- absent from the list, so an unreviewed row cannot carry findings; 'rejected'
  -- is absent, so a rejected row cannot either. This closes the one state
  -- classify() refuses but the schema used to allow: a rejected attempt
  -- carrying candidate-authority findings, which is precisely what the
  -- directive forbids. One predicate rather than two, because one is easier to
  -- keep true. 'stale' is included because the engine stores the findings it
  -- had already validated (bdj.py:131-133); classify() does the same.
  CONSTRAINT bdj_results_findings_require_review_check
    CHECK (finding_count = 0 OR review_outcome IN ('reviewed', 'stale'))
);

COMMENT ON TABLE project1_ai.bdj_results IS
  'CP-04A validated cloud-BDJ result. One row per attempt. Carries provenance, '
  'the structured result, and the four independent outcome dimensions '
  '(execution_outcome, generated validation_status, review_outcome, '
  'finding_authority). Holds no raw prompt and no completion text. '
  'result_payload DOES contain entrepreneur answer text: each finding carries '
  'Finding.source_refs[].quote, a verbatim substring of the declaration it '
  'cites. A History reader must therefore never return result_payload '
  'wholesale: it may project only the non-quote fields (rule_id, kind, '
  'observed_condition, counterargument, justification, next_action) and must '
  'treat source_refs[].quote as protected content requiring the same handling '
  'as bdj_raw_responses.';

COMMENT ON COLUMN project1_ai.bdj_results.result_payload IS
  'The structured BDJ result: {"findings": [...]}. PROTECTED CONTENT -- the '
  'findings embed verbatim answer quotes in source_refs[].quote, so this column '
  'must not be projected wholesale to any reader. Return the non-quote fields '
  'only; treat the quotes like bdj_raw_responses ciphertext.';

COMMENT ON COLUMN project1_ai.bdj_results.execution_outcome IS
  'D1 provider/transport outcome. Owner: project1_ai.attempts.outcome, written '
  'by ledger.finish(). Values returned|rejected|unknown_outcome. Must equal the '
  'attempt receipt outcome (C5, enforced by the service: the value is copied '
  'from the ledger, never derived from the review).';

COMMENT ON COLUMN project1_ai.bdj_results.review_outcome IS
  'D3 BDJEngine.review() verdict. Owner: the engine return value. Values '
  'reviewed|rejected|stale, or NULL when the attempt was reserved but the '
  'provider never returned, so no review happened. reviewed means the engine '
  'completed; it never means the finding is true.';

COMMENT ON COLUMN project1_ai.bdj_results.validation_status IS
  'D2 structured-response validation outcome, generated from review_outcome: '
  'NULL->not_validated, rejected->invalid, otherwise valid. Generated because '
  'review() validates if and only if it dispatched, so an independently written '
  'value could only ever disagree with the review.';

COMMENT ON COLUMN project1_ai.bdj_results.finding_authority IS
  'D4 authority this result may claim over its findings. Fixed at '
  'candidate_only: a model-assisted result can never be verified without '
  'independent review, which BCB enforces outside this table.';

COMMENT ON COLUMN project1_ai.bdj_results.finding_count IS
  'Number of findings in result_payload.findings. Stored so the derived state '
  'NO_ADMISSIBLE_FINDING is queryable without opening the JSONB payload.';

COMMENT ON COLUMN project1_ai.bdj_results.review_reason IS
  'Optional fixed reason code for the review outcome (for example '
  'CANDIDATE_VALIDATION_FAILED). Never provider text, prompt text or answer '
  'content.';

-- NO_ADMISSIBLE_FINDING is a DERIVED state, not a stored value and not a fifth
-- review outcome:
--     review_outcome = 'reviewed' AND finding_count = 0
-- 'reviewed' means only that the engine completed without a validation failure
-- or a stale fingerprint. It is deliberately not merged with "there is
-- something to show", because that merge is what let an empty result read as an
-- admitted finding in the withdrawn draft.
--
-- 'held' is NOT representable in this table, on purpose. BDJEngine.review()
-- returns 'held' at bdj.py:70-73 when no ruleset has been adopted, which is
-- BEFORE ledger.reserve() is ever called. No attempt row exists, so the
-- composite FK to attempts(run_id, owner_user_id, attempt_no) has no target.
-- Storing it would require a nullable FK (weakening integrity) or a synthetic
-- attempt row (fabricating an attempt). 'held' stays in the response body and
-- the workflow projection, where it already lives.

CREATE INDEX bdj_results_owner_recent_idx
  ON project1_ai.bdj_results (owner_user_id, created_at DESC);
CREATE INDEX bdj_results_assessment_idx
  ON project1_ai.bdj_results (assessment_id, assessment_revision, created_at DESC);

-- ---------------------------------------------------------------------------
-- 2. Supporting source references
-- ---------------------------------------------------------------------------
CREATE TABLE project1_ai.bdj_result_sources (
  result_id          uuid NOT NULL
                       REFERENCES project1_ai.bdj_results(result_id) ON DELETE RESTRICT,
  owner_user_id      uuid NOT NULL,
  source_rank        integer NOT NULL CHECK (source_rank >= 1),
  source_id          text NOT NULL CHECK (length(source_id) BETWEEN 1 AND 256),
  source_version     text NOT NULL CHECK (length(source_version) BETWEEN 1 AND 128),
  source_fingerprint text CHECK (source_fingerprint ~ '^[a-f0-9]{64}$'),
  locator            text CHECK (locator IS NULL OR length(locator) BETWEEN 1 AND 512),
  PRIMARY KEY (result_id, source_rank),
  -- A locator is a POINTER, and there is no legitimate prose value for it. It
  -- must name a valid item_key -- the same pattern SourceRef enforces at
  -- contracts.py:29 -- optionally suffixed with '@<item_version_id>' and with no
  -- whitespace anywhere. A verbatim answer quote is prose and almost always
  -- contains a space, so it cannot pass. A single-word quote deliberately
  -- prefixed with 'M2-04@' still would: that is an act of intent, not an
  -- accident, and the writer-side construction is the second layer. This CHECK
  -- exists for the accident.
  CONSTRAINT bdj_result_sources_locator_pointer_check
    CHECK (locator IS NULL OR locator ~
      '^(?:M2-(?:[0-9]{2}|O-0[12])|M2V1-(?:0[1-9]|1[01]))(@[^[:space:]]{1,128})?$')
);

-- ---------------------------------------------------------------------------
-- 3. Validation findings
-- ---------------------------------------------------------------------------
CREATE TABLE project1_ai.bdj_result_validations (
  result_id     uuid NOT NULL
                  REFERENCES project1_ai.bdj_results(result_id) ON DELETE RESTRICT,
  owner_user_id uuid NOT NULL,
  check_no      integer NOT NULL CHECK (check_no >= 1),
  check_code    text NOT NULL CHECK (length(check_code) BETWEEN 1 AND 64),
  severity      text NOT NULL CHECK (severity IN ('ERROR','WARNING','INFO')),
  passed        boolean NOT NULL,
  detail        text CHECK (detail IS NULL OR length(detail) BETWEEN 1 AND 1024),
  PRIMARY KEY (result_id, check_no)
);
-- detail is legitimately prose -- check_code is already the code, so constraining
-- this to a pattern would either duplicate check_code or exclude the explanation
-- the column exists for. It may describe WHY a check failed. It must never
-- reproduce the value that failed: not the quoted answer span, not the prompt,
-- not the provider body. The enforceable control is on the writer, which selects
-- from a fixed catalogue of details rather than interpolating content, and is
-- asserted by test; this comment is the reason that control exists.
COMMENT ON COLUMN project1_ai.bdj_result_validations.detail IS
  'Human-readable explanation of why this check passed or failed. May describe '
  'the failure; must never reproduce the quoted answer span, the prompt, or the '
  'provider body. Writers select from a fixed catalogue rather than '
  'interpolating content, because interpolated text is how answer quotes reach '
  'a column nobody is watching.';

-- ---------------------------------------------------------------------------
-- 4. Which findings this result produced
-- ---------------------------------------------------------------------------
CREATE TABLE project1_ai.bdj_result_findings (
  result_id     uuid NOT NULL
                  REFERENCES project1_ai.bdj_results(result_id) ON DELETE RESTRICT,
  -- NOT NULL, so the finding exists by construction: a finding that was
  -- rejected or held has no row in m2_bdj_findings and cannot be referenced
  -- here. Those states are therefore unrepresentable in this table rather than
  -- being recorded and disambiguated later.
  finding_id    uuid NOT NULL REFERENCES public.m2_bdj_findings(id),
  owner_user_id uuid NOT NULL,
  -- The only authority a cloud result may assert over a finding it produced.
  authority     text NOT NULL CHECK (authority = 'candidate'),
  PRIMARY KEY (result_id, finding_id)
);
COMMENT ON TABLE project1_ai.bdj_result_findings IS
  'Links a cloud BDJ result to the candidate findings it produced. A row '
  'asserts one thing only: this result produced this finding, at candidate '
  'authority. Because finding_id is NOT NULL and references '
  'public.m2_bdj_findings, a rejected or held finding -- which has no such row '
  '-- cannot appear here. The reason a result produced no finding lives on the '
  'parent row as review_outcome plus review_reason, never here: there is no '
  'per-finding free-text justification column, because an unconstrained text '
  'field in an append-only table is an invitation to record a rationale nobody '
  'validates. authority is fixed at ''candidate'' because a model-assisted '
  'result can never produce a verified finding; independent review is required '
  'for that and is enforced outside this table.';

COMMENT ON COLUMN project1_ai.bdj_result_findings.authority IS
  'Finding authority asserted by this cloud result. Single value candidate: a '
  'model-assisted result can never claim VERIFIED, which requires independent '
  'review (review_state=''VERIFIED'' with finding_hash, confirmation_id and '
  'review_event_id) enforced by BCB outside this schema.';

-- ---------------------------------------------------------------------------
-- 5. Protected original model output
-- ---------------------------------------------------------------------------
-- Deliberately a separate table with separate grants. The runtime may write it
-- but may not read it back, so an ordinary Activity History query cannot return
-- model text even if a future query is written carelessly. Reading it requires
-- the audit role and an explicit access decision.
CREATE TABLE project1_ai.bdj_raw_responses (
  result_id        uuid PRIMARY KEY
                     REFERENCES project1_ai.bdj_results(result_id) ON DELETE RESTRICT,
  owner_user_id    uuid NOT NULL,
  encryption_alg   text NOT NULL CHECK (encryption_alg IN
                     ('FERNET-AES128-CBC-HMAC-SHA256')),
  -- Which key encrypted it, so rotation can find and re-wrap old rows.
  key_id           text NOT NULL CHECK (length(key_id) BETWEEN 1 AND 64),
  ciphertext       bytea NOT NULL CHECK (octet_length(ciphertext) > 0),
  -- Integrity check over the plaintext, verifiable without the key being present.
  plaintext_digest text NOT NULL CHECK (plaintext_digest ~ '^[a-f0-9]{64}$'),
  plaintext_bytes  integer NOT NULL CHECK (plaintext_bytes > 0),
  retention_until  timestamptz NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bdj_raw_responses_retention_forward
    CHECK (retention_until > created_at)
);
COMMENT ON TABLE project1_ai.bdj_raw_responses IS
  'CP-04A original model output, encrypted at rest. Distinct from '
  'bdj_results.result_payload (the validated structured result). Never returned '
  'by general Activity History responses; readable only by the audit role.';

INSERT INTO project1_ai.schema_versions(version, receipt)
VALUES ('20261117_03_bdj_result_persistence',
        current_setting('project1.migration_receipt'));

-- ---------------------------------------------------------------------------
-- Ownership, RLS, immutability and grants.
--
-- Written out per table rather than generated with format/identifier
-- substitution: a reviewer (or a DBA) must be able to read exactly which
-- privilege is granted on which table without mentally executing a loop, and
-- client drivers interpret percent-prefixed sequences inside a format string as
-- parameter markers even when they appear in a comment.
-- Same posture as the existing ledger: NOLOGIN owner, RLS forced, append-only,
-- never writable by PUBLIC.
-- ---------------------------------------------------------------------------

ALTER TABLE project1_ai.bdj_results OWNER TO p1ai_owner;
ALTER TABLE project1_ai.bdj_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE project1_ai.bdj_results FORCE ROW LEVEL SECURITY;
REVOKE ALL ON project1_ai.bdj_results FROM PUBLIC;
CREATE POLICY owner_scope ON project1_ai.bdj_results
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);
CREATE POLICY technical_audit_read ON project1_ai.bdj_results
  FOR SELECT TO p1ai_audit USING (true);
CREATE TRIGGER immutable_history BEFORE UPDATE OR DELETE ON project1_ai.bdj_results
  FOR EACH ROW EXECUTE FUNCTION project1_ai.deny_mutation();

ALTER TABLE project1_ai.bdj_result_sources OWNER TO p1ai_owner;
ALTER TABLE project1_ai.bdj_result_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE project1_ai.bdj_result_sources FORCE ROW LEVEL SECURITY;
REVOKE ALL ON project1_ai.bdj_result_sources FROM PUBLIC;
CREATE POLICY owner_scope ON project1_ai.bdj_result_sources
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);
CREATE POLICY technical_audit_read ON project1_ai.bdj_result_sources
  FOR SELECT TO p1ai_audit USING (true);
CREATE TRIGGER immutable_history BEFORE UPDATE OR DELETE ON project1_ai.bdj_result_sources
  FOR EACH ROW EXECUTE FUNCTION project1_ai.deny_mutation();

ALTER TABLE project1_ai.bdj_result_validations OWNER TO p1ai_owner;
ALTER TABLE project1_ai.bdj_result_validations ENABLE ROW LEVEL SECURITY;
ALTER TABLE project1_ai.bdj_result_validations FORCE ROW LEVEL SECURITY;
REVOKE ALL ON project1_ai.bdj_result_validations FROM PUBLIC;
CREATE POLICY owner_scope ON project1_ai.bdj_result_validations
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);
CREATE POLICY technical_audit_read ON project1_ai.bdj_result_validations
  FOR SELECT TO p1ai_audit USING (true);
CREATE TRIGGER immutable_history BEFORE UPDATE OR DELETE ON project1_ai.bdj_result_validations
  FOR EACH ROW EXECUTE FUNCTION project1_ai.deny_mutation();

ALTER TABLE project1_ai.bdj_result_findings OWNER TO p1ai_owner;
ALTER TABLE project1_ai.bdj_result_findings ENABLE ROW LEVEL SECURITY;
ALTER TABLE project1_ai.bdj_result_findings FORCE ROW LEVEL SECURITY;
REVOKE ALL ON project1_ai.bdj_result_findings FROM PUBLIC;
CREATE POLICY owner_scope ON project1_ai.bdj_result_findings
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);
CREATE POLICY technical_audit_read ON project1_ai.bdj_result_findings
  FOR SELECT TO p1ai_audit USING (true);
CREATE TRIGGER immutable_history BEFORE UPDATE OR DELETE ON project1_ai.bdj_result_findings
  FOR EACH ROW EXECUTE FUNCTION project1_ai.deny_mutation();

ALTER TABLE project1_ai.bdj_raw_responses OWNER TO p1ai_owner;
ALTER TABLE project1_ai.bdj_raw_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE project1_ai.bdj_raw_responses FORCE ROW LEVEL SECURITY;
REVOKE ALL ON project1_ai.bdj_raw_responses FROM PUBLIC;
CREATE POLICY owner_scope ON project1_ai.bdj_raw_responses
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);
CREATE POLICY technical_audit_read ON project1_ai.bdj_raw_responses
  FOR SELECT TO p1ai_audit USING (true);
CREATE TRIGGER immutable_history BEFORE UPDATE OR DELETE ON project1_ai.bdj_raw_responses
  FOR EACH ROW EXECUTE FUNCTION project1_ai.deny_mutation();

-- Write path: the runtime records a result and may read results back.
GRANT SELECT, INSERT ON project1_ai.bdj_results            TO p1ai_runtime;
GRANT SELECT, INSERT ON project1_ai.bdj_result_sources     TO p1ai_runtime;
GRANT SELECT, INSERT ON project1_ai.bdj_result_validations TO p1ai_runtime;
GRANT SELECT, INSERT ON project1_ai.bdj_result_findings    TO p1ai_runtime;

-- The raw response is WRITE-ONLY for the runtime, on purpose: an ordinary
-- Activity History query cannot return model text even if a future query is
-- written carelessly. Reading it needs the audit role and an access decision.
GRANT INSERT ON project1_ai.bdj_raw_responses TO p1ai_runtime;

-- Audit read path, including the protected original response.
GRANT SELECT ON project1_ai.bdj_results            TO p1ai_audit;
GRANT SELECT ON project1_ai.bdj_result_sources     TO p1ai_audit;
GRANT SELECT ON project1_ai.bdj_result_validations TO p1ai_audit;
GRANT SELECT ON project1_ai.bdj_result_findings    TO p1ai_audit;
GRANT SELECT ON project1_ai.bdj_raw_responses      TO p1ai_audit;
COMMIT;
