-- PROPOSAL ONLY — NOT APPLIED, NOT REHEARSED. Requires separate approval.
--
-- CP-FINAL-04: objective identity must exist at reservation time.
--
-- Why the existing records cannot answer "which execution is objective A01's?"
-- -------------------------------------------------------------------------
-- The status route can only read "the newest QG attempt for this assessment".
-- With two approved objectives generating, that shows one objective's progress
-- under the other's heading.
--
-- Reusing existing durable records was investigated first, and measured on
-- project1_pg18_migrated_tests @ 5544 (2026-11-26):
--
--   * `m2_qg_candidates` is the **only** table carrying both `objective_id` and
--     `run_id`/`attempt_no` — so the only objective→run link is post-persistence,
--     which is exactly the case the brief forbids relying on.
--   * `m2_qg_authorizations` carries `objective_id` and is written before
--     dispatch, but no run id. Reconstructing the run from it requires
--     `qg_work_identity(assessment, source_fingerprint, policy, authorization_id)`
--     — attempted for all 80 authorizations against all 11 QG runs:
--     **0 matched**. The stored runs were created under a different source or
--     policy fingerprint than any current authorization records, so the
--     reconstruction cannot be made without guessing.
--   * `project1_ai.runs` and `project1_ai.attempts` have no objective column.
--
-- Conclusion: objective identity is genuinely absent at reservation time. The
-- code therefore fails closed today — `execution_status(objective_id=...)`
-- returns `OBJECTIVE_IDENTITY_NOT_RECORDED` instead of the newest attempt.
--
-- What this adds
-- --------------
-- One nullable column on `project1_ai.runs`, plus the objective in the QG work
-- identity so two objectives can never share a run.
--
-- Why `runs` and not `attempts`
-- -----------------------------
-- `runs` already carries owner, assessment and revision; the objective completes
-- that tuple. `attempts` joins to `runs` by `(run_id, owner_user_id)`, so an
-- attempt inherits the objective without a second column that could disagree.
--
-- Why the work identity must change too
-- -------------------------------------
-- `qg_work_identity` currently hashes assessment, source, policy and
-- evaluation id. Two objectives over the same facts with the same policy would
-- collide and reuse one run, which is the defect seen as "only the newest
-- attempt is visible". Adding the objective makes each objective its own run.
-- Historical runs keep their existing identity and stay NULL — honestly
-- unattributable rather than re-labelled.
--
-- Compatibility
-- -------------
-- * Additive and nullable; no row is rewritten.
-- * A run created before this migration has `objective_id = NULL` and can never
--   be presented as an objective's current execution.
-- * Code ships with a feature probe (`runs.has_run_objective_column`), so the
--   route works before and after.

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
  IF to_regclass('project1_ai.runs') IS NULL THEN
    RAISE EXCEPTION 'Execution ledger missing: reconcile before migrating';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'project1_ai' AND table_name = 'runs'
                AND column_name = 'objective_id') THEN
    RAISE EXCEPTION 'objective_id already present: reconcile version before migrating';
  END IF;
END $$;

ALTER TABLE project1_ai.runs ADD COLUMN objective_id text;

-- The objective dimension is only meaningful for QG: a BDJ run that *proposes*
-- objectives cannot itself belong to one. That rule is enforced in
-- `ensure_qg_run` (the only writer that sets the column) rather than by a CHECK,
-- because PostgreSQL forbids subqueries in CHECK constraints — a CHECK here
-- would look declarative and fail on apply. A BEFORE INSERT trigger could carry
-- it; that is deliberately left out of this proposal so the change stays a single
-- nullable column plus one index.

CREATE INDEX runs_objective_idx
  ON project1_ai.runs (assessment_id, objective_id)
  WHERE objective_id IS NOT NULL;

COMMIT;
