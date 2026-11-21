# PROJECT1 — LLM Responsibility Verification and Architecture Freeze

**Date:** 2026-11-17 · **Branch:** `merge_main_jed`
**Purpose:** verify what is already implemented before any change. No module was refactored, no prompt
edited, no schema altered. This is a read-and-report pass.

**Verdict: `RESPONSIBILITY_REDESIGN_NOT_REQUIRED`.** No responsibility defect was found in any of the
five modules. The blockers are integration and authorization gaps, not design errors.

---

## 1. Verification table

| Module | Established responsibility | Actual implementation | LLM required? | Test evidence | Genuine blocker | Recommendation |
|---|---|---|---|---|---|---|
| **BDJ** | Review entrepreneur-declared M2 statements for inconsistency, ambiguity, unsupported assertion. No viability judgment. | `bdj.py:24-145`; prompt `BDJ-SOURCE-3-CAND` (`prompts.py:39`); deterministic rules `bdj_candidate_rules.py` `RULE_CATALOGUE` (11 rules, `IMPLEMENTED_CANDIDATE`); `validate_candidates()` `bdj.py:33` | **Optional.** Deterministic path runs with `rules=None` runner (`project1_workflow.py:146`); cloud path uses the runner | 66 tests in `test_workflow.py`; 36 contract tests; 246 total | None for responsibility | `PRESERVE` |
| **BCB** | Construct a versioned Business Context Package from confirmed M2 + permitted BDJ findings + confirmed uncertainty, preserving provenance. | `business_context_v1.py` (355 lines, provider-independent, read-only); `current_business_description()` renders the template; `_FrozenM2` pins M2/BDJ/confirmation in one RR transaction | **No.** Zero runner/prompt references | `test_workflow.py`, `tests/m2_bcb` 42 passed on a disposable cluster | `UnverifiedContextBindings.resolve()` raises before any read (`business_context_repository.py:20-21`, called at `persisted_business_context_service.py:91`) | `PRESERVE` + `INTEGRATION_FIX` + `OWNER_DECISION_REQUIRED` on `tenant_id` |
| **QJ** | Decide research-measurement suitability for a confirmed uncertainty. Four registered routes; survey candidate requires frozen measurement fields else HOLD. | `research.py:135` `self.runner('QJ', qj_input, QJOutput)`; prompt `QJ-MEASURE-1-CAND`; validators `validate_measurement()` `research.py:29`, `authority.admit_qj()`, `authority.validate_measurement()` | **Yes, one call** | `test_workflow.py:222` constructs `ResearchWorkflow`; 66 tests pass | `ResearchWorkflow` is constructed **only in tests** — no production caller | `PRESERVE` + `INTEGRATION_FIX` |
| **QG** | Reuse approved bank items first; draft only when the bank returns `verified_no_equivalent`; never self-approve. | `research.py:152-160`; prompt `QG-FROZEN-1-CAND`; `validate_draft()` `research.py:48` enforces frozen measurement, exact stimulus/population/timeframe, no unsourced numbers, abstention must not contain a question | **Conditional** — only on the drafting branch | Same suite | Same as QJ (no production wiring) | `PRESERVE` |
| **Explanation** | Explain authorized findings; deterministic fallback available without an LLM. | `explanation_contracts.py` — `BANNED_PHRASES`, `NON_EVIDENCE_STATUSES`, `_NUMBER_RE`, `validate_candidate()`; `insufficient_evidence_output()` `:81` "No LLM call for an empty claim set"; prompt `EE01-EXPLANATION-1-CAND` | **Optional** | 15 tests in `tests/api/test_ee01_explanation.py`, all pass | No deterministic template for the **authorized-finding** case (see §3.5) | `PRESERVE` + flag the missing fallback |

## 2. Deterministic versus LLM, per module

| Module | Deterministic | LLM-assisted |
|---|---|---|
| BDJ | rule catalogue, `validate_candidates()` (exact refs, exact quotes, registered `rule_id`), `recheck_current` staleness | candidate identification |
| BCB | **entirely** — Business Description template, M2 resolution, finding permission filter, provenance pinning, packet hash | none |
| QJ | `validate_measurement()`, `admit_qj()`, independent `validate_measurement` authority | route selection + measurement proposal |
| QG | bank lookup, `verify_receipt()`, `validate_draft()` | drafting on the no-equivalent branch only |
| Explanation | guards, insufficiency output | interpretation of authorized claims |

Only BDJ's prompt version is read outside its own module (`model_assisted.py:135`, `runs.py:37` — for
`prompt_version` provenance). The QJ, QG and EXPLANATION prompts have **no caller in `src/`** other than
the injected `runner` in `research.py`; nothing in production constructs that runner.

## 3. Answers

### 3.1 Are the existing LLM responsibilities adequately defined?

**Yes.** All five are defined in versioned prompts that state the boundary explicitly, and each is
backed by deterministic validators that the model cannot bypass:

- BDJ must copy `rule_id` from `source_data.rule_catalogue` and quote an exact substring of the
  declaration's `value`; `validate_candidates()` rejects anything else. The prompt history records two
  retired versions and *why* (`prompts.py:33-38`), which is the strongest evidence the boundary is
  enforced rather than aspirational.
- QJ must return one of four registered routes and cannot prove profit from perception.
- QG cannot draft without a verified no-equivalent receipt and cannot alter the frozen measurement.
- Explanation cannot calculate, and `validate_candidate()` blocks banned phrases and unsourced numbers.
- BCB uses no LLM at all.

### 3.2 Is there actual duplication between BDJ and QJ?

**No.** They read different inputs and answer different questions.

| | BDJ | QJ |
|---|---|---|
| Input | M2 packet declarations + `rule_catalogue` | BCB packet + `confirmed_uncertainty` + research objective |
| Question | is this declared statement internally inconsistent or unsupported | what measurement can test this uncertainty |
| Output | findings with source refs | one of four routes + optional measurement |
| Re-validates M2? | yes, that is its job | **no** — `checked_context()` requires a `CURRENT_CONFIRMED` BCB packet and a confirmed uncertainty (`research.py:12-27`) |

`research.py` never calls `validate_candidates()`. The shared vocabulary is only `WorkflowHeld` and the
`no_authority()` spread, which is shared convention, not shared responsibility.

### 3.3 Does BCB require an LLM to construct its core context?

**No.** `business_context_v1.py` contains no runner, provider, prompt or model reference. The Business
Description is a deterministic template over M2V1 items 01–06 (`current_business_description`), and the
package is hashed and pinned. BCB is the one module where "LLM required" is unambiguously **no**.

### 3.4 What specifically prevents BCB from using existing confirmed M2 information?

Two distinct things, and they are often conflated:

1. **The resolver raises before any M2 read.** `_build()` calls `unit.resolve_inputs(selection, actor)`
   at `persisted_business_context_service.py:91`, and `UnverifiedContextBindings.resolve()` raises
   `ContextBindingUnavailable()` unconditionally (`business_context_repository.py:20-21`). No M2 row is
   read at all. This is a fail-closed placeholder, not a data problem.
2. **Two required fields have no source.** `get_context()` validates that `tenant_id` and
   `concept_version` are non-empty (`business_context_v1.py:120-121`). Neither has a source table:
   `tenant_id` exists only as a `NOT NULL` column on the **output** table
   (`business_context_schema.py:19`) and in the persistence migration; `concept_version` exists only as
   a constant in the unrelated `cq_successor/contracts.py:61`. Supplying either by guess is exactly what
   the resolver refuses to do.

Everything else BCB needs is already available and already read: `_FrozenM2` loads assessment,
confirmation, instrument, items, latest answers and findings in one transaction, and pins them with
`pins_match()`.

One more measured fact that matters: BCB reads findings from `public.m2_bdj_findings`, and that table
holds **0 rows on `Dss`** and **192 on the clone**. Cloud model-assisted results go to
`project1_ai.bdj_results` and are **not** bridged into `m2_bdj_findings`. So even with a resolver, a
confirmed revision with no deterministic BDJ evaluation has no findings to permit.

### 3.5 Does a deterministic explanation fallback exist?

**Partially, and the gap should be named precisely.** `insufficient_evidence_output()` is deterministic
and makes no LLM call — but it covers only the **empty claim set**. There is no deterministic template
that explains an **authorized** finding. `grep -rn template src/sitewise/services src/sitewise/project1`
returns only `business_context_v1.py` and `prompts.py`.

So the requirement "deterministic template fallback must remain available without an LLM" is satisfied
for the zero-evidence path and **not** satisfied for the authorized-finding path. This is genuine
missing functionality, not an integration gap — stated so it is not discovered later as a surprise.

### 3.6 Why ten authority bindings, and which are essential?

The readiness report lists nine rows; the tenth is `purpose`/access-decision, supplied by the request
rather than resolved. Status measured previously and not re-measured here:

| Binding | Status |
|---|---|
| `request.tenant_id` | MISSING — no source table defines it |
| `bindings.snapshot_id` | MISSING — no snapshot registry |
| `bindings.concept` / `current_concept_version` | MISSING — no concept table |
| `bindings.geography` | MISSING — no approved GEO_V1 catalogue |
| `bindings.rule_versions` | MISSING — `m2_bdj_findings` has the columns, 0 rows on `Dss` |
| `bindings.finding_authorities` | MISSING — no `finding_hash` / `review_event_id` |
| `bindings.sources` | MISSING — no external source qualification table |
| `bindings.uncertainty` | **RESOLVABLE** — 3/3 columns, 1 row |

Classification: **`tenant_id` and `concept_version` are structurally required** (validated at
`business_context_v1.py:120-121`). `geography`, `sources` and `finding_authorities` are **conditional on
external evidence and reporting** and are not needed to construct a context for the `QJ_CONTEXT` purpose.
None are "unnecessary duplication" — but they are not all needed at once, and the resolver currently
treats them as an all-or-nothing gate.

### 3.7 Which components can be connected without changing their responsibilities?

All of them. No signature changes are needed:

- `ResearchWorkflow(builder, authority, bank, runner)` — already dependency-injected; it needs a caller,
  not a redesign.
- `BdjResultStore` / `results_for_assessment` — already written and tested.
- `PersistedBusinessContextService` — already takes a `resolver_factory`; it needs a real factory.
- `_FrozenM2` — already reads everything BCB needs.
- The Explanation module — already takes an injected service and holds cleanly when unconfigured.

### 3.8 Smallest set of fixes for the next M2 → BDJ → BCB → QJ integration test

Four items, in order, none of which changes a responsibility:

1. **A production `ContextBindingsResolver`** that resolves only the bindings the requested purpose
   needs, instead of raising unconditionally. Requires the `tenant_id` decision (§3.4, B4-1) and an
   approved `concept_version` constant.
2. **An `AuthorizationPort` implementation** for `purpose`/`role` (currently only a test `_Authorizer`).
3. **`m2_bdj_findings` rows for the confirmed revision** — produced by the deterministic
   `/bdj/evaluate` path. Cloud results are not bridged, so a cloud-only assessment cannot feed BCB.
4. **A route that constructs `ResearchWorkflow`** with a real `runner`; today it is constructed only in
   `tests/project1/test_workflow.py:222`.

Items 1 and 2 are `INTEGRATION_FIX`; item 1 additionally needs `OWNER_DECISION_REQUIRED` for `tenant_id`.

## 4. Change classification

| Change | Class | Reason |
|---|---|---|
| BDJ responsibilities | `PRESERVE` | enforced by validators, two prompt retirements documented |
| BCB construction | `PRESERVE` | deterministic, provider-independent, already implements the Business Description template |
| QJ / QG responsibilities | `PRESERVE` | distinct inputs, bank-first, no self-approval |
| Explanation guards | `PRESERVE` | banned phrases, non-evidence statuses, unsourced-number rejection |
| BCB resolver | `INTEGRATION_FIX` | correct contract, no production implementation |
| `tenant_id` source | `OWNER_DECISION_REQUIRED` | ownership vs tenancy registry; cannot be guessed |
| QJ/QG route wiring | `INTEGRATION_FIX` | `ResearchWorkflow` has no production caller |
| Explanation deterministic template for authorized findings | genuine missing functionality | only the insufficiency path is LLM-free |
| Ten-binding all-or-nothing gate | `UNNECESSARY_COMPLEXITY` **only for the construction path** | the full set is not needed for `QJ_CONTEXT`; do not remove any check without an approved contract decision |

## 5. Freeze statement

No file in `src/`, `tests/`, `migrations/` or any prompt was modified by this verification. The only
artefact produced is this report.

`RESPONSIBILITY_REDESIGN_NOT_REQUIRED`

Engineering effort should go to the four items in §3.8, and to the `Dss` migration approval already
prepared in `CP04A_CORRECTED_MIGRATION_DSS_APPROVAL_REQUEST.md`.
