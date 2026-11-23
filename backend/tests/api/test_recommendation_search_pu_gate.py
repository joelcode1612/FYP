"""Expanded64 eligibility and deterministic recommendation search ordering."""
from __future__ import annotations

import uuid

import pytest
from sitewise.ml import pu_expanded
from sitewise.services.recommendation_search_service import (
    PU_ELIGIBILITY_THRESHOLD,
    RecommendationSearchService,
    SearchCriteria,
    _rank_key,
    _Row,
)

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def user_token(client, cleanup_users) -> str:
    sub = uuid.uuid4()
    token = make_token(
        sub=str(sub),
        email=f"pu-gate-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}",
    )
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    register_user_id(cleanup_users, sub)
    return token


def test_default_search_returns_only_pu_eligible_properties(client, user_token):
    """A no-filter search applies the gate and still finds >= 3 properties."""
    response = client.post(
        "/api/v1/recommendations/search",
        headers=auth(user_token),
        json={},
    )
    assert response.status_code == 200, response.text
    body = response.json()

    items = body["data"]
    assert len(items) >= 3, "the catalogue has hundreds of PU-eligible rows"

    ids = [item["property_id"] for item in items]
    assert len(ids) == len(set(ids)), "no property may be recommended twice"

    for item in items:
        research = item["research"]
        assert research["pu_available"] is True
        assert research["pu_score"] is not None
        assert research["pu_score"] > PU_ELIGIBILITY_THRESHOLD
        assert research["pu_score_scale"] == "0-100"
        assert research["catalog_suitability_score"] is None
        assert research["pu_score_source"] == "expanded64_live_inference"
        assert research["pu_model_version"]

    meta = body["meta"]["pu_eligibility"]
    assert meta["threshold"] == PU_ELIGIBILITY_THRESHOLD
    assert meta["comparison"] == "strictly_greater_than"


def test_expanded_scores_gate_search_without_using_stored_scores(monkeypatch):
    predictions = {
        "exact": {"available": True, "score": 0.5},
        "above": {"available": True, "score": 0.500001},
        "below": {"available": True, "score": 0.499999},
        "high": {"available": True, "score": 0.8},
        "unavailable": {"available": False, "score": None},
    }
    rows = [
        _Row(
            id=pid, title=pid, address="", city="", state="Selangor", postcode="",
            rental_rm=3000, size_sqft=1000, latitude=None, longitude=None,
            property_type="Shoplot", image_url=None, suitability_score=99, matches=[],
        )
        for pid in predictions
    ]
    service = RecommendationSearchService(None)
    monkeypatch.setattr(service, "_query", lambda _: rows)
    monkeypatch.setattr(service, "_catalogue_revision", lambda: "expanded64-gate-test")
    monkeypatch.setattr(service, "_cache_get", lambda _: None)
    monkeypatch.setattr(service, "_cache_put", lambda *_: None)
    monkeypatch.setattr(pu_expanded, "expanded_scores_many", lambda *_: predictions)

    ranked = service._ranked_candidates(SearchCriteria())
    assert [row.id for row in ranked] == ["high", "above"]
    assert [row.pu_score for row in ranked] == pytest.approx([80, 50.0001])
    assert all(row.suitability_score is None for row in ranked)


def test_ordering_prefers_higher_pu_on_equal_requirement_fit():
    """Requirement fit stays primary; PU breaks ties (higher first)."""

    def row(property_id: str, rent: float, pu: float) -> _Row:
        return _Row(
            id=property_id,
            title=property_id,
            address="",
            city="",
            state="Selangor",
            postcode="",
            rental_rm=rent,
            size_sqft=1000,
            latitude=None,
            longitude=None,
            property_type="Shoplot",
            image_url=None,
            suitability_score=pu,
            matches=[],
        )

    cheaper_low_pu = row("A", 3000, 60.0)
    pricier_high_pu = row("B", 5000, 90.0)
    ordered = sorted([cheaper_low_pu, pricier_high_pu], key=_rank_key)
    assert [r.id for r in ordered] == ["B", "A"], (
        "equal requirement fit: higher PU must win before lower rent"
    )


def test_filters_compose_with_pu_gate(client, user_token):
    """Selected filters narrow the eligible set; the gate still applies."""
    response = client.post(
        "/api/v1/recommendations/search",
        headers=auth(user_token),
        json={
            "max_rental_rm": 8000,
            "preferred_state": "Selangor",
            "property_type": "Shoplot",
        },
    )
    assert response.status_code == 200, response.text
    items = response.json()["data"]
    for item in items:
        assert item["research"]["pu_score"] > PU_ELIGIBILITY_THRESHOLD
        assert item["rental_rm"] <= 8000
        assert item["state"] == "Selangor"
        assert item["property_type"] == "Shoplot"
