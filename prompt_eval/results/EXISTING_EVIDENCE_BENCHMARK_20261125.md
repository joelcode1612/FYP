# CP-05 — performance from already-recorded dispatches

Source: `deliverables/phase2/CLOUD_AB_EVALUATION_RESULTS.json`
Recorded at: `2026-11-21T19:34:08.042405+00:00`
Mode: `LIVE_CLOUD_SYNTHETIC_AB` · budget 14 · dispatched 14 · retries 0
Model: `deepseek-v4.1-flash-1017` · temperature 0 · max_tokens 4000 (cap) · structured `json_schema`

> **Scope limit.** These dispatches used the *previous* prompt pair
> (`BDJ-OBJECTIVE-3-CAND` / `4-CAND` and `QG-PROPOSE-6-CAND` / `7-CAND`),
> not `BDJ-OBJECTIVE-4-M2V2-CAND` / `QG-FIXED-OPTION-4-CAND`. They are a
> performance baseline for the same model and the same task shape, not a
> measurement of the V4/V5 pair. CP-05 for V4/V5 requires a new authorised
> pilot.

> **P95 is withheld.** n = 6 (BDJ) and n = 8 (Direct-QG). A percentile
> computed from eight samples is a property of the sample, not of the
> system. The maximum is reported instead.

## BDJ — research objectives

Dispatches: **6** (returned 6, held/failed 0)

| Metric | Value |
|---|---|
| Latency median | **5564.0 ms** |
| Latency mean | 6105.7 ms |
| Latency min / max | 4340 / **9734** ms |
| Latency P95 | WITHHELD — n too small for a reliable percentile |
| Prompt tokens (total) | 15733 |
| Completion tokens (total) | 2652 |
| Total tokens | 18385 |
| Dispatches without usage metadata | 0 |
| `max_tokens` cap | 4000 (a cap, not consumption) |

| Proposed target | Value | Observed | Verdict |
|---|---|---|---|
| Median | ≤ 15000 ms | 5564.0 ms | **MET** |
| P95 | ≤ 30000 ms | worst case 9734 ms | NOT_ASSESSABLE — sample too small; worst case reported instead |
| Worst case vs P95 target | ≤ 30000 ms | 9734 ms | within |

| Case | Prompt | Status | Latency | Completion tokens |
|---|---|---|---|---|
| `clear_confirmed_uncertainty::original` | `BDJ-OBJECTIVE-3-CAND` | RETURNED | 4854 ms | 220 |
| `clear_confirmed_uncertainty::enhanced` | `BDJ-OBJECTIVE-4-CAND` | RETURNED | 5467 ms | 373 |
| `multiple_supported_uncertainties::original` | `BDJ-OBJECTIVE-3-CAND` | RETURNED | 9734 ms | 911 |
| `multiple_supported_uncertainties::enhanced` | `BDJ-OBJECTIVE-4-CAND` | RETURNED | 6578 ms | 545 |
| `no_supported_uncertainty::original` | `BDJ-OBJECTIVE-3-CAND` | RETURNED | 4340 ms | 237 |
| `no_supported_uncertainty::enhanced` | `BDJ-OBJECTIVE-4-CAND` | RETURNED | 5661 ms | 366 |

## Direct-QG — question generation

Dispatches: **8** (returned 7, held/failed 1)

| Metric | Value |
|---|---|
| Latency median | **20106.5 ms** |
| Latency mean | 20731 ms |
| Latency min / max | 10891 / **30037** ms |
| Latency P95 | WITHHELD — n too small for a reliable percentile |
| Prompt tokens (total) | 13971 |
| Completion tokens (total) | 16409 |
| Total tokens | 30380 |
| Dispatches without usage metadata | 1 |
| `max_tokens` cap | 4000 (a cap, not consumption) |

| Proposed target | Value | Observed | Verdict |
|---|---|---|---|
| Median | ≤ 10000 ms | 20106.5 ms | **NOT MET** |
| P95 | ≤ 25000 ms | worst case 30037 ms | NOT_ASSESSABLE — sample too small; worst case reported instead |
| Worst case vs P95 target | ≤ 25000 ms | 30037 ms | **EXCEEDS** |

| Case | Prompt | Status | Latency | Completion tokens |
|---|---|---|---|---|
| `complete_offer_single_choice::original` | `QG-PROPOSE-6-CAND` | RETURNED | 18636 ms | 2331 |
| `complete_offer_single_choice::enhanced` | `QG-PROPOSE-7-CAND` | HELD (`E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN`) | 30037 ms | — |
| `missing_price::original` | `QG-PROPOSE-6-CAND` | RETURNED | 16341 ms | 1875 |
| `missing_price::enhanced` | `QG-PROPOSE-7-CAND` | RETURNED | 10891 ms | 1065 |
| `single_choice_acceptability::original` | `QG-PROPOSE-6-CAND` | RETURNED | 14829 ms | 1861 |
| `single_choice_acceptability::enhanced` | `QG-PROPOSE-7-CAND` | RETURNED | 27314 ms | 3818 |
| `multiple_choice_factors::original` | `QG-PROPOSE-6-CAND` | RETURNED | 26223 ms | 3144 |
| `multiple_choice_factors::enhanced` | `QG-PROPOSE-7-CAND` | RETURNED | 21577 ms | 2315 |

## What this establishes

- The **BDJ** task shape meets both proposed targets comfortably: median
  ≈ 5.6 s against a 15 s target, worst case ≈ 9.7 s against a 30 s target.
- The **Direct-QG** task shape does **not** meet its targets. Median ≈ 20.1 s
  against a 10 s target; worst case ≈ 30.0 s, which is the configured
  timeout and was recorded as `E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN`.
- Completion tokens track latency closely across the QG runs (1 065 tokens
  → 10.9 s; 3 818 tokens → 27.3 s). Output volume, not prompt length, is the
  dominant term. This is the lever CP-06 should pull.

## What this does not establish

- Nothing about V4 or V5 quality, validity or research merit.
- No reliable P95, and therefore no basis for a percentile-based claim.
- No cost figure: `provider_reported_cost` was absent from every recorded
  run, so actual spend is **not available** and is not estimated here.
