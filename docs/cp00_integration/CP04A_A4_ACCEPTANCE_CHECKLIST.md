# CP-04A A4 — Acceptance Checklist for `ensure_run` + the Model-Assisted Route

**Status:** `SPECIFIED_NOT_EXECUTED`. No row below has been run. Every row is a claim someone
must later prove, not a result.
**Authorship:** content by `a4-runner` (read-only agent, delivered in message); transcribed to
this file and amended by the team lead, 2026-11-17. Amendments are marked **[LEAD]**.
**Base:** `CP04A_CLOUD_BDJ_RUNTIME_SPEC.md` §2.1, §3.0, §3.2, §3.3.
**Implementer:** `a3a4-builder`. **Independent verifier:** must be a fresh context — not the
implementer, not the author of this checklist.

Status vocabulary for this file, and no other: `VERIFIED` · `IMPLEMENTED_NOT_VERIFIED` ·
`BLOCKED <decision-id>` · `NOT_RUN` · `EXPECTED_HOLD`. A row is `VERIFIED` only when it was
executed and its output observed. Code existing is `IMPLEMENTED_NOT_VERIFIED`, never `VERIFIED`.

---

## 1. Rows that must pass

| # | Assertion | Anchored at | Class |
|---|---|---|---|
| P1 | `ensure_run` with the same `{assessment_id, revision, policy_fingerprint}` twice returns the same run id, and `SELECT count(*) FROM project1_ai.runs` for that identity is 1 | `ledger.py:47-49`; `20261111_01_candidate_ledger.sql:36-45` | clone |
| P2 | A different `revision` produces a different `work_identity` and a second row | same | clone |
| P3 | `work_identity` is computed in exactly one function; no call site open-codes the sha256 | `ensure_run` definition; route | unit |
| P4 | The route calls `classify()` and persists its return value; the persisted `execution_outcome` equals `attempts.outcome` read back from the ledger, not the engine verdict | `provider.py:140`; `result_contracts.py:88` | clone |
| P5 | A `reviewed` result with zero findings persists `finding_count=0` and reads back as `no_admissible_finding`, not as a failure | `result_contracts.py:161-168` | clone |
| P6 | A `reviewed` result with findings persists `finding_authority='candidate_only'` and each finding row carries `authority='candidate'` | `_03` C6; `bdj_result_findings.authority` | clone |
| P7 | The response body carries `held` only when no attempt row exists; no `bdj_results` row is written for `held` | `bdj.py:70-73` | clone |
| P8 | `M2V1-01` still returns the same payload as before the change, and its GEO validation is unchanged | OD-3 deferred | unit + clone |
| P9 | A `WorkflowHeld` anywhere in the route surfaces as a fixed code from the catalogue, never as a 500 and never as interpolated text | `main.py:137-141`; `contracts.py:20` | unit |
| P10 | Every disclosure refusal leaves `SELECT count(*) FROM project1_ai.runs WHERE work_identity = :wi` equal to **0** | spec §3.0 **[LEAD]** | clone |
| P11 | The locator **suffix** bounds are tested in both directions: `M2-04@` (empty suffix) rejected, `M2-04@` + 129 chars rejected, `M2-04@x` and `M2-04@` + 128 chars accepted | `_03:269` `(@[^[:space:]]{1,128})?` | clone |
| P12 | `WorkflowHeld.code` on a bare `raise WorkflowHeld()` returns `''` and does not raise; the handler maps it to `WORKFLOW_HELD` | `contracts.py:20`; handler guard | unit |
| P13 | The parity test asserts **set equality** of accepted keys between the SQL pattern and `SourceRef.item_key`, not two independent accept-lists | `contracts.py:29`; `_03:269` | clone |

## 2. Rows that must fail, by name

| # | Must be refused | By | Class |
|---|---|---|---|
| N1 | Second `reserve()` for the same `(run_id, stage)` | `MODEL_STAGE_ALREADY_RESERVED` (`ledger.py:54-57`) | clone |
| N2 | A request with no disclosure authorization, before any row is created | `DISCLOSURE_*` (`disclosure.py:49-67`) | clone |
| N3 | A real-data request when only synthetic is authorized | `DISCLOSURE_REAL_DATA_NOT_AUTHORIZED` | unit |
| N4 | A seventh attempt | `MODEL_ATTEMPT_BUDGET_EXHAUSTED` | clone |
| N5 | `classify()` on an unregistered D1 value | `RESULT_OUTCOME_UNCLASSIFIED` | unit |
| N6 | `classify()` on `review_result` carrying `finding_authority='VERIFIED'` | `RESULT_OUTCOME_UNCLASSIFIED` | unit |
| N7 | A `held` verdict passed to `classify()` | `RESULT_OUTCOME_UNCLASSIFIED` | unit |
| N8 | `('rejected', finding_count=5)` written by direct SQL | `bdj_results_findings_require_review_check` **[LEAD]** | clone |
| N9 | A `WorkflowHeld` raised with a formatted message emits `WORKFLOW_HELD`, not the message | handler guard `^[A-Z][A-Z0-9_]{2,63}$` **[LEAD]** | unit |
| N10 | `(review_outcome=NULL, finding_count=1)` written by direct SQL | `bdj_results_findings_require_review_check` — the constraint's **second** branch. N8 tests `rejected`; testing only N8 leaves half the predicate unproven **[LEAD]** | clone |

## 3. Reachability note — read this before trusting the matrix

The prompt asks for `E2E-A` … `E2E-E`. **E2E-A, B, D and E are not reachable without a live
TokenHarbor call.** `configured_runner()` is the only production path to a model response, and it
is a paid external dispatch. There is no recorded HTTP exchange available in its place, so any
"full journey" claim built on a fixture would be a claim about the fixture.

Consequence: the four journey rows are `BLOCKED B2` (Cloud AI execution authorization) until the
Owner authorizes one dispatch, and `E2E-E` is `BLOCKED_OD3` independently. What *is* reachable is
P1–P10 and N1–N9, all of which are `ensure_run` / persistence / refusal behaviour and none of
which requires a model call.

Do not close a journey row by substituting a fixture and relabelling it. A fixture proves the
fixture.

## 4. Coverage gaps this checklist does not close

1. **`bdj_result_findings` can still own finding rows for a `rejected` result** whose
   `finding_count` is 0. N8 closes the count, not the rows. No trigger was added, deliberately:
   an invoker-rights trigger reading the parent under RLS fails silently rather than loudly.
   The residual is closed by a **read-path precondition**: any reader of `bdj_result_findings`
   must join `bdj_results` and filter `review_outcome IN ('reviewed','stale')`. A reader built
   without that join re-opens the hole N8 was meant to close. **[LEAD]**
2. **`result_payload` contains entrepreneur answer text** via `source_refs[].quote`. No row above
   asserts the History projection excludes it; that is A5's obligation, not A4's.
3. **No row asserts the writer never builds `locator` from `quote`.** The schema CHECK is a floor
   (`M2-04@We-are-takeaway-only` passes it). The protection is writer construction, and it needs
   its own assertion — carried in `CP04A_RESULT_PERSISTENCE_SPEC.md`, not here.
4. **`retention_until` is unenforceable** while `immutable_history` blocks `DELETE`. Not an A4
   row; recorded in the security package so it is not rediscovered as a surprise.
5. **`finding_count` is a claim, not a fact bound to rows.** No constraint ties it to the number of
   `bdj_result_findings` rows. C9 stops the *counting* of findings on a rejected or unreviewed
   result; it does not stop rows existing, and it cannot detect a stored count that disagrees with
   the rows present. A reader must not derive a finding's authority from `finding_count`. This is
   the same residual as gap 1, seen from the reader's side. **[LEAD]**

## 5. Open questions, resolved

- *Does the `DISCLOSURE_*` predicate run before `ensure_run`?* **Yes.** Spec §3.0 amended
  2026-11-17. The earlier §3 ordering was the defect, not §6.5. P10 and N2 both depend on it.
- *Who adds `WorkflowHeld.code`?* The implementer, as a read-only property returning `str(self)` —
  not `self.args[0]`, which raises `IndexError` on a bare `raise WorkflowHeld()` inside the error
  handler. Spec §3.3 amended. **[LEAD]**
- *Which principal does the route execute as?* **`BLOCKED B2-01`.** `p1ai_engine` with
  `SET LOCAL ROLE p1ai_runtime` is the intended shape and `p1_m2_runtime` cannot reach the schema
  at all (no `USAGE`), but the choice between "same engine, restricted role" and "separate engine"
  is an Owner decision. Do not implement past it.
