-- Rollback for 20261123_01_qg_candidate_reviews.sql.
--
-- Drops only what that migration created: the policy, the index and the table.
-- No existing table, column or row is touched, so nothing outside this migration
-- can be lost.
--
-- Because the table holds owner judgements about generated questions, the
-- rollback REFUSES to run while it contains any row. Silently discarding a
-- reviewer's decision is worse than leaving the migration in place, so the
-- operator has to decide deliberately rather than discover afterwards that the
-- record is gone.
--
-- Explicit operator execution only.
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
    RAISE EXCEPTION 'Refusing to roll back on protected database %', current_database();
  END IF;

  IF to_regclass('public.m2_qg_candidate_reviews') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM public.m2_qg_candidate_reviews) THEN
      RAISE EXCEPTION 'Refusing to drop public.m2_qg_candidate_reviews while it holds % review rows',
                      (SELECT count(*) FROM public.m2_qg_candidate_reviews);
    END IF;
  END IF;
END
$guard$;

DROP POLICY IF EXISTS owner_scope ON public.m2_qg_candidate_reviews;
DROP INDEX IF EXISTS public.m2_qg_candidate_reviews_reviewer_idx;
DROP TABLE IF EXISTS public.m2_qg_candidate_reviews;

COMMIT;
