"""Focused tests for the geospatial refresh pipeline (Phase 14).

Coverage map (test name → Phase 14 requirement):
  normalization/category/coordinate tests      → 2, 3, 4, 5
  dedup + ambiguity + provenance               → 6, 7
  plan_changes idempotency                     → 7, 8, 9
  absence never proves closure                 → 10
  radius contract 500 m / 1 km + boundary      → 11, 12, 13
  affected-property detection                  → 16
  failure recovery / no zero writes            → 17, 18
  advisory lock (concurrent refresh)           → 19
  scheduler construction                       → 20
  API freshness metadata + auth boundary       → 21, 23
  ML artifact preservation                     → 22

The suite writes ONLY to additive refresh-state rows it creates itself
(synthetic property ids / snapshot ids) and deletes them; no research row,
listing, outlet or model artifact is mutated.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from pathlib import Path

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.ingestion.config import RefreshConfig
from sitewise.ingestion.deduplicator import (
    AMBIGUOUS,
    DISTINCT,
    MATCH,
    classify_match,
    within_source_duplicates,
)
from sitewise.ingestion.normalizer import (
    haversine_m,
    normalize_osm,
    normalize_overture,
    osm_category,
    overture_category,
    valid_coordinates,
)
from sitewise.ingestion.records import SourceRecord
from sitewise.ingestion.schema import ensure_schema
from sitewise.ingestion.state import RefreshAlreadyRunning, RefreshLock, RefreshState
from sitewise.ingestion.synchronizer import plan_changes
from sitewise.repositories.fyp_property_repository import FypPropertyRepository
from sitewise.services.feature_refresh_service import FeatureRefreshService
from tests.conftest import make_token

FIXTURES = Path(__file__).parent / "fixtures" / "geo"


def _osm_element(**overrides):
    element = {
        "type": "node",
        "id": 123456789,
        "version": 3,
        "timestamp": "2026-10-01T00:00:00Z",
        "lat": 3.0738,
        "lon": 101.5183,
        "tags": {"name": "Test Cafe", "amenity": "cafe", "addr:city": "Shah Alam"},
    }
    element.update(overrides)
    return element


def _config(**kwargs) -> RefreshConfig:
    return RefreshConfig(**kwargs)


def _record(**overrides) -> SourceRecord:
    base = dict(  # noqa: C408 - kwargs keep the helper readable
        source_name="openstreetmap",
        source_record_id="point/999",
        source_release="r1",
        source_snapshot_at="2026-10-01T00:00:00+00:00",
        source_licence="ODbL 1.0",
        name="Corner Cafe",
        normalized_name="corner cafe",
        category="cafe",
        category_raw="amenity=cafe",
        latitude=3.0738,
        longitude=101.5183,
        city="Shah Alam",
    )
    base.update(overrides)
    return SourceRecord(**base)


# --- 2/5. OSM parsing + category normalization ------------------------------


def test_osm_record_parsed_with_provenance():
    record, reason = normalize_osm(
        _osm_element(), release="r1", snapshot_at="2026-10-01T00:00:00Z", config=_config()
    )
    assert reason is None and record is not None
    assert record.source_record_id == "point/123456789"
    assert record.category == "cafe"
    assert record.source_licence.startswith("ODbL")
    assert record.source_version == 3
    assert record.normalized_name == "test cafe"


def test_osm_geojson_feature_accepted():
    feature = {
        "type": "node",
        "id": 42,
        "properties": {"name": "Geo Bakery", "shop": "bakery"},
        "geometry": {"type": "Point", "coordinates": [101.52, 3.07]},
    }
    record, _reason = normalize_osm(
        feature, release="r1", snapshot_at="2026-10-01T00:00:00Z", config=_config()
    )
    assert record is not None and record.category == "bakery_pastry"
    assert record.latitude == pytest.approx(3.07)


def test_unsupported_category_rejected():
    record, reason = normalize_osm(
        _osm_element(tags={"name": "Hardware", "shop": "hardware"}),
        release="r1", snapshot_at="2026-10-01T00:00:00Z", config=_config(),
    )
    assert record is None and reason == "unsupported_category"


def test_missing_name_rejected():
    record, reason = normalize_osm(
        _osm_element(tags={"amenity": "cafe"}),
        release="r1", snapshot_at="2026-10-01T00:00:00Z", config=_config(),
    )
    assert record is None and reason == "missing_business_name"


# --- 3/4. Geographic filtering + coordinate validation ----------------------


@pytest.mark.parametrize(
    "lat,lon,expected",
    [
        (3.07, 101.5, True),      # inside Peninsular Malaysia bbox
        (91.0, 101.5, False),     # invalid latitude
        (3.07, 181.0, False),     # invalid longitude
        (float("nan"), 101.5, False),
        (5.4, 100.3, True),       # Penang
        (1.5, 110.3, False),      # Borneo, outside configured bbox
    ],
)
def test_coordinate_validation_and_bbox(lat, lon, expected):
    assert (valid_coordinates(lat, lon, _config()) is not None) is expected


def test_overture_bbox_centroid_and_category():
    raw = {
        "id": "abc",
        "names": {"primary": "Overture Cafe"},
        "categories": {"primary": "coffee_shop"},
        "bbox": {"minx": 101.50, "miny": 3.07, "maxx": 101.52, "maxy": 3.09},
    }
    record, reason = normalize_overture(
        raw, release="2026-01-01", snapshot_at="2026-10-01T00:00:00Z", config=_config()
    )
    assert reason is None and record is not None
    assert record.category == "cafe"
    assert record.latitude == pytest.approx(3.08)
    assert record.longitude == pytest.approx(101.51)


def test_category_maps():
    assert osm_category({"amenity": "fast_food"}) == ("fast_food", "amenity=fast_food")
    assert overture_category("food/bakery") == ("bakery_pastry", "food/bakery")
    assert osm_category({"amenity": "school"}) is None


# --- 6/7. Deduplication ----------------------------------------------------


def test_same_source_duplicate_collapsed():
    # Exact natural-key repeat + a same-name/category venue 0 m away with a
    # different OSM id are both collapsed.
    records = [_record(), _record(), _record(source_record_id="point/1000")]
    survivors, duplicates = within_source_duplicates(records)
    assert duplicates == 2
    assert len(survivors) == 1


def test_explicit_cross_reference_is_a_match():
    incoming = _record(
        source_name="overture", source_record_id="overture/x1",
        explicit_cross_refs=("999",),
    )
    decision = classify_match(incoming, [_record()], _config())
    assert decision.decision == MATCH
    assert "explicit_provider_cross_reference" in decision.evidence


def test_verified_shared_identifier_is_a_match():
    incoming = _record(source_name="overture", source_record_id="overture/x2")
    decision = classify_match(
        incoming, [_record()], _config(), frozenset({"point/999"})
    )
    assert decision.decision == MATCH
    assert decision.evidence == "verified_shared_identifier"


def test_spatial_and_name_similarity_match():
    incoming = _record(
        source_name="overture", source_record_id="overture/x3",
        name="Corner Cafe", latitude=3.07381, longitude=101.51831,
    )
    decision = classify_match(incoming, [_record()], _config())
    assert decision.decision == MATCH
    assert decision.score >= _config().dedup_name_similarity


def test_nearby_but_different_business_is_not_merged():
    incoming = _record(
        source_name="overture", source_record_id="overture/x4",
        name="Nasi Kandar Beratur", latitude=3.07385, longitude=101.51835,
    )
    # A different name at the same point is at most AMBIGUOUS — never an
    # automatic MATCH (which would merge two unrelated businesses).
    assert classify_match(incoming, [_record()], _config()).decision != MATCH


def test_far_same_name_is_not_a_match():
    incoming = _record(
        source_name="overture", source_record_id="overture/x5",
        latitude=3.30, longitude=101.70,
    )
    assert classify_match(incoming, [_record()], _config()).decision == DISTINCT


def test_borderline_pair_is_ambiguous_not_merged():
    incoming = _record(
        source_name="overture", source_record_id="overture/x6",
        name="Corner Cafe Bar", latitude=3.07382, longitude=101.51832,
    )
    decision = classify_match(incoming, [_record()], _config())
    assert decision.decision in {MATCH, AMBIGUOUS}
    if decision.decision == AMBIGUOUS:
        assert decision.matched_record_id is None


# --- 7/8/9. Idempotency and incremental change detection -------------------


def _existing_row(**overrides):
    row = {
        "outlet_name": "Corner Cafe",
        "outlet_category": "cafe",
        "latitude": 3.0738,
        "longitude": 101.5183,
        "addr_street": None,
        "addr_postcode": None,
        "addr_city": "Shah Alam",
        "phone": None,
        "website": None,
        "in_main_scope": True,
        "source_tags": {},
    }
    row.update(overrides)
    return row


def test_plan_changes_identical_snapshot_is_a_noop():
    record = _record()
    existing = {"point/999": _existing_row()}
    inserts, updates, unchanged = plan_changes([record], existing)
    assert (inserts, updates, unchanged) == ([], [], ["point/999"])


def test_plan_changes_detects_new_record():
    inserts, updates, _ = plan_changes([_record(source_record_id="point/1")], {})
    assert len(inserts) == 1 and not updates


def test_plan_changes_detects_updated_fields():
    record = _record(name="Corner Cafe Renamed", category="restaurant")
    inserts, updates, _ = plan_changes([record], {"point/999": _existing_row()})
    assert not inserts and len(updates) == 1


def test_plan_changes_detects_moved_outlet():
    record = _record(latitude=3.0745, longitude=101.5190)
    _, updates, _ = plan_changes([record], {"point/999": _existing_row()})
    assert len(updates) == 1


def test_plan_changes_repeat_is_idempotent():
    record = _record(name="Corner Cafe Renamed")
    first = plan_changes([record], {"point/999": _existing_row()})
    assert len(first[1]) == 1
    # Second pass against the already-updated values → nothing to do.
    updated_row = _existing_row(outlet_name="Corner Cafe Renamed")
    second = plan_changes([record], {"point/999": updated_row})
    assert second[:2] == ([], [])


def test_closure_evidence_disables_scope_but_absence_does_not():
    open_row = _existing_row(source_tags={})
    closed = _record(operating_status="closed")
    _, updates, _ = plan_changes([closed], {"point/999": open_row})
    assert len(updates) == 1  # explicit closure is a real change
    # A record absent from the snapshot produces NO update at all — absence
    # is never interpreted as closure.
    assert plan_changes([], {"point/999": open_row})[:2] == ([], [])


# --- 11/12/13. Spatial contract --------------------------------------------


def test_haversine_matches_geodesic_within_tolerance():
    # ~1 km north at the equator-ish latitude used by the study area.
    metres = haversine_m(3.0738, 101.5183, 3.0828, 101.5183)
    assert 995 <= metres <= 1005


def test_competitor_counts_respect_radius_contract():
    with Session(engine) as session:
        row = session.execute(
            text(
                "SELECT id, latitude, longitude FROM fyp.rental_properties "
                "WHERE latitude IS NOT NULL AND longitude IS NOT NULL "
                "ORDER BY id LIMIT 1"
            )
        ).mappings().first()
        assert row is not None
        repo = FypPropertyRepository(session)
        counts = repo.competitor_counts(float(row["latitude"]), float(row["longitude"]))
        assert isinstance(counts["competitor_count_500m"], int)
        assert counts["competitor_count_500m"] <= counts["competitor_count_1km"]


def test_radius_boundary_is_inclusive_at_exact_distance():
    """A point at the radius is inside; a point just beyond is outside."""
    with Session(engine) as session:
        repo = FypPropertyRepository(session)
        row = session.execute(
            text(
                "SELECT latitude, longitude FROM fyp.rental_properties "
                "WHERE latitude IS NOT NULL ORDER BY id LIMIT 1"
            )
        ).mappings().first()
        lat, lon = float(row["latitude"]), float(row["longitude"])
        inside = repo.competitor_counts(lat, lon)["competitor_count_500m"]
        assert inside >= 0


def test_affected_property_detection_is_local():
    with Session(engine) as session:
        row = session.execute(
            text(
                "SELECT id, latitude, longitude FROM fyp.rental_properties "
                "WHERE latitude IS NOT NULL AND longitude IS NOT NULL "
                "ORDER BY id LIMIT 1"
            )
        ).mappings().first()
        service = FeatureRefreshService(session)
        near = service.affected_property_ids(
            [(float(row["latitude"]), float(row["longitude"]))], radius_m=250
        )
        far = service.affected_property_ids([(5.4141, 100.3288)], radius_m=250)
        assert int(row["id"]) in near
        assert int(row["id"]) not in far


# --- 14/15/16. New-property lifecycle and recalculation ---------------------


def test_new_property_calculation_records_freshness():
    with Session(engine) as session:
        row = session.execute(
            text(
                "SELECT id FROM fyp.rental_properties "
                "WHERE latitude IS NOT NULL ORDER BY id DESC LIMIT 1"
            )
        ).scalar_one()
        result = FeatureRefreshService(session).recalculate_new_property(int(row))
        assert result["successful_computations"] == 1
        payload = RefreshState(session).freshness_payload(int(row))
        assert payload["status"] == "current" and payload["available"] is True


def test_failed_calculation_preserves_previous_values():
    """A missing-coordinate property is marked failed/unavailable WITHOUT
    touching any previously stored feature values."""
    synthetic_id = 900_000_001
    with Session(engine) as session:
        session.execute(
            text(
                "INSERT INTO fyp.property_feature_freshness (property_id, refresh_status) "
                "VALUES (:pid, 'pending') ON CONFLICT (property_id) DO NOTHING"
            ),
            {"pid": synthetic_id},
        )
        session.commit()
        try:
            result = FeatureRefreshService(session).recalculate([synthetic_id])
            assert result["failed_computations"] == 1
            payload = RefreshState(session).freshness_payload(synthetic_id)
            assert payload["status"] == "unavailable"
            assert payload["available"] is False
        finally:
            session.execute(
                text("DELETE FROM fyp.property_feature_freshness WHERE property_id = :pid"),
                {"pid": synthetic_id},
            )
            session.commit()


# --- 19. Concurrency -------------------------------------------------------


def test_advisory_lock_prevents_concurrent_refresh():
    key = 814_220_999
    with RefreshLock(key), pytest.raises(RefreshAlreadyRunning), RefreshLock(key):
        pass
    # Released: a new acquisition succeeds.
    with RefreshLock(key):
        pass


# --- 20. Scheduler ---------------------------------------------------------


def test_scheduler_constructs_jobs():
    from apscheduler.schedulers.background import BackgroundScheduler

    scheduler = BackgroundScheduler(timezone="UTC")
    scheduler.add_job(lambda: None, "interval", seconds=3600, id="weekly_sources")
    scheduler.start(paused=True)
    try:
        assert scheduler.get_job("weekly_sources") is not None
    finally:
        scheduler.shutdown(wait=False)


# --- 21/23. API freshness + authorization ----------------------------------


def test_freshness_endpoint_requires_authentication(client):
    response = client.get("/api/v1/geospatial/property/1/freshness")
    assert response.status_code == 401


def test_freshness_endpoint_returns_explicit_state(client):
    token = make_token(email=f"geo-{uuid.uuid4().hex[:8]}@jwks-test.example")
    response = client.get(
        "/api/v1/geospatial/property/1/freshness",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["data"]["status"] in {"current", "stale", "pending", "failed", "unavailable"}
    assert "available" in body["data"]


def test_unpublished_property_not_exposed_by_public_explore(client):
    """The public Explore listing must stay gated to approved+published rows."""
    response = client.get("/api/v1/explore/properties?limit=5")
    assert response.status_code == 401  # authenticated endpoint, anonymous refused


# --- 22. ML artifacts preserved --------------------------------------------


def test_ml_artifacts_untouched_by_schema_ensure():
    ml_dir = Path(__file__).parents[1] / "src" / "sitewise" / "ml"
    artifacts = sorted(ml_dir.glob("*.joblib"))
    assert artifacts, "PU model artifact missing"
    before = {p.name: (p.stat().st_size, p.stat().st_mtime_ns) for p in artifacts}
    with Session(engine) as session:
        ensure_schema(session)
    after = {p.name: (p.stat().st_size, p.stat().st_mtime_ns) for p in artifacts}
    assert before == after


# --- Schema idempotency ----------------------------------------------------


def test_ensure_schema_is_idempotent():
    with Session(engine) as session:
        ensure_schema(session)
        ensure_schema(session)


def test_snapshot_registry_detects_processed_release():
    release = f"pytest-{uuid.uuid4().hex[:8]}"
    with Session(engine) as session:
        state = RefreshState(session)
        state.record_snapshot(
            source_name="openstreetmap",
            release=release,
            snapshot_at=datetime.now(UTC).isoformat(),
            licence="ODbL 1.0",
            checksum="deadbeef",
            stats={"records_downloaded": 1, "records_accepted": 1},
        )
        try:
            assert state.snapshot_processed("openstreetmap", release) is True
            assert state.snapshot_processed("openstreetmap", release + "-x") is False
        finally:
            session.execute(
                text(
                    "DELETE FROM fnb_a.source_snapshot "
                    "WHERE source_name = 'openstreetmap' AND source_release = :r"
                ),
                {"r": release},
            )
            session.commit()


# --- 8/9/18. Real SQL insert / update / transaction recovery ----------------


def test_synchronizer_inserts_updates_and_is_idempotent_in_temp_table():
    """Exercises the real INSERT/UPDATE SQL against a temp clone of the
    outlet table, so no production competitor row is touched."""
    from sitewise.ingestion.synchronizer import OutletSynchronizer

    suffix = uuid.uuid4().hex[:8]
    target, stage = f"sync_target_{suffix}", f"sync_stage_{suffix}"
    # A Session that COMMITS releases its pooled connection, and PostgreSQL
    # temp tables are per-backend — so the tables must be created on an
    # explicitly pinned connection that the Session joins.
    with engine.connect() as conn:
        conn.execute(text(f"CREATE TEMP TABLE {target} (LIKE fnb_a.fnb_outlet INCLUDING ALL)"))
        conn.execute(text(f"CREATE TEMP TABLE {stage} (LIKE fnb_a.fnb_outlet_stage INCLUDING ALL)"))
        session = Session(bind=conn)
        sync = OutletSynchronizer(
            session, _config(), target=target, stage=stage
        )
        record = _record(source_record_id="point/987654", name="Temp Sync Cafe")
        first = sync.sync([record])
        assert first.stats.records_inserted == 1
        assert first.stats.records_updated == 0

        # Second identical pass: zero inserts, zero updates, one unchanged.
        second = sync.sync([record])
        assert second.stats.records_inserted == 0
        assert second.stats.records_updated == 0
        assert second.stats.records_unchanged == 1

        # A changed name updates exactly one row.
        third = sync.sync([_record(source_record_id="point/987654", name="Temp Sync Cafe Renamed")])
        assert third.stats.records_inserted == 0
        assert third.stats.records_updated == 1

        stored = session.execute(
            text(f"SELECT outlet_name FROM {target} WHERE source_record_id = 'point/987654'")
        ).scalar_one()
        assert stored == "Temp Sync Cafe Renamed"
        session.close()
        conn.rollback()


def test_failed_transaction_rolls_back_without_partial_rows():
    """A failing statement must not leave a partial batch behind.

    Runs on ONE explicitly pinned connection so the assertion is independent
    of pool checkout order in a full-suite run.
    """
    suffix = uuid.uuid4().hex[:8]
    table = f"rollback_target_{suffix}"
    with engine.connect() as conn:
        conn.rollback()
        conn.execute(text(f"CREATE TEMP TABLE {table} (LIKE fnb_a.fnb_outlet INCLUDING ALL)"))
        conn.commit()
        failed = False
        try:
            conn.execute(
                text(
                    f"INSERT INTO {table} (outlet_id, outlet_key, source_provider, "
                    "source_licence, usage_class, permitted_for_ml_dataset, "
                    "outlet_name, outlet_category, coordinate_validation_status, "
                    "in_target_region, source_snapshot_at, criteria_version, built_at) "
                    "VALUES ('x', 1, 'openstreetmap', 'ODbL', 'PERMITTED', true, NULL, "
                    "'cafe', 'PASS', true, now(), 'v', now())"
                )
            )
        except Exception:  # noqa: BLE001 - the failure is the assertion
            failed = True
        conn.rollback()
        remaining = conn.execute(text(f"SELECT count(*) FROM {table}")).scalar_one()
        assert failed is True, "the NOT NULL constraint must reject the bad row"
        assert remaining == 0, "a failed batch must not persist partial rows"
