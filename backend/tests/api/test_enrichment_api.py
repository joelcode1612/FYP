"""Enrichment API: two phases, stored state, retry, and the submit guard.

Covers:
  POST /enrich with an explicit phase runs only that phase
  POST /enrich with no body keeps the legacy "all" behaviour
  GET  /enrichment reads stored state and never recalculates
  POST /enrichment/{category}/retry validates the category
  ownership scoping (403 for another owner, 404 for a missing listing)
  submit requires an explicit acknowledgement when population is unavailable

Each test creates its own draft and deletes it afterwards.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def cleanup_listings(cleanup_users):
    props: list[int] = []
    yield props
    with Session(engine) as session:
        if props:
            for table in (
                "verification_audit",
                "verification_document",
                "property_verification",
            ):
                session.execute(
                    text(f"DELETE FROM {table} WHERE property_id = ANY(:ids)"),
                    {"ids": props},
                )
            session.execute(
                text(
                    "DELETE FROM fyp.property_enrichment_category "
                    "WHERE property_id = ANY(:ids)"
                ),
                {"ids": props},
            )
            session.execute(
                text(
                    "DELETE FROM fyp.property_geospatial_features "
                    "WHERE property_id = ANY(:ids)"
                ),
                {"ids": props},
            )
            session.execute(
                text("DELETE FROM fyp.rental_properties WHERE id = ANY(:ids)"),
                {"ids": props},
            )
        session.commit()


def _owner(client, cleanup_users, tag: str) -> dict:
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub,
        email=f"enrich-{tag}-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": f"Enrich {tag}"},
    )
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    register_user_id(cleanup_users, uuid.UUID(sub))
    return {"token": token, "sub": sub}


@pytest.fixture()
def owner(client, cleanup_users):
    return _owner(client, cleanup_users, "owner")


@pytest.fixture()
def other_owner(client, cleanup_users):
    return _owner(client, cleanup_users, "other")


@pytest.fixture()
def listing(client, owner, cleanup_listings):
    """A draft with a real KL coordinate, ready to enrich."""
    response = client.post(
        "/api/v1/properties/listings/drafts",
        headers=auth(owner["token"]),
        json={
            "name": "Enrichment test shoplot",
            "property_type": "Shoplot",
            "latitude": 3.030927,
            "longitude": 101.618782,
        },
    )
    assert response.status_code == 201, response.text
    pid = int(response.json()["data"]["id"])
    cleanup_listings.append(pid)
    return pid


# ---------------------------------------------------------------------------
# Phase control
# ---------------------------------------------------------------------------


def test_phase_postgis_runs_only_phase_one(client, owner, listing):
    response = client.post(
        f"/api/v1/properties/listings/{listing}/enrich",
        headers=auth(owner["token"]),
        json={"phase": "postgis"},
    )
    assert response.status_code == 200, response.text
    states = response.json()["data"]["categories"]

    for category in ("fnb_competitors", "demand_generators", "roads_transport", "parking"):
        assert states[category]["status"] == "current", category
    assert states["population"]["status"] == "pending"


def test_phase_population_runs_only_phase_two(client, owner, listing):
    response = client.post(
        f"/api/v1/properties/listings/{listing}/enrich",
        headers=auth(owner["token"]),
        json={"phase": "population"},
    )
    assert response.status_code == 200, response.text
    states = response.json()["data"]["categories"]

    assert states["population"]["status"] in ("current", "unavailable")
    assert states["fnb_competitors"]["status"] == "pending"


def test_no_body_keeps_the_legacy_behaviour(client, owner, listing):
    response = client.post(
        f"/api/v1/properties/listings/{listing}/enrich",
        headers=auth(owner["token"]),
    )
    assert response.status_code == 200, response.text
    body = response.json()["data"]
    assert body["phase1"]["complete"] is True
    assert body["phase2"]["complete"] is True


def test_unknown_phase_is_rejected(client, owner, listing):
    response = client.post(
        f"/api/v1/properties/listings/{listing}/enrich",
        headers=auth(owner["token"]),
        json={"phase": "raster"},
    )
    assert response.status_code == 422


# ---------------------------------------------------------------------------
# Stored state is read-only
# ---------------------------------------------------------------------------


def test_reading_state_never_recalculates(client, owner, listing):
    client.post(
        f"/api/v1/properties/listings/{listing}/enrich",
        headers=auth(owner["token"]),
        json={"phase": "postgis"},
    )
    first = client.get(
        f"/api/v1/properties/listings/{listing}/enrichment",
        headers=auth(owner["token"]),
    )
    assert first.status_code == 200, first.text
    before = first.json()["data"]["categories"]["fnb_competitors"]["attempt_count"]

    for _ in range(3):
        again = client.get(
            f"/api/v1/properties/listings/{listing}/enrichment",
            headers=auth(owner["token"]),
        )
        assert again.status_code == 200

    after = again.json()["data"]["categories"]["fnb_competitors"]["attempt_count"]
    assert after == before


def test_state_reports_all_five_categories(client, owner, listing):
    response = client.get(
        f"/api/v1/properties/listings/{listing}/enrichment",
        headers=auth(owner["token"]),
    )
    assert response.status_code == 200
    categories = response.json()["data"]["categories"]
    assert set(categories) == {
        "fnb_competitors",
        "demand_generators",
        "roads_transport",
        "parking",
        "population",
    }
    assert all(state["status"] == "pending" for state in categories.values())


# ---------------------------------------------------------------------------
# Retry
# ---------------------------------------------------------------------------


def test_retry_rejects_an_unknown_category(client, owner, listing):
    response = client.post(
        f"/api/v1/properties/listings/{listing}/enrichment/traffic/retry",
        headers=auth(owner["token"]),
    )
    assert response.status_code == 422


def test_retry_runs_exactly_one_category(client, owner, listing):
    client.post(
        f"/api/v1/properties/listings/{listing}/enrich",
        headers=auth(owner["token"]),
        json={"phase": "postgis"},
    )
    before = client.get(
        f"/api/v1/properties/listings/{listing}/enrichment",
        headers=auth(owner["token"]),
    ).json()["data"]["categories"]

    response = client.post(
        f"/api/v1/properties/listings/{listing}/enrichment/parking/retry",
        headers=auth(owner["token"]),
    )
    assert response.status_code == 200, response.text
    after = response.json()["data"]["categories"]

    assert after["parking"]["attempt_count"] == before["parking"]["attempt_count"] + 1
    for category in ("fnb_competitors", "demand_generators", "roads_transport"):
        assert after[category]["attempt_count"] == before[category]["attempt_count"]


# ---------------------------------------------------------------------------
# Ownership scoping
# ---------------------------------------------------------------------------


def test_another_owner_cannot_enrich(client, owner, other_owner, listing):
    response = client.post(
        f"/api/v1/properties/listings/{listing}/enrich",
        headers=auth(other_owner["token"]),
        json={"phase": "postgis"},
    )
    assert response.status_code == 403


def test_missing_listing_is_404(client, owner):
    response = client.post(
        "/api/v1/properties/listings/999999999/enrich",
        headers=auth(owner["token"]),
        json={"phase": "postgis"},
    )
    assert response.status_code == 404


# ---------------------------------------------------------------------------
# Explicit submission
# ---------------------------------------------------------------------------


def test_submit_requires_acknowledgement_when_population_is_unavailable(
    client, owner, listing
):
    """Population is never estimated, so the owner must acknowledge the gap."""
    with Session(engine) as session:
        session.execute(
            text(
                "UPDATE fyp.rental_properties "
                "SET latitude = 0.0, longitude = 0.0 WHERE id = :pid"
            ),
            {"pid": listing},
        )
        session.commit()

    enriched = client.post(
        f"/api/v1/properties/listings/{listing}/enrich",
        headers=auth(owner["token"]),
        json={"phase": "population"},
    )
    assert enriched.status_code == 200, enriched.text
    assert (
        enriched.json()["data"]["categories"]["population"]["status"] == "unavailable"
    )

    refused = client.post(
        f"/api/v1/properties/{listing}/verification/submit",
        headers=auth(owner["token"]),
        json={"scope": "listing"},
    )
    assert refused.status_code == 409, refused.text
    assert "Population could not be measured" in refused.json()["detail"]

    acknowledged = client.post(
        f"/api/v1/properties/{listing}/verification/submit",
        headers=auth(owner["token"]),
        json={"scope": "listing", "acknowledge_unavailable_population": True},
    )
    # The acknowledgement satisfies the ENRICHMENT guard. The draft is still
    # missing address/price fields, so the pre-existing completeness guard may
    # refuse it — what must not happen is the population objection reappearing.
    assert "Population could not be measured" not in acknowledged.text


def test_submit_is_refused_while_enrichment_is_running(client, owner, listing):
    with Session(engine) as session:
        session.execute(
            text(
                """
                INSERT INTO fyp.property_enrichment_category
                    (property_id, category, phase, status, attempt_count,
                     started_at, updated_at)
                VALUES (:pid, 'fnb_competitors', 'postgis', 'running', 1,
                        now(), now())
                ON CONFLICT (property_id, category) DO UPDATE
                   SET status = 'running', started_at = now()
                """
            ),
            {"pid": listing},
        )
        session.commit()

    response = client.post(
        f"/api/v1/properties/{listing}/verification/submit",
        headers=auth(owner["token"]),
        json={"scope": "listing"},
    )
    assert response.status_code == 409, response.text
    assert "still running" in response.json()["detail"]


def test_submit_is_untouched_for_never_enriched_listings(client, owner, listing):
    """Legacy behaviour: no enrichment rows means no enrichment guard."""
    response = client.post(
        f"/api/v1/properties/{listing}/verification/submit",
        headers=auth(owner["token"]),
        json={"scope": "listing"},
    )
    assert response.status_code != 409 or "Enrichment" not in response.text
