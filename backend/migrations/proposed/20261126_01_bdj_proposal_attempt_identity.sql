-- PROPOSAL ONLY — NOT APPLIED. Requires explicit owner approval.
--
-- CP-FINAL-02: attempt-bound attribution for BDJ objective proposals.
--
-- Why this is needed
-- ------------------
-- `public.m2_bdj_objective_proposals` cannot be joined to the execution that
-- produced it. Measured on project1_pg18_migrated_tests @ 5544 (2026-11-26):
--
--   * the table has 25 columns and none of them is a run or attempt identifier;
--   * `evaluation_id` is generated with `uuid4()` in
--     `api/v1/project1_objective_proposals.py`, so it is a per-evaluation
--     random id, not the ledger run id;
--   * `SELECT count(*) FROM m2_bdj_objective_proposals p
--       JOIN project1_ai.runs r ON r.id = p.evaluation_id` returns 0 of 20 rows.
--
-- Consequence today: the status route can only count proposals by
-- `assessment_id`. A proposal set written by an earlier attempt therefore makes
-- a brand-new attempt look "Persisted". The application fails closed for this
-- case (`runs.refine_with_domain(..., attributable=False)` returns
-- `RETURNED / PERSISTENCE_UNATTRIBUTABLE`), which is correct but permanent
-- until the identity exists in the row.
--
-- What this changes
-- -----------------
-- Two nullable columns, one generated discriminator, and four foreign keys.
-- Nothing is back-filled: the 20 existing rows keep NULL and remain honestly
-- unattributable. NULL means "written before this identity existed", never
-- "assume the current run".
--
-- Why a single FK to `attempts` is not enough
-- -------------------------------------------
-- `FOREIGN KEY (run_id, attempt_no) REFERENCES attempts` proves only that
-- *some* attempt exists with those numbers. It would happily bind a BDJ
-- proposal to a QG attempt of the same run, to an attempt belonging to another
-- owner, or to a run for a different assessment or confirmation revision.
-- The binding below therefore pins every dimension the owner cares about:
--
--   * attempt identity + purpose : (run_id, attempt_no, attempt_stage='BDJ')
--   * owner                      : (run_id, owner_user_id) -> runs
--   * assessment                 : (run_id, assessment_id) -> runs
--   * confirmation revision      : (run_id, confirmation_revision)
--                                    -> runs(id, assessment_revision)
--   * source context             : trigger, because `source_fingerprint` here is
--                                  `character` and on `runs` it is `text`, and
--                                  PostgreSQL cannot build an FK across those
--                                  types. The trigger is the honest alternative
--                                  to either skipping the check or retyping a
--                                  governed column.
--
-- `attempt_stage` is a generated constant. It exists so the attempt FK can
-- include the discriminator: a stored generated column is the declarative way
-- to say "the referenced attempt must be a BDJ attempt" without a second
-- trigger.
--
-- Why nullable rather than NOT NULL
-- ---------------------------------
-- A NOT NULL constraint would require back-filling, and the only available
-- back-fill is a guess from timestamps or row order. The brief forbids
-- fabricating historical execution relationships, and a guessed run_id is worse
-- than an absent one: it would make a historical row look attributable.
--
-- Compatibility
-- -------------
-- * Additive for the proposals table: no existing column changes type or
--   meaning; no row is rewritten.
-- * `project1_ai.runs` gains two UNIQUE constraints (id, assessment_id) and
--   (id, assessment_revision). These add indexes only; every existing row
--   already satisfies them because `id` is the primary key.
-- * `project1_ai.attempts` gains a UNIQUE index on (run_id, attempt_no, stage).
--   It is implied by the primary key on (run_id, attempt_no), so it cannot fail
--   on existing data.
-- * Old readers ignore the new columns; the new reader treats NULL as
--   unattributable.
-- * The write path must only start populating them *after* this is applied, so
--   code and schema ship together (see the paired code change below).
--
-- Paired code change (NOT applied, same approval)
-- -----------------------------------------------
--   1. `project1/objective_adapter.py::persist(...)` gains `run_id=None,
--      attempt_no=None` and includes both in the INSERT column list.
--   2. `api/v1/project1_objective_proposals.py::evaluate_objective_proposals`
--      passes the run id and attempt number it already reports in
--      `_execution_block` into `persist`.
--   3. `ai_execution_status_live.py`: `ATTRIBUTABLE['BDJ']` becomes True and the
--      BDJ count is narrowed by `run_id`/`attempt_no`, exactly as QG already is.
--
-- Rollback
-- --------
-- See the sibling `_rollback.sql`. Dropping the columns loses no governed
-- content: they are provenance, and the ledger row they point at is untouched.
--
-- Target guard
-- ------------
-- Follows the existing migration convention: an explicit database identity and
-- review receipt must be set, and the script refuses anything else.

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
  IF to_regclass('public.m2_bdj_objective_proposals') IS NULL
     OR to_regclass('project1_ai.attempts') IS NULL
     OR to_regclass('project1_ai.runs') IS NULL THEN
    RAISE EXCEPTION 'Objective proposals or execution ledger missing: reconcile before migrating';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public'
                AND table_name = 'm2_bdj_objective_proposals'
                AND column_name = 'run_id') THEN
    RAISE EXCEPTION 'run_id already present: reconcile version before migrating';
  END IF;
  -- The binding is only as strong as the referenced uniqueness. Refuse to build
  -- a weaker one silently.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'project1_ai.runs'::regclass
                    AND contype = 'u'
                    AND pg_get_constraintdef(oid) = 'UNIQUE (id, owner_user_id)') THEN
    RAISE EXCEPTION 'runs(id, owner_user_id) uniqueness missing: owner binding impossible';
  END IF;
END $$;

-- 1. Referenced uniqueness the foreign keys require. `id` is already unique, so
--    these can never fail on existing rows.
ALTER TABLE project1_ai.runs
  ADD CONSTRAINT runs_id_assessment_id_key UNIQUE (id, assessment_id),
  ADD CONSTRAINT runs_id_assessment_revision_key UNIQUE (id, assessment_revision);

-- Implied by attempts_pkey (run_id, attempt_no); present so the attempt FK can
-- carry the stage discriminator.
CREATE UNIQUE INDEX attempts_run_attempt_stage_key
  ON project1_ai.attempts (run_id, attempt_no, stage);

-- 2. The identity itself.
ALTER TABLE public.m2_bdj_objective_proposals
  ADD COLUMN run_id uuid,
  ADD COLUMN attempt_no integer,
  ADD COLUMN attempt_stage text GENERATED ALWAYS AS ('BDJ'::text) STORED;

-- 3. The binding. Every clause below rejects a real defect, not a hypothetical.
ALTER TABLE public.m2_bdj_objective_proposals
  ADD CONSTRAINT m2_bdj_objective_proposals_attempt_fkey
  FOREIGN KEY (run_id, attempt_no, attempt_stage)
  REFERENCES project1_ai.attempts (run_id, attempt_no, stage)
  ON DELETE RESTRICT,
  ADD CONSTRAINT m2_bdj_objective_proposals_owner_fkey
  FOREIGN KEY (run_id, owner_user_id)
  REFERENCES project1_ai.runs (id, owner_user_id)
  ON DELETE RESTRICT,
  ADD CONSTRAINT m2_bdj_objective_proposals_assessment_fkey
  FOREIGN KEY (run_id, assessment_id)
  REFERENCES project1_ai.runs (id, assessment_id)
  ON DELETE RESTRICT,
  ADD CONSTRAINT m2_bdj_objective_proposals_revision_fkey
  FOREIGN KEY (run_id, confirmation_revision)
  REFERENCES project1_ai.runs (id, assessment_revision)
  ON DELETE RESTRICT;

-- Half an identity is not an identity.
ALTER TABLE public.m2_bdj_objective_proposals
  ADD CONSTRAINT m2_bdj_objective_proposals_attempt_pair_chk
  CHECK ((run_id IS NULL) = (attempt_no IS NULL));

-- 4. Source context. An FK cannot span `character` (here) and `text` (on runs),
--    so the same assertion is made by trigger. `btrim` because the local column
--    is blank-padded.
CREATE FUNCTION public.m2_bdj_proposal_source_binding() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  run_source text;
BEGIN
  IF NEW.run_id IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT source_fingerprint INTO run_source
    FROM project1_ai.runs WHERE id = NEW.run_id;
  IF run_source IS NULL THEN
    -- The run FK will refuse this row; nothing to compare against here.
    RETURN NEW;
  END IF;
  IF btrim(NEW.source_fingerprint) <> run_source THEN
    RAISE EXCEPTION 'BDJ_PROPOSAL_SOURCE_MISMATCH'
      USING HINT = 'A proposal must be written against the source its run recorded.';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER m2_bdj_proposal_source_binding_trg
  BEFORE INSERT OR UPDATE OF run_id, source_fingerprint
  ON public.m2_bdj_objective_proposals
  FOR EACH ROW EXECUTE FUNCTION public.m2_bdj_proposal_source_binding();

-- 5. Narrow the read the status route performs, so the attempt lookup is indexed
--    rather than a scan of the assessment's whole proposal history.
CREATE INDEX m2_bdj_objective_proposals_attempt_idx
  ON public.m2_bdj_objective_proposals (assessment_id, run_id, attempt_no)
  WHERE run_id IS NOT NULL;

COMMIT;
