-- ============================================================================
-- SITEWISE — Rollback for 20261105090000_role_model_staff_mfa.up.sql
--
-- SCOPE: restores the SCHEMA touched by the migration. The role-value DATA
-- mapping (user/property_owner -> entrepreneur, administrator -> admin) is
-- NOT reversed automatically — restore the pre-migration backup instead:
--
--   BEGIN;
--   TRUNCATE public.users;
--   INSERT INTO public.users SELECT * FROM public.users_backup_20261105;
--   COMMIT;
--
-- Run AFTER stopping the backend (no in-flight staff operations).
-- ============================================================================

BEGIN;

-- 1. Triggers + functions ----------------------------------------------------
DROP TRIGGER IF EXISTS users_identity_protection ON public.users;
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS users_touch_updated_at ON public.users;
DROP FUNCTION IF EXISTS public.enforce_users_identity_protection();
DROP FUNCTION IF EXISTS public.handle_new_auth_user();
DROP FUNCTION IF EXISTS public.touch_updated_at();

-- 2. Constraints + default ----------------------------------------------------
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_account_status_check;
ALTER TABLE public.users ALTER COLUMN role SET DEFAULT 'user';

-- 3. RLS policies on users (RLS itself stays enabled — pre-existing state) ----
DROP POLICY IF EXISTS users_select_own ON public.users;
DROP POLICY IF EXISTS users_update_own ON public.users;
DROP POLICY IF EXISTS users_no_anon ON public.users;

-- 4. Agent identity link -------------------------------------------------------
ALTER TABLE public.agent DROP CONSTRAINT IF EXISTS agent_user_id_fkey;
DROP INDEX IF EXISTS public.agent_user_id_unique;
ALTER TABLE public.agent DROP COLUMN IF EXISTS user_id;

-- 5. Onboarding / audit tables --------------------------------------------------
DROP TABLE IF EXISTS public.staff_invitations;
DROP TABLE IF EXISTS public.role_change_audit;

COMMIT;

-- Verification: the audit trail ends when these tables drop. Archive first if
-- the records matter for the FYP report:
--   CREATE TABLE public.role_change_audit_backup_20261105 AS
--     SELECT * FROM public.role_change_audit;
