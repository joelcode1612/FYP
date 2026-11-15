# SiteWise — category-aware recommendation research package (2026-11-15)

## Deliverables

- `SiteWise_Category_Aware_Recommendation_ResearchOnly.joblib` — **newly trained** 54-feature category classifier plus the **previously trained** 64-feature P-vs-U ensemble. The PU stage was **not retrained** in this experiment.
- `train_recommender.py` — reproducible data matching, geographic holdout model comparison, training and artifact export.
- `recommend_and_explain.py` — batch research recommendation lookup, per-property inference and **genuine permutation SHAP** for both stages.
- `sitewise_backend_adapter.py` — opt-in FastAPI-service adapter that uses exactly the validated model input feature names.
- `SHAP_Background_Category_54.csv` — real, stratified P examples (not synthetic).
- `SHAP_Background_PU_64.csv` — real P and U observations (not synthetic).
- `Model_Comparison.csv`, `Spatial_Fold_Results.csv`, `Spatial_Heldout_Predictions.csv` — evaluation evidence.
- `916_U_Category_Aware_Predictions.csv` — exploratory outcomes for U locations, **not** business-success probabilities.
- `Example_MD-00510_Explained.json` — SHAP additivity/score identity evidence.
- `SiteWise_PU_1796_With_Known_Business_Types.xlsx` and `SiteWise_PU_1796_Expanded_Observed.csv` — exact aligned input sources.

## Reproducible training

```bash
python train_recommender.py \
  --labels-xlsx SiteWise_PU_1796_With_Known_Business_Types.xlsx \
  --features-csv SiteWise_PU_1796_Expanded_Observed.csv \
  --pu-artifact SiteWise_PU_64_Logistic_expanded_age_residential_64_ResearchOnly.joblib \
  --out ./trained
```

The 64-feature model above is a prerequisite for **retraining**, shipped inside the package so the training process is reproducible.

## Prediction and ranking

```bash
python recommend_and_explain.py \
  --model SiteWise_Category_Aware_Recommendation_ResearchOnly.joblib \
  --features-csv SiteWise_PU_1796_Expanded_Observed.csv \
  --subject-id MD-00510
```

For a **selected business type**:

```bash
python recommend_and_explain.py \
  --model SiteWise_Category_Aware_Recommendation_ResearchOnly.joblib \
  --features-csv SiteWise_PU_1796_Expanded_Observed.csv \
  --rank --business-type 'Cafe / Coffee' --pu-min 0.5 --top 10
```

`--pu-min` is optional. A cutoff of 0.5 is a **research filter**, not a calibrated business-success threshold. The ranking uses the selected category's conditional pattern-association, with general P/U association as a tiebreaker. **It is not a learned entrepreneur preference scorer.** Apply SiteWise's existing authenticated assignment, budget and size filters separately, using their actual repository/service contracts.

## Genuine dual-model SHAP

```bash
python recommend_and_explain.py \
  --model SiteWise_Category_Aware_Recommendation_ResearchOnly.joblib \
  --features-csv SiteWise_PU_1796_Expanded_Observed.csv \
  --subject-id MD-00510 --business-type 'Restaurant' --explain \
  --category-background SHAP_Background_Category_54.csv \
  --pu-background SHAP_Background_PU_64.csv
```

- Category SHAP explains **the selected category classifier's class output** in its probability-output units, **not** probability of successful operation.
- General PU SHAP explains the **64-feature general P-vs-U association**.
- Both use their own saved fitted preprocessing and real background rows.
- Both require SHAP additivity residual <= `1e-5`; otherwise the explanation is unavailable.
- SHAP feature names are returned as machine-readable keys. Map them to user-friendly labels in `property_insights_service.py`, keeping original units and no invented positive narratives.

## Integration into the actual `joel` repository

1. **Preserve** the default `backend/src/sitewise/ml/PU_model.joblib` and the existing 47-feature model loader.
2. Put this package under `backend/ml_reference/category_recommender_v2/` or another existing versioned ML research location. Keep generated train data out of runtime modules.
3. Introduce a separate **research** variant for this artifact; it is **not** the same schema as the existing `ModelLoader` (`category_model`, `pu_estimators`, `metadata`). Use `sitewise_backend_adapter.py` in a package import context, adjusting its import to the chosen repo module path.
4. Resolve all **64** PU input names and the **54** category input names from trusted database fields. Do not fall back to random, district-level, or invented values. The saved training pipelines have imputers for documented missing measurements.
5. Modify the existing `recommendation_search_service.py` to call this variant only when explicitly enabled and permitted. Keep existing authenticated/assigned-property restrictions and deterministic user preference fit. Do not silently mix `sitewise_app.properties.suitability_score` from the 47-feature model with new 64-feature scores.
6. Update `property_insights_service.py` to invoke *this exact* category + PU stage for scores and the matching SHAP explanation; do not feed its result into the old 47-feature background or cache. Include artifact version/checksum in the cache key.
7. Show category result as **exploratory business-category similarity** until independent validation supports a stronger claim. If SHAP or category model input is missing, report unavailable rather than generate a mock value.
8. Do not execute research SQL cleanup against live property, user or assignment tables. No database changes are performed by this package.

**Important:** This is a local artifact and example integration adapter, **not an automatically installed GitHub/local Windows repository patch**. It has not modified your actual `C:\Users\Lenovo\AndroidStudioProjects\FYP` checkout.
