-- ============================================================================
-- SITEWISE — Identity migration: confirmed role model + staff workflow
-- File: 20261105090000_role_model_staff_mfa.up.sql
-- Target: Supabase identity PostgreSQL (project lzdpjwmcjbhtkzkqudyt)
-- Date: 2026-11-05
--
-- NATURE: additive + data-mapping. NO column is dropped or renamed. Existing
-- rows are preserved; legacy role values are mapped explicitly (see §1).
--
-- RUN ORDER: execute in one transaction in the Supabase SQL editor or via
-- `supabase db push`. Idempotent: safe to re-run.
--
-- ROLLBACK: 20261105090000_role_model_staff_mfa.down.sql (schema only — the
-- role-value mapping is data; restore from the backup taken in §0 to fully
-- reverse it).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 0. Safety snapshot (FYP-scale table; run standalone BEFORE this migration
--    if you prefer a separate backup statement):
--
--      CREATE TABLE public.users_backup_20261105 AS
--        SELECT * FROM public.users;
--
--    Live data observed 2026-11-05: 1 row, role='user', status='active'.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 1. Role-value mapping (explicit, conservative, logged).
--    Confirmed mapping:
--      user           -> entrepreneur   (public accounts)
--      property_owner -> entrepreneur   (ownership is a relationship, not a role)
--      administrator  -> admin
--    Rows already holding canonical values are untouched.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  changed integer;
BEGIN
  UPDATE public.users SET role = 'admin' WHERE role = 'administrator';
  GET DIAGNOSTICS changed = ROW_COUNT;
  RAISE NOTICE 'mapped administrator->admin: % row(s)', changed;

  UPDATE public.users SET role = 'entrepreneur'
   WHERE role IN ('user', 'property_owner');
  GET DIAGNOSTICS changed = ROW_COUNT;
  RAISE NOTICE 'mapped user/property_owner->entrepreneur: % row(s)', changed;

  UPDATE public.users SET role = 'entrepreneur' WHERE role IS NULL;
  GET DIAGNOSTICS changed = ROW_COUNT;
  RAISE NOTICE 'filled NULL roles->entrepreneur: % row(s)', changed;
END $$;

-- 1b. Defensive reconciliation: if a legacy `user_roles` table ever existed,
--     reconcile it into users.role BEFORE constraining. The live project has
--     no user_roles table (verified via REST schema 2026-11-05), so this is a
--     no-op there; it protects any environment that still carries one.
DO $$
DECLARE
  ur_exists boolean;
  col text;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables
     WHERE table_schema = 'public' AND table_name = 'user_roles'
  ) INTO ur_exists;
  IF ur_exists THEN
    -- Find the role column without assuming its name.
    SELECT column_name INTO col
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'user_roles'
       AND column_name IN ('role', 'role_name', 'role_title')
     LIMIT 1;
    IF col IS NOT NULL THEN
      EXECUTE format(
        'UPDATE public.users u SET role = CASE lower(ur.%I)
            WHEN ''admin'' THEN ''admin''
            WHEN ''agent'' THEN ''agent''
            ELSE ''entrepreneur'' END
           FROM public.user_roles ur
          WHERE ur.user_id = u.user_id
            AND u.role IN (''user'', ''property_owner'', ''administrator'')', col);
      RAISE NOTICE 'reconciled users.role from public.user_roles.%', col;
    ELSE
      RAISE NOTICE 'user_roles exists but has no recognised role column; skipped';
    END IF;
  ELSE
    RAISE NOTICE 'no user_roles table present (expected)';
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 2. Account-status reconciliation, then constraints.
--    Unknown/NULL statuses follow email verification (documented policy).
-- ----------------------------------------------------------------------------
UPDATE public.users
   SET account_status = CASE WHEN email_verified THEN 'active' ELSE 'pending' END
 WHERE account_status IS NULL
    OR account_status NOT IN ('pending', 'active', 'suspended');

-- 2b. Default role for ordinary public registration.
ALTER TABLE public.users ALTER COLUMN role SET DEFAULT 'entrepreneur';

-- 2c. Replace any legacy CHECK constraints on role / account_status, then add
--     the confirmed ones. NOT VALID + VALIDATE keeps the window tiny and the
--     operation safe on larger tables.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT con.conname
      FROM pg_constraint con
      JOIN pg_class t ON t.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
     WHERE t.relname = 'users' AND n.nspname = 'public'
       AND con.contype = 'c'
       AND (con.conname LIKE '%role%' OR con.conname LIKE '%account_status%')
  LOOP
    EXECUTE format('ALTER TABLE public.users DROP CONSTRAINT %I', r.conname);
    RAISE NOTICE 'dropped legacy constraint %', r.conname;
  END LOOP;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_role_check'
                  AND conrelid = 'public.users'::regclass) THEN
    ALTER TABLE public.users
      ADD CONSTRAINT users_role_check
      CHECK (role IN ('entrepreneur', 'agent', 'admin')) NOT VALID;
    ALTER TABLE public.users VALIDATE CONSTRAINT users_role_check;
    RAISE NOTICE 'added users_role_check';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_account_status_check'
                  AND conrelid = 'public.users'::regclass) THEN
    ALTER TABLE public.users
      ADD CONSTRAINT users_account_status_check
      CHECK (account_status IN ('pending', 'active', 'suspended')) NOT VALID;
    ALTER TABLE public.users VALIDATE CONSTRAINT users_account_status_check;
    RAISE NOTICE 'added users_account_status_check';
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 3. RLS on public.users: end users may read/update ONLY their own row.
--    Insert/delete stay service-role-only (no policies for them).
--    Column protection (role / account_status / email_verified) is enforced
--    by the trigger in §4 — RLS is row-scoped by design.
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class t
     WHERE t.oid = 'public.users'::regclass AND t.relrowsecurity
  ) THEN
    ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
    RAISE NOTICE 'enabled RLS on public.users';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'users_select_own') THEN
    CREATE POLICY users_select_own ON public.users
      FOR SELECT TO authenticated
      USING (auth.uid() = user_id);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'users_update_own') THEN
    CREATE POLICY users_update_own ON public.users
      FOR UPDATE TO authenticated
      USING (auth.uid() = user_id)
      WITH CHECK (auth.uid() = user_id);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'users_no_anon') THEN
    -- Explicit deny for anon (defence in depth; absence of a policy already
    -- denies when RLS is on).
    CREATE POLICY users_no_anon ON public.users
      FOR SELECT TO anon
      USING (false);
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 4. Self-service protection trigger (belt-and-braces with RLS).
--    * service_role / postgres / SQL-editor runs pass through;
--    * authenticated users may update only their OWN row and never their
--      role, account status, email verification or identity;
--    * end users can never INSERT rows (provisioning is backend-only).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_users_identity_protection()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
  caller text;
BEGIN
  caller := coalesce(auth.role(), current_user);
  IF caller IN ('service_role', 'supabase_admin', 'postgres') THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'INSERT' THEN
    RAISE EXCEPTION 'Profile provisioning is restricted to the Sitewise backend.';
  END IF;

  IF NEW.user_id IS DISTINCT FROM OLD.user_id
     OR NEW.role IS DISTINCT FROM OLD.role
     OR NEW.account_status IS DISTINCT FROM OLD.account_status
     OR NEW.email_verified IS DISTINCT FROM OLD.email_verified THEN
    RAISE EXCEPTION 'Role, account status and verification are managed by Sitewise administrators.';
  END IF;

  IF auth.uid() IS NULL OR auth.uid() <> OLD.user_id THEN
    RAISE EXCEPTION 'You may only update your own profile.';
  END IF;

  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS users_identity_protection ON public.users;
CREATE TRIGGER users_identity_protection
  BEFORE INSERT OR UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_users_identity_protection();

-- ----------------------------------------------------------------------------
-- 5. Automatic public.users provisioning on auth sign-up (Google included).
--    SECURITY DEFINER so the insert bypasses the end-user RLS/trigger path;
--    idempotent (ON CONFLICT DO NOTHING) so the backend's lazy provisioning
--    stays a safe fallback.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  INSERT INTO public.users (user_id, email, full_name, role, account_status, email_verified)
  VALUES (
    NEW.id,
    coalesce(NEW.email, ''),
    coalesce(NEW.raw_user_meta_data ->> 'full_name',
             NEW.raw_user_meta_data ->> 'name'),
    'entrepreneur',
    CASE WHEN NEW.email_confirmed_at IS NOT NULL THEN 'active' ELSE 'pending' END,
    NEW.email_confirmed_at IS NOT NULL
  )
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_auth_user();

-- ----------------------------------------------------------------------------
-- 6. staff_invitations — Sitewise onboarding state ONLY. Supabase Auth owns
--    the actual email-link authentication and password setup; no invitation
--    tokens, secrets or passwords are stored here.
--    RLS: enabled, NO policies -> invisible to anon/authenticated; the
--    backend reads/writes with the service role.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_invitations (
  invitation_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invited_user_id    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  invited_email      text NOT NULL,
  invited_by_user_id uuid NOT NULL REFERENCES public.users (user_id),
  invitation_status  text NOT NULL DEFAULT 'pending'
                     CHECK (invitation_status IN ('pending','sent','accepted','expired','revoked')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  sent_at            timestamptz,
  accepted_at        timestamptz,
  expires_at         timestamptz
);

CREATE INDEX IF NOT EXISTS staff_invitations_email_idx
  ON public.staff_invitations (invited_email);
CREATE INDEX IF NOT EXISTS staff_invitations_status_idx
  ON public.staff_invitations (invitation_status);
-- At most one OPEN invitation per email.
CREATE UNIQUE INDEX IF NOT EXISTS staff_invitations_one_open_per_email
  ON public.staff_invitations (invited_email)
 WHERE invitation_status IN ('pending', 'sent');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class t
     WHERE t.oid = 'public.staff_invitations'::regclass AND t.relrowsecurity
  ) THEN
    ALTER TABLE public.staff_invitations ENABLE ROW LEVEL SECURITY;
  END IF;
  -- No policies at all: deny-all for anon/authenticated (service role bypasses).
  REVOKE INSERT, UPDATE, DELETE ON public.staff_invitations FROM anon, authenticated;
END $$;

COMMENT ON TABLE public.staff_invitations IS
  'Sitewise staff onboarding tracking. Authentication + password setup are owned by Supabase Auth; no credentials stored.';

-- ----------------------------------------------------------------------------
-- 7. role_change_audit — server-generated events for agent provisioning /
--    activation / suspension / reactivation / role changes / access
--    revocation / MFA recovery administration.
--    RLS: enabled, NO policies for end users; the backend writes with the
--    service role, so ordinary users can neither create nor modify records.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.role_change_audit (
  audit_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  affected_user_id    uuid REFERENCES public.users (user_id) ON DELETE SET NULL,
  affected_email      text,
  performed_by_user_id uuid REFERENCES public.users (user_id),
  performed_by_email  text,
  action              text NOT NULL,
  previous_role       text,
  new_role            text,
  previous_status     text,
  new_status          text,
  details             jsonb,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS role_change_audit_affected_idx
  ON public.role_change_audit (affected_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS role_change_audit_action_idx
  ON public.role_change_audit (action, created_at DESC);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class t
     WHERE t.oid = 'public.role_change_audit'::regclass AND t.relrowsecurity
  ) THEN
    ALTER TABLE public.role_change_audit ENABLE ROW LEVEL SECURITY;
  END IF;
  REVOKE INSERT, UPDATE, DELETE ON public.role_change_audit FROM anon, authenticated;
END $$;

COMMENT ON TABLE public.role_change_audit IS
  'Server-generated privileged audit trail (staff provisioning, role/status changes, MFA recovery). Written only by the backend service role.';

-- ----------------------------------------------------------------------------
-- 8. Agent profile identity link (additive). The existing public.agent table
--    (agent_id int64 PK, agent_name, company_id) gains user_id so listing
--    authorization can resolve: auth UUID -> agent profile -> listing.agent_id.
--    Existing columns/rows untouched (0 rows observed 2026-11-05).
-- ----------------------------------------------------------------------------
ALTER TABLE public.agent ADD COLUMN IF NOT EXISTS user_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS agent_user_id_unique
  ON public.agent (user_id)
 WHERE user_id IS NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'agent_user_id_fkey' AND conrelid = 'public.agent'::regclass
  ) THEN
    ALTER TABLE public.agent
      ADD CONSTRAINT agent_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES public.users (user_id) ON DELETE SET NULL NOT VALID;
    RAISE NOTICE 'added agent_user_id_fkey';
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 9. updated_at maintenance on public.users (only if nothing maintains it).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $fn$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgrelid = 'public.users'::regclass
       AND tgname = 'users_touch_updated_at'
       AND NOT tgisinternal
  ) THEN
    DROP TRIGGER IF EXISTS users_touch_updated_at ON public.users;
    CREATE TRIGGER users_touch_updated_at
      BEFORE UPDATE ON public.users
      FOR EACH ROW
      EXECUTE FUNCTION public.touch_updated_at();
    RAISE NOTICE 'added users_touch_updated_at trigger';
  ELSE
    RAISE NOTICE 'updated_at maintenance already present; skipped';
  END IF;
END $$;

COMMIT;

-- ----------------------------------------------------------------------------
-- 10. Post-migration verification (run separately):
--
--   -- every role canonical:
--   SELECT role, count(*) FROM public.users GROUP BY role ORDER BY role;
--
--   -- constraints present:
--   SELECT conname FROM pg_constraint
--    WHERE conrelid = 'public.users'::regclass AND conname LIKE 'users_%';
--
--   -- new tables + RLS on:
--   SELECT relname, relrowsecurity FROM pg_class
--    WHERE relnamespace = 'public'::regclass
--      AND relname IN ('staff_invitations','role_change_audit');
--
--   -- protection trigger armed:
--   SELECT tgname FROM pg_trigger WHERE tgrelid = 'public.users'::regclass;
--
--   -- end-user self-protection smoke test (should FAIL as authenticated):
--   --   UPDATE public.users SET role='admin' WHERE user_id = auth.uid();
-- ----------------------------------------------------------------------------
