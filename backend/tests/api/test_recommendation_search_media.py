"""Batched media enrichment for the recommendation search response.

Two resolvers run ONCE per page beside the existing management enrichment:

* ``FypPropertyRepository.get_catalogue_photo_urls_batch`` — same verified
  chain and tie-breaks as the single-id ``get_catalogue_photos`` (verified
  subject link first, then the canonical ownerless rental row; ONE numeric
  target per catalogue id; primary photo first; blanks and duplicates
  dropped);
* ``panoramas_by_catalogue_ids`` — same authority and honesty rules as the
  insights endpoint's ``_panorama``: only a ``match_verified`` link joins to
  ``fyp.virtual_tour`` (never a numeric guess against the text catalogue
  id), only a completed status *with* a URL is ``ready``, and a linked-but-
  unfinished job is ``processing``.

Fixture rows live in a transaction that is ALWAYS rolled back — no live
catalogue, link, photo or tour row is modified. The HTTP test only checks
payload shape against live data (``fyp.virtual_tour`` is empty today, so
every card must honestly report no panorama).
"""
from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine
from sitewise.repositories.fyp_property_repository import FypPropertyRepository
from sitewise.services.property_insights_service import (
    PANORAMA_UNAVAILABLE,
    panoramas_by_catalogue_ids,
)

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

INSERT_PROPERTY_SQL = text(
    """
    INSERT INTO fyp.rental_properties (
        listing_id, catalogue_id, name, address, state, rental_price,
        size_sqft, latitude, longitude, property_type,
        catalogue_suitability_score, catalogue_dataset_validation,
        catalogue_source_workbook, catalogue_source_sheet,
        catalogue_source_row, catalogue_source_data
    ) VALUES (
        :id, :id, :title, :address, :state, :rental_rm, :size_sqft, :latitude,
        :longitude, :property_type, :suitability_score, :dataset_validation,
        :source_workbook, :source_sheet, :source_row, CAST(:source_data AS jsonb)
    )
    """
)


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def user_token(client, cleanup_users) -> str:
    sub = uuid.uuid4()
    token = make_token(
        sub=str(sub),
        email=f"search-media-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}",
    )
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    register_user_id(cleanup_users, sub)
    return token


def _property_row(catalogue_id: str) -> dict:
    return {
        "id": catalogue_id,
        "title": f"MEDIA FIXTURE {catalogue_id}",
        "address": "1 Fixture Street",
        "state": "Selangor",
        "rental_rm": 5000,
        "size_sqft": 1200,
        "latitude": 3.07,
        "longitude": 101.6,
        "property_type": "Shoplot",
        "suitability_score": 70.0,
        "dataset_validation": "test",
        "source_workbook": "test",
        "source_sheet": "test",
        "source_row": 1,
        "source_data": "{}",
    }


def _numeric_id(conn, catalogue_id: str) -> int:
    return conn.execute(
        text("SELECT id FROM fyp.rental_properties WHERE listing_id = :cid"),
        {"cid": catalogue_id},
    ).scalar_one()


def _add_link(conn, property_id: int, catalogue_id: str, verified: bool) -> None:
    conn.execute(
        text(
            """
            INSERT INTO fyp.property_subject_links (
                property_id, subject_id, sitewise_property_id, match_method,
                match_evidence, match_verified, linked_at, verified_at
            ) VALUES (
                :pid, NULL, :cid, 'test', 'test', :verified, now(), now()
            )
            """
        ),
        {"pid": property_id, "cid": catalogue_id, "verified": verified},
    )


def _add_photo(
    conn, property_id: int, url: str, primary: bool = False
) -> None:
    conn.execute(
        text(
            """
            INSERT INTO fyp.property_photos (
                property_id, url, caption, is_primary, created_at
            ) VALUES (:pid, :url, 'test', :primary, now())
            """
        ),
        {"pid": property_id, "url": url, "primary": primary},
    )


def _add_tour(conn, property_id: int, url: str | None, status: str) -> None:
    conn.execute(
        text(
            """
            INSERT INTO fyp.virtual_tour (
                tour_id, property_id, url, status, created_at, updated_at
            ) VALUES (
                gen_random_uuid(), :pid, :url, :status, now(), now()
            )
            """
        ),
        {"pid": property_id, "url": url, "status": status},
    )


def _build_fixtures(conn) -> dict:
    """Create four fixture properties covering every chain outcome."""
    ids = {}
    for cid in ("TEST-MD-A", "TEST-MD-B", "TEST-MD-C", "TEST-MD-D"):
        conn.execute(INSERT_PROPERTY_SQL, _property_row(cid))
        ids[cid] = _numeric_id(conn, cid)

    # A: verified link, completed tour with URL, primary photo + dup + blank.
    _add_link(conn, ids["TEST-MD-A"], "TEST-MD-A", verified=True)
    _add_tour(conn, ids["TEST-MD-A"], "https://example.com/pano-a.jpg", "complete")
    _add_photo(conn, ids["TEST-MD-A"], "https://example.com/a1.jpg", primary=True)
    _add_photo(conn, ids["TEST-MD-A"], "https://example.com/a2.jpg")
    _add_photo(conn, ids["TEST-MD-A"], "https://example.com/a1.jpg")  # duplicate
    _add_photo(conn, ids["TEST-MD-A"], "   ")  # blank, dropped

    # B: verified link, tour row still pending -> honest "processing".
    _add_link(conn, ids["TEST-MD-B"], "TEST-MD-B", verified=True)
    _add_tour(conn, ids["TEST-MD-B"], "https://example.com/pano-b.jpg", "pending")

    # C: NO link; photos hang off the canonical ownerless rental row.
    _add_photo(conn, ids["TEST-MD-C"], "https://example.com/c1.jpg", primary=True)

    # D: UNVERIFIED link with a completed tour -> must not be presented.
    _add_link(conn, ids["TEST-MD-D"], "TEST-MD-D", verified=False)
    _add_tour(conn, ids["TEST-MD-D"], "https://example.com/pano-d.jpg", "complete")
    return ids


def test_batch_photos_follow_the_verified_chain():
    with analytics_engine.connect() as conn:
        transaction = conn.begin()
        try:
            ids = _build_fixtures(conn)
            repo = FypPropertyRepository(Session(conn))
            all_ids = list(ids)
            result = repo.get_catalogue_photo_urls_batch(all_ids)

            assert result["TEST-MD-A"] == [
                "https://example.com/a1.jpg",  # primary first
                "https://example.com/a2.jpg",
            ]
            assert result["TEST-MD-C"] == ["https://example.com/c1.jpg"]
            # B has no photos; D's photos (none) must not leak from anywhere.
            assert "TEST-MD-B" not in result
            assert "TEST-MD-D" not in result
            # Empty / degenerate inputs resolve without touching SQL.
            assert repo.get_catalogue_photo_urls_batch([]) == {}
            assert repo.get_catalogue_photo_urls_batch(["", None]) == {}
        finally:
            transaction.rollback()


def test_batch_panoramas_report_ready_processing_and_absent_honestly():
    with analytics_engine.connect() as conn:
        transaction = conn.begin()
        try:
            ids = _build_fixtures(conn)
            result = panoramas_by_catalogue_ids(Session(conn), list(ids))

            assert result["TEST-MD-A"] == {
                "available": True,
                "status": "ready",
                "url": "https://example.com/pano-a.jpg",
                "reason": None,
            }
            assert result["TEST-MD-B"]["available"] is False
            assert result["TEST-MD-B"]["status"] == "processing"
            assert result["TEST-MD-B"]["url"] is None
            # C has no tour at all; D's link is unverified — neither is an
            # authority, so the router-side default applies.
            assert "TEST-MD-C" not in result
            assert "TEST-MD-D" not in result
            fallback = result.get("TEST-MD-D") or PANORAMA_UNAVAILABLE
            assert fallback["available"] is False
            assert fallback["status"] == "unavailable"
            assert panoramas_by_catalogue_ids(Session(conn), []) == {}
        finally:
            transaction.rollback()


def test_latest_tour_row_wins_per_property():
    """ORDER BY updated_at DESC NULLS LAST — newest link row is the answer."""
    with analytics_engine.connect() as conn:
        transaction = conn.begin()
        try:
            conn.execute(INSERT_PROPERTY_SQL, _property_row("TEST-MD-A"))
            pid = _numeric_id(conn, "TEST-MD-A")
            _add_link(conn, pid, "TEST-MD-A", verified=True)
            conn.execute(
                text(
                    """
                    INSERT INTO fyp.virtual_tour (
                        tour_id, property_id, url, status, created_at, updated_at
                    ) VALUES
                      (gen_random_uuid(), :pid, 'https://example.com/old.jpg',
                       'complete', now() - interval '2 days',
                       now() - interval '2 days'),
                      (gen_random_uuid(), :pid, 'https://example.com/new.jpg',
                       'complete', now() - interval '1 day', now() - interval '1 day')
                    """
                ),
                {"pid": pid},
            )
            result = panoramas_by_catalogue_ids(Session(conn), ["TEST-MD-A"])
            assert result["TEST-MD-A"]["url"] == "https://example.com/new.jpg"
        finally:
            transaction.rollback()


def test_search_payload_carries_media_fields(client, user_token):
    """Every item in a live search page gains ``photos`` + ``panorama``."""
    response = client.post(
        "/api/v1/recommendations/search", headers=auth(user_token), json={}
    )
    assert response.status_code == 200, response.text
    items = response.json()["data"]
    assert items, "the live catalogue returns cards to enrich"

    for item in items:
        photos = item["photos"]
        assert isinstance(photos, list)
        assert all(isinstance(u, str) and u.strip() for u in photos)

        panorama = item["panorama"]
        assert panorama["status"] in {"ready", "processing", "unavailable"}
        assert panorama["available"] is (panorama["status"] == "ready")
        if panorama["available"]:
            assert panorama["url"]
        else:
            assert panorama["url"] is None
            assert panorama["reason"]

        # The legacy scalar image key is untouched.
        assert "image_url" in item


def test_media_matches_the_live_tour_table(client, user_token):
    """With zero tour rows live, no card may claim a panorama."""
    with analytics_engine.connect() as conn:
        tour_rows = conn.execute(
            text("SELECT count(*) FROM fyp.virtual_tour")
        ).scalar()
    response = client.post(
        "/api/v1/recommendations/search",
        headers=auth(user_token),
        json={"page_size": 5},
    )
    assert response.status_code == 200, response.text
    items = response.json()["data"]
    assert len(items) <= 5
    if tour_rows == 0:
        for item in items:
            assert item["panorama"]["available"] is False
            assert item["panorama"]["status"] == "unavailable"
