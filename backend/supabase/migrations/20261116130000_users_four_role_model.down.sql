-- ============================================================================
-- SITEWISE — Rollback: three-role model
-- File: 20261116130000_users_four_role_model.down.sql
-- Reverses: 20261116130000_users_four_role_model.up.sql
--
-- THIS ROLLBACK IS DELIBERATELY CONDITIONAL.
--
-- There is no correct automatic way back to a three-value constraint while
-- `owner` rows exist: narrowing the constraint either fails, or — if someone
-- "fixes" it with an UPDATE — silently removes those accounts' property rights.
-- So this script refuses to run until the `owner` accounts have been
-- reclassified by a person who has checked their ownership records.
--
-- It is also schema-only. The up migration rewrote no rows, so there is no data
-- to restore; what has to be undone is the constraint.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Refuse to narrow while owner accounts exist.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  owner_rows bigint;
BEGIN
  SELECT count(*) INTO owner_rows FROM public.users WHERE role = 'owner';
  IF owner_rows > 0 THEN
    RAISE EXCEPTION
      'rollback refused: % account(s) hold role = ''owner''. Reclassify them '
      'explicitly (and confirm their property ownership records) before '
      'narrowing the constraint. Do not blanket-update owners to entrepreneurs: '
      'that silently removes their property rights.', owner_rows;
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 2. Restore the three-value constraint.
-- ----------------------------------------------------------------------------
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_role_check;

ALTER TABLE public.users
  ADD CONSTRAINT users_role_check
  CHECK (role IN ('entrepreneur', 'agent', 'admin')) NOT VALID;

ALTER TABLE public.users VALIDATE CONSTRAINT users_role_check;

ALTER TABLE public.users ALTER COLUMN role SET DEFAULT 'entrepreneur';

-- ----------------------------------------------------------------------------
-- 3. Verify.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  role_constraint text;
BEGIN
  SELECT pg_get_constraintdef(con.oid) INTO role_constraint
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace ns ON ns.oid = rel.relnamespace
   WHERE ns.nspname = 'public' AND rel.relname = 'users'
     AND con.contype = 'c' AND con.conname = 'users_role_check';

  IF role_constraint IS NULL THEN
    RAISE EXCEPTION 'users_role_check was not recreated';
  END IF;
  IF role_constraint ILIKE '%owner%' THEN
    RAISE EXCEPTION 'rollback incomplete: constraint still accepts owner: %',
      role_constraint;
  END IF;

  RAISE NOTICE 'rolled back to the three-role constraint: %', role_constraint;
END $$;

COMMIT;

-- ============================================================================
-- AFTER ROLLBACK
-- ============================================================================
-- The FastAPI RBAC layer must be rolled back with this migration, or it will
-- normalise `property_owner` to `owner` and then fail the constraint on write.
-- Revert `backend/src/sitewise/domain/rbac.py` in the same release, and note that
-- `property_owner` returns to folding into `entrepreneur` — which is the defect
-- the four-role model exists to fix.
-- ============================================================================
