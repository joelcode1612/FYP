-- Rollback for 20261124_04_qg_authorization_purpose.sql
--
-- Restores the pre-DD-034 guard and removes the four added columns.
--
-- Destructive by nature: consent_version and consent_digest are the only record
-- of *which* grant authorised a row. Dropping them returns every row to
-- "purpose assumed", which is exactly the ambiguity the migration removed. Run
-- this only to abandon the change, never to "clean up" a live environment.
--
-- The purpose/scope values themselves are recoverable from the defaults, so
-- nothing is lost that the original schema could have expressed.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required';
  END IF;
  IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
    RAISE EXCEPTION 'Refusing to roll back on protected database %', current_database();
  END IF;
END
$guard$;

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
     OR NEW.expires_at <> OLD.expires_at THEN
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

ALTER TABLE public.m2_qg_authorizations
    DROP CONSTRAINT IF EXISTS m2_qg_authorizations_consent_pair_check,
    DROP CONSTRAINT IF EXISTS m2_qg_authorizations_consent_digest_check,
    DROP CONSTRAINT IF EXISTS m2_qg_authorizations_scope_check,
    DROP CONSTRAINT IF EXISTS m2_qg_authorizations_purpose_check;

ALTER TABLE public.m2_qg_authorizations
    DROP COLUMN IF EXISTS consent_digest,
    DROP COLUMN IF EXISTS consent_version,
    DROP COLUMN IF EXISTS scope,
    DROP COLUMN IF EXISTS purpose;

COMMIT;
