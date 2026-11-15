# SiteWise 64-feature expanded PU research package

**Best exploratory P-versus-U model:** `SiteWise_PU_64_Logistic_expanded_age_residential_64_ResearchOnly.joblib`.

- 1,796 training subjects: 880 P and 916 U (same records as the prior training baseline)
- New attributes: 12 WorldPop Malaysia 2025 population-age counts + 8 OSM residential density/coverage measures
- 3 LandScan variables excluded -> 64 features (baseline 44 + 20 additions)
- 232 missing residential measurements across 38 subjects retained as missing and handled inside the training pipeline
- Mean spatial-holdout ROC-AUC: **0.699824** (logistic), compared with **0.646985** for 44-feature logistic baseline
- 52-feature residential-only logistic alternative: **0.698340**
- All scores are **P-versus-U research association**, NOT F&B business success probability or Café/Restaurant category prediction.

## What is in the package

| File | Description |
|---|---|
| `SiteWise_PU_64_Logistic_expanded_age_residential_64_ResearchOnly.joblib` | Highest-AUC 64-feature research model, 5 bagged logistic estimators |
| `SiteWise_PU_52_Logistic_baseline_plus_residential_52_ResearchOnly.joblib` | 52-feature comparison model without population age |
| `SiteWise_PU_64_expanded_age_residential_64_ResearchOnly.joblib` | 64-feature alternative Histogram Gradient Boosting model |
| `SiteWise_PU_44_baseline_44_ResearchOnly.joblib` | 44-feature HGB research comparator |
| `SiteWise_PU_1796_Expanded_Observed.csv` | Subject-keyed training table, with explicit nulls for unavailable residential measurements |
| `Expanded_Data_QA.json` | Source quality, missingness and subject counts |
| `Expanded_Model_Comparison.csv` | 8 model comparisons across 3 spatial holdouts |
| `Expanded_Spatial_Fold_Results.csv` | Per-fold metrics |
| `Expanded_Heldout_Predictions.csv` | Holdout subject-level scores for HGB baseline and expanded comparisons |
| `build_expanded_training_data.py` | Recreate input from existing xlsx workbooks |
| `train_expanded_pu.py` | Cross-validation and HGB model fitting |
| `refit_logistic_candidates.py` | Fit candidate and sensitivity logistic models |
| `predict_expanded_pu.py` | Minimal standalone research inference utility |
| `SiteWise_Expanded_PU_Methodology_Report.md` | FYP methodology/results and limitations |

## Run

`python train_expanded_pu.py --input SiteWise_PU_1796_Expanded_Observed.csv --out .`

`python refit_logistic_candidates.py`

The preprocessor fits only on each training split. U records are not treated as proven negatives. Age coverage is incomplete in some locations and positive-label validation remains limited. The old 47-feature backend contract **cannot** load this 64-feature model without versioned backend changes. No application, SQL tables, or original data were altered by this package.
