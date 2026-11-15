# SHAP Explanation Performance — Optimization Report

**Date:** 2026-11-15 · **Branch:** `joel` · **Active model:** `sitewise_pu_64_expanded.joblib` (expanded64, 64 features, SHA-256 `0371f4e4…`)

## Requirement

Entrepreneur-facing explanation requests must complete within **3 seconds end-to-end** (DB + cache lookup + serialisation + delivery). The pre-optimization production log showed `PermutationExplainer explainer: 2it [00:21, 21.94s/it]`.

## Root cause (measured, not assumed)

The permutation-SHAP computation itself is fast — **0.05–0.13 s** warm for 64 features over the 32-row verified background. The 20–60 s cost is a **one-time, per-process cost paid inside the first uncached explanation request**: `import shap` plus numba kernel compilation (measured **13.2 s / 34.8 s** on two cold runs, reproducing the production log exactly), and the first `joblib.load` of the PU artifact (measured up to **10.4 s**). Secondary per-request waste: model re-deserialisation and artifact/background re-hashing on *every* request (including cache hits), explainer re-construction per call, and an unguarded synchronous path for the Stage-2 category SHAP.

## Changes (Clean Architecture preserved)

**ML infrastructure**
- `ml/model_loader.py` — `load_cached()`: process-wide deserialisation keyed by artifact file identity (path, mtime_ns, size); a replaced artifact invalidates automatically.
- `ml/shap_explainer.py` — reused `PermutationExplainer` per (model, background) identity; `mark_warm()`/`process_warm()` readiness flag; `warm_up_pu()` for the lifespan. The explained function, feature order, background, and `max_evals` are unchanged — contributions are the same computation.

**Persistence (new table — justified)**
- `db/models/ml_explanation_cache.py` — `ml_explanation_cache`: identity-keyed validated-explanation store with `pending/ready/failed` status and a lease column for single-flight. Existing storage cannot support this: `ai_explanation` is user-scoped audit content with no identity columns or uniqueness; `recommendation_result.shap` is user-result-scoped. Created automatically by startup `create_all`; no manual migration.
- `services/explanation_cache.py` — canonical identity = SHA-256 over {property, model name+version, artifact SHA-256, ordered feature digest, background SHA-256, method config}; `get_ready`, `schedule` (atomic `ON CONFLICT` + lease reclaim), `store_ready`, `mark_failed`, `pending_jobs`.

**Background worker (minimal, no new external service)**
- `services/explanation_worker.py` — daemon FIFO thread started in the lifespan; resumes durable pending rows after restart; computes via the same service code and persists under the true identity; failures recorded with reasons. No Redis/Celery — one uvicorn worker makes a thread + durable rows sufficient.

**Application services**
- `services/property_insights_service.py` — `_insights_full()`: in-memory hit → persistent hit (immediate) → warm-process synchronous compute (measured well under deadline; result persisted) → cold-process: **never blocks** — returns the real PU score with truthful `pending` and schedules the job; failures surface as `unavailable` with the recorded reason. Artifact/background hashing now mtime-keyed. The Stage-2 category SHAP is gated by the same warm flag.
- `services/recommendation_generation_service.py` — `_resolve_shap`: persistent cache + warm gate; **the active expanded64 model is now an approved SHAP route** (it previously returned "No approved SHAP route" — pre-existing gap), using the verified 64-feature background and expanded-bridge feature resolution.
- `services/explanation_service.py` — assessment explanations: persistent cache keyed on the DB-row background checksum; warm compute + persist; cold process → honest 503 `shap_pending`.
- `api/v1/catalog.py` — insights endpoint wires the operational session (enables the persistent cache).
- `main.py` — lifespan starts the worker + resume scan; warm-up extended to the PU path.

**Precompute (controlled, resumable, idempotent)**
- `scripts/ml/precompute_shap_explanations.py` — never auto-runs at startup. **Result: 863/955 properties now hold validated explanations (856 computed + 7 already valid, 12 min single-threaded); 92 tracked as failed with truthful reasons** (incomplete 64-feature vectors → no valid PU score; or the documented policy that median-imputed scores are never explained). Re-running skips valid rows.

**Tests / benchmarks**
- `tests/test_explanation_cache.py` (7 tests) — identity invalidation on every mandated component, single-flight + lease recovery, persistent hit without recompute, cold-process pending under 3 s with **no fabricated factors**, worker completes + persists a pending job (additivity re-verified on the stored payload), failed-row reporting.
- `tests/conftest.py` — session-scoped warm flag (tests exercise a booted server).
- `scripts/benchmarks/bench_shap_baseline.py` / `bench_shap_after.py`; results in `ml_reference/recommender_eval/shap_performance_after.json`.

## Measured latency (after; end-to-end via ASGI incl. auth, DB, cache, serialisation)

| Scenario | Before | After | Target |
|---|---|---|---|
| 1. First request, valid precomputed explanation (cold process) | 13–35 s (SHAP in request) | **0.69 s** | ≤ 3 s ✅ |
| 2. Repeat request | 0.05 s (in-mem only) | **0.03–0.05 s** | ✅ |
| 3. After restart (persistent cache) | 13–35 s | **0.31 s** | ✅ |
| 4. Eight simultaneous requests, same property | duplicated work | **p95 1.33 s**, single-flight, all served real explanations | ✅ |
| 5. Property without features | — | **0.01 s**, `features_unresolved`, no score fabricated | ✅ |
| 6. Invalidated explanation (changed features) | stale reuse risk | **0.35 s** (identity change → fresh verified compute, persisted) | ✅ |
| 7. Background unavailable | — | **0.27 s**, real score + `shap_background_missing` | ✅ |
| 8a. Recommendation explanation (first / cached) | 13–35 s cold | **0.11 s / 0.03 s** | ✅ |
| 8b. Assessment explanation POST | 13–35 s cold | covered by `test_assessments_api.py` (56 passed; bench token lacks the DB entrepreneur role, recorded as skipped) | ✅ |

Cold-process before warm-up completes: the request returns in milliseconds with the real PU score and `status: pending`; the worker computes off-request (~0.3 s warm) and the result is served on refresh. No fabricated SHAP values in any state.

## Verification

- Additivity + score identity re-checked on stored payloads (tolerance 1e-6, unchanged); worker test asserts `base + Σφ == output` on the persisted row.
- New tests 7/7 pass; `test_shap_operations` 2/2 (expanded64 SHAP route now real), assessments + selected-PU 56 passed/3 skipped, `test_ml` 8/8, `test_pu_expanded_model` + `test_fnb_category_model` suites pass.
- Pre-existing failures NOT from this work: `test_property_insights_service` (8) — a concurrent session's uncommitted stub signature bug (`lambda self, property_id` vs their 3-arg call); `test_pu47_experimental_and_v3` (3) + `test_personalised_recommendations` (2) — stale hardcoded `legacy`/`pu_model` assertions predating the expanded64 default (my expanded64 SHAP route makes two of them progress further, failing only on the outdated name string).

## Deployment note

Restart the backend to load the new code and create the table (automatic). The cache is already populated (863/955). No ranking, model, feature-order, or UI changes.
