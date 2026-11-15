# SiteWise — Two-Stage PU + F&B Category Integration and Methodology Update

**Integration date:** 2026-11-15 · **Branch:** `joel` (no commit)
**Category model version:** `fnb_category_pu_v1_20261115`
**PU model version (unchanged):** `expanded_age_residential_64` (64-feature bagged logistic)
**Fallback PU model (unchanged):** `baseline_47` (`PU_model.joblib`)

This document records what was imported, what was verified, what was
reproduced, and what the results do and do not support. The supplied
`MODEL_CARD_AND_FYP_REPORT.md` remains the authoritative model card and is
preserved byte-for-byte.

## 1. Dataset origin and collection

The research sample is the SiteWise commercial-property dataset assembled from
DOSM/OSM/WorldPop/Overture geospatial sources plus a curated F&B outlet
inventory (`Sitewise_FNB_Geospatial_Competitor_Analysis.xlsx /
Competitor_Master`). It is a **research sample of observed locations**, not a
random sample of all Malaysian premises and not a longitudinal business
register.

## 2. Verified three-year operating-history criterion

* **P** = verified F&B business with **at least three years of continuous
  operation**.
* **U** = unlabelled commercial property without a confirmed F&B outcome —
  never a confirmed failure.

The eligibility basis is the data owner's confirmation (2026-11-15), recorded
in `P_LABEL_ELIGIBILITY_2026_11_15.md`. **No per-record opening dates,
durations, statuses or evidence references were supplied** in any package or
present in the analytics database (audited: `fnb_a` holds operating status and
evidence timestamps but no opening date). No dates were invented. A row-level
eligibility file remains outstanding and should replace the whole-set
confirmation when available.

Operating duration is used for **label eligibility only** and is never an input
feature.

## 3. Positive–Unlabelled construction

* Original recovery workbook: **1,849** subjects (894 P + 955 U).
* **53** excluded for an incomplete original model feature — training
  membership only; those records remain normal SiteWise catalogue properties.
* Complete-case research set: **1,796 = 880 P + 916 U**, unique `subject_id`,
  exact coordinate and label agreement between the category workbook and the
  64-feature matrix (asserted in code, `train_category_pu.py` /
  `retrain_fnb_category.py`).

## 4. Final counts and category distribution

| Class | n | Category labels |
|---|---:|---|
| P | 880 | Restaurant 327 · Café/Coffee 253 · Bakery/Dessert/Beverage 183 · Fast Food/Takeaway 117 |
| U | 916 | none — unlabelled |

`business_type_status`: 880 `KNOWN_FNB_CATEGORY`, 916 `UNKNOWN_UNLABELLED`.
U rows never receive a category label and are never treated as negatives.

## 5. Missing-data handling

* Category model: `SimpleImputer(strategy="median")` inside the saved
  pipeline; only **residential** measurements may be missing at inference
  (the artifact's own contract). Any other gap refuses to score and names the
  field.
* PU model: median imputer with missingness indicators, same residential-only
  policy.
* Missing values are never replaced with zero unless zero is a real
  measurement; no previously generated statistical estimate is used as an
  observation.

## 6. Additional population-age and residential features

12 WorldPop Malaysia 2025 age-group counts (500 m / 1 km) and 8 OSM residential
building/landuse measures extend the 44-feature baseline. Their live database
coverage is absent/mismatched (documented in the 64-feature integration record);
research subjects resolve them from the committed training bridge.

## 7. General PU model — training and selection (unchanged)

The 64-feature bagged logistic model was **not retrained**: the verified
three-year criterion was already satisfied by the same 880 P records, and the
supplied 64-feature artifact is **byte-identical** (sha256 `0371f4e4…`) to the
integrated one. Training population, labels and features are unchanged, so a
retrain would reproduce the same artifact.

Spatial validation (3 × 0.07° grouped holdouts): mean ROC-AUC **0.699824**;
comparators 44-feature logistic 0.646985, 52-feature residential 0.698340.
This is P-vs-U discrimination on a research proxy task — **not** a
business-success probability.

## 8. F&B category model — training and selection

* Four canonical classes; **880 P rows only** (U unlabelled).
* **54 features** = the 64-feature PU contract minus the ten F&B competitor
  count columns (`fnb_competitors_*`, `cafe_count_*`, `restaurant_count_*`,
  `fast_food_count_*`, `bakery_dessert_beverage_count_*`) because a known P
  outlet may appear in its own competitor inventory — self-inclusion has not
  been independently verified. Those counts remain available as **context
  only**, never as model input.
* Candidates: majority prior, 34-feature logistic, 54-feature logistic,
  54-feature HistGradientBoosting (`max_iter=110`, `max_leaf_nodes=9`,
  `l2=5`, `lr=0.06`, seed 20261115).
* Selection: macro-F1 on the geographic-block folds. The HistGradientBoosting
  model was selected, then refitted on all 880 P rows.

**Reproduction:** `backend/scripts/ml/retrain_fnb_category.py` re-runs the
supplied pipeline with the installed scikit-learn 1.8.0 and reproduces every
reported metric to six decimal places (macro-F1 0.273801, balanced accuracy
0.279401, top-2 0.616766), selects the same model and finds the same 28
duplicate P coordinates. The artifact is therefore validated and reproducible.

## 9. Spatial validation methodology

* **Geographic blocks:** four `GroupShuffleSplit` folds (75/25) over 0.12°
  grid cells, so neighbouring locations are never split across train/test.
* **Leave-one-state-out:** four folds across Johor, W.P. Kuala Lumpur, Pulau
  Pinang and Selangor to test transfer to unseen regions.
* The same folds are used for every candidate; because those folds also drove
  model selection, the scores are model-selection estimates, not an unbiased
  external test.

## 10. Performance comparison (actual results)

| Model | Features | Geographic macro-F1 | Geographic balanced acc. | LOSO macro-F1 | LOSO balanced acc. |
|---|---:|---:|---:|---:|---:|
| Majority prior | 34 | 0.144 | 0.250 | 0.135 | 0.250 |
| Logistic | 34 | 0.233 | 0.281 | 0.261 | 0.290 |
| Logistic | 54 | 0.242 | 0.277 | 0.254 | 0.299 |
| **HistGradientBoosting** | **54** | **0.274** | **0.279** | **0.272** | **0.296** |

Balanced accuracy of 27.9% against 25% chance is **weak discrimination**;
per-category F1 (LOSO pooled): Restaurant ≈ 0.47, Café 0.26, Bakery 0.27,
Fast Food 0.14. The model is therefore integrated as **research-only /
exploratory**, and the UI states that limitation wherever the scores appear.

## 11. SHAP explainability

* **PU:** permutation SHAP over the exact 64-feature artifact, 100-row real
  training background (`shap_background_64.csv`), additivity and score-identity
  checks before display.
* **Category:** permutation SHAP over the saved 54-feature pipeline's
  `predict_proba`, 32 real P-outlet background rows
  (`SHAP_Observed_Category_Background_54.csv`, 8 per category), reconstruction
  tolerance 2e-3. On MD-00510 the Restaurant probability 0.636622 reconstructs
  from baseline 0.300863 with error ≈ 1.1e-16.
* Category explanations never describe the PU score and vice versa; each
  response carries its model version and artifact identity.

## 12. Recommendation integration (four stages, kept separate)

1. **General F&B association** — the selected PU model (expanded64 live
   inference under the research variant; stored baseline score under the
   default variant). Eligibility threshold unchanged after review (strictly
   > 50 on the 0–100 scale; 47.7% of the training rows pass).
2. **Category resemblance** — Stage-2 scores attached per card from the SAME
   resolved feature vectors (one matrix inference per ranking), with the
   selected business type's rank/score when one was chosen.
3. **Preference fit** — the existing requirement-fit ordering is untouched:
   no new weights, no blended score, no retrained rule engine.
4. **Explainability** — PU SHAP, category SHAP and preference reasons are
   returned as separate fields and rendered as separate blocks.

Category evidence is computed when the `expanded64` two-stage research variant
is active; the default legacy ranking is byte-identical to before (290
eligible rows, stored provenance) and reports category evidence as
unavailable with a reason rather than paying a feature-resolution cost it
never had.

## 13. Interface wording rules

* "Business types that may fit this location" — never "best business type".
* Scores are shown as a 0–1 **resemblance index**, never a percentage, never
  "suitability", never "probability of success".
* Weak validation is displayed with the ranking, not buried in a tooltip.
* PU association, category resemblance and preference fit are labelled as
  three different things in the API and the UI.

## 14. Research limitations and threats to validity

1. **Survivorship / selection bias.** Every P record is a business that
   survived at least three years. Learning where such businesses operate
   cannot explain why other businesses closed, and the model **cannot estimate
   survival probability** without comparable failed-business outcomes, which
   these data do not contain. Three-year survival is also not proof of
   profitability.
2. **Weak category discrimination.** Balanced accuracy is only modestly above
   chance; Fast Food is poorly learned. Category rankings are exploratory.
3. **No category-specific economic outcomes.** There is no observed
   counterfactual of "category X would succeed at property Y"; the classifier
   only learns resemblance to observed outlets.
4. **Label verification.** Category labels come from a competitor inventory;
   some positive records lack independent verification. U records are
   unlabelled, not negatives.
5. **Feature data drift (new finding, 2026-11-15).** For at least one
   property (MD-00510) four live database features disagree with the model's
   training values (`nearest_transit_walk_m`, `nearest_major_road_m`,
   `road_intersection_density_500m_km2`, `road_length_density_500m_km_km2`; the
   last two appear swapped at the source). Live scores therefore differ from
   the artifact's in-sample outputs (MD-00510 PU 0.7717 live vs 0.5889 on the
   training row). This is documented rather than silently substituted; the
   source mapping should be audited before production use.
6. **Age/residential coverage.** WorldPop age rasters are partial/low coverage
   for some locations (1,067 COMPLETED / 590 PARTIAL / 139 LOW); the 16 new
   measurements are absent from the live database and served from the training
   bridge for research subjects only.
7. **Spatial validation scope.** Four states and three-to-four folds; grouped
   folds mitigate but do not remove spatial autocorrelation. No independent
   prospective test exists.
8. **Licensing/provenance.** LandScan was excluded from the 64-feature model
   due unresolved provenance; WorldPop/OSM/Overture licence terms must be
   verified before distribution or commercial use. `.joblib` artifacts are
   loaded only from trusted local files.
9. **Practical constraints absent.** Rent, tenancy, exhaust/ventilation,
   building-use permissions and fit-out costs are not in the feature contract
   but materially decide real openings.
10. **Model-selection reuse.** The same folds informed selection and reporting;
    a truly independent holdout is still required.

## 15. Integration map (code)

| Concern | Location |
|---|---|
| Category artifact (integrated copy) | `backend/src/sitewise/ml/sitewise_fnb_category.joblib` (sha256 `d75d9d06…`) |
| Category loading | `ModelLoader` branch `category_conditional_2026_11_15` |
| Inference / policy / SHAP | `backend/src/sitewise/ml/fnb_category.py` |
| Batch resolution reuse | `backend/src/sitewise/ml/pu_expanded.py` (`coverage_sink`) |
| Property-detail payload | `backend/src/sitewise/services/property_insights_service.py` (`category_model`) |
| Ranking evidence | `backend/src/sitewise/services/recommendation_search_service.py` (`category`) |
| Reproducible training | `backend/scripts/ml/retrain_fnb_category.py` |
| Web contract + panel | `fyp_jaspr_web/lib/data/property_insights_api.dart`, `components/property_detail/category_fit_panel.dart` |
| Shared ranking entity | `shared_logic/lib/src/domain/entities/recommendation_search.dart` (`CategoryEvidence`) |
