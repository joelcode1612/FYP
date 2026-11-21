# PROJECT1 — CP-03E Consolidated Verification

**Date:** 2026-11-17
**Repository:** `sport-marketplace/FYP`, branch `merge_main_jed`, base `ba30035` (dirty tree)
**Scope:** CP-03E / CP-04 / frontend compatibility, per the six-part directive.
**Publication:** not attempted. Scientific and release gates remain unverified.

---

## 0. Verdict roll-up

| # | Checkpoint | Verdict |
|---|---|---|
| 1 | BDJ-RULE-COVERAGE-01 — M2V1 ruleset | **RESOLVED (prepared for owner review, not adopted)** |
| 2 | BDJ-QUOTE-01 — value-only quote contract | **RESOLVED — verified live, 2/2 value spans** |
| 2b | Rule-vocabulary defect (found during 2) | **RESOLVED — verified live** |
| 3 | CP-04 BCB authority mapping | **BLOCKED — 1/10 bindings resolvable** |
| 4 | Frontend/API compatibility | **COMPLETE — 22 controls traced; 2 mismatches, 1 dead component** |
| 5 | Persisted AI outputs & Activity History | **PASS for read-only honesty; FAIL for ledger→history linkage** |
| 6 | Consolidated report | this document |
| — | Authenticated browser verification | **BLOCKED — Chrome remote debugging off** |
| — | Questionnaire publication | **NOT ATTEMPTED — gates unverified** |

Tests: **170 passed, 1 skipped** (`tests/project1` + `tests/test_architecture.py`).

---

## 1. BDJ-RULE-COVERAGE-01 — resolved, and the premise had to change

### 1.1 Why a rename would have been wrong

The legacy ruleset `BDJ-RULESET-0.2-CAND` (`domain/bdj_candidate_rules.py`) is bound to the
legacy M2 instrument, whose `M2-04` is a **free-text business description**. Its rules are text
heuristics over that prose:

- `format_conflict()` — regex over M2-04 prose vs the M2-05 service code
- `explicit_unsupported_claims()` — regex for "guaranteed profit", "no competitors",
  "we calculated break-even"

The live instrument is `M2V1-20261114-1`. **Every answerable item in it is a coded
SINGLE/MULTI/GEO selection; there is no free-text item at all.** Renaming `M2-04` to `M2V1-03`
would have produced a ruleset that silently never fires, because `_raw_description()` returns
`None` when the value is not a `str`.

Proven by test: `test_legacy_ruleset_abstains_on_m2v1_because_there_is_no_free_text`.

### 1.2 Most legacy contradictions are structurally impossible on M2V1

`validate_m2_answer` (`modules/decision_engine/domain/m2_rules.py:55-103`) already rejects them
at write time, so a rule for them could never fire:

| Class | Prevented by | Live message |
|---|---|---|
| primary group ∉ selected groups | `M2V1-05` derives options from `M2V1-04` | "Answer must match one registered option value." |
| first topic ∉ selected topics | `M2V1-10` derives options from `M2V1-09` | same |
| `NONE` + concrete source | `rules.exclusive` on `M2V1-08/09` | "NONE must be exclusive." |
| `UNDECIDED` + concrete choice | `rules.exclusive` on `M2V1-03/04` | "This response must be selected on its own." |
| feedback sought while investigation declined | `M2V1-11` `requires_priority` | "This conditional item is not applicable…" |

All five were executed against the live instrument definition and rejected. They are recorded in
`bdj_m2v1_candidate_rules.STRUCTURALLY_PREVENTED`, not implemented — a rule that can never fire is
a false claim of coverage.

**Consequence for CP-03D:** the contradiction planted there (`M2V1-05 = FAMILIES`) can never exist
in persisted data. BDJ's detection of it validated the *model*, not a reachable workflow state.
Re-running the new ruleset against that derived packet yields **no proposals**, correctly.

### 1.3 The delivered ruleset — `BDJ-M2V1-0.1-CAND`

`domain/bdj_m2v1_candidate_rules.py`. Four rules, each a **presupposition failure** the validator
permits, each requiring two independently identified items so it is a `SOURCE_CONFLICT`:

| Rule | Trigger | Why it is a real conflict |
|---|---|---|
| `M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS` | `M2V1-03 = [UNDECIDED]` + `M2V1-06 ∈ {QUALITY, DISTINCTIVE_CONCEPT}` | emphasises product quality/theme while the product range is undecided |
| `M2V1_PRODUCT_PREFERENCE_UNDECIDED_PRODUCTS` | `M2V1-03 = [UNDECIDED]` + `M2V1-09 ∋ PRODUCT_PREFERENCE` | asks to compare "my planned products" when none are planned |
| `M2V1_SEGMENT_INTEREST_UNDECIDED_GROUPS` | `M2V1-04 = [UNDECIDED]` + `M2V1-09 ∋ SEGMENT_INTEREST` | measures interest "among my intended group" with no group decided |
| `M2V1_DELIVERY_WITH_ON_PREMISE_OCCASION` | `M2V1-02 = DELIVERY` + `M2V1-07 ∈ {STUDY_WORK, SOCIAL, LEISURE}` | delivery-only format cannot host a seating-dependent occasion |

The fourth is a genuine permissive gap: `rules.not_applicable_when` only *permits*
`NOT_APPLICABLE` when the format is `DELIVERY`; it does not forbid `ANSWERED`.

**Status: prepared for owner review, not adopted.** It is registered in `bdj.py:RULE_MODULES` so an
owner *can* adopt it, but `load_rules` still demands an explicit adoption receipt and matching
sha256 in settings. Nothing is active. The historical ruleset and its execution evidence are
untouched.

### 1.4 Deterministic admission verified

19 tests in `tests/project1/test_bdj_m2v1_rules.py` cover: each rule fires and cites exactly two
real items; each abstains when not implicated; an omitted optional item is never a defect; the
legacy ruleset abstains; every prevented class names its mechanism; a model finding using an
unregistered rule is refused; a model returning nothing cannot suppress a deterministic finding;
a stale source is reported and not served.

---

## 2. BDJ-QUOTE-01 and the rule-vocabulary defect

### 2.1 Deterministic and recorded-output verification (done first, no dispatch)

`scripts/cp03e_quote_contract_verification.py` — **VERDICT=PASS**, 6/6:

```
PASS  recorded_output_present      cp03d_uncertainty_fd0b4380…
PASS  recorded_had_findings        issues=2
PASS  recorded_quotes_rejected     code=BDJ_SOURCE_QUOTE_INVALID
PASS  value_span_quotes_admitted   rewritten=4 admitted=2
PASS  clean_run_passes_vacuously   issues=0 admits with allowed_rules=EMPTY
PASS  defect_is_quote_only         both findings were well-formed two-source conflicts
```

This isolates the defect precisely: rewriting **only** the `quote` field to a declaration-value
span makes the same findings admissible. Nothing else was wrong.

### 2.2 Second defect found during live verification

With the v2 prompt, the model produced value-span quotes (**3/3**) but returned
`rule_id = "BDJ-001"` — an invented identifier — against an allowed set of
`["M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS"]`. Result: `BDJ_RULE_NOT_REGISTERED`, candidate
rejected. **Nothing told the model which rule identifiers are registered.**

Fix: `BDJEngine.review` now passes `rule_catalogue` (the sorted allowed rule ids) to the model
(`bdj.py`), and prompt v3 requires `rule_id` to be copied exactly from
`source_data.rule_catalogue`. The catalogue is policy, not source data, and does not alter
`source_fingerprint` (asserted by test).

### 2.3 Live verification — PASS

`scripts/cp03e_m2v1_live_admission.py`, run `bb54ef7b-b7cf-4861-bb07-2feaf764ce31`,
prompt `BDJ-SOURCE-3-CAND`, against a **representable** contradiction
(`M2V1-03=[UNDECIDED]`, `M2V1-06=QUALITY`):

```
PASS  packet_representable         b611fbf8266c -> 6466a48ca090
PASS  deterministic_proposal_fired M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS
PASS  run_provisioned              run_id=bb54ef7b-…
PASS  engine_returned              outcome=reviewed
PASS  admitted_findings            ['M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS', …]
PASS  admitted_rule_is_registered  every admitted finding maps to a deterministic proposal
PASS  no_authority_asserted        candidate-only; no scientific or release authority
PASS  audit_readback               identity=p1ai_audit rows=1 outcome=returned
PASS  quote_contract_value_span    2/2 value spans
PASS  rules_within_allowed         outside=[]
VERDICT=PASS
```

This is the first run where a **live cloud candidate survived the full admission path** and
appeared as a finding with `finding_authority=CANDIDATE_ONLY`.

### 2.4 Timeouts preserved, never counted as success

Runs `7948190f` and `5f634520` (v2, 30s and 45s) both ended
`E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN`. The ledger records `unknown_outcome`; no retry was issued;
neither was ever reported as validated. TLS reachability to the provider was 0.29s at the time of
the later runs, so the failures were model-level, not connectivity.

### 2.5 Prompt version history (all preserved in the ledger)

| Version | Status | Reason |
|---|---|---|
| `BDJ-SOURCE-1-CAND` | retired | "verbatim source quotes" did not name the field → question text quoted, 0/4 admissible |
| `BDJ-SOURCE-2-CAND` | retired | value-only quotes fixed, but no rule vocabulary → invented `BDJ-001` |
| `BDJ-SOURCE-3-CAND` | **active** | states both contracts; live-verified |

Historical rows keep their own `prompt_hash`, so older attempts stay interpretable.

---

## 3. CP-04 BCB authority readiness — BLOCKED

> **Superseded for the verdict by CP-04B** (`PROJECT1_CP04_BCB_AUTHORITY_AND_CONTEXT_REPORT.md`,
> 2026-11-17). This section records what the CP-04 probe measured on 2026-11-17
> and is retained unchanged. CP-04B re-derived the requirement from the builder
> and split the count: `STRUCTURAL=1/10`, `OPERATIONAL=0/10`. The `resolvable=1`
> below is a structural figure and should not be read as "one binding works".

`scripts/cp04_bcb_binding_readiness.py` — **VERDICT=BLOCKED**, `resolvable=1 missing=9`.

| Binding | Refusal code if absent | Status | Classification |
|---|---|---|---|
| `request.tenant_id` | `ACCESS_DENIED` | MISSING | **pending governance** (tenancy model) |
| `bindings.snapshot_id` | `SNAPSHOT_SCOPE_INVALID` | MISSING | missing source data |
| `bindings.concept` | `CONCEPT_MISSING`/`STALE` | MISSING | missing source data + integration |
| `bindings.current_concept_version` | `CONCEPT_STALE` | MISSING | missing source data |
| `bindings.geography` | `GEO_UNAPPROVED` | MISSING | **pending governance** (approved GEO source) |
| `bindings.rule_versions` | `FINDING_VERSION_INVALID` | MISSING | missing source data (0 findings at rev 12) |
| `bindings.finding_authorities` | `FINDING_AUTHORITY_INVALID` | MISSING | missing source data |
| `bindings.uncertainty` | `UNCERTAINTY_NOT_CONFIRMED` | **RESOLVABLE** | missing integration (no read accessor) |
| `bindings.sources` | `SOURCE_QUALIFICATION_INVALID` | MISSING | **pending governance** (evidence qualification) |
| `decision` | `ACCESS_DENIED` | MISSING | **pending governance** (access-decision service) |

**Structural fact:** `tenant_id` and `concept_version` exist as columns in exactly one table —
`m2_business_contexts`, the BCB **output**. No source table defines them. The output schema
anticipates an authority layer that does not exist.

No concept, tenant, geographic or scientific authority record was fabricated. `UnverifiedContextBindings.resolve()`
still raises by design.

### 3.1 Two measurement traps caught (methodology)

1. **`information_schema` is privilege-filtered.** As the app role it reported 12 relations, which
   would have "proved" no concept/tenant tables exist. Via `pg_class`: **70 in `public`, 74 in `Dss`**.
2. **RLS + transaction-local `set_config`.** `count(*)` returned 0 for `m2_assessments` while the
   repository read an assessment fine — RLS hid rows, and `M2SourceProjection.read()` rolls back in
   `finally`. Live counts in one transaction: 2 assessments, 12 answers, 1 confirmation, 0 findings,
   1 uncertainty, 0 contexts.

Both are the same error class: *true of the label, false of the thing labelled.*

---

## 4. Frontend compatibility matrix

Method: full read of `m2_workflow_panel.dart`, `m2_activity_panel.dart`,
`assessment_workspace_page.dart`, `activity_history_page.dart`, `report_activity_views.dart`,
`assessment_api.dart`, `api_m2_repository.dart`, cross-checked against `router.py`, `m2.py`,
`m2_route.py`, `m2_business_context.py`, `project1_workflow.py`. 22 active controls traced.
The two highest-impact findings were independently re-verified by me (see §5).

**Mounting:** `/api/v1` (`main.py:144`). `/m2` mounts only when `m2_upstream_enabled`
(`router.py:122`); `/project1-workflow` only when `project1_workflow_enabled` (`router.py:113`).
With a flag off, every path below is 404.

### 4.1 BDJ — the question asked directly

**The BDJ button runs deterministic BDJ. It never runs cloud BDJ.**

- `m2_workflow_panel.dart:678` → `_evaluate` `:292` → `m2.evaluate` `:302`
- `api_m2_repository.dart:199` builds `POST /api/v1/m2/assessments/{id}/bdj/evaluate`
- served by `m2.py:156` → `BDJService.evaluate` (`bdj_service.py:21`)
- worksheet read: `api_m2_repository.dart:412` → `GET .../business-understanding` → `m2.py:161` → `BDJService.read_worksheet`
- tables: `m2_assessments`, `m2_bdj_findings`, `m2_bdj_evaluations`, `m2_answer_revisions`,
  `m2_item_versions`, `m2_instrument_versions`, `m2_clarification_events`

The cloud path is a **different route and a different engine**: `project1_workflow.py:87`
`POST /project1-workflow/assessments/{id}/business-understanding` → `BDJEngine`. **No Dart file
references it**, and it is also deterministic (`project1_workflow.py:97-100`, "Deliberately no
cloud runner here"). No control was silently switched to cloud execution; the adopted
authorization and workflow contracts are unchanged.

### 4.2 Route resolution

**Zero missing endpoints by path.** All 18 M2 paths in `api_m2_repository.dart`
(`:133/149/156/159/174/199/206/241/253/282/312/337/357/377/396/412/421/426`) resolve to a
registered decorator. The availability risk is conditional mounting, not wrong paths.

### 4.3 Backend routes never called by the UI (16)

Including `POST .../findings/{fid}/decisions` (`m2.py:112`), `POST /m2/confirmations/{cid}/uncertainty`
(`m2.py:180`), `POST .../business-context` (`m2_business_context.py:86`),
`GET .../business-contexts/{cid}` (`:98`), `GET .../source-projection` (`m2.py:68`), and the entire
`/project1-workflow/*` surface. Dart methods `decide()`, `confirmUncertainty()`, `buildContext()`,
`readContext()`, `source()` exist but have **no call sites**.

---

## 5. Missing or mismatched UI integration

| # | Defect | Evidence | Impact |
|---|---|---|---|
| **UI-01** | **No control calls `decide()`**, but `ConfirmationService.confirm` requires a persisted `KEEP_ORIGINAL` decision for every current finding (`confirmation_service.py:124-127`) | `decide()` has no M2 call site (verified by grep) | **Any assessment with ≥1 finding can never be confirmed — always 409.** Blocks the whole downstream chain |
| **UI-02** | `origin` read at the wrong level | panel `:775` reads `result['origin']`; backend emits `result['source']['origin']` (`confirmation_service.py:197-199, 222`) — **re-verified by me** | objective line always renders `origin —` |
| **UI-03** | Conditional options ignored | panel `:191-200` reads `option_values.options`; backend validates against `effective_options` and `applicable` (`m2_rules.py:21-37, 61-63, 73, 86-92`) | offers codes the server rejects → guaranteed 422 on `M2V1-05/10/11` |
| **UI-04** | Dead component | `business_understanding_panel.dart` is defined but never mounted | the only client of `/project1-workflow` is unreachable |
| **UI-05** | Two "BDJ" renderers disagree | panel `:660-716` renders real `m2_bdj_findings`; workspace `:2332 _bdjFindingCard` renders **catalogue evidence metrics** labelled "BDJ findings" | same words, different object |
| **UI-06** | Step-3 "objective works" completes the **wrong stage** | `assessment_workspace_page.dart:2648-2655` calls `_completeStage(record, 'location_evidence')` | BDJ objective decision is never persisted; session state only |
| **UI-07** | Cross-language digest equality untested | `api_m2_repository.dart:265-268` recomputes the snapshot digest in Dart vs Python `json.dumps(sort_keys=True, separators=(",",":"))` | confirmation may throw on byte-level drift; no test covers it |
| **UI-08** | Missing authority flag accepted | `api_m2_repository.dart:340, 342` treat a **missing** `qj_execution_authorized` as acceptable | a response omitting the authority flag passes the check |

---

## 6. Persisted AI outputs and Activity History fidelity

### 6.1 Ledger → result linkage: **FAIL**

The ledger records the attempt and `output_digest`, but **no persisted row links a ledger run to a
BDJ finding**. `m2_bdj_findings` has no `run_id`, `attempt_id` or `output_digest` column, and
`project1_ai` has no output table. The cloud result of run `bb54ef7b` exists only as
`backend/backups/cp03e_bb54ef7b…/result.json`, outside PostgreSQL.

So the chain is: *ledger attempt → digest* (in `project1_ai`) and *finding → assessment* (in
`m2_bdj_findings`), with **no durable join between them**. Activity History therefore cannot show
that a given finding came from a cloud execution, and does not claim to.

### 6.2 Rejected and timed-out executions remain auditable: **PASS**

| Run | Outcome | Appears as a finding? |
|---|---|---|
| `cdfc5a2b`, `10d840cf` | rejected | no |
| `96cefb30` | returned, 0 issues | no (nothing to show) |
| `fd0b4380` | returned, 2 issues | no — rejected by admission |
| `7948190f`, `5f634520` | unknown_outcome | no |
| `9aefb13d`, `79ee04e1` | returned, rejected by admission | no |
| `bb54ef7b` | returned, **admitted** | yes, in the run evidence only |

All nine attempts are durable in `project1_ai` with their outcome. None of the failed ones is
presented as an accepted finding. `outcome='unknown_outcome'` is never treated as success.

### 6.3 Activity History honesty: **PASS**

- Read-only at both UI and HTTP level: only `GET` verbs in `m2_activity_panel.dart` and
  `activity_history_page.dart`; every other control is `setState`, clipboard or navigation.
- Renders **real persisted rows**, projected from `m2_answer_revisions`, `m2_bdj_evaluations`,
  `m2_reviews`, `m2_confirmation_snapshots`, `m2_clarification_events`, `m2_bdj_findings`,
  `m2_confirmed_uncertainties`, `m2_business_contexts`, `m2_business_context_builds`.
- On failure it sets `activity = null` and displays
  *"No substitute activity records are shown."* (`m2_activity_panel.dart:96-97`). No synthetic
  success data.
- Caveat: the server-side read takes a `FOR UPDATE` lock (`m2_repository.py:181-184`) — no rows
  change, but the read serialises against writers.
- Cosmetic: `status` is `null` for `ANSWER_SAVED`/`REVIEW_RECORDED`/`CONTEXT_CONFIRMED` because the
  repo reads a non-existent `decision` column (`m2_repository.py:60`) → UI prints
  "Recorded — outcome not supplied".

---

## 7. Tests and browser verification

| Suite | Result |
|---|---|
| `tests/project1` + `tests/test_architecture.py` | **170 passed, 1 skipped** |
| `tests/project1/test_bdj_m2v1_rules.py` (new) | 19 passed |
| `tests/project1/test_workflow.py` quote regression | 3 cases pass |
| `tests/api` | 48 pre-existing failures (recommendation search returns 200 with empty `data`); unrelated to project1 |
| Pre-existing collection errors | missing `rasterio`; `CATEGORY_BACKGROUND_CSV` import |

**Authenticated browser verification: BLOCKED.** Chrome remote debugging is off, so no browser
journey was executed. No UI claim in this document rests on browser evidence; §4-§6 come from code
inspection, and the two highest-impact items (UI-01, UI-02) were re-verified directly.

---

## 8. Files changed

| File | Change |
|---|---|
| `backend/src/sitewise/domain/bdj_m2v1_candidate_rules.py` | **new** — `BDJ-M2V1-0.1-CAND`, 4 rules + `STRUCTURALLY_PREVENTED` register |
| `backend/src/sitewise/project1/bdj.py` | register the M2V1 ruleset; pass `rule_catalogue` to the model |
| `backend/src/sitewise/project1/prompts.py` | BDJ prompt v3 (value-only quote + rule vocabulary) |
| `backend/src/sitewise/project1/contracts.py` | `SourceRef.quote` schema description (value-only) |
| `backend/tests/project1/test_bdj_m2v1_rules.py` | **new** — 19 tests |
| `backend/tests/project1/test_workflow.py` | quote-contract regression (3 cases) |
| `backend/scripts/cp03e_quote_contract_verification.py` | **new** — recorded-output verification |
| `backend/scripts/cp03e_m2v1_live_admission.py` | **new** — bounded live admission test |
| `backend/scripts/cp04_bcb_binding_readiness.py` | **new** — binding readiness probe |

No endpoint was duplicated and no second database system was created. The FastAPI architecture and
the completed frontend design are unchanged.

---

## 9. Reproduction

```bash
cd sport-marketplace/FYP/backend
./.venv/Scripts/python.exe -m pytest tests/project1 tests/test_architecture.py -q   # 170 passed
./.venv/Scripts/python.exe scripts/cp03e_quote_contract_verification.py             # PASS (no dispatch)
./.venv/Scripts/python.exe scripts/cp04_bcb_binding_readiness.py                    # BLOCKED 1/10
./.venv/Scripts/python.exe scripts/cp03e_m2v1_live_admission.py                     # 1 live call
```

Evidence: `backend/backups/cp03e_bb54ef7b-b7cf-4861-bb07-2feaf764ce31/result.json`
