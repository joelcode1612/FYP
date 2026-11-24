-- N04-C Decision 1, part 2: allow a versioned re-admission per proposal.
--
-- The constraint this replaces
-- ----------------------------
-- public.m2_bdj_objective_admissions carries ``uq_admission_once UNIQUE
-- (proposal_id)``: one admission per proposal, forever. That was correct while
-- an admission could only ever describe one business-context snapshot. It is
-- wrong now that a re-admission is the legitimate way to bind the same approved
-- objective to a rebuilt context -- the insert fails with a duplicate key, which
-- is what happened on the first attempt to record one.
--
-- What replaces it
-- ----------------
-- A partial unique index on (proposal_id) WHERE readmission_basis IS NULL. The
-- original invariant is preserved exactly for first admissions: a proposal can
-- still have only one. Re-admissions are exempt because they are the versioned
-- continuation, and the existing ``m2_bdj_objective_admissions_readmission_once``
-- index already limits them to one per (proposal, context).
--
-- Nothing is dropped from the table. The constraint is a rule about future
-- inserts, not data, so removing it cannot alter a row.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required';
  END IF;
  IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
    RAISE EXCEPTION 'Refusing to relax admission uniqueness on protected database %',
                    current_database();
  END IF;
END
$guard$;

-- Refuse if the data already violates the invariant this is meant to preserve.
DO $verify$
DECLARE offenders integer;
BEGIN
  SELECT count(*) INTO offenders FROM (
    SELECT proposal_id FROM public.m2_bdj_objective_admissions
     WHERE readmission_basis IS NULL
     GROUP BY proposal_id HAVING count(*) > 1) AS d;
  IF offenders > 0 THEN
    RAISE EXCEPTION 'First-admission uniqueness already violated for % proposal(s)', offenders;
  END IF;
END
$verify$;

ALTER TABLE public.m2_bdj_objective_admissions
    DROP CONSTRAINT IF EXISTS uq_admission_once;

CREATE UNIQUE INDEX IF NOT EXISTS m2_bdj_objective_admissions_first_once
    ON public.m2_bdj_objective_admissions (proposal_id)
    WHERE readmission_basis IS NULL;

COMMIT;
