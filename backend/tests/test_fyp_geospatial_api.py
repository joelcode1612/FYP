"""Geospatial competitor contract + owner listing/enrichment tests.

These run against the real local database (``Final_Location_Analysis``) — the
same engine the application uses — because the point of the contract is that
the SQL and the stored features agree. Every row created here is deleted by
the ``created_properties`` fixture, and the users are tracked by the shared
``cleanup_users`` fixture.
"""

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.repositories.fyp_property_repository import (
    COMPETITOR_SOURCES,
    FypPropertyRepository,
)
from tests.conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token):
    return {"Authorization": f"Bearer {token}"}


def _published_property_ids(limit: int = 3) -> list[int]:
    with Session(engine) as session:
        rows = session.execute(
            text(
                """
                SELECT id FROM fyp.rental_properties
                WHERE latitude IS NOT NULL AND longitude IS NOT NULL
                  AND is_published AND verification_status = 'approved'
                ORDER BY id LIMIT :n
                """
            ),
            {"n": limit},
        ).all()
    return [r[0] for r in rows]


@pytest.fixture()
def owner_token(client, cleanup_users):
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"owner-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}"
    token = make_token(sub=str(sub), email=email)
    response = client.get("/api/v1/auth/me", headers=auth(token))
    assert response.status_code == 200, response.text
    return sub, token


@pytest.fixture()
def created_properties():
    ids: list[int] = []
    yield ids
    with Session(engine) as session:
        for pid in ids:
            session.execute(
                text("DELETE FROM fyp.property_geospatial_features WHERE property_id = :p"),
                {"p": pid},
            )
            session.execute(
                text("DELETE FROM fyp.rental_properties WHERE id = :p"), {"p": pid}
            )
        session.commit()


PROPERTY_BODY = {
    "name": "Contract Test Shoplot",
    "address": "12 Jalan Uji, Taman Uji",
    "city": "Kuala Lumpur",
    "state": "Kuala Lumpur",
    # Address-validation policy requires a postcode on submission.
    "postcode": "50000",
    "latitude": 3.046482,
    "longitude": 101.587067,
    "rental_price": 4200,
    "size_sqft": 1100,
    "property_type": "Shop",
    "availability": "immediate",
    "has_parking": True,
    "is_fnb_suitable": True,
}


# ---------------------------------------------------------------------------
# Competitor counting contract
# ---------------------------------------------------------------------------


def test_canonical_counts_match_independent_sql():
    """The repository's count must equal an independently written query using
    the documented predicate (in_target_region AND in_main_scope, geodesic)."""
    pids = _published_property_ids(3)
    assert pids, "no published property with coordinates in this database"
    with Session(engine) as session:
        repo = FypPropertyRepository(session)
        for pid in pids:
            lat, lon = repo._coords(pid)
            counts = repo.competitor_counts(lat, lon)
            for label, radius in (("500m", 500), ("1km", 1000)):
                independent = session.execute(
                    text(
                        """
                        SELECT count(*) FROM fnb_a.fnb_outlet o
                        WHERE o.geom IS NOT NULL
                          AND o.in_target_region AND o.in_main_scope
                          AND ST_DWithin(o.geom::geography,
                              ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                              :r)
                        """
                    ),
                    {"lat": lat, "lon": lon, "r": radius},
                ).scalar_one()
                assert counts[f"competitor_count_{label}"] == int(independent)


def test_500m_is_subset_of_1km():
    pids = _published_property_ids(3)
    with Session(engine) as session:
        repo = FypPropertyRepository(session)
        for pid in pids:
            lat, lon = repo._coords(pid)
            counts = repo.competitor_counts(lat, lon)
            assert counts["competitor_count_500m"] <= counts["competitor_count_1km"]


def test_source_modes_and_merged_deduplication():
    pids = _published_property_ids(1)
    with Session(engine) as session:
        repo = FypPropertyRepository(session)
        lat, lon = repo._coords(pids[0])
        counts = repo.competitor_counts_by_source(lat, lon, radius_m=500)
        assert counts["merged"] == counts["osm"] + counts["overture_unique"]
        assert counts["overture_unique"] <= counts["overture_raw"]
        assert counts["duplicates_removed"] == counts["overture_raw"] - counts["overture_unique"]

        merged = repo.list_competitors(pids[0], radius_m=500, limit=100, source="merged")
        keys = [(row["provider"], row["competitor_key"]) for row in merged["data"]]
        assert len(keys) == len(set(keys)), "merged list must not repeat a competitor"
        # No Overture row that is already MATCHed to an OSM outlet may appear.
        overture_ids = [row["competitor_key"] for row in merged["data"] if row["provider"] == "overture"]
        if overture_ids:
            matched = session.execute(
                text(
                    """
                    SELECT count(*) FROM fnb_a.overture_match
                    WHERE decision = 'MATCH' AND overture_id = ANY(:ids)
                    """
                ),
                {"ids": overture_ids},
            ).scalar_one()
            assert matched == 0


def test_overture_rows_report_unknown_status_and_provenance():
    pids = _published_property_ids(1)
    with Session(engine) as session:
        repo = FypPropertyRepository(session)
        result = repo.list_competitors(pids[0], radius_m=1000, limit=100, source="overture")
    if not result["data"]:
        pytest.skip("no Overture places within 1 km of the sample property")
    for row in result["data"]:
        assert row["provider"] == "overture"
        assert row["operating_status"] in ("unknown", "open", "closed")
        assert row["source_licence"], "Overture rows must carry their licence"
        assert row["source_snapshot"], "Overture rows must carry their release"
        assert row["category"], "competitor rows must be F&B categorised"


def test_competitor_endpoint_defaults_to_osm(client, owner_token):
    """Backward compatibility: omitting `source` returns the OSM-only result."""
    _sub, token = owner_token
    pid = _published_property_ids(1)[0]
    default = client.get(
        f"/api/v1/explore/properties/{pid}/competitors?radius_m=500&limit=10",
        headers=auth(token),
    )
    assert default.status_code == 200, default.text
    explicit = client.get(
        f"/api/v1/explore/properties/{pid}/competitors?radius_m=500&limit=10&source=osm",
        headers=auth(token),
    )
    assert explicit.status_code == 200
    assert default.json()["meta"]["source"] == "osm"
    assert [r["competitor_key"] for r in default.json()["data"]] == [
        r["competitor_key"] for r in explicit.json()["data"]
    ]
    # Legacy keys the Dart mapper reads must still be present.
    if default.json()["data"]:
        row = default.json()["data"][0]
        for legacy in ("outlet_key", "outlet_name", "outlet_category", "addr_street", "addr_city"):
            assert legacy in row
    assert "counts" in default.json()["meta"]


def test_competitor_endpoint_rejects_unknown_source_and_radius(client, owner_token):
    _sub, token = owner_token
    pid = _published_property_ids(1)[0]
    bad_source = client.get(
        f"/api/v1/explore/properties/{pid}/competitors?source=google", headers=auth(token)
    )
    assert bad_source.status_code == 422
    bad_radius = client.get(
        f"/api/v1/explore/properties/{pid}/competitors?radius_m=750", headers=auth(token)
    )
    assert bad_radius.status_code == 422
    assert set(COMPETITOR_SOURCES) == {"osm", "overture", "merged"}


# ---------------------------------------------------------------------------
# Owner listing creation + enrichment
# ---------------------------------------------------------------------------


def test_create_listing_persists_pending_and_enriches(client, owner_token, created_properties):
    sub, token = owner_token
    response = client.post(
        "/api/v1/properties/listings", headers=auth(token), json=PROPERTY_BODY
    )
    assert response.status_code == 201, response.text
    body = response.json()
    pid = body["data"]["id"]
    created_properties.append(pid)

    assert body["data"]["verification_status"] == "pending"
    assert body["data"]["is_published"] is False
    assert body["data"]["name"] == PROPERTY_BODY["name"]

    with Session(engine) as session:
        owner = session.execute(
            text("SELECT owner_user_id FROM fyp.rental_properties WHERE id = :p"), {"p": pid}
        ).scalar_one()
        assert str(owner) == str(sub), "owner identity must be the verified UUID"
        geom = session.execute(
            text("SELECT ST_AsText(geom) FROM fyp.rental_properties WHERE id = :p"), {"p": pid}
        ).scalar_one()
        assert geom.startswith("POINT("), "generated geom must be populated"

    # The create path now runs the feature-refresh service and reports its
    # summary (not a per-feature dict). The values land in the geospatial
    # table; assert them there so the test still proves real enrichment.
    enrichment = body["enrichment"]
    assert enrichment["status"] == "ok", enrichment
    assert enrichment["features"]["properties_recalculated"] >= 1
    with Session(engine) as session:
        features = session.execute(
            text(
                "SELECT competitor_count_500m, competitor_count_1km, population_500m "
                "FROM fyp.property_geospatial_features WHERE property_id = :p"
            ),
            {"p": pid},
        ).mappings().first()
    assert features is not None, "enrichment must persist a geospatial row"
    assert features["competitor_count_500m"] is not None
    assert features["competitor_count_1km"] >= features["competitor_count_500m"]
    # Population has no legitimate per-coordinate source in this deployment.
    assert features["population_500m"] is None
    assert body["meta"]["note"].endswith("until an administrator verifies them.")


def test_create_listing_requires_authentication(client):
    response = client.post("/api/v1/properties/listings", json=PROPERTY_BODY)
    assert response.status_code == 401


def test_create_listing_rejects_invalid_payload(client, owner_token):
    _sub, token = owner_token
    bad_coords = {**PROPERTY_BODY, "latitude": 120.0}
    assert client.post(
        "/api/v1/properties/listings", headers=auth(token), json=bad_coords
    ).status_code == 422
    missing_name = {k: v for k, v in PROPERTY_BODY.items() if k != "name"}
    assert client.post(
        "/api/v1/properties/listings", headers=auth(token), json=missing_name
    ).status_code == 422
    zero_price = {**PROPERTY_BODY, "rental_price": 0}
    assert client.post(
        "/api/v1/properties/listings", headers=auth(token), json=zero_price
    ).status_code == 422


def test_enrichment_is_idempotent(client, owner_token, created_properties):
    _sub, token = owner_token
    created = client.post(
        "/api/v1/properties/listings", headers=auth(token), json=PROPERTY_BODY
    )
    pid = created.json()["data"]["id"]
    created_properties.append(pid)

    first = client.post(f"/api/v1/properties/listings/{pid}/enrich", headers=auth(token))
    second = client.post(f"/api/v1/properties/listings/{pid}/enrich", headers=auth(token))
    assert first.status_code == 200, first.text
    assert second.status_code == 200
    assert first.json()["data"]["competitor_count_500m"] == second.json()["data"]["competitor_count_500m"]

    with Session(engine) as session:
        rows = session.execute(
            text("SELECT count(*) FROM fyp.property_geospatial_features WHERE property_id = :p"),
            {"p": pid},
        ).scalar_one()
    assert rows == 1, "repeated enrichment must not duplicate the feature row"


def test_enrichment_denied_for_other_owner(client, owner_token, cleanup_users, created_properties):
    _sub, token = owner_token
    created = client.post(
        "/api/v1/properties/listings", headers=auth(token), json=PROPERTY_BODY
    )
    pid = created.json()["data"]["id"]
    created_properties.append(pid)

    other = uuid.uuid4()
    register_user_id(cleanup_users, other)
    other_token = make_token(sub=str(other), email=f"other-{other.hex[:8]}@{TEST_EMAIL_DOMAIN}")
    client.get("/api/v1/auth/me", headers=auth(other_token))

    denied = client.post(
        f"/api/v1/properties/listings/{pid}/enrich", headers=auth(other_token)
    )
    assert denied.status_code == 403


def test_owner_listings_returns_only_own_rows(client, owner_token, created_properties):
    sub, token = owner_token
    created = client.post(
        "/api/v1/properties/listings", headers=auth(token), json=PROPERTY_BODY
    )
    pid = created.json()["data"]["id"]
    created_properties.append(pid)

    listed = client.get("/api/v1/properties/listings/mine", headers=auth(token))
    assert listed.status_code == 200
    ids = [row["id"] for row in listed.json()["data"]]
    assert pid in ids
    assert all(row["verification_status"] == "pending" for row in listed.json()["data"])
