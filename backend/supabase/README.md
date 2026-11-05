# Supabase identity migrations (SiteWise)

Safe SQL migrations for the **Supabase identity PostgreSQL** — the database
that owns `auth.users`, `public.users` (authoritative role), and the staff
onboarding / audit tables. The local application (`sitesense`) and analytics
(`Final_Location_Analysis`) databases are managed by FastAPI + Alembic and are
NOT touched from here.

## Contents

| File | Purpose |
|---|---|
| `migrations/20261105090000_role_model_staff_mfa.up.sql` | Confirmed 3-role model (`entrepreneur`/`agent`/`admin`), legacy-role data mapping, `staff_invitations`, `role_change_audit`, self-service protection trigger, sign-up provisioning trigger, `agent.user_id` identity link, RLS. |
| `migrations/20261105090000_role_model_staff_mfa.down.sql` | Schema rollback (data mapping is reverted via backup restore, see header). |

## How to run (staging first)

1. **Back up** (either):
   - Supabase Dashboard → Database → Backups, or
   - SQL editor: `CREATE TABLE public.users_backup_20261105 AS SELECT * FROM public.users;`
   - CLI: `pg_dump "$SUPABASE_DB_URL" --table=public.users --table=public.agent > pre_migration_backup.sql`
2. Paste the `.up.sql` file into **Supabase SQL Editor** and run (or
   `supabase db push` if the CLI is linked). It is a single transaction and
   idempotent — safe to re-run.
3. Run the verification queries in §10 of the migration file. Expected:
   - `SELECT role, count(*) FROM public.users GROUP BY role;` → only
     `entrepreneur` / `agent` / `admin`.
   - `staff_invitations` + `role_change_audit` exist with `relrowsecurity = true`.
   - Triggers `users_identity_protection`, `on_auth_user_created` armed.

## Required Supabase Auth configuration (manual, after migration)

- **Auth → URL Configuration → Redirect URLs**: add the app origin used in
  invite/recovery links (e.g. `http://localhost:8090/**` for the Jaspr dev
  server, plus the deployed origin). The backend sends
  `redirect_to = <origin>/auth/callback` via
  `SUPABASE_STAFF_INVITE_REDIRECT_URL` (see `backend/.env.example`).
- **Auth → Email Templates → Invite**: keep the default `{{ .ConfirmationURL }}`
  link — the "password setup" screen is Supabase's native invite flow; no
  custom tokens are involved.
- **Auth → Providers**: Google stays enabled for the Entrepreneur Portal only
  (the Staff Portal never offers OAuth).
- **MFA**: TOTP is a native Supabase Auth feature — nothing to enable
  server-side beyond leaving factors allowed (default).

## What this migration deliberately does NOT do

- No column drops/renames on `public.users` (all 11 spec columns preserved).
- No `user_roles` drop — the table does not exist in the live project
  (verified 2026-11-05); the migration contains a defensive no-op
  reconciliation if an environment still has one.
- No application-data changes (`listing`, `listing_verification`, `company`,
  `address`, analytics tables untouched). The only additive change is
  `agent.user_id` (nullable uuid + unique index + FK).
- No destructive SQL anywhere.
