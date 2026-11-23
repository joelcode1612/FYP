-- REVIEW CANDIDATE, EXPLICIT OPERATOR EXECUTION ONLY. Never run at startup.
-- Requires a reviewed target and receipt, e.g.
--   SET project1.migration_target='project1_workflow_tests';
--   SET project1.migration_receipt='<actual reviewed change record>';
--
-- GATE 3.5: register EXPLANATION as a fourth execution stage.
--
-- The candidate ledger was created with CHECK (stage IN ('BDJ','QJ','QG')), so an
-- EXPLANATION attempt is refused by the database even after the application
-- allows it. This migration widens exactly that constraint and nothing else.
--
-- What it does NOT do:
--   * it does not re-open QJ — QJ stays in the constraint for history, but the
--     application's _ALLOWED_STAGES still excludes it from new reservations;
--   * it does not grant any disclosure authority. A stage existing in a ledger is
--     not permission to call a provider;
--   * it does not touch any existing row. The constraint is replaced in place and
--     every prior attempt keeps its stage value.
--
-- The constraint is located by its definition rather than by name, because the
-- original CHECK was declared inline and PostgreSQL generated its name. Matching
-- on the name alone would silently skip a database whose constraint was renamed.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '60s';
DO $$
DECLARE
  target_db text := current_database();
  has_stage_check boolean;
BEGIN
  IF target_db NOT IN ('Dss', 'project1_workflow_tests', 'project1_disposable_app',
                       'cp08_qg_retry_tests')
     OR current_setting('project1.migration_target', true) IS DISTINCT FROM target_db
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
  IF to_regclass('project1_ai.attempts') IS NULL THEN
    RAISE EXCEPTION 'project1_ai.attempts missing: apply 20261111_01 first';
  END IF;
  -- Already applied? Then this is a re-run, not a fresh migration.
  IF EXISTS (
    SELECT 1 FROM project1_ai.schema_versions
    WHERE version = '20261122_01_explanation_stage'
  ) THEN
    RAISE EXCEPTION '20261122_01_explanation_stage already applied; reconcile before re-running';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'project1_ai.attempts'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%stage%IN%BDJ%'
  ) INTO has_stage_check;
  IF NOT has_stage_check THEN
    RAISE EXCEPTION 'attempts stage CHECK not found in the expected shape: reconcile version before migrating';
  END IF;
END $$;

-- Drop by definition, not by name: the original CHECK was inline and unnamed in
-- the migration source, so its generated name is not guaranteed.
DO $$
DECLARE
  c record;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'project1_ai.attempts'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%stage%IN%BDJ%'
  LOOP
    EXECUTE format('ALTER TABLE project1_ai.attempts DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

ALTER TABLE project1_ai.attempts
  ADD CONSTRAINT attempts_stage_check
  CHECK (stage IN ('BDJ', 'QJ', 'QG', 'EXPLANATION'));

INSERT INTO project1_ai.schema_versions(version, receipt)
VALUES ('20261122_01_explanation_stage', current_setting('project1.migration_receipt'));

COMMIT;
