# PROJECT1 — Frontend ↔ Backend API Integration (CP-00 + Assessment Workspace)

**Repository:** `C:\Users\HP\OneDrive\Desktop\sport-marketplace\FYP`
**Branch / HEAD:** `merge_main_jed` @ `ba30035`
**Date:** 2026-11-16
**Scope of this pass:** CP-00 inventory, M2/CQ database-binding verification, and source-supported
integration of the active assessment flow. No customer publication or fielding was enabled.

---

## 0. How to read the statuses

| Status | Meaning in this document |
|---|---|
| `REAL_API_CONNECTED` | A typed client method exists **and** calls a route that is present in the mounted router composition. Runtime behaviour is **not** proven here. |
| `VERIFIED_END_TO_END` | Browser interaction → HTTP → service → PostgreSQL → response → UI → reload persistence, all observed. **None in this pass.** |
| `MOCK_DATA_ONLY` | The active surface renders fixture/demo data. |
| `HARDCODED_FALLBACK` | A failure path substitutes invented data. |
| `LOCAL_STATE_ONLY` | User action mutates in-memory or cookie state; nothing is persisted. |
| `API_EXISTS_NOT_CONNECTED` | A route exists but no active screen calls it. |
| `API_NOT_REGISTERED` | No route exists in the mounted composition. |
| `CONTRACT_MISMATCH` | Client and server disagree on shape, ID space, or semantics. |
| `AUTHORIZATION_BLOCKED` | The route exists but refuses by design (hold / unverified authority). |

**Runtime verification was not possible in this pass.** No FastAPI listener was running on the
checked ports, and the configured database principal is a PostgreSQL **superuser**, which the
task's own safeguards forbid using as the runtime identity. Every `REAL_API_CONNECTED` row is
therefore source-verified only.

---

## 1. Database bindings — verified (read-only)

Read-only probe (`BEGIN READ ONLY`) against both local databases, using the credentials already
configured in `backend/.env`. No password was printed.

| Fact | Observed value |
|---|---|
| `DATABASE_URL` target | `localhost:5432/Final_Location_Analysis` |
| Configured role | `postgres` — **`rolsuper = true`, `rolbypassrls = true`** |
| `M2_DATABASE_URL` | EMPTY |
| `EE01_DATABASE_URL` | EMPTY |
| `PROJECT1_RUNTIME_DATABASE_URL` | EMPTY |
| `M2_UPSTREAM_ENABLED` | not set |
| `CQ_RUNTIME_ENABLED` | not set |
| `PROJECT1_WORKFLOW_ENABLED` | not set |
| `TOKENHARBOR_ENABLED` | not set |

| Database | `m2_assessments` | `m2_*` tables | `cq_*` tables | `project1_ai` schema | `fyp` schema | `p1_ee01_runtime` role |
|---|---|---|---|---|---|---|
| `Final_Location_Analysis` | absent | 0 | 0 | absent | **present** | present |
| `Dss` | **present** | **19** | **25** | **absent** | absent | present |

### What this means

1. **The M2/CQ schema is physically in `Dss` and is substantial** (19 M2 tables, 25 CQ tables,
   `m2_assessments` present). The migration work exists; the application cannot reach it.
2. **The application cannot bind to `Dss`.** `sitewise/db/m2_session.py:17` falls back to
   `settings.database_url` when `m2_database_url` is empty, then requires
   `url.database == settings.m2_expected_database` (`'Dss'`). The configured URL names
   `Final_Location_Analysis`, so every M2 and CQ dependency raises
   `M2_DATABASE_TARGET_UNVERIFIED` (503). CQ reuses the same engine
   (`customer_questionnaire.py:26`), so CQ is blocked by the same defect.
3. **EE-01 is separately unbound.** `customer_questionnaire.py:49-54` additionally requires
   `ee01_database_url` to name `Dss` **and** user `p1_ee01_runtime`. The variable is empty → 503.
4. **The runtime identity is a superuser.** `postgres` with `BYPASSRLS` defeats the RLS design in
   `migrations/project1_ai/20261111_01_candidate_ledger.sql` and is exactly what the brief
   prohibits. This is a configuration defect, not a code defect.
5. **The workflow attempt ledger does not exist.** `project1_ai` is absent in `Dss` and the
   `p1ai_runtime` role does not exist, so `PostgresAttemptLedger._scope()` would refuse even if
   the schema existed. Any live model dispatch is therefore unrecordable — a hard blocker for a
   real BDJ/QJ model run.

### Required configuration (not applied — operator action)

```
M2_DATABASE_URL=postgresql+psycopg2://<non-superuser>@localhost:5432/Dss
EE01_DATABASE_URL=postgresql+psycopg2://p1_ee01_runtime@localhost:5432/Dss
M2_UPSTREAM_ENABLED=true
```

Plus: a non-superuser application role for `DATABASE_URL`, and the `project1_ai` migration applied
with a reviewed receipt before any model call can be ledgered.

---

## 2. D1 — Frontend-to-Backend API Mapping Matrix

### 2.1 Jaspr web — authentication and shell

| # | Page / component | User action or data | Endpoint | Method | Current source | Status |
|---|---|---|---|---|---|---|
| 1 | Sign-in / session | Password sign-in, session restore | Supabase SDK → `GET /api/v1/auth/me` | GET | `auth_client.js`, `auth_browser.dart` | `REAL_API_CONNECTED` |
| 2 | Router role guard | Anonymous/wrong-role redirect | — (client guard over verified profile) | — | `app.dart:131-173` | `REAL_API_CONNECTED` |
| 3 | Dev bypass | Local preview identity | none (no token issued) | — | `dev_auth_bypass.dart` | `LOCAL_STATE_ONLY` |

### 2.2 Jaspr web — dashboard

| # | Component | Data | Endpoint | Method | Status |
|---|---|---|---|---|---|
| 4 | Dashboard greeting | Verified profile name | `GET /auth/me` (session) | GET | `REAL_API_CONNECTED` |
| 5 | Saved KPI | Saved property count | `GET /saved-properties/me` | GET | `REAL_API_CONNECTED` (visitor: `LOCAL_STATE_ONLY` cookie) |
| 6 | Catalogue KPI | Property total | `GET /catalog/properties` | GET | `REAL_API_CONNECTED` |
| 7 | Current assessment card | Most recent assessment | `GET /assessments/me/current` | GET | `REAL_API_CONNECTED` |
| 8 | Recent assessments | History rows | `GET /assessments/me` | GET | `REAL_API_CONNECTED` |
| 9 | “Continue / Review” links | Navigate to workspace | `/entrepreneur/assessments?id=` | — | **fixed this pass** (was `API_NOT_REGISTERED` — singular path never routed) |

### 2.3 Jaspr web — properties

| # | Component | Data / action | Endpoint | Method | Status |
|---|---|---|---|---|---|
| 10 | Recommendations list | Ranked search | `POST /recommendations/search` | POST | `REAL_API_CONNECTED` |
| 11 | Recommendations facets | Counts | `GET /recommendations/facets` | GET | `REAL_API_CONNECTED` |
| 12 | Property detail | Catalogue record | `GET /catalog/properties/{id}` | GET | `REAL_API_CONNECTED` |
| 13 | Evidence panel | Measured evidence | `GET /catalog/properties/{id}/evidence` | GET | `REAL_API_CONNECTED` |
| 14 | Insights panel | PU score, coverage | `GET /catalog/properties/{id}/insights` | GET | `REAL_API_CONNECTED` |
| 15 | Save / unsave | Shortlist | `POST /saved-properties/`, `DELETE /saved-properties/me/{ref}` | POST/DELETE | `REAL_API_CONNECTED` |
| 16 | Compare tray | Selected set | none | — | `LOCAL_STATE_ONLY` |
| 17 | Preferences form | Read/write preferences | `GET/PATCH /preferences/me` | GET/PATCH | `REAL_API_CONNECTED` |
| 18 | “Assess” CTA (detail, search, AI recs, map) | Open workspace | `/entrepreneur/assessments?id=` | — | **fixed this pass** (6 links across 4 files) |
| 19 | Map / Explore | Catalogue + analysis | `GET /catalog/properties`, `GET /explore/analysis?ref=` | GET | `REAL_API_CONNECTED` |

### 2.4 Jaspr web — assessment workspace (`/entrepreneur/assessments`)

| # | Stage | Action | Endpoint | Method | Status |
|---|---|---|---|---|---|
| 20 | All | List own assessments | `GET /assessments/me` | GET | `REAL_API_CONNECTED` |
| 21 | All | Start / resume | `POST /assessments/` | POST | `REAL_API_CONNECTED` |
| 22 | All | Open by property | `GET /assessments/by-property/{id}` | GET | `REAL_API_CONNECTED` |
| 23 | All | Delete | `DELETE /assessments/{id}` | DELETE | `REAL_API_CONNECTED` |
| 24 | Stage 2 | **Save the five answers** | `PATCH /assessments/{id}` (`requirements`) | PATCH | **fixed this pass** — was `LOCAL_STATE_ONLY` |
| 25 | Stage 2 | Complete the stage | `PATCH /assessments/{id}` (`complete_stage`) | PATCH | `REAL_API_CONNECTED` — was guaranteed `409 requirements_missing` |
| 26 | Stage 3 | Location evidence | `GET /catalog/properties/{id}/evidence` | GET | `REAL_API_CONNECTED` |
| 27 | Stage 3 | Finding refine / add note | none | — | `LOCAL_STATE_ONLY` |
| 28 | Stage 4 | Candidate approve/reject/add | none | — | `LOCAL_STATE_ONLY` |
| 29 | Report step | Assessment report | `GET /assessments/{id}/report` | GET | `REAL_API_CONNECTED` |
| 30 | Report step | PDF export | no server route (browser print) | — | `API_NOT_REGISTERED` |
| 31 | Report selector | “View report” hand-off | routes to `/entrepreneur/report?id=<property>` (property report, not assessment report) | — | `CONTRACT_MISMATCH` (open) |

### 2.5 Jaspr web — M2 / BCB / BDJ / research (new surface, this pass)

| # | Surface | Action | Endpoint | Method | Status |
|---|---|---|---|---|---|
| 32 | M2 workflow | List saved M2 assessments | `GET /m2/assessments` | GET | `REAL_API_CONNECTED` (gated) |
| 33 | M2 workflow | List authorized instruments | `GET /m2/instruments` | GET | `REAL_API_CONNECTED` (gated) |
| 34 | M2 workflow | Create M2 assessment | `POST /m2/assessments` | POST | `REAL_API_CONNECTED` (gated) |
| 35 | M2 workflow | Load items + saved answers | `GET /m2/assessments/{id}` | GET | `REAL_API_CONNECTED` (gated) |
| 36 | M2 workflow | Save one answer | `PUT /m2/assessments/{id}/answers/{item_key}` | PUT | `REAL_API_CONNECTED` (gated) |
| 37 | M2 workflow | Run candidate BDJ + read worksheet | `POST /m2/assessments/{id}/bdj/evaluate`, `GET .../business-understanding` | POST/GET | `REAL_API_CONNECTED` (deterministic ruleset, **not** a model call) |
| 38 | M2 workflow | Record review + confirmation | `POST /m2/assessments/{id}/review`, `.../confirm` | POST | `REAL_API_CONNECTED` (gated) |
| 39 | M2 workflow | Business-context status | `GET /m2/assessments/{id}/confirmations/{cid}/business-context-status` | GET | `AUTHORIZATION_BLOCKED` — live dependency is `UnverifiedContextBindings`, which raises by design |
| 40 | M2 workflow | Save research objective | `POST /m2/confirmations/{cid}/research-objectives` | POST | `REAL_API_CONNECTED` (gated) |
| 41 | M2 workflow | Read QJ context | `GET /m2/research-objectives/{oid}/qj-context` | GET | `REAL_API_CONNECTED` — a **read**, not execution |
| 42 | M2 workflow | QJ execution | none | — | `API_NOT_REGISTERED` |
| 43 | M2 workflow | QG drafting / bank reuse | none | — | `API_NOT_REGISTERED` |
| 44 | Candidate review | Entrepreneur/owner review of a candidate | `GET /m2/research-questions/{v}/entrepreneur-review`, `POST .../owner-review` | GET/POST | `API_EXISTS_NOT_CONNECTED` (no active screen) |
| 45 | Activity History | Read-only M2 events | `GET /m2/assessments/{id}/activity` | GET | `REAL_API_CONNECTED` |
| 46 | Activity History | BDJ cloud / QJ / QG / CQ history | none | — | `API_NOT_REGISTERED` — the panel states this explicitly |

### 2.6 Jaspr web — readiness, CQ, explanations

| # | Surface | Data | Endpoint | Method | Status |
|---|---|---|---|---|---|
| 47 | Project1 readiness panel | Held artifacts | `GET /project1-read/readiness` | GET | `REAL_API_CONNECTED` |
| 48 | CQ availability | Fielding state | `GET /cq/availability` | GET | `AUTHORIZATION_BLOCKED` (returns `held`) |
| 49 | EE-01 explanation | Explanation candidate | `POST /cq/assessments/.../explanations` | POST | `API_EXISTS_NOT_CONNECTED` — flag off, 503 hold |
| 50 | Assessment explanation | Stored SHAP narrative | `GET /assessments/{id}/explanation` | GET | `REAL_API_CONNECTED` |
| 51 | CQ preview component | Q01–Q13 + QG objects | none (caller-supplied) | — | `LOCAL_STATE_ONLY` — unmounted |

### 2.7 Flutter mobile

| # | Screen | Data / action | Endpoint | Method | Status |
|---|---|---|---|---|---|
| 52 | Sign-in / restore | Auth + profile | Supabase → `GET /auth/me` | GET | `REAL_API_CONNECTED` |
| 53 | Home recommendation count | Ranked count | none — `RecommendationRepositoryImpl` over `DemoData` | — | `MOCK_DATA_ONLY` |
| 54 | Saved | Shortlist | `GET/POST/DELETE /saved-properties/*` | — | `REAL_API_CONNECTED` (conditional on `usesLiveApi`; else local) |
| 55 | Recommendations | Search + facets | `POST /recommendations/search`, `GET .../facets` | — | `REAL_API_CONNECTED` |
| 56 | Property detail | Detail lookup | `GET /explore/properties/{int}` with catalogue `EP-/MD-` IDs | GET | `CONTRACT_MISMATCH` — ID-space mismatch, no catalogue fallback |
| 57 | Preferences | Save preferences | none (local draft file) | — | `LOCAL_STATE_ONLY` |
| 58 | Compare | Selected set | none | — | `LOCAL_STATE_ONLY` |
| 59 | Assess tab | CQ invitations + session | `GET /cq/invitations`, `POST /cq/sessions`, … | — | `AUTHORIZATION_BLOCKED` (fielding hold) |
| 60 | M2 prototype form | 11 illustrative items | none — `kM2AnswerItems` | — | `MOCK_DATA_ONLY` |
| 61 | M2 API client | Full M2/BJD/BCB surface | `/m2/*` | — | `API_EXISTS_NOT_CONNECTED` (no mobile caller) |
| 62 | Provider workspace | Listings, enquiries, performance | `GET /properties/listings/mine`, `/staff/me/listings`, `/provider/*` | — | `REAL_API_CONNECTED` |
| 63 | Agent Schedule | Schedule events | none | — | `API_NOT_REGISTERED` |
| 64 | Property report | Report | no caller of `GET /reports/property/{id}` | — | `API_EXISTS_NOT_CONNECTED` |

### 2.8 Counts (64 mapped operations)

| Status | Count |
|---|---|
| `REAL_API_CONNECTED` | 41 |
| `VERIFIED_END_TO_END` | **0** |
| `MOCK_DATA_ONLY` | 2 |
| `LOCAL_STATE_ONLY` | 7 |
| `API_EXISTS_NOT_CONNECTED` | 4 |
| `API_NOT_REGISTERED` | 5 |
| `CONTRACT_MISMATCH` | 2 |
| `AUTHORIZATION_BLOCKED` | 3 |

Row 5 is counted once under `REAL_API_CONNECTED`; its visitor-only cookie path is noted in the row.
Rows 9 and 18 are client-side route hand-offs repaired in this pass, counted as connected because
they now reach a mounted route instead of an unregistered one.


---

## 3. D2 — Mock / local-state inventory (active runtime only)

| # | Location | Kind | Disposition |
|---|---|---|---|
| 1 | `fyp_mobile_app/.../entrepreneur_dashboard_mobile_page.dart` → `RecommendationRepositoryImpl` | Active runtime mock (demo catalogue ranking) | **Retained, not corrected.** Wiring it to `ApiRecommendationSearchRepository` changes a dashboard KPI's meaning; recorded as an open item. |
| 2 | `shared_logic/.../demo_data.dart` `analysisFor()` returns the first demo property for unknown IDs | Hardcoded fallback | Active only in demo builds. Not reachable when `usesLiveApi` is true. Recorded. |
| 3 | `fyp_mobile_app/.../m2_assessment_mobile_page.dart` + `m2_prototype_data.dart` | Fixture screen, self-labelled prototype | Unrouted. Not an active dependency. |
| 4 | `fyp_jaspr_web/.../customer_questionnaire_preview_page.dart` | Synthetic preview, local selections | Unmounted. Not an active dependency. |
| 5 | Jaspr assessment Stage 2 answers | **Was** local-only, and stage completion was guaranteed to fail with `409 requirements_missing` | **Corrected** — now `PATCH /assessments/{id}` with `requirements`, then `complete_stage`. |
| 6 | Jaspr assessment Stage 3 refine/add, Stage 4 candidate decisions | Local-only, self-labelled session-only | Not corrected: no backend route exists for either. Shown as unavailable rather than persisted. |
| 7 | Jaspr compare tray | Local + 8h cookie mirror | By design (no server compare resource). |
| 8 | Mobile preferences / compare / assessment summary | Local draft files, explicitly labelled on-device | Not corrected: no mobile preferences route is wired; the screen says so. |
| 9 | Tests under `fyp_jaspr_web/test`, `backend/tests` | Test fixtures | **Preserved.** No fixture deleted. |

No active runtime surface silently substitutes fabricated data on HTTP failure: the audited
failure paths show explicit error/empty states. The one previously-silent case — the Stage-2
"success" that could not have persisted — is now a real write followed by a real stage confirm.

---

## 4. D3 — Source changes in this pass

| File | Change |
|---|---|
| `fyp_jaspr_web/lib/data/assessment_api.dart` | Added `saveRequirements()` (`PATCH /assessments/{id}` with `requirements`); removed the comment that documented the missing write. |
| `fyp_jaspr_web/lib/pages/entrepreneur/assessment_workspace_page.dart` | Added `_requirementsPayload()`; `_saveAnswers()` now persists requirements **then** confirms the stage, and reports a requirements failure as a failure. |
| `fyp_jaspr_web/lib/components/m2_workflow_panel.dart` | **New.** Live M2 → BDJ → confirmation → BCB status → objective → QJ-context surface with explicit blocked states. |
| `fyp_jaspr_web/lib/app.dart` | Registered `/entrepreneur/m2-workflow`; imported the panel. |
| `fyp_jaspr_web/lib/data/navigation.dart` | Added the “M2 research” entrepreneur destination. |
| `fyp_jaspr_web/lib/pages/entrepreneur/dashboard_page.dart` | Fixed 3 broken `assess` links. |
| `fyp_jaspr_web/lib/pages/entrepreneur/recommendations_page.dart` | Fixed 2 broken `assess` links. |
| `fyp_jaspr_web/lib/pages/entrepreneur/property_detail_page.dart` | Fixed 1 broken `assess` link. |
| `fyp_jaspr_web/lib/pages/entrepreneur/ai_recommendations_page.dart` | Fixed 1 broken `assess` link. |
| `fyp_jaspr_web/lib/pages/entrepreneur/explore_page.dart` | Fixed 1 broken `assess` link. |
| `shared_logic/lib/src/data/repositories/api_m2_repository.dart` | Added `createObjective()` and `qjContext()`; both reject a response that claims QJ execution authority. |

No backend file was modified. No new endpoint was invented. No duplicate API service was created.

---

## 5. D7 — Missing backend contract register

| # | Missing capability | Consequence | Needed |
|---|---|---|---|
| 1 | QJ execution route | The objective can be saved and its context read, but no judgement can run. | A reviewed endpoint over `ResearchWorkflow.execute_objective` with disclosure, bank and authority adapters. |
| 2 | QG drafting route | No candidate question can be produced or bank-matched. | Approved-bank lookup + QG authority adapter + `persist_candidate` wiring. |
| 3 | Cloud BDJ execution route | `/project1-workflow` evaluates with `BDJEngine(rules)` and **no** model runner. | Runner composition + ledger + disclosure adapter. |
| 4 | `project1_ai` attempt ledger | No durable record of a model attempt or receipt. | Apply the reviewed migration; create `p1ai_*` roles. |
| 5 | BCB verified bindings | `UnverifiedContextBindings` raises, so persisted BCB cannot be built. | Real tenant/concept/geography/purpose resolvers. |
| 6 | Stage-3 / Stage-4 persistence | Refine notes and candidate decisions have no route. | Assessment-scoped objective/candidate resources. |
| 7 | Report PDF export | UI uses browser print. | Server-side renderer or an explicit "not offered" state. |
| 8 | Agent schedule | Mobile tab has no resource. | Schedule API, or remove the tab. |

---

## 6. D8 — Defects and risks

**Security / authorization**

- **CRITICAL (configuration):** the runtime DB principal is `postgres` with `BYPASSRLS`. Every RLS
  policy in `project1_ai` and the CQ/M2 schemas is inert under this identity.
- **CRITICAL (credential exposure):** a provider key was printed into this session by a broad code
  search. It must be revoked and rotated; the `.env` file's mtime shows it had **not** been changed
  after the exposure was reported.
- Frontend never receives DB credentials; all calls are bearer-authenticated. No API key is
  hardcoded in Dart.

**Database**

- M2 and CQ cannot bind to `Dss` (fallback resolves to `Final_Location_Analysis`).
- `project1_ai` absent → no attempt ledger → model dispatch would be unrecordable.
- EE-01 additionally requires the `p1_ee01_runtime` role; the variable is empty.

**Contract**

- Mobile property detail resolves catalogue IDs through a numeric-ID endpoint.
- Jaspr report selector hands off to the property report, not the assessment report.
- Many M2/CQ handlers return untyped dictionaries; the Dart clients compensate with hand-written
  validators, which is where drift will appear.

**UI**

- Two different "history" concepts share a sidebar area (assessment history vs M2 activity).
- Stage 3/4 remain session-only by necessity and say so on screen.

---

## 7. Verification results

| Check | Command | Result |
|---|---|---|
| Jaspr static analysis | `dart analyze lib` (fyp_jaspr_web) | **PASS** — no issues |
| Shared logic analysis | `dart analyze lib` (shared_logic) | **PASS** — no issues |
| Jaspr client build | `dart run jaspr_cli:jaspr build` | **PASS** — 2,419 outputs, `dart compile js` succeeded |
| Jaspr test suite | `dart test` | 8 failures — **identical 8 failures at HEAD baseline** (verified in a detached worktree); **no regression introduced** |
| Backend workflow tests | `pytest tests/project1` | **PASS** — 137 passed, 1 skipped, 7 subtests |
| Strict model identity | offline `httpx.MockTransport` probe | **PASS** — see §8 |
| Live BDJ model call | — | **BLOCKED** — key not rotated, ledger absent, provider disabled |
| Live QJ run | — | **BLOCKED** — no endpoint |
| DB write / persistence readback | — | **NOT PERFORMED** — superuser principal, M2 unbound |
| Browser screenshots of a live flow | — | **NOT PRODUCED** — no runnable backend under the required safeguards |

### The 8 pre-existing test failures (unchanged by this pass)

`activity_history_availability_test.dart` ×4 · `admin_users_integration_test.dart` (admin sidebar
destinations) · `project1_read_panel_test.dart` (server hold) · `staff_guard_test.dart` ×2
(retired `/owner` paths return 302, test expects 200).

---

## 8. Requirement 7 — the test-only model-identity exception

`sitewise/project1/provider.py:89-90` compares the returned envelope model against the module
constant `MODEL = 'mimo-v2.6-flash:free'`. There is no alias allowlist, no environment override,
and the only config field containing "model" is `sitewise_pu_model_variant` (an unrelated
PU-scoring setting).

Offline proof (`httpx.MockTransport`, no network):

```
REQUESTED_MODEL=mimo-v2.6-flash:free
CONFIG_FIELDS_WITH_MODEL=sitewise_pu_model_variant
ALIAS_mimo-v2.6-flash:free=ACCEPTED
ALIAS_without_free_suffix=HELD:PROVIDER_MODEL_MISMATCH
ALIAS_other_model=HELD:PROVIDER_MODEL_MISMATCH
```

**Verdict: PASS.** A returned alias is rejected, and no configuration can relax it. The test-only
exception described in the earlier brief does **not** exist in this checkout, so it cannot be
enabled in production — it would have to be written and reviewed first.

---

## 9. Final PASS / FAIL / BLOCKED

| # | Requirement | Result |
|---|---|---|
| 1 | Use only the designated checkout | **PASS** |
| 2 | Preserve uncommitted changes | **PASS** — no reset, no stash, no reverted user file |
| 3 | Verify M2/CQ bindings to `Dss` separately from the property DB | **PASS (verification)** — binding is **broken**; documented in §1 |
| 4 | Complete the mapping matrix and identify remaining runtime mocks | **PASS** — §2, §3 |
| 5 | Replace mock/local-only behaviour in the active assessment flow | **PARTIAL** — Stage 2 corrected; Stage 3/4 have no endpoint |
| 6 | Fix incorrect frontend bindings without duplicating services | **PASS** — 8 broken links, 1 impossible write, 2 missing client methods |
| 7 | Test-only model exception cannot be enabled in production | **PASS** — §8 |
| 8 | One live BDJ → objective → QJ case | **BLOCKED** — key not rotated; `project1_ai` absent; QJ route absent |
| 9 | Verify HTTP responses, DB persistence, browser display, read-only history | **BLOCKED** — no runnable backend under the required safeguards |
| 10 | Preserve model/provider receipts in the audit | **N/A** — no provider call was made, so there is nothing to preserve. No receipt is fabricated. |

**Nothing in this document is a claim of live model execution, database persistence, or end-to-end
UI verification.** The integration is source-complete for the assessment Stage 2 path and the new
M2 surface; it is runtime-unverified everywhere.
