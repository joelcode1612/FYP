# Add the selected research PU model to your existing SiteWise backend — without replacing the original

This add-on is based on your `joelcode1612/FYP` **main** branch checked on 2026-11-10.
It does NOT make any changes to your repository itself. It contains ONLY additive files.

## Crucial clarification

`PU_model.joblib` (already present in `backend/src/sitewise/ml/`) and the included
`sitewise_selected_pu_model.joblib` are **both P-versus-U Layer 1 models**. The new file is
not a personalised Layer 2 recommender. The `sitewise_selected_pu_model.joblib` is the
47-feature logistic-bagging selection from the earlier canonical 190-column training matrix,
not a new model trained on the newer recovered 231-column matrix.

Your current backend ALREADY has these modules; **do not overwrite** any of them:
`ml/model_loader.py`, `ml/pu_learning.py`, `ml/pu_model_compat.py`,
`ml/shap_explainer.py`, `ml/property_features.py`, `ml/property_predictor.py`,
`api/v1/ml_predictions.py`, `api/v1/recommendations.py`, `services/recommendation_service.py`.

## 1. Copy the add-on

From this ZIP's `backend` folder, copy only the NEW files into your local `FYP/backend`:

- `src/sitewise/ml/sitewise_selected_pu_model.joblib`
- `src/sitewise/ml/selected_pu_integration.py`
- `src/sitewise/ml/selected_pu_cli.py`
- `src/sitewise/api/v1/selected_pu_routes.py` (optional API)
- `ml_reference/shap_background_47.csv`
- `ml_reference/example_property_47.json`

The original `PU_model.joblib` stays where it is. Existing `/ml/...` routes still use it.
`model_loader.py` already supports another filename with
`ModelLoader().load("sitewise_selected_pu_model")` — NO loader modification needed.
Existing `pu_model_compat.py` supports deserialisation of this bagged model — do not
copy the training package's `pu_model.py` into your backend or replace `pu_model_compat.py`.

## 2. Install runtime dependencies in your backend virtual environment

The backend `pyproject.toml` lists joblib only in `[dev]` and does not list scikit-learn
or SHAP among runtime dependencies. For this artifact's tested environment use:

```powershell
cd C:\Users\Lenovo\AndroidStudioProjects\FYP\backend
python -m pip install "joblib==1.5.3" "scikit-learn==1.8.0" "shap==0.50.0" "numpy==2.3.5"
```

Update and lock your backend's dependency manifest after confirming compatibility
with your deployment Python version and the original `PU_model.joblib`.
Never load joblib files from untrusted sources.

## 3. Confirm ORIGINAL model remains the default

From the backend folder:

```powershell
$env:PYTHONPATH = "src"
python -m sitewise.ml.cli inspect
```

Do not rename or overwrite the original `PU_model.joblib`.

## 4. Inspect, score and explain the SELECTED alternate model

```powershell
python -m sitewise.ml.selected_pu_cli inspect
python -m sitewise.ml.selected_pu_cli predict --features-json ml_reference/example_property_47.json
python -m sitewise.ml.selected_pu_cli explain --features-json ml_reference/example_property_47.json --out ml_reference/example_shap_result.json
```

The sample property is a **real, complete-case U row from your older training matrix**;
its score is in-sample, not an independent evaluation. The 25 background rows are actual
complete-case training observations (12 positive, 13 unlabeled) with ONLY 47 features.
Replace/review this reference with a version-controlled, legally usable and representative
reference sample from the **same model's feature definitions** before deployment.

Your existing SHAP engine calculates **permutation SHAP** on the research model's
positive-label association (`predict_proba(X)[:, 1]`), NOT the Layer 2 personalised score.
Show SHAP as a separate "Research model: factors associated with P-labelled outlets" section,
with positive and negative contributions. `baseline + sum(contributions) ≈ score`.
Do not describe the score as probability of commercial success.

## 5. OPTIONAL: register three new API routes (no existing route replaced)

In `src/sitewise/api/v1/router.py`, import the new module **beside** existing imports:

```python
from sitewise.api.v1 import selected_pu_routes
```

At the bottom near the existing `ml_predictions` registration, add:

```python
router.include_router(selected_pu_routes.router, prefix="/ml/selected", tags=["ml_selected"])
```

Then the added authenticated routes are:

- `GET /api/v1/ml/selected/model` (confirm your application's outer API prefix)
- `GET /api/v1/ml/selected/properties/{catalog_id}/prediction`
- `GET /api/v1/ml/selected/properties/{catalog_id}/explanation`

Use catalogue **text IDs** such as `MD-00510`, not integer rental IDs. Your existing
`PropertyFeatureRepository` resolves real features through verified mapping and fails
closed on missing data; it does not silently alias competitors or fill unknowns with zero.
The property endpoints need the existing analytics DB data loaded with the exact features.
Do not assume that uploading the joblib alone imports those feature rows to PostgreSQL.

## 6. Layer 2 and Layer 3: keep them distinct

Layer 1: original or selected PU research association (choose one model for a run)
  -> Layer 2: **not in this add-on**. Build preference eligibility/matching using
     the existing entrepreneur preferences routes and property characteristics
  -> Layer 3: research SHAP explains the chosen Layer 1 PU score; preference
     explanations must be separately derived from actual budget/size/etc rules.

Your existing `api/v1/recommendations.py` currently provides CRUD/history, not
personalised ranking inference. Your current `/suitability` endpoint uses separate
premises-assessment logic. Do **not** replace either wholesale with this model.

## 7. Rollback

Remove ONLY the six copied add-on files and the optional router import/registration.
Your existing PU artifact and endpoints remain unchanged.

## Provenance and limitations

- New alternate model: 47 features, older canonical 1,849-row matrix (894 P / 955 U).
- Unlabeled U is NOT a failed/unsuitable business.
- Scores are uncalibrated P/U-origin associations, not business outcomes.
- The recovered `Sitewise_PU_Matrix_1849_Recovered.csv` (1,849 x 231) was NOT
  provided and not used for retraining. Re-run fresh CV and refit if you adopt it.
- Do not expose SHAP unbounded per list item; cache + rate limit explanations.
