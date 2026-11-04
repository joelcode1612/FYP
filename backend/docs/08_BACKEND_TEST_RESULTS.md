# 08 — Backend Test Results (actual execution)

Command executed (backend venv, Python 3.13.14, pytest 9.2.0):

```
cd backend
.venv\Scripts\python -m pytest tests -q --junitxml=report.xml
```

**Result: 62 tests — 0 failures, 0 errors, 0 skipped (5.7 s).**
Evidence: `backend/report.xml` (JUnit), `backend/run.log`.

## Suites and what they prove

| File | Tests | Covers |
|---|---|---|
| `tests/test_security.py` | 14 | Valid ES256 token; expired; wrong issuer; wrong audience; unknown `kid`; **HS256 forgery rejected by alg allow-list**; unsigned `none` token rejected; tampered signature; missing `sub`/`aud`/`iss`; future `nbf`; malformed token; JWKS unreachable → **503 fail-closed**; empty JWKS → fail-closed; **key rotation picked up on unknown kid without restart** |
| `tests/test_rbac_domain.py` | 6 | Permission matrices; administrator never publicly registrable; protected-field filtering |
| `tests/test_auth_api.py` | 13 | `/auth/me` 401 without token; provisioning on first call (no duplicates); garbage/wrong-scheme tokens; `/users/me` GET/PATCH/status; **role/status/email/user_id change attempts → 403 (not silently ignored, mixed payloads included)**; user list requires admin; direct user creation → 410; saved-property ownership (foreign save forced to self, foreign read/delete → 403); property creation requires owner role; **suspended account → 403** |
| `tests/test_architecture.py` | 5 | Domain has no fastapi/supabase/sqlmodel/sqlalchemy/pydantic-settings imports; ml layer framework-free; services testable with fake repositories (demonstrated); no `sitewise.main`/`api` imports from domain |
| `tests/test_database.py` | 5 | App DB connectivity + expected tables; analytics DB connectivity + DOSM tables/views + read-only proof; **identity mapping creates no duplicates**; users table has no password/hash/refresh-token columns and PK is `user_id`; DOSM statistics endpoint works |
| `tests/test_ml.py` | 9 | Missing artifact → explicit `ModelUnavailableError`; artifact without feature contract rejected; valid dummy artifact loads, predicts (0.75, label 1); **missing feature reported, never imputed**; extra contract column rejected; ranking pure function; SHAP reports unavailability; suitability envelope `score: null` |
| `tests/api/test_app.py`, `tests/api/test_statistics.py`, `tests/domain/test_domain.py` (pre-existing) | 4 | Health, OpenAPI, statistics reachability, ranking behaviour — all still pass (no regressions) |

## Test isolation notes

* Supabase is never contacted: an ES256 keypair is generated per run and the
  JWKS fetch is substituted — the real verification code path executes.
* Tests that touch the development `sitesense` database create rows with
  `@jwks-test.example` emails and delete them in teardown.
* No real Supabase accounts were created; no live authentication settings
  were modified.

## Known non-tests

Registration/login/logout/refresh flows run in Supabase Auth and the
frontend SDK — they are covered here only at the boundary FastAPI owns
(token verification + identity provisioning). End-to-end OAuth round-trips
were verified interactively against the live project (redirect accepted by
Supabase), not in this pytest run.
