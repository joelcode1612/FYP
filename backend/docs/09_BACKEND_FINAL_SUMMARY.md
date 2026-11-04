# 09 — Backend Final Summary

Date: 2026-11-04 · Scope: complete missing components of the existing
Sitewise FastAPI backend, reusing the existing Supabase project, Clean
Architecture implementation and the two local PostgreSQL databases.

## Mandatory summary table

| Component | Previous Status | Changes Made | Final Status | Tests |
|---|---|---|---|---|
| FastAPI backend | Existing | Auth/ownership wiring in routers; error mapping (401/403/404/503/410); non-leaking 500; auth router registered | COMPLETE | 62/62 suite green |
| Supabase connection | Configured (verified live) | `SUPABASE_*` added to `.env`; config settings; JWKS client + verifier | COMPLETE | Health/JWKS/admin live checks + 14 security tests |
| Supabase registration | Incomplete (by design in backend) | Documented as frontend-owned; direct local creation disabled with explicit 410 | COMPLETE (design per spec §6.1) | `test_user_creation_endpoint_is_gone` |
| Supabase login | Incomplete (by design in backend) | Documented as frontend-owned; bearer verification is the backend contract | COMPLETE (design) | All bearer tests |
| JWT verification | Missing | `core/security.py`: JWKS cache + rotation, ES256 allow-list, iss/aud/exp/nbf/sub/iss-claims, HS256/none rejection, 503 fail-closed | COMPLETE | 14 matrix tests |
| Profile management | Incomplete | `/auth/me`, `/users/me` GET/PATCH/status; immutable-field protection; lazy provisioning | COMPLETE | 8 API tests |
| RBAC | Missing | `domain/rbac.py` matrices + `require_*` dependencies | COMPLETE | 6 domain + 8 API tests |
| Property ownership | Unverified | Ownership checks server-side; `user_id` stamped from identity; transfer impossible | COMPLETE | ownership tests |
| Application PostgreSQL (`sitesense`) | Existing (0 users) | Identity mapping via UUID PK; race-safe provisioning; datetime-awareness fix | COMPLETE | 5 DB tests |
| Analytics PostgreSQL (`Final_Location_Analysis`) | Existing | Verified DOSM tables/view; separate read-only engine preserved; endpoint live (200, real rows) | COMPLETE | connectivity + endpoint tests |
| Suitability engine | Placeholder (`score: 0.0`) | Honest unavailable envelope with prerequisites; property-404 distinct from model-503/200 | PARTIALLY_COMPLETE (blocked on spec) | envelope test |
| PU Learning integration | Incomplete | Full inference contract (load/validate/predict/report); blocks honestly without artifact | PARTIALLY_COMPLETE (blocked on artifact) | 4 ML tests |
| SHAP integration | Incomplete | Guarded integration with explainer-type from metadata | PARTIALLY_COMPLETE (blocked on artifact + shap dep) | 1 test |
| Automated tests | 4 trivial | 58 new tests across security/RBAC/API/architecture/DB/ML | COMPLETE | **62 passed, 0 failed** |

Statuses: `COMPLETE` · `PARTIALLY_COMPLETE` · `BLOCKED` · `NOT_IMPLEMENTED`.

## Deliverables

`backend/docs/01…09` (this set) · modified sources under
`backend/src/sitewise/**` · `backend/.env.example` (placeholders) ·
`backend/pyproject.toml` (+`pyjwt[crypto]`, `numpy`, pytest config) ·
`backend/tests/**` (7 new modules + conftest) · `backend/report.xml` +
`backend/run.log` (execution evidence).

## Remaining blockers (exact)

1. **Suitability/ML predictions** — need (a) supervisor-approved scoring
   specification and (b) a trained artifact at
   `backend/ml/artifacts/pu_model.pkl` (+ feature contract). Files:
   `src/sitewise/domain/suitability_engine.py`,
   `src/sitewise/ml/pu_learning.py`. Nothing to train on exists.
2. **Agent professional verification** — no table/flow exists;
   non-destructive migration proposed in
   `docs/06_DATABASE_INTEGRATION.md` (requires approval before execution).
3. **Alembic baseline** — `alembic/versions/` empty; proposed `0001_initial`
   autogenerate (requires approval; schema is currently `create_all`-managed).
4. **Frontend cutover** — the web frontend still uses the Express API
   (`:3001`) for profiles/data; pointing it at FastAPI is a frontend change,
   out of backend scope here.

## Security posture changes

* No endpoint performs identity-trusted actions without a verified Supabase
  JWT; role/status always read from the local DB, never from token metadata.
* Unauthenticated user CRUD removed; admin routes enforce `administrator`.
* 500 responses no longer echo exception text (logged server-side instead).
* Secret key stays in git-ignored `.env`, is unused by verification, and
  `.env.example` carries placeholders only.
