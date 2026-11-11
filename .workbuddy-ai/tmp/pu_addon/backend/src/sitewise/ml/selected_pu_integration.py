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
