"""Additive research endpoints for the optional selected PU model.

Mounted at /ml/selected. Requires normal authentication and reuses the current
read-only analytics repository and SHAP engine. Does not alter existing routes.
"""
from __future__ import annotations

import csv
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.db.analytics_session import get_analytics_db
from sitewise.dependencies import CurrentUser
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import FeatureResolutionError, PropertyFeatureRepository
from sitewise.ml.selected_pu_integration import (
    SELECTED_MODEL_NAME, selected_metadata, predict_selected, explain_selected_payload
)

router = APIRouter()
AnalyticsSession = Annotated[Session, Depends(get_analytics_db)]
REFERENCE_CSV = Path(__file__).resolve().parents[4] / 'ml_reference' / 'shap_background_47.csv'


@router.get('/model')
def model_info(_user: CurrentUser) -> dict:
    return selected_metadata()


def _features(session: Session, property_id: str):
    loaded = ModelLoader().load(SELECTED_MODEL_NAME)
    resolved = PropertyFeatureRepository(session).get(
        property_id, loaded.feature_names, source='catalog'
    )
    if resolved.missing_features:
        raise ModelUnavailableError(
            'Missing required features: ' + ', '.join(resolved.missing_features)
        )
    return resolved


@router.get('/properties/{property_id}/prediction')
def selected_prediction(
    property_id: str, session: AnalyticsSession, _user: CurrentUser
) -> dict:
    try:
        resolved = _features(session, property_id)
        return {
            'model_name': SELECTED_MODEL_NAME,
            **resolved.as_coverage(),
            **predict_selected(property_id, resolved.values),
        }
    except FeatureResolutionError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ModelUnavailableError as exc:
        return {'property_id': property_id, 'available': False, 'score': None,
                'reason': str(exc), 'research_only': True}


@router.get('/properties/{property_id}/explanation')
def selected_explanation(
    property_id: str, session: AnalyticsSession, _user: CurrentUser
) -> dict:
    # SHAP is computationally expensive. Call on selected property detail only,
    # not once per list item. Add a cache/rate limit if exposed at scale.
    try:
        resolved = _features(session, property_id)
        with REFERENCE_CSV.open(encoding='utf-8-sig', newline='') as fp:
            background = list(csv.DictReader(fp))
        if not background:
            raise ModelUnavailableError('Real SHAP background is empty')
        return {
            'property_id': property_id,
            **explain_selected_payload(resolved.values, background),
        }
    except FeatureResolutionError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (OSError, ModelUnavailableError) as exc:
        return {'property_id': property_id, 'available': False,
                'reason': str(exc), 'research_only': True}
