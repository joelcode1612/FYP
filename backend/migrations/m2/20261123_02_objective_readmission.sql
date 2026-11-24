-- N04-C Decision 1: versioned objective re-admission against the current BCB.
--
-- The problem
-- -----------
-- An objective was admitted on 2026-11-22 against business-context packet
-- 26f243be. The BCB was rebuilt on 2026-11-23 (packet d61118e8) after the owner
-- confirmed the uncertainty the objective exists to measure. The old snapshot is
-- now refused by the application itself with BCB_CONTEXT_SOURCE_CHANGED, and no
-- admission cites the current one. Direct-QG therefore has an admitted objective
-- bound to a superseded source and a current source bound to no admission.
--
-- What this adds, and what it refuses to do
-- -----------------------------------------
-- Re-admission is a NEW ROW over the SAME approved proposal, carrying the
-- current context hash and an explicit link to the admission it supersedes.
-- Nothing is overwritten: the historical admission keeps its context hash, its
-- created_at and its proposal_hash, so an auditor can still see exactly what was
-- approved when. No proposal is authored here -- a re-admission without an
-- already-approved proposal is refused by the service, not manufactured.
--
-- Why the version column is explicit
-- ----------------------------------
-- "Which admission is authoritative?" must be answerable without relying on
-- created_at ordering alone. admission_version is the ordinal within a
-- supersession chain, and supersedes_admission_id is the edge. The most recent
-- row remains the one QG eligibility selects, so no existing reader changes.
--
-- Additive only: three columns, one partial unique index, one check constraint.
-- No existing column, constraint or row is modified.
--
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
    RAISE EXCEPTION 'Refusing to apply objective re-admission to protected database %',
                    current_database();
  END IF;

  IF to_regclass('public.m2_bdj_objective_admissions') IS NULL THEN
    RAISE EXCEPTION 'public.m2_bdj_objective_admissions is missing';
  END IF;
END
$guard$;

ALTER TABLE public.m2_bdj_objective_admissions
    ADD COLUMN IF NOT EXISTS admission_version integer NOT NULL DEFAULT 1;

ALTER TABLE public.m2_bdj_objective_admissions
    ADD COLUMN IF NOT EXISTS supersedes_admission_id uuid NULL
        REFERENCES public.m2_bdj_objective_admissions (admission_id)
        ON DELETE RESTRICT;

--: Why this admission exists. NULL for every historical row, which is what makes
--: the partial unique index below safe to add to a populated table.
ALTER TABLE public.m2_bdj_objective_admissions
    ADD COLUMN IF NOT EXISTS readmission_basis text NULL;

DO $constraints$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'm2_bdj_objective_admissions_version_positive') THEN
    ALTER TABLE public.m2_bdj_objective_admissions
      ADD CONSTRAINT m2_bdj_objective_admissions_version_positive
      CHECK (admission_version >= 1);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'm2_bdj_objective_admissions_readmission_shape') THEN
    -- A re-admission must name what it supersedes; a first admission must not.
    ALTER TABLE public.m2_bdj_objective_admissions
      ADD CONSTRAINT m2_bdj_objective_admissions_readmission_shape
      CHECK ((readmission_basis IS NULL AND supersedes_admission_id IS NULL
              AND admission_version = 1)
             OR (readmission_basis IS NOT NULL AND supersedes_admission_id IS NOT NULL
                 AND admission_version > 1));
  END IF;
END
$constraints$;

-- One re-admission per proposal per context. A repeated owner action is
-- idempotent at the service layer; this index makes it impossible to accumulate
-- duplicate rows if the service is bypassed.
CREATE UNIQUE INDEX IF NOT EXISTS m2_bdj_objective_admissions_readmission_once
    ON public.m2_bdj_objective_admissions (proposal_id, context_packet_hash)
    WHERE readmission_basis IS NOT NULL;

COMMIT;
