# 07 — ML Integration Report (actual status)

> **Historical-state warning (updated 2026-11-12):** The inventory below is a
> snapshot of the repository on **2026-11-04**. Its statements that no model
> artifacts exist and that all model inference is unavailable are no longer true.
> The current tracked artifacts, runtime behavior, checksums, reproducible
> property scores and remaining training-provenance gaps are documented in
> `10_THREE_LAYER_RECOMMENDATION_SYSTEM.md` and
> `ml_reference/pu_artifact_verification_2026_11_12.json`.

## Verified precondition (2026-11-04; historical, superseded)

* `ml/model_loader.py`, `ml/pu_learning.py`, `ml/shap_explainer.py` were empty
  stubs (`class X: pass`).
* **No trained model artifact exists anywhere in the repository** (searched
  `*.pkl`, `*.joblib`, `*.onnx`, `*model*.json`).
* No approved suitability scoring specification exists (no weights, benchmark
  tables, or normalisation ranges documented anywhere).
* `shap` is not a declared dependency; `numpy` was missing from the venv and
  has been added to `pyproject.toml`.

Therefore **no real predictions can be produced today**, and per the task
rules nothing is fabricated: the previous `{"score": 0.0}` stub (which
masqueraded as a model output) has been removed.

## What is now implemented (the real integration path)

| Module | Behaviour |
|---|---|
| `ml/model_loader.py` | Loads `ml/artifacts/pu_model.pkl` + its feature contract (`pu_model_features.json`) + metadata; validates existence, JSON shape and feature-order agreement with `feature_names_in_`; raises `ModelUnavailableError` with the exact missing prerequisite otherwise. |
| `ml/pu_learning.py` | `predict()` enforces the feature contract (missing geospatial features are **reported, never imputed**), runs `predict_proba`/`predict`, normalises to `PUPrediction`; `predict_or_report()` returns the explicit availability envelope for API use. |
| `ml/shap_explainer.py` | Guarded `shap` import; loads the model through the same loader; uses the `explainer_type` recorded in model metadata; raises `ModelUnavailableError` when the library/artifact is missing. |
| `domain/suitability_engine.py` | Returns an explicit unavailable assessment (`available: false`, `score: null`, missing prerequisites listed) — no fabricated numbers. |
| `api/v1/suitability.py` | Authenticated; 404 for unknown properties; 200 + availability envelope while scoring is unavailable. |

## Missing prerequisites (exact)

1. Trained PU-Learning artifact at `backend/ml/artifacts/pu_model.pkl`
   (+ `pu_model_features.json` with the exact training feature order, +
   `pu_model_meta.json` with `version` and `explainer_type`).
2. The approved supervisor-reviewed suitability specification (premises
   scoring weights, benchmarks, business-matching rules).
3. The feature-extraction pipeline mapping `property_id` → geospatial
   features from `Final_Location_Analysis` (the analytics tables to feed it
   exist and are verified reachable).
4. `shap` added to dependencies when explanations are actually wired.

Until then every suitability/ML endpoint answers with a structured
"unavailable" report — never a fabricated score, never a zero-as-prediction.
