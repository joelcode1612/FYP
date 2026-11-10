"""Authenticated, read-only research-PU endpoints for catalogue properties.

Do not use their scores as verified commercial-success probabilities or
personalized suitability ranks. Keep the approved assessment workflow separate.
"""
from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.db.analytics_session import get_analytics_db
from sitewise.dependencies import CurrentUser
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import FeatureResolutionError
from sitewise.ml.property_predictor import PropertyPUPredictor

router = APIRouter()
AnalyticsSession = Annotated[Session, Depends(get_analytics_db)]


@router.get("/model")
def model_metadata(_user: CurrentUser) -> dict:
    try:
        loaded = ModelLoader().load()
    except ModelUnavailableError as exc:
        return {"available": False, "reason": str(exc), "research_only": True}
    return {
        "available": True,
        "model": "pu_model",
        "artifact": loaded.meta.get("artifact_filename"),
        "feature_set": loaded.meta.get("feature_set"),
        "feature_count": len(loaded.feature_names),
        "model_kind": getattr(loaded.model, "kind", None),
        "score_meaning": loaded.meta.get("score_meaning"),
        "experiment_tag": loaded.meta.get("experiment_tag"),
        "research_only": True,
        "calibrated_probability": bool(loaded.meta.get("is_calibrated_PU_class_prior", False)),
    }


@router.get("/properties/{property_id}/coverage")
def feature_coverage(
    property_id: str,
    session: AnalyticsSession,
    _user: CurrentUser,
) -> dict:
    try:
        return PropertyPUPredictor(session).coverage(property_id, "catalog")
    except FeatureResolutionError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ModelUnavailableError as exc:
        return {"property_id": property_id, "available": False, "reason": str(exc)}


@router.get("/properties/{property_id}/prediction")
def predict_catalog_property(
    property_id: str,
    session: AnalyticsSession,
    _user: CurrentUser,
) -> dict:
    """A research positive-label association, never a success probability."""
    try:
        return PropertyPUPredictor(session).predict(property_id, "catalog")
    except FeatureResolutionError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ModelUnavailableError as exc:
        return {
            "property_id": property_id,
            "available": False,
            "score": None,
            "reason": str(exc),
            "research_only": True,
        }
