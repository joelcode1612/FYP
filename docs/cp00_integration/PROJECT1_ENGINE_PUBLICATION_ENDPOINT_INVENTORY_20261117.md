# PROJECT1 — Engine & Publication Endpoint Inventory (revised)

Date: 2026-11-17
Repo: `sport-marketplace/FYP` · branch `merge_main_jed` · HEAD `ba30035`
Purpose: satisfy the "revised endpoint inventory" deliverable of *PROJECT1 — Resolve TokenHarbor and Missing Engine/Publication APIs*.

Safety posture for this document:
- No cloud model call was made.
- No publication record, campaign, session, or customer contact was created.
- Every status below is evidence-bounded. Where a capability does not exist, it is labelled BLOCKED rather than described as "in progress".

## 0. Live evidence

- Live server `http://127.0.0.1:8090/health` → `200`.
- Live `/openapi.json` → **198 operations across 180 paths**.
- Relevant M2/CQ/Project1/engine operations → **65** (matched on `m2|cq|project1|bdj|qj|qg|bank|publication|release|manifest|activity|ledger|attempt|workflow`).
- `POST /api/v1/m2/assessments/{id}/bdj/evaluate` is **deterministic only**: `BDJService.__init__` accepts a repository and no model runner (`backend/src/sitewise/services/bdj_service.py:18`). It is not cloud BDJ.

## 1. Status legend

| Label | Meaning |
|---|---|
| EXISTING | Present in live OpenAPI and backed by real code + persistence. |
| REGISTERED | Code exists and is importable, but the router is not mounted (feature flag false) or the route returns a permanent hold. |
| TESTED | Has focused automated evidence recorded in this workstream. |
| BLOCKED | Cannot be truthfully implemented or exercised without a named missing dependency (credential, authority, migration, or approval). |

## 2. Engine endpoints

| Capability | Status | Live route | Evidence / blocker |
|---|---|---|---|
| Deterministic BDJ evaluate | EXISTING · TESTED | `POST /api/v1/m2/assessments/{id}/bdj/evaluate` | `BDJService` repository-only; persists evaluations/findings. Deterministic ruleset, **not** cloud BDJ. |
| BDJ candidate read | EXISTING | `GET /api/v1/m2/assessments/{id}/workflow-overview`, `.../business-understanding` | Candidate findings only; no adoption. |
| Cloud BDJ execution (provider dispatch + ledger) | **BLOCKED** | — | `configured_runner()` in `project1/provider.py` has no production caller; `PostgresAttemptLedger` has no production construction; TokenHarbor key is unrotated and `tokenharbor_enabled=false`. |
| BCB construct / read | EXISTING · REGISTERED | `POST /api/v1/m2/assessments/{id}/business-context`, `GET .../business-contexts/{context_id}`, `GET .../business-context-status` | Persists contexts, but production binding resolver is `UnverifiedContextBindings` (fails closed). `qj_execution_authorized=false`, `qg_execution_authorized=false` are hard-typed. |
| Authoritative BCB source bindings | **BLOCKED** | — | No tenant/concept/GEO/purpose authority adapter exists; cannot be fabricated. |
| QJ context read | EXISTING | `GET /api/v1/m2/research-objectives/{objective_id}/qj-context` | Context projection only. |
| QJ execution | **BLOCKED** | — | `ResearchWorkflow.execute_objective` needs production authority/bank/runner adapters; only exercised via test doubles. No route. |
| Approved-bank lookup / equivalence | **BLOCKED** | — | No approved bank exists; `cq_bank_versions` has no approved seed; no lookup route. |
| QG candidate generation | **BLOCKED** | — | Needs provider (rotated key) + approved bank + disclosure/authority adapter. No route. |
| Research objective / questions | EXISTING | `POST /api/v1/m2/confirmations/{id}/research-objectives`, `.../research-questions/*` | Persisted objective + question authoring. |

## 3. Activity / history endpoints

| Capability | Status | Live route | Evidence / blocker |
|---|---|---|---|
| Persisted M2/BCB activity | EXISTING · TESTED | `GET /api/v1/m2/assessments/{id}/activity` | Returns `m2-activity/1` + `workflow-history-metadata/1`; owner-scoped; 17 events proven under `p1_m2_runtime` for the owner, none for cross-owner. |
| AI run/attempt/receipt readback | **BLOCKED (grant + code)** | — | `project1_ai.runs/attempts/attempt_receipts` exist with RLS + FORCE RLS + immutable triggers but hold 0 rows. The application role `p1_m2_runtime` has **no `USAGE ON SCHEMA project1_ai` and no `SELECT`** on those tables (`20261116_02_m2_runtime_role.sql` grants only `public` M2 tables). `p1ai_runtime`/`p1ai_audit` are NOLOGIN. A read-only projection therefore fails closed with permission-denied until a reviewed grant adds owner-scoped SELECT to the app role. |
| Cloud BDJ/QJ/QG output history | **BLOCKED** | — | No cloud execution has occurred, so there is no output to persist or display. The UI already marks these NOT_VERIFIED rather than fabricating. |

## 4. Publication endpoints

| Capability | Status | Live route | Evidence / blocker |
|---|---|---|---|
| Manifest read | EXISTING · REGISTERED | `GET /api/v1/cq/manifests/{release_id}` | Requires authority grant; `UnverifiedCqAuthority.authorize()` always refuses with `PRODUCTION_FIELDING_HOLD`. |
| Availability hold | EXISTING | `GET /api/v1/cq/availability` | `state=held`, `production_fielding_authorized=false`. |
| Campaign / participant / session runtime | EXISTING · REGISTERED | `POST /api/v1/cq/assessments/{id}/campaign`, `/campaigns/{id}/participants`, `/sessions*` | All route through `_release()` → authority, which refuses. `cq_runtime_enabled=false`. |
| Developer import/inspection | EXISTING | `/api/v1/cq/developer-imports*` | Developer inspection only; does **not** authorize fielding. |
| Publication / release creation | **BLOCKED** | — | Four hard dependencies: (1) no production manifest builder; (2) `cq_manifest_releases` has **no owner column** and no `bank_version` column (needs reviewed migration); (3) no trusted authority adapter; (4) `verify_release()` hard-refuses lane `ENTREPRENEUR_SPECIFIC`. |

## 5. Why publication cannot be built honestly yet

A creation endpoint must, at minimum, (a) be owner-scoped, (b) validate a real manifest/policy/bank/assignments via the existing `_release()` chain, and (c) obtain an authority grant before any fielding. Today:

1. **No manifest builder** — `load_sources()` returns contract/reference, not a publishable manifest. `synthetic_dss_import.py:48` only accepts `source_class='SYNTHETIC_FIXTURE'`.
2. **No owner column on releases** — `cq_manifest_releases(id, manifest_hash, policy_hash, manifest_json, policy_json, source_class)`. Owner scoping lives only at the campaign layer. Adding a column to an append-only table requires a reviewed migration.
3. **No authority adapter** — `UnverifiedCqAuthority.authorize()` raises `PRODUCTION_FIELDING_HOLD` unconditionally. Inventing a grant would fabricate scientific/Owner approval.
4. **Entrepreneur-specific lane hard-blocked** — `verify_release()` raises `CQ_ENTREPRENEUR_ASSIGNMENT_AUTHORITY_UNVERIFIED` (503) because no QJ/BCB/measurement/approved-bank adapter exists.

Building around any of these would produce a fake approval or a fake manifest. That is refused by design.

## 6. What is required to unblock (owner actions)

| # | Unblock | Enables |
|---|---|---|
| 1 | Rotate the TokenHarbor key; confirm the old key is revoked; set `tokenharbor_enabled=true` | Cloud BDJ/QJ/QG dispatch (after adapters exist) |
| 2 | Enable Chrome remote debugging (`chrome://inspect/#remote-debugging`) and sign in as the test account | Authenticated browser journey, screenshots, HTTP/DB readback |
| 3 | Approve the trusted authority adapters (disclosure, approved bank, BCB bindings, release authority) | QJ/QG execution and real publication |
| 4 | Approve an instrument + bank version for release | A manifest that can pass `verify_release` |
| 5 | Authorize a reviewed migration adding owner scoping to `cq_manifest_releases` | Owner-scoped publication persistence |
| 6 | Authorize a reviewed grant of owner-scoped `SELECT` on `project1_ai.runs/attempts/attempt_receipts` to the app role (or a dedicated LOGIN audit role) | AI ledger readback for Activity History |

## 7. Verdict summary

| Area | Verdict |
|---|---|
| Deterministic engine (BDJ/M2) | **PASS** — existing and tested |
| Activity history (deterministic M2/BCB) | **PASS** — existing, owner-scoped, honest |
| AI ledger readback API | **BLOCKED** — the app role `p1_m2_runtime` has no `project1_ai` schema usage or SELECT; needs a reviewed owner-scoped grant before any read-only projection can return data |
| Cloud BDJ/QJ/QG execution | **BLOCKED** — unrotated credential + missing trusted adapters |
| Publication creation | **BLOCKED** — no manifest builder, no owner-scoped release storage, no authority adapter |
| Authenticated browser journey | **BLOCKED** — Chrome remote debugging off |

No status above claims completion based on task-progress counts. Each BLOCKED item names the exact dependency that must be supplied.
