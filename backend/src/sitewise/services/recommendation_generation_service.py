"""Layer 2 + Layer 3 orchestration for personalised recommendations.

Pipeline
========
1. Read the AUTHENTICATED entrepreneur's saved preferences (never a request id).
2. Read eligible research-catalogue candidates with verified field mappings.
3. Use the stored Layer 1 PU *research association* score as the PU input.
4. Apply eligibility filters, then the versioned rule-based Layer 2 scoring.
5. Rank deterministically and persist the batch in the process-local store.
6. On demand, produce two SEPARATED explanations:
     A. a SHAP explanation of the research PU model only, and
     B. the Layer 2 rule engine's own reasons / cautions.
   SHAP is never used to justify a rule it did not calculate.

No trained ``recommender.joblib`` exists in this repository or in the supplied
packages; Layer 2 is explicitly rule-based. See ``LIMITATIONS`` below.
"""
from __future__ import annotations

import copy
import csv
import hashlib
import json
import math
import threading
import uuid
from collections import Counter
from pathlib import Path
from typing import Any

from sqlmodel import Session

from sitewise.core.config import Settings
from sitewise.core.logging import logger
from sitewise.domain.recommendation_scoring import (
    SCORE_MEANING,
    SCORING_CONFIG,
    PropertyCandidate,
    eligibility_failures,
    preference_profile_from,
    rank_candidates,
    score_candidate,
)
from sitewise.domain.recommendation_scoring import (
    SCORING_CONFIG_V3,
)
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import PropertyFeatureRepository
from sitewise.ml.pu_variant import experimental_prediction, resolve_variant
from sitewise.ml.sitewise_recommender_v3 import load_snapshot
from sitewise.ml.selected_pu_integration import (
    SELECTED_MODEL_NAME,
    explain_selected_payload,
)
from sitewise.repositories.generated_recommendation_store import (
    DatabaseRecommendationStore,
    GeneratedRecommendationStore,
    generated_recommendation_store,
)
from sitewise.repositories.recommendation_candidate_repository import (
    RecommendationCandidateRepository,
)
from sitewise.services.preferences_service import PreferencesService

LIMITATIONS: tuple[str, ...] = (
    (
        "Layer 1 is an uncalibrated P-vs-U association index, not a calibrated "
        "probability of commercial success, profitability or survival."
    ),
    (
        "Layer 2 is a transparent RULE-BASED engine, not a trained recommender. "
        "No trained recommender.joblib exists in the repository or supplied packages."
    ),
    (
        "The 70/30 combination and all component weights are a configurable "
        "research baseline; they have NOT been fitted to or validated against "
        "business outcomes."
    ),
    (
        "Catalogue availability is UNKNOWN_NOT_VERIFIED for every research row. "
        "These are research candidates, NOT confirmed available listings; pending "
        "verification fyp.rental_properties rows are excluded entirely."
    ),
    (
        "Generated results persist in PostgreSQL (recommendation_result, one "
        "row per ranked property with its payload and preference snapshot "
        "context) and survive restarts and worker boundaries; the process-local "
        "store remains available only for isolated tests."
    ),
)


def _ml_reference_dir() -> Path:
    """Locate backend/ml_reference without assuming a fixed package depth."""
    for parent in Path(__file__).resolve().parents:
        candidate = parent / "ml_reference"
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parents[3] / "ml_reference"


REFERENCE_DIR = _ml_reference_dir()
BACKGROUND_CSV = REFERENCE_DIR / "shap_background_47.csv"
EXAMPLE_VECTOR_JSON = REFERENCE_DIR / "example_property_47.json"

# Permutation SHAP over 47 features and the 25 real background rows is
# expensive (~1 minute for the first property). Cache the VERIFIED payload per
# property/model so repeated explanation reads are cheap. Failures are NOT
# cached, so a transient database problem can recover on the next request.
_SHAP_CACHE: dict[str, dict[str, Any]] = {}
_SHAP_CACHE_LOCK = threading.Lock()


def _feature_labels(shap_payload: dict[str, Any] | None) -> dict[str, str]:
    """Plain-English labels for the features actually present in a SHAP payload.

    Reuses the single 47-feature label map owned by
    :mod:`sitewise.services.property_insights_service` rather than keeping a
    second copy that could drift. Imported lazily to avoid a module cycle, and
    a missing map degrades to an empty dict - a client then falls back to the
    technical name instead of the endpoint failing.
    """
    if not shap_payload:
        return {}
    try:
        from sitewise.services.property_insights_service import FEATURE_LABELS
    except Exception:  # noqa: BLE001 - labels are presentation, never fatal
        return {}
    names = set((shap_payload.get("contributions") or {}).keys())
    return {name: FEATURE_LABELS[name] for name in sorted(names) if name in FEATURE_LABELS}


class RecommendationGenerationService:
    """Application service: framework-free orchestration over domain + repos."""

    def __init__(
        self,
        app_session: Session,
        analytics_session: Session,
        store: GeneratedRecommendationStore | DatabaseRecommendationStore | None = None,
    ):
        self.app_session = app_session
        self.analytics_session = analytics_session
        self.preferences = PreferencesService(app_session)
        self.candidates = RecommendationCandidateRepository(analytics_session)
        # Default to the DURABLE PostgreSQL store: generated batches must
        # survive a backend restart and cross uvicorn worker boundaries
        # (Phase 5). The process-local store remains injectable for tests.
        self.store = store if store is not None else DatabaseRecommendationStore(app_session)

    # ------------------------------------------------------------- generation
    @staticmethod
    def _inputs_hash(
        profile: Any,
        limit: int,
        state: str | None,
        property_ids: list[str] | None,
        *,
        layer1_key: str,
        layer1_version: str | None,
        engine_version: str,
    ) -> str:
        """Stable hash of every input that can change the ranked output.

        Covers the normalised preference profile, the request filters, the
        Layer-2 engine version, AND the Layer-1 variant + artifact version -
        a preference edit, a different limit, a new scoring version or a
        model-variant switch all produce a different hash, so a cached batch
        can never be served for changed inputs (cache invalidation on model,
        preference or calibration change).
        """
        material = json.dumps(
            {
                "profile": profile.as_dict(),
                "limit": limit,
                "state": state,
                "property_ids": sorted(property_ids or []),
                "scoring_version": engine_version,
                "layer1_variant": layer1_key,
                "layer1_version": layer1_version,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        return hashlib.sha256(material.encode("utf-8")).hexdigest()

    def generate(
        self,
        user_id: uuid.UUID,
        *,
        limit: int = 20,
        state: str | None = None,
        property_ids: list[str] | None = None,
    ) -> dict[str, Any]:
        """Score and rank the eligible catalogue for one entrepreneur.

        ``property_ids`` optionally narrows the search to a shortlist (useful
        for regenerating an explanation for one known property). It can only
        RESTRICT the eligible set - it never adds a property that failed the
        repository's verification / availability exclusions.

        If nothing that influences the output has changed since the user's
        most recent batch (preferences, filters, scoring version), the stored
        batch is returned without recomputing (``reused_existing_batch``).
        """
        limit = max(1, min(int(limit), 100))
        settings = Settings()
        variant = resolve_variant(settings)
        payload = self.preferences.payload(user_id)
        stored = payload.get("preferences")
        profile = preference_profile_from(stored)
        # Layer-2 engine follows the stored preferences' schema version: v3
        # (five-question) answers score with the V3 rule engine whose
        # calibration is verified against RECOMMENDER_V3.joblib. v1/v2
        # records keep the original engine and are never re-interpreted.
        recommender = None
        if profile.preferences_version == 3:
            recommender = load_snapshot()
            engine_version = SCORING_CONFIG_V3.version
        else:
            engine_version = SCORING_CONFIG.version
        inputs_hash = self._inputs_hash(
            profile,
            limit,
            state,
            property_ids,
            layer1_key=variant.key,
            layer1_version=variant.version,
            engine_version=engine_version,
        )

        existing = self.store.latest(user_id)
        if existing and existing.get("results"):
            first = existing["results"][0]
            if first.get("generation_inputs_hash") == inputs_hash:
                return self._reused_response(user_id, existing, profile, stored, payload)

        rows = self.candidates.list_candidates(
            max_rent=profile.max_rent_myr,
            min_size=profile.min_floor_area_sqft,
            state=state,
        )
        shortlist: set[str] | None = None
        if property_ids is not None:
            shortlist = {str(pid).strip() for pid in property_ids if str(pid).strip()}
            rows = [row for row in rows if str(row.get("property_id")) in shortlist]

        rejections: Counter[str] = Counter()
        scored: list[Any] = []
        experimental_unavailable: list[dict[str, Any]] = []
        experimental_scored = 0
        for row in rows:
            candidate = PropertyCandidate.from_row(row)
            failures = eligibility_failures(candidate, profile)
            if variant.key == "experimental47":
                # The stored legacy score is irrelevant for the experimental
                # variant: eligibility re-checks the LIVE score instead, so a
                # row without a stored score can still be scored - and a row
                # WITH a stored score never leaks it into this batch.
                failures = [
                    f for f in failures
                    if f != "pu_association_score_missing_or_invalid"
                ]
            if failures:
                for reason in failures:
                    rejections[reason] += 1
                continue
            if variant.key == "experimental47":
                prediction = experimental_prediction(
                    self.analytics_session, str(candidate.property_id)
                )
                if not prediction.get("available"):
                    rejections["experimental47_47_feature_inference_unavailable"] += 1
                    if len(experimental_unavailable) < 10:
                        experimental_unavailable.append(
                            {
                                "property_id": candidate.property_id,
                                "missing_features": (
                                    prediction.get("feature_coverage") or {}
                                ).get("missing_features", []),
                                "inference_state": prediction.get("inference_state"),
                            }
                        )
                    continue
                from dataclasses import replace as _replace

                candidate = _replace(
                    candidate,
                    pu_association_score=float(prediction["score"]),
                    pu_score_source=variant.score_source,
                    pu_feature_set="experimental_47_landscan_update",
                    pu_model_method="live_inference",
                )
                experimental_scored += 1
            try:
                if recommender is not None:
                    scored.append(
                        recommender.score_preference(
                            profile,
                            candidate,
                            config=SCORING_CONFIG_V3,
                            layer1_model=variant.layer1_model,
                        )
                    )
                else:
                    item = score_candidate(candidate, profile, config=SCORING_CONFIG)
                    if item.layer1_model != variant.layer1_model:
                        from dataclasses import replace

                        item = replace(item, layer1_model=variant.layer1_model)
                    scored.append(item)
            except ValueError as exc:
                # Fail closed on an invalid PU score or out-of-range component:
                # never substitute a demonstration value.
                logger.warning(
                    "Skipping recommendation candidate %s: %s", row.get("property_id"), exc
                )
                rejections["scoring_failed_closed"] += 1

        ranked = rank_candidates(scored)
        top = ranked[:limit]
        candidate_summary = {
            "catalogue_rows_read": len(rows),
            "eligible": len(ranked),
            "returned": len(top),
            "rejected": len(rows) - len(ranked),
            "rejection_reasons": dict(sorted(rejections.items())),
            "pre_filters": {
                "max_rent_myr": profile.max_rent_myr,
                "min_floor_area_sqft": profile.min_floor_area_sqft,
                "state": state,
                "property_ids": sorted(shortlist) if shortlist is not None else None,
            },
            "limit": limit,
            "layer1_variant": variant.key,
            "layer1_model": variant.layer1_model,
            "layer2_engine_version": engine_version,
            "experimental_coverage": {
                "scored_live_inference": experimental_scored,
                "unavailable_examples": experimental_unavailable,
            }
            if variant.key == "experimental47"
            else None,
            "ranking": "final_score desc, preference_match_score desc, "
                       "pu_association_score desc, property_id asc",
        }
        payloads = []
        for item in top:
            item_dict = item.as_dict()
            # Batch-level provenance travels on every stored row so an
            # unchanged-input reuse can reconstruct the full response.
            item_dict["generation_inputs_hash"] = inputs_hash
            item_dict["batch_summary"] = candidate_summary
            payloads.append(item_dict)
        batch = self.store.save_batch(user_id, payloads)

        return {
            "user_id": str(user_id),
            "batch_id": batch["batch_id"],
            "generated_at": batch["generated_at"],
            "status": "ok" if top else "no_eligible_properties",
            "reused_existing_batch": False,
            "preferences": {
                "saved": bool(stored),
                "updated_at": payload.get("updated_at"),
                "profile": profile.as_dict(),
                "note": (
                    None if stored else
                    "No saved preferences. Only components measurable from the "
                    "property's own verified features were scored; all "
                    "preference-dependent components are reported as unknown, "
                    "never as zero."
                ),
            },
            "model": self._model_section(variant),
            "layer2": self._layer2_section(recommender),
            "scoring": self._scoring_section(recommender),
            "candidate_summary": candidate_summary,
            "results": batch["results"],
            "explanation_endpoint": (
                "GET /api/v1/recommendations/{result_id}/explanation"
            ),
            "limitations": list(LIMITATIONS),
        }

    # ------------------------------------------------------------ sections
    @staticmethod
    def _model_section(variant: Any) -> dict[str, Any]:
        """Layer-1 section describing the ACTIVE PU variant."""
        section = variant.as_dict()
        section["used_for_ranking"] = True
        section["selected_alternative"] = {
            "name": SELECTED_MODEL_NAME,
            "role": "optional alternate Layer 1 PU research model",
            "used_for_ranking": False,
            "endpoints": [
                "GET /api/v1/ml/selected/model",
                "GET /api/v1/ml/selected/properties/{property_id}/prediction",
                "GET /api/v1/ml/selected/properties/{property_id}/explanation",
            ],
        }
        return section

    @staticmethod
    def _layer2_section(recommender: Any | None) -> dict[str, Any]:
        """Layer-2 section for the engine actually used by this batch."""
        if recommender is not None:
            describe = recommender.describe()
            return {
                "engine": "rule_based_5q_v3",
                "trained_recommender": False,
                "config_version": SCORING_CONFIG_V3.version,
                "status": (
                    "Five-question V3 rule engine. The calibration constants are "
                    "restored from the supplied RECOMMENDER_V3.joblib snapshot and "
                    "verified field-by-field at load time; the package's original "
                    ".py source was not supplied, so the deterministic rules are a "
                    "documented reconstruction anchored on the snapshot's own "
                    "values. Nothing here is a trained model output."
                ),
                "calibration": describe.get("calibration"),
                "training_data_needed": [
                    "Per-entrepreneur preference snapshots linked to a decision",
                    (
                        "Observed outcomes (shortlist, viewing, lease signed, outlet "
                        "survival/revenue) with explicit negative feedback"
                    ),
                    "Consent, de-identification and a time-based train/test split",
                    (
                        "Offline evaluation (NDCG / MAP / CTR calibration) before "
                        "replacing the research baseline weights"
                    ),
                ],
            }
        return {
            "engine": "rule_based",
            "trained_recommender": False,
            "status": (
                "No genuine trained Layer 2 recommender.joblib was found in "
                "the repository or the supplied training/SHAP packages. None "
                "was fabricated; a transparent versioned scoring engine is used."
            ),
            "training_data_needed": [
                "Per-entrepreneur preference snapshots linked to a decision",
                (
                    "Observed outcomes (shortlist, viewing, lease signed, outlet "
                    "survival/revenue) with explicit negative feedback"
                ),
                "Consent, de-identification and a time-based train/test split",
                (
                    "Offline evaluation (NDCG / MAP / CTR calibration) before "
                    "replacing the research baseline weights"
                ),
            ],
        }

    @staticmethod
    def _scoring_section(recommender: Any | None) -> dict[str, Any]:
        if recommender is not None:
            section = SCORING_CONFIG_V3.as_dict()
            section["engine"] = "rule_based_5q_v3"
            section["calibration"] = recommender.describe().get("calibration")
            return section
        return SCORING_CONFIG.as_dict()

    def _reused_response(
        self,
        user_id: uuid.UUID,
        existing: dict[str, Any],
        profile: Any,
        stored: dict[str, Any] | None,
        payload: dict[str, Any],
    ) -> dict[str, Any]:
        """Return the stored batch unchanged when no input hash changed.

        Identical response shape to a fresh generation except
        ``reused_existing_batch`` is True and no catalogue scan or scoring
        pass runs.
        """
        variant = resolve_variant(Settings())
        recommender = load_snapshot() if profile.preferences_version == 3 else None
        results = existing["results"]
        first = results[0]
        return {
            "user_id": str(user_id),
            "batch_id": existing["batch_id"],
            "generated_at": existing["generated_at"],
            "status": "ok" if results else "no_eligible_properties",
            "reused_existing_batch": True,
            "preferences": {
                "saved": bool(stored),
                "updated_at": payload.get("updated_at"),
                "profile": profile.as_dict(),
                "note": (
                    None if stored else
                    "No saved preferences. Only components measurable from the "
                    "property's own verified features were scored; all "
                    "preference-dependent components are reported as unknown, "
                    "never as zero."
                ),
            },
            "model": self._model_section(variant),
            "layer2": self._layer2_section(recommender),
            "scoring": self._scoring_section(recommender),
            "candidate_summary": first.get("batch_summary") or {},
            "results": results,
            "explanation_endpoint": (
                "GET /api/v1/recommendations/{result_id}/explanation"
            ),
            "limitations": list(LIMITATIONS),
        }

    def latest(self, user_id: uuid.UUID) -> dict[str, Any]:
        batch = self.store.latest(user_id)
        return {
            "user_id": str(user_id),
            "available": batch is not None,
            "batch": batch,
            "note": (
                None if batch else
                "No generated batch stored yet for this account. Call POST "
                "/api/v1/recommendations/generate. Results persist in "
                "PostgreSQL and remain available after a restart."
            ),
        }

    # ------------------------------------------------------------ explanation
    def explain(self, result_id: uuid.UUID, user_id: uuid.UUID) -> dict[str, Any] | None:
        """Two separated explanation sections; SHAP is optional."""
        record = self.store.get(result_id, user_id)
        if record is None:
            return None

        base_explanation = record.get("explanation") or {}
        shap_payload = self.store.shap_of(result_id, user_id)
        if shap_payload is None:
            shap_payload, shap_status = self._resolve_shap(
                record["property_id"],
                float(record["model"]["association_score"]),
            )
            if shap_payload is not None:
                self.store.attach_shap(result_id, user_id, shap_payload, shap_status)
        else:
            shap_status = {"available": True, "reason": None, "source": "cached"}

        personalisation = record["personalisation"]
        personalised = {
            "engine": "rule_based",
            # The engine version is whatever actually scored this row (the
            # five-question V3 engine for v3 preferences). Hardcoding the
            # baseline config here would mislabel a V3 result as v1/v2.
            "config_version": (
                personalisation.get("config_version") or SCORING_CONFIG.version
            ),
            "preference_reasons": base_explanation.get("preference_reasons", []),
            "cautions": base_explanation.get("cautions", []),
            "preference_match_score": record["personalisation"]["preference_match_score"],
            "components": record["personalisation"]["components"],
            "component_status": record["personalisation"]["component_status"],
            "component_details": record["personalisation"]["component_details"],
            "coverage": record["personalisation"]["coverage"],
            "final_score": record["final_recommendation"]["score"],
            "rank": record["final_recommendation"]["rank"],
            "listing_verification": record["property"]["verification"],
            "explanation_method": (
                "These reasons, evidence values and cautions come directly from "
                "the Layer 2 rule engine's own component calculations. SHAP is "
                "NOT used to explain any rule, preference or filter."
            ),
        }
        pu_section = {
            "available": shap_payload is not None,
            "shap": shap_payload,
            "reason": shap_status.get("reason"),
            "note": (
                "SHAP in this section explains ONLY the research PU model's "
                "positive-label association score. It is not a personalised "
                "recommendation explanation and not a business-outcome prediction."
            ),
        }
        return {
            "result_id": str(result_id),
            "batch_id": record.get("batch_id"),
            "user_id": str(user_id),
            "property_id": record["property_id"],
            # The stored property block, so the explanation surface can name
            # the unit it explains and link onward without a second request.
            # It carries the canonical id, the verified listing reference and
            # the verification state - never a promise of availability.
            "property": record.get("property") or {},
            "generated_at": record.get("generated_at"),
            "model": record["model"],
            "personalisation": record["personalisation"],
            "final_recommendation": record["final_recommendation"],
            "explanation": {
                "preference_reasons": base_explanation.get("preference_reasons", []),
                "cautions": base_explanation.get("cautions", []),
                "shap": shap_payload,
                "shap_status": shap_status,
                "score_meaning": SCORE_MEANING,
                # Plain-English names for every model feature, so no client has
                # to render a raw column name such as ``pop_500m`` or duplicate
                # a 47-entry map of its own. Only features present in the
                # deployed feature set are included.
                "feature_labels": _feature_labels(shap_payload),
                "sections": {
                    "pu_research_explanation": pu_section,
                    "personalised_recommendation_explanation": personalised,
                },
            },
        }

    # ------------------------------------------------------------- SHAP internals
    def _resolve_shap(
        self, property_id: str, pu_score: float
    ) -> tuple[dict[str, Any] | None, dict[str, Any]]:
        """Produce a VERIFIED SHAP explanation, or an explicit unavailable status.

        Feature vectors must be the exact 47 saved features. Three outcomes:
        live resolution succeeds; or the supplied 47-feature reference vector
        for that exact property is used (real supplied data, validated against
        the model score); or SHAP is unavailable and the recommendation still
        works with its rule-based explanation.
        """
        try:
            loaded = ModelLoader().load(SELECTED_MODEL_NAME)
        except Exception as exc:  # noqa: BLE001 - optional subsystem: fail closed, never 500
            return None, {
                "available": False,
                "reason": f"Selected PU model could not be loaded: {exc}",
            }

        # The cache key includes the model version so replacing the artifact
        # invalidates every cached explanation (safe invalidation); failures
        # are never cached, so a transient problem can recover.
        cache_key = f"{SELECTED_MODEL_NAME}:{loaded.meta.get('model_version')}:{property_id}"
        with _SHAP_CACHE_LOCK:
            hit = _SHAP_CACHE.get(cache_key)
        if hit is not None:
            payload = copy.deepcopy(hit)
            relation = payload.get("relation_to_recommendation") or {}
            relation["recommendation_pu_score"] = pu_score
            relation["scores_agree"] = (
                abs(float(payload.get("score", 0.0)) - pu_score) <= 1e-6
            )
            payload["relation_to_recommendation"] = relation
            return payload, {
                "available": True,
                "reason": None,
                "source": "process-wide verified SHAP cache",
                "reconstruction_verified": True,
            }

        features: dict[str, float] | None = None
        provenance = ""
        failure_reason = "No verified 47-feature vector could be resolved."

        try:
            resolved = PropertyFeatureRepository(self.analytics_session).get(
                property_id, loaded.feature_names, source="catalog"
            )
            if not resolved.missing_features:
                features = dict(resolved.values)
                provenance = (
                    "sitewise_analytics.subject_features / demand_gen.features / "
                    "fyp_features.property_population_spatial, resolved to the "
                    "exact 47 saved features"
                )
            else:
                failure_reason = (
                    "Live feature resolution is incomplete (missing "
                    f"{len(resolved.missing_features)} of 47 features): "
                    + ", ".join(resolved.missing_features[:8])
                )
        except Exception as exc:  # noqa: BLE001 - any resolver failure must fail closed
            failure_reason = (
                "Live 47-feature resolution is unavailable on this deployment: "
                f"{type(exc).__name__}: {exc}"
            )

        if features is None:
            reference = self._reference_vector(loaded.feature_names)
            if reference is not None and reference["property_id"] == property_id:
                features = dict(reference["features"])
                provenance = (
                    "ml_reference/example_property_47.json - the supplied, real "
                    "47-feature vector for this exact property (used because "
                    "live resolution fails closed on this deployment)"
                )
            else:
                return None, {
                    "available": False,
                    "reason": failure_reason,
                    "policy": (
                        "No feature vector is fabricated or zero-filled. SHAP is "
                        "omitted; the rule-based personalised explanation and the "
                        "recommendation remain fully available."
                    ),
                }

        try:
            with BACKGROUND_CSV.open(encoding="utf-8-sig", newline="") as fp:
                background = list(csv.DictReader(fp))
            if not background:
                raise ValueError("ml_reference/shap_background_47.csv is empty")
            raw = explain_selected_payload(features, background)
        except Exception as exc:  # noqa: BLE001 - SHAP is optional; omit, do not 500
            logger.warning("SHAP explanation failed for %s: %s", property_id, exc)
            return None, {
                "available": False,
                "reason": f"SHAP computation unavailable: {type(exc).__name__}: {exc}",
            }

        score = float(raw["score"])
        baseline = float(raw["baseline"])
        contributions = {str(k): float(v) for k, v in raw["contributions"].items()}
        reconstruction = baseline + math.fsum(contributions.values())
        error = abs(reconstruction - score)
        if error >= 1e-6:
            return None, {
                "available": False,
                "reason": (
                    f"SHAP reconstruction check failed (|baseline + "
                    f"sum(contributions) - score| = {error:.3g} >= 1e-6); "
                    "the explanation was withheld rather than shown as valid."
                ),
            }

        shap_payload = {
            "model_name": raw["model_name"],
            "model_version": loaded.meta.get("model_version"),
            "explainer": raw["explainer"],
            "score": score,
            "baseline": baseline,
            "baseline_plus_contributions": reconstruction,
            "reconstruction_error": error,
            "reconstruction_verified": True,
            "contributions": contributions,
            "top_positive_features": raw["top_positive_features"],
            "top_negative_features": raw["top_negative_features"],
            "feature_count": len(contributions),
            "data_provenance": {
                "feature_vector": provenance,
                "background": "ml_reference/shap_background_47.csv (supplied real rows)",
                "background_size": raw["background_size"],
                "feature_set": loaded.meta.get("feature_set"),
            },
            "score_meaning": raw["score_meaning"],
            "research_only": True,
            "explanation_scope": raw["explanation_scope"],
            "relation_to_recommendation": {
                "recommendation_pu_score": pu_score,
                "shap_explained_score": score,
                "scores_agree": abs(score - pu_score) <= 1e-6,
                "note": (
                    "SHAP explains the optional selected PU artifact. The ranked "
                    "recommendation uses the default pu_model association score "
                    "stored for the catalogue row. Agreement is measured, not "
                    "assumed; both artifacts currently use the same baseline_47 "
                    "logistic estimator."
                ),
            },
        }
        with _SHAP_CACHE_LOCK:
            _SHAP_CACHE[cache_key] = copy.deepcopy(shap_payload)
        return shap_payload, {
            "available": True,
            "reason": None,
            "source": provenance,
            "reconstruction_verified": True,
        }

    @staticmethod
    def _reference_vector(feature_names: list[str]) -> dict[str, Any] | None:
        try:
            payload = json.loads(EXAMPLE_VECTOR_JSON.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        features = payload.get("features")
        if not isinstance(features, dict):
            return None
        if set(features) != set(feature_names):
            return None
        return {
            "property_id": str(payload.get("property_id") or ""),
            "features": {k: float(v) for k, v in features.items()},
        }
