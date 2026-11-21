# CP-04A — Runtime Writer, Run Provisioning and Route Verification

**Date:** 2026-11-17 · **Branch:** `merge_main_jed` · **Database used:** `project1_workflow_tests` (clone)
**Scope:** Gate P1 of the CP-04A/BCB Priority Execution Directive — cloud BDJ application integration.
**Status vocabulary:** `VERIFIED` · `IMPLEMENTED_NOT_VERIFIED` · `BLOCKED` · `NOT_RUN` · `EXPECTED_HOLD` · `OWNER_DECISION_REQUIRED`

---

## 1. Headline

The cloud-BDJ path now runs end to end **against the isolated PostgreSQL clone, under the restricted
principal**, and its persisted results are readable back through a new owner-scoped History V1.1
endpoint. **246 tests pass, 1 skips** (the skip is pre-existing and unrelated).

What is *not* verified, and is not claimed: a live provider call, the Dart/Jaspr History surface, and
anything on `Dss`. Sections 6 and 7 say exactly why.

| Gate P1 requirement | State | Evidence |
|---|---|---|
| Run provisioning | `VERIFIED` (clone) | §3.1, 13 writer tests |
| Reuse the existing runner, not a replacement | `VERIFIED` (fixture provider) | §3.2 |
| Result writer connected to `result_contracts` | `VERIFIED` (clone) | §3.3 |
| Activity History V1.1 readback | `VERIFIED` (API) / `NOT_RUN` (UI) | §4 |
| Private answer text cannot leak through History | `VERIFIED` (sentinel) | §5 |
| Live provider dispatch | `NOT_RUN` — `BLOCKED B2` | §6 |

## 2. Commands run, verbatim

```
cd backend
./.venv/Scripts/python.exe scripts/run_project1_clone_tests.py tests/project1 \
    -q --no-header -p no:cacheprovider
→ 246 passed, 1 skipped, 7 subtests passed in 4.08s
```

`scripts/run_project1_clone_tests.py` was added because the clone-only tests skip at module level
without `PROJECT1_CLONE_URL` / `PROJECT1_CLONE_ADMIN_URL`, and **pytest reports a module-level skip as
one skipped test**. Two modules covering 23 tests therefore reported `1 skipped` each and looked
verified-by-absence. The script derives both URLs from `backend/.env` (swapping only the database name
to `project1_workflow_tests`), sets them for the test process, and runs pytest. It prints no URL and no
password, and it cannot target `Dss` because the database name is hard-coded.

Before this change: `200 passed, 3 skipped`. The 200 did not include a single writer or route test.

## 3. What was implemented

### 3.1 Run provisioning — `src/sitewise/project1/runs.py`

`PostgresAttemptLedger.reserve()` raises `WORKFLOW_RUN_NOT_FOUND` when no `project1_ai.runs` row
exists, and no production code created one. `ensure_run()` now does, idempotently:

- `work_identity = sha256(canonical({assessment_id, revision, policy_fingerprint}))`
  (`runs.py:42`), one derivation, no second copy anywhere.
- `policy_fingerprint` hashes the **effective** policy — rules version, prompt version, model
  (`runs.py:33`) — so changing the model starts a new run rather than silently reusing one computed
  under different terms.
- `INSERT … ON CONFLICT (owner_user_id, work_identity) DO NOTHING`, then `SELECT`.
- Post-conflict assertion that `assessment_revision` matches (`runs.py:87-90`). This is the **only**
  place the packet/run revision binding is enforced: `reserve()` never compares revisions.

### 3.2 Runner reuse — `src/sitewise/project1/model_assisted.py`

`configured_runner(ledger, disclosure, prompts)` had zero production callers. It is now injected
through `runner_factory`, which the route receives as a dependency. Tests inject a fixture provider
with the same call surface as `TokenHarbor`, so **no test can reach the network** and none does.

### 3.3 Writer — `src/sitewise/project1/result_store.py`

`BdjResultStore.persist()` writes `bdj_results` and its children in one transaction, taking
`execution_outcome` verbatim from the ledger receipt (`provider.py:140`) rather than deriving it from
the engine verdict, and taking the four outcome dimensions from `result_contracts.classify()`.

The four dimensions stay independent: a `returned` transport outcome coexists with `reviewed`,
`rejected` or `stale`. `held` is returned at `bdj.py:70-73` before `ledger.reserve()`, so it has no
attempt row, so it cannot be stored — it stays in the response body only. That is deliberate; the
composite FK was not weakened to accommodate it.

### 3.4 A defect found and fixed during this work — disclosure ordering

`project1_ai.runs` is append-only (`deny_mutation()` refuses `DELETE`). The first implementation
checked only `data_class` and `purpose` before `ensure_run()`, while `require_current()` validated
**nine** `DISCLOSURE_*` conditions at dispatch — which is *after* the run row exists. Seven of the nine
could therefore leave an orphan run row that no later code could remove.

Fixed by extracting the whole predicate into `disclosure.validate_synthetic()` — a pure function that
takes fields and the packet, never a run id — and calling it **before** `ensure_run()`.
`require_current()` now delegates to the same function, so dispatch and preflight cannot drift apart.

Regression coverage: `tests/project1/test_disclosure_contract.py` (17 tests, no database) covers all
nine codes plus the unbound-authorization case, and two route tests assert `run_count == 0` and
`attempt_count == 0` after both a pre-provisioning refusal and a code that previously fired at
dispatch.

## 4. Activity History V1.1 readback

New route: `GET /project1-workflow/assessments/{assessment_id}/results`
(`api/v1/project1_workflow.py`), backed by `result_store.results_for_assessment()`.

Additive to the V1 feed at `/m2/assessments/{id}/activity`, which is untouched. Every row carries
`finding_authority='CANDIDATE_ONLY'` and the response spreads `no_authority()`, so a saved result can
never read as approval. `Cache-Control: no-store` on the response.

Owner scoping is applied twice on purpose: `restricted_scope()` binds `project1.actor_id` so RLS
filters the rows, and the `WHERE owner_user_id = :owner` clause filters them again. A projection that
relied on RLS alone would silently widen if a future session ran with `BYPASSRLS`.

## 5. Private answer text cannot reach the History response — proven, not asserted

Three independent controls, each tested:

1. `result_payload` is selected only to be projected, never returned. It is the column that embeds
   `source_refs[].quote`.
2. `_project_payload()` copies `FINDING_KEYS` and `REFERENCE_KEYS` only. Neither contains `quote`, and
   `source_refs` is not a finding key, so the quote has no path into the output.
3. `bdj_raw_responses` is never referenced. The runtime principal has no `SELECT` on it.

The test does not merely assert absence — it asserts absence **while proving the data was stored**:

```
test_history_projection_excludes_the_quote_sentinel
  finding carries two exact quotes: 'We are takeaway-only.' and 'DINE_IN_FOCUSED'
  POST  → 200, one persisted finding
  GET   → 'We are takeaway-only.' NOT in response
          'DINE_IN_FOCUSED'       NOT in response
          'result_payload'        NOT in response
          'bdj_raw_responses'     NOT in response
          every reference has exactly {item_key, answer_revision_id, item_version_id}
  admin SELECT result_payload → the quote IS there
```

A redacted reader does not prove plaintext is protected at rest. It is not: `result_payload` holds the
quotes in plaintext, and `bdj_raw_responses` encryption is therefore theatre for that text. That is
recorded as a known gap, not a mitigation (§7.3).

## 6. What is not verified

**Live provider dispatch — `NOT_RUN`, `BLOCKED B2`.** Every test uses a fixture provider. A real
TokenHarbor call is a paid external dispatch and needs Owner authorization. `E2E-1` is therefore
`API_DB_VERIFIED` with a fixture provider, not "real-provider verified".

**Browser and Dart/Jaspr surface — `NOT_RUN`.** The API half of History V1.1 exists and is tested. The
Dart DTO and Jaspr rendering were not built in this session, so the directive's "API → Dart DTO →
Jaspr" chain is one third complete. Claiming the UI from an API test would be the exact substitution
the directive forbids.

**`Dss` — `BLOCKED`, by design.** Measured, not assumed:

```
Dss                      ERROR: relation "project1_ai.bdj_results" does not exist
project1_workflow_tests  runs=183 attempts=173 results=124 findings=16 sources=168 raw=8
```

The error is the evidence that the corrected schema is absent from `Dss`.

## 7. Known gaps carried forward

1. **`finding_count` is a claim, not a fact bound to child rows.** `bdj_results_findings_require_review_check`
   stops a rejected or unreviewed result from *counting* findings; it cannot stop rows attaching to a
   rejected parent whose count is 0. Any reader of `bdj_result_findings` must join `bdj_results` and
   filter `review_outcome IN ('reviewed','stale')`.
2. **`detail` semantics are documented inconsistently.** The code enforces a closed code set
   (`VALIDATION_DETAIL_CODES`); the migration comment calls the column "legitimately prose". The code
   is the safer of the two and the documents are being aligned to it. A comment-only migration edit
   was deferred rather than churning the hash.
3. **Plaintext quotes at rest.** See §5.
4. **Five constraints have no drop-and-observe proof** (sandbox policy blocked the meta-check). Their
   refusals are asserted by constraint name, which is substitute evidence and labelled as such in
   `CP04A_A2_CLONE_VERIFICATION_REPORT.md` §6.

## 8. Files changed

| File | Change |
|---|---|
| `src/sitewise/project1/disclosure.py` | extracted `validate_synthetic()`; `require_current()` delegates; refuses an unbound authorization |
| `src/sitewise/project1/model_assisted.py` | full disclosure predicate before `ensure_run()` |
| `src/sitewise/project1/result_store.py` | added `results_for_assessment()` |
| `src/sitewise/api/v1/project1_workflow.py` | added `GET /assessments/{id}/results` |
| `scripts/run_project1_clone_tests.py` | new — makes the 23 clone tests executable |
| `tests/project1/test_disclosure_contract.py` | new — 17 tests |
| `tests/project1/test_model_assisted_route.py` | +6 tests (2 ordering, 4 History V1.1) |

Written earlier by `a3a4-builder` and verified in this session: `runs.py`, `result_store.py`,
`model_assisted.py`, `principal.py`, and the `main.py` handler.
