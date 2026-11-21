-- CP-05: third entrepreneur decision REQUEST_REVISION, with parent-version
-- linkage, a reason, an actor and a context hash.
--
-- Before this migration a candidate version could only reach
-- APPROVE_FOR_REVIEW or REJECT. There was no way to say "this question is
-- wrong, produce another one", so a rejected candidate was a dead end and a
-- regeneration produced a second concurrent "current" version.
--
-- What this migration changes on public.m2_candidate_owner_reviews:
--
--   1. decision CHECK admits REQUEST_REVISION as a third terminal value.
--      The old constraint is dropped by DISCOVERY (pg_constraint), not by a
--      guessed name: the constraint name differs between the DDL that created
--      it and any later rename, and a missed drop would silently leave a
--      2-value CHECK that rejects the new value.
--
--   2. context_hash varchar(64) NULL, format-checked as 64 lowercase hex.
--      The value is the confirmation snapshot digest the candidate was raised
--      against, so a decision records WHICH context it judged. NULL is
--      permitted only for the two pre-existing decision values, because rows
--      written before this migration cannot be rewritten (append-only).
--
--   3. REQUEST_REVISION requires a context hash. The CHECK is legal on an
--      append-only table: the trigger fires on UPDATE/DELETE only, so adding a
--      constraint that no existing row can violate does not rewrite history.
--
-- Parent-version linkage deliberately adds NO column. A revision is a new
-- public.m2_review_question_versions row whose `supersedes` names the version
-- under review; `supersedes` is already UNIQUE, so at most one revision child
-- can exist per candidate and two concurrent "current" versions are impossible.
-- A second column would be a second source of truth for the same edge.
--
-- No new table: PRIMARY KEY(candidate_id) plus append-only already guarantees
-- exactly one terminal decision per version.
--
-- Explicit operator execution only. Never run at application startup.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  -- Same guard shape as 20261115_01_candidate_owner_review.sql:2-8.
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required '
                    '(project1.m2_bcb_migration_target must equal current_database(); '
                    'project1.m2_bcb_migration_receipt must be non-empty)';
  END IF;

  -- Hard safety by name: the live database is refused even if a caller sets the
  -- guard setting to it by mistake.
  IF current_database() = 'Dss' THEN
    RAISE EXCEPTION 'Refusing to apply candidate review v2 to protected database %',
                    current_database();
  END IF;

  IF to_regclass('public.m2_candidate_owner_reviews') IS NULL THEN
    RAISE EXCEPTION 'public.m2_candidate_owner_reviews is missing; apply 20261115_01 first';
  END IF;
  IF to_regclass('public.m2_review_question_versions') IS NULL THEN
    RAISE EXCEPTION 'public.m2_review_question_versions is missing; parentage is unavailable';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public'
                AND table_name = 'm2_candidate_owner_reviews'
                AND column_name = 'context_hash') THEN
    RAISE EXCEPTION 'context_hash already present; candidate review v2 is already applied';
  END IF;
END
$guard$;

-- ---------------------------------------------------------------------------
-- 1. Discover and drop the existing decision CHECK.
--
-- The live name is m2_candidate_owner_reviews_decision_check, but the drop is
-- driven by the constraint DEFINITION so a renamed or regenerated constraint is
-- still found. Only CHECK constraints that actually mention a decision value
-- are touched; the rationale length CHECK is left alone.
-- ---------------------------------------------------------------------------
DO $drop_decision_check$
DECLARE
  found text;
  dropped int := 0;
BEGIN
  FOR found IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.m2_candidate_owner_reviews'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%APPROVE_FOR_REVIEW%'
  LOOP
    EXECUTE format('ALTER TABLE public.m2_candidate_owner_reviews DROP CONSTRAINT %I', found);
    RAISE NOTICE 'dropped decision CHECK constraint %', found;
    dropped := dropped + 1;
  END LOOP;

  IF dropped = 0 THEN
    RAISE EXCEPTION 'no decision CHECK constraint found on m2_candidate_owner_reviews';
  END IF;
END
$drop_decision_check$;

ALTER TABLE public.m2_candidate_owner_reviews
    ADD CONSTRAINT m2_candidate_owner_reviews_decision_check
    CHECK (decision IN ('APPROVE_FOR_REVIEW', 'REJECT', 'REQUEST_REVISION'));

-- ---------------------------------------------------------------------------
-- 2. Context hash. Nullable for rows written before this migration; format
--    checked for every row that does carry one.
-- ---------------------------------------------------------------------------
ALTER TABLE public.m2_candidate_owner_reviews
    ADD COLUMN context_hash varchar(64);

ALTER TABLE public.m2_candidate_owner_reviews
    ADD CONSTRAINT m2_candidate_owner_reviews_context_hash_format
    CHECK (context_hash IS NULL OR context_hash ~ '^[0-9a-f]{64}$');

-- A revision request without the context it judged is not a decision.
ALTER TABLE public.m2_candidate_owner_reviews
    ADD CONSTRAINT m2_candidate_owner_reviews_revision_context
    CHECK (decision <> 'REQUEST_REVISION' OR context_hash IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Prove the invariants inside the same transaction: a silent no-op must not be
-- mistaken for success.
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
  decision_def text;
  column_type  text;
  column_null  text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO decision_def
  FROM pg_constraint
  WHERE conrelid = 'public.m2_candidate_owner_reviews'::regclass
    AND conname = 'm2_candidate_owner_reviews_decision_check';

  IF decision_def IS NULL
     OR decision_def NOT LIKE '%APPROVE_FOR_REVIEW%'
     OR decision_def NOT LIKE '%REJECT%'
     OR decision_def NOT LIKE '%REQUEST_REVISION%' THEN
    RAISE EXCEPTION 'decision CHECK does not admit all three decisions: %', decision_def;
  END IF;

  -- No surviving constraint may still restrict the value set to two decisions.
  IF EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.m2_candidate_owner_reviews'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) LIKE '%APPROVE_FOR_REVIEW%'
        AND pg_get_constraintdef(oid) NOT LIKE '%REQUEST_REVISION%'
  ) THEN
    RAISE EXCEPTION 'a two-value decision CHECK survived the migration';
  END IF;

  SELECT data_type, is_nullable INTO column_type, column_null
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'm2_candidate_owner_reviews'
    AND column_name = 'context_hash';

  IF column_type IS DISTINCT FROM 'character varying' OR column_null IS DISTINCT FROM 'YES' THEN
    RAISE EXCEPTION 'context_hash is not a nullable varchar (%, nullable=%)',
                    column_type, column_null;
  END IF;

  IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.m2_candidate_owner_reviews'::regclass
        AND conname = 'm2_candidate_owner_reviews_context_hash_format'
        AND pg_get_constraintdef(oid) LIKE '%[0-9a-f]%'
  ) THEN
    RAISE EXCEPTION 'context_hash format CHECK is missing';
  END IF;

  IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.m2_candidate_owner_reviews'::regclass
        AND conname = 'm2_candidate_owner_reviews_revision_context'
  ) THEN
    RAISE EXCEPTION 'REQUEST_REVISION context-hash CHECK is missing';
  END IF;

  -- History must still be protected: adding columns must not have disturbed the
  -- append-only trigger.
  IF NOT EXISTS (
      SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.m2_candidate_owner_reviews'::regclass
        AND tgname = 'm2_owner_review_append_only'
        AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'append-only trigger m2_owner_review_append_only is missing';
  END IF;

  -- Parentage must remain expressible and single-child.
  IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.m2_review_question_versions'::regclass
        AND contype = 'u'
        AND pg_get_constraintdef(oid) LIKE '%supersedes%'
  ) THEN
    RAISE EXCEPTION 'm2_review_question_versions.supersedes is not UNIQUE; parentage would branch';
  END IF;
END
$verify$;

COMMIT;
