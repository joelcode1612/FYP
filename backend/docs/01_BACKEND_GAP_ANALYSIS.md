# 01 — Backend Gap Analysis (verified against source, 2026-11-04)

Inspection method: direct source read of `backend/src/sitewise/**`, live
verification of the Supabase project (auth health, JWKS, admin API), live
queries against both local PostgreSQL databases. Prior reports
(`CLEAN_ARCHITECTURE_REVIEW.md`) were used as orientation only.

## Verified pre-existing state

| Area | Verified state |
|---|---|
| FastAPI app | 9 v1 routers, CORS, two DB engines, `/health`; lifespan runs `create_all` on the app DB only |
| Application DB `sitesense` | 15 tables incl. `users` (UUID PK, `role`, `account_status`, `email_verified`, **no password column**), 0 rows |
| Analytics DB `Final_Location_Analysis` | All DOSM tables + `vw_latest_district_statistics` + PostGIS; used read-only via `db/analytics_session.py` |
| Supabase | GoTrue v2.197.0 healthy; JWKS publishes **1 × ES256** key (`kid b4b6694b-…`); publishable key valid; secret key accepted by admin API (HTTP 200) |
| Auth in FastAPI | **Nothing** — no JWT verification, no auth dependencies, all routers open |
| `users.py` | Unauthenticated CRUD over all users (create/update/delete any user) |
| `domain/rbac.py` | Did not exist |
| `domain/suitability_engine.py` | Stub returning `{"score": 0.0}` — a fabricated prediction |
| `ml/*` | Empty stubs (`class X: pass`); **no model artifacts anywhere** in the repo |
| Tests | Only 4 trivial tests (health/openapi/rank/statistics) |

## Gaps closed in this work

1. JWT verification (JWKS/ES256) — implemented, `core/security.py`.
2. Auth dependencies + RBAC — implemented, `dependencies.py` + `domain/rbac.py`.
3. `/auth/me`, `/users/me` (GET/PATCH/status) — implemented.
4. Identity mapping (Supabase UUID → `users.user_id` PK) — implemented; duplicates structurally impossible.
5. Router protection: saved-properties ownership, property-management roles, recommendation scoping, admin-only user routes, disabled direct user creation (410).
6. Honest ML/suitability unavailability reporting (no fabricated scores).
7. Security: generic 500 (no exception text leakage), admin-guarded routes, ownership checks server-side.

## Remaining gaps (with prerequisites)

| Gap | Blocker |
|---|---|
| Agent professional verification | No `agent_verification` table/flow exists in any database; needs a spec + non-destructive migration (proposed in `06_DATABASE_INTEGRATION.md`) |
| Real suitability scores | No approved scoring specification and no trained artifact — see `07_ML_INTEGRATION_REPORT.md` |
| PU-Learning / SHAP execution | No trained artifact; `shap` intentionally not a hard dependency |
| Frontend → FastAPI migration | The web frontend currently authenticates through Supabase directly and stores profiles via the Express API (`:3001`); switching it to FastAPI is a frontend task |
| Alembic migrations | `alembic/versions/` is empty; schema currently comes from `create_all` on the app DB. First migration to be generated only after the agent-verification schema decision |
