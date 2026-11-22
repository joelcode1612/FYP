"""Layer-1 PU model variant resolution for the personalised recommender.

Two variants, selected by ``SITEWISE_PU_MODEL_VARIANT``:

``legacy`` (default)
    The stored production ``research_p_association_score`` per catalogue row —
    the original PU model's saved output for the 47-feature baseline vectors.
    Nothing is recomputed; the production artifact is untouched.

``experimental47``
    LIVE inference with the supplied experimental artifact
    (``sitewise_pu_47_experimental.joblib``, bagged Histogram Gradient
    Boosting, version ``hist_gradient_boosting@PU_47_CANDIDATE_2026_11_11``).
    A property is scored ONLY when its exact 47-feature vector resolves from
    the live database plus the committed training bridge (1,794/1,849
    research subjects). Everything else reports
    ``47-feature inference unavailable`` with the missing-feature list and is
    EXCLUDED from an experimental ranking — never imputed, never borrowed
    from another property.

Guarantees enforced here
========================
* One ranking batch uses exactly ONE variant; legacy and experimental scores
  are never averaged, mixed, or written into each other's columns (the
  durable store records ``model_name`` + ``scoring_version`` per row).
* The experimental artifact stays production-gated: its model card says
  ``production_ready: false`` and the LandScan licence provenance is
  unresolved; every experimental response carries both facts.
"""
from __future__ import annotations

import threading
from dataclasses import dataclass
from typing import Any

from sqlmodel import Session

from sitewise.core.config import Settings
from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.feature_bridge import merge_bridge_features
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import (
    FeatureResolutionError,
    PropertyFeatureBundle,
    PropertyFeatureRepository,
)
from sitewise.ml.pu_learning import PULearning

EXPERIMENTAL_MODEL_NAME = "sitewise_pu_47_experimental"
LEGACY_MODEL_NAME = "pu_model"


@dataclass(frozen=True)
class VariantInfo:
    key: str
    layer1_model: str
    artifact: str
    version: str | None
    feature_count: int | None
    research_only: bool
    production_ready: bool | None
    score_source: str
    score_meaning: str
    notes: tuple[str, ...] = ()

    def as_dict(self) -> dict[str, Any]:
        return {
            "key": self.key,
            "name": self.layer1_model,
            "layer1_model": self.layer1_model,
            "artifact": self.artifact,
            "version": self.version,
            "feature_count": self.feature_count,
            "research_only": self.research_only,
            "production_ready": self.production_ready,
            "score_source": self.score_source,
            "score_meaning": self.score_meaning,
            "notes": list(self.notes),
        }


def resolve_variant(
    settings: Settings | None = None, *, variant_key: str | None = None
) -> VariantInfo:
    """Describe the ACTIVE Layer-1 variant (loads the artifact once)."""
    variant = variant_key or (settings or Settings()).pu_model_variant
    if variant == "legacy":
        loaded = ModelLoader().load_cached(LEGACY_MODEL_NAME)
        return VariantInfo(
            key="legacy",
            layer1_model=LEGACY_MODEL_NAME,
            artifact=loaded.meta.get("artifact_filename", "PU_model.joblib"),
            version=loaded.meta.get("version") or loaded.meta.get("feature_set"),
            feature_count=len(loaded.feature_names),
            research_only=True,
            production_ready=None,
            score_source=(
                "fyp.rental_properties.catalogue_source_data."
                "research_p_association_score "
                "(stored output of the original PU model on the 47-feature baseline)"
            ),
            score_meaning=(
                "Uncalibrated association with the observed-positive F&B sample "
                "class; NOT a probability of commercial success."
            ),
        )
    if variant == "expanded64":
        from sitewise.ml.pu_expanded import EXPANDED_MODEL_NAME

        loaded = ModelLoader().load_cached(EXPANDED_MODEL_NAME)
        meta = loaded.meta
        return VariantInfo(
            key="expanded64",
            layer1_model=EXPANDED_MODEL_NAME,
            artifact=meta.get("artifact_filename", "sitewise_pu_64_expanded.joblib"),
            version=meta.get("model_variant"),
            feature_count=len(loaded.feature_names),
            research_only=True,
            production_ready=bool(meta.get("production_ready", False)),
            score_source=(
                "live inference: exact 64-feature vector resolved from the analytics "
                "database + committed training-data bridge, scored by "
                "sitewise_pu_64_expanded.joblib (sha256 "
                "0371f4e4ef20a0e264cc4fa7b47f770e7fae23016787fc0d8f7bd42d3541676f)"
            ),
            score_meaning=(
                "Uncalibrated bagged-LogisticRegression P-vs-U association index "
                "(spatial CV AUROC 0.699824 on the 1,796-row research sample); NOT a "
                "probability of commercial success."
            ),
            notes=(
                "Expanded research model: production_ready=false per its model card.",
                "The 16 population-age/residential measurements exist only in the "
                "committed training data; properties without a complete "
                "expanded-bridge record (including every newly submitted listing) "
                "report their missing features and are excluded — never imputed, "
                "never borrowed from another property.",
                "WorldPop age-raster coverage is incomplete for some locations "
                "(1,067 COMPLETED / 590 PARTIAL_COVERAGE / 139 LOW_COVERAGE on the "
                "training sample); the status travels with every response.",
                "Eligibility-threshold review (2026-11-15): the documented strictly-"
                "greater-than-50 gate on the 0-100 scale retains 47.7% of the "
                "model's own training rows (median 47.8), comparable to the legacy "
                "stored-score scale, so the threshold is unchanged.",
            ),
        )
    loaded = ModelLoader().load_cached(EXPERIMENTAL_MODEL_NAME)
    meta = loaded.meta
    return VariantInfo(
        key="experimental47",
        layer1_model=EXPERIMENTAL_MODEL_NAME,
        artifact=meta.get("artifact_filename", "sitewise_pu_47_experimental.joblib"),
        version=meta.get("version"),
        feature_count=len(loaded.feature_names),
        research_only=True,
        production_ready=bool(meta.get("production_ready", False)),
        score_source=(
            "live inference: exact 47-feature vector resolved from the analytics "
            "database + committed training bridge, scored by "
            "sitewise_pu_47_experimental.joblib (sha256 "
            "1d09cb9a44301d1020bb367a1b3dcb1803935e853c348eccad357f0ede8fd1e2)"
        ),
        score_meaning=(
            "Uncalibrated bagged-HistGradientBoosting P-vs-U association index "
            "(spatial CV AUROC 0.76007 on the 1,849-row research sample); NOT a "
            "probability of commercial success."
        ),
        notes=(
            "Experimental research model: production_ready=false per model card.",
            "LandScan licence provenance is UNRESOLVED (NO_PENDING_LICENCE is an "
            "internal record flag, not proof of the dataset's licence); authorized "
            "local research testing only.",
            "Properties without a complete verified 47-feature vector report "
            "'47-feature inference unavailable' and are excluded from this "
            "experimental ranking.",
        ),
    )


#: Cache of per-property experimental results, keyed by
#: (model_version, property_id). Model-version keyed, so replacing the
#: artifact invalidates every cached score (requirement: cache invalidation on
#: model change). Calibration/preference changes do NOT affect this cache —
#: they only affect Layer 2, whose inputs hash already covers them.
_SCORE_CACHE: dict[tuple[str, str], dict[str, Any]] = {}
_SCORE_CACHE_LOCK = threading.Lock()


def clear_experimental_cache() -> int:
    """Test/admin hook: drop the experimental score cache."""
    with _SCORE_CACHE_LOCK:
        count = len(_SCORE_CACHE)
        _SCORE_CACHE.clear()
        return count


def experimental_prediction(
    analytics_session: Session, property_id: str
) -> dict[str, Any]:
    """Score ONE catalogue property with the experimental 47-feature model.

    Returns the ``predict_or_report`` contract plus the full feature-coverage
    report and the LandScan/production gating flags. Failures are explicit:
    ``available: false`` names the exact missing features.
    """
    loaded = ModelLoader().load(EXPERIMENTAL_MODEL_NAME)
    model_version = str(loaded.meta.get("version") or "unknown")
    cache_key = (model_version, str(property_id))
    with _SCORE_CACHE_LOCK:
        cached = _SCORE_CACHE.get(cache_key)
    if cached is not None:
        return cached

    # Resolve the exact saved 47-feature vector (live DB + training bridge).
    coverage: dict[str, Any]
    try:
        bundle: PropertyFeatureBundle = PropertyFeatureRepository(analytics_session).get(
            str(property_id), loaded.feature_names, source="catalog"
        )
        merged = merge_bridge_features(bundle, expected_features=loaded.feature_names)
        coverage = merged.as_dict()
    except FeatureResolutionError as exc:
        coverage = {
            "property_id": str(property_id),
            "complete": False,
            "missing_features": [f"feature_resolution_failed: {exc}"],
            "unrecoverable_features": [],
            "value_sources": {},
            "values": {},
            "available_features": 0,
            "feature_count": len(loaded.feature_names),
            "flags": [f"Feature resolution failed closed: {exc}"],
        }
    except Exception as exc:  # noqa: BLE001 - fail closed, never fabricate
        coverage = {
            "property_id": str(property_id),
            "complete": False,
            "missing_features": [f"feature_resolution_failed: {type(exc).__name__}: {exc}"],
            "unrecoverable_features": [],
            "value_sources": {},
            "values": {},
            "available_features": 0,
            "feature_count": len(loaded.feature_names),
            "flags": ["Feature resolution failed closed."],
        }

    features = {
        name: value for name, value in coverage.get("values", {}).items() if value is not None
    }
    result = PULearning(model_name=EXPERIMENTAL_MODEL_NAME).predict_or_report(
        str(property_id), features, allow_model_imputation=False
    )
    result["feature_coverage"] = {
        key: coverage[key]
        for key in (
            "available_features", "feature_count", "complete",
            "missing_features", "unrecoverable_features", "value_sources", "flags",
        )
    }
    result["inference_state"] = (
        "ready" if result.get("available") else "47_feature_inference_unavailable"
    )
    result["layer1_model"] = EXPERIMENTAL_MODEL_NAME
    result["gating"] = {
        "production_ready": False,
        "landscan_provenance": "unresolved (NO_PENDING_LICENCE record flag, not licence proof)",
        "research_only": True,
    }
    if result.get("available"):
        with _SCORE_CACHE_LOCK:
            _SCORE_CACHE[cache_key] = result
    return result
