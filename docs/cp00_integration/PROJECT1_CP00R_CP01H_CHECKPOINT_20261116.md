# PROJECT1 CP-00R / CP-01H checkpoint — 2026-11-16

Scope: restore and independently verify the actual runtime, then resolve CP-01H.
Safety: no cloud model call, questionnaire publication, campaign creation, customer contact, or live workflow-data write was performed.

## Verdict summary

| Area | Verdict | Evidence-bounded statement |
|---|---|---|
| CP-00R live runtime identity/configuration | **PASS** | Current process was stopped and restarted through a recorded, recoverable path from the known checkout and known `.env` files. Live OpenAPI (198 operations) is identical to a fresh in-process route inventory. Effective app/analytics DB identity was proven via `pg_stat_activity`. M2 target/role was corrected and verified on a fresh connection. Direct process-memory environment introspection was blocked by security policy, so no pre-restart process configuration is claimed. |
| CP-01H restricted role / RLS / history retrieval | **PASS** | `p1_m2_runtime` is LOGIN, non-superuser, NOBYPASSRLS; M2 tables have RLS and owner policies. Under that exact application role, owner A sees the assessment and 17 persisted activity events; cross-owner B sees no assessment. |
| CP-01H ledger security / immutability | **PASS** | Under `p1_m2_runtime`, `PostgresAttemptLedger.reserve()` fails closed with `RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED`. A rolled-back ledger probe confirmed the append-only trigger rejects `UPDATE` with `Workflow history is append-only`, leaving zero persistent rows. |
| CP-01H complete model-execution ledger path | **BLOCKED** | No production code constructs `PostgresAttemptLedger`; `project1_ai` has no exposed history/attempt API; `p1ai_runtime` is NOLOGIN; no dedicated runtime/audit engine is wired. Security is fail-closed, but no permitted write path exists. Do not call cloud models. |
| Authenticated browser journey and screenshots | **BLOCKED** | Chrome remote debugging is off. The chosen test account exists in both databases with the same UUID, but no authenticated UI session was available. No screenshots were captured. |
| Saved-rental API regression | **PASS** | Earlier focused disposable-clone suite: 12/12 passed. Authenticated UI/restart persistence remains separate and unverified. |
| Architecture-test defect fixes | **PASS** | Corrected import-boundary scanner: 4 focused architecture tests passed. Earlier synthetic Project1 suite: 63/63 passed. Scoped `git diff --check` passed. |
| Credential rotation | **FAIL** | Prior audit recorded an exposed TokenHarbor key; no rotation evidence was found. Current provider flag remains disabled. Treat the key as unrotated. |
| Publication / QJ / QG endpoints | **BLOCKED** | No publication-creation, cloud QJ execution, QG generation, approved-bank lookup, or durable attempt-history endpoint exists in the live OpenAPI. |

## 1. Live runtime identity and configuration

### Repository / process

- Checkout: `C:\Users\HP\OneDrive\Desktop\sport-marketplace\FYP`
- HEAD: `ba30035ecb24b80fa155cc7049cf3cdf94a67844`
- Working tree: 89 changed entries; all pre-existing unrelated changes were preserved.
- Old processes: reloader PID `13504`, server PID `24900`, started 2026-11-16 15:16 +08.
- Controlled stop: `taskkill /PID 13504 /T /F`; port 8090 was confirmed released.
- Restart: same checkout and same Python environment, reloader PID `16768`, server PID `10596`, launched with `uvicorn.run(..., host=127.0.0.1, port=8090, reload=True, reload_dirs=['src'])` from the backend directory.
- `/health`: `ok`; `/api/v1/health`: `ok`, database `ok`.
- Live OpenAPI: 198 operations. Fresh in-process OpenAPI: 198 operations. `only_live = []`, `only_fresh = []`, route sets identical.

### Effective configuration loaded by the restart path

| Setting | Value |
|---|---|
| App DB | `Final_Location_Analysis` |
| Analytics DB | `Final_Location_Analysis` |
| M2 DB | `Dss` |
| M2 role | `p1_m2_runtime` |
| `m2_upstream_enabled` | true |
| `m2_bcb_persistence_enabled` | true |
| `project1_workflow_enabled` | false |
| `cq_runtime_enabled` | false |
| `cq_synthetic_preview_enabled` | true |
| `cq_synthetic_interactive_enabled` | true |
| `tokenharbor_enabled` | false |
| `ee01_explanation_enabled` | false |
| `db_auto_create` | false |

### Configuration defect corrected

`.env` already pointed M2 at `p1_m2_runtime`, but `.env.local` overrode `M2_DATABASE_URL` back to `postgres`. Only that override was replaced from `.env`.

- Backup: `backend/backups/cp00r_20261116/.env.local.2ec7f332a64d.bak`
- Backup SHA-256 prefix: `2ec7f332a64d`
- New `.env.local` SHA-256 prefix: `a94b23d42651`
- Post-fix fresh connection: `current_database=Dss`, `current_user=p1_m2_runtime`, `rolsuper=false`, `rolbypassrls=false`, `rolcanlogin=true`.
- Live worker DB connection: local port `56761` mapped in `pg_stat_activity` to `Final_Location_Analysis` / `postgres`.

Secrets were not printed and no secret values are recorded here.

## 2. CP-01H database, RLS and ledger proof

### Roles

| Role | Attributes |
|---|---|
| `p1_m2_runtime` | LOGIN, NOSUPERUSER, NOBYPASSRLS, NOINHERIT |
| `p1ai_runtime` | NOLOGIN, NOSUPERUSER, NOBYPASSRLS, NOINHERIT |
| `p1ai_owner` | NOLOGIN, NOSUPERUSER, NOBYPASSRLS, NOINHERIT |
| `p1ai_audit` | NOLOGIN, NOSUPERUSER, NOBYPASSRLS, NOINHERIT |
| `p1_ee01_runtime` | LOGIN, NOSUPERUSER, NOBYPASSRLS |

### Table controls

- M2 core tables including `m2_assessments`, `m2_answer_revisions`, `m2_bdj_evaluations`, `m2_bdj_findings`, `m2_review_events`, `m2_confirmation_snapshots`, `m2_clarification_events`, `m2_business_contexts` and `m2_business_context_builds` all have RLS enabled.
- Owner-scoped policies exist for M2 core tables; reference tables use `reference_read`.
- Append-only triggers exist for `m2_answer_revisions`, `m2_bdj_evaluations`, `m2_bdj_findings`, `m2_review_events`, `m2_confirmation_snapshots`, `m2_business_contexts` and others.
- `project1_ai.runs`, `attempts` and `attempt_receipts` have RLS and FORCE RLS enabled, with `immutable_history` triggers.

### Restricted-identity behavioral proof

Using the application’s `p1_m2_runtime` connection and `m2_session_for(actor)`:

| Actor | Result |
|---|---|
| Owner `11111111-1111-4111-8111-111111111111` | Assessment `da90aa4a-f9cf-4145-9acf-7de36c9d6fad` visible; `M2Service.activity()` returned **17 events**, `bcb_history_available=true`, extension `workflow-history-metadata/1`. |
| Cross-owner `e49b0084-b6eb-4865-b4a9-02082eb7655f` | Assessment not visible; no activity returned. |

Ledger adapter under `p1_m2_runtime`:

- `PostgresAttemptLedger.reserve('BDJ', ...)` → `WorkflowHeld: RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED`.
- No attempt row was created.

Ledger immutability probe in a transaction that was rolled back:

- `UPDATE project1_ai.attempts SET prompt_version='tampered'` → rejected: `Workflow history is append-only`.
- `runs` count after rollback: `0`.

### Persisted output inventory in Dss

- Answers: 21
- BDJ evaluations: 1
- BDJ findings: 0
- Review events: 1
- Confirmation snapshots: 1
- Clarification events: 0
- Persisted business contexts: 0
- Ledger runs / attempts / receipts: 0 / 0 / 0

This proves existing M2 persistence and history retrieval, but not cloud-model output persistence, because no cloud model was invoked and no production ledger write path exists.

## 3. Authenticated UI status

- Browser Use CLI: unavailable.
- Chrome CDP: not connected; remote debugging is still off.
- Selected test account (`tabhello1612@gmail.com`) exists in both `Dss` and `Final_Location_Analysis` with the same `user_id` (`32ef694a-69b0-4863-a77f-b9cf6c056b56`).
- General database identity mismatch remains: Dss has 20 users, Final has 3, overlap is 1. It does not block this specific account.
- No authenticated browser screenshots were captured.
- Saved-rental → assessment → M2 save → confirmation → reload remains **NOT_VERIFIED**.

Next required user action: in Chrome open `chrome://inspect/#remote-debugging`, enable **Allow remote debugging for this browser instance**, sign in to the SiteWise test account, then continue.

## 4. HTTP / API readback

Verified anonymously/read-only:

- `GET /health` → 200 `{"status":"ok"}`
- `GET /api/v1/health` → 200 `database: ok`
- `GET /openapi.json` → 198 operations
- Protected endpoints (`/api/v1/cq/availability`, `/api/v1/project1-read/readiness`, `/api/v1/m2/instruments`, `/api/v1/cq/manifests/{id}`) → 401 without a token.
- Jaspr public home → 200; `/entrepreneur/activity-history` → redirect to `/login?next=...`.

Authenticated HTTP readback is pending browser access.

## 5. Corrected architecture tests

Two low-severity defects reported by independent review were fixed in `backend/tests/test_architecture.py`:

1. Imported member names are no longer treated as module paths.
2. Constant-string `importlib.import_module()` and `__import__()` calls are now detected.

Verification:

- `pytest tests/test_architecture.py -k 'feature_domain or legacy_m2_rules or import_scanner'` → **4 passed, 6 deselected**.
- Earlier `pytest tests/project1/test_workflow.py` → **63 passed**.
- Scoped `git diff --check` → exit 0.
- No four-module migration expansion was performed.

## 6. Missing API endpoints / components

Live OpenAPI has 65 relevant M2/CQ/Project1 routes, but the following are absent:

- `POST` cloud BDJ execution with provider dispatch and ledger reservation.
- `POST` QJ execution (only `GET /api/v1/m2/research-objectives/{objective_id}/qj-context` exists).
- `POST` QG candidate generation.
- Approved-bank lookup / verification endpoint.
- Authoritative BCB binding administration (tenant, concept, GEO catalogue, purpose authority).
- Publication/release creation endpoint (only `GET /api/v1/cq/manifests/{release_id}` exists).
- Durable AI attempt/run/receipt readback endpoint for Activity History.
- Production ledger write wiring: no production construction of `PostgresAttemptLedger`.

Presence of `/api/v1/cq/developer-imports/*` does not authorize fielding; those are developer inspection/import routes.

## 7. Credential rotation

- TokenHarbor key is present in `.env` but not exposed in this report.
- Prior audit recorded the key as exposed in session output and recommended revocation/rotation.
- No rotation evidence was found. Treat as **not rotated**.
- `tokenharbor_enabled=false`; no provider call was made.
- Supabase DB password and secret key were previously pasted in chat in earlier sessions; rotation status is also unverified.

## 8. Next gate

Do not invoke cloud models, create publication records, or contact customers.

Required next milestone sequence:

1. Enable Chrome remote debugging and authenticate the test account.
2. Execute one browser-authenticated saved-rental → assessment → M2 save → confirmation → reload journey.
3. Capture screenshots and independently read back the DB rows and ownership under the restricted application identity.
4. Only then decide whether to implement the missing engine endpoints under their scientific and workflow authorization gates.

## Re-check — 2026-11-17 00:12 +08

- Live OpenAPI still has 198 operations; 42 match publication/engine keywords.
- Present: M2 assessment/confirmation/BCB/QJ-context routes, CQ manifest read, campaign/participant/session routes, CQ developer-import routes, and two Project1 readiness routes.
- Still absent: cloud BDJ execution, QJ execution, QG generation, approved-bank lookup/verification, authoritative BCB binding administration, publication/release creation, and durable AI attempt/run/receipt readback.
- `configured_runner()` exists in `project1/provider.py`, but no production caller constructs it. `PostgresAttemptLedger` has no production construction. `/project1-workflow` remains unmounted because `project1_workflow_enabled=false`.
- `TokenHarbor` uses the same endpoint and model as the suggested OpenAI-SDK snippet: `https://tokenharbor.ai/v1/chat/completions` and `mimo-v2.6-flash:free`. The OpenAI SDK is installed, but `tokenharbor_enabled=false`; the key is present and unrotated.
- Using the OpenAI SDK directly would still be an external provider call. It would bypass the current adapter's disclosure check, pre-dispatch ledger reservation, strict model check, redirect refusal, retries disabled, response-size limit, timeout budget and structured validation. It is not a CP-01H workaround and was not executed.

## TokenHarbor rotation + bounded diagnostic readiness — 2026-11-17

The user selected "rotate the TokenHarbor key" as the next priority. A bounded, one-shot diagnostic is staged and verified to refuse on the un-rotated key:

- Script: `backend/scripts/tokenharbor_diagnostic.py`
- It loads real `settings`, computes the key SHA-256 prefix (never the value), and **refuses with `KEY_NOT_ROTATED` while the prefix equals the exposed key `9e9644b42e51`**. Verified: current run prints `key_sha256_12=9e9644b42e51` then blocks before any network call.
- When run with a rotated key and `--i-understand-this-makes-one-live-call`, it makes **exactly one** `TokenHarbor.complete()` call (harmless prompt, strict `DiagnosticOutput{status:OK}`, 30s budget, no retry, no redirect) and reports the validated output plus a statement that model identity was enforced by the adapter.
- Scope honesty: this proves the **provider adapter** only (credential accepted, model identity == `mimo-v2.6-flash:free`, structured output validated). It makes **no ledger or disclosure claim**. The full `ModelRunner` path remains blocked because the disclosure adapter has no production implementation and `p1ai_runtime` is NOLOGIN.
- Rotation is a user action in the TokenHarbor dashboard. The new key must be placed directly in `backend/.env` (replacing `TOKENHARBOR_API_KEY`) and must **not** be pasted into chat, to avoid re-exposing it.

### Rotation result + model-identity reconciliation — 2026-11-17 00:57

- Key rotated: stored prefix changed `9e9644b42e51` → `bf27654d8dc9` (value never printed).
- First diagnostic run: `PROVIDER_MODEL_MISMATCH` after 10.0 s. A single raw probe (same endpoint, no retry/redirect, timeout, size cap) showed the cause: HTTP 200, `returned_model='mimo-v2.6-flash'`, `expected_model='mimo-v2.6-flash:free'`, `finish_reason='stop'`, `content='{"status":"OK"}'`. The provider returns its canonical name without the `:free` tier marker.
- Fix (kept strict): `provider.py` now sends `MODEL='mimo-v2.6-flash:free'` (tier routing) but validates the response against `ALLOWED_RESPONSE_MODELS = {'mimo-v2.6-flash', 'mimo-v2.6-flash:free'}`. Any other model still raises `PROVIDER_MODEL_MISMATCH`.
- Evidence: `pytest tests/project1/test_workflow.py` → **63 passed**. Live diagnostic re-run → **PASS**, `elapsed_s=6.459`, `validated_output={'status':'OK'}`, model identity validated, no retry.
- Scope: proves the **provider adapter** with the rotated key. Still does NOT prove the ledger-backed `ModelRunner` path (disclosure adapter has no production implementation; `p1ai_runtime` is NOLOGIN).



