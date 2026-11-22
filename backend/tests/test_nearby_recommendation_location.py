"""Nearby recommendation opt-in contract: validated coordinates and radius."""
import pytest
from pydantic import ValidationError

from sitewise.api.v1.recommendations import RecommendationSearchRequest
from sitewise.services.recommendation_search_service import (
    SearchCriteria,
    _haversine_km,
    _within_nearby,
)
from types import SimpleNamespace


def test_contract_requires_complete_location_tuple():
    with pytest.raises(ValidationError):
        RecommendationSearchRequest(location_latitude=3.1)
    with pytest.raises(ValidationError):
        RecommendationSearchRequest(nearby_radius_km=5)
    assert RecommendationSearchRequest().location_latitude is None


def test_haversine_same_point_and_radius():
    assert _haversine_km(3.1, 101.6, 3.1, 101.6) < 0.001
    criteria = SearchCriteria(location_latitude=3.1, location_longitude=101.6, nearby_radius_km=5)
    near = SimpleNamespace(latitude=3.1, longitude=101.61)
    far = SimpleNamespace(latitude=4.0, longitude=101.6)
    missing = SimpleNamespace(latitude=None, longitude=None)
    assert _within_nearby(near, criteria)
    assert not _within_nearby(far, criteria)
    assert not _within_nearby(missing, criteria)


def test_location_part_of_pagination_fingerprint():
    normal = SearchCriteria().cache_payload()
    near = SearchCriteria(location_latitude=3.1, location_longitude=101.6, nearby_radius_km=5).cache_payload()
    assert normal != near
