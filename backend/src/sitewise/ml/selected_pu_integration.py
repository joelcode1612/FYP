"""Optional second SiteWise research PU model. Leaves the default PU model unchanged.

IMPORTANT: this is an alternate Layer-1 P-vs-U model, not Layer-2 personalised
recommendation. SHAP explains this research score, not business success.

Feature coverage (Phase: Layer 1 completion)
--------------------------------------------
``feature_coverage`` combines the live database (duplicate-population-safe
after the ``property_features`` fix) with the committed original-training
bridge file. It reports every feature's value and provenance and NEVER
fabricates a value: for properties whose 47th feature
(``worldpop_walk_reachable_10min``) cannot be recovered the prediction state
is explicitly ``unavailable`` with the exact blocking features listed.
"""
from __future__ import annotations

from sqlmodel import Session

from sitewise.ml.feature_bridge import merge_bridge_features
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import PropertyFeatureBundle, PropertyFeatureRepository
from sitewise.ml.pu_learning import PULearning
from sitewise.ml.shap_explainer import ShapExplainer

SELECTED_MODEL_NAME = "sitewise_selected_pu_model"


def selected_metadata() -> dict:
    loaded = ModelLoader().load(SELECTED_MODEL_NAME)
    return {
        "name": SELECTED_MODEL_NAME,
        "artifact": loaded.meta.get("artifact_filename"),
        "feature_set": loaded.meta.get("feature_set"),
        "model_version": loaded.meta.get("model_version"),
        "features": loaded.feature_names,
        "research_only": True,
        "score_meaning": loaded.meta.get("score_meaning"),
    }


def feature_coverage(analytics_session: Session, property_id: str) -> dict:
    """Resolve the exact saved feature vector for one catalogue property.

    Returns the full 47-feature coverage report: every value with its source,
    the missing features, and which of those are documented unrecoverable.
    """
    loaded = ModelLoader().load(SELECTED_MODEL_NAME)
    bundle: PropertyFeatureBundle = PropertyFeatureRepository(analytics_session).get(
        property_id, loaded.feature_names, source="catalog"
    )
    coverage = merge_bridge_features(bundle, expected_features=loaded.feature_names)
    report = coverage.as_dict()
    report["model"] = {
        "name": SELECTED_MODEL_NAME,
        "feature_set": loaded.meta.get("feature_set"),
        "research_only": True,
    }
    report["inference_state"] = (
        "ready" if coverage.complete else "unavailable_missing_training_features"
    )
    return report


def predict_live(analytics_session: Session, property_id: str) -> dict:
    """In-sample research prediction from resolved features, or explicit unavailable.

    No value is ever fabricated or zero-filled. When the 47-feature vector is
    incomplete the response states ``available: false`` with the exact
    blocking features (currently ``worldpop_walk_reachable_10min`` for every
    property, since no available data source holds it).
    """
    coverage_report = feature_coverage(analytics_session, property_id)
    features = {
        name: value
        for name, value in coverage_report["values"].items()
        if value is not None
    }
    result = PULearning(model_name=SELECTED_MODEL_NAME).predict_or_report(
        property_id, features, allow_model_imputation=False
    )
    result["feature_coverage"] = {
        key: coverage_report[key]
        for key in (
            "feature_count", "available_features", "complete", "missing_features",
            "unrecoverable_features", "value_sources", "flags",
        )
    }
    result["inference_state"] = coverage_report["inference_state"]
    if not result.get("available"):
        result["policy"] = (
            "No feature value is fabricated or zero-filled. The live prediction "
            "stays unavailable until the listed features are supplied by a "
            "verified source; the stored per-property research_p_association_score "
            "remains the ranking input meanwhile."
        )
    return result


def predict_selected(property_id: str, features: dict) -> dict:
    # Strict by default: does not silently equate missing features with zero.
    return PULearning(model_name=SELECTED_MODEL_NAME).predict_or_report(
        property_id, features, allow_model_imputation=False
    )


def explain_selected(features: dict, background: list[dict]) -> dict:
    # Reuses your EXISTING ShapExplainer; no duplicate SHAP implementation.
    return ShapExplainer(model_name=SELECTED_MODEL_NAME).explain(
        features, background=background
    )


def explain_selected_payload(features: dict, background: list[dict]) -> dict:
    """The existing SHAP engine's result reshaped into the API contract.

    Purely additive formatting on top of [explain_selected]: baseline +
    sum(contributions) still reconstruct the model's positive-label
    association (verified in tests). The explanation scope is stated
    explicitly so a SHAP contribution can never be presented as a
    Layer-2 personalised preference explanation.
    """
    raw = explain_selected(features, background)
    contributions = {
        str(name): float(value)
        for name, value in (raw.get("contributions") or {}).items()
    }
    ordered = sorted(contributions.items(), key=lambda kv: kv[1], reverse=True)
    return {
        "model_name": str(raw.get("model") or SELECTED_MODEL_NAME),
        "explainer": raw.get("explainer"),
        "score": raw.get("positive_label_association"),
        "baseline": raw.get("baseline_association"),
        "contributions": contributions,
        "top_positive_features": [
            {"feature": name, "contribution": value}
            for name, value in ordered
            if value > 0
        ][:10],
        "top_negative_features": [
            {"feature": name, "contribution": value}
            for name, value in reversed(ordered)
            if value < 0
        ][:10],
        "score_meaning": raw.get("score_meaning"),
        "background_size": raw.get("background_size"),
        "research_only": True,
        "explanation_scope": (
            "SHAP explains the research PU model's positive-label association. "
            "It is NOT a personalised preference explanation and NOT a "
            "prediction of restaurant success or profitability."
        ),
    }
