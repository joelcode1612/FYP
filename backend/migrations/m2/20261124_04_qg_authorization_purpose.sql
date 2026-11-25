-- DD-034: bind a QG authorization to a purpose and a disclosure scope.
--
-- The defect this closes
-- ----------------------
-- public.m2_qg_authorizations binds the assessment, confirmation, revision,
-- source fingerprint, context, objective, admission, measurement, prompt and
-- expiry -- but not *what the owner authorised the attempt for*. The only
-- consent recorded on an assessment was granted to "derive research
-- objectives", and nothing in the QG path compared the two.
--
-- public.m2_qg_authorizations had no purpose column, and QgLiveRunner checked
-- ``payload['purpose'] == QG_PURPOSE`` against a dict the HTTP route built in
-- process. The check therefore compared a value the caller had just written.
--
-- What this adds
-- --------------
-- Four columns, all NOT NULL with a default except the two consent fields:
--
--   purpose          the authorised act. Defaults to the QG research-evaluation
--                    purpose because every existing row was issued for exactly
--                    that: qg_authorization.issue() had no other caller.
--   scope            the authorised disclosure scope, so a future QG variant
--                    (different packet, different data list) cannot silently
--                    reuse this row.
--   consent_version  the consent contract the grant was read from
--                    ('ai-processing-consent-qg/1'), NULL for legacy rows.
--   consent_digest   the digest of the consent block that authorised it, so a
--                    reader can prove *which* grant was relied on.
--
-- The guard trigger is replaced so the new columns join the immutable set. The
-- only permitted UPDATE remains consumption; a caller still cannot rewrite the
-- purpose of a row it already holds.
--
-- Why the defaults are honest rather than convenient
-- --------------------------------------------------
-- Every pre-existing row was created by qg_authorization.issue() for a fixed-
-- option QG candidate attempt, and that function had no other purpose or scope
-- argument. Recording the values it implicitly had is a backfill of fact, not a
-- grant: consent_version and consent_digest stay NULL, so a legacy row is
-- visibly distinguishable from one issued under the new contract.
--
-- Additive only: no existing column, constraint or row is removed or retyped.
-- Explicit operator execution only. Never run at application startup.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required '
                    '(project1.m2_bcb_migration_target must equal current_database(); '
                    'project1.m2_bcb_migration_receipt must be non-empty)';
  END IF;

  IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
    RAISE EXCEPTION 'Refusing to apply QG authorization purpose to protected database %',
                    current_database();
  END IF;

  IF to_regclass('public.m2_qg_authorizations') IS NULL THEN
    RAISE EXCEPTION 'public.m2_qg_authorizations is missing';
  END IF;
END
$guard$;

ALTER TABLE public.m2_qg_authorizations
    ADD COLUMN IF NOT EXISTS purpose varchar(64) NOT NULL
        DEFAULT 'SYNTHETIC_QG_RESEARCH_EVALUATION',
    ADD COLUMN IF NOT EXISTS scope varchar(64) NOT NULL
        DEFAULT 'QG_FIXED_OPTION_CANDIDATE',
    ADD COLUMN IF NOT EXISTS consent_version varchar(64) NULL,
    ADD COLUMN IF NOT EXISTS consent_digest char(64) NULL;

DO $constraints$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.m2_qg_authorizations'::regclass
                   AND conname = 'm2_qg_authorizations_purpose_check') THEN
    -- A closed vocabulary. A purpose outside it is a contract change, not a
    -- request parameter, so it must fail here rather than be carried as a
    -- free-text claim nobody validates.
    ALTER TABLE public.m2_qg_authorizations
      ADD CONSTRAINT m2_qg_authorizations_purpose_check
      CHECK (purpose IN ('SYNTHETIC_QG_RESEARCH_EVALUATION'));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.m2_qg_authorizations'::regclass
                   AND conname = 'm2_qg_authorizations_scope_check') THEN
    ALTER TABLE public.m2_qg_authorizations
      ADD CONSTRAINT m2_qg_authorizations_scope_check
      CHECK (scope IN ('QG_FIXED_OPTION_CANDIDATE'));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.m2_qg_authorizations'::regclass
                   AND conname = 'm2_qg_authorizations_consent_digest_check') THEN
    ALTER TABLE public.m2_qg_authorizations
      ADD CONSTRAINT m2_qg_authorizations_consent_digest_check
      CHECK (consent_digest IS NULL OR consent_digest ~ '^[0-9a-f]{64}$');
  END IF;

  -- Version and digest travel together: a digest with no contract version
  -- cannot be verified against the terms it claims to cover.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.m2_qg_authorizations'::regclass
                   AND conname = 'm2_qg_authorizations_consent_pair_check') THEN
    ALTER TABLE public.m2_qg_authorizations
      ADD CONSTRAINT m2_qg_authorizations_consent_pair_check
      CHECK ((consent_version IS NULL) = (consent_digest IS NULL));
  END IF;
END
$constraints$;

-- Replace the guard so the new columns are immutable too. CREATE OR REPLACE is
-- safe here: the trigger binding is unchanged and the function is not shared.
CREATE OR REPLACE FUNCTION public.m2_qg_authorization_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'QG authorizations cannot be deleted' USING ERRCODE = '55000';
  END IF;
  IF NEW.authorization_id <> OLD.authorization_id
     OR NEW.assessment_id <> OLD.assessment_id
     OR NEW.confirmation_id <> OLD.confirmation_id
     OR NEW.assessment_revision <> OLD.assessment_revision
     OR NEW.source_fingerprint <> OLD.source_fingerprint
     OR NEW.context_id <> OLD.context_id
     OR NEW.context_packet_hash <> OLD.context_packet_hash
     OR NEW.objective_id <> OLD.objective_id
     OR NEW.objective_admission_id <> OLD.objective_admission_id
     OR NEW.measurement_id <> OLD.measurement_id
     OR NEW.measurement_version <> OLD.measurement_version
     OR NEW.prompt_version <> OLD.prompt_version
     OR NEW.prompt_sha256 <> OLD.prompt_sha256
     OR NEW.issued_at <> OLD.issued_at
     OR NEW.expires_at <> OLD.expires_at
     -- Added by 20261124_04. Without these, a caller could keep a valid row and
     -- rewrite the purpose it was issued for, which is the defect this migration
     -- exists to close.
     OR NEW.purpose IS DISTINCT FROM OLD.purpose
     OR NEW.scope IS DISTINCT FROM OLD.scope
     OR NEW.consent_version IS DISTINCT FROM OLD.consent_version
     OR NEW.consent_digest IS DISTINCT FROM OLD.consent_digest THEN
    RAISE EXCEPTION 'QG authorization binding columns are immutable'
      USING ERRCODE = '55000';
  END IF;
  IF OLD.consumed_at IS NOT NULL THEN
    RAISE EXCEPTION 'QG authorization already consumed' USING ERRCODE = '55000';
  END IF;
  IF NEW.consumed_at IS NULL THEN
    RAISE EXCEPTION 'The only permitted update is consumption' USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END
$function$;

COMMENT ON COLUMN public.m2_qg_authorizations.purpose IS
  'The authorised act. Closed vocabulary; a new value is a contract change.';
COMMENT ON COLUMN public.m2_qg_authorizations.scope IS
  'The authorised disclosure scope, so a future QG variant cannot reuse this row.';
COMMENT ON COLUMN public.m2_qg_authorizations.consent_digest IS
  'Digest of the consent block relied on. NULL means the row predates the QG consent contract.';

COMMIT;
