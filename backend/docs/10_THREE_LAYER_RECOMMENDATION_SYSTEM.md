# 10 — Three-Layer AI Recommendation System (implemented state)

> **Audit update (2026-11-12):** Sections 2, 5 and 13 below were refreshed after a
> reproducible artifact audit at local HEAD `698a1cc94ddb482e621fbc0d2d2e09f4f5121fa7`.
> The original PU training source/package and independent holdout evidence are not
> present in this checkout. See `ml_reference/pu_artifact_verification_2026_11_12.json`
> for raw artifact hashes, actual inference, SHAP reconstruction, exact target inputs,
> and the live read-only property-detail service responses.

Status date: **2026-11-11**, branch `joel`, integration commits
`dfb2243` (pipeline) → `86e3c23` (Layer 1) → `c4cdc01` (persistence) →
`866410c` (Layer 2 + training gate) → `1f1050a` (SHAP ops) → `762c700`
(ID compatibility) → `0e93e1f` (Flutter) → `1307833` (Jaspr).

Everything below is **implemented and verified** unless explicitly marked
*planned*. No metric in this document is invented; measured numbers carry
their measurement context.

---

## 1. Architecture

```
Entrepreneur (Flutter / Jaspr)
        │  authenticated session (Supabase JWT, ownership = token sub)
        ▼
POST /api/v1/recommendations/generate          GET  .../me/generated
GET  .../{result_id}/explanation               GET  /ml/selected/properties/{id}/coverage
        ▼
RecommendationGenerationService (clean architecture, framework-free domain)
   │
   ├─ Layer 1  PU research association score (stored per property)
   ├─ Layer 2  versioned rule-based preference engine  (this doc §4)
   └─ Layer 3  Permutation SHAP over the PU artifact   (this doc §5)
        ▼
PostgreSQL  recommendation_result (durable batches; process-local store only for tests)
```

* **Layer 1** produces an *uncalibrated P-vs-U association index* for each
  research-catalogue property. It is **not** a probability of commercial
  success; the API never presents it as one.
* **Layer 2** scores preference fit from the entrepreneur's saved
  preferences with eight normalised components and combines the two layers.
* **Layer 3** explains the Layer 1 score with SHAP. SHAP never explains a
  Layer 2 rule; the two explanation sections travel separately in every
  explanation response.

## 2. Layer 1 — PU model, feature contract and coverage

The local checkout tracks three executable PU artifacts and one separate V3
calibration snapshot. Their SHA-256 values, Python types, exact feature order,
real target-property predictions and source-value provenance are emitted by
`backend/scripts/ml/verify_pu_artifacts.py` to
`backend/ml_reference/pu_artifact_verification_2026_11_12.json`.

| Artifact | Classification / runtime role | Verified contract |
|---|---|---|
| `PU_model.joblib` | Original legacy PU model; active by default. The recommendation batch reads its stored catalogue output, not a fresh model call on every row. | `BaggedPUClassifier`; 3 fitted logistic pipelines; `baseline_47`; 47 ordered features; predict + predict_proba. SHA-256 `5c00c574cfe4cbcb76fe1fb21eb32e40cfea3a428ef1c70ea60c893c1e8c2f98`. |
| `sitewise_selected_pu_model.joblib` | Separate, loadable Layer-1 alternate; not the personalised recommender. Ranking does not select it, and recommendation SHAP no longer targets it — SHAP explains whichever artifact actually produced the ranked score. | `BaggedPUClassifier`; 3 fitted logistic pipelines; 47 features; model version `sitewise-pu-pvu-1.0`. SHA-256 `07bbf5c50dd04d43e33b45ad0257f7290af396e3709a4bd5165a5ee9919e863d`. |
| `sitewise_pu_47_experimental.joblib` | Experimental research PU artifact; runs live inference only when `SITEWISE_PU_MODEL_VARIANT=experimental47`. It remains `production_ready:false` and its LandScan licence provenance is unresolved. | `PUScoreEnsemble`; 4 fitted HistGradientBoosting bags; exact 47-feature contract; version `hist_gradient_boosting@PU_47_CANDIDATE_2026_11_11`. SHA-256 `1d09cb9a44301d1020bb367a1b3dcb1803935e853c348eccad357f0ede8fd1e2`. |
| `recommender_v3.joblib` | Calibration snapshot only. Never invoked as a predictor. | 948 bytes, SHA-256 `74fe71c37acbeeb4afcab6d0b42387c973487775cd0166ea3d1206eeed70dc43`; no `predict()`/`predict_proba()`. V3 rules call `score_candidate_v3()`. |

**Feature resolution and verified inference.** The production repository resolves
42 named features from the live analytics tables, then
`feature_bridge.merge_bridge_features()` supplies up to five more exact training
inputs by the same canonical property ID. The bridge has 1,849 rows (894 P +
955 U), with `worldpop_walk_reachable_10min` present for 1,794 and explicitly
missing for 55; it never borrows another property's value. The full catalogue
comparison recorded 896/955 experimental live scores (59 unavailable), which is
a different coverage denominator/path than the bridge-row count.

With the checked-in database and bridge, both MD-00510 and MD-01755 resolve 47/47
inputs for all three PU artifacts. For the original model, exact live inference
reproduces `source_data.research_p_association_score`:

| Property | Stored original score | `PU_model.joblib` live score | Absolute difference | Experimental47 live score |
|---|---:|---:|---:|---:|
| MD-00510 | 0.2725532873237277 | 0.27255328732372774 | 5.55e-17 | 0.42026395529537236 |
| MD-01755 | 0.9799711282139384 | 0.9799711282139385 | 1.11e-16 | 0.325063311754101 |

Both stored-vs-original comparisons are within 1e-6. These are training-population
records and therefore in-sample reproduction evidence, not out-of-sample model
validation and not evidence of commercial success. The target vector for MD-00510
also matches `ml_reference/example_property_47.json` exactly. The verifier prints
each input in trained order with its DB or bridge source.

**Recommendation score source:** `RecommendationCandidateRepository._map()` reads
`sitewise_app.properties.source_data.research_p_association_score` and records the
source/method/type. Default `legacy` ranking uses this stored original model output.
`experimental47` instead uses `PULearning.predict_or_report()` on a complete live
47-feature vector; incomplete properties are excluded from that experimental batch.
The two variants are never mixed. All scores are uncalibrated P-vs-U association
indices, not success probabilities.

**Training/provenance limit:** the PU training code and full training package are
not present in this repository. The original artifact was added as a binary in
`ed74378`; no reproducible original fit script, full source dataset, split/fold
assignments, feature-selection procedure, or independent holdout report was found.
The selected-model integration notes say it came from an older canonical
190-column matrix, not the later recovered 231-column matrix. Experimental
metadata reports spatial-CV AUROC 0.76007 / average precision 0.73324 on the
1,849-row research sample, but omits a reproducible fold protocol and independent
holdout. Its referenced supplied research-package README/manifest is not in this
checkout. A LandScan audit also records at least one positive training row with an
empty-set zero from 0% raster coverage; the bridge was not rewritten to correct
that row. Treat reported metrics and input lineage as limited research evidence.

**Experimental restrictions:** `NO_PENDING_LICENCE` is an internal data flag,
not licence proof. The model metadata leaves LandScan provenance unresolved and
sets `production_ready:false`. Only permitted local research testing is claimed;
no licensing gate is bypassed and the experimental result is never described as a
business-success probability.

## 3. Data-quality decisions

* Missing data is **excluded and renormalised** — never zero-filled — in
  both the feature resolver and every Layer 2 component.
* The 955 imported `fyp.rental_properties` rows are
  `verification_status='pending'` and are excluded from the personalised
  pipeline (the research catalogue `sitewise_app.properties` is the
  candidate source); availability is `UNKNOWN_NOT_VERIFIED` and is surfaced
  as a caution, never as confirmed availability.
* All 955 catalogue rows carry a verified identity mapping to their
  commercial listing (`fyp.property_subject_links.match_verified`),
  exposed as `listing_ref` with an explicit `detail_available` state
  (§7).

## 4. Layer 2 — rule-based preference engine (authoritative)

```
preference = Σ(w_i · component_i) / Σ(w_i)   over components with known values
final      = 0.70 · pu_association + 0.30 · preference
```

| Component | Weight |
|---|---|
| budget_fit | 0.20 |
| size_fit | 0.15 |
| property_type_fit | 0.10 |
| target_market_fit | 0.20 |
| accessibility_fit | 0.10 |
| parking_fit | 0.10 |
| competition_fit | 0.10 |
| physical_fit | 0.05 |

* Config version `sitewise_rule_based_preference_v1`; `validated_optimal:
  false` travels in every response. The weights are a research baseline,
  not fitted parameters.
* Hard eligibility filters run before scoring (rent/size present, PU score
  valid, availability, U-class, analysis completed, verification not
  rejected, budget/size/state/area bounds).
* Ranking is a deterministic total order: final score ↓, preference ↓, PU ↓,
  property id ↑.
* **Reproduced saved-V3 example (read-only service run):** active local test
  profile preference summary = cafe/coffee, dine-in, nearby residents + office
  workers, `high_nearby_population`, standard space. Variant `legacy`; PU is
  the stored score. Effective weights for that Q4 priority were
  `{budget: .15, size: .10, property_type: .05, target_market: .35,
  accessibility: .10, parking: .05, competition: .10, physical: .10}`;
  property_type and competition were unknown and excluded (known weight sum .85).

  | Rank | Property | Ephemeral result ID* | PU | Preference | Final from service | Independently recomputed final |
  |---:|---|---|---:|---:|---:|---:|
  | 1 | MD-01755 | `a25d05aa-1d27-4e91-a93f-3081bfeb5c0a` | .9799711282 | .7268078113 | .904022 | .9040221331 |
  | 2 | MD-01259 | `7cb16528-048a-4b2d-9235-1642354db7b9` | .9139302380 | .7480911512 | .864179 | .8641785120 |
  | 3 | MD-00891 | `51e8b3ed-6e53-44df-812d-30dc5ac3f9c6` | .9118322837 | .7525530988 | .864049 | .8640485282 |

  Formula was recomputed from exact stored PU values and unrounded component
  values: `preference = Σ(effective_weight_i × component_i) / Σ(effective_weight_i)`
  over known components; `final = .70 × PU + .30 × preference`. Each absolute
  difference from the six-decimal API/service value was < 4.9e-7; an independent
  re-score of all 955 eligible rows reproduced the entire returned rank order
  (`full_returned_rank_order_matches: true`, no rows persisted).
  `*` These IDs came from an **in-memory** service call; they are ephemeral, not
  durable `recommendation_result` IDs. Separately, the slow
  `test_shap_reconstruction_through_api_for_reference_property` test exercises
  the actual FastAPI generation + explanation routes with a test-only JWKS token,
  verifies the persisted result ID and same-artifact SHAP contract, and removes
  the fixture user/rows on teardown. It does not use a real Supabase browser
  bearer token or the existing saved-V3 account used for the service replay; that
  authenticated-user scenario remains unverified in this session.
* **Unchanged-input reuse:** `generate` hashes the normalised preference
  profile, request filters and scoring version; when nothing changed the
  stored batch is returned with `reused_existing_batch: true` and no
  catalogue scan or scoring pass runs.

### Trained-recommender decision (honest status)

**No trained `recommender.joblib` exists, and none was fabricated.** The
real label inventory (verified 2026-11-11): 0 preference snapshots,
0 stored recommendations before Phase 5, a handful of favourites with no
exposure pairing, no outcome table. `scripts/ml/train_personalised_
recommender.py` queries the live inventory and **refuses to train**
(exit 2, `ml_reference/recommender_eval/model_selection_report.json`
names the exact missing data). The fully specified future path:
exposure-paired positives (saved-after-exposed) / negatives
(exposed-never-saved), per-user temporal split, NDCG/MAP/Precision/Recall,
PU-vs-preference ablation, artifact written only when held-out NDCG@10
beats the rule baseline.

## 5. Layer 3 — SHAP

* `ShapExplainer.explain()` loads the named PU artifact through the same trusted
  `ModelLoader` and calls that artifact's actual `predict_proba(... )[:, 1]`
  during Permutation SHAP. Each feature row is assembled in that artifact's exact
  47-feature order. The checked-in `ml_reference/shap_background_47.csv` contains
  25 real rows (12 P + 13 U), not synthetic rows.
* **Reconstruction and identity gates:** the response is withheld unless
  `|baseline + Σ contributions − model output| < 1e-6`, and the explained model
  output also matches the score being displayed within 1e-6. SHAP is always
  labelled with the model and version it actually explains.
* Reproduced from the local artifacts and read-only property vectors:
  MD-00510 — baseline `0.6192941851841924`, contribution sum `-0.34674089786046475`,
  output `0.27255328732372774`, additivity error `5.55e-17`; MD-01755 — same
  baseline, contribution sum `0.3606769430297463`, output `0.9799711282139385`,
  error `2.22e-16`. In both cases the explained output equals the live prediction
  exactly (difference `0.0`), over the real 25-row background. The original and
  selected logistic artifacts reproduce those outputs. The exact SHAP values are
  in the verification JSON.
* Property-detail now merges exact-property training-bridge values for the model
  input and keeps a valid PU score visible when SHAP is unavailable. A complete
  feature vector is required for live score calculation and SHAP; missing fields
  still yield an explicit list, never a fabricated score. The experimental47
  score may be computed under its explicit research variant, but SHAP is withheld
  unless a matching licensed background for that artifact is verified. Its model
  card remains production-gated.
* Recommendation-explanation SHAP now loads the exact artifact recorded on each
  ranked result. It does not use the selected alternate to explain a legacy
  score. Cache identity includes model version, artifact checksum, property id
  and stored score. Experimental47 explanations remain withheld until a matching
  licensed background is verified. SHAP explains PU association only; Layer-2
  preference reasons remain separate.
* **Latency is environment/cache dependent.** `ml_reference/recommender_eval/
  shap_latency.json` is rewritten by the operational test on every run; the
  current record is `pu_model`/`baseline_47` (SHA-256 `5c00c574…`) at 0.0733 s
  first / 0.0222 s cached, because the artifact was already warm in that test
  process. The independent audit verifier, starting from a cold process, measured
  18.7 s for the first MD-00510 original-model explanation and then 0.017–0.021 s
  for subsequent calls. These are not comparable measurements; treat a cold first
  explanation as potentially seconds, never as a guaranteed 40 ms. Recommendation-
  SHAP cache keys include model name, version, artifact checksum, property id and
  ranking score; failures are not cached. Ranking itself does not run SHAP.
  Successful recommendation explanations may be attached to the durable result
  on demand.

## 6. Persistence (PostgreSQL)

The process-local store (24 h TTL) remains only for isolated tests. The
production store is the existing `recommendation_result` table, reshaped by
**migration 0008** (alembic file + `scripts/apply_recommendation_persistence_
migration.py`, following this repo's out-of-band apply-script convention):

* `property_id` INTEGER → **TEXT** (the table was empty; the old FK pointed
  at the retired `public.property`). Canonical ids (`EP-01877`) are never
  forced through an integer key.
* Added: `batch_id UUID`, `pu_association_score`/`preference_match_score`
  NUMERIC(8,6), `scoring_version`, `model_name`, `payload JSONB` (the full
  result contract), `shap JSONB`.
* `users` FK recreated **ON DELETE CASCADE** (account deletion removes the
  user's batches; history survives restarts and crosses workers).

Flow: `save_batch` (one transaction) → `latest` (newest batch per user,
rank order) → `get`/`shap_of`/`attach_shap` (ownership-scoped; a foreign
result is indistinguishable from a missing one). Verified restart-survival
and cascade tests live in `tests/api/test_recommendation_persistence.py`.

## 7. Property identity

Recommendation ids are canonical text (`EP-/MD-`); explore/detail navigate
by bigint listing id. Every recommendation payload carries
`property.listing_ref = {listing_id, match_verified, detail_available,
detail_note}` resolved from `fyp.property_subject_links` (955/955 verified;
MD-00510 → listing 316). Because all 955 imported listings are
`verification_status='pending'`, `detail_available` is `false` today and the
explore-detail 404 policy is preserved — clients navigate to the
canonical-keyed assessment/research surfaces instead of following a link
that would 404. Unlinked rows would be `listing_ref: null` (never a guessed
numeric id).

## 8. API surface (implemented)

| Method & path | Purpose |
|---|---|
| `POST /api/v1/recommendations/generate` | rank the eligible catalogue for the authenticated entrepreneur (`{limit, state?, property_ids?}`; identity never from the body) |
| `GET /api/v1/recommendations/me/generated` | the durable latest batch |
| `GET /api/v1/recommendations/{result_id}/explanation` | two separated explanation sections |
| `GET /api/v1/ml/selected/properties/{id}/coverage` | per-feature 47-feature coverage report |
| `GET /api/v1/ml/selected/properties/{id}/prediction` | live inference or explicit unavailable state |
| `GET /api/v1/ml/selected/properties/{id}/explanation` | SHAP or explicit unavailable state |

Legacy routes (`GET /me`, `GET /`, `POST /`, `GET /user/{user_id}`,
`DELETE /{result_id}`, `POST /search`, `GET /facets`) remain operational.

Example generation result (shape, abridged):

```json
{
  "property_id": "MD-00510",
  "model": {"association_score": 0.83, "score_meaning": "Uncalibrated association ..."},
  "personalisation": {
    "preference_match_score": 0.57, "engine": "rule_based",
    "components": {"budget_fit": 1.0, "parking_fit": null},
    "component_status": {"budget_fit": "scored", "parking_fit": "unknown"}
  },
  "final_recommendation": {"score": 0.75, "rank": 1, "basis": "pu_0.70_preference_0.30"},
  "property": {"listing_ref": {"listing_id": 316, "match_verified": true,
                               "detail_available": false, "detail_note": "..."}},
  "explanation": {"preference_reasons": ["..."], "cautions": ["UNKNOWN_NOT_VERIFIED ..."], "shap": null}
}
```

## 9. Client integration

**Flutter** (`0e93e1f`): `EntrepreneurAiRecommendationsMobilePage` +
`personalised_recommendations_providers.dart` + shared_logic entities and
`ApiPersonalisedRecommendationRepository`. Ranked cards show preference fit
and PU index separately, reasons/cautions, the explanation sheet with the
component breakdown and the SHAP section (or its explicit fallback), and
assessment navigation by canonical id. Route
`/entrepreneur/ai-recommendations`; the entry action on the requirement-fit
Recommendations header rides with that screen's concurrently-maintained
rewrite. The five navigation destinations are unchanged.

**Jaspr** (`1307833`): `AiRecommendationsPage` at
`/entrepreneur/ai-recommendations` (`?result=` opens the two-layer
explanation view); `AppLocator.personalisedRecommendations` reuses the same
shared client; the detail link renders only when
`listing_ref.detail_available` is true.

## 10. Verification

* Focused suites run after each phase, all green: Layer-1 coverage (12),
  selected-PU (10), `test_ml` (8), personalised pipeline (22),
  persistence (8), reuse + training gate (3), SHAP operations (2),
  ID compatibility (4).
* Full backend suite (2026-11-11, default pytest temp, 326 collected):
  **316 passed, 7 failed, 3 skipped, 0 errors**.
* The 7 failures are **not attributable to this integration**: all are in
  `tests/api/test_owner_listing_drafts.py` (3) and
  `tests/test_fyp_geospatial_api.py` (4), and their assertion messages are
  the concurrent session's uncommitted postcode/address-validation work
  (`"Complete these fields ... postcode"`, `"Field required: postcode"`,
  `KeyError: 'data'`). Those production files
  (`property_verification.py`, `fyp_property_repository.py`,
  `property_verification_service.py`) remain uncommitted in the other
  session's working tree; none is touched by any commit in this series.
  The prior handoff reported 15 such failures on the active tree; the count
  is 7 at this verification point.
* Sandbox note: pytest's tmpdir garbage cleanup trips the environment's
  bulk-delete guard at teardown and truncates the final stdout summary;
  results above were reconstructible from the progress-dot census and
  cross-checked with `-rf --tb=line` runs. `--basetemp` workarounds add
  setup `PermissionError` errors (an environment artifact, not product
  defects) and are not used for the authoritative count.
* Notable verified behaviours: both artifacts load with independent
  contracts; unknown components excluded-never-zero-filled; deterministic
  ranking; ownership isolation (API + DB); restart survival; user-deletion
  cascade; unchanged-input reuse; changed inputs regenerate; the label inventory
  gate refuses training on the recorded counts and no trained
  `recommender*.joblib` exists; SHAP reconstruction < 1e-6; measured latency recorded.
  The current `train()` function remains a placeholder and is not a complete
  end-to-end Layer-2 training pipeline.
* **Audit verification on 2026-11-12:** `scripts/ml/verify_pu_artifacts.py
  --include-shap --include-recommendations --include-property-detail` completed
  against the read-only analytics connection. Both target properties reproduced
  their stored original PU scores to <1.2e-16; original/selected SHAP
  reconstructed each model output to <2.3e-16, and each explained output equalled
  the live prediction exactly. The experimental artifact's SHAP was deliberately
  not computed without a verified matching background.
  `tests/test_property_insights_service.py`,
  `tests/api/test_personalised_recommendations.py`,
  `tests/api/test_shap_operations.py` and `tests/api/test_selected_pu_model.py`
  together: **57 passed**. Jaspr `property_insights_api_test.dart`: **4 passed**;
  targeted Dart analysis clean; Python `ruff` clean on every touched file.
* Recommendation scoring was reproduced through
  `RecommendationGenerationService.generate()` with an existing active local
  test-profile's saved V3 preferences and an in-memory result store. 955 catalogue
  rows were evaluated; the first three order and arithmetic were reproduced.
  This was **not** an HTTP call: no authorized bearer token was available, so no
  recommendation row was committed. Exact output values are in the task's audit
  evidence; rerunning through the authenticated endpoint is still required to
  verify authentication and durable result IDs.

### Final layer-by-layer verification (2026-11-12)

| Layer | Artifact or algorithm | Exists locally | Loaded at runtime | Predicts live? | Used in recommendation | Verified evidence |
|---|---|---|---|---|---|---|
| Layer 1 | Original PU `PU_model.joblib` | Yes, Git-tracked (7,865 B) | Yes, via `ModelLoader` | Yes when invoked; ranking reads its **stored** output | **Yes** — 70 % of the final score | SHA-256 `5c00c574…`; MD-00510 `0.27255328732372774`, MD-01755 `0.9799711282139385`; stored-vs-live diff ≤ 1.2e-16 |
| Layer 1 | Selected PU `sitewise_selected_pu_model.joblib` | Yes, Git-tracked (7,684 B) | Yes, on demand (selected-PU routes, verifier) | Yes | No — never selected for ranking | SHA-256 `07bbf5c5…`; identical predictions on both targets; version `sitewise-pu-pvu-1.0` |
| Layer 1 | Experimental PU `sitewise_pu_47_experimental.joblib` | Yes, Git-tracked (715,771 B) | Only when `SITEWISE_PU_MODEL_VARIANT=experimental47` | Yes, 47/47 exact features | Only inside that variant | SHA-256 `1d09cb9a…`; `0.4202639553` / `0.3250633118`; `production_ready:false`, LandScan provenance unresolved |
| Layer 2 | V3 rules + `recommender_v3.joblib` calibration snapshot | Yes, Git-tracked (948 B) | Yes, snapshot read for calibration | **No** — no `predict()`/`predict_proba()` | **Yes** — 30 % preference fit | No predictor methods; `score_candidate_v3()`; 955-row replay reproduced rank order; 57 tests |
| Layer 3 | `shap_explainer.py` + `shap_background_47.csv` | Yes, Git-tracked | Yes, on demand only | Yes — real `predict_proba[:,1]` inside Permutation SHAP | No — explanation only | Baseline + Σ contributions = output within 2.3e-16; output == prediction (diff `0.0`); 25 real background rows |

## 11. Reproducing

```bash
cd backend
# reproducible artifact + inference + SHAP + recommendation evidence
./.venv/Scripts/python.exe scripts/ml/verify_pu_artifacts.py \
  --include-shap --include-recommendations --include-property-detail \
  > ml_reference/pu_artifact_verification_2026_11_12.json

# apply the persistence migration (idempotent, refuses on a non-empty table)
./.venv/Scripts/python.exe scripts/apply_recommendation_persistence_migration.py

# focused suites
./.venv/Scripts/python.exe -m pytest tests/api/test_layer1_feature_coverage.py \
  tests/api/test_recommendation_persistence.py tests/api/test_layer2_reuse_and_gate.py \
  tests/api/test_shap_operations.py tests/api/test_property_id_compatibility.py \
  tests/api/test_personalised_recommendations.py tests/api/test_selected_pu_model.py

# full suite
./.venv/Scripts/python.exe -m pytest tests/

# honest training attempt (refuses today; writes the model-selection report)
./.venv/Scripts/python.exe scripts/ml/train_personalised_recommender.py
```

## 12. Test totals

| Run | Passed | Failed | Skipped | Errors |
|---|---|---|---|---|
| Clean integration worktree at `dfb2243` (prior handoff) | 288 | 0 | 3 | 0 |
| Active working tree at handoff (concurrent postcode work) | — | 15 | — | — |
| Final full backend suite, this integration (2026-11-11) | **316** | **7** | **3** | **0** |

The 7 final failures are the same concurrent postcode-related set (reduced
from 15 as that session's work progressed); none lies in a file changed by
this integration. Per-phase focused suites are listed in §10.

## 13. Limitations and future work

1. Live inference is allowed only for an exact, complete, provenance-resolved
   47-feature vector. The committed bridge has 1,794/1,849 rows with the fifth
   feature, and the catalogue comparison scored 896/955; the 55 bridge-missing
   research rows and other incomplete vectors remain unavailable, not imputed.
2. LandScan licence (`NO_PENDING_LICENCE`) is not proof of permission. Resolve
   the source licence and the audited 0%-coverage positive-row zero before any
   use beyond local reproduction of the artifacts' training inputs.
3. No trained Layer 2 recommender exists. The label gate currently refuses
   training on the observed inventory; `train()` itself is a placeholder and
   requires a real, implemented training/evaluation pipeline after paired
   feedback has accumulated.
4. PU training code, the complete source dataset and independent-holdout
   protocol are absent from this checkout; reproduce and document them before
   making validation or superiority claims.
5. The 955 imported listings' approval/publishing state and the distinction
   between research availability and operational listings remain product
   constraints; PU scores are research indices, not success probabilities.
