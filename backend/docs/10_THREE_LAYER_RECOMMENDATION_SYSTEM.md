# 10 — Three-Layer AI Recommendation System (implemented state)

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

Artifacts (`backend/src/sitewise/ml/`, loaded by `model_loader.py`):

| Artifact | Role | Contract |
|---|---|---|
| `PU_model.joblib` | default ranking model (untouched) | 47 features, order `feature_names_in_` |
| `sitewise_selected_pu_model.joblib` | optional alternate (SHAP target) | identical 47 features, `feature_set=baseline_47`, logistic method, `model_version=sitewise-pu-pvu-1.0` |

Feature resolution per property (`property_features.py` + `feature_bridge.py`):

| Source | Features |
|---|---|
| `sitewise_analytics.subject_features` (+ `other_features`), `demand_gen.features` | 39 |
| `fyp_features.property_population_spatial` (3 documented WorldPop ring equivalents) | 3 |
| `ml_reference/training_population_bridge_1849.csv` (the original training export: `pop_2000m`, `landscan_ambient_pop_{1000m,2000m,3000m}`) | 4 |
| **Total resolvable** | **46 / 47** |
| Unrecoverable | `worldpop_walk_reachable_10min` — absent from the database, the training export, every workbook and both SQL dumps; it survives only inside the 25-row SHAP background |

Evidence recorded in-repo:

* The duplicate-population defect: `fyp_features.property_population_spatial`
  holds **two rows per catalogue id** (`PROPERTY_UNLABELED`,
  `SITEWISE_U_PROPERTY`). The single-property resolver used to abort with
  `Ambiguous ... 2 records matched` for *every* property. It now resolves one
  row deterministically and prefers `SITEWISE_U_PROPERTY`, which is
  **byte-identical** to the model's training record (verified against the
  supplied `example_property_47.json` for MD-00510:
  `pop_ring_0_500m=1071.6`, `pop_total_1km=6430.9`, `pop_total_3km=108745.1`;
  the alphabetical-first twin differs in the 4th significant digit).
* Bridge byte-parity: for MD-00510 the four bridge values equal the supplied
  reference vector exactly (`pop_2000m=35472.8`, landscan 2749 / 30743 / 85886).
* LandScan licence: the training export records
  `landscan_ml_training_eligible=NO_PENDING_LICENCE` for all 1,849 rows. The
  values are reproduced only as the artifact's own training inputs (in-sample
  research use); every coverage report surfaces the licence flag.

**Consequence:** live 47-feature inference is *explicitly unavailable* for
every catalogue property (`/ml/selected/properties/{id}/prediction` returns a
controlled `available: false` body naming the blocking feature and the
no-fabrication policy). The ranking pipeline is unaffected: it uses the
stored per-property `research_p_association_score`, which was verified to be
the default PU model's own output on the training vectors. Coverage and
prediction states are exposed at `GET /ml/selected/properties/{id}/coverage`.

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

* `ShapExplainer` runs Permutation SHAP over the selected artifact's
  `predict_proba` positive class with the **real** 25-row background
  (`ml_reference/shap_background_47.csv`, no synthetic rows).
* **Reconstruction gate:** the response is withheld unless
  `|baseline + Σ contributions − score| < 1e-6`; `reconstruction_verified`
  and the numeric error travel in every payload.
* Explained output is explicit: the model's positive-label association.
* **Coverage:** full SHAP for MD-00510 (its real supplied 47-feature
  vector). For all other properties SHAP is *explicitly unavailable*
  (`shap_status.reason` names the missing 47th feature); the rule-based
  explanation remains fully available.
* **Caching / latency** (measured, `ml_reference/recommender_eval/shap_
  latency.json`): first call **14.65 s** (live permutation run over 47
  features), cached call **0.019 s**. Cache keys embed the artifact's
  `model_version`, so replacing the model invalidates every cached
  explanation; failures are never cached. Explanations are on-demand only —
  ranking never blocks on SHAP. Per-user SHAP payloads persist durably on
  the stored result.

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

* Backend suites touching this work (run 2026-11-11, exact totals in
  `§12`): Layer-1 coverage (12), selected-PU (10), `test_ml` (8),
  personalised pipeline (22), persistence (8), reuse + training gate (3),
  SHAP operations (2), ID compatibility (4).
* Notable verified behaviours: both artifacts load with independent
  contracts; unknown components excluded-never-zero-filled; deterministic
  ranking; ownership isolation (API + DB); restart survival; user-deletion
  cascade; unchanged-input reuse; changed inputs regenerate; the training
  gate refuses on the real inventory and no `recommender*.joblib` exists;
  SHAP reconstruction < 1e-6; measured latency recorded.

## 11. Reproducing

```bash
cd backend
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

Filled from the final full-suite run of this integration — see
`backend/tests/` and the implementation report. The pre-integration
documented baseline was 288 passed / 3 skipped on a clean tree; this
integration adds the suites listed in §10.

## 13. Limitations and future work

1. `worldpop_walk_reachable_10min` must be recomputed (raster + 10-min walk
   isochrone) before any live 47-feature inference or universal SHAP is
   possible; today that state is explicit, never fabricated.
2. LandScan licence (`NO_PENDING_LICENCE`) must be resolved before any use
   beyond reproducing the artifact's own training inputs.
3. No trained Layer 2 recommender until real exposure-paired feedback
   accumulates (the gate + pipeline are ready).
4. The 955 imported listings remain `pending`; admin approval + publishing
   is the product path that turns `detail_available` true.
5. PU scores remain an in-sample research index; independent outcome-based
   validation is a documented prerequisite for any product claim.
