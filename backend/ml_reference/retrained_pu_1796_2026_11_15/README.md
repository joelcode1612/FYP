# SiteWise PU experimental retraining (observed-only, 1,796 records)

## Overview

This package was prepared from the uploaded `SiteWise_PU_1849_Recovery_Verified.xlsx`. It filters out the 53 research subjects that had one or more missing **original 47-feature** values; it does not use the 103 statistically imputed measurements in the separate experimental file. The cleaned matrix is 880 known existing F&B outlets (`P`) + 916 unlabelled commercial-property locations (`U`) = **1,796 unique subjects**. Only 47 original columns are model inputs: the additional age columns are not part of this experiment.

## Outputs

- `SiteWise_PostgreSQL_Safe_PU_53_Training_Copy_Delete.sql`: SQL to create a separate *research training copy* of `sitewise_analytics.subject_features`, delete the exact 53 incomplete subject IDs **from that copy only**, and assert expected counts. No live tables are changed unless you run the SQL.
- `SiteWise_PU_53_Excluded_Incomplete_Records.csv`: Exact 53 IDs with missing feature names.
- `SiteWise_PU_1796_Observed_47_Features.csv`: All 47 feature values observed (not imputed), plus subject ID, P/U labels, state, latitude, longitude.
- `SiteWise_PU_1796_Complete_Observed_Only.xlsx`: (if included) same clean matrix in Excel with an exclusion audit.
- `train_sitewise_pu_1796.py`: Reproducible Python training + spatial validation + 6-model comparison.
- `SiteWise_PU_Model_Comparison.csv`: 3 geographically held-out folds, 2 algorithms, 3 feature sets.
- `SiteWise_PU_Spatial_Validation_Fold_Results.csv`: Per-fold metrics and class counts.
- `SiteWise_PU_Spatial_Validation_Predictions.csv`: *Held-out* P-vs-U scores for auditing, not validated commercial success labels.
- `SiteWise_PU_44_Features_recommended_research_ResearchOnly.joblib`: Five fitted hist-gradient-boosted bag models; **research-only, not production-ready**.
- `SiteWise_PU_47_Features_full47_restricted_ResearchOnly.joblib`: Same methodology on all 47 features with unresolved LandScan rights/provenance. Do not deploy before approval.
- `predict_research_pu.py`: Standalone predictions from saved model dictionaries, not a drop-in backend replacement.
- `SiteWise_PU_FYP_Methodology_Report.docx` / `.md`: Source-ready FYP methods/results/limitations. Adapt citations and word choice to actual implementation chapter.

## Training

This was an **experimental bagged positive-vs-unlabelled proxy classifier**, not an established non-negative PU risk estimator or a calibrated P(success) model. During each training bag all P records were labelled 1 and a random ~78% subset of the U records was temporarily labelled 0 for estimation. U records are **not** verified negatives; model output means association with the known P records versus the sampled U background.

Validation: 3 spatial GroupShuffleSplit partitions by approximately 0.07-degree latitude/longitude blocks, 23% of geographic groups held out. No held-out records were used for fitting, scaling or tuning within each fold. Scores were ROC-AUC, average precision and balanced accuracy for distinguishing P from U; **none** tests business success or actual category-specific viability. Group blocks may still share data-source bias and nearby dependencies, so this is a preliminary validation.

Three feature sets were compared: full original 47 (with licence hold); 44 excluding three LandScan columns; and 34 excluding LandScan plus 10 F&B competitor columns to test possible self-match leakage. Two learners were tried (Logistic Regression and Histogram Gradient Boosting). The highest-AUC option *among non-LandScan feature sets* is recorded as the preferred research candidate; the best full-47 model is saved separately for comparison.

## Run it

Python libraries used: `scikit-learn==1.8.0`, `joblib==1.5.3`, `numpy==2.3.5`.

```powershell
cd path\to\SiteWise_PU_Retraining_1796
python train_sitewise_pu_1796.py --input SiteWise_PU_1796_Observed_47_Features.csv --out .
python predict_research_pu.py --model SiteWise_PU_44_Features_recommended_research_ResearchOnly.joblib --csv SiteWise_PU_1796_Observed_47_Features.csv --out research_scores.csv
```

**Do not overwrite** the app's current `PU_model.joblib`. The artifacts are dictionaries of multiple sklearn pipelines and will not load through the existing backend `ModelLoader` without a separate adapter. `joblib.load` is only safe for artifacts you trust.

## Gates before production or final scientific claims

1. Source positive-label audits: some P records are unverified or partially verified; improve independent source evidence.
2. Resolve potential F&B competitor self-matching and inconsistent place inventory sources. Review population/raster coverage and accessible-route measurements.
3. Confirm the terms and origins of every LandScan-derived feature; the source workbook flags missing rights documentation. Excluding LandScan is a *precaution*, not a legal determination about the dataset.
4. Evaluate spatial cross-validation at multiple block sizes, external cities and independently curated business-outcome labels.
5. Recompute site data for future unlabelled properties using the same feature definitions and inputs; new properties not in the research cohort may have missing features.
6. This is **general F&B location P/U association**. A café-vs-restaurant-vs-bakery classifier is a separate task requiring valid category-labelled examples.
7. Dropping 53 rows (14 P, 39 U) may create selection bias. Document limitations rather than claiming all 1,849 complete.

## SQL safety

Review SQL first. It creates a new `sitewise_ml.pu_training_1796_20261115` table using the `sitewise_analytics.subject_features` source. The only `DELETE` targets this *new copy*. Transactions abort on unexpected source/target counts or missing IDs. PostgreSQL may require an explicit `ROLLBACK` after an error.

**No database changes were performed by ChatGPT.**
