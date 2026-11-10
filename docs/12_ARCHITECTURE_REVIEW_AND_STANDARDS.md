# 12 — Architecture Boundary Review, Coding Standards & Review Checklists

- **Date:** 2026-11-09
- **Branch / HEAD:** `joel` @ `a9f4ad8` (`joel11`)
- **Reviewer role:** Senior Full-Stack Architect (read-only review)
- **Scope note:** the request contained the literal placeholder `[INSERT CODE/DIFF HERE]` and no diff was attached. `git status --short` was empty, so there were no uncommitted changes to review. The audit therefore covers **(a)** the full file set changed by `a9f4ad8` and **(b)** the current layering of `backend/src/sitewise`, `shared_logic/lib`, `fyp_jaspr_web/lib` and `fyp_mobile_app/lib`. Re-run against a supplied PR/diff to narrow the findings.
- **Method:** static import/call-graph audit and key-by-key comparison of Python response payload builders against Dart `fromJson` factories / mappers. **No source code was modified, no build and no test suite was run** for this review (the only new file is this document).

---

## 1. Verdict

| # | Rule | Verdict | Introduced / worsened in `a9f4ad8` | Pre-existing |
|---|------|---------|-----------------------------------|--------------|
| 1 | NO ORM IN THE API LAYER | **FAIL** | `explore.py`, `ml_predictions.py`, `property_verification.py`, `reports.py` | `catalog.py`, `recommendations.py`, `saved_properties.py`, `properties.py`, `staff.py`, `virtual_tours.py`, `geospatial.py`, `statistics.py`, `suitability.py`, `users.py`, `assessments.py`, `preferences.py` |
| 2 | CONTRACT MATCHING | **AT RISK** (no verified break in the wired paths; one unwired surface) | 4 new `-> dict` endpoints with no response models; `/api/v1/ml/*` has no Dart consumer | inline Pydantic request models in API files; no schemas package |
| 3 | LOGIC SEPARATION | **FAIL** | `_is_admin()` in API; scoring/thresholds/orchestration in API and `shared_logic` | `FilterProperties`, `PropertyFilter`, `api_intelligence_repository.dart` rating/scoring logic |
| 4 | DEPENDENCY INVERSION | **FAIL (4 UI files)** | `pages/admin/user_detail_page.dart` (2 calls) | 3 role `profile_page.dart` files; 18 direct `WebAuth` calls in Jaspr data layer |

**Overall:** the backend has a real service layer (10 API modules import `sitewise.services`), but it is not consistently *enforced*. The dominant anti-pattern is that endpoints receive an ORM `Session` via `Depends(get_db)` and hand it to a service constructor — or skip services entirely. The client side is better: Flutter's entire `lib/presentation` tree contains **zero** direct HTTP clients, and `WebApiClient` is a proper `ApiClient` adapter. Four Jaspr page files and one shared-logic repository are the outliers.

---

## 2. Rule 1 — NO ORM IN THE API LAYER (FAIL)

> FastAPI endpoints must call services, never `backend/db/models` or raw repositories directly.

### 2.1 New / regressed in `a9f4ad8`

| File | Evidence | Why it fails |
|------|----------|--------------|
| `api/v1/explore.py` | `:17` `from sqlmodel import Session`; `:19` `from sitewise.db.session import get_db`; `:21` `from sitewise.repositories.fyp_property_repository import FypPropertyRepository`; `:25` `DbSession = Depends(get_db)`; repository instantiated directly at `:35, :63, :92, :127, :144, :158, :171, :189` | **Most severe.** Entire module has **no `sitewise.services` import at all**. All 9 endpoints are thin repository wrappers; the API owns the DB session and the repository. All filter composition, gating semantics, 404 policy and `meta.available` derivation live in the endpoint. |
| `api/v1/ml_predictions.py` | `:11` `Session`; `:14` `get_analytics_db`; `:16-18` `ModelLoader`, `FeatureResolutionError`, `PropertyPUPredictor`; `:21` `AnalyticsSession = Annotated[Session, Depends(get_analytics_db)]`; used at `:27, :51, :66` | No service layer. ML orchestration, error-to-payload policy and score semantics are implemented in the endpoint. |
| `api/v1/property_verification.py` | `:19` `Session`; `:21` `get_db`; `:40` `DbSession = Annotated[Session, Depends(get_db)]` | **Partial credit:** every handler *does* delegate to `PropertyVerificationService` / `AdminPropertyReviewService` (`:30-34`, `:78, :91, :111, :133, :168, :188, :198, :212, :224, :236`). The remaining violation is that the API still acquires and injects the ORM session instead of a service dependency. |
| `api/v1/reports.py` | `:2` `Session`; `:5` `get_db`; `:13` `session: Session = Depends(get_db)`; `:21` `ReportService(session)` | Correct delegation, wrong ownership of the session. |

### 2.2 Pre-existing (still active)

- `api/v1/catalog.py:18-23,47,49` — `text()` raw SQL executed **inside** the endpoint plus `CatalogRepository` / `PROPERTY_COLUMNS` imports.
- `api/v1/recommendations.py:4,6,66` — `select(RecommendationResult)` on an ORM model imported into the API and `session.exec(...)` in the handler.
- `api/v1/saved_properties.py:21-28,160` — `FavouriteProperty` ORM import, two repository imports, `session.exec(...)`.
- `api/v1/properties.py:4,7,43-45` — `RentalProperty` ORM import, inline `from sqlmodel import select`, `session.exec(...)`.
- `api/v1/staff.py:26,29` — `User` ORM import; 6 handlers declare `session: Session = Depends(get_db)`.
- `api/v1/virtual_tours.py:7`, `api/v1/geospatial.py:5` — ORM model / repository imports.
- `Session = Depends(get_db)` in handler signatures: `users.py` (6), `statistics.py` (2), `suitability.py`, `geospatial.py` (4), `virtual_tours.py` (5), `assessments.py` (2 aliases), `preferences.py`.

### 2.3 Target shape

```python
# api/v1/explore.py — compliant
from fastapi import APIRouter, Depends
from sitewise.dependencies import CurrentUser
from sitewise.services.explore_service import ExploreService

router = APIRouter()

def get_explore_service() -> ExploreService:
    return ExploreService()          # service owns its unit of work

@router.get("/properties")
def explore_properties(_user: CurrentUser, svc: ExploreService = Depends(get_explore_service), ...):
    return svc.list_published(ExploreQuery(...))   # no Session, no repository, no SQL here
```

`backend/services` constructs the session/repository; `backend/api/v1` sees only service interfaces and Pydantic schemas.

---

## 3. Rule 2 — CONTRACT MATCHING (AT RISK)

> FastAPI request/response models must match `shared_logic/models` and `shared_logic/services` serialization schemas exactly.

### 3.1 Structural problem

- All four new API modules annotate handlers `-> dict` and return raw dictionaries. There is **no `schemas/` package anywhere under `backend/src/sitewise`**, no `response_model=`, and no generated OpenAPI component for the new payloads. Contracts exist only as prose plus defensive Dart parsers.
- The only Pydantic `BaseModel` classes are declared **inside API files**: `DimensionRequest`, `RejectRequest`, `InformationRequest` (`property_verification.py:45-57`), `SavePreferencesRequest`, `StartAssessmentRequest`, `UpdateAssessmentRequest`, `SavePropertyRequest`, and six in `staff.py`. Dart has no corresponding request models — it builds raw `Map`s (`ApiPropertyVerificationRepository._decide`, `:101-107`).
- `RejectRequest.reason` and `InformationRequest.note` enforce `min_length=1, max_length=2000`; nothing on the Dart side encodes those limits.

### 3.2 Verified matches (key-by-key, no break found in wired paths)

| Endpoint | Python producer | Dart consumer | Result |
|---|---|---|---|
| `GET /explore/options` | `FypPropertyRepository.filter_options()` `:602-608` → `{"data": {states, cities, property_types, availability, published_total}}` | `ExplorePropertyMapper.filterOptions` `:119-125` | MATCH |
| `GET /explore/properties` | `list_published()` `:176-178` → `{"data": [...], "meta": {total, limit, offset}}` | `ApiExploreRepository.search` `:45-57` | MATCH |
| Row shape | `_LIST_COLUMNS` `:40-78` | `ExplorePropertyMapper._propertyFromRow` `:23-62` | MATCH (incl. `primary_image`, `has_research_link`, `overall_location_score`, `competitor_count_500m`) |
| `GET /explore/properties/{id}` | `explore.py:102-109` → row + `photos`, `amenities`, `listing_sources` | `ExplorePropertyMapper.detail` `:78-90+` | MATCH |
| `GET /explore/analysis` | `explore.py:217-251` → `{"data": {...geospatial_features, competitor_counts, research_link, population, catalog_suitability_score...}, "meta": {...}}` | `ApiLocationIntelligenceRepository._analysis` `:32-44`, `analysisFromJson` `:70-197` | MATCH (but see fragility below) |
| `GET /staff/properties/` | `AdminPropertyReviewService.queue()` `:426-435` → `items, total, offset, limit, counts` and flat SQL aliases `:410-415` (`price`, `property_type_normalized`, `normalized_address`, `property_status`) | `VerificationQueuePage.fromJson` `:671-699`, `VerificationQueueRow.fromJson` `:610-645` | MATCH |
| `GET /staff/properties/{id}` | `detail()` `:485-491` → `property, owner, verification, documents, history` | `VerificationDetail.fromJson` `:436-459` | MATCH |
| Verification payloads | `property_payload` / `verification_payload` / `document_payload` / `audit_payload` `:53-117` | `VerificationProperty`, `PropertyVerification`, `VerificationDocument`, `VerificationReviewEvent` `fromJson` | MATCH |
| `POST .../verification/{action}` | `DimensionRequest` / `RejectRequest` / `InformationRequest` `:45-57` | `_decide` sends `dimension`, optional `reason` / `note` `:101-107` | MATCH (no schema enforcement) |

### 3.3 Confirmed gaps / drift risks

1. **`/api/v1/ml/*` has no client contract.** Registered at `router.py:61` (comment: "implemented; was never registered"). No Dart file calls `/api/v1/ml`. `PuPrediction` (`shared_logic/.../pu_prediction.dart`) expects `positive_label_association`, `model_version`, `score_meaning`, `feature_count`, `available_features`, `missing_features`, `quality_flags`; `PuFeatureCoverage` expects `subject_id` and more. Neither has a `fromJson`, and there is no `PuPredictionRepository` implementation. `ml_predictions.py` returns whatever `PropertyPUPredictor.coverage()/predict()` emit, plus three different ad-hoc fallback shapes (`{"available": False, "reason": ..., "research_only": True}`). Wiring this up later will silently mismatch.
2. **Duplicated validation constant.** `_ALLOWED_RADII_M = (250, 500, 1000)` (`fyp_property_repository.py:28`, checked at `:373-374`, `:462-463`) is hardcoded again as `ApiExploreRepository.allowedRadiiM` (`:29`) and pre-validated client-side by `_assertRadius` (`:98-106`). The `Query` signature in `explore.py` has no enum/`Literal` constraint, so OpenAPI does not advertise the allowed values.
3. **Defensive parsers mask drift.** `ApiPropertyVerificationRepository` uses `payload['data'] is Map ? payload['data'] : payload` in four places (`:19-31, :83-85`), and `ApiLocationIntelligenceRepository._analysis` uses a double-unwrap heuristic (`:40-43`) whose `payload['data'] as Map<String, dynamic>` cast throws under any wrapper change. These make a real contract break appear as an empty screen instead of a loud failure.
4. **Wrapper inconsistency.** `/explore/options` wraps in `{"data": ...}` while `/explore/properties` returns `{"data": ..., "meta": ...}` unwrapped from the repository, and `/staff/properties/` returns a bare object. Three envelope conventions increase the chance of a future mismatch.

---

## 4. Rule 3 — LOGIC SEPARATION (FAIL)

> The UI or `shared_logic` must not contain business rules, permissions, or complex calculations. Those belong exclusively in `backend/services`.

`shared_logic/lib/src/data/repositories/api_intelligence_repository.dart` is the clearest violation — it is a **repository implementation that computes the product's decision-support output**:

- `:46-51` `_rating(double)` — hardcoded 75 / 60 / 45 score bands.
- `:55-59` `_competitionRating(int)` — `<=15 Strong`, `<=40 Moderate`, else `Weak`, with `Impact` values.
- `:61-67` `_populationRating(double?)` — 50 000 / 15 000 / 5 000 thresholds.
- `:70-197` `analysisFromJson` — synthesizes `suitabilityScore`, invents factor scores (85/70/50/30 and 80/55/30), clamps `accessibility`, divides income by 100, and composes `evidence`, `demandSummary` and `socioeconomicSummary` strings.
- `:204-224` `getExplanation` — derives `strengths` / `considerations` and authors the recommendation summary.

The file's own comment calls these "display thresholds", but they materially determine what the user is told about a site. Under the stated rule this must be returned by `backend/services` as a fully-formed `LocationAnalysis` payload; the Dart side should only deserialize.

`shared_logic/lib/src/application/usecases/filter_properties.dart:3-9` is self-documenting evidence: *"It is a genuine business rule — the definition of 'matches' — so it belongs in the shared application layer"*. That is exactly what Rule 3 forbids. `property_filter.dart:18-71` likewise owns `"does this property match"`, chip generation and currency formatting.

**Permission logic in the API layer:** `api/v1/property_verification.py:59-62`

```python
def _is_admin(user: AuthenticatedUser) -> bool:
    return rbac.can_administer_users(user.role) and user.assurance_level == "aal2"
```

This re-derives administrative authority inside the endpoint and passes it into services as a boolean. A boolean handed in by the transport layer is not an authorization boundary — it belongs in `backend/services` (or a dependency the service resolves), never computed in `api/v1`. Note the staff surface itself is correctly protected by `require_admin_mfa` (`:42`), so this is a layering defect rather than an immediate privilege-escalation hole, but it is the pattern that produces one.

**Orchestration in endpoints:** `explore.py:189-251` resolves references, decides when to use precomputed vs live counts, and computes `meta.available`; `ml_predictions.py:24-76` decides score semantics and error policy.

---

## 5. Rule 4 — DEPENDENCY INVERSION (FAIL for 4 UI files)

> The UI should only invoke `shared_logic/repositories` functions. It must not instantiate direct HTTP clients or bypass the service layer.

### 5.1 Violations — Jaspr pages calling the transport directly

| File | Lines | Calls |
|---|---|---|
| `fyp_jaspr_web/lib/pages/admin/user_detail_page.dart` | `:91`, `:125` | `WebAuth.request(GET /api/v1/users/{id})`, `WebAuth.request(PATCH ...)` |
| `fyp_jaspr_web/lib/pages/admin/profile_page.dart` | `:96` | `WebAuth.request(...)` |
| `fyp_jaspr_web/lib/pages/owner/profile_page.dart` | `:92` | `WebAuth.request(...)` |
| `fyp_jaspr_web/lib/pages/entrepreneur/profile_page.dart` | `:89` | `WebAuth.request(...)` |

These bypass `AppLocator`, the `ApiClient` port and `shared_logic` repositories. `user_detail_page.dart:84-88` documents *why*: `SitewiseUser` does not expose `phone_number` / `last_login`, and that page was rewritten under a strict "modify only this one file" constraint. That constraint is now the cause of the violation — the correct fix is to add the two fields to the shared model and route the read/save through `UserRepository` once the constraint is lifted. The `PATCH` also implements server-echo confirmation (`:135-140`) in the widget, which is a business rule in the UI.

### 5.2 Compliant / acceptable

- `fyp_mobile_app/lib/presentation/**` — **no matches** for `HttpClient`, `http.Client`, `IOClient`, `dart:io`, `package:http`. Clean.
- `fyp_jaspr_web/lib/data/web_api_client.dart` — the single `ApiClient` adapter; `app_locator.dart` wires all `Api*Repository` implementations through it (`:38, :50, :57, :63, :91`). Correct composition root.
- `fyp_jaspr_web/lib/data/auth_stub.dart`, `staff_guard.dart`, `api_proxy.dart` — server-only proxy/bootstrap code that legitimately constructs `http.Client` / `HttpClient`; `api_proxy.dart:9` explicitly says "never imported by client code". Exempt, but must be recorded as an allowed exception in the standards.

### 5.3 Secondary smell (weaker finding)

18 `WebAuth.request` / `requestDetailed` calls live in Jaspr's **data** layer outside `WebApiClient`: `admin_api.dart` (11), `assessment_api.dart` (4), `api_property_repository.dart` (2), `location_evidence_api.dart` (1). These are not UI (so not a strict Rule 4 breach), but they bypass the shared `ApiClient` port and create a second transport path. Consolidate onto `WebApiClient` so bearer handling, error classification and `data` unwrapping have exactly one implementation.

---

## 6. Prioritised remediation plan

| P | Action | Files |
|---|--------|-------|
| P0 | Add `backend/src/sitewise/services/explore_service.py`; move all `FypPropertyRepository` construction, filter composition, gating and `meta` shaping into it. Make `explore.py` depend on the service only. | `api/v1/explore.py` (new service) |
| P0 | Move `_is_admin` authority derivation into the verification services; pass the authenticated principal, not a boolean. | `api/v1/property_verification.py`, `services/property_verification_service.py` |
| P0 | Move the four page-level `WebAuth.request` calls behind `shared_logic` repository methods; extend `SitewiseUser` with `phone_number` / `last_login`. | 4 page files, `shared_logic/.../user_model.dart`, `api_user_repository.dart` |
| P1 | Create `backend/src/sitewise/schemas/` with Pydantic request+response models for explore, verification and ml; add `response_model=` to every endpoint; publish one envelope convention. | all new API modules |
| P1 | Move `_rating` / `_competitionRating` / `_populationRating` / `analysisFromJson` / `getExplanation` into `backend/services`, returning a ready-to-render payload; reduce Dart to `fromJson`. | `api_intelligence_repository.dart` |
| P1 | Remove `Session` / `get_db` from handler signatures across all 19 API files; services own the unit of work. | all `api/v1/*.py` |
| P1 | Move `FilterProperties` / `PropertyFilter` matching rules to `backend/services` and expose a filtered endpoint; keep only chip/label formatting client-side. | `shared_logic/.../usecases/*` |
| P2 | Either implement `PuPredictionRepository` against `/api/v1/ml/*` with matching schemas, or remove the router registration until a consumer exists. | `ml_predictions.py`, `router.py:61`, `pu_prediction.dart` |
| P2 | Derive allowed radii from one published schema (or an OpenAPI enum); delete `ApiExploreRepository.allowedRadiiM`. | both sides |
| P2 | Route all Jaspr data-layer calls through `WebApiClient`; retire the direct `WebAuth` path outside the adapter. | 4 data files |

---

# 7. Coding Standards (normative)

Applies to `backend/`, `shared_logic/`, `fyp_jaspr_web/`, `fyp_mobile_app/`. Keywords MUST / MUST NOT / SHOULD are normative.

## 7.1 Layer definitions and allowed imports

| Layer | Responsibility | MAY import | MUST NOT import |
|---|---|---|---|
| `backend/db/models` | ORM entities & mapping only | `sqlmodel`, `sqlalchemy`, other models | services, api, repositories, FastAPI |
| `backend/repositories` | SQL queries & CRUD only | `db/models`, `db/session`, `sqlalchemy.text` | `api`, `services`, FastAPI `HTTPException` |
| `backend/services` | **All** business logic, permissions, scoring, recommendations, orchestration, unit of work | `db/models`, `repositories`, `db/session`, `core`, `domain` | `api/v1` (no reverse dependency), FastAPI request objects |
| `backend/api/v1` | HTTP transport: auth dependencies, request validation, status codes, serialization | `schemas`, `services`, `dependencies`, `fastapi` | `db/models`, `repositories`, `db/session`, `sqlmodel`, `sqlalchemy`, `Session`, `Depends(get_db)` |
| `backend/schemas` | Pydantic request/response contracts (single source of truth) | `pydantic`, `domain` enums | everything else |
| `shared_logic/models` + `data/models` + `data/dtos` | Dart data shapes, `fromJson` / `toJson` only | pure Dart | `dart:io`, `dart:html`, `package:http`, Flutter, Jaspr |
| `shared_logic/repositories` | Abstract contracts + `ApiClient`-backed implementations; transport & deserialization only | `core/network/api_client.dart`, `data/mappers` | direct HTTP clients, business rules, scoring, permissions |
| `shared_logic/services` | Reusable API communication & shared domain plumbing | `core/network`, `models` | business rules, permissions, complex calculation |
| `fyp_jaspr_web/lib/data` + `fyp_mobile_app/lib/data` | Platform adapters (`ApiClient` implementations, auth bridge) | `dart:io` / `dart:html` / `package:http` **here only** | — |
| `lib/pages`, `lib/components`, `lib/presentation` | Render state, dispatch to repositories | `shared_logic` repositories/entities, theme | `WebAuth`, `HttpClient`, `package:http`, SQL, ORM, business rules |

## 7.2 Backend standards

1. A route handler MUST NOT contain the token `Session`, `Depends(get_db)`, `Depends(get_analytics_db)`, `session.exec`, `session.execute`, `select(`, or `text(`.
2. A route handler MUST call exactly one service method per business operation. Two service calls in one handler require a service-level facade.
3. Every request body MUST be a `BaseModel` declared in `backend/schemas/`, not inline in an API file.
4. Every response MUST declare `response_model=` (or an explicit return annotation referencing a `schemas` class). `-> dict` is FORBIDDEN for new endpoints.
5. All responses MUST use ONE envelope. Adopt: `{"data": <payload>, "meta": {...}?}` for collections and single objects; error responses use FastAPI's `{"detail": ...}`. No bare objects mixed with wrapped objects inside the same router.
6. Authorization MUST be resolved in `backend/services` or in a dependency that produces a typed principal. Endpoints MUST NOT compute `is_admin`-style booleans and MUST NOT pass booleans as authority.
7. Enum vocabularies (roles, statuses, dimensions, radii) MUST be defined once in `domain`/`schemas` and exposed through OpenAPI (`Literal` / `Enum`), never duplicated in a repository constant and a Dart constant.
8. Repositories MUST NOT raise `HTTPException`; they raise domain errors which the API maps to status codes.
9. Business thresholds, weights, score bands and derived narrative text MUST live in `backend/services` and be unit-tested there.

## 7.3 Dart / `shared_logic` standards

1. `shared_logic` MUST remain pure Dart: no `dart:io`, `dart:html`, Flutter, Jaspr, or `package:http`.
2. Repository implementations MUST depend only on the abstract `ApiClient` port. They MUST NOT instantiate `HttpClient`, `http.Client`, `Dio`, or call `WebAuth` / `Supabase`.
3. `fromJson` / mappers MUST be total and defensive but MUST NOT silently substitute business defaults (`?? 0` for a missing *business* value is forbidden; `null` stays `null`). A changed key MUST surface as a visible state or a typed failure, not as an empty screen.
4. Client-side validation MAY check shape/format but MUST NOT re-encode server business limits. Limits come from the schema.
5. No scoring, rating, ranking, permission check, or complex calculation in `shared_logic` or UI. Deserialize and render.
6. UI MUST obtain data through `shared_logic` repositories resolved at the composition root (`AppLocator` / `sitewiseOverrides`). UI MUST NOT import a data-layer transport class.
7. Exactly one `ApiClient` implementation per platform (`WebApiClient`, `MobileApiClient`). All HTTP for that platform flows through it.
8. Entities MUST NOT be modified to fit a single page; add fields to the shared model + repository contract instead.

## 7.4 Contract-change protocol

Any change to a request/response shape MUST, in the **same commit**:
1. update the Pydantic schema in `backend/schemas/`,
2. update the Dart `fromJson` / `toJson` / mapper,
3. update or add a golden-JSON fixture test on both sides,
4. bump the endpoint version or document backward compatibility,
5. run the contract checklist in §8.3.

A green `dart analyze` or a passing Python import is **not** evidence of a matching contract.

## 7.5 Allowed exceptions (must be documented in-code)

- `fyp_jaspr_web/lib/data/api_proxy.dart`, `auth_stub.dart`, `staff_guard.dart` — server-only bootstrap/proxy, may construct `http.Client` / `HttpClient`; MUST carry the "server-only, never imported by client code" comment.
- `fyp_mobile_app/lib/data/datasources/local/` — platform secure storage, may use `dart:io`.
- Composition roots (`app_locator.dart`, `service_locator.dart`, `providers.dart`) — the only places allowed to `new` a repository implementation.

---

# 8. Review Checklists

## 8.1 PR author checklist

- [ ] No `Session`, `get_db`, `sqlmodel`, `sqlalchemy`, `select(`, `text(` or `session.exec/execute` in any file under `api/v1`.
- [ ] No `sitewise.db.models.*` or `sitewise.repositories.*` import in any file under `api/v1`.
- [ ] Every new endpoint has a `schemas/` request model (if it has a body) and a `response_model`.
- [ ] Every response uses the standard `{"data": ..., "meta": ...}` envelope.
- [ ] Every new/changed field is reflected in the Dart model, mapper and a golden fixture.
- [ ] No enum/status/radius vocabulary duplicated between Python and Dart.
- [ ] No scoring, rating, permission check or threshold in `shared_logic` or UI.
- [ ] No UI file imports `WebAuth`, `HttpClient`, `package:http`, `dart:io` or a data-layer transport class.
- [ ] No `-> dict` handler added.
- [ ] Any new API route has a `shared_logic` repository consumer (no orphan endpoints).
- [ ] `dart analyze` clean for touched Dart; `pytest` for touched Python services/API.

## 8.2 Reviewer checklist — by rule

**Rule 1 — no ORM in API**
- [ ] `grep -nE "sqlmodel|sqlalchemy|db\.models|repositories|Depends\(get_(analytics_)?db\)|session\.(exec|execute)" backend/src/sitewise/api/v1/` returns nothing for new lines.
- [ ] Each handler delegates to exactly one service method.
- [ ] The session/unit of work is constructed in `services`, not in the route.
- [ ] Repository errors are domain errors, not `HTTPException`.

**Rule 2 — contract matching**
- [ ] `response_model` present and matches the JSON the service actually returns.
- [ ] Field names, nullability and types compared **key by key** against Dart `fromJson`.
- [ ] Envelope consistent with sibling endpoints.
- [ ] Enums/literals identical on both sides (`wire` values in Dart vs `Literal`/`Enum` in Python).
- [ ] Golden-JSON test added/updated on both sides.
- [ ] No `?? 0` / `?? ''` hiding a missing business field.

**Rule 3 — logic separation**
- [ ] No `_is_admin`, `can_*`, role check or `assurance_level` comparison in `api/v1`.
- [ ] No threshold, weight, score band, ranking or derived narrative in `shared_logic` / UI.
- [ ] "matches" / filtering rules are server-side.
- [ ] Client validation is shape-only, not a copy of server limits.

**Rule 4 — dependency inversion**
- [ ] `grep -rnE "WebAuth\.|HttpClient\(|http\.Client\(|IOClient\(|dart:io|package:http" fyp_jaspr_web/lib/pages fyp_jaspr_web/lib/components fyp_mobile_app/lib/presentation` returns nothing.
- [ ] All new calls go through a `shared_logic` repository resolved at the composition root.
- [ ] Only one `ApiClient` implementation per platform receives the new call.

## 8.3 Contract-change checklist (run for every payload edit)

- [ ] List every added / removed / renamed / retyped key in a table in the PR description.
- [ ] Update `backend/schemas/` **and** Dart `fromJson` **and** the mapper in the same commit.
- [ ] Add a golden fixture containing `null`, `0`, an empty list and a missing optional key.
- [ ] Confirm a missing key produces a visible "not provided" state, not a fabricated value.
- [ ] Confirm no other consumer (Jaspr page, Flutter page, mobile repository) reads the old key.
- [ ] Version or deprecate the endpoint if a breaking rename is unavoidable.

## 8.4 CI enforcement (recommended, cheap to add)

Add a fast static gate before tests — no build required:

```bash
# Rule 1: forbid ORM / repository / session access in the API layer
! grep -rnE "from (sqlmodel|sqlalchemy)|sitewise\.db\.models|sitewise\.repositories|Depends\(get_(analytics_)?db\)|session\.(exec|execute)\(" \
    backend/src/sitewise/api/v1/

# Rule 4: forbid transport clients in UI trees
! grep -rnE "WebAuth\.|HttpClient\(|http\.Client\(|IOClient\(|dart:io|package:http" \
    fyp_jaspr_web/lib/pages fyp_jaspr_web/lib/components fyp_mobile_app/lib/presentation

# Rule 2: forbid untyped new endpoints
! grep -rn "def .*-> dict" backend/src/sitewise/api/v1/
```

Suggested follow-ups: a `ruff` custom rule / `import-linter` contract for the Python layer graph, and a Dart `dart analyze` custom lint banning `package:http` outside `data/`.

## 8.5 Release gate

- [ ] All P0 items from §6 closed.
- [ ] All four rules pass the CI gate above on the full tree (baseline the pre-existing violations with a documented, time-boxed waiver list).
- [ ] OpenAPI schema regenerated and diffed against the previous release; any breaking diff approved.
- [ ] One end-to-end probe per changed endpoint exercising 200 / 401 / 403 / 404 / 422.

---

## Appendix A — Audit commands used

```bash
git status --short; git log -1 --oneline; git show --name-status --format="" HEAD
grep -rnE "^\s*(from|import)\s+(sitewise\.db\.models|sitewise\.repositories|sqlmodel|sqlalchemy)|Depends\(get_db\)|session\.(exec|execute)\(" backend/src/sitewise/api/v1/
grep -rnE "^\s*from\s+sitewise\.services" backend/src/sitewise/api/v1/
grep -rnE "WebAuth\.request|HttpClient\(|http\.Client\(|IOClient\(|dart:io|dart:html|package:http" fyp_jaspr_web/lib/
grep -rnE "HttpClient\(|http\.Client\(|IOClient\(|dart:io|package:http" fyp_mobile_app/lib/presentation/
grep -rnE "class .*\(BaseModel\)" backend/src/sitewise/
```

## Appendix B — Findings not covered / limitations

- No dynamic analysis, runtime request capture, or OpenAPI generation was performed; findings are static.
- The `[INSERT CODE/DIFF HERE]` placeholder means this is a whole-tree baseline, not a PR-specific review. Supply a diff for a narrower, actionable PR verdict.
- Pre-existing violations are reported for completeness; they are not regressions introduced by `a9f4ad8`.
- `shared_logic/lib/src/application/services/*`, `domain/usecases/*` and `application/notifiers/*` were sampled (`filter_properties.dart`, `property_filter.dart`) rather than exhaustively audited; a full Rule 3 sweep of those directories is recommended.
