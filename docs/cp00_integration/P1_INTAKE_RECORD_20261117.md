# P1 Intake Record — QJ/QG Research Directive

**Directive:** `PROJECT1-QJQG-RESEARCH-EXEC-20261117-01`
**Package:** `PROJECT1_QJ_QG_RESEARCH_AND_AGENT_HANDOFF_20261117.zip`
**Extracted to:** `C:\Users\HP\AppData\Local\Temp\qjqg\PROJECT1_QJ_QG_RESEARCH_HANDOFF_20261117`
**Recorded:** 2026-11-17, before any code change under this directive.

Purpose: satisfy the directive's requirement to "record exact paths, signatures and versions before coding" and to "**not invent schema names**". Everything below is quoted from the working tree at the hashes given, not from memory or from the research package.

---

## 1. Package integrity

`sha256sum -c SHA256_MANIFEST.txt` → **11 of 11 OK**. No file in the handoff package was modified.

| File | Status as declared |
|---|---|
| `AGENT_EXECUTION_DIRECTIVE.md` | read in full |
| `RESEARCH_BASELINE.md` | `RESEARCH_RECOMMENDATION / PROVISIONAL / NOT_SCIENTIFICALLY_APPROVED / NOT_FOR_FIELDING` |
| `MEASUREMENT_CANDIDATE_LAB_V0_1.json` | `PROVISIONAL_TEST_ONLY_NOT_APPROVED`, `test_only=true`, all approval flags `false` |
| `CHECKPOINT_EVIDENCE.md` | P1 `RESEARCH_BASELINE_PREPARED`; P2 `PRODUCTION_ADAPTER_NOT_IMPLEMENTED`; P3 `LIVE_QG_NOT_EXECUTED`; P4 `DESK_REVIEW_ONLY` |
| `EVALUATION_RUBRIC.md` | `RUBRIC-PRICE-0.1`; `ACCEPT_FOR_FIELDED_SURVEY` explicitly unavailable |
| `SOURCE_REGISTER.csv` | 8 external sources (S1–S8) + 4 project sources (P1–P4) |
| `OFFLINE_TEST_RESULTS.txt` | 18 reference tests, `OK` (reference gate only) |
| `REFERENCE_VALIDATION.py`, `test_reference_validation.py` | offline stdlib reference module — **not** the repository implementation |
| `PROJECT1_QJ_QG_RESEARCH_BASELINE_20261117.pdf` | rendered baseline |
| `README.md` | package orientation |

## 2. Repository state at intake

- Branch `merge_main_jed`. Working tree dirty from earlier authorised work (migrations, provider transport, payload custody, QJ disclosure adapter). **Nothing committed.**
- Live database `Dss` untouched since the verified Phase 6 deployment (10 tables, ledger 5 rows, 6/6 RLS, behavioural 4/4).
- Provider budget: `var/llm_campaign/budget_state.json` → `spent: 4`, `limit: 6`, **2 calls remaining**, ceiling USD $0.00, model `mimo-v2.6-flash:free`.
- Test suite at intake: 353 passed, 1 skipped.

## 3. Actual interfaces (quoted from source)

| Interface | Path:line | Exact signature / shape |
|---|---|---|
| `Measurement` | `backend/src/sitewise/project1/contracts.py:56-67` | `uncertainty_version`, `construct` (alias of `construct_name`), `population`, `timeframe`, `stimulus`, `response_options: list[str]` (2..12), `response_codes: list[str]` (2..12), `routing: dict[str,str]`, `denominator: str` (1..500), `source_refs: list[str]` (1..20), `limitations: str` |
| `QJOutput` | `contracts.py:70-74` | `route: Literal['CUSTOMER_SURVEY_CANDIDATE','SCENARIO_ANALYSIS_REQUIRED','EXTERNAL_EVIDENCE_REQUIRED','HOLD']`, `justification`, `measurement: Measurement \| None` |
| `QGOutput` | `contracts.py:77-81` | `decision: Literal['DRAFT','ABSTAIN_NEEDS_REVIEW']`, `question`, `measurement: Measurement`, `justification` |
| Strictness | `contracts.py:24-25` | `ConfigDict(extra='forbid', strict=True, serialize_by_alias=True)` |
| `SourceRef` item pattern | `contracts.py:29` | `^(?:M2-(?:\d{2}\|O-0[12])\|M2V1-(?:0[1-9]\|1[01]))$` — M2V1-01..11 only |
| `checked_context` | `research.py:13-26` | recomputes `packet_hash`; requires `confirmation.status=='CURRENT_CONFIRMED'`; requires `confirmed_uncertainty`; rejects membership of `{'M2-11','M2-15','M2-20','M2-21'}` |
| `validate_measurement` | `research.py:29-43` | refs = `answer_revision_id`s ∪ `{id+'@'+version}` of `supporting_sources` ∪ `{confirmed_uncertainty.id}` (∪ objective_id); requires subset, no duplicates, `len(codes)==len(options)`, unique codes, unique options, `set(routing)==set(codes)` |
| `validate_draft` | `research.py:46-62` | `QGOutput` equality with the frozen `Measurement`; on `DRAFT` requires `stimulus`, `population`, `timeframe` substrings in `question`, and every number in the question to appear in those three fields; on abstention the question must be empty |
| `ResearchWorkflow` | `research.py:65-67` | `__init__(self, builder, authority, bank, runner)` — **all four ports duck-typed, no Protocol** |
| Bank contract | `research.py:147-162` | `lookup(measurement, packet) -> dict` with `outcome` ∈ `verified_equivalent` / `verified_no_equivalent` / other; `verified_equivalent` requires truthy `item_version` **and** `approval_receipt`; then `verify_receipt(lookup, digest(measurement), packet)`; `verified_no_equivalent` requires `authority.require_drafting(...)` before QG; any other outcome → `WorkflowHeld('BANK_AUTHORITY_UNVERIFIED')` |
| `BusinessContextBuilderV1` | `services/business_context_v1.py:145,157` | `get_context(request) -> dict`; `CURRENT_CONTEXT_VERSION = GEO_EXCLUDED_CONTEXT_VERSION = "BCB-V1-1.1.0"` (`:42-43`); schema `business-context-package/1.1`; packet assembled at `:387` with `confirmed_uncertainty`, `geography`, `supporting_sources` |
| Confirmed uncertainty | `services/confirmation_service.py:206-222` | `origin='ENTREPRENEUR'` requires `snapshot['instrument_version']=='M2V1-20261114-1'`, ANSWERED `M2V1-09/10/11`, `priority in topics`, `'NONE' not in topics`; creates the uncertainty whose `exact_text` is the objective string; returns `qj_execution_authorized: False` |
| QJ context read | `services/confirmation_service.py:227-233` | `qj_context(objective_id, actor_id, revision)` → `{'contract_version':'qj-objective-context/1', 'objective_id', 'objective', 'source', 'qj_execution_authorized': False}` |
| QJ disclosure adapter | `project1/qj_disclosure.py:344-372` | `SyntheticQjDisclosure(authorization, references, *, clock=None)`; `require_current(stage, packet, endpoint, model)`; `validate_qj_synthetic(...)` with 8 checks |

### File hashes at intake (first 16 hex of sha256)

| File | Hash |
|---|---|
| `project1/contracts.py` | `fc364ae930e5437c` |
| `project1/research.py` | `af08dcd6fad968e6` |
| `project1/qj_disclosure.py` | `1b862ed58a93a9e7` |
| `services/business_context_v1.py` | `7957728c95d4525f` |
| `services/confirmation_service.py` | `5a2bc6ace046ab30` |
| `project1/provider.py` | `da86bcfbbe4c17ba` |
| `project1/model_assisted.py` | `fcbb369af7203565` |

### Line-number drift after intake

The line numbers above are correct **as at intake**. A later change under this directive (`D-01`, a currency-amount guard added inside `validate_draft`) inserted 11 lines at `research.py:59`, so every anchor after that point moved by +11. Current anchors in `research.py`: `validate_draft` at `:46`, digit-subset check at `:55`, amount guard at `:65`, `ResearchWorkflow.__init__` at `:75`, the "independent adopted validator" comment at `:154`, `bank.lookup` at `:156`, `BANK_EXACT_APPROVAL_REQUIRED` at `:161`, `BANK_AUTHORITY_UNVERIFIED` at `:171`. Function names and exact strings are the authoritative anchors; treat line numbers as advisory.

## 4. Schema facts that constrain P1

The candidate specification in the handoff package and the live contract do **not** share a schema. Recorded here because the directive forbids inventing names:

1. Handoff `response_options` is a list of `{code, label}` objects. The live contract uses **two parallel string lists**: `response_options` (labels) and `response_codes` (codes), with a length-equality requirement.
2. Handoff `numerator_codes` and `denominator_codes` have **no live field**. The live contract has a single free-text `denominator: str` (max 500). The estimator is therefore not machine-expressible in the deployed contract.
3. Handoff `excluded_response_states_report_separately` has no live field.
4. Handoff `construct_code` has no live field; `construct` is free text.
5. `routing` must be keyed by **every** response code (`set(routing)==set(response_codes)`), so a four-code measurement needs four routing entries.

Consequence: the estimator must be carried in a **test-only versioned model** and mapped down to the deployed contract. It must not be added to `contracts.py`, which would be an unversioned production schema change.

## 5. Structural findings that change the plan

| Finding | Evidence | Consequence |
|---|---|---|
| `ResearchWorkflow` is never instantiated in `src/` | `grep -rn "ResearchWorkflow" backend/src` returns only the definition at `research.py:65`; every instantiation is in `backend/tests/` | QJ→QG is **not composed in production**. There is no production route, so no production bank lookup can occur today. |
| No bank port, no bank implementation | `services/ports/` has 4 files, none is a bank port; `grep "class .*Bank\|def lookup" backend/src` → nothing; only test doubles at `tests/project1/test_workflow.py:209-214` and `tests/m2_bcb/connected_chain_checks.py:123-129` return hard-coded receipts (`'SYN-ONLY'`, `'SYNTHETIC-PRIVATE-LAB-ONLY'`) | P2 cannot "implement the existing port against approved entries" — there are no approved entries and no store. P2 must record the absence and propose the governing decision. |
| No approved-question store in the schema | `grep -rln "question_bank\|approved_question\|bank_item\|bank_snapshot" backend/{src,migrations,tests}` → only `cq_successor/contracts.py`, `cq_successor/policy.py`, `tests/cq_successor/test_successor.py` | The only `QUESTION_BANK_VERSION` in the tree (`SYN-QBANK-V1`) is the CQ Q01–Q13 successor instrument, which the directive states is **not** the QG bank. |
| Generated QG candidates are stored separately from any bank | `confirmation_service.persist_candidate` (`:299-310`) writes a candidate receipt keyed by `uuid5(NAMESPACE_URL, digest(receipt))` | A candidate store is not an approved bank and confers no equivalence. |

## 6. What this record does **not** establish

- It does not establish that RM13 is an appropriate price, that the offer is representative, or that any measurement is scientifically valid. All of that remains `REVIEW_REQUIRED`.
- It does not establish bank authority, equivalence, or that an empty bank proves no equivalent.
- It does not establish provider reliability. Prior live calls are n=1 each and every one recorded `identity_verified: false` under the declared test exception.
- It does not re-verify the 17 Nov execution report's database claims; those remain agent-reported environment evidence.
