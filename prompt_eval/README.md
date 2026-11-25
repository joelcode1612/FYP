# `prompt_eval/` — BDJ and Direct-QG prompt evaluation workspace

File-based, versioned, and independent of the application. It creates no
database, registers no prompt in the production registry, and makes no cloud
request unless a script says so explicitly.

Everything here is **candidate-only**. Nothing in this directory approves a
prompt, authorises fielding, or asserts that a result is scientifically accepted.

## Layout

```
prompt_eval/
  README.md                     this file
  ACCEPTANCE_CRITERIA.md        CP-04 — criteria, expected behaviour, compliance matrix
  candidates.py                 V5 prompt objects (not in the production registry)
  contracts_v5.py               additive bdj-objective-proposal/2 + validator
  fixtures.py                   CP-04 — controlled synthetic cases + expected behaviour
  prompts/
    bdj_objective_v4.{json,md}      CP-01 baseline, extracted from code
    qg_fixed_option_v4.{json,md}    CP-01 baseline, extracted from code
    baseline_manifest.json          versions + fingerprints
    bdj_objective_v5.instruction.txt    CP-02 candidate (single source of truth)
    qg_fixed_option_v5.instruction.txt  CP-03 candidate
  baseline/BASELINE_V4.md       CP-01 — input construction, schemas, rules, settings
  results/
    FIXTURE_GATE_20261125.json          CP-04 gate output (0 model calls)
    PROMPT_INPUT_COST_20261125.json     CP-06 input cost, V4 vs V5
    EXISTING_EVIDENCE_BENCHMARK_20261125.{json,md}  CP-05 from recorded runs
    DEFECTS_FOUND_20261125.md           defects and evidence gaps
  scripts/
    extract_baseline.py         dumps V4 verbatim from the registry
    run_fixtures.py             deterministic gate — no network
    measure_prompt_cost.py      input cost, V4 vs V5
    benchmark_existing_evidence.py  re-reads recorded dispatches
```

## Running it

From the repository root, with the backend virtualenv:

```bash
backend/.venv/Scripts/python.exe prompt_eval/scripts/extract_baseline.py
backend/.venv/Scripts/python.exe prompt_eval/scripts/run_fixtures.py --verbose
backend/.venv/Scripts/python.exe prompt_eval/scripts/measure_prompt_cost.py
backend/.venv/Scripts/python.exe prompt_eval/scripts/benchmark_existing_evidence.py
```

None of these four opens a network connection. `run_fixtures.py` exits non-zero
if any golden output fails its own contract or any negative is rejected with the
wrong code — a wrong code is treated as a **fixture** defect, not a pass.

## Reading the database, if you must

The CQ tables are protected by row-level security whose every policy resolves the
caller from `current_setting('project1.actor_id', true)`. On a bare connection
that setting is unset, the predicate is false, and `SELECT count(*)` returns **0
without an error**.

A zero-row result is therefore **not** evidence that a table is empty. Before
reporting one, either:

- run under a `rolbypassrls` principal (`postgres`), or
- set `project1.actor_id` to the owning actor, or
- corroborate with an operator count.

Verified counts on 2026-11-25 (`project1_pg18_migrated_tests` @ 5544): 146
sessions (129 SUBMITTED + 17 ACTIVE), 129 receipts, 811 answer revisions. Full
evidence and reproducible SQL: `deliverables/PROJECT1_DB_IDENTITY_VERIFICATION_20261125.md`.

## Status

| CP | Deliverable | State |
|---|---|---|
| CP-01 | V4 baseline frozen, extracted from code, fingerprinted | **Done** |
| CP-02 | `BDJ-OBJECTIVE-5-M2V2-CAND` drafted | **Drafted, not evaluated** |
| CP-03 | `QG-FIXED-OPTION-5-CAND` drafted | **Drafted, not evaluated** |
| CP-04 | Workspace, 11 cases, 20 negatives, deterministic gate green | **Done (E2)** |
| CP-05 | Performance | **Partial** — prior-run evidence only; V4/V5 unmeasured |
| CP-06 | Optimisation | **Analysis only** — input cost measured, output not yet |
| CP-07 | Evidence retention | **Not started** — needs a live run |
| CP-08 | V4 vs V5 comparison | **Not started** — needs a live run |
| CP-09 | Application integration | **Blocked** — DEF-01, and adoption has not happened |
| CP-10 | Final deliverables | **Partial** — see below |

### What is genuinely finished

- Both baseline prompts extracted **programmatically**, so the "original" is the
  code, not a transcription.
- A deterministic gate that fails when a fixture or a validator disagrees with
  the declared expectation — currently 11 cases / 20 negatives / 0 defects.
- Two candidate prompts that are dispatchable without touching production.
- Input cost measured: BDJ V5 is **8.6% smaller** than V4 on input despite a 39%
  longer instruction, because V4's three few-shot examples cost more than the six
  new required fields. QG V5 is **3.3% larger** on input.

### What is not finished, and why

- **No live dispatch has been made.** `tokenharbor_enabled = False`; enabling it
  is an authorisation decision (control C2), not a configuration change.
- **CP-08 is impossible without that pilot.** Comparing V4 and V5 on research
  quality, token consumption and latency requires real responses from both.
- **CP-09 is blocked twice over**: the Direct-QG path is held unconditionally
  (DEF-01), and integration is only supposed to follow adoption.
- **P95 is not reported anywhere.** The largest available sample is n = 8; a
  percentile from eight samples describes the sample, not the system.

## What a live pilot would need

1. Explicit authorisation to enable the provider (C2) and a spend ceiling.
2. A dispatch budget: 11 cases × 2 versions × 2 families, with one attempt each
   and no retry, is the minimum that can support a comparison. At the recorded
   completion-token levels that is the dominant cost, not the prompt.
3. Retention of the raw envelope per attempt (CP-07): prompt version, submitted
   input, provider response, parsed output, validation outcome, model identity,
   usage, timings, attempt and candidate ids.
4. Held-out cases opened **once**, after prompt wording is frozen.
