# SiteWise — Expanded P/U Model Experiment (2026-11-15)

## Study objective

Determine whether newly collected **WorldPop 2025 age-group population estimates** and **OSM residential building/land-use measurements** improve the ability to distinguish known F&B outlet locations (positive, P) from unlabelled commercial properties (U), compared with the previously trained SiteWise baseline. This study **does not** estimate profitability, opening success, or the best F&B category.

## Data and matching

The previous recovery workbook contained 1,849 unique geospatial subjects (894 P, 955 U). To compare with the prior 47-feature complete-case experiment, the same 53 subjects with an incomplete original model feature were excluded. The resulting research dataset contained **1,796 unique subjects: 880 P, 916 U**. No previously estimated values from the separate 103-cell imputation workbook were used.

Inputs were matched on exact `subject_id` and `sample_class` from:

- `SiteWise_PU_1796_Observed_47_Features.csv` derived from `SiteWise_PU_1849_Recovery_Verified.xlsx`
- `SiteWise_PU_1849_Recovery_Verified.xlsx`, `PU 47 Features`: 12 WorldPop age-group counts, 500 m and 1 km
- `SiteWise_PU_Residential_Density_1849.xlsx`, `01_Combined_P_U`: 8 residential building-density/coverage attributes

The expanded source matrix contains 67 numeric candidate features: 47 original plus 12 age plus 8 residential. The 3 original LandScan ambient-population features were excluded from this retraining experiment due to unresolved training licence/provenance restrictions, yielding **64 model input features**. The existing 44 baseline inputs were unchanged.

### Data availability and quality

- All 12 WorldPop age-group counts are populated for 1,796 subjects; source year 2025. Of these, 1,067 have `age_data_status=COMPLETED`, 590 have `PARTIAL_COVERAGE`, and 139 `LOW_COVERAGE`. Counts are estimated raster summaries, not censused exact persons at every address.
- There are 232 absent residential field values across 38 subjects (34 U, 4 P) in the eight added OSM-based attributes. They remained missing in the input CSV and were **not zero-filled**. Logistic Regression's median imputation/missing indicators were fitted inside training folds only; Histogram Gradient Boosting handled missing inputs natively.
- Geospatial competitor counts, walking-access features, transit measures and population totals were already included among the original 44/47 features. Those are **not newly added** in this comparison.
- DOSM household income was not present in these inputs as a verified matched subject-level training column and **was not included** in the experiment. District-level DOSM information should retain its geographic scale if merged later.

## Experimental design

Four feature configurations were evaluated on **identical** three spatial group holdouts using 0.07-degree grid cells, `GroupShuffleSplit` (23% group holdout target; seed 20261115):

1. Baseline: 44 features excluding LandScan
2. Baseline + 12 population-age counts: 56 features
3. Baseline + 8 residential attributes: 52 features
4. Baseline + both additions: 64 features

Each configuration was tested with Logistic Regression (median imputer with missingness indicators, standardisation, regularisation) and Histogram Gradient Boosting. In each fit, 3 bagging replicates used all training-fold P records and a separately sampled 78% of training-fold U records as an unlabelled reference group. The predicted P-versus-U association was the mean of the bagged classifiers' outputs. Validation subjects and their grid cells never entered model fitting within their own fold. Three folds are an exploratory evaluation, not a final independent external test.

### Spatial validation comparison

| Feature set | Algorithm | Mean ROC-AUC P-versus-U | Standard deviation | Mean average precision |
|---|---|---:|---:|---:|
| 44 baseline | Logistic Regression | 0.646985 | 0.081815 | 0.595909 |
| 44 baseline | Histogram Gradient Boosting | 0.662849 | 0.073969 | 0.623374 |
| 56 (+age) | Logistic Regression | 0.653943 | 0.043094 | 0.610960 |
| 56 (+age) | Histogram Gradient Boosting | 0.663486 | 0.070381 | 0.621648 |
| 52 (+residential) | Logistic Regression | 0.698340 | 0.065106 | 0.642856 |
| 52 (+residential) | Histogram Gradient Boosting | 0.677052 | 0.076380 | 0.644301 |
| **64 (+age +residential)** | **Logistic Regression** | **0.699824** | **0.039046** | **0.678400** |
| 64 (+age +residential) | Histogram Gradient Boosting | 0.685416 | 0.067147 | 0.644539 |

The highest observed mean ROC-AUC was **0.699824**, achieved by the 64-feature Logistic Regression candidate. Relative to the logistic baseline, this is a **+0.052839** absolute AUC improvement across the same exploratory spatial splits. However, relative to the 52-feature residential-only logistic model, the added age data improved mean AUC by only **+0.001484**; the apparent improvement is driven mostly by residential measurements and should not be interpreted as proof that age variables add independent predictive utility. Results varied across holdouts; statistical confidence in the differences is limited.

## Research artifacts

A five-bag Logistic Regression model was fitted on the complete research dataset for each of the 64- and 52-feature configurations and saved as a standalone `joblib` package. The model includes ordered input feature names and provenance warnings. A five-bag Histogram Gradient Boosting research artifact is also saved for the 64-feature configuration. These artifacts must not overwrite the deployed `PU_model.joblib`, which has a different 47-feature contract.

The output is an uncalibrated P-versus-U **research association**, not a calibrated probability of restaurant success. The unlabelled background may contain suitable properties, and known F&B outlets are not verified profitable businesses. Category-specific suitability (e.g. Café versus Restaurant) requires a separate validated model using verified business categories and corresponding features.

## Limitations and future work

1. Positive outlet labels and competitor self-matching have unresolved independent-source verification; residential/age feature coverage varies spatially.
2. The U set consists of unlabelled properties, **not negative examples**; P-versus-U ROC-AUC measures proxy discrimination only.
3. A 0.07-degree grid holdout mitigates but does not fully remove spatial autocorrelation, and the same folds were used to choose variants. Evaluate on an additional independent time/area holdout before production claims.
4. Check age raster coverage and subject matching before assessing new listings. Repeat comparisons on full-coverage subsets as a sensitivity analysis.
5. Verify rights and model-use conditions of each input source; LandScan was excluded from the recommended models due to unresolved provenance.
6. DOSM income can be added later only if the geographic join is validated and district-level values are not falsely represented as building-specific income.
7. The deployed FastAPI model reader currently expects 47 ordered features. A new 64-feature extraction contract and versioned adapter are required; do **not** swap model files blindly.
8. Retain the previous model for comparison. Neither old nor new models should be labelled *production-ready* based on these experiments alone.

## Reproducibility

1. Build the expanded research dataset with `build_expanded_training_data.py` (using the exact three input files).
2. Train and compare with `train_expanded_pu.py --input SiteWise_PU_1796_Expanded_Observed.csv --out .`.
3. Refit the best-performing research Logistic variants with `refit_logistic_candidates.py`.
4. Verify loading/inference with `predict_expanded_pu.py` and an input JSON containing all model feature keys; nullable residential fields may be supplied as `null`.
5. Use `Expanded_Spatial_Fold_Results.csv`, `Expanded_Model_Comparison.csv` and `Expanded_Data_QA.json` to reproduce every reported count and score.
