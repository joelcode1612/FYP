-- Rollback for 20261123_03_admission_supersession.sql.
--
-- Restores the original UNIQUE (proposal_id) rule. Refuses while any
-- re-admission row exists: the constraint cannot be satisfied by those rows, and
-- deleting them to satisfy it would erase supersession history.
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
    RAISE EXCEPTION 'Re-admission rows exist; restoring UNIQUE (proposal_id) would fail or lose history';
  END IF;
END
$refuse$;

DROP INDEX IF EXISTS public.m2_bdj_objective_admissions_first_once;

DO $constraint$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_admission_once') THEN
    ALTER TABLE public.m2_bdj_objective_admissions
      ADD CONSTRAINT uq_admission_once UNIQUE (proposal_id);
  END IF;
END
$constraint$;

COMMIT;
