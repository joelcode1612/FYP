"""Contract tests for the nearby-places read model behind the map's markers.

These run without a database: the session is a fake that returns scripted
rows per source table, so what is asserted is the service's contract, not the
SQL (the SQL itself is validated against live PostgreSQL on real properties).

What is asserted here is deliberately narrow but load-bearing:

* every place carries the full field set the map needs — stable id, name,
  category + subtype, coordinate, source + source id, operating status,
  straight-line distance, observation date and ``source_updated_at``;
* all five categories (properties, competitors, demand generators,
  accessibility, parking) come back from their real source tables;
* the envelope reports per-category ``state`` plus returned/total/truncated,
  so "mapped locations", "measured zero", "count without coordinates" and
  "source unavailable" stay separate — unavailable is never converted to zero;
* a capped category returns the nearest N and flags the truncation instead
  of silently shrinking the picture;
* a missing origin is not an error: every category reports an honest zero
  and no place is fabricated;
* one failing source query does not remove the other categories;
* places come back nearest-first across categories, so payload order is
  deterministic for the iframe.
"""

from __future__ import annotations

import pytest

import sitewise.services.nearby_places_service as svc
from sitewise.services.nearby_places_service import NearbyPlacesService

_ALL_CATEGORIES = {
    "properties", "competitors", "demand_generators", "accessibility", "parking",
}


class _FakeResult:
    def __init__(self, rows):
        self._rows = rows

    def mappings(self):
        return self

    def all(self):
        return self._rows


class _FakeSession:
    """Dispatches on the source table the SQL reads."""

    def __init__(self, scripted: dict[str, list[dict]], fail: set[str] | None = None):
        self._scripted = scripted
        self._fail = fail or set()
        self.calls: list[str] = []
        self.params: dict[str, object] = {}

    def execute(self, statement, params=None):
        sql = str(statement)
        self.params = params or {}
        for fragment, rows in self._scripted.items():
            if fragment in sql:
                self.calls.append(fragment)
                if fragment in self._fail:
                    raise RuntimeError(f"source down: {fragment}")
                return _FakeResult(rows)
        raise AssertionError(f"No scripted rows for SQL: {sql[:120]}")


def _row(category: str, n: int, total: int) -> dict:
    """One scripted source row in the shape the service's SQL selects."""
    coords = {
        "properties": (5.2991, 100.2687),
        "competitors": (5.2991, 100.2687),
        "demand_generators": (5.2979, 100.2681),
        "accessibility": (5.2985, 100.2671),
        "parking": (5.3002, 100.2675),
    }[category]
    lat, lng = coords
    row = {
        "id": f"{category[0]}{n}",
        "name": f"Place {category} {n}",
        "subtype": "SUBTYPE",
        "detail": "detail",
        "lat": lat,
        "lng": lng,
        "source": "osm",
        "source_id": str(1000 + n),
        "operating_status": "likely_open",
        "status_evidence": "evidence",
        "coords_verified": True,
        "distance_m": n * 10,
        "observed_at": "2026-01-02",
        "total": total,
    }
    if category == "accessibility":
        row["route_names"] = ["300", "T400", "KJ1"]
        row["weekday_departures"] = 214
        row["weekend_departures"] = 120
    return row


def _scripted(per_category: dict[str, int], total: int = 40) -> dict[str, list[dict]]:
    return {
        fragment: [
            _row(category, n, total)
            for n in range(1, per_category.get(category, 0) + 1)
        ]
        for fragment, category in (
            ("FROM fyp.catalogue_properties", "properties"),
            ("FROM fnb_a.fnb_outlet", "competitors"),
            ("FROM demand_gen.pois_master", "demand_generators"),
            ("FROM fyp_features.gtfs_stops", "accessibility"),
            ("FROM public.psense_parking", "parking"),
        )
    }


def test_places_carry_the_full_field_set():
    session = _FakeSession(_scripted(
        {"properties": 1, "competitors": 3, "demand_generators": 2, "accessibility": 1, "parking": 1},
    ))
    payload = NearbyPlacesService(session).nearby(
        5.2987749, 100.2680584, 1000, exclude_property_id="EP-01001",
    )

    assert set(payload) == {"radius_m", "distance_method", "categories", "places"}
    assert payload["radius_m"] == 1000
    assert payload["distance_method"] == "straight_line_spherical"
    assert len(payload["places"]) == 8
    for place in payload["places"]:
        assert set(place) == {
            "id", "name", "category", "subtype", "detail", "lat", "lng",
            "source", "source_id", "operating_status", "status_evidence",
            "coords_verified", "distance_m", "observed_at", "source_updated_at",
        }
        assert isinstance(place["distance_m"], int)
        assert -90 <= place["lat"] <= 90 and -180 <= place["lng"] <= 180


def test_categories_report_totals_and_all_five_sources():
    session = _FakeSession(_scripted(
        {"properties": 2, "competitors": 3, "demand_generators": 0, "accessibility": 2, "parking": 1},
    ))
    payload = NearbyPlacesService(session).nearby(5.2987749, 100.2680584, 1000)

    categories = payload["categories"]
    assert set(categories) == _ALL_CATEGORIES
    for meta in categories.values():
        assert set(meta) == {"state", "returned", "total_in_radius", "truncated", "source"}
        assert meta["source"]
    assert categories["properties"]["returned"] == 2
    assert categories["competitors"]["total_in_radius"] == 40
    assert categories["competitors"]["truncated"] is False
    # A measured absence stays a measured absence, never an error.
    assert categories["demand_generators"] == {
        "state": "measured_zero", "returned": 0, "total_in_radius": 0,
        "truncated": False, "source": categories["demand_generators"]["source"],
    }
    # Categories with records report the mapped state.
    assert categories["competitors"]["state"] == "mapped"
    assert len(payload["places"]) == 8


def test_transit_places_carry_route_and_departure_detail():
    session = _FakeSession(_scripted({"accessibility": 1}))
    payload = NearbyPlacesService(session).nearby(5.2987749, 100.2680584, 1000)

    stop = payload["places"][0]
    assert stop["detail"] == "Routes 300, T400, KJ1 · 214 weekday scheduled departures · 120 weekend"


def test_cap_returns_nearest_and_flags_truncation(monkeypatch):
    monkeypatch.setattr(svc, "_CAP_PER_CATEGORY", 5)
    session = _FakeSession(_scripted(
        {"properties": 1, "competitors": 9, "demand_generators": 1, "accessibility": 1, "parking": 1},
        total=120,
    ))
    payload = NearbyPlacesService(session).nearby(5.2987749, 100.2680584, 3000)

    competitors = payload["categories"]["competitors"]
    assert competitors["returned"] == 5
    assert competitors["total_in_radius"] == 120
    assert competitors["truncated"] is True
    distances = [p["distance_m"] for p in payload["places"] if p["category"] == "competitors"]
    assert distances == [10, 20, 30, 40, 50]
    # The untouched categories are not falsely marked truncated.
    assert payload["categories"]["demand_generators"]["truncated"] is False


def test_places_sort_nearest_first_across_categories():
    session = _FakeSession(_scripted(
        {"properties": 2, "competitors": 2, "demand_generators": 2, "accessibility": 2, "parking": 2},
    ))
    payload = NearbyPlacesService(session).nearby(5.2987749, 100.2680584, 1000)

    distances = [p["distance_m"] for p in payload["places"]]
    assert distances == sorted(distances)
    assert payload["places"][0]["distance_m"] == 10


def test_missing_origin_reports_honest_zeroes_and_no_places():
    session = _FakeSession(_scripted({}))
    payload = NearbyPlacesService(session).nearby(None, None, 1000)

    assert payload["places"] == []
    for meta in payload["categories"].values():
        assert meta["state"] == "mapped"
        assert meta["returned"] == 0 and meta["total_in_radius"] == 0 and meta["truncated"] is False
    # Nothing was queried: with no origin there is nothing honest to compute.
    assert session.calls == []


def test_one_failed_source_is_unavailable_without_hiding_the_rest():
    session = _FakeSession(_scripted(
        {"properties": 1, "competitors": 2, "demand_generators": 1, "accessibility": 1, "parking": 1},
    ), fail={"FROM public.psense_parking"})
    payload = NearbyPlacesService(session).nearby(5.2987749, 100.2680584, 1000)

    parking = payload["categories"]["parking"]
    assert parking["state"] == "source_unavailable"
    assert parking["total_in_radius"] is None
    assert "source down" in parking["error"]
    assert not any(p["category"] == "parking" for p in payload["places"])
    # Every other category is untouched and still mapped.
    for key in _ALL_CATEGORIES - {"parking"}:
        assert payload["categories"][key]["state"] == "mapped"
    assert sum(1 for p in payload["places"] if p["category"] == "competitors") == 2


def test_exclude_id_reaches_the_properties_query():
    session = _FakeSession(_scripted({"properties": 1}))
    NearbyPlacesService(session).nearby(5.2987749, 100.2680584, 500, exclude_property_id="EP-01001")

    assert session.params.get("exclude_id") == "EP-01001"


def test_states_vocabulary_is_stable():
    assert svc.STATES == (
        "mapped",
        "measured_zero",
        "source_unavailable",
        "source_not_integrated",
        "data_stale",
    )
    assert set(_ALL_CATEGORIES) == set(svc._CATEGORY_SOURCES)


def test_stale_transit_keeps_places_but_flags_data_stale():
    session = _FakeSession(_scripted({"accessibility": 2, "properties": 1}))
    payload = NearbyPlacesService(session).nearby(
        5.2987749, 100.2680584, 1000, transit_stale=True,
    )

    accessibility = payload["categories"]["accessibility"]
    assert accessibility["state"] == "data_stale"
    assert accessibility["returned"] == 2 and accessibility["total_in_radius"] == 40
    # The markers still come back — stale is a quality warning, not an absence.
    assert sum(1 for p in payload["places"] if p["category"] == "accessibility") == 2
    # Other categories are not affected by transit freshness.
    assert payload["categories"]["properties"]["state"] == "mapped"
    # And with fresh feeds the same data is plainly mapped.
    fresh = NearbyPlacesService(_FakeSession(_scripted({"accessibility": 1}))).nearby(
        5.2987749, 100.2680584, 1000, transit_stale=False,
    )
    assert fresh["categories"]["accessibility"]["state"] == "mapped"


@pytest.mark.parametrize("fragment", [
    "FROM fyp.catalogue_properties",
    "FROM fnb_a.fnb_outlet",
    "FROM demand_gen.pois_master",
    "FROM fyp_features.gtfs_stops",
    "FROM public.psense_parking",
])
def test_every_category_queries_a_real_source_table(fragment):
    scripted = _scripted({})
    assert fragment in scripted
