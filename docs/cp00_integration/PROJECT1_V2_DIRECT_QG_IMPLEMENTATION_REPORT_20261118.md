# PROJECT1 — Simplified BDJ → BCB → QG Implementation Report (V2.0)

**Directive:** `PROJECT1-SIMPLIFIED-BDJ-BCB-QG-V2.0` + correction withdrawing CP-04
**Date:** 18 November 2026
**Branch:** `merge_main_jed` — nothing committed; all changes in the working tree
**Provider budget:** **5 of 6 used. The last free call was NOT spent.** Ceiling USD $0.00.

---

## 0. The one thing to read first

The correction removed QJ from the active path and forbade a replacement. That removal
took with it the **only component in this repository that produced a `Measurement`**.

`Measurement` requires eleven fields. The BCB packet supplies **three** of them.

| `Measurement` field | Source after QJ is removed | Status |
|---|---|---|
| `uncertainty_version` | `measurement_policy.resolve_uncertainty_version(packet)` | **SOURCED** (server-authored, F-01) |
| `source_refs` | derivable from `packet.m2_answers` + `confirmed_uncertainty.id` | **DERIVABLE** |
| `limitations` | template could be written | **DERIVABLE, NOT AUTHORITATIVE** |
| `construct` | — | **NO SOURCE** |
| `population` | — | **NO SOURCE** |
| `timeframe` | — | **NO SOURCE** |
| `stimulus` | — | **NO SOURCE** |
| `response_options` | — | **NO SOURCE** |
| `response_codes` | — | **NO SOURCE** |
| `routing` | — | **NO SOURCE** |
| `denominator` | — | **NO SOURCE** |

The BCB packet carries the uncertainty as **free text** and the concept as a **single
`description` string** — `business_context_v1.py:280-282` enforces
`set(concept["content"]) == {"description"}`. There is no structured offer, no population,
no response coding, no denominator, and no confirmation of any of them.

This is reported as an **unresolved contract decision**, per the correction's instruction.
It was not filled in, not inferred, and no module was invented to supply it. The code
**names** the gap and **refuses** it (`research.py:24-29`, `DIRECT_QG_MEASUREMENT_SOURCES`).

**Consequence for CP-08: the live QG call was not dispatched.** Its input contract cannot
be satisfied without a measurement, and the only complete measurement in the tree is
`tests/m2_bcb/lab_measurement_v0_1.py::canonical_spec()`, which is test-only by
construction. Spending the last call to dispatch against a synthetic fixture would
produce a candidate about a fictional population and record it as if it were research.

---

## 1. Status table

| # | Checkpoint | Status | Evidence |
|---|---|---|---|
| **CP-01** | Replace QJ orchestration with a versioned direct-QG path | **PASS (engine) / PARTIAL (exposure)** | `direct_qg_service.py` (`P1-WORKFLOW-2.0-DIRECT-QG`), `research.py:98-166`; 45 new tests. **No HTTP endpoint** — see §5. |
| **CP-02** | Zero-BDJ-finding, entrepreneur-originated objectives | **PASS** | `execute_direct_qg(..., objective=...)`; objective reaches QG input and `objective_id` is recorded on the result. No BDJ component is composed into this path, so no finding can be required. |
| **CP-03** | BCB → QG input without inventing products/prices/locations/denominators | **PASS (as a refusal)** | Nothing is invented. A measurement that omits a required field is refused (`F02_MEASUREMENT_INCOMPLETE`); a price the uncertainty never confirmed is refused (`F02_STIMULUS_NOT_SUPPORTED_BY_UNCERTAINTY`). |
| **CP-04** | **WITHDRAWN** — build no readiness validator, spec builder, construct catalogue, or `METHOD_REVIEW_REQUIRED` | **PASS (by absence)** | `grep` for all four identifiers across `src/`: zero hits. Nothing was built. |
| **CP-05** | Direct QG; remove the BD-01/BD-02 bank gate by versioned contract change; keep bank code identifiable as deferred; retain D-01 | **PASS** | `bank=None` in the composed workflow; `question_bank.STATUS = 'DEFERRED_BY_CONTRACT_CHANGE_P1_WORKFLOW_2_0'`; result says `NOT_CONSULTED_DIRECT_QG`, never `not_checked`; D-01 RM13/RM12 regression retained and re-proven on the new path. |
| **CP-06** | Entrepreneur `APPROVE_FOR_REVIEW` / `REJECT` / `REQUEST_REVISION` with parent version, reason, actor, context hash | **BLOCKED** | `REQUEST_REVISION` does not exist anywhere in the codebase. `m2_candidate_owner_reviews.decision` CHECK admits only two values. No `context_hash` column on candidates. No database was reachable to test a migration — see §6. |
| **CP-07** | UI in existing Business Understanding / M2 surfaces; no QJ page; no bank-readiness copy | **PARTIAL** | No QJ page exists (correct by absence). Candidate review UI exists **only** in `fyp_jaspr_web/lib/components/research_workflow_panel.dart`; the Flutter M2 surfaces have none. No "QJ AUTHORIZATION REQUIRED" string exists. |
| **CP-08** | One conditional live QG call | **CORRECTLY NOT SPENT** | Budget ledger `spent: 5 / limit: 6`, five attempts, unchanged. Input contract unsatisfiable — see §0. |
| **CP-09** | Verify report explanation fallback integration | **PARTIAL** | Empty-claim-set fallback is implemented, reachable and tested (25 passed). The **authorized-finding** fallback is **ABSENT** — refused upstream with `EXPLANATION_ADAPTER_UNVERIFIED`. One governance defect found: false prompt attribution. See §7. |
| **CP-10** | Reconcile historical issues; do not relabel blocked tests as passing | **PASS** | See §8. 28 issues reconciled; 4 moot, 24 live. |
| **§13** | Record baseline and run integration scenarios | **PASS** | Baseline **555 passed, 6 skipped, 7 subtests**. After: **600 passed, 6 skipped, 7 subtests**. 45 new tests, zero regressions. |

---

## 2. What changed in code

### `project1/research.py` — the active path
`execute_direct_qg(request, *, frozen_measurement, measurement_source, measurement_source_ref=None, objective=None)`
and its worker `_direct_qg`. It:
- verifies the packet (`checked_context`) before anything else;
- resolves the uncertainty version through **`resolve_version`**, not `admit_qj`;
- validates the measurement against the real versioned policy (F-02) and **re-verifies the receipt**;
- invokes **QG only**;
- returns `{'qj': None, 'bank': 'NOT_CONSULTED_DIRECT_QG', 'candidate_authority': 'ENTREPRENEUR_REVIEW_ONLY', **no_authority()}`.

Refusal codes: `QG_FROZEN_MEASUREMENT_REQUIRED`, `QG_MEASUREMENT_SOURCE_UNRECOGNIZED`,
`QG_MEASUREMENT_SOURCE_NOT_AVAILABLE`, `QG_MEASUREMENT_SOURCE_REF_REQUIRED`,
`QG_MEASUREMENT_AUTHORITY_UNVERIFIED`.

### `project1/measurement_policy.py` — QJ permission is not a hidden precondition
`admit_qj` was split into `resolve_version` (version + provenance + geography) and
`admit_qj` (the above **plus** the `qj_execution` permission assertion). The direct path
calls `resolve_version`.

This is not cosmetic. `admit_qj` refuses a packet whose `permissions.qj_execution` is not
`False`. A path that never runs QJ must not be gated on a QJ permission, or the retired
stage survives as an invisible precondition. `test_a_packet_that_asserts_qj_authority_is_refused_by_the_legacy_path_only`
proves both halves: the legacy admission still refuses, and the direct path runs on that
same packet.

### `project1/direct_qg_service.py` — production composition (new)
`DirectQgService`, contract version `P1-WORKFLOW-2.0-DIRECT-QG`, `ACTIVE_STAGES == ('QG',)`.
It composes `ResearchWorkflow(PacketBuilder(packet), authority, None, runner)` — **`bank=None`**.
Gates: `DIRECT_QG_CONTRACT_VERSION_MISMATCH`, `DIRECT_QG_NOT_ENABLED`,
`DIRECT_QG_CONTEXT_SERVICE_MISSING`, `DIRECT_QG_AUTHORITY_UNVERIFIED`,
`DIRECT_QG_RUNNER_MISSING`, `DIRECT_QG_MEASUREMENT_NOT_SUPPLIED`.

`gates()` reports `bank_required: False` **explicitly** rather than omitting the key, so a
reader cannot mistake the contract change for an oversight. `qj_execution_authorized` is
recorded as `qj_execution_authorized_observed` — history, not a gate.

### `project1/question_bank.py` — deferred, and it says so
`STATUS = 'DEFERRED_BY_CONTRACT_CHANGE_P1_WORKFLOW_2_0'`, exported. The module is
retained so its rules stay testable and re-enablable; the constant distinguishes
"deferred by contract" from "never implemented". Re-enabling it requires a signed
contract change, not a code edit.

### `project1/prompts.py`
`QG` v1 (`QG-FROZEN-1-CAND`) retired → **`QG-FROZEN-2-CAND`**. It removes the V1.0
instruction that a draft must follow a verified no-equivalent bank receipt (no longer
true), and adds explicit price-fidelity and never-self-approving rules.

---

## 3. Test evidence

| Suite | Result |
|---|---|
| `tests/project1/test_direct_qg.py` (new) | **30 passed** |
| `tests/project1/test_direct_qg_service.py` (new) | **15 passed** |
| `tests/project1` + `tests/m2_bcb` (scoped baseline) | **600 passed, 6 skipped, 7 subtests** |
| Baseline before modification | **555 passed, 6 skipped, 7 subtests** |

Zero regressions. The 45 new tests are additive.

### What the new tests actually prove

**The path runs without QJ or a bank.** `test_composed_service_drafts_without_a_bank_and_without_qj`
composes the service and asserts `calls == ['QG']`, `result['qj'] is None`,
`result['bank'] == 'NOT_CONSULTED_DIRECT_QG'`. `test_direct_path_records_the_bank_as_not_consulted_not_as_unchecked`
pins the distinction between *deferred* and *skipped*, because `not_checked` would read as
a step that was forgotten.

**A QJ permission cannot gate the active path.** `test_a_context_that_does_not_authorize_qj_still_runs_the_active_path`
runs against `qj_execution_authorized: False` — the value the real persisted context
returns today, and the value that blocked the V1.0 composition. Under V2.0 it is recorded
and ignored. `test_a_context_that_does_authorize_qj_gains_nothing_from_it` proves the
converse: the flag confers no authority either.

**Removing QJ did not remove the context gate.** `test_an_unconfirmed_context_is_still_refused`
(`BCB_CONFIRMATION_REQUIRED`), `test_a_tampered_packet_is_still_refused`
(`BCB_PACKET_FINGERPRINT_INVALID`), `test_restricted_m2_membership_stops_the_direct_path`
(`BCB_RESTRICTED_ITEM_MEMBERSHIP`), and `test_geography_is_still_refused_on_the_direct_path`
(`F02_GEO_NOT_EXCLUDED`). Each asserts `calls == []` — no model call precedes a refusal.

**F-02 survived the path change.** `test_a_no_op_authority_cannot_reach_the_direct_path`
shows a `lambda *_: None` validator is refused with `MEASUREMENT_RECEIPT_MISSING` and that
**no candidate is drafted**. `test_an_authority_without_version_resolution_is_refused`
closes the duck-typing route.

**D-01 survived.** `test_price_drift_is_refused_on_the_direct_path` quotes the frozen
stimulus verbatim and appends a second, different price. It deliberately does **not**
replace RM13 inside the stimulus, because that would trip the wording check first and the
amount guard would never run — the same masking error found twice in this project.

**Abstention cannot smuggle a candidate.** `test_abstention_yields_no_candidate` and
`test_an_abstention_that_smuggles_a_question_is_refused`.

**The gap is refused, not filled.** `test_no_production_measurement_source_exists_today`
asserts `AUTHORISED_PRODUCTION_SPEC` is refused with `QG_MEASUREMENT_SOURCE_NOT_AVAILABLE`,
and `test_no_supplied_measurement_is_refused_at_composition` refuses at composition with
`DIRECT_QG_MEASUREMENT_NOT_SUPPLIED`.

---

## 4. Historical QJ records remain readable

`ResearchWorkflow.execute` / `_evaluate` were **retained unchanged** for the legacy path.
`test_the_legacy_path_is_retained_and_still_returns_qj_records` executes it and asserts
`result['qj']['route'] == 'HOLD'`. Retiring a stage from the active path is not deleting
its history.

---

## 5. CP-01 is PARTIAL: the engine is composed, but not exposed

`grep -rn "direct_qg\|DirectQg" src/sitewise/api/` returns nothing. There is no HTTP
route. `DirectQgService` is a server composition that no transport currently calls, in
the same way `QjQgService` had no caller before V1.0.

This is reported rather than papered over. Exposing it requires an endpoint that also
solves the CP-06 problem: a candidate produced but never reviewable is not progress.

---

## 6. CP-06 is BLOCKED, with the exact delta specified

Recorded from a fresh-context review of the current schema:

| Requirement | Current state | Delta needed |
|---|---|---|
| `APPROVE_FOR_REVIEW` | exists (`m2.py:242`, CHECK constraint) | none |
| `REJECT` | exists | none |
| `REQUEST_REVISION` | **absent everywhere** | CHECK constraint + API `Literal` + service |
| parent version | **absent** on the candidate row | new column + FK |
| reason | `rationale` exists, `BETWEEN 1 AND 1000` | none |
| actor | `reviewer_id` exists | none |
| context hash | **absent**; the receipt embeds a snapshot digest but candidate staleness is never compared | new column + comparison |
| never overwrite history | **PASS** — append-only trigger `m2_owner_review_append_only`, versions immutable | none |

**Not implemented, deliberately.** `tests/project1/test_postgres.py` **skips** — no
database is reachable in this environment, and a direct connection attempt was blocked by
policy. Writing a security-sensitive migration that cannot be executed would repeat the
`BD01-SQL-01` / `BD01-SQL-02` failure mode, where both defects were found only *by
running* the DDL against a clone. Half-implementing it in the application layer alone is
worse: adding `REQUEST_REVISION` to the API `Literal` without the matching CHECK
constraint converts a validation error into a 500 from a constraint violation.

**What unblocks it:** a reachable clone, the migration, and a probe script in the pattern
of `scripts/f01_append_only_probe.py`. The review is specified in §6 and can be applied
and tested in one pass.

---

## 7. CP-09 — PARTIAL: one fallback is real, the other does not exist

Two independent verifications disagreed on whether the empty-claim fallback is reachable.
I settled it from the code and the tests rather than choosing the more convenient account.

**Verified directly:** `tests/api/test_ee01_explanation.py` → **25 passed**, including
`test_empty_findings_produce_local_insufficient_evidence`. The service returns a real
result at `ee01_explanation_service.py:111-126`.

| Claim | Status | Evidence |
|---|---|---|
| Empty claim set returns a deterministic local template | **TRUE, reachable, tested** | `explanation_contracts.py:81` `insufficient_evidence_output`; called at `ee01_explanation_service.py:111`; `llm_execution: 'NOT_ATTEMPTED'`, `authority: 'CANDIDATE_UNVERIFIED'` |
| The template is validated like any candidate | **TRUE** | `validate_candidate(...)` at `:117` runs against the same guards a model output would face |
| A fallback exists for **authorized findings** | **ABSENT** | `ee01_explanation_service.py:99-102` refuses with `EXPLANATION_ADAPTER_UNVERIFIED` (503) whenever `context['findings']` is non-empty. `_store_held_context` hard-codes `'findings': []` (`ee01_service.py:220`), so the branch is never populated |
| `PROMPTS['EXPLANATION']` is ever dispatched | **FALSE — no caller** | Registered at `prompts.py:115`; no call site passes `'EXPLANATION'` to a runner |

### Defect found: false prompt attribution

`ee01_explanation_service.py:121` emits `'prompt_version': 'EE01-EXPLANATION-1-CAND'`
on a result that **was never produced by that prompt** — the prompt is never executed on
this path. A reader of the stored envelope is told a model was involved when it was not.

The envelope does carry `llm_execution: 'NOT_ATTEMPTED'`, so the *envelope* is honest.
But the 13-field `candidate` contract (`explanation_contracts.py:64-78`) has **no
provenance field**. A consumer that persists only `candidate` cannot distinguish this
template from a genuine model output for a legitimately empty claim set — both carry
`insufficient_evidence: true` and `used_claim_ids: []`. **No test covers that
indistinguishability.**

This is the recurring error class in this project: a label that is true of the envelope
but false of the object a downstream reader actually consumes.

### What this means for the checkpoint

The checkpoint asked me to *verify the fallback integration*. The integration that exists
covers the empty-claim case only, and it is correct. The case that matters for a real
report — an authorized finding that cannot be interpreted — has no fallback and is
refused upstream. `PARTIAL` is the accurate label; neither `PASS` nor `BLOCKED` is.

---

## 8. CP-10 — historical reconciliation

28 distinct issues were extracted from the four `docs/cp00_integration/` reports.
**4 are moot** under V2.0 because QJ no longer exists. **24 remain live** and are
carried forward unchanged. No previously blocked item was relabelled as passing.

### Moot because QJ is removed
`F-01` (unnamed `uncertainty_version` in the QJ prompt), the QJ half of `F-02`, the
`P3` QJ `HOLD` route, and the QJ-branch bank gate.

### Live under V2.0 — the important ones
- **`F-02` (validator inert) — live in principle.** It is repaired in the direct path
  (`verify_validation_receipt`), but the historical report's status stays `OPEN`. It is
  *not* relabelled.
- **`F-01`'s mechanism — live wherever a receipt still carries a version.** The direct
  path consumes a receipt that names `uncertainty_version`. The source is now
  server-authored (`resolve_uncertainty_version`), so the *gap* is closed, but any
  component that later accepts a version from a model would reopen it.
- **`BD-01` bank authority — live, and now deferred by contract** rather than blocking.
  Deferral is not resolution: the bank still has zero approved entries.
- **`F-04` (92 pre-existing failures, geospatial schema drift + ML import errors)** —
  untouched, still present on `merge_main_jed`, still outside the touched suites.
- **`D-01` — FIXED, and re-proven on the new path.**

**Identifier collision, recorded:** the bank integration report uses `F-01` for a
*different* item than the QJ report's `F-01`. Both are preserved with their originating
document named, rather than renumbered.

---

## 9. What is not true

Stated plainly so no reader infers otherwise:

- **No live QG call was made.** The budget is unchanged at 5/6.
- **No scientific acceptance exists.** Every receipt is `TEST_SCOPED_VALID` with
  `scientific_accepted: false`, `fielding_authorized: false`, `production_eligible: false`.
- **No candidate was reviewed by an entrepreneur.** The path produces candidates; CP-06
  cannot record a decision on them.
- **The question bank is empty and its authority is unsigned.** Deferring the gate did not
  create an approved item.
- **The only complete `Measurement` in the tree is a test fixture.** Every passing
  end-to-end test in §3 runs against a synthetic instrument with a fictional population.
- **`Dss` was not touched.** No DDL, no DML, no migration.
- **No explanation fallback exists for authorized findings.** The empty-claim template is
  real and tested; the fallback that a real report would need is absent (§7).
- **Nothing is committed.** All changes are in the working tree on `merge_main_jed`.

---

## 10. The next decision, and it is not a technical one

The blocker is a **research decision**, not an engineering one:

> Who authors the `Measurement` — construct, population, timeframe, stimulus, response
> coding, routing, denominator — for a real entrepreneur objective, and by what authority
> is it confirmed?

Three options, none of which this engine may choose for itself:

1. **Owner-authored measurement specification**, versioned and confirmed like an
   objective. Requires an Owner decision and a schema field. The direct path would then
   accept `AUTHORISED_PRODUCTION_SPEC`, which is already reserved and already refused.
2. **A methodologist role authors it** under a named authority. Requires a role that does
   not exist in the current model.
3. **Reinstate a QJ-equivalent authoring stage** — which the correction explicitly
   forbids. Listed only to be excluded.

Until one is chosen, the active path is complete and refuses correctly, and the last free
provider call stays unspent.
