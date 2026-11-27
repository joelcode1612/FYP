# PROJECT1 — LLM-First Execution: Report

**Date:** 2026-11-17 · **Branch:** `merge_main_jed`
**Overall:** `LLM-01 PASS` · **LLM-02..05 BLOCKED on a transport defect** · **1 of 6 approved calls spent**

No real entrepreneur data. No production collection, publication or real-data dispatch. All feature flags
off after the run (`TOKENHARBOR_ENABLED` and `PROJECT1_WORKFLOW_ENABLED` absent from `.env`; the provider
flag was set only for the single invocation). Nothing committed.

---

## Required execution report

| Checkpoint | Status | Actual model calls | Validation outcome | Remaining issue |
|---|---|---|---|---|
| **LLM-01** | **PASS** | 0 | request body built and validated against `httpx.MockTransport`; ledger `reserve`→`finish` | route path not exercisable — see §3 |
| **LLM-02 BDJ** | **BLOCKED** | 1 attempted, **0 returned** | none — no response body obtained | transport decode failure; ledger holds a reserved attempt with no receipt |
| **LLM-03 QJ** | **BLOCKED** | 0 | not attempted | no QJ-scoped synthetic disclosure adapter exists |
| **LLM-04 QG** | **NOT_RUN** | 0 | not attempted | Case B needs a call; Case A never executed because the campaign halted |
| **LLM-05 Reliability** | **BLOCKED** | 0 | nothing to evaluate | no model outputs exist |

**No LLM output exists for this phase.** No findings, no QJ route, no QG candidate. Nothing here is a
scientific validation, and no performance figure is reported.

## 1. LLM-01 — what was actually verified

- **Instrument** loaded through the operator's own reader (`scripts/register_m2_v1.definition()`), not a
  copy: version `M2V1-20261114-1`, **13 items** (`M2V1-01`…`M2V1-11`, plus `M2-20`, `M2-21`; 11 answerable).
  `source.txt` is **6,044 bytes** — the brief's 6,428 is stale — and hashes to
  `d09a7db532cbd2e41458d9776004de2830c67c91cacb0a264dc4cfbe5c432c6b`, matching the declared `source_sha256`.
  `.gitattributes` pins `-text`, so the checkout is byte-identical.
- **Packet** carries 11 declarations whose question text, `item_version_id` and value come from those
  versioned rows; `instrument_digest` is derived, not asserted.
- **Five synthetic fixtures** under `tests/project1/llm_campaign/fixtures/`, all `synthetic:true`,
  non-personal, and `no_expected_output_recorded:true` — pre-baking expected output would have corrupted
  LLM-05. Cases: consistent, contradictory service format, missing/ambiguous, confirmed uncertainty,
  uncertainty requiring clarification.
- **Request body proven without dispatch**: `mimo-v2.6-flash:free`, `max_tokens 4000`, `temperature 0`,
  `stream false`, `response_format json_schema/BDJOutput/strict`, 4 messages, all 11 M2V1 keys present.
  Transport was a local `httpx.MockTransport`; `tokenharbor_enabled` stayed `False`; zero sockets.
- Tests: campaign **47 passed**; `tests/project1` + `tests/m2_bcb` **316 passed, 6 skipped**.

## 2. D02 re-affirmed — the ruleset that was asked for was retired

A ruleset re-keying the catalogue onto M2V1 (`BDJ-RULESET-0.3-M2V1-CAND`) was authored and then **retired
the same day**. `SERVICE_FORMAT_EXPLICIT_CONFLICT` on `M2V1-02` + `M2V1-07` restates the objection D02
already upheld for `M2V1_DELIVERY_WITH_ON_PREMISE_OCCASION`: an occasion can be served off-premise.

- Removed from `RULE_MODULES`; `load_rules()` raises `BDJ_RULE_ADOPTION_REQUIRED` **even with the correct
  sha256 and a forged receipt** — version membership is checked before the hash, so no pair can revive it.
- Module kept with `ADOPTED = False`, `STATUS = "RETIRED_NOT_ADOPTED"`, and the full 12-row mapping table in
  its docstring as the audit record of what was considered and why it was rejected.
- Consequence adopted, not worked around: `rule_catalogue` for a genuine M2V1 packet under
  `BDJ-RULESET-0.2-CAND` is `[]`. That is D02's position — *contradiction-free by design* — not a defect.
- 4 retirement tests added; legacy `bdj_candidate_rules.py` remains byte-identical at `42f7fef3…`.

## 3. Why LLM-02 is BLOCKED

The single approved dispatch failed at the transport layer:

```
httpx.DecodingError: Error -3 while decompressing data: incorrect header check
```

It failed inside `response.iter_bytes()`, during gzip decompression. `provider.py:76-79` sets no explicit
`Accept-Encoding`, so httpx negotiates `gzip, deflate, br`; a body that is not compressed while the header
claims it is produces exactly this error. The sandbox then blocked the command, so **whether the request
reached `tokenharbor.ai` or was intercepted is unknown**.

The ledger recorded the honest state — reserved, no receipt:

```json
"attempts": [{ "attempt_no": 1, "reserved_at": "2026-11-17T12:40:48.626961+00:00", "stage": "BDJ" }],
"receipts": []
```

Budget: **1 of 6 spent, 5 remaining.** No retry was attempted.

Also recorded from LLM-01: the HTTP route is **not** exercisable as configured. `configuration_gate`
requires `Dss` with a non-superuser principal, but `p1ai_engine` has no `SELECT` on
`public.m2_assessments`/`public.users`, and `p1_m2_runtime` lacks `public.users`. The worker stopped rather
than widen a grant, and I did not override that. Separately, `M2SourceProjection` emits no `data_class`, so
`run_model_assisted` refuses real data with `DISCLOSURE_REAL_DATA_NOT_AUTHORIZED` — preserved as intended.

## 4. LLM-03 refused rather than bypassed

There is no synthetic disclosure adapter for stage QJ; the only one is BDJ-scoped and refuses QJ by design.
The runner originally called `provider.complete` for QJ behind construction-time assertions. I changed that
stage to **refuse and spend no call**: reaching the provider with no disclosure control is the very thing
that control exists to prevent, and an `assert` is not a substitute for it. Enabling QJ needs a QJ-scoped
synthetic disclosure adapter — a governance artefact, not a flag.

The runner now reports `REFUSED_NO_QJ_DISCLOSURE_ADAPTER` and consumes no budget slot.

## 5. CP-06 and deferred items

| Item | State |
|---|---|
| **CP-06** runner timeout | **DONE** — 240s → 900s. Measured 251.49s and 246.28s had timed out three times. Only the cap changed; no test skipped, weakened or retried. |
| **CP-07** M2 write-path certification | **DEFERRED.** Risk: in the lab, M2 writes run as the harness superuser, so write-path grants as `p1_m2_runtime` remain unproven. Restricted-reader and authorization controls untouched. |
| **CP-08** validity basis | **DONE, test-scoped.** No automatic production expiry policy introduced; absent basis fails closed with `VALIDITY_BASIS_UNAUTHORIZED`. |
| **CP-09** legacy payload re-wrapping | **DEFERRED.** Risk: 320 plaintext `result_payload` rows in the clone are not retro-sealed; a re-wrap job does not exist. Existing encryption and retention controls remain enabled; real-sensitive dispatch stays prohibited. |

## 6. Next dependency, in order

1. **Resolve the transport path.** Either fix `Accept-Encoding` in `provider.py` (a real client defect
   regardless) or authorise one unsandboxed diagnostic call to determine whether the sandbox is
   intercepting. Until then no provider call can succeed and no checkpoint can move.
2. **Author a QJ-scoped synthetic disclosure adapter** before LLM-03 can run at all.
3. **Raise the call budget** if LLM-05 stability is to be measured — 5 remaining slots cannot cover
   5 BDJ scenarios plus repeats plus QG Case B.
4. The ruleset question is **closed** by D02; do not reopen it without a new decision record.
