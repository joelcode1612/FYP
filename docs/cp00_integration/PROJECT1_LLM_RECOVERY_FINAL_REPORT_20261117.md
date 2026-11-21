# PROJECT1 — LLM Recovery: Final Report

**Date:** 2026-11-17 · **Branch:** `merge_main_jed`  
**Provider spend:** **USD $0.00** · **Calls used:** 4 of 6 · **Remaining:** 2 (unspent)  
**Model:** `mimo-v2.6-flash:free` (catalogue pricing 0/0, verified) — fallback never exercised

No real entrepreneur data. No production collection, publication or real-data dispatch. Flags off.  
Nothing committed.

---

## Checkpoints

| Checkpoint             | Status                       | Calls          | Validation outcome                                                                    | Remaining issue                               |
| ---------------------- | ---------------------------- | -------------- | ------------------------------------------------------------------------------------- | --------------------------------------------- |
| **LLM-01**             | **PASS**                     | 0              | request body built and validated; ledger `reserve`→`finish`                           | —                                             |
| **LLM-02 BDJ**         | **PASS**                     | 2 (+1 unknown) | HTTP 200, structured output validated, engine `reviewed`, 0 candidates / 0 authorized | 0 findings by D02 design; identity unverified |
| **LLM-03 QJ**          | **PASS**                     | 1              | HTTP 200, route `HOLD`, deterministic validation valid, zero codes                    | route beyond HOLD unexercised                 |
| **LLM-04 QG**          | **BLOCKED**                  | 0              | not attempted                                                                         | no bank adapter, bank empty, no measurement   |
| **LLM-05 Reliability** | ***NOT&#x20;*&#x4D;EASURED** | 0              | nothing to evaluate for stability                                                     | no repeats; QG absent                         |

| Recovery item            | Status                                                                                                                     |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| **R01** transport        | **PASS** — `Accept-Encoding: identity`, `DecodingError` → `E_PROVIDER_RESPONSE_DECODE_OUTCOME_UNKNOWN` → `unknown_outcome` |
| **R02** accounting       | 4 spent, 2 remaining; attempt 1 delivery remains **UNKNOWN**                                                               |
| **R03** QJ disclosure    | **PASS** — 8/8 checks against a real `BusinessContextBuilderV1` packet                                                     |
| **R04** provider outputs | **PARTIAL** — BDJ and QJ obtained; QG structurally blocked                                                                 |
| **R05** reliability      | **NOT MEASURED**                                                                                                           |

---

## Root cause of the original failure

`HTTP_PROXY`/`HTTPS_PROXY` = `http://127.0.0.1:51039`. The live call failed inside `iter_bytes()` with  
`DecodingError: Error -3 while decompressing data: incorrect header check`. The proxy is the leading  
hypothesis, **not a proven cause** — the directive correctly warns against concluding root cause from the  
client exception alone. Mitigation is `Accept-Encoding: identity`, which produced uncompressed responses on  
every subsequent call (no `Content-Encoding` header, chunked framing only).

The OpenAI-SDK detour was reverted: the SDK runs on httpx and would traverse the same proxy, and it cost the  
monotonic deadline control for no benefit.

## Free-tier verification

Queried `GET /v1/models` before dispatch. `mimo-v2.6-flash:free` → `input 0 / output 0 / cache_read 0 /
cache_write 0`. The paid sibling `mimo-v2.6-flash` is 0.14 / 0.28 per 1M. The gate enforces  
`pricing == 0` and fails closed with `FREE_TIER_UNAVAILABLE`. Full 85-entry catalogue archived.

## LLM-02 — BDJ

Raw assistant content, verbatim:

> `{"issues":[],"overall_note":"No rule identifiers are available because source_data.rule_catalogue is
> empty, so no finding can carry a catalogue rule_id. No findings are returned."}`

`reasoning_content`: *"The rule catalogue is empty, so no rule_id fits. Return no findings."*

HTTP 200 · 3,370 ms · uncompressed · 1 dispatch · no retry · `finish_reason: stop` ·  
`usage 3177 / 57 / 3234` · engine `reviewed` · checkpoint 5 `bounded_no_issue` · `rule_catalogue: []` ·  
**0 candidates, 0 rejection codes, 0 authorized findings**.

The model **abstained deliberately** rather than inventing a finding with a fabricated `rule_id`. Under  
re-affirmed D02 the M2V1 catalogue is empty by design, so this scenario cannot demonstrate contradiction  
detection; it demonstrates abstention and admission control. Both are stated separately and neither is  
inflated.

## LLM-03 — QJ

Raw assistant content, verbatim (abridged to the operative clause; full text at  
`var/llm_campaign/runs/qj-live-20261117T132744Z/raw_response.txt`):

> "The confirmed uncertainty concerns customer willingness-to-pay, which could in principle route to a  
> customer survey, but no frozen measurement fields (construct, population, timeframe, stimulus, response  
> options/codes, routing, denominator, source refs, limitations, uncertainty version) are supplied in the  
> source records. A survey candidate requires all frozen fields; otherwise HOLD. … geography out of V1 scope."

HTTP 200 · 9,420 ms · request 13,257 B / response 1,613 B · `usage 4653 / 242 / 4895` ·  
route **`HOLD`** · deterministic validation **valid, zero codes** · disclosure **8/8** · `authority NONE`.

It named the intended objective, separated declaration ambiguity from the confirmed measurable uncertainty,  
preserved the frozen-field requirement, and refused to invent population/construct/stimulus/timeframe.  
**Correct behaviour**: the synthetic context legitimately has no frozen measurement specification.

Fail-closed scenario: uncertainty absent → `QJ_DISCLOSURE_UNCERTAINTY_NOT_CONFIRMED`, `sent: false`, budget  
file byte-identical (sha256 `89eb1cd4…`), 4 → 4. Zero calls, as required.

## LLM-04 — QG, structurally blocked

| Requirement             | State                                                                                             |
| ----------------------- | ------------------------------------------------------------------------------------------------- |
| Production bank adapter | **does not exist** — only test doubles; no `src/` implementation of `lookup()`/`verify_receipt()` |
| Approved questions      | **0** (`m2_review_question_versions` 0, owner reviews 0, review assignments 0)                    |
| Verified no-equivalent  | impossible — empty bank, no adapter                                                               |
| Confirmed measurement   | **absent** — the QJ run returned `HOLD`, measurement `null`                                       |

The bank is **empty, not merely unapproved**. `cq_bank_versions` (3×13) is the CQ questionnaire bank, a  
different object. Case A = `BLOCKED_NO_APPROVED_QUESTIONS`; Case B = `BLOCKED`. No QG attempt was made,  
because a call without a verified no-equivalent and a confirmed measurement would violate the directive's  
own precondition. Remaining calls were therefore **not** reassigned.

## Model identity — carried into every result

Every call returned `mimo-v2.6-flash` for a `mimo-v2.6-flash:free` request, classified  
`MODEL_IDENTITY_UNVERIFIED_TEST_EXCEPTION` with **`identity_verified: false`**. This is recorded, not  
absorbed: the provider did not confirm that the free route served the call, so no output in this phase can  
claim a verified model identity.

## What would move each blocked item

1. **LLM-04** — a production bank adapter implementing the `bank` port, seeded approved questions, and a QJ  
   route that emits a full `Measurement`. All three are prerequisites; none is a model problem.
2. **LLM-05** — repeat runs per scenario for stability. Two remaining calls cannot cover it; report  
   `NOT_MEASURED`, not a reliability PASS.
3. **R02** — attempt 1 delivery stays `UNKNOWN` without provider-side request/usage records. Absence of  
   evidence is not evidence of non-delivery.

## Artifacts

`var/llm_campaign/runs/`: `r01-gate-20261117T132045Z/` (gate + 85-entry catalogue),  
`r01-live-20261117T132434Z/` (capture, raw response, raw meta, ledger),  
`qj-live-20261117T132744Z/` (raw response first, then derived capture),  
`var/llm_campaign/qg_preflight_20261117.json`, `var/llm_campaign/budget_state.json` (append-only, 4 attempts).

Test suite: **353 passed, 1 skipped**.
