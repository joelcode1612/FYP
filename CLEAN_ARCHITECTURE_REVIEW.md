# CLEAN_ARCHITECTURE REVIEW

**Generated:** 2026-11-03
**Package reviewed:** `backend/src/sitewise` (FastAPI + SQLModel + SQLAlchemy + Alembic)

## 1. Actual directory structure (presentation → application → domain → infrastructure)

```
sitewise/
├── main.py                      # Composition root: app, lifespan, CORS, routers, health
├── dependencies.py              # FastAPI bridge: DbSession = Annotated[object, Depends(get_db)]
├── api/v1/                      # PRESENTATION LAYER (FastAPI routers)
│   ├── router.py                # Aggregates all v1 routers
│   ├── users.py  properties.py  recommendations.py  suitability.py
│   ├── saved_properties.py  geospatial.py  virtual_tours.py  reports.py
│   └── statistics.py            # ADDED: read-only DOSM statistics (see correction report)
├── services/                    # APPLICATION LAYER (use-cases / application services)
│   ├── user_service.py  property_service.py  recommendation_service.py
│   ├── suitability_service.py  geospatial_service.py  virtual_tour_service.py
│   ├── explanation_service.py  report_service.py  statistics_service.py (ADDED)
├── repositories/                # INFRASTRUCTURE LAYER (persistence)
│   ├── user_repository.py  property_repository.py  recommendation_repository.py
│   ├── favourite_repository.py  property_feature_repository.py
│   ├── property_photo_repository.py  geospatial_repository.py
│   ├── user_repository.py  virtual_tour_repository.py  statistics_repository.py (ADDED)
├── db/                          # INFRASTRUCTURE LAYER (DB engine + ORM models)
│   ├── session.py               # app engine + get_db (sitesense)
│   ├── analytics_session.py     # ADDED: analytics engine + get_analytics_db (Final_Location_Analysis)
│   ├── base.py  models/ (15 SQLModel tables)  __init__.py
├── domain/                      # DOMAIN LAYER (business rules, pure)
│   ├── entities.py              # `class Entity: pass` (marker)
│   ├── ranking.py               # `rank(items)` pure function
│   └── suitability_engine.py    # `SuitabilityEngine.score()` — STUB returns 0.0
├── core/                        # CROSS-CUTTING
│   ├── config.py                # Pydantic Settings (DB URLs, CORS, secret)
│   ├── exceptions.py            # SiteWiseError / NotFoundError (defined, unused)
│   └── logging.py
└── ml/                          # SEPARATE (NOT imported by the running app)
    ├── model_loader.py  pu_learning.py  shap_explainer.py
```

## 2. Layer responsibility mapping

| Layer | Intended responsibility | Where implemented | Verdict |
|---|---|---|---|
| Presentation | HTTP, validation, status codes, DI, routing | `api/v1/*`, `main.py`, `dependencies.py` | OK |
| Application | Use-cases, workflows, app services, coordination | `services/*` | OK (see violation #3) |
| Domain | Entities, business rules, suitability policy | `domain/*` | Partial — suitability logic is a stub |
| Infrastructure | Repositories, SQLAlchemy models, sessions, PostGIS, external adapters | `repositories/*`, `db/*` | OK (DOSM was missing, now added) |

## 3. Dependency-rule verification

| # | Rule | Result | Evidence |
|---|---|---|---|
| 1 | Domain does not depend on FastAPI | **PASS** | `grep` for `fastapi`/`sqlalchemy` in `domain/` → no matches; `domain/ranking.py` and `domain/suitability_engine.py` contain no imports at all. |
| 2 | Domain does not import SQLAlchemy implementations | **PASS** | Same grep; domain is import-free. |
| 3 | Application does not depend directly on infrastructure implementations | **PARTIAL / MINOR** | `services/*` import concrete repositories (`from sitewise.repositories.user_repository import UserRepository`) and `db.models` directly, rather than depending on abstract ports. Pragmatic, but not strict Clean Architecture. |
| 4 | Infrastructure implements interfaces required by app/domain | **N/A** | No formal repository interfaces exist; services consume repository classes directly. |
| 5 | Presentation routes call use-cases (not embedded logic) | **PASS** | Routers are thin: `UserService(session).list_users(...)`, `SuitabilityService(session).assess(...)`. |
| 6 | DB sessions managed correctly | **PASS** | `get_db` / `get_analytics_db` use `with Session(engine) as s: yield s` (context-managed, auto-close). |
| 7 | Dependency injection consistent | **PASS** | FastAPI `Depends(get_db)` used uniformly; analytics uses `Depends(get_analytics_db)`. |
| 8 | No circular dependencies | **PASS** | Import graph is acyclic: `main → router → services → repositories → models`; `config`/`session` are leaves. |

## 4. Missing / incomplete components

1. **Authentication & authorization — ABSENT.**
   - No login endpoint, no password hashing, no JWT/session logic.
   - `SECRET_KEY` (`config.py`) is an unused placeholder (`change-me`).
   - `UserTokens` model exists but is never read/written.
   - The audit-referenced tables `fyp.users` (in `Final_Location_Analysis`, with
     `password_hash`, `is_active`, bigint `id`) and `sitewise_app.profiles`
     (uuid `user_id`, `display_name`, `role`) are **not referenced by any
     backend code**. The backend's own `User` model (`user_id uuid`, **no**
     `password_hash`) maps to `sitesense.public.users` and is unrelated to
     `fyp.users`. → These tables do **not** belong to the FastAPI backend as
     implemented; there is an integration gap. (Per task constraints, auth is
     reported, not implemented.)

2. **Suitability / recommendation scoring — INCOMPLETE (stub).**
   - `domain/suitability_engine.py::SuitabilityEngine.score()` always returns
     `{"property_id": …, "score": 0.0}`. The actual scoring policy is not
     implemented. `domain/ranking.py::rank()` is trivial. The ML modules
     (`ml/pu_learning.py`, `shap_explainer.py`) are **not imported by the app**
     and are therefore not wired into any use-case.

3. **DOSM statistical datasets — MISSING repository (now added).**
   - The 8 DOSM datasets live in `Final_Location_Analysis.public` and were not
     retrievable through any repository. A read-only `StatisticsRepository`
     (+ service + router) was added (see correction report).

4. **Automated tests — SPARSE.**
   - Only 2 tests exist (`tests/api/test_app.py`: `/health`, `/openapi.json`).
   - `tests/domain/`, `tests/repositories/`, `tests/services/` are empty.

## 5. Corrective actions taken

| Action | File(s) | Reason |
|---|---|---|
| Fix connection string `sitewise` → `sitesense` | `.env`, `.env.example`, `core/config.py`, `alembic.ini`, `docker-compose.yml` | Configured database `sitewise` did not exist; the app's ORM models map to `sitesense.public`. |
| Add read-only analytics connection + DOSM repository | `core/config.py` (`analytics_database_url`), `db/analytics_session.py`, `repositories/statistics_repository.py`, `services/statistics_service.py`, `api/v1/statistics.py`, `api/v1/router.py`, `tests/api/test_statistics.py` | Provide access to the DOSM datasets in `Final_Location_Analysis` without polluting the app's ORM metadata. |

## 6. Open architectural recommendations (not executed — require product decision)

- **Schema alignment with `Final_Location_Analysis`.** The backend currently
  targets `sitesense.public`. If the intended system of record is
  `Final_Location_Analysis` (with `fyp`/`sitewise_app` schemas), the ORM models
  must be schema-qualified (`__table_args__ = {"schema": "fyp"}`) or the DB
  connection redirected. This is a larger change and should be confirmed by the
  user before execution.
- **Introduce repository interfaces (ports)** in `domain` or an `application/ports`
  module so the application layer depends on abstractions, satisfying strict
  Clean Architecture rule #3.
- **Implement the suitability scoring** policy in `domain/suitability_engine.py`
  and wire the `ml/` modules into the recommendation use-case if ML scoring is
  in scope.
- **Integrate authentication** against `fyp.users` (or define the backend's own
  auth) — explicitly out of scope per task constraints.
