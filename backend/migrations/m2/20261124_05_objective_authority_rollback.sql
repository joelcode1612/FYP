-- Rollback for 20261124_05_objective_authority.sql.
--
-- Restores the exact pre-05 state:
--
--   * the guard function reverts to the 20261124_04 body (old columns compared
--     with <>, purpose/scope/consent_* compared with IS DISTINCT FROM, no
--     reference to the objective-authority columns)
--   * the eight CHECK constraints added by 05 are dropped
--   * the six columns added by 05 are dropped (their foreign keys go with them)
--   * objective_admission_id, measurement_id and measurement_version become
--     NOT NULL again on both tables
--
-- Fail-closed on data
-- -------------------
-- The NOT NULL restore is only possible when no row depends on the relaxation.
-- If any row was written under contract 2.1 (authority carried by
-- objective_decision_id, measurement not approved), restoring NOT NULL would
-- silently discard the only record of how that row was authorised -- or, worse,
-- force an operator to invent an admission id to satisfy the constraint. So the
-- rollback refuses instead of coercing, and names the offending rows. Deleting
-- or re-pointing those rows is an owner decision, not a migration side effect.
--
-- Order matters and is deliberate: the guard is restored before the columns are
-- dropped, so no window exists in which the trigger references a column that is
-- gone.
--
-- Destructive by nature (DROP COLUMN). Explicit operator execution only.
-- Never run at application startup.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
DECLARE
  tbl     text;
  n_2_1   bigint;
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required '
                    '(project1.m2_bcb_migration_target must equal current_database(); '
                    'project1.m2_bcb_migration_receipt must be non-empty)';
  END IF;

  IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
    RAISE EXCEPTION 'Refusing to roll back the objective-authority relationship on protected database %',
                    current_database();
  END IF;

  IF to_regclass('public.m2_qg_candidates') IS NULL
     OR to_regclass('public.m2_qg_authorizations') IS NULL THEN
    RAISE EXCEPTION 'm2_qg_candidates and m2_qg_authorizations are both required';
  END IF;

  -- Refuse to restore NOT NULL while rows rely on the relaxation.
  FOREACH tbl IN ARRAY ARRAY['m2_qg_candidates', 'm2_qg_authorizations'] LOOP
    EXECUTE format(
      'SELECT count(*) FROM public.%I '
      'WHERE objective_admission_id IS NULL '
      '   OR measurement_id IS NULL '
      '   OR measurement_version IS NULL', tbl)
      INTO n_2_1;
    IF n_2_1 > 0 THEN
      RAISE EXCEPTION
        'Cannot roll back: % row(s) in public.% depend on the 2.1 authority '
        'relaxation (objective_admission_id / measurement_id / measurement_version '
        'is NULL). Restoring NOT NULL would discard how those rows were '
        'authorised. Resolve them explicitly before rolling back.',
        n_2_1, tbl;
    END IF;
  END LOOP;
END
$guard$;

-- 1. Restore the 20261124_04 guard body. It no longer references the columns
--    that step 3 drops, so the trigger is valid at every point after this.
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

-- 2. Drop the two authority triggers and their function. Dropped before the
--    columns, because the function body reads objective_decision_id.
DROP TRIGGER IF EXISTS m2_qg_candidates_authority_guard ON public.m2_qg_candidates;
DROP TRIGGER IF EXISTS m2_qg_authorizations_authority_guard ON public.m2_qg_authorizations;
DROP FUNCTION IF EXISTS public.m2_qg_objective_authority_guard();

-- 3. Drop the eight constraints added by 05.
DO $constraints$
DECLARE
  tbl  text;
  cons text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['m2_qg_candidates', 'm2_qg_authorizations'] LOOP
    FOREACH cons IN ARRAY ARRAY[
      tbl || '_authority_present',
      tbl || '_authority_declared',
      tbl || '_objective_kind_check',
      tbl || '_measurement_basis_check'
    ] LOOP
      EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT IF EXISTS %I', tbl, cons);
    END LOOP;
  END LOOP;
END
$constraints$;

-- 4. Drop the six columns added by 05 (and the two composite foreign keys with
--    them), then the unique constraint those foreign keys referenced.
ALTER TABLE public.m2_qg_candidates
    DROP COLUMN IF EXISTS objective_decision_id,
    DROP COLUMN IF EXISTS objective_kind,
    DROP COLUMN IF EXISTS measurement_basis;

ALTER TABLE public.m2_qg_authorizations
    DROP COLUMN IF EXISTS objective_decision_id,
    DROP COLUMN IF EXISTS objective_kind,
    DROP COLUMN IF EXISTS measurement_basis;

ALTER TABLE public.m2_bdj_objective_decisions
    DROP CONSTRAINT IF EXISTS uq_bdj_decision_confirmation;

-- 5. Restore the legacy NOT NULLs. Reached only when the guard above proved no
--    row needs the relaxation.
ALTER TABLE public.m2_qg_candidates
    ALTER COLUMN objective_admission_id SET NOT NULL,
    ALTER COLUMN measurement_id SET NOT NULL,
    ALTER COLUMN measurement_version SET NOT NULL;

ALTER TABLE public.m2_qg_authorizations
    ALTER COLUMN objective_admission_id SET NOT NULL,
    ALTER COLUMN measurement_id SET NOT NULL,
    ALTER COLUMN measurement_version SET NOT NULL;

COMMIT;
