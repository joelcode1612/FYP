# SiteWise retrained category-aware recommendation model — research-only

**Run date:** 2026-11-15

## Research objective

Given a commercial location's observed geospatial, demographic, residential-density, public-transport and amenity attributes, estimate its resemblance to the known categories of established F&B businesses. The saved model supports **research ranking by entrepreneur-selected F&B category**, alongside a separately stored general Positive–Unlabelled (PU) association score. **Neither output estimates profitability or the likelihood that a new business will survive for three years.**

## Data and labels

- Input observations: **1,796** unique locations from the complete-case SiteWise training matrix (880 P and 916 U).
- Supervised category target: **880 P outlets**, comprising Restaurant 327; Café / Coffee 253; Bakery / Dessert / Beverage 183; and Fast Food / Takeaway 117.
- **916 U properties** were not assigned training category labels; these are scored only after training.
- The dataset owner stated that the included F&B businesses have been operating for **more than three years**. The delivered label workbook does **not** contain per-outlet opening dates or duration fields; accordingly, the duration criterion was *not independently revalidated* in this experiment. No synthetic dates were inserted.
- No closed-business, survival-failure, financial or entrepreneur-outcome target is available.

## Input features and leakage controls

The model uses **54 features** from the expanded matrix: demographics by age, residential density/coverage, accessibility, population, nearby amenities and transport. Ten F&B competitor-count variables were excluded **from the category classifier** because subject-outlet self-matching could reveal the target. Their exclusion does not prove that all residual spatial or selection leakage is absent. The reused 64-feature general PU ensemble retains its original feature contract and prior source limitations.

The category classifier's imputation is fitted **inside each geographic training fold**, never on the held-out data. Of the 1,796 locations, **38** have some missing residential measurements; **590** age datasets are flagged `PARTIAL_COVERAGE` and **139** flagged `LOW_COVERAGE`.

## Training and validation method

Compared a majority-category dummy baseline, balanced multinomial Logistic Regression, Histogram Gradient Boosting and Extra Trees. Used the same four geographical holdouts based on approximately **0.12° grid groups** for every candidate; separately measured leave-one-state-out transfer across four states. Model selection used mean **macro-F1** on the geographic grid holdouts. Final candidate was retrained on all 880 positive category-labelled records. The saved 64-feature PU ensemble from the prior project experiment is included unchanged.

### Held-out results

| Model | Geographic macro-F1 | Geographic balanced accuracy |
|---|---:|---:|
| Majority-category baseline | 0.144 | 0.250 |
| Logistic Regression, 54 features | 0.242 | 0.277 |
| **HistGradientBoosting, 54 features — selected** | **0.289** | **0.292** |
| Extra Trees, 54 features | 0.261 | 0.291 |

The previous category research package reported geographic macro-F1 **0.274** for its selected gradient-boosting configuration. The new run reached **0.289**, an improvement of about **0.015** macro-F1 under the prior data/split definition. The gain is small and these are development selection folds, **not an independent locked external test set**. A four-class balanced accuracy of 0.292 is only modestly higher than the uniform-chance benchmark of 0.25. The model remains **exploratory** and should not automatically decide which business to open.

## Ranking design

For an entrepreneur who selects **Café**, compute the **Café conditional category-association output** for each eligible U property; sort primarily by that output and use the existing 64-feature general PU association as a tie-breaker. Apply the existing access-control, assignment, budget, size and other preference filters from SiteWise independently. The supplied code does **not** claim that the category classifier is a supervised personalized recommender, as no labelled entrepreneur-choice or financial outcome records were provided.

## Explainable AI

The updated `recommend_and_explain.py` computes **permutation SHAP** against the exact saved category model (54 features) or saved general PU model (64 features). It uses real, finite reference samples from the training dataset, the saved fitted preprocessing steps, and enforces SHAP additivity. The sample `MD-00510` was verified with errors close to floating-point precision for both explanations. SHAP values explain association outputs; they are not causal effects or indicators of guaranteed financial returns.

## Threats to validity

1. **Survivorship bias:** all P observations are established businesses; unsuccessful closures and their locations are absent.
2. **Label provenance:** the claimed 3+ year duration is user-confirmed but opening dates are not present in the supplied workbook.
3. **Source quality:** a substantial minority of age estimates have low or partial population raster coverage; some residential values require in-fold imputation.
4. **Transfer:** validation across states and spatial blocks suggests limited category discrimination; the same dataset was used to compare/select candidate model types.
5. **Unlabelled meaning:** U is not a confirmed negative and must not be coded as failure or non-viability.
6. **General PU reuse:** the 64-feature PU model carries previously documented data-provenance and study-design limitations.

## Validity statement for the FYP report

> A research category-matching classifier was trained on 880 previously established F&B outlets with category labels, alongside 916 unlabelled commercial locations used as inference candidates. Ten potentially leaky F&B competitor-count attributes were excluded from the category classifier. Four spatially separated validation splits produced mean macro-F1 of 0.289 and balanced accuracy of 0.292 for the selected 54-feature gradient-boosting model. This indicates limited ability to distinguish the four observed business categories from geospatial attributes, and the resulting category rankings are used as exploratory location-pattern evidence rather than predicted profitability, survival probability or confirmed best-use suitability. The general 64-feature Positive–Unlabelled association model was retained separately, and permutation SHAP explained the saved artifact's corresponding outputs with additivity checks.

For exact per-fold measurements see `Spatial_Fold_Results.csv` and `Model_Comparison.csv`.
