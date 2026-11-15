"""Research-only F&B business-category resemblance (54-feature model).

Stage 2 of the two-stage research system. The active artifact is the
2026-11-15 **retrain** (``category_recommender_v2_20261115``): a fitted sklearn
``Pipeline`` (median imputer -> HistGradientBoostingClassifier) over **54
leakage-reduced features** — the 64-feature PU contract minus the ten F&B
competitor-count columns, because a known P outlet may appear in its own
competitor inventory (self-inclusion has not been independently verified).

The artifact, its feature contracts and its SHAP backgrounds are owned by
:mod:`sitewise.ml.category_aware`. This module adds the catalogue-facing
orchestration: feature resolution, the missing-value policy, batch scoring and
the response payload.

Contract enforced here
======================
* The exact feature names and order come from the artifact itself
  (``metadata.category_feature_names``); nothing is derived from the PU model.
* Only the residential measurements may be missing (the saved median imputer
  supports exactly that, mirroring the package's own prediction utility). Any
  other gap refuses to score and names the missing fields.
* The competitor counts remain available as **local context only** — they are
  never inputs to the category model and are reported under an explicit
  "not used by the model" key.
* Output is an exploratory resemblance among *observed operating* F&B
  categories. It is **not** a success probability, a profitability forecast or
  a validated "best business type" recommendation. Validation is weak
  (geographic macro-F1 0.289, balanced accuracy 0.292 against a 0.25 chance
  level) and the model card marks it research-only / not production-validated.
* The entrepreneur's selected category — not the model's top category — is what
  :func:`category_explanation` explains.

U records are never treated as negatives; they are simply unlabelled.
"""
from __future__ import annotations

import math
import threading
from typing import Any

from sqlmodel import Session

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml import category_aware
from sitewise.ml.category_aware import (
    CATEGORIES,
    SCORE_MEANING,
    CategoryBundle,
)
from sitewise.ml.category_aware import (
    EXCLUDED_COMPETITOR_FEATURES as _COMPETITOR_FEATURES,
)
from sitewise.ml.feature_bridge import merge_bridge_features
from sitewise.ml.property_features import FeatureResolutionError, PropertyFeatureRepository
from sitewise.ml.pu_expanded import merge_expanded_bridge_features

#: Registry name of the ACTIVE category artifact. The previous research
#: artifact (``sitewise_fnb_category.joblib``) is preserved on disk and remains
#: loadable by name for audit; this constant is the one the services use.
CATEGORY_MODEL_NAME = "sitewise_fnb_category_v2"

#: The ten columns excluded from category training (self-inclusion leakage
#: control). Resolved for context display only.
COMPETITOR_CONTEXT_FEATURES: tuple[str, ...] = _COMPETITOR_FEATURES

CANONICAL_CATEGORIES: tuple[str, ...] = CATEGORIES




def _bundle() -> CategoryBundle:
    return category_aware.load_bundle()


def match_business_type(value: str | None) -> str | None:
    """Map an entrepreneur-facing business-type string onto a model category.

    The UI offers free-form wording ("Café / Coffee Shop", "Fast Food"), while
    the model has four canonical classes. Unknown wording returns ``None`` —
    the caller then shows no category-specific claim rather than guessing.
    """
    text = (value or "").strip().lower().replace("é", "e").replace("è", "e")
    if not text:
        return None
    for cls in CANONICAL_CATEGORIES:
        if cls.lower() == text:
            return cls
    if "cafe" in text or "coffee" in text:
        return "Cafe / Coffee"
    if "restaurant" in text:
        return "Restaurant"
    if "bakery" in text or "dessert" in text or "beverage" in text or "drink" in text:
        return "Bakery / Dessert / Beverage"
    if "fast" in text or "takeaway" in text or "take-away" in text or "quick" in text:
        return "Fast Food / Takeaway"
    return None


def category_feature_names() -> list[str]:
    return list(_bundle().category_features)


def validation_summary(meta: dict[str, Any] | None = None) -> dict[str, Any]:
    """The selected model's geographic validation figures from the artifact.

    ``meta`` is accepted for backwards compatibility with callers that already
    hold a loaded artifact's metadata; the authoritative source is the bundle.
    """
    return category_aware.validation_summary(_bundle())


def _policy_split(missing: list[str]) -> tuple[list[str], list[str]]:
    imputable = [n for n in missing if n.startswith("residential_")]
    required = [n for n in missing if not n.startswith("residential_")]
    return imputable, required


def _payload(
    bundle: CategoryBundle,
    scores: dict[str, float],
    imputed: list[str],
    *,
    business_type: str | None = None,
) -> dict[str, Any]:
    """The response contract for one property's category probabilities."""
    ranked = sorted(scores.items(), key=lambda kv: -kv[1])
    payload: dict[str, Any] = {
        "available": True,
        "model_version": bundle.version,
        "model_kind": "research_only",
        "artifact": bundle.path.name,
        "artifact_sha256": bundle.sha256,
        "feature_count": len(bundle.category_features),
        "rankings": [
            {"business_type": cls, "score": round(score, 6), "rank": index + 1}
            for index, (cls, score) in enumerate(ranked)
        ],
        "top_category": ranked[0][0],
        "top_score": round(ranked[0][1], 6),
        "runner_up": ranked[1][0],
        "runner_up_score": round(ranked[1][1], 6),
        "imputed_features": imputed,
        "score_meaning": SCORE_MEANING,
        "research_only": True,
        "production_ready": bool(bundle.meta.get("production_ready", False)),
        "reliability": category_aware.validation_summary(bundle),
    }
    selected = match_business_type(business_type) if business_type else None
    if selected is not None and selected in scores:
        rank = next(
            (index + 1 for index, (cls, _) in enumerate(ranked) if cls == selected),
            None,
        )
        payload["selected_category"] = {
            "business_type": selected,
            "score": round(scores[selected], 6),
            "rank": rank,
            "is_model_top_category": selected == ranked[0][0],
        }
    return payload


def predict_categories(
    features: dict[str, Any], *, business_type: str | None = None
) -> dict[str, Any]:
    """Rank the four categories for one resolved feature vector.

    Raises ``ModelUnavailableError`` when a non-residential feature is missing
    or the vector is unusable — never returns a partial guess.
    """
    bundle = _bundle()
    names = bundle.category_features
    missing = [n for n in names if features.get(n) is None]
    imputable, required = _policy_split(missing)
    if required:
        raise ModelUnavailableError(
            "Observed non-residential features are required by the category "
            f"model contract: {required}"
        )

    import numpy as np

    values: list[float] = []
    for name in names:
        value = features.get(name)
        if value is None:
            values.append(float("nan"))
        else:
            if isinstance(value, bool):
                raise ModelUnavailableError(f"Feature {name} must be numeric")
            try:
                number = float(value)
            except (TypeError, ValueError) as exc:
                raise ModelUnavailableError(f"Feature {name} must be numeric") from exc
            if not math.isfinite(number):
                raise ModelUnavailableError(f"Feature {name} must be finite or explicitly missing")
            values.append(number)
    X = np.asarray([values], dtype=float)
    try:
        probabilities = np.asarray(bundle.category_model.predict_proba(X), dtype=float)
        classes = list(bundle.classes)
        if probabilities.shape != (1, len(classes)):
            raise ValueError(f"Unexpected predict_proba shape {probabilities.shape}")
        scores = {cls: float(probabilities[0, i]) for i, cls in enumerate(classes)}
    except (ValueError, TypeError, IndexError) as exc:
        raise ModelUnavailableError(f"Category inference failed: {exc}") from exc

    return _payload(bundle, scores, imputable, business_type=business_type)


def predict_categories_many(
    vectors: dict[str, dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    """Rank categories for MANY resolved vectors in ONE model call.

    Per-row sklearn calls cost ~37 ms each; a 955-candidate ranking would
    spend ~35 s in overhead alone. This builds one (N, 54) matrix, applies the
    same policy per row, and maps the probabilities back to per-property
    payloads identical to :func:`predict_categories`.
    """
    import numpy as np

    bundle = _bundle()
    names = bundle.category_features
    version = bundle.version
    results: dict[str, dict[str, Any]] = {}
    pending: list[tuple[str, list[float], list[str]]] = []

    for property_id, values in vectors.items():
        missing = [n for n in names if values.get(n) is None]
        imputable, required = _policy_split(missing)
        if required:
            results[property_id] = {
                "available": False,
                "model_version": version,
                "reason": {
                    "code": "category_inference_unavailable",
                    "message": (
                        "Observed non-residential features are required by the "
                        "category model contract: " + ", ".join(required)
                    ),
                },
                "research_only": True,
            }
            continue
        pending.append(
            (
                property_id,
                [
                    float(values[n]) if values.get(n) is not None else float("nan")
                    for n in names
                ],
                imputable,
            )
        )

    if pending:
        X = np.asarray([row for _, row, _ in pending], dtype=float)
        try:
            probabilities = np.asarray(bundle.category_model.predict_proba(X), dtype=float)
            classes = list(bundle.classes)
            if probabilities.shape != (len(pending), len(classes)):
                raise ValueError(f"Unexpected predict_proba shape {probabilities.shape}")
        except (ValueError, TypeError, IndexError) as exc:
            for property_id, _, _ in pending:
                results[property_id] = {
                    "available": False,
                    "model_version": version,
                    "reason": {
                        "code": "category_inference_unavailable",
                        "message": f"Category inference failed: {exc}",
                    },
                    "research_only": True,
                }
            return results
        for index, (property_id, _, imputable) in enumerate(pending):
            scores = {
                cls: float(probabilities[index, j]) for j, cls in enumerate(classes)
            }
            results[property_id] = _payload(bundle, scores, imputable)
    return results


#: Cache of per-property category results, keyed by
#: (model version, artifact sha256, property id). A replaced artifact can never
#: serve a previous model's ranking.
_CACHE: dict[tuple[str, str, str], dict[str, Any]] = {}
_CACHE_LOCK = threading.Lock()


def clear_category_cache() -> int:
    with _CACHE_LOCK:
        count = len(_CACHE)
        _CACHE.clear()
        return count


def competition_context(values: dict[str, Any]) -> dict[str, float]:
    """The excluded competitor counts, for display only — never model input."""
    out: dict[str, float] = {}
    for name in COMPETITOR_CONTEXT_FEATURES:
        value = values.get(name)
        if value is None:
            continue
        try:
            number = float(value)
        except (TypeError, ValueError):
            continue
        if math.isfinite(number):
            out[name] = number
    return out


def category_prediction(
    analytics_session: Session, property_id: str, *, business_type: str | None = None
) -> dict[str, Any]:
    """Resolve the 54 features for one catalogue property and rank categories.

    Failures are explicit (``available: false`` + reason). Successful results
    are cached per (model version, artifact checksum, property).
    """
    bundle = _bundle()
    cache_key = (bundle.version, bundle.sha256, str(property_id))
    with _CACHE_LOCK:
        cached = _CACHE.get(cache_key)
    if cached is not None:
        return cached

    resolution_features = list(bundle.category_features) + [
        n for n in COMPETITOR_CONTEXT_FEATURES if n not in bundle.category_features
    ]
    try:
        feature_bundle = PropertyFeatureRepository(analytics_session).get(
            str(property_id), resolution_features, source="catalog"
        )
        coverage = merge_bridge_features(feature_bundle, expected_features=resolution_features)
        coverage = merge_expanded_bridge_features(
            coverage, expected_features=resolution_features
        )
    except FeatureResolutionError as exc:
        return {
            "available": False,
            "model_version": bundle.version,
            "reason": {"code": "features_unresolved", "message": str(exc)},
            "research_only": True,
        }
    except Exception as exc:  # noqa: BLE001 - fail closed, never fabricate
        return {
            "available": False,
            "model_version": bundle.version,
            "reason": {
                "code": "features_unresolved",
                "message": f"{type(exc).__name__}: {exc}",
            },
            "research_only": True,
        }

    try:
        result = predict_categories(dict(coverage.values), business_type=business_type)
    except ModelUnavailableError as exc:
        return {
            "available": False,
            "model_version": bundle.version,
            "reason": {
                "code": "category_inference_unavailable",
                "message": str(exc),
                "missing_features": list(coverage.missing_features),
            },
            "research_only": True,
        }

    result["property_id"] = str(property_id)
    result["feature_coverage"] = {
        "available_features": sum(v is not None for v in coverage.values.values()),
        "feature_count": len(bundle.category_features),
        "missing_features": [
            n for n in bundle.category_features if coverage.values.get(n) is None
        ],
        "flags": list(coverage.flags),
    }
    result["competition_context_NOT_used_by_model"] = competition_context(
        dict(coverage.values)
    )
    with _CACHE_LOCK:
        _CACHE[cache_key] = result
    return result


def category_scores_from_coverage(
    coverage_by_id: dict[str, dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    """Rank categories for MANY properties from already-resolved coverage.

    The recommendation pipeline resolves the 64-feature contract once for a
    whole candidate set; the 54 category features are a subset, so no second
    database pass is needed and the whole batch runs in one model call. One
    model version serves the whole batch.
    """
    if not coverage_by_id:
        return {}
    vectors = {
        property_id: (coverage.get("values") or {})
        for property_id, coverage in coverage_by_id.items()
    }
    results = predict_categories_many(vectors)
    for property_id, result in results.items():
        if result.get("available"):
            result["property_id"] = property_id
            result["competition_context_NOT_used_by_model"] = competition_context(
                coverage_by_id[property_id].get("values") or {}
            )
    return results


# ---------------------------------------------------------------------------
# SHAP — conditional category explanation for the SELECTED business type
# ---------------------------------------------------------------------------


def category_explanation(
    features: dict[str, Any], business_type: str | None = None
) -> dict[str, Any]:
    """Permutation SHAP for the entrepreneur's selected category output.

    Explains the category model only — never the 64-feature PU score. When
    ``business_type`` is omitted the model's top category is explained, which is
    what the property page uses when the entrepreneur has no saved selection.
    The baseline + contributions must reconstruct the model's own probability
    within the package tolerance (1e-5); otherwise the explanation is refused.
    """
    bundle = _bundle()
    names = bundle.category_features
    missing = [n for n in names if features.get(n) is None]
    _, required = _policy_split(missing)
    if required:
        raise ModelUnavailableError(
            "SHAP requires every observed non-residential category feature: "
            + ", ".join(required)
        )
    if missing:
        raise ModelUnavailableError(
            "SHAP is withheld when residential measurements were imputed: "
            + ", ".join(missing)
        )

    scores = category_aware.category_probabilities(features, bundle)
    selected = match_business_type(business_type) if business_type else None
    if selected is None:
        selected = max(scores, key=scores.get)
    if selected not in scores:
        raise ModelUnavailableError(f"'{business_type}' is not a model category")

    explained = category_aware.explain_category(features, selected, bundle)
    return {
        "available": True,
        "model": CATEGORY_MODEL_NAME,
        "model_version": explained["model_version"],
        "artifact_sha256": explained["artifact_sha256"],
        "explainer": explained["explainer"],
        "explained_output": {
            "business_type": selected,
            "probability": round(explained["model_output"], 6),
            "is_model_top_category": selected == max(scores, key=scores.get),
        },
        "base_value": round(explained["base_value"], 6),
        "reconstructed": round(explained["reconstructed"], 6),
        "reconstruction_error": explained["additivity_error"],
        "additivity_tolerance": explained["additivity_tolerance"],
        "background_size": explained["background_size"],
        "contributions": [
            {"technical": item["technical"], "contribution": round(item["contribution"], 8)}
            for item in explained["contributions"]
        ],
        "research_only": True,
        "score_meaning": SCORE_MEANING,
    }
