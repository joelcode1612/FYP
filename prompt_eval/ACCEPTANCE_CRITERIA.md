# CP-04 — Acceptance criteria and predefined expected behaviour

Written **before** any paid dispatch. Every criterion below is stated so that a
reviewer can decide it from the response alone, without asking the model to
grade itself.

## Evidence standard

| Level | Meaning | Counts as |
|---|---|---|
| E1 | Prompt text exists and is versioned | Necessary, never sufficient |
| E2 | Deterministic fixture / schema check passes | Structural validity only |
| E3 | Reproducible run against the model, evidence retained | Behavioural evidence |
| E4 | Owner verification through the application | Closure |

CP-04 delivers **E2**. Nothing in this workspace is E3 until a live pilot runs,
and nothing is E4 until the owner verifies it in the UI.

A golden output is a **specification**, not a result. It is never counted as
evidence that a prompt works.

---

## 1. Hard acceptance criteria (pass/fail, no judgement)

These are the same for V4 and V5. A version that fails any of them is not
eligible for adoption, regardless of how good its research content looks.

| # | Criterion | How it is decided |
|---|---|---|
| H1 | Response parses against the declared contract | Pydantic / `json_schema` strict |
| H2 | No invented business fact | `QG_UNSOURCED_NUMBER`, `QG_UNSOURCED_AMOUNT`, `BDJ_OBJECTIVE_SOURCE_INVALID` |
| H3 | Every citation resolves to an ANSWERED declaration with matching ids | `BDJ_OBJECTIVE_SOURCE_INVALID` |
| H4 | A gap is established by a declaration that can establish one | `BDJ_OBJECTIVE_SOURCE_NOT_SUPPORTING` |
| H5 | No prohibited claim | `BDJ_OBJECTIVE_CLAIM_NOT_ALLOWED`, `PROHIBITED_*` |
| H6 | Objective is a research statement, not a question | `BDJ_OBJECTIVE_PHRASING_INVALID` |
| H7 | Routing keyed by exact codes; every target `END` | `QG_ROUTING_DRIFT`, `QG_ROUTING_TARGET_UNVERIFIED` |
| H8 | Denominator names declared codes | `QG_DENOMINATOR_DRIFT` |
| H9 | Options: 2–12, unique codes and labels, `order` 0..n−1 | `QG_RESPONSE_CODING_DRIFT`, `QG_OPTION_ORDER_INVALID` |
| H10 | Abstention and draft are mutually exclusive | `QG_ABSTENTION_CONTAINS_QUESTION`, `QG_ABSTENTION_CONTAINS_MEASUREMENT` |
| H11 | No fixed objective O1–O6 is created, retired, renumbered or re-ranked | `objective_registry.mandatory_status` + `BDJ_V2_RESTATES_FIXED_OBJECTIVE` |
| H12 | Duplicate objectives are not returned | `BDJ_OBJECTIVE_DUPLICATE_RECOMMENDATION`, `BDJ_V2_DUPLICATE_CONSTRUCT` |

H1–H12 are all exercised by `scripts/run_fixtures.py` with zero network calls.

---

## 2. Research criteria (rubric, scored by a reader)

Structural validity says nothing about whether an objective is worth researching.
These are scored by a reviewer reading the response against the declarations, not
by a second model call — the brief forbids adding LLM calls to evaluate criteria
during normal execution, and a self-graded rubric is not independent anyway.

Score each proposal 0–2 on each row.

| # | Criterion | 0 | 1 | 2 |
|---|---|---|---|---|
| R1 | Uncertainty is identified, not asserted | Restates a decision | Vague or partly inferred | Names a specific unresolved thing from the declarations |
| R2 | Source grounding | No ref, or a ref that does not establish it | Ref valid but weak | Ref establishes it; extra refs are the subject, not padding |
| R3 | Objective is answerable by customers | Not answerable | Partly | Directly answerable by the named population |
| R4 | Justification is business-relevant | Generic | Plausible but unspecific | Names the decision it changes |
| R5 | Business decision supported | Absent or is a claim | Named but vague | Named, concrete, and genuinely turns on this evidence |
| R6 | Customer-research suitability | Wrong | Declared but unargued | Correct verdict with a reason tied to who can answer |
| R7 | Construct is named and measurable | Prose or missing | Named but unmeasurable | Named construct a fixed-option item can measure |
| R8 | Measurement approach is feasible | Contradicts the format | Plausible | Format, population and stimulus all stated and compatible |
| R9 | Expected evidence is honest | Overclaims | Vague | States what would and would not be established |
| R10 | Limitations are specific | Boilerplate | Generic | Names the exact misreading this result invites |
| R11 | Abstention discipline | Invents an objective | Hedges | Proposes nothing when nothing is justified |
| R12 | Conciseness | Essay | Padding | One sentence per field, no restatement |

A proposal scoring 0 on R1, R2 or R7 is rejected regardless of total: those three
are the difference between research and decoration.

---

## 3. Expected behaviour, fixed per case

`prompt_eval/fixtures.py` declares, for each case, what a compliant response must
do. The table is the contract between the fixtures and the comparison.

### BDJ

| Case | Split | Expected |
|---|---|---|
| `bdj_undecided_scalar` | dev | One `MOST_SUGGESTED`, cites `M2V2-01`, objective is a statement |
| `bdj_priced_hypothesis` | dev | One `MOST_SUGGESTED`, cites `M2V2-18` (establishes); `M2V2-11`/`M2V2-14` may accompany |
| `bdj_all_definite` | dev | **Empty array** preferred; a `SUGGESTED` with no refs is tolerated; a gap invented from `DINE_IN` is a failure |
| `bdj_unsuitable_for_customers` | heldout | Proposes nothing, or marks `NOT_SUITABLE` and does **not** raise it as a customer gap |
| `bdj_duplicate_construct` | heldout | Exactly one proposal; same construct + same source is a duplicate even if wording differs |
| `bdj_conflicting_declarations` | heldout | `M2V2-18 NOT_ESTABLISHED` is not citable as an established gap; `M2V2-11 EXPLORE` is |

### Direct-QG

| Case | Split | Expected |
|---|---|---|
| `qg_complete_offer` | dev | `DRAFT`, `SINGLE_CHOICE`, 4 options, opt-out present and named as excluded |
| `qg_missing_price` | dev | `ABSTAIN_NEEDS_REVIEW`, empty question, `PRICE` named |
| `qg_ambiguous_measurement` | heldout | `ABSTAIN` on `OBJECTIVE`; no fabricated closed question |
| `qg_binary_format` | heldout | `DRAFT`, `BINARY_CHOICE`, exactly 2 options |
| `qg_unsourced_offer_component` | heldout | Must not introduce an unconfirmed size |

---

## 4. Research standards compliance matrix

The brief cites **ROAS-V1** and **QGAS-V1** as previously supplied. **Neither
document is present in this repository** (searched `*.md`, `*.py`, `*.json`,
`*.txt`; no match). The matrix below is therefore built against the requirement
list as restated in the brief, and must be re-checked against the original
standards when they are supplied. Claiming compliance with a document nobody in
this repository has read would be exactly the kind of unearned assertion the
brief forbids.

### BDJ — the ten required fields

| Required element | Field in `bdj-objective-proposal/2` | Enforced by |
|---|---|---|
| Identified business uncertainty | `business_uncertainty` | required; non-blank when `MOST_SUGGESTED` |
| Supporting confirmed source references | `source_refs` | exact-id match + must establish |
| Research objective | `research_objective` | opener rule, no `?`, no claim phrase |
| Concise research justification | `research_justification` | required, ≤ 600 chars |
| Business decision supported | `business_decision` | required, claim-scan |
| Customer-research suitability | `customer_research_suitability` | must lead with a registered verdict; `NOT_SUITABLE` may not be a `MOST_SUGGESTED` gap |
| Proposed measurement construct | `measurement_construct` | `^STATED_[A-Z0-9_]+$`, no collision with O1–O6 |
| Preliminary measurement approach | `measurement_approach` | required, ≤ 600 chars |
| Expected evidence | `expected_evidence` | required, claim-scan |
| Interpretation limitations | `interpretation_limitations` | required; claim-scan excluded on purpose (DEF-02) |

| Constraint | Where it lives |
|---|---|
| Six mandatory objectives preserved independently | `objective_registry.OBJECTIVES` (O1–O6, `mandatory=True`); prompt forbids restating them; `linked_fixed_objective` is the only reference channel |
| No duplicate objectives | `BDJ_OBJECTIVE_DUPLICATE_RECOMMENDATION` (wording) + `BDJ_V2_DUPLICATE_CONSTRUCT` (construct+source) |
| Return nothing when nothing is justified | Empty `recommendations` is explicitly valid; `bdj_all_definite` fixes this as the expected behaviour |
| No invented prices / products / uncertainties / customer characteristics | `source_refs` must resolve; claim scan; `QG_UNSOURCED_*` on the QG side |
| Concise structured output | per-field caps + "one sentence" instruction |
| Reuse the existing contract | v2 is additive; `problem`→`business_uncertainty`, `reason`→`research_justification`, `source_refs` and `research_objective` unchanged |

### Direct-QG — the nine required elements

| Required element | Field | Enforced by |
|---|---|---|
| Question stem | `question` | non-empty on `DRAFT`, ≤ 2000 |
| Response format | `fixed_measurement.response_format` | one of five |
| Complete response options | `response_options` / `options` | 2–12, entry-by-entry equality |
| Meaningful option labels | `label` | 1–500, non-blank, unique |
| Stable option codes | `code` | `^[A-Z][A-Z0-9_]{0,63}$`, unique |
| Selection constraints | `min_selections`, `max_selections`, `exclusive_codes` | format-dependent |
| Measurement alignment | `construct_interpretation` | required, claim-scan |
| Concise interpretation explanation | `fixed_measurement.interpretation` | required |
| Measurement limitations | `limitations` (both levels) | ≥ 20 chars, required |

| Constraint | Where it lives |
|---|---|
| Reuse supported routing / response contracts | `routing` keyed by exact codes, every target `END` |
| No unsupported routing rules | `QG_ROUTING_TARGET_UNVERIFIED` |
| No repeat of the BDJ analysis | prompt: "do not restate the BDJ research analysis" |
| No regeneration of Q01–Q13 | prompt: "do not regenerate the fixed questions Q01-Q13" |
| Smallest justified number of questions | prompt: one question is the default, two at most |
| Abstain with an explicit reason when unmeasurable | `ABSTAIN_NEEDS_REVIEW` + `missing_business_facts` + justification |
| Additional-question routing and EE-01 deferred | not implemented here, by instruction |

---

## 5. Performance criteria (CP-05)

Proposed targets, recorded as proposals rather than capabilities.

| Metric | Target | Measured for V4/V5? |
|---|---|---|
| BDJ median | ≤ 15 s | **No** — only the prior pair was measured |
| BDJ P95 | ≤ 30 s | **No** — n too small in any available evidence |
| Direct-QG median, one objective | ≤ 10 s | **No** |
| Direct-QG P95 | ≤ 25 s | **No** |
| Cached result retrieval | P95 ≤ 2 s | **No** — requires the application, CP-09 |
| Questionnaire composition | P95 ≤ 3 s | **No** — requires the application, CP-09 |

Recorded separately per attempt, never merged: input preparation, provider
request, parsing, validation, persistence, API response, browser click-to-render,
prompt tokens, completion tokens, total tokens, provider-reported cost, timeout
rate, validation rejection rate, successful persistence rate.

Failed and timed-out attempts are included in every denominator. A timeout is a
result.

**What the available evidence already shows** (see
`results/EXISTING_EVIDENCE_BENCHMARK_20261125.md`): the Direct-QG shape recorded a
median of ≈ 20.1 s and a worst case of ≈ 30.0 s against a 10 s / 25 s target. On
current evidence those two targets are **not achievable** without cutting output
volume, and completion tokens track latency closely (1 065 tokens → 10.9 s;
3 818 tokens → 27.3 s).

---

## 6. What would make this evaluation invalid

Stated in advance so it can be checked afterwards.

1. Comparing V4 and V5 on different inputs, or with different model settings.
2. Reporting only successful runs, or excluding timeouts from a rate.
3. Presenting `max_tokens` as token usage.
4. Calling a golden output a model result.
5. Declaring P95 from a handful of samples.
6. Treating "newest" as "best" before the comparison is read.
7. Weakening a validator check so a prompt passes.
8. Evaluating on held-out cases while still editing prompt wording.
