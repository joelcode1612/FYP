"""Explore nearby-property spatial filter tests (task: 500 m / 3+ default).

These run against the real local database (``Final_Location_Analysis``) —
the same engine the application uses — because the point of the filter is
that PostGIS geodesic math, the generated ``geom`` column and the GIST index
agree end to end. Every row created here is deleted by the
``created_properties`` fixture, and the users are tracked by the shared
``cleanup_users`` fixture.

Clusters are placed at grid-searched points that are far from every
pre-existing eligible listing (so the expected nearby counts are exact) and
far from each other (so one test's cluster never becomes another test's
neighbour). Assertions on the RESULT SET are additionally scoped with the
``q`` search term because the real dataset contains its own qualifying
listings.
"""

import math
import time
import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.repositories.fyp_property_repository import FypPropertyRepository
from tests.conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

#: All test rows carry this name prefix, so `q=` scopes result-set assertions.
NAME_PREFIX = "Nearby Filter Test"


def auth(token):
    return {"Authorization": f"Bearer {token}"}


def _haversine(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * 6_371_000 * math.asin(math.sqrt(h))


@pytest.fixture(scope="module")
def isolated_points() -> list[tuple[float, float]]:
    """Coordinates far from every pre-existing eligible listing AND from each
    other, so test clusters have exactly the neighbours they create."""
    with Session(engine) as session:
        rows = session.execute(
            text(
                """
                SELECT lat, lon, min_dist FROM (
                    SELECT gg.lat, gg.lon,
                           min(ST_DistanceSphere(p.geom,
                               ST_SetSRID(ST_MakePoint(gg.lon, gg.lat), 4326))) AS min_dist
                    FROM generate_series(0.5, 7.0, 0.25) AS g(lat)
                    CROSS JOIN generate_series(99.0, 105.0, 0.25) AS g2(lon)
                    CROSS JOIN LATERAL (SELECT g.lat AS lat, g2.lon AS lon) gg
                    CROSS JOIN fyp.rental_properties p
                    WHERE p.geom IS NOT NULL
                      AND p.is_published AND p.verification_status = 'approved'
                    GROUP BY gg.lat, gg.lon
                    ORDER BY min_dist DESC
                    LIMIT 40
                ) t
                """
            )
        ).all()
    assert rows, "no eligible properties to measure distance from"
    assert float(rows[0][2]) >= 1500, (
        f"grid search found no point >=1500 m from eligible listings "
        f"(best {float(rows[0][2]):.0f} m)"
    )
    picked: list[tuple[float, float]] = []
    for lat, lon, _ in rows:
        point = (float(lat), float(lon))
        if all(_haversine(point, other) >= 50_000 for other in picked):
            picked.append(point)
        if len(picked) >= 2:
            break
    return picked


@pytest.fixture()
def owner_token(client, cleanup_users):
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"owner-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}"
    token = make_token(sub=str(sub), email=email)
    response = client.get("/api/v1/auth/me", headers=auth(token))
    assert response.status_code == 200, response.text
    return token


@pytest.fixture()
def created_properties():
    ids: list[int] = []
    yield ids
    with Session(engine) as session:
        for pid in ids:
            session.execute(
                text("DELETE FROM fyp.rental_properties WHERE id = :p"), {"p": pid}
            )
        session.commit()


_counter = {"n": 0}


def _insert_property(
    session: Session,
    *,
    lat: float | None,
    lon: float | None,
    published: bool = True,
    approved: bool = True,
    created: list[int] | None = None,
) -> int:
    """Insert one test listing; NULL coordinates are inserted as SQL NULL."""
    _counter["n"] += 1
    status = "approved" if approved else "pending"
    row = session.execute(
        text(
            """
            INSERT INTO fyp.rental_properties (
                name, property_type, address, city, state, latitude, longitude,
                rental_price, size_sqft, availability,
                verification_status, is_published
            ) VALUES (
                :name, 'Shop', '12 Jalan Uji', 'Kuala Lumpur', 'Kuala Lumpur',
                :lat, :lon, 4000, 1000, 'immediate',
                :status, :published
            )
            RETURNING id
            """
        ),
        {
            "name": f"{NAME_PREFIX} #{_counter['n']}",
            "lat": lat,
            "lon": lon,
            "status": status,
            "published": published,
        },
    ).scalar_one()
    session.commit()
    if created is not None:
        created.append(row)
    return row


def _insert_at_offset(
    session: Session,
    center: tuple[float, float],
    distance_m: float,
    azimuth_deg: float,
    *,
    published: bool = True,
    approved: bool = True,
    created: list[int] | None = None,
) -> int:
    """Insert a listing exactly [distance_m] geodesic metres from [center]."""
    lat, lon = center
    _counter["n"] += 1
    row = session.execute(
        text(
            """
            INSERT INTO fyp.rental_properties (
                name, property_type, address, city, state, latitude, longitude,
                rental_price, size_sqft, availability,
                verification_status, is_published
            )
            SELECT :name, 'Shop', '12 Jalan Uji', 'Kuala Lumpur', 'Kuala Lumpur',
                   ST_Y(p::geometry), ST_X(p::geometry),
                   4000, 1000, 'immediate', :status, :published
            FROM (
                SELECT ST_Project(
                    ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                    :dist, radians(:azimuth)) AS p
            ) proj
            RETURNING id
            """
        ),
        {
            "name": f"{NAME_PREFIX} #{_counter['n']}",
            "lat": lat,
            "lon": lon,
            "dist": float(distance_m),
            "azimuth": float(azimuth_deg),
            "status": "approved" if approved else "pending",
            "published": published,
        },
    ).scalar_one()
    session.commit()
    if created is not None:
        created.append(row)
    return row


def _search(client, owner_token, **params) -> dict:
    response = client.get(
        "/api/v1/explore/properties", headers=auth(owner_token), params=params
    )
    assert response.status_code == 200, response.text
    return response.json()


def _by_id(payload: dict) -> dict[int, dict]:
    return {row["property_id"]: row for row in payload["data"]}


# ---------------------------------------------------------------------------
# 1. Property with exactly three nearby eligible properties -> displayed
# ---------------------------------------------------------------------------


def test_property_with_exactly_three_nearby_is_returned(
    client, owner_token, isolated_points, created_properties
):
    point = isolated_points[0]
    with Session(engine) as session:
        center = _insert_property(
            session, lat=point[0], lon=point[1], created=created_properties
        )
        for azimuth in (0, 120, 240):
            _insert_at_offset(session, point, 150, azimuth, created=created_properties)
    payload = _search(
        client,
        owner_token,
        q=NAME_PREFIX,
        min_nearby_properties=3,
        nearby_radius_m=500,
        limit=100,
    )
    rows = _by_id(payload)
    assert rows[center]["nearby_property_count"] == 3
    assert payload["meta"]["min_nearby_properties"] == 3
    assert payload["meta"]["nearby_radius_m"] == 500


# ---------------------------------------------------------------------------
# 2. Property with only two nearby -> hidden, visible without the filter
# ---------------------------------------------------------------------------


def test_property_with_only_two_nearby_is_hidden(
    client, owner_token, isolated_points, created_properties
):
    point = isolated_points[0]
    with Session(engine) as session:
        center = _insert_property(
            session, lat=point[0], lon=point[1], created=created_properties
        )
        for azimuth in (0, 10):
            _insert_at_offset(session, point, 150, azimuth, created=created_properties)
    payload = _search(
        client,
        owner_token,
        q=NAME_PREFIX,
        min_nearby_properties=3,
        nearby_radius_m=500,
        limit=100,
    )
    assert center not in _by_id(payload)
    # The same listing IS visible without the spatial filter.
    unfiltered = _search(client, owner_token, q=NAME_PREFIX, limit=100)
    assert center in _by_id(unfiltered)


# ---------------------------------------------------------------------------
# 3. Boundary distance: inclusive inside, exclusive outside
# ---------------------------------------------------------------------------


def test_boundary_distance_around_500m(
    client, owner_token, isolated_points, created_properties
):
    """ST_DWithin is inclusive (<= radius).

    Precision note: a pair whose spheroid ST_Distance is EXACTLY 500.0 m can
    still be excluded, because ST_DWithin evaluates the geodesic through its
    own direct-path arithmetic that may land a sub-millimetre above the
    radius. The deterministic boundary validation therefore places neighbours
    100 mm inside and 100 mm outside the radius; the SQL contract itself
    stays ``<=``.
    """
    point = isolated_points[0]
    with Session(engine) as session:
        center = _insert_property(
            session, lat=point[0], lon=point[1], created=created_properties
        )
        _insert_at_offset(session, point, 499.9, 45, created=created_properties)
        _insert_at_offset(session, point, 500.1, 135, created=created_properties)
    payload = _search(
        client,
        owner_token,
        q=NAME_PREFIX,
        min_nearby_properties=1,
        nearby_radius_m=500,
        limit=100,
    )
    rows = _by_id(payload)
    assert len(rows) == 2
    assert rows[center]["nearby_property_count"] == 1


# ---------------------------------------------------------------------------
# 4. Exclusion of the property itself
# ---------------------------------------------------------------------------


def test_property_does_not_count_itself(
    client, owner_token, isolated_points, created_properties
):
    point = isolated_points[0]
    with Session(engine) as session:
        center = _insert_property(
            session, lat=point[0], lon=point[1], created=created_properties
        )
        _insert_at_offset(session, point, 100, 0, created=created_properties)
    payload = _search(
        client,
        owner_token,
        q=NAME_PREFIX,
        min_nearby_properties=1,
        nearby_radius_m=500,
        limit=100,
    )
    rows = _by_id(payload)
    # Center sees exactly one OTHER listing; it is never its own neighbour.
    assert len(rows) == 2
    assert rows[center]["nearby_property_count"] == 1
    neighbour_id = next(pid for pid in rows if pid != center)
    assert rows[neighbour_id]["nearby_property_count"] == 1


# ---------------------------------------------------------------------------
# 5. Unpublished / unapproved neighbours are not eligible
# ---------------------------------------------------------------------------


def test_unpublished_and_unapproved_neighbours_are_excluded(
    client, owner_token, isolated_points, created_properties
):
    point = isolated_points[0]
    with Session(engine) as session:
        center = _insert_property(
            session, lat=point[0], lon=point[1], created=created_properties
        )
        _insert_at_offset(session, point, 100, 0, created=created_properties)
        _insert_at_offset(session, point, 100, 120, created=created_properties)
        _insert_at_offset(
            session, point, 100, 240, published=False, created=created_properties
        )
        _insert_at_offset(
            session, point, 100, 300, approved=False, created=created_properties
        )
    payload = _search(
        client,
        owner_token,
        q=NAME_PREFIX,
        min_nearby_properties=3,
        nearby_radius_m=500,
        limit=100,
    )
    rows = _by_id(payload)
    # Only the two approved+published neighbours count -> below the threshold.
    assert center not in rows


# ---------------------------------------------------------------------------
# 6. Missing coordinates can never satisfy the spatial filter
# ---------------------------------------------------------------------------


def test_missing_coordinates_are_excluded(
    client, owner_token, isolated_points, created_properties
):
    point = isolated_points[0]
    with Session(engine) as session:
        center = _insert_property(session, lat=None, lon=None, created=created_properties)
        for azimuth in (0, 120, 240):
            _insert_at_offset(session, point, 150, azimuth, created=created_properties)
    payload = _search(
        client,
        owner_token,
        q=NAME_PREFIX,
        min_nearby_properties=3,
        nearby_radius_m=500,
        limit=100,
    )
    # The coordinate-less listing is never fabricated a position.
    assert center not in _by_id(payload)


# ---------------------------------------------------------------------------
# 7. Totals and pagination stay consistent with the filtered set
# ---------------------------------------------------------------------------


def test_totals_and_pagination_are_consistent(
    client, owner_token, isolated_points, created_properties
):
    """Cluster at point A (five qualifying listings), a non-qualifying pair at
    a point >=50 km away. Paged ids must reconstruct the filtered set."""
    cluster, loner_point = isolated_points[0], isolated_points[1]
    with Session(engine) as session:
        # Five listings at/around the cluster point: each sees the two
        # co-located centres plus two ring neighbours -> 4 nearby each.
        _insert_property(session, lat=cluster[0], lon=cluster[1], created=created_properties)
        _insert_property(session, lat=cluster[0], lon=cluster[1], created=created_properties)
        for azimuth in (0, 120, 240):
            _insert_at_offset(session, cluster, 150, azimuth, created=created_properties)
        # A pair 50 km away: one nearby neighbour each -> never qualifies.
        loner = _insert_property(
            session, lat=loner_point[0], lon=loner_point[1], created=created_properties
        )
        _insert_at_offset(session, loner_point, 150, 0, created=created_properties)

    expected_ids: set[int] | None = None
    paged_ids: set[int] = set()
    for offset in range(0, 6, 2):
        page = _search(
            client,
            owner_token,
            q=NAME_PREFIX,
            min_nearby_properties=3,
            nearby_radius_m=500,
            limit=2,
            offset=offset,
            sort="newest",
        )
        assert page["meta"]["total"] == 5, page["meta"]
        assert len(page["data"]) == (2 if offset < 4 else 1)
        paged_ids |= {row["property_id"] for row in page["data"]}
        full = _search(
            client,
            owner_token,
            q=NAME_PREFIX,
            min_nearby_properties=3,
            nearby_radius_m=500,
            limit=100,
            sort="newest",
        )
        expected_ids = {row["property_id"] for row in full["data"]}
    assert paged_ids == expected_ids
    assert loner not in expected_ids
    assert len(expected_ids) == 5


# ---------------------------------------------------------------------------
# 8. Backward compatibility: without the parameters nothing changes
# ---------------------------------------------------------------------------


def test_without_parameters_response_is_backward_compatible(
    client, owner_token, isolated_points, created_properties
):
    point = isolated_points[0]
    with Session(engine) as session:
        center = _insert_property(
            session, lat=point[0], lon=point[1], created=created_properties
        )
        _insert_at_offset(session, point, 150, 0, created=created_properties)
    payload = _search(client, owner_token, q=NAME_PREFIX, limit=100)
    rows = _by_id(payload)
    assert center in rows
    assert "nearby_property_count" not in rows[center]
    assert "min_nearby_properties" not in payload["meta"]
    assert "nearby_radius_m" not in payload["meta"]


def test_invalid_radius_returns_422(client, owner_token):
    response = client.get(
        "/api/v1/explore/properties",
        headers=auth(owner_token),
        params={"min_nearby_properties": 3, "nearby_radius_m": 400},
    )
    assert response.status_code == 422


def test_min_nearby_below_one_rejected(client, owner_token):
    response = client.get(
        "/api/v1/explore/properties",
        headers=auth(owner_token),
        params={"min_nearby_properties": 0},
    )
    assert response.status_code == 422


# ---------------------------------------------------------------------------
# 10. Query performance over the real dataset (no test rows)
# ---------------------------------------------------------------------------


def test_default_filter_query_performance():
    """The set-based spatial filter must answer from one statement per phase.

    Measures the repository call (total + page statements) over the full
    eligible dataset with the default 3 / 500 m parameters.
    """
    started = time.perf_counter()
    with Session(engine) as session:
        result = FypPropertyRepository(session).list_published(
            {
                "min_nearby_properties": 3,
                "nearby_radius_m": 500,
                "limit": 24,
                "offset": 0,
            }
        )
    elapsed = time.perf_counter() - started
    counts = {
        row["property_id"]: row["nearby_property_count"] for row in result["data"]
    }
    assert all(count >= 3 for count in counts.values())
    # Generous bound for shared hardware; the plan must stay one statement per
    # phase, never one query per card.
    assert elapsed < 5.0, f"spatial explore took {elapsed:.2f}s"
    print(
        f"nearby-filter explore query: {elapsed * 1000:.0f} ms "
        f"(total={result['meta']['total']})"
    )


# ---------------------------------------------------------------------------
# Repository-level check on real data: counts match an independent query
# ---------------------------------------------------------------------------


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


def test_nearby_count_matches_independent_sql():
    pids = _published_property_ids(3)
    assert pids, "no published property with coordinates in this database"
    with Session(engine) as session:
        repo = FypPropertyRepository(session)
        result = repo.list_published(
            {
                "min_nearby_properties": 1,
                "nearby_radius_m": 500,
                "limit": 100,
                "offset": 0,
            }
        )
        rows = {
            row["property_id"]: row["nearby_property_count"] for row in result["data"]
        }
        for pid in pids:
            if pid not in rows:
                continue
            lat, lon = repo._coords(pid)
            independent = session.execute(
                text(
                    """
                    SELECT count(*) FROM fyp.rental_properties o
                    WHERE o.id <> :pid
                      AND o.is_published AND o.verification_status = 'approved'
                      AND o.geom IS NOT NULL
                      AND ST_DWithin(o.geom::geography,
                          ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                          500)
                    """
                ),
                {"pid": pid, "lat": lat, "lon": lon},
            ).scalar_one()
            assert rows[pid] == int(independent)
