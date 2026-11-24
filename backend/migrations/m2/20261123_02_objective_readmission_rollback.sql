-- Rollback for 20261123_02_objective_readmission.sql.
--
-- Refuses to run while any re-admission row exists: dropping the columns would
-- destroy the supersession edges that make the current admission explainable.
-- Deleting those rows to satisfy the rollback would be rewriting governance
-- history, which is exactly what the migration exists to avoid.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required';
  END IF;
END
$guard$;

DO $refuse$
BEGIN
  IF EXISTS (SELECT 1 FROM public.m2_bdj_objective_admissions
             WHERE readmission_basis IS NOT NULL) THEN
    RAISE EXCEPTION 'Re-admission rows exist; rollback would erase supersession history';
  END IF;
END
$refuse$;

DROP INDEX IF EXISTS public.m2_bdj_objective_admissions_readmission_once;

ALTER TABLE public.m2_bdj_objective_admissions
    DROP CONSTRAINT IF EXISTS m2_bdj_objective_admissions_readmission_shape;
ALTER TABLE public.m2_bdj_objective_admissions
    DROP CONSTRAINT IF EXISTS m2_bdj_objective_admissions_version_positive;

ALTER TABLE public.m2_bdj_objective_admissions
    DROP COLUMN IF EXISTS readmission_basis;
ALTER TABLE public.m2_bdj_objective_admissions
    DROP COLUMN IF EXISTS supersedes_admission_id;
ALTER TABLE public.m2_bdj_objective_admissions
    DROP COLUMN IF EXISTS admission_version;

COMMIT;
