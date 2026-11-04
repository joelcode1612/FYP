# 03 — FastAPI Clean Architecture

## Dependency direction (preserved and enforced by tests)

```
api/v1 (presentation: routes, HTTP errors, auth dependencies)
   → services (application: use-cases, ownership checks, profile rules)
      → domain (pure business rules: rbac.py, suitability_engine.py, ranking.py)
   → repositories / db / core.security (infrastructure)
domain imports NOTHING from fastapi / supabase / sqlmodel / sqlalchemy
(test_architecture.py::test_domain_has_no_framework_dependencies)
```

## What was added, per layer

| Layer | File | Responsibility |
|---|---|---|
| Presentation | `api/v1/auth.py` (new) | `GET /auth/me`, `GET /auth/session` |
| Presentation | `api/v1/users.py` (rewritten) | `/users/me*` self-service; admin-guarded user routes; direct creation disabled (410) |
| Presentation | `dependencies.py` (rewritten) | `bearer_token`, `get_current_user`, `get_active_user`, `require_roles` factory, `require_entrepreneur/property_owner/agent/admin`; verifier construction (JWKS primary, userinfo fallback) |
| Presentation | `main.py` | Auth error mapping (401/403/404/503), non-leaking 500 |
| Application | `services/user_service.py` | `get_or_sync_current` (provision + mirror verification), `update_own_profile` (field rules via domain) |
| Domain | `domain/rbac.py` (new) | Roles, matrices, statuses, self-editable vs protected profile fields — pure functions |
| Domain | `domain/suitability_engine.py` (rewritten) | Honest unavailable-assessment envelope |
| Infrastructure | `core/security.py` (new) | `JWKSClient`, `SupabaseJWTVerifier`, `SupabaseUserinfoVerifier` |
| Infrastructure | `ml/model_loader.py`, `ml/pu_learning.py`, `ml/shap_explainer.py` (rewritten) | Artifact loading/validation, inference contract, guarded SHAP — all raise `ModelUnavailableError` when prerequisites are missing |
| Infrastructure | `repositories/user_repository.py` | `get_or_create_from_supabase` (race-safe via PK/unique constraints) |

## Composition root

`main.py` remains the single wiring point: settings → engines → routers →
exception handlers. Dependencies resolve through FastAPI `Depends`; services
receive a `Session` and construct their repositories (existing convention kept
per the brief's "do not reorganize for naming consistency").

## Error mapping

| Exception | HTTP |
|---|---|
| `AuthError` | 401 |
| `AuthUnavailableError` | 503 |
| `ForbiddenError` / `ForbiddenActionError` | 403 |
| `NotFoundError` | 404 |
| `ModelUnavailableError` | 503 |
| unhandled `Exception` | 500 with a generic message (details logged, never returned) |
