# CP-07 — Staged E2E Transition Matrix

**Date:** 2026-11-17 · **Branch:** `merge_main_jed`
**Rule:** each transition reports its state separately. `IMPLEMENTED` is not `API_DB_VERIFIED`, and
`API_DB_VERIFIED` is not `BROWSER_VERIFIED`. A fixture-authorized pass is not a real-authority pass.

States: `IMPLEMENTED` · `API_DB_VERIFIED` · `BROWSER_VERIFIED` · `EXPECTED_HOLD` · `BLOCKED` · `NOT_RUN`

---

## 1. Transition matrix

| ID | Transition | Implemented | API+DB verified | Browser verified | Remaining blocker |
|---|---|---|---|---|---|
| E2E-0 | M2 → deterministic BDJ → History V1 | Yes (pre-existing) | Partial — engine only (§2) | `NOT_RUN` | History V1 consistency not asserted this session |
| E2E-1 | Cloud BDJ → run → fixture provider → validator → writer → History V1.1 | **Yes (new)** | **Yes — 246 tests, clone** | `NOT_RUN` | Dart/Jaspr surface not built |
| E2E-2A | BCB deliberate HOLD | Yes (pre-existing) | **Yes — 42 passed / 6 skipped / 4 xfailed on a disposable cluster** | `NOT_RUN` | authority is still absent; the HOLD is correct behaviour, not a pass |
| E2E-2B | BCB fixture-authorized positive | Yes (pre-existing, 42-test baseline cited) | `NOT_RUN` | `NOT_RUN` | disposable cluster required |
| E2E-3 | BCB → QJ → bank-first QG | Component only | `NOT_RUN` | `NOT_RUN` | `BLK-BCB-AUTH` + no approved bank adapter |
| E2E-4A | CQ synthetic responses → EE-01 | Yes (pre-existing) | `NOT_RUN` | `NOT_RUN` | needs approved synthetic dataset + independent SQL oracle |
| E2E-4B | EE-01 → explanation → R01–R12 → ReportAdmission | No | `NOT_RUN` | `NOT_RUN` | `BLOCKED_IMPLEMENTATION` |
| E2E-5 | Full authenticated browser → report | No | `NOT_RUN` | `NOT_RUN` | `BLOCKED_OD3` + downstream gates |

## 2. E2E-1 — the one that actually moved

**Chain, each link with the code that owns it:**

```
POST /project1-workflow/assessments/{id}/business-understanding/model-assisted
  → configuration_gate            (project1_workflow.py)      gate passes or 503
  → require_entrepreneur          (dependencies.py)           owner identity
  → packet_source                 (projection.py)             confirmed M2 revision
  → validate_synthetic            (disclosure.py)             ALL ten refusals, BEFORE any row
  → ensure_run                    (runs.py)                   idempotent, revision-bound
  → PostgresAttemptLedger.reserve (ledger.py)                 one attempt, budget, stage
  → configured_runner             (provider.py)               existing runner, not a replacement
  → BDJEngine.review              (bdj.py)                    validate_candidates
  → ledger.finish                 (ledger.py)                 D1 transport outcome + digest
  → result_contracts.classify     (result_contracts.py)       four independent dimensions
  → BdjResultStore.persist        (result_store.py)           parent + children, one transaction
GET  /project1-workflow/assessments/{id}/results
  → results_for_assessment        (result_store.py)           owner-scoped projection
```

**Evidence (clone, restricted principal):**

```
246 passed, 1 skipped, 7 subtests passed in 4.08s
runs=183 attempts=173 results=124 findings=16 sources=168 raw=8
```

The row counts are the point: 124 persisted results and 16 persisted findings were written and read
back by the tests. This is not a schema-only result.

**What E2E-1 does not prove:** that a real TokenHarbor call works. Every test injects a fixture provider
with the same call surface. `configured_runner()` is exercised as a composition path, not as a network
call. A real dispatch is a paid external action and is `BLOCKED B2`.

## 3. E2E-0 — what was and was not run

The deterministic route (`POST …/business-understanding`) is pre-existing and is covered by
`tests/project1/test_workflow.py` inside the 246. What was **not** asserted this session is the
consistency between the deterministic result and the V1 History feed
(`GET /m2/assessments/{id}/activity`). That check is `NOT_RUN`, not passed.

The directive warns: do not claim a fresh browser assessment completed while OD-3 is deferred. Nothing
here does.

## 4. E2E-2A — executed, and the hold was observed

The harness finished after this document was first drafted, so this section supersedes the earlier
`NOT_RUN`. Command:

```
./.venv/Scripts/python.exe tests/m2_bcb/run_isolated.py \
    --output ../docs/cp00_integration/cp07_e2e2a_bcb_isolated.json --suite regression
→ NEW private PostgreSQL lab: …\Temp\project1_m2_bcb_lzui2ehv
→ 42 passed, 6 skipped, 4 xfailed in 164.05s
→ Private cluster stopped; live Dss was not written.
```

The run is worth more than a pass count because it emitted a per-interaction oracle:
`api_execution.json` holds **391 API interactions across 46 distinct tests**, each with
`expected_http` / `actual_http`. Six entries differ under naive comparison, and all six are false
positives — the expectation is a list (`[200, 201]`, `[200, 422]`) and the actual is one of the
accepted values. **Zero genuine status mismatches.**

The two decisive interactions, from `test_PG13_production_binding_factory_refuses_and_feature_flag_is_off_gate`:

| Request | Expected | Actual | Code |
|---|---|---|---|
| `POST …/business-context` with the production factory restored | 503 | 503 | `BCB_BINDING_AUTHORITY_UNVERIFIED` |
| `POST …/business-context` with `m2_bcb_persistence_enabled=False` | 503 | 503 | `BCB_PERSISTENCE_NOT_CONFIGURED` |

So the fail-closed path is `EXPECTED_HOLD` and it was **watched**, not inferred. Two things this still
does not establish: that any authority exists (it does not — `BLK-BCB-AUTH` is open), and that the same
refusal occurs against `Dss` rather than a synthetic cluster.

The remaining `6 skipped` and `4 xfailed` are reported as they are, not folded into the 42. An `xfail`
is an expected failure — it is not a pass, and counting it as one would be the arithmetic error this
project has already corrected twice.

## 5. Independent SQL oracle — not built

E2E-4A requires an independent SQL oracle for EE-01 (exact counts and denominators computed by a second
implementation, not by the service under test). It was not built this session. Without it, an EE-01 pass
would be the service agreeing with itself.

## 6. Prohibited false positives, restated

| Temptation | Why it is false |
|---|---|
| "246 tests pass, so the workflow is complete" | no live provider, no UI, no `Dss` |
| "The schema is verified, so persistence is verified" | schema-level refusals ≠ a writer producing valid rows |
| "The API returns History, so the UI works" | the Dart DTO and Jaspr rendering do not exist yet |
| "BCB refuses, so BCB is correct" | a refusal proves fail-closed, not that authority exists |
| "The fixture authorized it, so it is approved" | fixture authority is not production approval |
| "`Dss` is unchanged because no one ran the migration" | measured: `bdj_results` does not exist there — that is the proof, not the intention |
