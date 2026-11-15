# Integration note — retrained category-aware model (2026-11-15)

This directory is the provenance package for the artifact the backend now
serves. Nothing here is imported at request time except the two SHAP
backgrounds; the model itself is copied to
`backend/src/sitewise/ml/sitewise_fnb_category_v2.joblib`.

## What is active

| Stage | Artifact | Contract | Served by |
|---|---|---|---|
| A — general PU | `sitewise_pu_64_expanded.joblib` (byte-identical to the package's `SiteWise_PU_64_Logistic_…_64_ResearchOnly.joblib`, md5 `2c951461…`) | 64 features | `sitewise.ml.pu_expanded` |
| B — F&B category | `sitewise_fnb_category_v2.joblib` (md5 `9459b034…`, sha256 `6a9f931d…`) | 54 features | `sitewise.ml.category_aware` |

Version string: `category_recommender_v2_20261115`. `research_only: true`,
`production_ready: false`.

The previous research artifact `sitewise_fnb_category.joblib`
(`fnb_category_pu_v1_20261115`) and the original `PU_model.joblib` (47
features) are untouched and remain loadable by name.

## Code map

| File | Role |
|---|---|
| `backend/src/sitewise/ml/category_aware.py` | Artifact contract: one load per worker, 54/64 validation, dual permutation SHAP, 1e-5 additivity, background loaders, startup warm-up |
| `backend/src/sitewise/ml/fnb_category.py` | Catalogue orchestration: feature resolution, missing-value policy, batch scoring, response payload |
| `backend/src/sitewise/services/property_insights_service.py` | Property Details read model: PU score + PU SHAP, category block for the **selected** type, cache identity |
| `backend/src/sitewise/services/recommendation_search_service.py` | Ranking: requirement fit → selected-category association → PU → headroom → id |
| `backend/src/sitewise/api/v1/catalog.py` | `GET /properties/{id}/insights?business_type=…` |
| `backend/scripts/ml/verify_category_aware_integration.py` | The 15 focused checks, against live records |

## Deliberate decisions

1. **Selected category, never the model's favourite.** `explain_category`
   takes the class index of the entrepreneur's choice. A Café selection
   explains Café even where Restaurant scores 0.58 vs Café 0.30.
2. **Preference fit stays primary.** The category term is the third sort key,
   after matched/unmet requirement counts. No undocumented weight is applied
   to either model output; with no selection the ordering is byte-identical to
   the previous requirement-fit order.
3. **`expanded64` is now the default PU variant.** The brief forbids mixing
   47-feature stored scores with 64-feature scores in one ranking, and Stage 2
   is defined over the same vector. Coverage on the live catalogue: 896/955
   resolve, 351 pass the unchanged strict `> 50` gate.
4. **Cache identity = model version + artifact checksum + resolved feature
   digest + selected category.** The feature digest is why the cache lookup
   moved *after* feature resolution.
5. **The shared Dart DTO is not broken.** `CategoryEvidence.reliability`
   remains a status string for the mobile client; the richer evidence is added
   as `reliability_detail`.

## Measured behaviour (local, 2026-11-15)

| Path | Cold | Warm |
|---|---|---|
| Property insights, first property | 0.6–2.1 s | 0.05 s |
| SHAP additivity error | 2.2e-16 | — |
| Recommendations, 351 eligible rows | ~19 s (unchanged 955-row resolution) | ~1.5 s |

`import shap` costs ~10 s and the first explainer call compiles ~5 s of numba
kernels. `sitewise.main` starts a daemon warm-up thread so no user request pays
that; without the warm-up the first explanation in a worker takes ~15–27 s.

## Known limitations

- Category discrimination is weak: geographic macro-F1 **0.289**, balanced
  accuracy **0.292** against 0.25 chance. UI wording must stay
  "how well this location matches your selected business type".
- 59 of 955 catalogue properties cannot resolve a complete 64-feature vector
  and report an explicit unavailable state.
- The 916-property prediction CSV in this package is evidence only. It is not
  read at runtime; identity and version were not revalidated against the live
  catalogue.
- The three-year operating-history claim is user-attested; the workbook
  contains no opening dates, so it was not independently verified.
