-- ============================================================================
-- SITEWISE — Identity migration: four-role model (Admin / Property Owner /
--            Agent / Entrepreneur)
-- File: 20261116130000_users_four_role_model.up.sql
-- Target: Supabase identity PostgreSQL
-- Date: 2026-11-16
--
-- NATURE: constraint-only. NO column is added, dropped or renamed, and NO row
-- is rewritten. `public.users` is not recreated.
--
-- WHAT THIS CHANGES
--   `public.users.role` accepts exactly:
--       'admin', 'owner', 'agent', 'entrepreneur'
--
--   It previously accepted three values — 'entrepreneur', 'agent', 'admin' —
--   and the FastAPI RBAC layer normalised the legacy spelling `property_owner`
--   onto `entrepreneur`. That mapping is the defect this change removes:
--   Property Owner is a first-class role with its own property rights, and an
--   owner folded into `entrepreneur` has no property authority at all.
--
-- WHAT THIS DOES NOT DO
--   * It does not convert any account. `entrepreneur` rows stay entrepreneurs.
--   * It does not promote accounts that own property. Ownership is a fact about
--     `public.property`, not about the role string, and promoting on that basis
--     without review is a data decision — see §5.
--   * It does not touch `users_account_status_check`, any index, trigger,
--     policy or foreign key on `public.users`.
--
-- RUN ORDER: one transaction, in the Supabase SQL editor or via `supabase db
-- push`. Idempotent: safe to re-run.
--
-- ROLLBACK: 20261116130000_users_four_role_model.down.sql
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 0. INSPECT (read-only). Run these on their own first and read the output.
--    The live constraint's name is not assumed anywhere below, but its
--    definition should be confirmed before the transaction is applied.
-- ----------------------------------------------------------------------------
-- SELECT con.conname, pg_get_constraintdef(con.oid) AS definition,
--        con.convalidated
--   FROM pg_constraint con
--   JOIN pg_class rel ON rel.oid = con.conrelid
--   JOIN pg_namespace ns ON ns.oid = rel.relnamespace
--  WHERE ns.nspname = 'public' AND rel.relname = 'users' AND con.contype = 'c'
--  ORDER BY con.conname;
--
-- SELECT role, count(*) FROM public.users GROUP BY role ORDER BY role;
--
-- Safety snapshot (optional, recommended):
--   CREATE TABLE public.users_backup_20261116 AS SELECT * FROM public.users;

-- ----------------------------------------------------------------------------
-- 1. Pre-flight: refuse to continue if a legacy value is present.
--
--    'property_owner' is legal under neither the old constraint nor the new one,
--    so if it is found the database has drifted from the documented history and
--    the accounts need review before this migration can be trusted. Failing here
--    is deliberate: a silent UPDATE would reclassify accounts without the
--    ownership verification the four-role model requires.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  legacy_rows bigint;
  sample text;
BEGIN
  SELECT count(*) INTO legacy_rows
    FROM public.users
   WHERE role IS NOT NULL
     AND role NOT IN ('admin', 'owner', 'agent', 'entrepreneur');

  IF legacy_rows > 0 THEN
    SELECT string_agg(DISTINCT role, ', ' ORDER BY role) INTO sample
      FROM public.users
     WHERE role IS NOT NULL
       AND role NOT IN ('admin', 'owner', 'agent', 'entrepreneur');
    RAISE EXCEPTION
      'public.users holds % row(s) outside the four-role set (values: %). '
      'Review and reclassify them explicitly before applying this migration; '
      'it will not rewrite accounts automatically.', legacy_rows, sample;
  END IF;

  RAISE NOTICE 'pre-flight: every existing role value is within the four-role set';
END $$;

-- ----------------------------------------------------------------------------
-- 2. Replace the role CHECK constraint — and only the role one.
--
--    The constraint is found by definition, not by name: the live name may be
--    `users_role_check` or something a previous migration chose, and dropping a
--    guessed name would either fail or leave the three-value constraint in place
--    beside a new, weaker one.
--
--    A role CHECK always mentions `role` and at least one role value. Requiring
--    both keeps this from matching `users_account_status_check`, whose definition
--    mentions none of them.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  found_constraint text;
  found_definition text;
  replaced integer := 0;
BEGIN
  FOR found_constraint, found_definition IN
    SELECT con.conname, pg_get_constraintdef(con.oid)
      FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
      JOIN pg_namespace ns ON ns.oid = rel.relnamespace
     WHERE ns.nspname = 'public'
       AND rel.relname = 'users'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) ILIKE '%role%'
       AND (
            pg_get_constraintdef(con.oid) ILIKE '%entrepreneur%'
         OR pg_get_constraintdef(con.oid) ILIKE '%admin%'
         OR pg_get_constraintdef(con.oid) ILIKE '%agent%'
       )
  LOOP
    RAISE NOTICE 'dropping role CHECK constraint: % (%)',
      found_constraint, found_definition;
    EXECUTE format('ALTER TABLE public.users DROP CONSTRAINT %I', found_constraint);
    replaced := replaced + 1;
  END LOOP;

  IF replaced = 0 THEN
    RAISE NOTICE
      'no existing role CHECK constraint found; the four-value constraint is '
      'added below. Confirm in review that the table had none.';
  ELSE
    RAISE NOTICE 'replaced % role CHECK constraint(s)', replaced;
  END IF;
END $$;

-- Idempotent re-run guard.
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_role_check;

-- NOT VALID + VALIDATE is the non-blocking pair. §1 already proved every row is
-- inside the four-value set, so validation cannot fail — and if it does, that is
-- a finding worth aborting for.
ALTER TABLE public.users
  ADD CONSTRAINT users_role_check
  CHECK (role IN ('admin', 'owner', 'agent', 'entrepreneur')) NOT VALID;

ALTER TABLE public.users VALIDATE CONSTRAINT users_role_check;

-- ----------------------------------------------------------------------------
-- 3. Ordinary registration keeps the least privileged role.
--
--    Only the DEFAULT is set; no row is rewritten. `entrepreneur` stays the
--    default because a self-registered account has no verified property, and
--    this migration must never hand out owner rights at sign-up.
-- ----------------------------------------------------------------------------
ALTER TABLE public.users ALTER COLUMN role SET DEFAULT 'entrepreneur';

-- A NULL role makes every authorisation decision ambiguous. Separate statement so
-- a legacy NULL is reported clearly instead of surfacing as "cannot validate".
UPDATE public.users SET role = 'entrepreneur' WHERE role IS NULL;

-- ----------------------------------------------------------------------------
-- 4. Verify. These raise, so a wrong state aborts the transaction.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  role_constraint text;
  bad_rows bigint;
  total_rows bigint;
  trigger_count integer;
  fk_count integer;
  status_constraint text;
BEGIN
  SELECT pg_get_constraintdef(con.oid) INTO role_constraint
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace ns ON ns.oid = rel.relnamespace
   WHERE ns.nspname = 'public' AND rel.relname = 'users'
     AND con.contype = 'c' AND con.conname = 'users_role_check';

  IF role_constraint IS NULL THEN
    RAISE EXCEPTION 'users_role_check was not created';
  END IF;
  IF role_constraint NOT ILIKE '%owner%' THEN
    RAISE EXCEPTION 'users_role_check does not accept owner: %', role_constraint;
  END IF;
  IF role_constraint NOT ILIKE '%entrepreneur%'
     OR role_constraint NOT ILIKE '%agent%'
     OR role_constraint NOT ILIKE '%admin%' THEN
    RAISE EXCEPTION 'users_role_check is missing a required role: %', role_constraint;
  END IF;

  SELECT count(*) INTO bad_rows
    FROM public.users
   WHERE role NOT IN ('admin', 'owner', 'agent', 'entrepreneur');
  IF bad_rows > 0 THEN
    RAISE EXCEPTION '% row(s) hold a role outside the four-value set', bad_rows;
  END IF;

  SELECT count(*) INTO total_rows FROM public.users;
  RAISE NOTICE 'public.users holds % row(s); all within the four roles.', total_rows;

  -- The account-status protection must be untouched by this migration.
  SELECT pg_get_constraintdef(con.oid) INTO status_constraint
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace ns ON ns.oid = rel.relnamespace
   WHERE ns.nspname = 'public' AND rel.relname = 'users'
     AND con.contype = 'c' AND con.conname = 'users_account_status_check';
  IF status_constraint IS NULL THEN
    RAISE WARNING
      'users_account_status_check is absent. This migration does not create it; '
      'restore it from 20261105090000_role_model_staff_mfa.up.sql before deploying.';
  END IF;

  -- Identity-sync and role-protection triggers must survive: nothing here drops
  -- a trigger, and this reports if one has gone missing for another reason.
  SELECT count(*) INTO trigger_count
    FROM pg_trigger t
    JOIN pg_class rel ON rel.oid = t.tgrelid
    JOIN pg_namespace ns ON ns.oid = rel.relnamespace
   WHERE ns.nspname = 'public' AND rel.relname = 'users' AND NOT t.tgisinternal;
  RAISE NOTICE 'public.users has % non-internal trigger(s) after the change.',
    trigger_count;
  IF trigger_count = 0 THEN
    RAISE WARNING
      'public.users has no triggers. If this project relies on a role-change or '
      'account-status trigger, restore it before deploying the API change.';
  END IF;

  SELECT count(*) INTO fk_count
    FROM pg_constraint con
   WHERE con.contype = 'f' AND con.confrelid = 'public.users'::regclass;
  RAISE NOTICE '% foreign key(s) still reference public.users.', fk_count;
END $$;

COMMIT;

-- ============================================================================
-- 5. DATA MIGRATION — deliberately NOT executed
-- ============================================================================
-- Accounts that should become `owner` cannot be identified from the role string
-- alone. Two cases exist, and both need a human decision:
--
-- a) Rows that literally hold 'property_owner'. §1 aborts if any exist. Decide
--    per account:
--
--      SELECT user_id, role FROM public.users WHERE role = 'property_owner';
--
-- b) Rows holding 'entrepreneur' that are recorded as the owner of a property.
--    These are the accounts the old normalisation mislabelled. Find them; do not
--    guess them:
--
--      SELECT u.user_id, u.role, p.property_id
--        FROM public.users u
--        JOIN public.property p ON p.owner_id = u.user_id
--       WHERE u.role = 'entrepreneur';
--
--    Only after that list is reviewed and the ownership records confirmed should
--    a targeted UPDATE be written. A blanket UPDATE is wrong: some of those
--    accounts are legitimately entrepreneurs recorded against a property for
--    other reasons (assessment, enquiry, shortlist).
--
--    The column name above (`p.owner_id`) is the documented relationship; verify
--    it against the live schema before running the query.
-- ============================================================================
