"""Compare module regression tests — dual id universes, ordering, errors.

These run against the real local database (``Final_Location_Analysis``), the
same engine the endpoint uses, because the contract under test is property
RESOLUTION: catalogue ids (EP-/MD-) and operational numeric ids
(``fyp.rental_properties``, approved + published only) must both resolve, in
selection order, with accurate unresolved information.
"""

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine
from sitewise.db.session import engine
from sitewise.services.property_compare_service import PropertyCompareService
from tests.conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def user_token(client, cleanup_users):
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"compare-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}"
    token = make_token(sub=str(sub), email=email)
    response = client.get("/api/v1/auth/me", headers=auth(token))
    assert response.status_code == 200, response.text
    return token


@pytest.fixture()
def catalogue_ids():
    """Three real catalogue ids, preferentially ones with measurements."""
    with Session(analytics_engine) as session:
        rows = session.execute(
            text(
                """
                SELECT p.id FROM fyp.catalogue_properties p
                WHERE p.rental_rm > 0 AND p.size_sqft > 0
                ORDER BY p.id LIMIT 5
                """
            )
        ).all()
    ids = [r[0] for r in rows]
    assert len(ids) >= 3, "catalogue has too few properties in this database"
    return ids[:3]


@pytest.fixture()
def operational_ids():
    """Two real approved+published numeric listing ids."""
    with Session(engine) as session:
        rows = session.execute(
            text(
                """
                SELECT id::text FROM fyp.rental_properties
                WHERE is_published AND verification_status = 'approved'
                ORDER BY id LIMIT 2
                """
            )
        ).all()
    ids = [r[0] for r in rows]
    assert len(ids) == 2, "no approved+published operational rows"
    return ids


@pytest.fixture()
def unapproved_numeric_id():
    with Session(engine) as session:
        row = session.execute(
            text(
                """
                SELECT id::text FROM fyp.rental_properties
                WHERE NOT (is_published AND verification_status = 'approved')
                ORDER BY id LIMIT 1
                """
            )
        ).first()
    assert row is not None
    return row[0]


# ---------------------------------------------------------------------------
# Endpoint behaviour
# ---------------------------------------------------------------------------


def test_compare_requires_authentication(client, catalogue_ids):
    r = client.post("/api/v1/compare", json={"property_ids": catalogue_ids[:2]})
    assert r.status_code == 401, r.text


def test_compare_single_id_is_422(client, user_token, catalogue_ids):
    r = client.post(
        "/api/v1/compare",
        headers=auth(user_token),
        json={"property_ids": catalogue_ids[:1]},
    )
    assert r.status_code == 422


def test_compare_more_than_three_is_422(client, user_token, catalogue_ids):
    r = client.post(
        "/api/v1/compare",
        headers=auth(user_token),
        json={"property_ids": catalogue_ids + [catalogue_ids[0]]},
    )
    assert r.status_code == 422


def test_compare_duplicate_ids_are_422(client, user_token, catalogue_ids):
    r = client.post(
        "/api/v1/compare",
        headers=auth(user_token),
        json={"property_ids": [catalogue_ids[0], catalogue_ids[0]]},
    )
    assert r.status_code == 422


def test_compare_invalid_id_format_is_unresolved_not_500(
    client, user_token, catalogue_ids
):
    r = client.post(
        "/api/v1/compare",
        headers=auth(user_token),
        json={"property_ids": [catalogue_ids[0], "not-an-id"]},
    )
    assert r.status_code == 200, r.text
    body = r.json()["data"]
    assert body["resolved_count"] == 1
    assert body["unresolved_ids"] == ["not-an-id"]
    reasons = {row["id"]: row["reason"] for row in body["unresolved_details"]}
    assert "not a recognised" in reasons["not-an-id"].lower()


# ---------------------------------------------------------------------------
# Resolution contract
# ---------------------------------------------------------------------------


def test_catalogue_compare_resolves_in_selection_order(
    client, user_token, catalogue_ids
):
    selected = [catalogue_ids[2], catalogue_ids[0]]
    r = client.post(
        "/api/v1/compare", headers=auth(user_token), json={"property_ids": selected}
    )
    assert r.status_code == 200, r.text
    body = r.json()["data"]
    assert body["resolved_count"] == 2
    assert [p["property_id"] for p in body["properties"]] == selected


def test_operational_numeric_ids_resolve_from_rental_properties(
    client, user_token, operational_ids
):
    r = client.post(
        "/api/v1/compare", headers=auth(user_token), json={"property_ids": operational_ids}
    )
    assert r.status_code == 200, r.text
    body = r.json()["data"]
    assert body["resolved_count"] == 2
    assert body["unresolved_ids"] == []
    first = body["properties"][0]
    assert first["verification"]["verified_listing"] is True
    assert first["verification"]["provenance"] == "operational_verified_listing"
    # The row's own rental is a real measurement, never a fabricated one.
    rent = first["metrics"]["monthly_rent_rm"]
    assert rent["available"] is True and rent["value"] > 0


def test_unapproved_operational_id_is_unresolved_with_access_reason(
    client, user_token, catalogue_ids, unapproved_numeric_id
):
    r = client.post(
        "/api/v1/compare",
        headers=auth(user_token),
        json={"property_ids": [catalogue_ids[0], unapproved_numeric_id]},
    )
    assert r.status_code == 200, r.text
    body = r.json()["data"]
    assert body["resolved_count"] == 1
    reasons = {row["id"]: row["reason"] for row in body["unresolved_details"]}
    assert "published" in reasons[unapproved_numeric_id].lower()
    # A pending listing's data is never leaked through the compare payload.
    assert unapproved_numeric_id not in {p["property_id"] for p in body["properties"]}


def test_mixed_universes_preserve_selection_order_and_share_metrics(
    client, user_token, catalogue_ids, operational_ids
):
    selected = [operational_ids[0], catalogue_ids[0], operational_ids[1]]
    r = client.post(
        "/api/v1/compare", headers=auth(user_token), json={"property_ids": selected}
    )
    assert r.status_code == 200, r.text
    body = r.json()["data"]
    assert [p["property_id"] for p in body["properties"]] == selected
    # Both universes expose the SAME metric keys — the UI renders one table.
    keys_a = set(body["properties"][0]["metrics"])
    keys_b = set(body["properties"][1]["metrics"])
    assert keys_a == keys_b, "both id universes must expose identical metric keys"


# ---------------------------------------------------------------------------
# Measurement honesty
# ---------------------------------------------------------------------------


def test_missing_geospatial_data_is_reported_not_zeroed():
    """A candidate without measurements yields unavailable metrics + gaps."""
    from sitewise.repositories.recommendation_candidate_repository import (
        RecommendationCandidateRepository,
    )

    bare = {
        "property_id": "MD-TEST",
        "title": "Bare",
        "source_data": {},
        "subject_doc": {},
        "population_doc": {},
        "listing_id": None,
        "listing_detail_available": None,
    }
    mapped = RecommendationCandidateRepository(Session(analytics_engine))._map(bare)
    svc = PropertyCompareService(Session(analytics_engine), Session(engine))
    prop = svc._property(mapped, {}, {"verified_listing": False}, dict(
        __import__(
            "sitewise.services.property_insights_service", fromlist=["PANORAMA_UNAVAILABLE"]
        ).PANORAMA_UNAVAILABLE
    ))
    rent = prop["metrics"]["monthly_rent_rm"]
    assert rent["available"] is False and rent["value"] is None
    assert rent["display"] == "Data not available"
    assert prop["data_gaps"], "every missing measurement must be explained"
    assert prop["availability"]["confirmed"] is False


def test_unavailable_research_status_produces_notice_not_silence():
    svc = PropertyCompareService(Session(analytics_engine), Session(engine))
    candidate = {
        "property_id": "MD-TEST",
        "title": "Rented",
        "availability_status": "RENTED",
        "source_data": {"property_availability_status": "RENTED"},
        "subject_doc": {},
        "population_doc": {},
    }
    prop = svc._property(candidate, {}, {}, dict(
        __import__(
            "sitewise.services.property_insights_service", fromlist=["PANORAMA_UNAVAILABLE"]
        ).PANORAMA_UNAVAILABLE
    ))
    assert prop["availability"]["confirmed"] is False
    assert "RENTED" in (prop["availability"]["notice"] or "")


def test_radius_provenance_prevents_1km_displayed_as_500m():
    """A 1 km fallback value must surface radius_m=1000, never 500."""
    svc = PropertyCompareService(Session(analytics_engine), Session(engine))
    candidate = {
        "property_id": "MD-TEST",
        "title": "Fallback",
        "subject_doc": {"other_features": {"universities_count_1km": 7}},
        "source_data": {},
        "population_doc": {},
    }
    from sitewise.repositories.recommendation_candidate_repository import (
        RecommendationCandidateRepository,
    )

    mapped = RecommendationCandidateRepository(Session(analytics_engine))._map(candidate)
    assert mapped["universities_count_500m"] == 7.0
    assert mapped["universities_count_500m_radius_m"] == 1000
    prop = svc._property(mapped, {}, {}, {})
    metric = prop["metrics"]["universities_count_500m"]
    assert metric["available"] is True
    assert metric["radius_m"] == 1000


def test_metric_value_channel_is_numeric_only():
    """The Dart entity casts metric `value` to num? — a recorded parking
    flag (bool) or floor-level text must ride `display`, never `value`."""
    svc = PropertyCompareService(Session(analytics_engine), Session(engine))
    candidate = {
        "property_id": "MD-TEST",
        "title": "Facts",
        "source_data": {"property_availability_status": "VERIFIED_AVAILABLE"},
        "subject_doc": {},
        "population_doc": {},
    }
    prop = svc._property(candidate, {}, {"has_parking": True, "floor_level": "G"}, {})
    for key, metric in prop["metrics"].items():
        assert metric["value"] is None or (
            isinstance(metric["value"], (int, float))
            and not isinstance(metric["value"], bool)
        ), f"{key} smuggled a non-numeric value: {metric['value']!r}"
    # The facts still reach the user through the display channel.
    assert prop["metrics"]["has_parking"]["display"] == "Yes"
    assert prop["metrics"]["has_parking"]["available"] is True
    assert prop["metrics"]["floor_level_text"]["display"] == "G"


# ---------------------------------------------------------------------------
# Fit against the caller's saved requirements
# ---------------------------------------------------------------------------


def _bare_property(rent=None, area=None, parking=None):
    """A property dict shaped like ``_property`` output for fit tests.

    Only the three channels the fit rows read are built; the display text
    follows the same type rules the real service applies.
    """
    unavailable = {"value": None, "available": False, "display": "Data not available"}
    return {
        "property_id": "MD-FIT",
        "title": "Fit",
        "property_type": "Shop office",
        "metrics": {
            "monthly_rent_rm": unavailable
            if rent is None
            else {
                "value": rent,
                "available": True,
                "display": f"{rent:,} RM / month",
            },
            "size_sqft": unavailable
            if area is None
            else {
                "value": area,
                "available": True,
                "display": f"{area:,} sq ft",
            },
            "has_parking": unavailable
            if parking is None
            else {
                "value": None,
                "available": True,
                "display": "Yes" if parking else "No",
            },
        },
    }


def test_fit_rows_state_bounds_and_never_a_score():
    from sitewise.domain.recommendation_scoring import preference_profile_from

    svc = PropertyCompareService(Session(analytics_engine), Session(engine))
    prop = _bare_property(rent=6000, area=900)
    profile = preference_profile_from(
        {
            "max_monthly_rent_myr": 5000,
            "min_floor_area_sqft": 1200,
            "property_type": ["Shophouse"],
            "requirements": ["customer parking", "wheelchair access"],
            "preferred_state": "Selangor",
        }
    )
    rows = {row["key"]: row for row in svc._preference_fit(prop, profile)}
    assert rows["budget"]["status"] == "outside"
    assert "RM 1,000 above" in rows["budget"]["detail"]
    assert rows["floor_area"]["status"] == "outside"
    assert rows["property_type"]["status"] == "differs"
    # Saved but unverifiable: parking is only recorded on verified listings.
    assert rows["parking"]["status"] == "not_recorded"
    assert "wheelchair" not in rows["parking"]["detail"]
    # A stated accessibility need has no measurement in either source.
    assert rows["accessibility"]["status"] == "not_capturable"
    # Location stays in Recommendations; this page never re-ranks on it.
    assert "location" not in rows
    for row in rows.values():
        assert row["status"] in {
            "meets",
            "outside",
            "differs",
            "not_stated",
            "not_recorded",
            "not_capturable",
        }


def test_fit_rows_pass_on_recorded_values_inside_the_saved_bounds():
    from sitewise.domain.recommendation_scoring import preference_profile_from

    svc = PropertyCompareService(Session(analytics_engine), Session(engine))
    prop = _bare_property(rent=4000, area=1500, parking=True)
    profile = preference_profile_from(
        {
            "max_monthly_rent_myr": 5000,
            "min_floor_area_sqft": 1200,
            "property_type": ["shop office"],
            "requirements": ["customer parking"],
        }
    )
    rows = {row["key"]: row for row in svc._preference_fit(prop, profile)}
    assert rows["budget"]["status"] == "meets"
    assert rows["floor_area"]["status"] == "meets"
    # Exact recorded text, no fuzzy similarity claim.
    assert rows["property_type"]["status"] == "meets"
    assert rows["parking"]["status"] == "meets"
    # A recorded "No" is a mismatch, not a missing value.
    no_parking = {
        row["key"]: row
        for row in svc._preference_fit(
            _bare_property(rent=4000, area=1500, parking=False), profile
        )
    }
    assert no_parking["parking"]["status"] == "differs"
    # Nothing stated at all: the requirement, not the property, is missing.
    empty = preference_profile_from(None)
    blank = {row["key"]: row for row in svc._preference_fit(prop, empty)}
    assert {row["status"] for row in blank.values()} == {"not_stated"}


def test_compare_without_saved_requirements_offers_no_fit_rows(
    client, user_token, catalogue_ids
):
    r = client.post(
        "/api/v1/compare", headers=auth(user_token), json={"property_ids": catalogue_ids[:2]}
    )
    assert r.status_code == 200, r.text
    body = r.json()["data"]
    basis = body["preference_fit_basis"]
    assert basis["saved"] is False
    assert "not available" in basis["statement"].lower()
    assert basis["not_compared"], "skipped checks must be stated, not hidden"
    for prop in body["properties"]:
        assert prop["preference_fit"] == []


def test_compare_reports_fit_for_the_signed_in_account(
    monkeypatch, client, user_token, catalogue_ids
):
    from sitewise.api.v1 import compare as compare_api

    seen = {}

    def fake_payload(self, user_id):
        seen["user_id"] = user_id
        return {
            "preferences": {
                "max_monthly_rent_myr": 1,
                "min_floor_area_sqft": 99_000_000,
            }
        }

    monkeypatch.setattr(compare_api.PreferencesService, "payload", fake_payload)
    r = client.post(
        "/api/v1/compare",
        headers=auth(user_token),
        json={"property_ids": catalogue_ids[:2]},
    )
    assert r.status_code == 200, r.text
    # The bounds are read for the AUTHENTICATED identity, never from the body.
    assert isinstance(seen["user_id"], uuid.UUID)
    body = r.json()["data"]
    assert body["preference_fit_basis"]["saved"] is True
    for prop in body["properties"]:
        rows = {row["key"]: row for row in prop["preference_fit"]}
        assert rows["budget"]["status"] == "outside"
        assert rows["floor_area"]["status"] == "outside"
