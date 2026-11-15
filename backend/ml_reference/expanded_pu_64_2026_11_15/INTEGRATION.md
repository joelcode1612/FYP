# SiteWise Integration — Expanded 64-Feature PU Model (2026-11-15)

Integration record for the two supplied retraining packages. The original
reports, scripts, datasets and artifacts in this directory and in
`../retrained_pu_1796_2026_11_15/` are preserved byte-for-byte; this file only
documents how the repository consumes them.

## 1. Package locations

| Package | Repository path |
|---|---|
| `SiteWise_PU_1796_Retrained_Models_SQL_Report.zip` | `backend/ml_reference/retrained_pu_1796_2026_11_15/` |
| `SiteWise_PU_64_Features_Expanded_Training_Package.zip` | `backend/ml_reference/expanded_pu_64_2026_11_15/` |

Both were extracted exactly as supplied (18 + 16 files). No `__pycache__`,
logs or duplicates were added; the only generated files are the two
integration reference CSVs described in §5 and this document.

## 2. Model versions and artifacts

| Variant | Artifact (package) | Integrated name | Algorithm | Features |
|---|---|---|---|---|
| Original production (default, untouched) | `backend/src/sitewise/ml/PU_model.joblib` | `pu_model` | bagged logistic, baseline_47 | 47 |
| Experimental 47 (prior package, untouched) | `backend/src/sitewise/ml/sitewise_pu_47_experimental.joblib` | `sitewise_pu_47_experimental` | bagged HistGradientBoosting | 47 |
| **Expanded 64 (integrated now)** | `SiteWise_PU_64_Logistic_expanded_age_residential_64_ResearchOnly.joblib` | `backend/src/sitewise/ml/sitewise_pu_64_expanded.joblib` (sha256 `0371f4e4…3541676f`, identical to the package file) | 5-bag LogisticRegression (median imputer + missingness indicators, standardiser, C=0.5, balanced) | **64** |
| Comparators (preserved, not integrated) | `SiteWise_PU_44_baseline_44_ResearchOnly.joblib`, `SiteWise_PU_52_Logistic_baseline_plus_residential_52_ResearchOnly.joblib`, `SiteWise_PU_64_expanded_age_residential_64_ResearchOnly.joblib` (HGB) | — | HGB / logistic comparators | 44/52/64 |
| Prior retraining package (preserved) | `SiteWise_PU_44_Features_recommended_research_ResearchOnly.joblib`, `SiteWise_PU_47_Features_full47_restricted_ResearchOnly.joblib` | — | — | 44/47 |

`PU_model.joblib` was NOT overwritten and remains the deployed default.

## 3. Training data

* 1,849 original research subjects (894 P + 955 U) in the recovery workbook.
* 53 subjects excluded for an incomplete original feature (the package's
  `SiteWise_PU_53_Excluded_Incomplete_Records.csv`); the package's cleanup SQL
  (`SiteWise_PostgreSQL_Safe_PU_53_Training_Copy_Delete.sql`) applies to a
  separate research training copy ONLY and was **not** run against
  `fyp.rental_properties`, `sitewise_analytics.subject_features`, the live
  catalogues or any production table. The 53 records remain normal SiteWise
  catalogue properties; exclusion affects training membership only.
* 1,796 complete-case training records: **880 P + 916 U**.

## 4. The 64-feature input definition

44 baseline features (the original 47 minus the three LandScan ambient
population fields, excluded for licence-provenance reasons) **plus**:

* 12 WorldPop Malaysia 2025 population-age counts — `pop_age_{0_14,15_24,25_34,35_49,50_64,65_plus}_{500m,1km}`;
* 8 OSM residential measurements — `residential_building_count_{500m,1000m}`,
  `residential_building_density_{500m,1000m}_km2`,
  `residential_footprint_coverage_{500m,1000m}_pct`,
  `residential_landuse_coverage_{500m,1000m}_pct`.

The exact order is read from the artifact itself
(`model_info["feature_names"]`); the loader never assumes an order.

## 5. Live feature resolution — verified data-source findings (2026-11-15)

Read-only audit of this deployment's analytics database:

* The `pop_age_*` columns of `fyp_features.property_population_spatial` are
  **completely unpopulated** (0 of 6,410 rows) and
  `local_age_raster_status = 'SOURCE_NOT_AVAILABLE'`.
* The residential columns the DB does hold were produced by a **different
  measurement method** than the model's training values and disagree on every
  sampled subject (e.g. MD-00510: DB 323 vs training 340.0; MD-04816: 468 vs
  241.0). Four of the six DB age bands use different definitions
  (`35_54`/`55_64`/`65plus` vs the model's `35_49`/`50_64`/`65_plus`).
  None are equivalent, so **none are mapped** — substituting them would score
  the model on values it never learned from.

Consequently the 16 new features are served only from the committed training
bridge `backend/ml_reference/training_expanded_bridge_1796.csv`
(sha256 `d27caf7988f9e31c564d9a394ad7759cebd8225ec18cb9ce8d15c83d6375de26`),
generated reproducibly by `backend/scripts/ml/build_expanded_reference_data.py`
from this package's own observed-only dataset and keyed by `subject_id` +
`canonical_property_id` like the existing 47-feature bridge. This is in-sample
research use of the artifact's own training inputs — the same policy as the
47-feature bridge. The base bridge
(`training_population_bridge_1849.csv`) continues to supply `pop_2000m` and
`worldpop_walk_reachable_10min`.

Practical consequence: only the 1,796 research subjects with a complete
expanded-bridge record can score. **Every newly submitted commercial listing
reports the exact missing fields and is excluded** — never imputed from other
properties, never zero-filled, never substituted with district values.

## 6. Integration architecture

* **Versioned selection** — `SITEWISE_PU_MODEL_VARIANT=expanded64` (values:
  `legacy` default | `experimental47` | `expanded64`; validated in
  `sitewise/core/config.py`). The expanded model stays opt-in until the
  data-quality and integration checks below are reviewed by the team.
* **Loader adapter** — the artifact is a plain dict (`model_info` +
  `estimators`), not a pickled wrapper, so `ModelLoader` detects the bagged
  structure and builds `PUExpandedEnsemble` (`ml/pu_model_compat.py`) around
  the saved pipelines. Prediction = the training package's own recipe
  (`predict_expanded_pu.py`): mean of the five members' positive-class
  probabilities. Parity is bit-exact with the package's vectorised recipe and
  within one ULP of its scalar loop (enforced by `tests/test_pu_expanded_model.py`).
* **Imputation policy** — the saved median imputer with missingness indicators
  may receive NaN **only** for `residential_*` features. The rule is enforced
  structurally inside the ensemble (`_prepare` refuses NaN in any other
  column) and again in the scoring helpers (`expanded_policy_split`), so a
  missing population/accessibility/competition value can never be imputed.
* **Live scoring** — `ml/pu_expanded.py` provides `expanded_prediction` (one
  property) and `expanded_scores_many` (batched resolution for a whole
  ranking: one query per source table), with per-(model-version, property)
  caching. Scores carry version, feature coverage (available/missing per
  feature, imputed list, data-quality flags incl. WorldPop age coverage
  status and source year), `research_only: true` and
  `production_ready: false`.
* **Recommendations** — under `expanded64` the ranking gates on LIVE scores
  (strictly > 50 on the 0–100 scale, threshold unchanged after reviewing the
  model's own score distribution: min 0.005, median 0.478, max 0.99999,
  47.7% of training rows pass — comparable to the legacy stored-score scale).
  Properties whose vector does not resolve are excluded and reported.
  Stored legacy scores are neither used nor displayed in an expanded ranking;
  every candidate in one ranking uses one model version; ranking order,
  requirement-fit logic and weighting are unchanged (PU remains the
  eligibility gate + tie-break). The cache and cursor fingerprints include
  the artifact digest, so replacing the artifact invalidates pages.
* **SHAP** — `shap_background_64.csv`
  (sha256 `04013d63a8da64cb8b7b8e9f5b42cd50dc8c7cb4835641326fa5add3acb13b06`):
  100 deterministic, class-stratified rows (50 P + 50 U) drawn with seed
  20261115 from the 1,758 complete-case training observations. The 47-feature
  background is never used for the expanded model, and vice versa. Permutation
  SHAP runs over the same artifact that produced the displayed score;
  additivity (`base + Σ contributions == output`) and score identity are
  checked before display, exactly as for the legacy variant. When residential
  values were imputed for the score, SHAP is withheld with an explicit reason
  rather than explained against partially measured data.
* **UI** — the property-detail page gains the "Housing Around" category (the
  six categories, with the 47-feature baseline honestly showing it empty);
  all 20 new features have plain-English labels and units ("people",
  "buildings", "buildings/km²", "%"). The recommendations page labels the
  expanded provenance ("Live PU research association · <version>") and states
  on each card that the score was computed live by the expanded model while
  the stored research index belongs to a different model.

## 7. Validation methodology and results (research discrimination only)

Three spatial holdouts (0.07° grid-cell `GroupShuffleSplit`, identical splits
across variants, seed 20261115; preprocessor fitted inside each training fold;
U records never treated as confirmed negatives):

| Feature set | Algorithm | Mean ROC-AUC P-vs-U |
|---|---|---:|
| 44 baseline | Logistic | 0.646985 |
| 44 baseline | HGB | 0.662849 |
| 56 (+age) | Logistic | 0.653943 |
| 56 (+age) | HGB | 0.663486 |
| 52 (+residential) | Logistic | 0.698340 |
| 52 (+residential) | HGB | 0.677052 |
| **64 (+age +residential)** | **Logistic** | **0.699824** |
| 64 (+age +residential) | HGB | 0.685416 |

The expanded Logistic model is the best exploratory candidate (mean ROC-AUC
≈ 0.700). **This is P-vs-U discrimination on a research proxy task — it is NOT
business-success prediction accuracy and must never be quoted as one.** The
age variables add only +0.001484 AUC over the 52-feature residential model;
the apparent gain is driven mostly by residential measurements, and
differences across three holdouts carry limited statistical confidence.

## 8. Known limitations (preserved from the methodology reports)

* Missing residential measurements: 232 absent values across 38 subjects
  (34 U, 4 P); retained as missing inside training, handled by the saved
  imputer; never zero-filled.
* Population-age source limitations: WorldPop 2025 raster summaries (not
  censused counts); coverage 1,067 COMPLETED / 590 PARTIAL_COVERAGE /
  139 LOW_COVERAGE. The status travels with every response as a flag.
* Positive-label verification limitations: operating F&B outlets are not
  verified profitable businesses; competitor self-matching concerns remain.
* The U set is unlabelled, not negative; P-vs-U ROC-AUC measures proxy
  discrimination only.
* Licensing: LandScan was excluded from the recommended models due to
  unresolved provenance; WorldPop/OSM licence and model-use conditions must be
  verified before any use beyond research.
* The score is an **uncalibrated research association index** — how similar a
  location's measured characteristics are to operating F&B sites — never a
  probability of commercial success, and never a Café/Restaurant/Bakery
  category prediction. Category-specific advice requires a separate validated
  model.

## 9. Verification performed (2026-11-15)

* Artifact loading: order/labels/count from the artifact; sha256 identity with
  the package file; legacy 47 and experimental 47 artifacts still load.
* Inference: ensemble == package recipe (bit-exact vectorised, ≤1 ULP scalar);
  live end-to-end scoring for MD-00510 (0.771730) with 64/64 coverage;
  owner-submitted listings fail closed with the exact reason.
* SHAP: genuine permutation SHAP over the 64-feature background;
  additivity OK; output == displayed score; all 64 features categorised.
* Recommendation: legacy path unchanged (290 eligible, stored provenance,
  5/5 PU-gate tests); expanded64 path (351 eligible, live provenance, zero
  stored-score leakage, cursor/cache keyed by artifact digest).
* `tests/test_pu_expanded_model.py` (11 tests), `tests/test_property_insights_service.py`
  (20), `tests/test_ml.py`, `tests/api/test_recommendation_search_pu_gate.py` (5),
  `tests/test_architecture.py` — 50 passing; `dart analyze` clean for
  `shared_logic` and `fyp_jaspr_web` (one pre-existing unrelated warning).
