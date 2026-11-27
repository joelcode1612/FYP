-- PROPOSAL ONLY — NOT APPLIED, NOT REHEARSED. Requires separate approval.
--
-- CP-FINAL-02 addendum: durable evidence for a governed write that inserted
-- zero rows.
--
-- The gap this closes
-- -------------------
-- `m2_bdj_objective_proposals` records one row per *recommendation*. A run that
-- legitimately proposes nothing — the model returned a validated payload with
-- zero recommendations, or the model abstained — inserts zero rows and
-- therefore leaves no trace in the domain table at all.
--
-- Measured on project1_pg18_migrated_tests @ 5544 (2026-11-26):
--   * `public.m2_bdj_evaluations` exists but has 0 rows and no writer; it is the
--     BDJ *source evaluation* header, a different pipeline (DD-124), so reusing
--     it here would conflate the two.
--   * `project1_ai.bdj_raw_responses` is written only by the source-evaluation
--     path; the objective-proposal path stores no raw payload.
--   * the ledger receipt proves the provider *answered*; it does not prove the
--     governed INSERT committed.
--
-- Consequence today: for an attempt bound to a run, `persisted = 0` is
-- ambiguous. It can mean "a valid zero-proposal outcome" or "the write failed
-- before inserting anything". The status projection therefore refuses to
-- complete the Persisted milestone (`RETURNED / RETURNED_NOT_PERSISTED`) rather
-- than guess, which is correct but leaves a legitimate zero-proposal run unable
-- to show completion.
--
-- What this adds
-- --------------
-- One row per governed write attempt, inserted in the *same transaction* as the
-- proposal rows. Its presence is the evidence that the write committed; its
-- `recommendation_count` distinguishes zero from positive without counting
-- proposal rows.
--
-- Why a table rather than a column
-- --------------------------------
-- The fact belongs to the write, not to a proposal: with zero proposals there is
-- no row to carry it. A nullable column on a table with no rows cannot record
-- "this attempt wrote nothing".
--
-- Compatibility
-- -------------
-- * New table only; no existing table, column or row is touched.
-- * Old readers ignore it. The status projection uses it only when present.
-- * Rows are append-only by policy: one per (run_id, attempt_no). A duplicate
--   governed write for the same attempt is refused by the primary key, which is
--   the same guarantee `attempts` already gives.

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '60s';

DO $$
BEGIN
  IF current_setting('project1.migration_target', true)
       IS DISTINCT FROM current_database()
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
  IF to_regclass('project1_ai.attempts') IS NULL THEN
    RAISE EXCEPTION 'Execution ledger missing: reconcile before migrating';
  END IF;
END $$;

CREATE TABLE project1_ai.objective_writes (
  run_id uuid NOT NULL,
  attempt_no integer NOT NULL,
  owner_user_id uuid NOT NULL,
  assessment_id uuid NOT NULL,
  -- 0 is a first-class value: it is the valid zero-proposal outcome.
  recommendation_count integer NOT NULL CHECK (recommendation_count >= 0),
  contract_version text NOT NULL,
  prompt_version text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, attempt_no),
  FOREIGN KEY (run_id, attempt_no)
    REFERENCES project1_ai.attempts (run_id, attempt_no) ON DELETE RESTRICT,
  FOREIGN KEY (run_id, owner_user_id)
    REFERENCES project1_ai.runs (id, owner_user_id) ON DELETE RESTRICT,
  FOREIGN KEY (run_id, assessment_id)
    REFERENCES project1_ai.runs (id, assessment_id) ON DELETE RESTRICT
);

-- The status read is always "the write for this attempt", which the primary key
-- already serves; this index serves the assessment-wide diagnostic instead.
CREATE INDEX objective_writes_assessment_idx
  ON project1_ai.objective_writes (assessment_id, created_at DESC);

COMMIT;
