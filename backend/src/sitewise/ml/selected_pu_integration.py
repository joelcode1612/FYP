"""Optional second SiteWise research PU model. Leaves the default PU model unchanged.

IMPORTANT: this is an alternate Layer-1 P-vs-U model, not Layer-2 personalised
recommendation. SHAP explains this research score, not business success.
"""
from __future__ import annotations

from sitewise.ml.model_loader import ModelLoader
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
