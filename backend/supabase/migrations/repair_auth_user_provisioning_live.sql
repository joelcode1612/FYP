-- ---------------------------------------------------------------------------
-- Sitewise: repair auth.users -> public.users provisioning (live project)
--
-- WHY: GoTrue `invite_user_by_email` currently fails with
--      "Database error saving new user". The AFTER INSERT trigger on
--      auth.users raises while writing public.users, so no identity can be
--      created and no staff invitation can be sent.
--
-- WHAT: re-creates the provisioning function exactly as the repository
--       migration 20261105090000_role_model_staff_mfa §5 intends, plus
--       explicit created_at/updated_at values so the insert is valid even if
--       those live columns have no DEFAULT.
--
-- SAFETY: idempotent (CREATE OR REPLACE + DROP TRIGGER IF EXISTS),
--         touches NO table/column/data, changes NO RLS policy, and keeps
--         ON CONFLICT DO NOTHING so existing rows are never overwritten.
--         Run the PRE-CHECK first; paste its output if you want me to
--         confirm the diagnosis before applying.
-- ---------------------------------------------------------------------------

-- ── PRE-CHECK (read-only) ──────────────────────────────────────────────────
-- 1) Existing triggers on auth.users:
--    select tgname, pg_get_triggerdef(t.oid)
--      from pg_trigger t
--     where tgrelid = 'auth.users'::regclass and not tgisinternal;
--
-- 2) Existing provisioning function body (look for SECURITY DEFINER):
--    select pg_get_functiondef('public.handle_new_auth_user()'::regprocedure);
--
-- 3) Confirm the timestamp defaults on public.users:
--    select column_name, column_default, is_nullable
--      from information_schema.columns
--     where table_schema = 'public' and table_name = 'users'
--       and column_name in ('created_at','updated_at');

-- ── FIX ────────────────────────────────────────────────────────────────────
begin;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  insert into public.users (
    user_id, email, full_name, role, account_status, email_verified,
    created_at, updated_at
  )
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'full_name',
             new.raw_user_meta_data ->> 'name'),
    'entrepreneur',
    case when new.email_confirmed_at is not null then 'active' else 'pending' end,
    new.email_confirmed_at is not null,
    now(),
    now()
  )
  on conflict (user_id) do nothing;
  return new;
end $fn$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_auth_user();

commit;

-- ── POST-CHECK (read-only) ─────────────────────────────────────────────────
-- select tgname, pg_get_triggerdef(t.oid)
--   from pg_trigger t
--  where tgrelid = 'auth.users'::regclass and not tgisinternal;
--
-- Then retry Invite Agent in the admin UI. Expected: Supabase creates the
-- identity, the password-setup email is handed to the mail provider, and the
-- agent appears as "pending" with its company in the directory.
