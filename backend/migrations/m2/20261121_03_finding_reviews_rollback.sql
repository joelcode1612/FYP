-- Rollback for 20261121_03_finding_reviews.sql.
--
-- Drops the review table and its trigger function. The table is append-only, so
-- this script never deletes a row: dropping the table destroys every recorded
-- approval at once. That is why it REFUSES while any review row exists — losing
-- a record of an owner decision is worse than leaving the migration in place.
--
-- Explicit operator execution only.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
DECLARE rows integer;
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required';
  END IF;

  IF current_database() = 'Dss' THEN
    RAISE EXCEPTION 'Refusing to roll back finding reviews on protected database %',
                    current_database();
  END IF;

  IF to_regclass('public.m2_finding_reviews') IS NULL THEN
    RAISE EXCEPTION 'm2_finding_reviews absent: migration not applied, nothing to roll back';
  END IF;

  EXECUTE 'SELECT count(*) FROM public.m2_finding_reviews' INTO rows;
  IF rows > 0 THEN
    RAISE EXCEPTION
      'Refusing rollback: % recorded finding decision(s) would be destroyed. '
      'Decide deliberately before dropping the only record of an approval.', rows;
  END IF;
END
$guard$;

DROP TABLE public.m2_finding_reviews;
DROP FUNCTION public.m2_finding_review_reject_mutation();

COMMIT;
