"""Contract tests for the nearby-places read model behind the map's markers.

These run without a database: the session is a fake that returns scripted
rows per source table, so what is asserted is the service's contract, not the
SQL (the SQL itself is validated against live PostgreSQL on real properties).

What is asserted here is deliberately narrow but load-bearing:

* every place carries the full field set the map needs — stable id, name,
  category + subtype, coordinate, source + source id, operating status,
  straight-line distance and observation date;
* the envelope reports per-category returned/total/truncated so "recorded
  totals vs mapped locations" can be shown honestly side by side;
* a capped category returns the nearest N and flags the truncation instead
  of silently shrinking the picture;
* a missing origin is not an error: every category reports an honest zero
  and no place is fabricated;
* places come back nearest-first across categories, so payload order is
  deterministic for the iframe.
"""

from __future__ import annotations

import sitewise.services.nearby_places_service as svc
from sitewise.services.nearby_places_service import NearbyPlacesService


class _FakeResult:
    def __init__(self, rows):
        self._rows = rows

    def mappings(self):
        return self

    def all(self):
        return self._rows


class _FakeSession:
    """Dispatches on the source table the SQL reads."""

    def __init__(self, scripted: dict[str, list[dict]]):
        self._scripted = scripted
        self.calls: list[str] = []

    def execute(self, statement, params=None):
        sql = str(statement)
        for fragment, rows in self._scripted.items():
            if fragment in sql:
                self.calls.append(fragment)
                return _FakeResult(rows)
        raise AssertionError(f"No scripted rows for SQL: {sql[:120]}")


def _row(category: str, n: int, total: int) -> dict:
    """One scripted source row in the shape the service's SQL selects."""
    coords = {
        "competitors": (5.2991, 100.2687),
        "demand_generators": (5.2979, 100.2681),
        "accessibility": (5.2985, 100.2671),
        "parking": (5.3002, 100.2675),
    }[category]
    lat, lng = coords
    return {
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


def _scripted(per_category: dict[str, int], total: int = 40) -> dict[str, list[dict]]:
    return {
        fragment: [
            _row(category, n, total)
            for n in range(1, per_category.get(category, 0) + 1)
        ]
        for fragment, category in (
            ("FROM fnb_a.fnb_outlet", "competitors"),
            ("FROM demand_gen.pois_master", "demand_generators"),
            ("FROM fyp_features.gtfs_stops", "accessibility"),
            ("FROM public.psense_parking", "parking"),
        )
    }


def test_places_carry_the_full_field_set():
    session = _FakeSession(_scripted({"competitors": 3, "demand_generators": 2, "accessibility": 1, "parking": 1}))
    payload = NearbyPlacesService(session).nearby(5.2987749, 100.2680584, 1000)

    assert set(payload) == {"radius_m", "categories", "places"}
    assert payload["radius_m"] == 1000
    assert len(payload["places"]) == 7
    for place in payload["places"]:
        assert set(place) == {
            "id", "name", "category", "subtype", "detail", "lat", "lng",
            "source", "source_id", "operating_status", "status_evidence",
            "coords_verified", "distance_m", "observed_at",
        }
        assert isinstance(place["distance_m"], int)
        assert -90 <= place["lat"] <= 90 and -180 <= place["lng"] <= 180


def test_categories_report_totals_and_all_four_sources():
    session = _FakeSession(_scripted({"competitors": 3, "demand_generators": 0, "accessibility": 2, "parking": 1}))
    payload = NearbyPlacesService(session).nearby(5.2987749, 100.2680584, 1000)

    categories = payload["categories"]
    assert set(categories) == {"competitors", "demand_generators", "accessibility", "parking"}
    for meta in categories.values():
        assert set(meta) == {"returned", "total_in_radius", "truncated", "source"}
        assert meta["source"]
    assert categories["competitors"]["returned"] == 3
    assert categories["competitors"]["total_in_radius"] == 40
    assert categories["competitors"]["truncated"] is False
    # A measured absence stays a measured absence: zero returned, zero total.
    assert categories["demand_generators"] == {
        "returned": 0, "total_in_radius": 0, "truncated": False,
        "source": categories["demand_generators"]["source"],
    }
    assert len(payload["places"]) == 6


def test_cap_returns_nearest_and_flags_truncation(monkeypatch):
    monkeypatch.setattr(svc, "_CAP_PER_CATEGORY", 5)
    session = _FakeSession(_scripted({"competitors": 9, "demand_generators": 1, "accessibility": 1, "parking": 1}, total=120))
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
    session = _FakeSession(_scripted({"competitors": 2, "demand_generators": 2, "accessibility": 2, "parking": 2}))
    payload = NearbyPlacesService(session).nearby(5.2987749, 100.2680584, 1000)

    distances = [p["distance_m"] for p in payload["places"]]
    assert distances == sorted(distances)
    assert payload["places"][0]["distance_m"] == 10


def test_missing_origin_reports_honest_zeroes_and_no_places():
    session = _FakeSession(_scripted({}))
    payload = NearbyPlacesService(session).nearby(None, None, 1000)

    assert payload["places"] == []
    for meta in payload["categories"].values():
        assert meta["returned"] == 0 and meta["total_in_radius"] == 0 and meta["truncated"] is False
    # Nothing was queried: with no origin there is nothing honest to compute.
    assert session.calls == []
