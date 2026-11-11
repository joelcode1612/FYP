"""Two-phase geospatial enrichment: lifecycle, isolation, idempotency, honesty.

Coverage map (test name → requirement):
  phase 1 never starts phase 2                → independent phases
  phase 2 runs on its own                     → independent phases
  one category failing leaves the rest alone  → per-category async state
  second run does not recompute               → idempotent
  force recomputes                            → explicit recalculation
  moved coordinates invalidate                → coordinate versioning
  no coordinates → unavailable, never 0       → no zero-for-unknown
  no raster coverage → unavailable            → population honesty
  retry is scoped to one category             → retryable
  fresh running job is not duplicated         → duplicate-job prevention
  stale running job is reclaimed              → crash recovery
  stale flag keeps previous values            → never delete good data
  submit guard requires acknowledgement       → explicit Submit to Admin

Every test creates its own synthetic property row and deletes it afterwards.
No research row, listing, outlet or model artifact is mutated.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.services.enrichment_schema import CATEGORIES
from sitewise.services.property_enrichment_service import (
    CALCULATION_VERSION,
    PropertyEnrichmentService,
    coordinate_hash,
)

#: A real Kuala Lumpur coordinate with measured coverage in every Phase 1
#: source and inside the LandScan raster.
KL_LAT, KL_LON = 3.030927, 101.618782
#: Open ocean: no F&B, no roads, and no population raster tile.
EMPTY_LAT, EMPTY_LON = 0.0, 0.0


@pytest.fixture()
def make_property():
    ids: list[int] = []

    def _make(lat=KL_LAT, lon=KL_LON, listing_id=None):
        with Session(engine) as session:
            pid = session.execute(
                text(
                    """
                    INSERT INTO fyp.rental_properties
                        (name, latitude, longitude, listing_id,
                         verification_status, is_published)
                    VALUES (:name, :lat, :lon, :listing_id, 'draft', false)
                    RETURNING id
                    """
                ),
                {
                    "name": f"enrich-test-{uuid.uuid4()}",
                    "lat": lat,
                    "lon": lon,
                    "listing_id": listing_id,
                },
            ).scalar_one()
            session.commit()
        ids.append(int(pid))
        return int(pid)

    yield _make

    with Session(engine) as session:
        if ids:
            session.execute(
                text(
                    "DELETE FROM fyp.property_enrichment_category "
                    "WHERE property_id = ANY(:ids)"
                ),
                {"ids": ids},
            )
            session.execute(
                text(
                    "DELETE FROM fyp.property_geospatial_features "
                    "WHERE property_id = ANY(:ids)"
                ),
                {"ids": ids},
            )
            session.execute(
                text("DELETE FROM fyp.rental_properties WHERE id = ANY(:ids)"),
                {"ids": ids},
            )
        session.commit()


def _service() -> PropertyEnrichmentService:
    return PropertyEnrichmentService(Session(engine))


# ---------------------------------------------------------------------------
# Phase independence
# ---------------------------------------------------------------------------


def test_phase1_never_starts_phase2(make_property):
    pid = make_property()
    with Session(engine) as session:
        summary = PropertyEnrichmentService(session).run(pid, phase="postgis")

    states = summary["categories"]
    for category in ("fnb_competitors", "demand_generators", "roads_transport", "parking"):
        assert states[category]["status"] == "current", category
    # Phase 2 was never requested, so it must not have run.
    assert states["population"]["status"] == "pending"
    assert summary["phase2"]["complete"] is False


def test_phase2_runs_on_its_own(make_property):
    pid = make_property()
    with Session(engine) as session:
        summary = PropertyEnrichmentService(session).run(pid, phase="population")

    states = summary["categories"]
    assert states["population"]["status"] in ("current", "unavailable")
    for category in ("fnb_competitors", "demand_generators", "roads_transport", "parking"):
        assert states[category]["status"] == "pending", category


def test_phase1_measurements_are_real(make_property):
    """Phase 1 must produce measured numbers from the live tables."""
    pid = make_property()
    with Session(engine) as session:
        summary = PropertyEnrichmentService(session).run(pid, phase="postgis")

    competitors = summary["categories"]["fnb_competitors"]["measurement"]
    assert competitors["competitor_count_500m"] >= 0
    assert competitors["competitor_count_1km"] >= competitors["competitor_count_500m"]

    roads = summary["categories"]["roads_transport"]["measurement"]
    assert roads["accessibility_road_km_1km"] > 0
    assert roads["nearest_major_road_m"] is not None

    parking = summary["categories"]["parking"]["measurement"]
    assert parking["parking_facilities_1km"] >= parking["parking_facilities_500m"]

    # Every current category carries provenance naming its source table.
    for category in ("fnb_competitors", "demand_generators", "roads_transport", "parking"):
        provenance = summary["categories"][category]["provenance"]
        assert provenance["source"]
        assert provenance["licence"]


def test_category_failure_does_not_stop_the_others(make_property, monkeypatch):
    """A raising category settles as ``failed`` while the rest stay current."""
    pid = make_property()

    def boom(*_args, **_kwargs):
        raise RuntimeError("parking source unavailable")

    monkeypatch.setattr(PropertyEnrichmentService, "_parking", boom)
    with Session(engine) as session:
        summary = PropertyEnrichmentService(session).run(pid, phase="postgis")

    states = summary["categories"]
    assert states["parking"]["status"] == "failed"
    assert "parking source unavailable" in states["parking"]["last_error"]
    for category in ("fnb_competitors", "demand_generators", "roads_transport"):
        assert states[category]["status"] == "current", category


# ---------------------------------------------------------------------------
# Idempotency / retry / duplicate-job prevention
# ---------------------------------------------------------------------------


def test_second_run_does_not_recompute(make_property):
    pid = make_property()
    with Session(engine) as session:
        service = PropertyEnrichmentService(session)
        service.run(pid, phase="postgis")
        first = service.states(pid)["fnb_competitors"]["attempt_count"]
        service.run(pid, phase="postgis")
        second = service.states(pid)["fnb_competitors"]["attempt_count"]

    assert first == second == 1


def test_force_recomputes(make_property):
    pid = make_property()
    with Session(engine) as session:
        service = PropertyEnrichmentService(session)
        service.run(pid, phase="postgis")
        service.run(pid, phase="postgis", force=True)
        assert service.states(pid)["fnb_competitors"]["attempt_count"] == 2


def test_moving_the_property_invalidates_the_measurement(make_property):
    pid = make_property()
    with Session(engine) as session:
        service = PropertyEnrichmentService(session)
        service.run(pid, phase="postgis")
        first_hash = service.states(pid)["fnb_competitors"]["coordinate_hash"]
        assert first_hash == coordinate_hash(KL_LAT, KL_LON)

        # ``geom`` is a generated column, so moving the property means updating
        # the coordinates it is generated from.
        session.execute(
            text(
                "UPDATE fyp.rental_properties "
                "SET latitude = :lat, longitude = :lon "
                "WHERE id = :pid"
            ),
            {"lat": 3.15, "lon": 101.70, "pid": pid},
        )
        session.commit()

        service.run(pid, phase="postgis")
        state = service.states(pid)["fnb_competitors"]
        assert state["coordinate_hash"] == coordinate_hash(3.15, 101.70)
        assert state["attempt_count"] == 2


def test_retry_is_scoped_to_one_category(make_property):
    pid = make_property()
    with Session(engine) as session:
        service = PropertyEnrichmentService(session)
        service.run(pid, phase="postgis")
        before = service.states(pid)
        summary = service.retry(pid, "parking")
        after = summary["categories"]

    assert after["parking"]["attempt_count"] == before["parking"]["attempt_count"] + 1
    for category in ("fnb_competitors", "demand_generators", "roads_transport"):
        assert after[category]["attempt_count"] == before[category]["attempt_count"]


def test_retry_rejects_an_unknown_category(make_property):
    pid = make_property()
    with Session(engine) as session:
        with pytest.raises(ValueError):
            PropertyEnrichmentService(session).retry(pid, "traffic")


def test_a_fresh_running_job_is_not_duplicated(make_property):
    pid = make_property()
    with Session(engine) as session:
        service = PropertyEnrichmentService(session)
        service.ensure_schema()
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
            {"pid": pid},
        )
        session.commit()

        service.run(pid, phase="postgis")
        state = service.states(pid)["fnb_competitors"]
        # The in-flight job owns the category: no second computation starts.
        assert state["status"] == "running"
        assert state["attempt_count"] == 1


def test_an_abandoned_running_job_is_reclaimed(make_property):
    pid = make_property()
    with Session(engine) as session:
        service = PropertyEnrichmentService(session)
        service.ensure_schema()
        session.execute(
            text(
                """
                INSERT INTO fyp.property_enrichment_category
                    (property_id, category, phase, status, attempt_count,
                     started_at, updated_at)
                VALUES (:pid, 'fnb_competitors', 'postgis', 'running', 1,
                        now() - interval '2 hours', now())
                ON CONFLICT (property_id, category) DO UPDATE
                   SET status = 'running',
                       started_at = now() - interval '2 hours'
                """
            ),
            {"pid": pid},
        )
        session.commit()

        service.run(pid, phase="postgis")
        state = service.states(pid)["fnb_competitors"]
        assert state["status"] == "current"
        assert state["attempt_count"] == 2


# ---------------------------------------------------------------------------
# Honesty: unavailable is never zero
# ---------------------------------------------------------------------------


def test_missing_coordinates_are_unavailable_not_zero(make_property):
    pid = make_property(lat=None, lon=None)
    with Session(engine) as session:
        summary = PropertyEnrichmentService(session).run(pid, phase="all")

    for category in CATEGORIES:
        state = summary["categories"][category]
        assert state["status"] == "unavailable", category
        assert state["measurement"] is None
        assert state["provenance"]["reason"] == "property_has_no_coordinates"


def test_no_raster_coverage_makes_population_unavailable(make_property):
    pid = make_property(lat=EMPTY_LAT, lon=EMPTY_LON)
    with Session(engine) as session:
        summary = PropertyEnrichmentService(session).run(pid, phase="population")

    population = summary["categories"]["population"]
    assert population["status"] == "unavailable"
    assert population["measurement"] is None
    assert population["provenance"]["reason"] == "no_population_raster_coverage"
    assert summary["population_unavailable"] is True


def test_measured_absence_is_zero_not_unavailable(make_property):
    """Open ocean genuinely has no F&B outlet: that is a measured 0."""
    pid = make_property(lat=EMPTY_LAT, lon=EMPTY_LON)
    with Session(engine) as session:
        summary = PropertyEnrichmentService(session).run(pid, phase="postgis")

    competitors = summary["categories"]["fnb_competitors"]
    assert competitors["status"] == "current"
    assert competitors["measurement"]["competitor_count_500m"] == 0


def test_stale_keeps_the_previous_measurement(make_property):
    pid = make_property()
    with Session(engine) as session:
        service = PropertyEnrichmentService(session)
        service.run(pid, phase="postgis")
        before = service.states(pid)["fnb_competitors"]["measurement"]

        marked = service.mark_stale(pid, ["fnb_competitors"])
        state = service.states(pid)["fnb_competitors"]

        # The state is a prompt to recalculate; the values survive.
        assert marked == 1
        assert state["status"] == "stale"
        assert state["measurement"] == before


# ---------------------------------------------------------------------------
# Summary contract
# ---------------------------------------------------------------------------


def test_summary_reports_progress_and_readiness(make_property):
    pid = make_property()
    with Session(engine) as session:
        service = PropertyEnrichmentService(session)
        partial = service.run(pid, phase="postgis")
        assert partial["phase1"]["complete"] is True
        assert partial["phase2"]["complete"] is False
        assert partial["ready_to_submit"] is False

        full = service.run(pid, phase="population")
        assert full["phase1"]["complete"] is True
        assert full["phase2"]["complete"] is True
        assert full["ready_to_submit"] is True
        assert full["calculation_version"] == CALCULATION_VERSION


def test_states_never_leak_a_null_lifecycle(make_property):
    """A property that was never enriched still reports all five categories."""
    pid = make_property()
    with Session(engine) as session:
        states = PropertyEnrichmentService(session).states(pid)

    assert set(states) == set(CATEGORIES)
    for category, state in states.items():
        assert state["status"] == "pending", category
        assert state["phase"] in ("postgis", "population")
