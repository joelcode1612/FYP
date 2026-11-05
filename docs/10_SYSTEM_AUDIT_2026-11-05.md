# 10 — System Audit: Auth / Roles / Staff Workflow (2026-11-05)

Audit method: direct source read of `backend/src/sitewise/**`, `fyp_jaspr_web`
auth stack, live read-only inspection of the Supabase project (REST OpenAPI,
role distribution, anon-access probe) and the local `sitesense` PostgreSQL.
All live data observations were made with the service key in read-only mode.

## 1. Live databases — what actually exists

| Store | Reality (verified) |
|---|---|
| Supabase identity DB (`lzdpjwmcjbhtkzkqudyt`) | `public.users` exists with exactly the 11 spec columns (`user_id` uuid PK, `full_name`, `email`, `phone_number`, `role`, `profile_picture_url`, `account_status`, `email_verified`, `last_login`, `created_at`, `updated_at`). **1 row: `role='user'`, `status='active'`** (legacy value). `auth.users` is the identity source. RPCs `is_active_user` / `is_admin` exist. **Anon access to `users` is denied (42501)** — RLS/grants already block public reads. |
| Supabase `public` (application tables) | `agent` (`agent_id` int64, `agent_name`, `company_id` — **no `user_id` column yet**, 0 rows), `company` (3 cols), `listing` (`listing_id` int64, `property_id` int64, `agent_id` int64 + 18 research columns, 0 rows), `listing_verification` (`verification_id` uuid, `listing_id`, **`verified_by_user_id` uuid**, status/reason/evidence columns), plus `address`, `property`, `property_photo`, `property_geospatial_feature`, `favorite_property`, `recommendation_result`, `demand_generator`, `transportation_access`, `nearby_competitor`, `district_demographic`, `pano_jobs`, legacy `user_tokens`. |
| Local PostgreSQL `sitesense` | FastAPI's application DB: `users` mirror (same 11 columns, SQLModel `create_all`-managed), plus property/preferences/favourite/recommendation tables. `alembic/versions/` is **empty**. |
| Local PostgreSQL `Final_Location_Analysis` | Analytics (DOSM + PostGIS), read-only via `db/analytics_session.py`. Untouched by this work. |

**Key correction to the ERD assumption:** the property/listing/agent/company
tables live in **Supabase `public`**, not local `sitesense`. `user_roles`,
`role_change_audit`, and `staff_invitations` **do not exist anywhere** (no DDL
in the repo, not exposed by the Supabase REST API).

## 2. Existing backend implementation (keep and extend)

| Component | State |
|---|---|
| JWT verification (`core/security.py`) | Works, well tested (17 tests): JWKS ES256, alg allow-list (rejects `none`/HS256), iss/aud/exp/nbf, rotation via unknown-`kid` refresh, fail-closed 503. |
| Auth dependencies (`dependencies.py`) | `bearer_token` → `get_current_user` (verifies + lazy-provisions local profile) → `get_active_user` (suspended/pending → 403) → `require_roles` factory. Role/status **always** read from the local DB row, never token metadata. |
| RBAC (`domain/rbac.py`) | Pure-domain string constants. **Mismatch:** 5 roles (`user`, `entrepreneur`, `property_owner`, `agent`, `administrator`); `PUBLIC_REGISTRATION_ROLES` wrongly includes `property_owner` and `agent`. Protected profile fields correctly reject self-service role/status changes. |
| Identity mapping | Supabase UUID = `sitesense.users.user_id` PK; lazy provisioning with default `role="user"` (→ must become `entrepreneur`). |
| User admin endpoints (`api/v1/users.py`) | `GET/PATCH/DELETE /users/{id}` admin-only, role/status validated (422) — but **no audit trail** and no write-through to the authoritative Supabase `public.users` row. |
| Endpoints present | `/auth/me`, `/auth/session`, `/users/me*`, admin user CRUD, properties, saved-properties, recommendations, virtual tours, suitability, reports, geospatial/statistics (public by design). |
| **Missing (confirmed)** | Agent provisioning (no Supabase admin usage anywhere — `SUPABASE_SECRET_KEY` configured but dead), `staff_invitations`, `role_change_audit`, staff MFA assurance (`aal`) checks, assigned-listing authorization, MFA recovery, password-reset backend support. `pyproject.toml` had **no Supabase SDK** (added in this work: `supabase>=2.34`). |
| Alembic | Empty — schema via `create_all`. No application-DB schema change is required by this work (staff/invitation/audit tables live in Supabase), so no migration is generated. |
| Tests | Real local `sitesense` + generated ES256 keypair (`conftest.py`), `test_security.py` (17), `test_auth_api.py` (14), `test_rbac_domain.py` (7). Role expectations reference legacy values. |

## 3. Existing frontend implementation (keep and extend)

| Component | State |
|---|---|
| Jaspr auth bridge | Dart `WebAuth` (`lib/data/auth_browser.dart`) → JS global `sitewiseAuth` from `tool/auth_client.js` (bundled supabase-js, PKCE). Config from `web/auth-config.json` (publishable key only — safe client-side). |
| Entrepreneur flows | Email/password sign-in, Google OAuth (`/auth/callback`), sign-up (role hardcoded `entrepreneur` server-provisioned), remember-me storage. |
| Staff portal | Split UI just redesigned (dark-glass card, no Google, no sign-up). MFA **challenge/verify** exists at sign-in (TOTP), but: (a) detection is a "no session + verified factor" heuristic, not the documented `getAuthenticatorAssuranceLevel()` flow; (b) **no MFA enrollment UI** (`mfa.enroll` never called); (c) profile/`/api/me` calls still target the legacy Express API (`:3001`), not FastAPI. |
| Password recovery | Forgot pages are **demo-disabled** ("Demo build — password reset is disabled"); `resetPasswordForEmail` is never called anywhere. |
| Mobile (Flutter) | Local demo auth only, no Supabase client — out of scope for this task. |

## 4. Gaps → actions taken (this work)

1. Role model → 3 canonical roles (`entrepreneur`/`agent`/`admin`) with legacy
   aliases (`user`→`entrepreneur`, `administrator`→`admin`,
   `property_owner`→`entrepreneur`) normalized in `rbac`.
2. Supabase identity migration (additive, idempotent): role/status CHECK
   constraints + data mapping, `staff_invitations`, `role_change_audit`
   (RLS: service-role only), self-service protection trigger on
   `public.users`, `auth.users` → profile provisioning trigger, and
   `agent.user_id` (additive column) to bind auth identities to agent
   profiles.
3. FastAPI: official `supabase` SDK admin adapter (invite-based agent
   provisioning, authoritative identity-row sync, audit + invitation
   writes, documented GoTrue admin REST for MFA-factor recovery since
   supabase-py 2.34.0 does not wrap admin factor endpoints), staff
   authorization dependency requiring **`aal2`**, `/staff/*` router
   (create/list/suspend agents, invitations, listing assignment,
   verification findings, audit read), audit recording on admin role/status
   changes, default provisioning role `entrepreneur`.
4. Jaspr: FastAPI endpoints wired (`/api/v1/auth/me`), staff sign-in moved to
   the documented AAL flow (`getAuthenticatorAssuranceLevel`), TOTP
   enrollment screen, password recovery + reset for both portals.
5. Tests updated/added for the new role model, `aal2` enforcement, agent
   provisioning and scoping.
