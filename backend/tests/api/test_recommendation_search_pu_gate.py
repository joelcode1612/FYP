"""PU eligibility gate for the recommendation search endpoint.

Verification matrix for the strict ``PU score > 50`` rule (0-100 scale):

* default searches return only PU-eligible properties, and at least three
  exist in the live catalogue;
* a score of exactly 50.0 is excluded; 50.0001 is included (fixture rows in a
  transaction that is ALWAYS rolled back — no catalogue row is modified);
* NULL scores can never occur (column NOT NULL) and a NULL would fail the
  gate anyway (``NULL > 50`` is NULL, not TRUE);
* ordering prefers the higher PU score among equally-fitting properties,
  while requirement fit stays the primary key;
* serialization reports the real PU score under both ``pu_score`` (explicit,
  with ``pu_score_scale``) and the legacy ``catalog_suitability_score`` name;
* filters compose with the gate and totals count only eligible rows.
"""
from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text

from sitewise.db.analytics_session import analytics_engine
from sitewise.services.recommendation_search_service import (
    PU_ELIGIBILITY_THRESHOLD,
    RecommendationSearchService,
    SearchCriteria,
    _rank_key,
    _Row,
)

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

FIXTURE_TITLE = "PU GATE FIXTURE"


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


def _fixture_row(property_id: str, score: float) -> dict:
    return {
        "id": property_id,
        "title": f"{FIXTURE_TITLE} {property_id}",
        "address": "1 Fixture Street",
        "state": "Selangor",
        "rental_rm": 5000,
        "size_sqft": 1200,
        "latitude": 3.07,
        "longitude": 101.6,
        "property_type": "Shoplot",
        "suitability_score": score,
        "dataset_validation": "test",
        "source_workbook": "test",
        "source_sheet": "test",
        "source_row": 1,
        "source_data": "{}",
    }


INSERT_SQL = text(
    """
    INSERT INTO sitewise_app.properties (
        id, title, address, state, rental_rm, size_sqft, latitude, longitude,
        property_type, suitability_score, dataset_validation, source_workbook,
        source_sheet, source_row, source_data
    ) VALUES (
        :id, :title, :address, :state, :rental_rm, :size_sqft, :latitude,
        :longitude, :property_type, :suitability_score, :dataset_validation,
        :source_workbook, :source_sheet, :source_row, CAST(:source_data AS jsonb)
    )
    """
)


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
        # Both names must report the same stored score.
        assert research["pu_score"] == research["catalog_suitability_score"]

    meta = body["meta"]["pu_eligibility"]
    assert meta["threshold"] == PU_ELIGIBILITY_THRESHOLD
    assert meta["comparison"] == "strictly_greater_than"

    with analytics_engine.connect() as conn:
        eligible = conn.execute(
            text(
                "SELECT count(*) FROM sitewise_app.properties "
                "WHERE rental_rm IS NOT NULL AND size_sqft IS NOT NULL "
                "AND suitability_score > :t"
            ),
            {"t": PU_ELIGIBILITY_THRESHOLD},
        ).scalar()
    assert body["pagination"]["total"] == eligible


def test_boundary_50_excluded_50_plus_included():
    """Strictness at the boundary, plus PU-desc ordering, on fixture rows.

    The transaction is rolled back unconditionally — the live catalogue is
    never modified.
    """
    with analytics_engine.connect() as conn:
        transaction = conn.begin()
        try:
            for property_id, score in (
                ("TEST-PU-0500", 50.0),      # exactly at threshold -> excluded
                ("TEST-PU-0501", 50.0001),   # just above -> included
                ("TEST-PU-0499", 49.9999),   # just below -> excluded
                ("TEST-PU-0800", 80.0),      # included, should rank first
            ):
                conn.execute(INSERT_SQL, _fixture_row(property_id, score))

            service = RecommendationSearchService(conn)
            result = service.search(
                SearchCriteria(query=FIXTURE_TITLE, page_size=20)
            )
            ids = [item["property_id"] for item in result["data"]]

            assert ids == ["TEST-PU-0800", "TEST-PU-0501"], ids
            assert result["pagination"]["total"] == 2
            scores = [item["research"]["pu_score"] for item in result["data"]]
            assert scores == [80.0, 50.0001]
        finally:
            transaction.rollback()


def test_pu_column_is_not_null_and_gate_excludes_nulls():
    """The schema forbids NULL PU scores; the SQL gate would exclude them."""
    with analytics_engine.connect() as conn:
        nullable = conn.execute(
            text(
                "SELECT is_nullable FROM information_schema.columns "
                "WHERE table_schema='sitewise_app' AND table_name='properties' "
                "AND column_name='suitability_score'"
            )
        ).scalar()
    assert nullable == "NO"
    # NULL > 50 evaluates to NULL (not TRUE): a null score can never pass the
    # WHERE clause. Assert the SQL semantics explicitly.
    with analytics_engine.connect() as conn:
        passes = conn.execute(
            text("SELECT CAST(NULL AS double precision) > :t"),
            {"t": PU_ELIGIBILITY_THRESHOLD},
        ).scalar()
    assert passes is None


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
