# SiteWise: Positive–Unlabelled Model Retraining and Validation
*Prepared: 15 November 2026 · Research experiment — not production validated*

## Executive summary

The SiteWise study prepared an observed-only training cohort from a recovered geospatial dataset comprising 1,849 unique locations: 894 known F&B outlets (P) and 955 unlabelled commercial-property locations (U). Subjects with any missing value in the original 47-feature contract were excluded, leaving 1,796 complete rows (880 P and 916 U). The excluded 53 subjects accounted for 103 missing feature cells. No statistically estimated missing values were used in retraining. Six experimental model configurations were evaluated using three geographically held-out splits. The selected research candidate is a 44-feature histogram gradient-boosting ensemble excluding three LandScan variables, with mean P-vs-U ROC-AUC 0.662849 (SD 0.073969). Its score represents association with known F&B locations relative to the unlabelled background, not the probability of business success or suitability of a specific F&B category. Both model provenance and positive-label validity require further verification before deployment.

## 1. Research objective and prediction target

The objective is to assess whether geospatial attributes of candidate commercial-property locations resemble those of existing F&B outlets. Because independently verified unsuccessful F&B locations were unavailable, a positive–unlabelled (PU) formulation was used. The observed training target is P (known outlet) versus U (unlabelled property). U does not mean a confirmed unsuitable or unsuccessful location. The resulting scores must not be described as commercial success probabilities. Café/restaurant/bakery rankings and user-preference matching require separate model layers and valid supporting labels.

## 2. Dataset preparation and missing-value handling

The source workbook was SiteWise_PU_1849_Recovery_Verified.xlsx. A unique subject_id was checked for every record, and exactly 47 predetermined feature columns were selected in their original order. A record was retained only when all 47 were finite numeric observations. This removed 53 incomplete subjects—14 P and 39 U—and 103 blank feature cells. The complete-cohort proportion was 1,796/1,849 = 97.13%. No zeros were substituted for unknown values; the separately produced 103-value imputation experiment was not used. The cleaned data were exported as a reproducible CSV and an Excel workbook. Age-group attributes present in the source are supplemental and were not included in this 47-feature experiment. Exclusion can bias the cohort if missingness is spatially or demographically non-random.

## 3. Predictors and source-quality controls

The original 47 candidate predictors cover residential population estimates; office, education, retail and public facility counts; roads, pedestrian and transit accessibility; LandScan ambient population; parking; and nearby F&B competitor counts. Three source-flagged LandScan fields were excluded to construct a 44-feature sensitivity variant. Ten F&B competitor-count columns were further excluded to create a 34-feature sensitivity variant, because the research workbook flags possible self-matching and inventory differences near existing outlets. All full-47 values are preserved for a separately marked restricted experiment, not approved production use. The workbook retains unresolved source-validation and LandScan rights/provenance flags; omitting three LandScan fields does not by itself certify the other sources.

## 4. PU learning procedure

An experimental bagged P-versus-U proxy-classifier workflow was implemented. Within each fitted bag, all available P records were used as observed positives. A random approximately 78% subset of U records was sampled as a temporary comparison background and assigned a proxy zero label for fitting only. The subsets varied across bags. Predictions from fitted classifiers were averaged to create a continuous P-versus-U association score. This approach is not a non-negative PU risk estimator, does not recover a class prior, and does not calibrate the score to the chance of success. Two base learners were compared: standardised logistic regression and histogram gradient boosting. Data preprocessing was fitted only on each training sample.

## 5. Spatially held-out validation and model selection

To reduce overly optimistic results from geographically neighbouring locations, latitude/longitude coordinates were assigned to approximately 0.07-degree grid-cell groups. A GroupShuffleSplit procedure produced three partitions, holding out approximately 23% of grid-cell groups for each comparison. The same split indices were used for all six configurations. Each validation split was excluded from fitting and any imputation/scaling used by its training bags. The holdout sizes were 373, 275 and 436 records, respectively. Reported measures are ROC-AUC, average precision and balanced accuracy for discriminating the P/U observation label. These are not independently measured restaurant-outcome metrics. Configurations were compared by mean held-out ROC-AUC; the selected candidate was restricted to feature sets excluding unresolved LandScan fields.

## 6. Quantitative findings

Table 1 presents the empirical results of three spatial holdouts per configuration. The best unrestricted 47-feature result had mean AUC 0.681201 using gradient boosting, but its feature provenance is flagged and therefore it was not selected as the preferred deployment candidate. Among the non-LandScan experiments, the 44-feature gradient-boosting configuration had the largest mean AUC, 0.662849 (SD 0.073969), average precision 0.623374 and balanced accuracy 0.604679. Variation between geographic folds indicates limited robustness and the need for external testing. The full 47-feature artifact was retained strictly as a licence/provenance-restricted research comparator.

| Feature set | Algorithm | Mean ROC-AUC | SD ROC-AUC | Mean average precision | Mean balanced accuracy |
|---|---|---:|---:|---:|---:|
| full_47_licence_hold | Logistic | 0.646 | 0.033 | 0.620 | 0.607 |
| full_47_licence_hold | HistogramGradientBoosting | 0.681 | 0.081 | 0.642 | 0.626 |
| no_landscan_44 | Logistic | 0.647 | 0.082 | 0.596 | 0.611 |
| no_landscan_44 | HistogramGradientBoosting | 0.663 | 0.074 | 0.623 | 0.605 |
| conservative_34 | Logistic | 0.632 | 0.116 | 0.588 | 0.610 |
| conservative_34 | HistogramGradientBoosting | 0.649 | 0.062 | 0.601 | 0.604 |

## 7. Model artifacts and deployment boundary

The recommended research model is stored as SiteWise_PU_44_Features_recommended_research_ResearchOnly.joblib; the restricted comparator is SiteWise_PU_47_Features_full47_restricted_ResearchOnly.joblib. Each serialized artifact contains metadata plus five fitted sklearn pipelines. They are not drop-in substitutes for SiteWise’s existing PULearning / ModelLoader API. A standalone prediction script is included. The current deployed PU_model.joblib must not be overwritten until feature-order compatibility, rights, model governance, independent validation and integration tests are completed. Never load an untrusted joblib file. These models were not trained to determine which of Café, Restaurant or Bakery is the best category.

## 8. Threats to validity and future work

The largest limitations are the incomplete independent verification of positive labels, possible self-matching of P outlets in competitor counts, uncertain provenance or rights for some raster/ambient-population measurements, missingness-driven selection bias, geographically correlated data sources and the absence of observed financial outcomes. The geographic grids are a preliminary safeguard, not a complete separation of related businesses or shared sources. The 47-feature full model should not be deployed until the specific data rights are reviewed. Before final model approval, the study should independently verify P records, resolve competitor self-matches, audit source years/coverage, test withheld cities or later years, and compare with a business outcome dataset. Any future SHAP explanation should use the exact fitted model and feature set; it must explain P-vs-U association rather than claiming business success or category preference.

## 9. Database handling

To avoid impacting live SiteWise listings, a separate PostgreSQL research table is created from sitewise_analytics.subject_features. A SQL script excludes the exact 53 subject IDs from that new table and verifies the expected counts of 880 P and 916 U, with exceptions triggering transaction rollback. The script does not delete entries in fyp.rental_properties, sitewise_analytics.subject_features, or other operational tables. The model itself was trained directly from the cleaned Excel-derived CSV rather than from this staging table. No database SQL was executed as part of this report.

## 10. Recommended thesis reporting language

“A complete-case analysis was conducted on the 1,849-location SiteWise geospatial dataset comprising known existing F&B outlets (positive class) and unlabelled commercial properties. Fifty-three records with missing values among the predefined 47 predictors were excluded, resulting in 1,796 observations (880 P; 916 U). Positive–unlabelled proxy classifiers were trained using repeated unlabelled-background sampling. A geographically grouped validation strategy evaluated logistic regression and histogram gradient boosting across 47-, 44- and 34-feature configurations. The selected 44-feature gradient-boosting research candidate achieved mean spatial-holdout ROC-AUC of 0.663, with substantial variability across held-out geographic regions. The score expresses relative association with known F&B locations, not a calibrated likelihood of business success. Unresolved source and label-quality issues mean this model is experimental and requires further external validation prior to deployment.”

## References

Elkan, C., & Noto, K. (2008). Learning classifiers from only positive and unlabeled data. Proceedings of KDD ’08, 213–220. https://doi.org/10.1145/1401890.1401920

Bekker, J., & Davis, J. (2020). Learning from positive and unlabeled data: A survey. Machine Learning, 109, 719–760. https://doi.org/10.1007/s10994-020-05877-5

Roberts, D. R., et al. (2017). Cross-validation strategies for data with temporal, spatial, hierarchical, or phylogenetic structure. Ecography, 40, 913–929. https://doi.org/10.1111/ecog.02881

SiteWise research dataset (2026). SiteWise_PU_1849_Recovery_Verified.xlsx [Unpublished source workbook; complete-case audit and source flags].
