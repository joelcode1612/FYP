-- Rollback for 20261118_02_candidate_review_v2.sql.
--
-- Restores the two-value decision CHECK, drops context_hash and its two
-- constraints. Nothing is deleted: the table is append-only and this script
-- does not attempt an UPDATE or DELETE on it.
--
-- Because a REQUEST_REVISION row cannot exist under the restored two-value
-- CHECK, the rollback REFUSES to run while such a row is present. Losing the
-- record of a decision is worse than leaving the migration in place, so the
-- operator must decide deliberately rather than have history silently
-- truncated.
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

  IF current_database() = 'Dss' THEN
    RAISE EXCEPTION 'Refusing to roll back candidate review v2 on protected database %',
                    current_database();
  END IF;

  IF to_regclass('public.m2_candidate_owner_reviews') IS NULL THEN
    RAISE EXCEPTION 'public.m2_candidate_owner_reviews is missing; nothing to roll back';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public'
                    AND table_name = 'm2_candidate_owner_reviews'
                    AND column_name = 'context_hash') THEN
    RAISE EXCEPTION 'context_hash is absent; candidate review v2 is not applied';
  END IF;

  IF EXISTS (SELECT 1 FROM public.m2_candidate_owner_reviews
              WHERE decision = 'REQUEST_REVISION') THEN
    RAISE EXCEPTION 'REQUEST_REVISION rows exist; the two-value CHECK cannot be restored '
                    'without discarding history. Refusing.';
  END IF;
END
$guard$;

ALTER TABLE public.m2_candidate_owner_reviews
    DROP CONSTRAINT IF EXISTS m2_candidate_owner_reviews_revision_context;
ALTER TABLE public.m2_candidate_owner_reviews
    DROP CONSTRAINT IF EXISTS m2_candidate_owner_reviews_context_hash_format;
ALTER TABLE public.m2_candidate_owner_reviews
    DROP CONSTRAINT IF EXISTS m2_candidate_owner_reviews_decision_check;
ALTER TABLE public.m2_candidate_owner_reviews
    DROP COLUMN IF EXISTS context_hash;

ALTER TABLE public.m2_candidate_owner_reviews
    ADD CONSTRAINT m2_candidate_owner_reviews_decision_check
    CHECK (decision IN ('APPROVE_FOR_REVIEW', 'REJECT'));

DO $verify$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public'
                AND table_name = 'm2_candidate_owner_reviews'
                AND column_name = 'context_hash') THEN
    RAISE EXCEPTION 'context_hash still present after rollback';
  END IF;

  IF EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.m2_candidate_owner_reviews'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) LIKE '%REQUEST_REVISION%'
  ) THEN
    RAISE EXCEPTION 'a decision CHECK still admits REQUEST_REVISION after rollback';
  END IF;

  IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.m2_candidate_owner_reviews'::regclass
        AND conname = 'm2_candidate_owner_reviews_decision_check'
        AND pg_get_constraintdef(oid) LIKE '%APPROVE_FOR_REVIEW%'
  ) THEN
    RAISE EXCEPTION 'two-value decision CHECK was not restored';
  END IF;

  IF NOT EXISTS (
      SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.m2_candidate_owner_reviews'::regclass
        AND tgname = 'm2_owner_review_append_only'
        AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'append-only trigger m2_owner_review_append_only is missing after rollback';
  END IF;
END
$verify$;

COMMIT;
