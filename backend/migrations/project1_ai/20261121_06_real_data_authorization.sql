-- Real-data BDJ authorisation: the production counterpart of the synthetic trial
-- authority. Without a row here, the disclosure guard refuses real worksheets.
--
-- The guard this answers (disclosure.py:217):
--     if data_class != 'SYNTHETIC_NONHUMAN':
--         raise WorkflowHeld('DISCLOSURE_REAL_DATA_NOT_AUTHORIZED')
--
-- What a row binds: the exact confirmed revision (fingerprint), the exact adopted
-- ruleset (hash), and the exact prompt. So an authorisation cannot be reused for
-- a different worksheet, a different ruleset, or a re-worded prompt.
--
-- NOT wired yet. Creating this table changes no behaviour: the guard still fires
-- until a disclosure class reads it. That is deliberate — the moment it is wired,
-- real entrepreneur data can flow through BDJ, and that should follow a decision
-- about who may sign, expiry and single-use, not a migration.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required';
  END IF;
  IF to_regclass('project1_ai.bdj_results') IS NULL THEN
    RAISE EXCEPTION 'project1_ai.bdj_results missing; apply result persistence first';
  END IF;
  IF to_regclass('project1_ai.bdj_real_data_authorizations') IS NOT NULL THEN
    RAISE EXCEPTION 'bdj_real_data_authorizations exists: reconcile before migrating';
  END IF;
END
$guard$;

CREATE TABLE project1_ai.bdj_real_data_authorizations (
  id                  uuid PRIMARY KEY,
  assessment_id       uuid NOT NULL,
  assessment_revision integer NOT NULL CHECK (assessment_revision >= 0),
  -- Binds the authorisation to ONE confirmed revision, not to the assessment.
  source_fingerprint  text NOT NULL CHECK (source_fingerprint ~ '^[a-f0-9]{64}$'),
  ruleset_version     text NOT NULL,
  rules_sha256        text NOT NULL CHECK (rules_sha256 ~ '^[a-f0-9]{64}$'),
  prompt_sha256       text NOT NULL CHECK (prompt_sha256 ~ '^[a-f0-9]{64}$'),
  authorized_by       uuid NOT NULL,
  authorized_at       timestamptz NOT NULL DEFAULT now(),
  -- NULL is NOT permitted: standing consent to process real data forever is not
  -- a decision anyone can make on someone else's behalf.
  expires_at          timestamptz NOT NULL,
  -- Single-use: set when a run consumes it, in the same transaction as the run.
  consumed_at         timestamptz,
  consumed_run_id     uuid,
  receipt             text NOT NULL CHECK (length(btrim(receipt)) > 0),
  CONSTRAINT ck_bdj_real_auth_window CHECK (expires_at > authorized_at)
);

COMMENT ON TABLE project1_ai.bdj_real_data_authorizations IS
  'Explicit authorisation for BDJ to process ONE real (non-synthetic) confirmed '
  'worksheet. Bound to source fingerprint, ruleset hash and prompt hash. Expires; '
  'single-use. The receipt records who signed and why.';

-- At most one unconsumed authorisation per (revision, ruleset, prompt): a second
-- signature for the same run is a duplicate, not a second opinion.
CREATE UNIQUE INDEX uq_bdj_real_auth_live
  ON project1_ai.bdj_real_data_authorizations
     (assessment_id, assessment_revision, source_fingerprint, ruleset_version, rules_sha256, prompt_sha256)
  WHERE consumed_at IS NULL;

CREATE INDEX ix_bdj_real_auth_lookup
  ON project1_ai.bdj_real_data_authorizations (assessment_id, assessment_revision, expires_at);

-- Append-only for the binding columns: an authorisation may only be consumed,
-- never re-pointed at a different worksheet or ruleset.
CREATE FUNCTION project1_ai.bdj_real_auth_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.assessment_id IS DISTINCT FROM OLD.assessment_id
     OR NEW.assessment_revision IS DISTINCT FROM OLD.assessment_revision
     OR NEW.source_fingerprint IS DISTINCT FROM OLD.source_fingerprint
     OR NEW.ruleset_version IS DISTINCT FROM OLD.ruleset_version
     OR NEW.rules_sha256 IS DISTINCT FROM OLD.rules_sha256
     OR NEW.prompt_sha256 IS DISTINCT FROM OLD.prompt_sha256
     OR NEW.expires_at IS DISTINCT FROM OLD.expires_at THEN
    RAISE EXCEPTION 'Authorisation binding is immutable; issue a new authorisation'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER bdj_real_auth_binding_immutable
  BEFORE UPDATE ON project1_ai.bdj_real_data_authorizations
  FOR EACH ROW EXECUTE FUNCTION project1_ai.bdj_real_auth_guard();

COMMIT;
