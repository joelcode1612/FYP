"""Unit tests for the official-Malaysia-GTFS importer.

A minimal GTFS ZIP is built in memory and pushed through the real parser and
derivation code, so what is asserted is the contract the ``fyp_features.gtfs_*``
tables were built on: feed-prefixed uids, honest coordinate filtering,
calendar/daytype resolution, departure seconds, route/stop joins and the
rapid-rail mode registry. Database writes are NOT exercised here — applying a
feed runs against live PostgreSQL and is verified separately with --dry-run
plus one real feed refresh.
"""

from __future__ import annotations

import io
import json
import zipfile
from datetime import date
from pathlib import Path

import pytest

import sitewise.ingestion.sources.gtfs_importer as gtfs
from sitewise.ingestion.sources.gtfs_importer import (
    FEEDS,
    GtfsImportError,
    parse_feed,
)


def _zip_bytes(files: dict[str, str]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as zf:
        for name, content in files.items():
            zf.writestr(name, content)
    return buffer.getvalue()


def _minimal_files() -> dict[str, str]:
    return {
        "feed_info.txt": "feed_publisher_name,feed_version\nTest Transit,v2026.11\n",
        "stops.txt": (
            "stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station\n"
            "S1,Central,3.10,101.60,0,\n"
            "S2,Depot,3.20,101.70,0,\n"
            "S3,Bad coords,0,0,0,\n"
            "S4,Out of range,95,101.6,0,\n"
            "S1,Central duplicate,3.11,101.61,0,\n"
            "S5,No coords,1.0,,0,\n"
        ),
        "routes.txt": (
            "route_id,route_short_name,route_long_name,route_type\n"
            "R1,300,Test Bus Line,3\n"
            "R2,KGL,Kajang Line,1\n"
        ),
        "trips.txt": (
            "trip_id,route_id,service_id\n"
            "T1,R1,SA\n"
            "T2,R2,SA\n"
            "T3,R1,SB\n"
            "T4,R9,SA\n"
        ),
        "stop_times.txt": (
            "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
            "T1,,14:04:00,S1,1\n"
            "T1,,15:00:00,S2,2\n"
            "T2,,25:30:00,S2,1\n"
            "T2,,08:00:00,S1,2\n"
            "T3,,07:00:00,S1,1\n"
            "T4,,09:00:00,S1,1\n"
        ),
        "calendar.txt": (
            "service_id,mon,tue,wed,thu,fri,sat,sun,start,end\n"
            "SA,1,1,1,1,1,1,1,20261101,20261231\n"
        ),
        "calendar_dates.txt": (
            "service_id,date,exception_type\n"
            "SB,20261108,1\n"
        ),
    }


def _parse(files: dict[str, str], feed: str = "gtfs_rapid_bus_kl", anchor: date | None = None):
    return parse_feed(
        feed,
        _zip_bytes(files),
        provider="Test",
        endpoint="https://example.test/gtfs",
        sha256="deadbeef",
        anchor=anchor or date(2026, 11, 4),
    )


def test_stops_are_prefixed_deduped_and_coordinate_filtered():
    data = _parse(_minimal_files())

    assert [s["stop_uid"] for s in data.stops] == ["gtfs_rapid_bus_kl:S1", "gtfs_rapid_bus_kl:S2"]
    assert data.stops[0]["lat"] == 3.10 and data.stops[0]["lon"] == 101.60
    # (0,0), out-of-range and coordinate-less rows never enter the table; the
    # duplicate S1 is deduplicated, and every drop is counted, not absorbed.
    assert data.dedup["stops"] == 1
    assert data.feed_version == "v2026.11"


def test_trips_on_unknown_routes_or_without_service_are_dropped():
    data = _parse(_minimal_files())

    assert [t["trip_uid"] for t in data.trips] == [
        "gtfs_rapid_bus_kl:T1", "gtfs_rapid_bus_kl:T2", "gtfs_rapid_bus_kl:T3",
    ]
    assert data.dedup["trips_dropped"] == 1  # T4 references unknown route R9


def test_active_services_resolve_first_weekday_and_weekend_dates():
    data = _parse(_minimal_files())

    sa = {(r["service_id"], r["daytype"]): r["ref_date"] for r in data.active_services}
    # SA runs every day; from a Wednesday anchor the first WEEKDAY is the
    # anchor day itself and the first WEEKEND is the coming Saturday.
    assert sa[("SA", "WEEKDAY")] == date(2026, 11, 4)
    assert sa[("SA", "WEEKEND")] == date(2026, 11, 7)
    # SB exists only via a calendar_dates addition on Sunday 2026-11-08.
    assert sa[("SB", "WEEKEND")] == date(2026, 11, 8)
    assert ("SB", "WEEKDAY") not in sa


def test_dep_flattens_scheduled_departures_per_daytype():
    data = _parse(_minimal_files())

    t1_weekday = [r for r in data.dep if r["trip_uid"] == "gtfs_rapid_bus_kl:T1" and r["daytype"] == "WEEKDAY"]
    assert {r["dep_s"] for r in t1_weekday} == {14 * 3600 + 4 * 60, 15 * 3600}
    t2 = [r for r in data.dep if r["trip_uid"] == "gtfs_rapid_bus_kl:T2"]
    assert {r["dep_s"] for r in t2} == {25 * 3600 + 30 * 60, 8 * 3600}  # >24h hours are legal GTFS
    # T3's service SB is weekend-only.
    assert {r["daytype"] for r in data.dep if r["trip_uid"] == "gtfs_rapid_bus_kl:T3"} == {"WEEKEND"}


def test_stop_routes_and_stop_modes_follow_the_pipeline_conventions():
    data = _parse(_minimal_files())

    pairs = {(r["stop_uid"], r["route_uid"]) for r in data.stop_routes}
    assert ("gtfs_rapid_bus_kl:S1", "gtfs_rapid_bus_kl:R1") in pairs
    assert ("gtfs_rapid_bus_kl:S2", "gtfs_rapid_bus_kl:R2") in pairs
    # S1 is served by R1 (bus) and R2 (KGL rail): the mode registry decides.
    modes = {r["stop_uid"]: r["mode"] for r in data.stop_modes}
    assert modes["gtfs_rapid_bus_kl:S1"] == "BUS"  # a bus feed maps its routes to BUS
    kgl_stops = [r for r in data.stop_modes if "KGL" not in r]
    # n_routes counts distinct routes serving each stop.
    n_routes = {r["stop_uid"]: r["n_routes"] for r in data.stop_modes}
    assert n_routes["gtfs_rapid_bus_kl:S1"] == 2
    assert n_routes["gtfs_rapid_bus_kl:S2"] == 2


def test_rapid_rail_mode_registry_matches_the_stored_mapping():
    files = _minimal_files()
    files["routes.txt"] = (
        "route_id,route_short_name,route_long_name,route_type\n"
        "KGL,KGL,Kajang Line,1\n"
        "MRL,MRL,KL Monorail Line,1\n"
        "BRT,BRT,Sunway Line,0\n"
        "KJ,KJL,Kelana Jaya Line,1\n"
    )
    files["trips.txt"] = (
        "trip_id,route_id,service_id\n"
        "T1,KGL,SA\nT2,MRL,SA\nT3,BRT,SA\nT4,KJ,SA\n"
    )
    files["stop_times.txt"] = (
        "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
        "T1,,08:00:00,S1,1\nT2,,08:10:00,S2,1\n"
        "T3,,08:20:00,S3,1\nT4,,08:30:00,S4,1\n"
    )
    files["stops.txt"] = (
        "stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station\n"
        "S1,One,3.0,101.5,0,\nS2,Two,3.1,101.6,0,\n"
        "S3,Three,3.2,101.7,0,\nS4,Four,3.3,101.8,0,\n"
    )
    data = _parse(files, feed="gtfs_rapid_rail_kl")

    modes = {r["stop_uid"]: r["mode"] for r in data.stop_modes}
    assert modes["gtfs_rapid_rail_kl:S1"] == "MRT"
    assert modes["gtfs_rapid_rail_kl:S2"] == "MONORAIL"
    assert modes["gtfs_rapid_rail_kl:S3"] == "OTHER"
    assert modes["gtfs_rapid_rail_kl:S4"] == "LRT"


def test_corrupt_or_invalid_payloads_raise_instead_of_returning_partial_data():
    with pytest.raises(GtfsImportError):
        parse_feed(
            "gtfs_test", b"definitely not a zip",
            provider="Test", endpoint="x", sha256="0",
        )

    files = _minimal_files()
    del files["stop_times.txt"]
    with pytest.raises(GtfsImportError, match="stop_times.txt"):
        _parse(files)

    files = _minimal_files()
    del files["calendar.txt"]
    del files["calendar_dates.txt"]
    with pytest.raises(GtfsImportError, match="calendar"):
        _parse(files)


def test_registry_covers_the_six_stored_feeds_with_official_endpoints():
    assert set(FEEDS) == {
        "gtfs_ktmb", "gtfs_rapid_rail_kl", "gtfs_rapid_bus_kl",
        "gtfs_rapid_bus_mrtfeeder", "gtfs_rapid_bus_penang", "gtfs_mybas",
    }
    for entry in FEEDS.values():
        assert entry["endpoint"].startswith("https://api.data.gov.my/gtfs-static/")
    assert FEEDS["gtfs_mybas"]["endpoint"].endswith("mybas-johor")


def test_status_records_attempts_and_preserves_last_success_on_failure(tmp_path, monkeypatch):
    monkeypatch.setenv("GTFS_DATA_DIR", str(tmp_path))

    class _Data:
        feed = "gtfs_ktmb"
        provider = "KTMB"
        endpoint = "https://api.data.gov.my/gtfs-static/ktmb"
        feed_version = "v1"
        sha256 = "aa"
        dedup: dict[str, int] = {}

    gtfs.record_attempt(_Data(), ok=True, error=None, counts={"stops": 155})
    gtfs.record_attempt(_Data(), ok=False, error="api down", counts=None)

    entry = gtfs.read_status()["feeds"]["gtfs_ktmb"]
    assert entry["status"] == "failed"
    assert entry["last_success"] is not None  # the stored rows are still yesterday's import
    assert entry["counts"] == {"stops": 155}
    assert entry["error"] == "api down"


def test_staleness_flags_every_core_feed_stale(tmp_path, monkeypatch):
    monkeypatch.setenv("GTFS_DATA_DIR", str(tmp_path))
    today = date(2026, 11, 16)

    fresh = {"provider": "KTMB", "endpoint": "x", "last_success": today.isoformat()}
    stale = {"provider": "KTMB", "endpoint": "x", "last_success": "2026-11-01"}
    never = {"provider": "KTMB", "endpoint": "x", "last_success": None}

    gtfs.write_status({"feeds": {"gtfs_ktmb": stale, "gtfs_mybas": fresh}})
    snapshot = gtfs.status_snapshot(today=today)
    assert snapshot["feeds"]["gtfs_ktmb"]["stale"] is True
    assert snapshot["feeds"]["gtfs_mybas"]["stale"] is False
    # A mixed dataset is not blanket-stale.
    assert gtfs.is_transit_stale() is False

    gtfs.write_status({"feeds": {name: stale for name in FEEDS}})
    assert gtfs.is_transit_stale() is True

    gtfs.write_status({"feeds": {name: never for name in FEEDS}})
    assert gtfs.is_transit_stale() is True

    # No status file at all means unknown, never stale.
    (Path(tmp_path) / "import_status.json").unlink()
    assert gtfs.is_transit_stale() is False
