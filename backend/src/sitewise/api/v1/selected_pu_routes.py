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
from sitewise.ml.feature_bridge import merge_bridge_features
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


def _coverage(session: Session, property_id: str):
    """Resolve features through the live DB + training bridge.

    Raises FeatureResolutionError (-> 404) only when the property or its
    analytical subject cannot be found. Partial feature coverage is NOT an
    error: it is returned as an explicit per-feature report the caller must
    act on (predictions stay unavailable; nothing is zero-filled).
    """
    loaded = ModelLoader().load(SELECTED_MODEL_NAME)
    bundle = PropertyFeatureRepository(session).get(
        property_id, loaded.feature_names, source='catalog'
    )
    return loaded, merge_bridge_features(bundle, expected_features=loaded.feature_names)


@router.get('/properties/{property_id}/coverage')
def selected_coverage(
    property_id: str, session: AnalyticsSession, _user: CurrentUser
) -> dict:
    """Explicit 47-feature coverage report for one catalogue property."""
    try:
        _loaded, coverage = _coverage(session, property_id)
    except FeatureResolutionError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    report = coverage.as_dict()
    report['inference_state'] = (
        'ready' if coverage.complete else 'unavailable_missing_training_features'
    )
    return report


@router.get('/properties/{property_id}/prediction')
def selected_prediction(
    property_id: str, session: AnalyticsSession, _user: CurrentUser
) -> dict:
    try:
        loaded, coverage = _coverage(session, property_id)
    except FeatureResolutionError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    features = {k: v for k, v in coverage.values.items() if v is not None}
    result = predict_selected(property_id, features)
    result['feature_coverage'] = coverage.as_dict()
    if not result.get('available'):
        # Controlled unavailable body (not an HTTP error): the missing-feature
        # list and the no-fabrication policy travel with every response.
        result.setdefault('reason', (
            'Missing required features: ' + ', '.join(coverage.missing_features)
        ))
        result['policy'] = (
            'No feature value is fabricated or zero-filled. The prediction '
            'stays unavailable until every saved feature resolves from a '
            'verified source.'
        )
    return result


@router.get('/properties/{property_id}/explanation')
def selected_explanation(
    property_id: str, session: AnalyticsSession, _user: CurrentUser
) -> dict:
    # SHAP is computationally expensive. Call on selected property detail only,
    # not once per list item. Add a cache/rate limit if exposed at scale.
    try:
        loaded, coverage = _coverage(session, property_id)
        if coverage.missing_features:
            return {
                'property_id': property_id,
                'available': False,
                'reason': (
                    'Missing required features: '
                    + ', '.join(coverage.missing_features)
                ),
                'missing_features': coverage.missing_features,
                'feature_coverage': coverage.as_dict(),
                'research_only': True,
            }
        with REFERENCE_CSV.open(encoding='utf-8-sig', newline='') as fp:
            background = list(csv.DictReader(fp))
        if not background:
            raise ModelUnavailableError('Real SHAP background is empty')
        return {
            'property_id': property_id,
            **explain_selected_payload(
                {k: v for k, v in coverage.values.items() if v is not None},
                background,
            ),
        }
    except FeatureResolutionError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (OSError, ModelUnavailableError) as exc:
        return {'property_id': property_id, 'available': False,
                'reason': str(exc), 'research_only': True}
