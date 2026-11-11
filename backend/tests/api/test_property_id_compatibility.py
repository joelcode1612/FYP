"""Phase 6 verification: recommendation-to-property navigation contract.

The pipeline's ids are canonical text (``EP-01877``, ``MD-00510``); the
explore/detail routes navigate with the commercial listing's bigint id. The
identity mapping is ``fyp.property_subject_links`` (``match_verified``), and
the explore detail policy (approved + published ONLY) deliberately 404s the
pending imported catalogue listings.

Verified here:

* every generated recommendation carries a ``listing_ref`` with the verified
  bigint id and an explicit ``detail_available`` state - MD-00510 resolves to
  listing 316;
* ``detail_available`` is False for the pending catalogue (with a note), so a
  client never follows a link that 404s silently; the canonical id remains
  the key for assessments and research evidence (``/assessments`` accepts
  the text id);
* an unlinked row maps to ``listing_ref: null`` (never a guessed id);
* the explore detail 404 for a pending listing is the documented policy,
  unchanged.
"""
from __future__ import annotations

import re
import uuid
from pathlib import Path

import pytest

from sitewise.repositories.recommendation_candidate_repository import (
    RecommendationCandidateRepository,
)

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

BACKEND_DIR = Path(__file__).resolve().parents[2]
CATALOGUE_ID = re.compile(r"^(EP|MD)-\d+$")


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def identity(client, cleanup_users):
    sub = str(uuid.uuid4())
    token = make_token(sub=sub, email=f"nav-{sub[:8]}@{TEST_EMAIL_DOMAIN}")
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    register_user_id(cleanup_users, uuid.UUID(sub))
    return {"token": token, "user_id": uuid.UUID(sub)}


def test_recommendations_carry_verified_listing_refs(client, identity):
    response = client.post(
        "/api/v1/recommendations/generate",
        json={"limit": 5},
        headers=auth(identity["token"]),
    )
    assert response.status_code == 200, response.text
    results = response.json()["results"]
    assert results
    for result in results:
        assert CATALOGUE_ID.match(result["property_id"])
        ref = result["property"]["listing_ref"]
        assert isinstance(ref, dict), result["property_id"]
        assert isinstance(ref["listing_id"], int)
        assert ref["match_verified"] is True
        assert ref["detail_available"] is False  # the 955 imported rows are pending
        assert "NOT approved+published" in ref["detail_note"]


def test_md_00510_maps_to_the_verified_listing(client, identity):
    response = client.post(
        "/api/v1/recommendations/generate",
        json={"limit": 1, "property_ids": ["MD-00510"]},
        headers=auth(identity["token"]),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "ok", body["candidate_summary"]
    ref = body["results"][0]["property"]["listing_ref"]
    assert ref["listing_id"] == 316  # verified live mapping, not invented


def test_pending_detail_is_404_by_policy(client, identity):
    """The explore detail policy is preserved, not bypassed."""
    response = client.get(
        "/api/v1/explore/properties/316", headers=auth(identity["token"])
    )
    assert response.status_code == 404
    assert response.json()["detail"]["code"] == "property_not_found"


def test_unlinked_row_maps_to_null_listing_ref():
    from sqlmodel import Session

    from sitewise.db.analytics_session import analytics_engine

    with Session(analytics_engine) as session:
        rows = RecommendationCandidateRepository(session).list_candidates(limit=None)
    # Every catalogue row currently has a verified link; simulate the absent
    # case directly on the mapper.
    mapped = RecommendationCandidateRepository(session)._map(
        {
            "property_id": "EP-99999",
            "title": "",
            "address": "",
            "city": "",
            "state": "",
            "postcode": "",
            "property_type": None,
            "monthly_rental_myr": 1000.0,
            "built_up_sqft": 500.0,
            "latitude": None,
            "longitude": None,
            "image_url": None,
            "source_data": {},
            "subject_doc": {},
            "population_doc": {},
            "listing_id": None,
            "listing_detail_available": None,
        }
    )
    assert mapped["listing_ref"] is None
    assert rows  # the live feed is intact
