# SiteWise — Two-stage PU and F&B Business Category Research Model

**Version:** `fnb_category_pu_v1_20261115`  
**Status:** Research-only; **NOT production-ready** or a validated forecast of the most commercially successful business category.  
**Source 1:** `SiteWise_PU_1796_With_Known_Business_Types.xlsx` (observed business-category labels).  
**Source 2:** `SiteWise_PU_1796_Expanded_Observed.csv` (matched, versioned 64-feature research matrix).  
**Stage 1 artifact:** prior `SiteWise_PU_64_Logistic_expanded_age_residential_64_ResearchOnly.joblib`.

## 1. Research objective and critical distinction

SiteWise seeks to identify commercial properties whose surroundings resemble currently operating F&B locations and to explore which *observed F&B outlet category* best matches the area's characteristics. There are two separate tasks:

1. **General P/U association:** an existing 64-feature bagged logistic model compares documented operating F&B outlets (**P**) with **U** (unlabelled commercial properties). Its scalar output is uncalibrated and is *not* a likelihood of business success.
2. **Conditional category resemblance:** a newly trained four-class classifier learns the observed category of P outlets only. For a U location, its outputs compare environmental resemblance to those four groups. It does *not* learn which category would be profitable or successful at a U property, because no such ground-truth outcomes exist in these files.

**Do not describe the output as a tested “best business to open” recommendation.** Use "exploratory match to observed F&B categories" or "potential category to investigate" until independent business-outcome and external-location validation is available.

## 2. Training dataset and labels

The source workbook has **1,796 unique `subject_id` records** and its join with the expanded CSV is exact on 1,796 IDs, matching coordinates and P/U labels. The supplied sample has:

| Class | Number | Category labels |
|---|---:|---|
| P | 880 | Observed operating F&B category |
| U | 916 | Unknown, **never assigned a training category label** |

Known P categories: Restaurant **327**, Café/Coffee **253**, Bakery/Dessert/Beverage **183**, Fast Food/Takeaway **117**. U records are not treated as known negative examples in the category classifier.

The category-labelled Excel supplies **47 original numeric location features**, the P/U label and `business_type`. The expanded matched CSV supplies the same records plus **12 age counts and 8 residential-density/coverage features**. An existing 64-feature model had excluded three LandScan fields due unresolved licensing provenance. It is *not correct* to claim that the category-labelled Excel by itself contains 64 features.

## 3. Models and features

**PU stage:** Five previously fitted bagged logistic pipelines; 64 columns in the exact `metadata.pu_feature_names` order. The general P-vs-U score is the mean `predict_proba(X)[:, 1]` across bags. This stage is reused, not newly retrained here; its prior cross-validation research summary reported an approximately 0.700 P-vs-U ROC-AUC, which is not a business-success accuracy.

**Category stage:** Separate `HistGradientBoostingClassifier` with a median-imputation pipeline on **54 features**, trained using the **880 known P rows**. These 54 features retain the new age and residential measurements. Ten category/generic F&B competitor-count columns have been **excluded** from category training because a P outlet might appear in its own competitor inventory; self-inclusion has not been independently verified or consistently excluded. These counts remain available as *separate local context* only, never as learned category evidence.

Comparator models: majority-category prior, 34-feature logistic baseline, 54-feature logistic model and 54-feature histogram gradient boosting.

## 4. Spatial validation and model selection

Four held-out 0.12-degree geographic-grid splits were used for model comparison. A four-fold **leave-one-state-out** analysis was also performed across Johor, W.P. Kuala Lumpur, Pulau Pinang and Selangor to test geographic transfer. Nearby locations are deliberately grouped and are not independently randomised into training/test folds.

| Category model | Geographic-block macro F1 | Geographic-block balanced accuracy | Leave-state-out macro F1 | Leave-state-out balanced accuracy |
|---|---:|---:|---:|---:|
| Majority-category baseline | 0.144 | 0.250 | 0.135 | 0.250 |
| 34-feature Logistic Regression | 0.233 | 0.281 | 0.261 | 0.290 |
| 54-feature Logistic Regression | 0.242 | 0.277 | 0.254 | 0.299 |
| **54-feature Histogram Gradient Boosting** | **0.274** | **0.279** | **0.272** | **0.296** |

The 54-feature gradient booster was selected on geographic-block macro-F1, then refitted to all **880 P** rows. **These performance numbers are poor and indicate weak category-discrimination ability.** In particular, balanced accuracy of **27.9%** is only modestly above **25%** chance-level balanced accuracy for four categories. This is not production evidence of which category is suitable to open.

Because the same grouped folds informed model selection, their scores are *model-selection estimates*, not an unbiased independent external test. Independent, prospective and geographically diverse holdouts are still required.

Additional leave-state-out pooled per-class F1: Restaurant approximately **0.47**; Café/Coffee **0.26**; Bakery/Dessert/Beverage **0.27**; Fast Food/Takeaway **0.14**. Rare categories, especially Fast Food, are not learned reliably.

## 5. Model output for a real U property — `MD-00510`

The standalone inference script reloaded the saved two-stage `.joblib` and computed:

| Research measurement | Value |
|---|---:|
| General P/U research association (64-feature model) | 0.588861 |
| Restaurant conditional category resemblance | 0.636622 |
| Café/Coffee conditional category resemblance | 0.270824 |
| Bakery/Dessert/Beverage conditional category resemblance | 0.070810 |
| Fast Food/Takeaway conditional category resemblance | 0.021745 |

**Interpretation:** The experimental classifier identifies Restaurant as the category most similar to known operating locations for the given features. **This is *not* a 63.7% chance that opening a restaurant will succeed**; it is a model's conditional output among the four known P business labels. The weak category validation limits its reliability.

A separate source-data check shows the 1 km local F&B competition counts in the source matrix, but these counts were *not used to train the category model*.

## 6. Explainability

`explain_category_shap.py` computes **real permutation SHAP** with 32 complete, observed P-outlet background records (8 from each category). The function explained is the saved 54-feature category model's `predict_proba` for each category. On MD-00510, Restaurant's conditional model score **0.636622** was reconstructed from its SHAP baseline **0.300863** plus contributions, with reconstruction error approximately **2.22 × 10^-16**. The category SHAP contributions do **not** explain the stage-one 64-feature PU score. To explain that score, a *separate 64-feature PU-specific SHAP analysis* is required.

SHAP values capture predictive associations in the fitted model, not causal effects or outcomes.

## 7. Training/reproduction

**Inputs:** (a) the latest category-labelled workbook, (b) expanded source CSV, (c) prior trusted 64-feature PU artifact.

```bash
python train_category_pu.py \
  --input-xlsx SiteWise_PU_1796_With_Known_Business_Types.xlsx \
  --expanded-csv SiteWise_PU_1796_Expanded_Observed.csv \
  --pu-model SiteWise_PU_64_Logistic_expanded_age_residential_64_ResearchOnly.joblib \
  --out ./retrained_category
```

For research inference:

```bash
python predict_category_pu.py \
  --model SiteWise_Two_Stage_PU_FNB_Category_ResearchOnly.joblib \
  --csv SiteWise_PU_1796_Expanded_Observed.csv \
  --subject-id MD-00510
```

For conditional category SHAP (not PU SHAP):

```bash
python explain_category_shap.py \
  --model SiteWise_Two_Stage_PU_FNB_Category_ResearchOnly.joblib \
  --background SHAP_Observed_Category_Background_54.csv \
  --csv SiteWise_PU_1796_Expanded_Observed.csv \
  --subject-id MD-00510
```

**Dependencies:** Python, `numpy`, `scikit-learn` (training run with 1.8.0), `joblib`, `artifact_tool` (to read the Excel) and `shap` (optional for explanations). Load `.joblib` only from trusted local sources.

`SiteWise_Two_Stage_PU_FNB_Category_ResearchOnly.joblib` includes the existing PU ensembles and the new conditional category model; `SiteWise_FNB_Category_Conditional_ResearchOnly.joblib` stores only the category model. The user-provided historical `PU_model.joblib` must not be overwritten.

For *new* rental properties, the backend must resolve the **exact 64 input features** (including age, residential coverage, and source validation), handle missing fields per saved preprocessing, run both stages consistently, version/cache results, and preserve U's original unknown category in the database. Do not use research predictions to populate ground-truth training labels.

## 8. Limitations and future research needed

1. **No category-specific economic outcomes.** Operating examples do not establish which category would be successful at a different location.
2. **Only four regions.** Model validation has limited geographic coverage; future results may differ elsewhere.
3. **Weak category identification.** Results are near chance on balanced accuracy, particularly for Fast Food.
4. **Observed-label verification.** Some positive outlet/categorical records lack independent validation.
5. **Demographic data coverage.** Several age-population areas have partial or low raster coverage; additional data cleaning and source verification are needed.
6. **Missing practical property constraints.** Commercial size, tenancy restrictions, drainage, exhaust/ventilation, building use permissions and actual rents would materially affect opening decisions.
7. **Licensing.** Three LandScan features were omitted from new experiments due unresolved provenance/license status. Other data licences should also be checked before distribution or deployment.
8. **Self-count leakage.** F&B competitor counts were excluded from category training until subject-self-exclusion is verified.
9. **No independent calibrated suitability scores.** Conditional category scores are not probabilities of success, expected revenue or a validated viability index.
10. **External validation.** Train/test strategy must be strengthened with independent unseen areas and independently checked business types and outcomes before any live category suitability claim.

**Suggested report wording:** "The proposed two-stage research system first estimates general positive-label association using a Positive–Unlabelled model. A distinct supervised model then attempts to classify the observed F&B business category based on geospatial and demographic attributes. Across geographically held-out evaluations, category classification demonstrated only limited discrimination. Consequently, category rankings are presented as exploratory evidence and cannot be interpreted as business success probabilities or validated recommendations of the most suitable business type."
