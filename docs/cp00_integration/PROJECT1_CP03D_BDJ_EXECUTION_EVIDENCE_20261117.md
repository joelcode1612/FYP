# PROJECT1 — CP-03C / CP-03D Execution Evidence

**Date:** 2026-11-17
**Repository:** `sport-marketplace/FYP`, branch `merge_main_jed`, base `ba30035` (dirty working tree)
**Authorisation:** CP-03C/CP-03D Completion Directive, steps 1–12
**Verdict summary:** acceptance milestone **MET**; cloud-BDJ *admissibility* **FAIL**; two defects registered.

> The acceptance bar set by the directive was: *"The acceptance milestone requires an authorized
> ModelRunner invocation and a matching durable ledger receipt."* That bar is met — see §3.
> It is **not** the same claim as "cloud BDJ works end to end", which is **false** today — see §5.

---

## 1. Scope and what was actually authorised

| Item | State |
|---|---|
| Data class | `SYNTHETIC_NONHUMAN` only |
| Provider | TokenHarbor `https://tokenharbor.ai/v1/chat/completions` |
| Model requested | `mimo-v2.6-flash:free` (canonical response `mimo-v2.6-flash`) |
| Attempts per run | exactly 1 (`max_attempts=1`), no retry, no redirect |
| Live calls made | 4 (2 returned, 2 timed out) |
| Real personal data sent | none |
| QJ / QG / publication / fielding enabled | **no** |
| Free-tier billing claimed as verified | **no** |

---

## 2. Verified environment

| Fact | Evidence |
|---|---|
| Two databases, one server (`localhost:5432`) | `Final_Location_Analysis` (app/catalogue, `postgres`), `Dss` (M2/research/CQ, `p1_m2_runtime`) |
| `project1_ai` exists only in `Dss` | superuser inspection; `information_schema` hides it from restricted roles |
| `project1_ai` is an append-only **attempt ledger**, not a role and not the LLM's role | tables `runs`, `attempts`, `attempt_receipts`, `schema_versions`; hashes/digests only, no raw prompts/completions/keys |
| Roles | `p1ai_owner` (NOLOGIN, owner) · `p1ai_runtime` (NOLOGIN, INSERT/SELECT) · `p1ai_audit` (NOLOGIN, SELECT) · `p1ai_engine` (LOGIN, member of `p1ai_runtime`) · `p1ai_auditor` (LOGIN, member of `p1ai_audit`) |
| Restricted execution-principal contract | log in as `p1ai_engine` / `p1ai_auditor`, then `SET LOCAL ROLE` into the NOLOGIN restricted role — mirrors `SET LOCAL ROLE p1_ee01_runtime` in `synthetic_dss_import.py` |
| `p1ai_runtime` made LOGIN? | **No** — directive respected; the login principal is `p1ai_engine`, not the restricted role |
| RLS | `FORCE RLS`, `owner_scope` policy keyed on `current_setting('project1.actor_id')` |
| Append-only | `immutable_history` trigger raises `Workflow history is append-only` |

---

## 3. Directive steps 1–12 — exact status

| # | Step | Status | Evidence |
|---|---|---|---|
| 1 | Re-verify repo + ledger migration post disk incident | **PASS** | `merge_main_jed`/`ba30035`; migration `20261117_01_execution_principal.sql` applied; C: recovered to 10.92 GB free |
| 2 | Run previously unexecuted PostgreSQL integration suite in disposable DB | **PASS** | `8 passed in 2.60s` in a private PG18 cluster, fixture `tests/cp07/fixtures/stage_m2_schema.sql` |
| 3 | `p1ai_engine` → `SET LOCAL ROLE p1ai_runtime`, RLS, append-only, receipts, rejected/unknown outcomes | **PASS** | reserve→finish→readback proven; append-only proven via superuser (runtime lacks UPDATE, so permission-denied would mask the trigger); app role and superuser both held with `RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED` |
| 4 | Narrow synthetic-only disclosure adapter | **PASS** | `project1/disclosure.py`; 4 fail-closed codes exercised live (source / model / stage / real-data) |
| 5 | Reuse `ModelRunner`, `PostgresAttemptLedger`, TokenHarbor, adopted prompt — no second model service | **PASS** | `scripts/cp03d_bdj_execution.py` composes the existing components only |
| 6 | Authorise exactly one bounded synthetic BDJ attempt with source/destination/model/budget checks | **PASS** | `SyntheticBdjAuthorization(max_attempts=1)`; receipt names purpose and single attempt |
| 7 | Execute the actual cloud BDJ call; validate structured output + source fidelity | **PASS (invocation)** | run `96cefb30`; `BDJOutput` validation passed; 0 bad source refs |
| 8 | Persist attempt, outcome, output digest, authorised output record | **PASS** | receipt `outcome=returned`, `output_digest=6be29bd0…`; sanitised record in `backups/cp03d_96cefb30…/bdj_output.json` |
| 9 | Independent read-back under the restricted audit identity | **PASS** | `identity=p1ai_audit rows=1 outcome=returned` |
| 10 | Unauthorised / mismatched source / model requests fail closed | **PASS** | `DISCLOSURE_SOURCE_MISMATCH`, `DISCLOSURE_MODEL_MISMATCH`, `DISCLOSURE_STAGE_NOT_AUTHORIZED`, `DISCLOSURE_REAL_DATA_NOT_AUTHORIZED` |
| 11 | Do not auto-enable QJ / QG / publication | **PASS** | no QJ/QG route touched; publication remains BLOCKED |
| 12 | Deliver exact PASS/FAIL/BLOCKED evidence and remaining defects | **this document** | — |

### CP-03D primary run — `96cefb30-60b9-4a9c-b028-e87793c2a82a`

```
PASS  packet_built                 declarations=11 fp=b611fbf8266c
PASS  synthetic_actor              source is the synthetic non-human test identity
PASS  run_provisioned              run_id=96cefb30-60b9-4a9c-b028-e87793c2a82a
PASS  disclosure_source_mismatch   code=DISCLOSURE_SOURCE_MISMATCH
PASS  disclosure_model_mismatch    code=DISCLOSURE_MODEL_MISMATCH
PASS  disclosure_stage_not_authorized  code=DISCLOSURE_STAGE_NOT_AUTHORIZED
PASS  disclosure_real_data_refused code=DISCLOSURE_REAL_DATA_NOT_AUTHORIZED
PASS  model_runner_returned        issues=0
PASS  source_fidelity              bad_refs=0
PASS  structured_validation        validated against BDJOutput
PASS  single_attempt_enforced      code=MODEL_STAGE_ALREADY_RESERVED
PASS  audit_readback               identity=p1ai_audit rows=1 outcome=returned
VERDICT=PASS
```

**Caveat that matters:** `issues=0`. This run exercised the happy path only. It did **not**
demonstrate uncertainty detection, and because an empty issue list passes every downstream
validator trivially, it also masked the two defects in §5.

---

## 4. CP-03D(b) — uncertainty detection, verified

The P3 directive asked for a poor or contradictory case and a check that BDJ detects genuine
uncertainty. A *derived* synthetic packet was built with two real internal contradictions:

| Mutation | Was | Became | Why it is a real contradiction |
|---|---|---|---|
| `M2V1-05` primary group | `STUDENTS` | `FAMILIES` | not in `M2V1-04` = `[STUDENTS, OFFICE_WORKERS]` |
| `M2V1-09` investigation topics | `[CONCEPT_INTEREST, PRICE_ACCEPTABILITY]` | `[PRICE_ACCEPTABILITY]` | `M2V1-10` first topic `CONCEPT_INTEREST` is no longer selected |

Run `fd0b4380-1c37-4dd4-ae3c-5faf4a138d01`, prompt `BDJ-SOURCE-1-CAND`:

```
PASS  contradiction_planted        primary=FAMILIES in groups=[OFFICE_WORKERS, STUDENTS]: False
PASS  derived_fingerprint_changed  b611fbf8266c -> 13a565e13c37
PASS  model_runner_returned        issues=2
PASS  uncertainty_detected         issues=2
PASS  conflict_kind_used           SOURCE_CONFLICT findings=2
PASS  planted_items_cited          cited=['M2V1-04','M2V1-05','M2V1-09','M2V1-10']
PASS  source_fidelity              bad_refs=0
PASS  single_attempt_enforced      code=MODEL_STAGE_ALREADY_RESERVED
PASS  audit_readback               identity=p1ai_audit rows=1 outcome=returned
VERDICT=PASS
```

The model produced both findings with correct rule identifiers and correct item pairs:

- `SOURCE_CONFLICT / PRIMARY_GROUP_NOT_IN_SELECTED_GROUPS` → refs `M2V1-04`, `M2V1-05`
- `SOURCE_CONFLICT / PRIORITY_TOPIC_NOT_IN_SELECTED_TOPICS` → refs `M2V1-09`, `M2V1-10`

**Conclusion:** BDJ genuinely detects planted contradiction and names it correctly. It does not
merely restate the packet.

---

## 5. Defects — both verified, not hypothesised

### BDJ-QUOTE-01 — cloud findings are rejected by the engine's own quote gate (FIXED, unverified live)

`BDJEngine.validate_candidates` (`project1/bdj.py:43-45`) requires `ref.quote` to be a substring of
the declaration's **value**:

```python
values = source['value'] if isinstance(source['value'], list) else [source['value']]
if not any(isinstance(v, str) and ref.quote in v for v in values):
    raise WorkflowHeld('BDJ_SOURCE_QUOTE_INVALID')
```

The deterministic path agrees (`bdj.py:82` sets `quote` to the raw value; `test_workflow.py:104`
asserts `quote == value_json`). The v1 prompt said only *"verbatim source quotes"* without naming
the field, so the model quoted the **question text**. Measured on run `fd0b4380`: **0 of 4** refs
passed the gate.

```
allowed_rules = model's own rule ids  -> REJECTED BDJ_SOURCE_QUOTE_INVALID
  BAD M2V1-04 | value=["STUDENTS","OFFICE_WORKERS"] | quote='Which groups of customers ... serve?'
  BAD M2V1-05 | value="FAMILIES"                    | quote='Among the customer groups ... = FAMILIES'
  BAD M2V1-09 | value=["PRICE_ACCEPTABILITY"]       | quote='Which aspects of your proposed café ...'
  BAD M2V1-10 | value="CONCEPT_INTEREST"            | quote='Which selected topic ... = CONCEPT_INTEREST'
```

**Fix applied (prompt is wrong, validator is right — validator left strict):**

- `contracts.py` — `SourceRef.quote` now carries a `description` that ships inside the JSON schema
  sent to the provider: *"An exact substring copied from this declaration's value field… Never
  quote the question text and never append the value to the question."*
- `prompts.py` — BDJ prompt superseded `BDJ-SOURCE-1-CAND` → **`BDJ-SOURCE-2-CAND`**, with the
  value-only quote contract stated in the instruction. v1 is retired, not edited, so historical
  ledger rows keep their own `prompt_hash` and stay interpretable.
- `tests/project1/test_workflow.py` — new regression `test_source_quote_must_come_from_declared_value`
  (3 cases: value span admitted; question text rejected; `question = value` rejected).

Plumbing verified without dispatch: version `BDJ-SOURCE-2-CAND`, fingerprint
`9dbd038b9f1f…`, contract present in the system message **and** in
`BDJOutput.model_json_schema()['$defs']['SourceRef']['properties']['quote']['description']`.

**Live re-verification: BLOCKED.** Two attempts (`7948190f`, `5f634520`) both returned
`E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN` at 30 s and 45 s. The earlier successful calls completed in
~6.5 s, so this is provider-side degradation, not a regression — but it is **not verified live**
and must not be reported as such.

### BDJ-RULE-COVERAGE-01 — no finding can be admitted for the M2V1 instrument (OPEN)

`BDJEngine.review` computes `allowed = {p['rule_id'] for p in proposals}` from the deterministic
ruleset, and `validate_candidates` raises `BDJ_RULE_NOT_REGISTERED` for any rule outside it. The
model is deliberately not allowed to invent findings; it must land on a rule the independent
detector also fired.

But `BDJ-RULESET-0.2-CAND` (`domain/bdj_candidate_rules.py`) is written **entirely against M2-xx
keys** — `M2-04`, `M2-05`, `M2-12`…`M2-18`, `M2-O-01`. The live instrument is
`M2V1-20261114-1` with keys `M2V1-01…11`. On the contradictory packet the deterministic detector
returned **zero** proposals, so `allowed` was empty:

```
deterministic proposals: []
allowed_rules = set()                 -> REJECTED BDJ_RULE_NOT_REGISTERED
```

Therefore on the current instrument the cloud BDJ path can **never** surface a finding, even after
BDJ-QUOTE-01 is fixed. Run `96cefb30` hid this: with `issues=[]` both gates pass vacuously.

**Status: OPEN / BLOCKED on an owner decision.** Closing it requires an M2V1 ruleset version plus
its adoption receipt and sha256 — a governance event, not a code tidy-up. No rules were invented
here.

### Cloud BDJ is not wired into HTTP (by design, stated)

`api/v1/project1_workflow.py:97-99` deliberately passes rules only:

```python
# Deliberately no cloud runner here until durable storage/disclosure adapters
# and the shared status register have an adopted integration contract.
result = BDJEngine(rules).review(packet, recheck_current=...)
```

`POST /m2/.../bdj/evaluate` uses `BDJService(repository)` — deterministic, never dispatches a
model. So cloud BDJ exists and is proven at `ModelRunner` level only.

---

## 6. Ledger state — six runs, all durable

| run_id | source fp | prompt_version | outcome | output digest |
|---|---|---|---|---|
| `cdfc5a2b…` | `aaaaaaaaaa` | BDJ-SOURCE-1-CAND | rejected | — |
| `10d840cf…` | `aaaaaaaaaa` | BDJ-SOURCE-1-CAND | rejected | — |
| `96cefb30…` | `b611fbf826` | BDJ-SOURCE-1-CAND | **returned** | `6be29bd04d` |
| `fd0b4380…` | `13a565e13c` | BDJ-SOURCE-1-CAND | **returned** | `c04bd85985` |
| `7948190f…` | `13a565e13c` | BDJ-SOURCE-2-CAND | unknown_outcome | — |
| `5f634520…` | `13a565e13c` | BDJ-SOURCE-2-CAND | unknown_outcome | — |

The two `unknown_outcome` rows are correct fail-closed behaviour: a dispatched POST that timed out
may have completed upstream, so it is recorded as unknown and **never** retried automatically.

---

## 7. Claims explicitly refused

- ❌ "Cloud BDJ works end to end" — two gates reject every finding; not wired to HTTP.
- ❌ "The quote fix is verified live" — BLOCKED by provider timeouts; unit-tested and plumbed only.
- ❌ "Provider HTTP 200 proves success" — 200 + valid JSON is exactly what runs `96cefb30` and
  `fd0b4380` returned, and it still was not admissible.
- ❌ "Free-tier billing is verified" — model-name reconciliation only; billing not observed.
- ❌ "BDJ results are scientifically accepted / approved" — `finding_authority=CANDIDATE_ONLY`,
  `status_contract=UNRECONCILED_PROPOSAL`, all `no_authority()` flags false.

---

## 8. Remaining blockers and next checkpoint

| ID | Item | Status |
|---|---|---|
| BDJ-RULE-COVERAGE-01 | M2V1 deterministic ruleset + adoption receipt | **OPEN — owner decision** |
| BDJ-QUOTE-01 | Prompt/schema quote contract | **FIXED, live re-verification BLOCKED** |
| Cloud BDJ HTTP wiring | Needs adopted integration contract | **NOT WIRED (by design)** |
| Provider availability | 2 consecutive timeouts | **DEGRADED** |

Per the directive, the next checkpoint is **CP-04: Authoritative BCB bindings**, which does not
depend on either BDJ defect.

---

## 9. Reproduction

```bash
cd sport-marketplace/FYP/backend
./.venv/Scripts/python.exe scripts/cp03d_bdj_execution.py      # acceptance milestone
./.venv/Scripts/python.exe scripts/cp03d_bdj_uncertainty.py   # contradiction probe (1 live call)
./.venv/Scripts/python.exe -m pytest tests/project1/ -q       # 140 passed, 1 skipped
```

Evidence directories:
`backend/backups/cp03d_96cefb30-60b9-4a9c-b028-e87793c2a82a/`
`backend/backups/cp03d_uncertainty_fd0b4380-1c37-4dd4-ae3c-5faf4a138d01/`
