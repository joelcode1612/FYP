"""Official-Malaysia-GTFS scheduled importer (backend-only).

Downloads the static GTFS ZIPs published through the national Open API
(https://developer.data.gov.my/realtime-api/gtfs-static, CC BY 4.0), validates
them, and refreshes the EXISTING ``fyp_features.gtfs_*`` tables feed by feed.
It never creates replacement tables: the eleven tables (stops, stop_modes,
stop_routes, routes, trips, stop_times, calendar, calendar_dates,
active_services, active_trips, dep) are wiped per feed and repopulated inside
ONE transaction, so an invalid or partial feed can never erase the previously
imported data — the transaction rolls back and the old rows stay.

Refresh semantics (reverse-engineered from the tables this project's feature
pipeline already built, and verified row-for-row against the stored data):

* ``gtfs_stops`` / ``gtfs_routes`` / ``gtfs_trips`` / ``gtfs_stop_times`` /
  ``gtfs_calendar`` / ``gtfs_calendar_dates`` carry the raw feed files with
  ``feed:``-prefixed uids (e.g. ``gtfs_ktmb:19000``) — the same convention the
  stored rows use, so downstream joins keep working;
* ``gtfs_active_services`` resolves, per service and day type, the FIRST date
  on or after the import anchor where the service runs (WEEKDAY = Mon–Fri,
  WEEKEND = Sat/Sun, honouring calendar_dates adds/removals);
* ``gtfs_active_trips`` are the trips whose service is active per day type;
* ``gtfs_dep`` flattens each active trip's stop_times into scheduled departure
  seconds after midnight — the published timetable, never live arrivals;
* ``gtfs_stop_routes`` are the distinct (stop, route) pairs via trips;
* ``gtfs_stop_modes`` assigns each stop its mode from the routes serving it
  (KTM for KTMB, BUS for bus feeds, and the rapid-rail registry below).

Each feed keeps a status record in ``<data_dir>/import_status.json`` —
provider, endpoint, feed version, fetch/import dates, per-table counts and
the last error — so consumers can distinguish a healthy feed from a stale or
never-imported one. :data:`STALE_AFTER_DAYS` defines staleness and
:func:`status_snapshot` exposes it; the nearby-places service marks the
transit category stale from this snapshot when the API host shares the
importer's data directory.

Requests are rate-limited (minimum spacing between downloads) and retried
with exponential backoff; ZIPs are cached locally so a run can be replayed
without re-downloading.

CLI::

    cd backend
    .venv\\Scripts\\python.exe -m sitewise.ingestion.sources.gtfs_importer --all --dry-run
    .venv\\Scripts\\python.exe -m sitewise.ingestion.sources.gtfs_importer --feeds gtfs_ktmb,gtfs_mybas
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import logging
import os
import time
import zipfile
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.request import Request, urlopen

LOGGER = logging.getLogger("sitewise.gtfs_importer")

#: National Open API base for GTFS Static (returns ZIP files).
API_BASE = "https://api.data.gov.my/gtfs-static/"

#: The feeds already present in ``fyp_features.gtfs_*``, mapped to their
#: official endpoints. ``gtfs_mybas`` holds the Johor Bahru BAS.MY stops
#: (lat 1.35-1.73, lon 103.39-103.96), so it maps to the ``mybas-johor``
#: endpoint.
FEEDS: dict[str, dict[str, str]] = {
    "gtfs_ktmb": {"provider": "KTMB", "endpoint": API_BASE + "ktmb"},
    "gtfs_rapid_rail_kl": {
        "provider": "Prasarana",
        "endpoint": API_BASE + "prasarana?category=rapid-rail-kl",
    },
    "gtfs_rapid_bus_kl": {
        "provider": "Prasarana",
        "endpoint": API_BASE + "prasarana?category=rapid-bus-kl",
    },
    "gtfs_rapid_bus_mrtfeeder": {
        "provider": "Prasarana",
        "endpoint": API_BASE + "prasarana?category=rapid-bus-mrtfeeder",
    },
    "gtfs_rapid_bus_penang": {
        "provider": "Prasarana",
        "endpoint": API_BASE + "prasarana?category=rapid-bus-penang",
    },
    "gtfs_mybas": {"provider": "BAS.MY", "endpoint": API_BASE + "mybas-johor"},
}

#: Additional official BAS.MY city feeds, importable on demand with
#: ``--optional``. New feed names create new rows in the existing tables —
#: no schema change.
OPTIONAL_FEEDS: dict[str, dict[str, str]] = {
    f"gtfs_mybas_{city}": {"provider": "BAS.MY", "endpoint": API_BASE + slug}
    for city, slug in (
        ("kangar", "mybas-kangar"),
        ("alor_setar", "mybas-alor-setar"),
        ("kota_bharu", "mybas-kota-bharu"),
        ("kuala_terengganu", "mybas-kuala-terengganu"),
        ("ipoh", "mybas-ipoh"),
        ("seremban_a", "mybas-seremban-a"),
        ("seremban_b", "mybas-seremban-b"),
        ("melaka", "mybas-melaka"),
        ("kuching", "mybas-kuching"),
    )
}

#: Minimum spacing between consecutive downloads (be a polite API citizen).
MIN_REQUEST_INTERVAL_SECONDS = 2.0

DOWNLOAD_TIMEOUT_SECONDS = 120
DOWNLOAD_ATTEMPTS = 3

#: A feed whose last successful import is older than this is stale.
STALE_AFTER_DAYS = 3

_REQUIRED_MEMBERS = ("stops.txt", "routes.txt", "trips.txt", "stop_times.txt")

#: Rapid-rail routes by short name (KL/Melaka region). Anything else on the
#: rail feed defaults to LRT; the mapping reproduces the stored stop_modes.
_RAPID_RAIL_MODES = {
    "KGL": "MRT",
    "PYL": "MRT",
    "MRL": "MONORAIL",
    "BRT": "OTHER",
}


class GtfsImportError(Exception):
    """A feed could not be downloaded, validated, parsed or applied."""


@dataclass
class FeedData:
    """One validated feed, ready to be applied to the database."""

    feed: str
    provider: str
    endpoint: str
    feed_version: str | None
    sha256: str
    stops: list[dict[str, Any]] = field(default_factory=list)
    routes: list[dict[str, Any]] = field(default_factory=list)
    trips: list[dict[str, Any]] = field(default_factory=list)
    stop_times: list[dict[str, Any]] = field(default_factory=list)
    calendar: list[dict[str, Any]] = field(default_factory=list)
    calendar_dates: list[dict[str, Any]] = field(default_factory=list)
    active_services: list[dict[str, Any]] = field(default_factory=list)
    active_trips: list[dict[str, Any]] = field(default_factory=list)
    dep: list[dict[str, Any]] = field(default_factory=list)
    stop_routes: list[dict[str, Any]] = field(default_factory=list)
    stop_modes: list[dict[str, Any]] = field(default_factory=list)
    dedup: dict[str, int] = field(default_factory=dict)

    def counts(self) -> dict[str, int]:
        return {
            "stops": len(self.stops),
            "routes": len(self.routes),
            "trips": len(self.trips),
            "stop_times": len(self.stop_times),
            "calendar": len(self.calendar),
            "calendar_dates": len(self.calendar_dates),
            "active_services": len(self.active_services),
            "active_trips": len(self.active_trips),
            "dep": len(self.dep),
            "stop_routes": len(self.stop_routes),
            "stop_modes": len(self.stop_modes),
        }


def data_dir() -> Path:
    """Local cache/status directory (override with ``GTFS_DATA_DIR``)."""
    override = os.environ.get("GTFS_DATA_DIR")
    if override:
        return Path(override)
    return Path(__file__).resolve().parents[4] / "data" / "gtfs"


# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------


def download_feed(endpoint: str, dest: Path, *, use_cache: bool = False) -> str:
    """Fetch the ZIP (rate-limited, retried), cache it locally, return sha256.

    ``use_cache`` replays a cached ZIP instead of hitting the API, so a run
    can be verified offline; a missing cache raises instead of failing silently.
    """
    import hashlib

    if use_cache:
        if not dest.exists():
            raise GtfsImportError(f"No cached ZIP at {dest}; run without --cache-only first.")
        return hashlib.sha256(dest.read_bytes()).hexdigest()

    dest.parent.mkdir(parents=True, exist_ok=True)
    last_error: Exception | None = None
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        if attempt > 1:
            # Exponential backoff: 2s, 4s before the 2nd/3rd retry.
            time.sleep(MIN_REQUEST_INTERVAL_SECONDS * 2 ** (attempt - 1))
        else:
            time.sleep(MIN_REQUEST_INTERVAL_SECONDS)
        try:
            request = Request(endpoint, headers={"User-Agent": "sitewise-gtfs-importer/1.0"})
            with urlopen(request, timeout=DOWNLOAD_TIMEOUT_SECONDS) as response:
                payload = response.read()
            if not payload:
                raise GtfsImportError(f"{endpoint} returned an empty response")
            tmp = dest.with_suffix(".zip.part")
            tmp.write_bytes(payload)
            os.replace(tmp, dest)
            return hashlib.sha256(payload).hexdigest()
        except (URLError, TimeoutError, OSError) as exc:
            last_error = exc
            LOGGER.warning("Download attempt %d for %s failed: %s", attempt, endpoint, exc)
    raise GtfsImportError(f"Download failed after {DOWNLOAD_ATTEMPTS} attempts: {last_error}")


# ---------------------------------------------------------------------------
# Validation + parsing
# ---------------------------------------------------------------------------


def _rows_from_zip(zf: zipfile.ZipFile, member: str) -> list[dict[str, str]]:
    with zf.open(member) as handle:
        text = io.TextIOWrapper(handle, encoding="utf-8-sig", newline="")
        return list(csv.DictReader(text))


# calendar.txt column names vary between feeds (full GTFS names here vs the
# short names the fyp_features tables store); normalise on read.
_CALENDAR_ALIASES = {
    "monday": "mon", "tuesday": "tue", "wednesday": "wed",
    "thursday": "thu", "friday": "fri", "saturday": "sat", "sunday": "sun",
    "start_date": "start", "end_date": "end",
}


def parse_feed(
    feed: str,
    payload: bytes,
    *,
    provider: str,
    endpoint: str,
    sha256: str,
    anchor: date | None = None,
) -> FeedData:
    """Validate the ZIP and parse every GTFS file into typed rows.

    Raises :class:`GtfsImportError` — never returns a half-valid feed — so the
    caller's transactional refresh only ever sees feed data that is complete.
    """
    try:
        zf = zipfile.ZipFile(io.BytesIO(payload))
    except zipfile.BadZipFile as exc:
        raise GtfsImportError(f"{feed}: payload is not a valid ZIP: {exc}") from exc
    if zf.testzip() is not None:
        raise GtfsImportError(f"{feed}: ZIP failed its CRC integrity check")
    members = {name.split("/")[-1]: name for name in zf.namelist() if not name.endswith("/")}
    for member in _REQUIRED_MEMBERS:
        if member not in members:
            raise GtfsImportError(f"{feed}: missing required GTFS member {member}")
    if "calendar.txt" not in members and "calendar_dates.txt" not in members:
        raise GtfsImportError(f"{feed}: feed has neither calendar.txt nor calendar_dates.txt")

    data = FeedData(feed=feed, provider=provider, endpoint=endpoint, feed_version=None, sha256=sha256)
    if "feed_info.txt" in members:
        for row in _rows_from_zip(zf, members["feed_info.txt"]):
            if row.get("feed_version"):
                data.feed_version = row["feed_version"]
                break

    # stops.txt — every row must carry a usable coordinate.
    seen: set[str] = set()
    for row in _rows_from_zip(zf, members["stops.txt"]):
        stop_id = (row.get("stop_id") or "").strip()
        if not stop_id:
            continue
        try:
            lat = float(row["stop_lat"])
            lon = float(row["stop_lon"])
        except (KeyError, ValueError):
            continue
        if not (-90 <= lat <= 90 and -180 <= lon <= 180) or (lat == 0 and lon == 0):
            continue
        if stop_id in seen:
            data.dedup["stops"] = data.dedup.get("stops", 0) + 1
            continue
        seen.add(stop_id)
        data.stops.append({
            "feed": feed,
            "stop_uid": f"{feed}:{stop_id}",
            "stop_id": stop_id,
            "name": (row.get("stop_name") or "").strip() or None,
            "lat": lat,
            "lon": lon,
            "location_type": (row.get("location_type") or "0").strip() or "0",
            "parent": (row.get("parent_station") or "").strip() or None,
        })
    if not data.stops:
        raise GtfsImportError(f"{feed}: stops.txt holds no row with a usable coordinate")

    stop_ids = seen
    seen = set()
    for row in _rows_from_zip(zf, members["routes.txt"]):
        route_id = (row.get("route_id") or "").strip()
        if not route_id or route_id in seen:
            if route_id in seen:
                data.dedup["routes"] = data.dedup.get("routes", 0) + 1
            continue
        seen.add(route_id)
        data.routes.append({
            "feed": feed,
            "route_uid": f"{feed}:{route_id}",
            "route_id": route_id,
            "short": (row.get("route_short_name") or "").strip() or None,
            "long": (row.get("route_long_name") or "").strip() or None,
            "type": (row.get("route_type") or "").strip() or None,
        })

    route_ids = seen
    trip_service: dict[str, str] = {}
    trip_route: dict[str, str] = {}
    seen = set()
    for row in _rows_from_zip(zf, members["trips.txt"]):
        trip_id = (row.get("trip_id") or "").strip()
        route_id = (row.get("route_id") or "").strip()
        service_id = (row.get("service_id") or "").strip()
        if not trip_id or trip_id in seen:
            if trip_id in seen:
                data.dedup["trips"] = data.dedup.get("trips", 0) + 1
            continue
        if not service_id or route_id not in route_ids:
            # A trip without a service cannot be scheduled; a trip on an
            # unknown route would orphan the join. Both are dropped and the
            # drop is recorded rather than silently absorbed.
            data.dedup["trips_dropped"] = data.dedup.get("trips_dropped", 0) + 1
            continue
        seen.add(trip_id)
        trip_service[trip_id] = service_id
        trip_route[trip_id] = route_id
        data.trips.append({
            "feed": feed,
            "trip_uid": f"{feed}:{trip_id}",
            "trip_id": trip_id,
            "route_uid": f"{feed}:{route_id}",
            "service_id": service_id,
        })
    if not data.trips:
        raise GtfsImportError(f"{feed}: no trip references a known route and service")

    trip_ids = seen
    seen_stop_times: set[tuple[str, int, str]] = set()
    for row in _rows_from_zip(zf, members["stop_times.txt"]):
        trip_id = (row.get("trip_id") or "").strip()
        stop_id = (row.get("stop_id") or "").strip()
        if trip_id not in trip_ids or stop_id not in stop_ids:
            continue
        try:
            seq = int((row.get("stop_sequence") or "").strip())
        except ValueError:
            continue
        dep = (row.get("departure_time") or row.get("arrival_time") or "").strip() or None
        key = (trip_id, seq, stop_id)
        if key in seen_stop_times:
            continue
        seen_stop_times.add(key)
        data.stop_times.append({
            "feed": feed,
            "trip_uid": f"{feed}:{trip_id}",
            "stop_uid": f"{feed}:{stop_id}",
            "dep": dep,
            "seq": seq,
        })

    if "calendar.txt" in members:
        data.calendar = []
        for row in _rows_from_zip(zf, members["calendar.txt"]):
            service = (row.get("service_id") or "").strip()
            if not service:
                continue
            normalised: dict[str, str] = {"feed": feed, "service_id": service}
            for col in ("mon", "tue", "wed", "thu", "fri", "sat", "sun", "start", "end",
                        "monday", "tuesday", "wednesday", "thursday", "friday",
                        "saturday", "sunday", "start_date", "end_date"):
                value = (row.get(col) or "").strip()
                if not value:
                    continue  # a feed carries only one naming convention; never blank the alias
                normalised[_CALENDAR_ALIASES.get(col, col)] = value
            data.calendar.append(normalised)
    if "calendar_dates.txt" in members:
        data.calendar_dates = [
            {
                "feed": feed,
                "service_id": (row.get("service_id") or "").strip(),
                "date": (row.get("date") or "").strip(),
                "ex": (row.get("exception_type") or "").strip() or None,
            }
            for row in _rows_from_zip(zf, members["calendar_dates.txt"])
            if (row.get("service_id") or "").strip()
        ]

    _derive(data, anchor=anchor or date.today())
    return data


def _parse_dep_seconds(dep: str | None) -> int | None:
    """``HH:MM:SS`` (hours may exceed 24) to seconds after midnight."""
    if not dep or ":" not in dep:
        return None
    parts = dep.strip().split(":")
    if len(parts) < 2:
        return None
    try:
        hours = int(parts[0])
        minutes = int(parts[1])
        seconds = int(parts[2]) if len(parts) > 2 else 0
    except ValueError:
        return None
    if minutes < 0 or minutes > 59 or seconds < 0 or seconds > 59 or hours < 0:
        return None
    return hours * 3600 + minutes * 60 + seconds


def _service_active_dates(data: FeedData) -> dict[str, set[date]]:
    """Every date each service runs, honouring calendar + calendar_dates."""
    active: dict[str, set[date]] = {}
    dow_flags = {
        "mon": ("mon", 1), "tue": ("tue", 2), "wed": ("wed", 3),
        "thu": ("thu", 4), "fri": ("fri", 5), "sat": ("sat", 6), "sun": ("sun", 7),
    }
    for row in data.calendar:
        service = row["service_id"]
        try:
            start = datetime.strptime(row["start"], "%Y%m%d").date()
            end = datetime.strptime(row["end"], "%Y%m%d").date()
        except ValueError:
            continue
        # Keys are ISO weekdays (1=Mon .. 7=Sun) because the scan below looks
        # them up by ``day.isoweekday()``.
        flags = {
            n: row.get(col) == "1"
            for col, (_dow, n) in dow_flags.items()
            if row.get(col) in ("0", "1")
        }
        days = set()
        for offset in range((end - start).days + 1):
            day = start + timedelta(days=offset)
            if flags.get(day.isoweekday()):
                days.add(day)
        active.setdefault(service, set()).update(days)
    for row in data.calendar_dates:
        try:
            day = datetime.strptime(row["date"], "%Y%m%d").date()
        except ValueError:
            continue
        if row["ex"] == "1":
            active.setdefault(row["service_id"], set()).add(day)
        elif row["ex"] == "2":
            active.get(row["service_id"], set()).discard(day)
    return active


def _derive(data: FeedData, *, anchor: date) -> None:
    """Build the derived tables exactly the way the stored ones were built.

    * active_services: per (service, daytype) the FIRST date >= anchor where
      the service runs; services that never run on a day type get no row;
    * active_trips: trips whose service is active per daytype;
    * dep: (stop, trip, daytype, route, departure-seconds) for active trips;
    * stop_routes: distinct (stop, route) pairs via trips;
    * stop_modes: per stop the mode of the routes serving it.
    """
    active_dates = _service_active_dates(data)

    def daytype(day: date) -> str:
        return "WEEKDAY" if day.isoweekday() <= 5 else "WEEKEND"

    for service, days in sorted(active_dates.items()):
        for kind in ("WEEKDAY", "WEEKEND"):
            ref = min((d for d in days if d >= anchor and daytype(d) == kind), default=None)
            if ref is not None:
                data.active_services.append({
                    "feed": data.feed, "service_id": service, "daytype": kind, "ref_date": ref,
                })
    active_by_daytype: dict[str, set[str]] = {}
    for row in data.active_services:
        active_by_daytype.setdefault(row["daytype"], set()).add(row["service_id"])

    stop_route_pairs: set[tuple[str, str]] = set()
    for trip in data.trips:
        for kind, services in active_by_daytype.items():
            if trip["service_id"] in services:
                data.active_trips.append({
                    "feed": data.feed, "trip_uid": trip["trip_uid"],
                    "route_uid": trip["route_uid"], "daytype": kind,
                })

    stop_times_by_trip: dict[str, list[dict[str, Any]]] = {}
    for row in data.stop_times:
        stop_times_by_trip.setdefault(row["trip_uid"], []).append(row)

    trip_route_by_uid = {trip["trip_uid"]: trip["route_uid"] for trip in data.trips}
    for row in data.stop_times:
        stop_route_pairs.add((row["stop_uid"], trip_route_by_uid[row["trip_uid"]]))
    data.stop_routes = [
        {"feed": data.feed, "stop_uid": stop_uid, "route_uid": route_uid}
        for stop_uid, route_uid in sorted(stop_route_pairs)
    ]

    for active_trip in data.active_trips:
        for st in stop_times_by_trip.get(active_trip["trip_uid"], ()):
            dep_s = _parse_dep_seconds(st["dep"])
            if dep_s is None:
                continue
            data.dep.append({
                "stop_uid": st["stop_uid"], "trip_uid": st["trip_uid"],
                "daytype": active_trip["daytype"], "route_uid": active_trip["route_uid"],
                "dep_s": dep_s,
            })

    route_modes: dict[str, str] = {}
    for route in data.routes:
        route_modes[route["route_uid"]] = _route_mode(data.feed, route)
    stop_by_uid = {stop["stop_uid"]: stop for stop in data.stops}
    routes_per_stop: dict[str, list[str]] = {}
    for stop_uid, route_uid in sorted(stop_route_pairs):
        routes_per_stop.setdefault(stop_uid, []).append(route_uid)
    for stop_uid, route_uids in routes_per_stop.items():
        stop = stop_by_uid.get(stop_uid)
        if stop is None:
            continue
        modes = {route_modes.get(r, _feed_default_mode(data.feed)) for r in route_uids}
        mode = sorted(modes)[0] if len(modes) > 1 else (modes.pop() if modes else _feed_default_mode(data.feed))
        data.stop_modes.append({
            "feed": data.feed, "stop_uid": stop_uid, "name": stop["name"],
            "lat": stop["lat"], "lon": stop["lon"], "mode": mode,
            "n_routes": len(route_uids),
        })


def _route_mode(feed: str, route: dict[str, Any]) -> str:
    if feed == "gtfs_ktmb":
        return "KTM"
    if feed in ("gtfs_rapid_bus_kl", "gtfs_rapid_bus_mrtfeeder", "gtfs_rapid_bus_penang") or feed.startswith("gtfs_mybas"):
        return "BUS"
    if feed == "gtfs_rapid_rail_kl":
        short = route.get("short") or ""
        if short in _RAPID_RAIL_MODES:
            return _RAPID_RAIL_MODES[short]
        return "LRT"
    return "OTHER"


def _feed_default_mode(feed: str) -> str:
    return _route_mode(feed, {})


# ---------------------------------------------------------------------------
# Database apply (one transaction per feed)
# ---------------------------------------------------------------------------

_GTFS_TABLES_WITH_FEED = (
    "gtfs_stops", "gtfs_stop_modes", "gtfs_stop_routes", "gtfs_routes",
    "gtfs_trips", "gtfs_stop_times", "gtfs_calendar", "gtfs_calendar_dates",
    "gtfs_active_services", "gtfs_active_trips",
)

_INSERT_BATCH = 5000

_INSERTS = {
    "stops": (
        "INSERT INTO fyp_features.gtfs_stops (feed, stop_uid, stop_id, name, lat, lon, location_type, parent, geom) "
        "VALUES (:feed, :stop_uid, :stop_id, :name, :lat, :lon, :location_type, :parent, "
        "ST_SetSRID(ST_MakePoint(:lon, :lat), 4326))",
        "stops",
    ),
    "routes": (
        "INSERT INTO fyp_features.gtfs_routes (feed, route_uid, route_id, short, long, type) "
        "VALUES (:feed, :route_uid, :route_id, :short, :long, :type)",
        "routes",
    ),
    "trips": (
        "INSERT INTO fyp_features.gtfs_trips (feed, trip_uid, trip_id, route_uid, service_id) "
        "VALUES (:feed, :trip_uid, :trip_id, :route_uid, :service_id)",
        "trips",
    ),
    "stop_times": (
        "INSERT INTO fyp_features.gtfs_stop_times (feed, trip_uid, stop_uid, dep, seq) "
        "VALUES (:feed, :trip_uid, :stop_uid, :dep, :seq)",
        "stop_times",
    ),
    "calendar": (
        "INSERT INTO fyp_features.gtfs_calendar (feed, service_id, mon, tue, wed, thu, fri, sat, sun, start, end) "
        "VALUES (:feed, :service_id, :mon, :tue, :wed, :thu, :fri, :sat, :sun, :start, :end)",
        "calendar",
    ),
    "calendar_dates": (
        "INSERT INTO fyp_features.gtfs_calendar_dates (feed, service_id, date, ex) "
        "VALUES (:feed, :service_id, :date, :ex)",
        "calendar_dates",
    ),
    "active_services": (
        "INSERT INTO fyp_features.gtfs_active_services (feed, service_id, daytype, ref_date) "
        "VALUES (:feed, :service_id, :daytype, :ref_date)",
        "active_services",
    ),
    "active_trips": (
        "INSERT INTO fyp_features.gtfs_active_trips (feed, trip_uid, route_uid, daytype) "
        "VALUES (:feed, :trip_uid, :route_uid, :daytype)",
        "active_trips",
    ),
    "dep": (
        "INSERT INTO fyp_features.gtfs_dep (stop_uid, trip_uid, daytype, route_uid, dep_s) "
        "VALUES (:stop_uid, :trip_uid, :daytype, :route_uid, :dep_s)",
        "dep",
    ),
    "stop_routes": (
        "INSERT INTO fyp_features.gtfs_stop_routes (feed, stop_uid, route_uid) "
        "VALUES (:feed, :stop_uid, :route_uid)",
        "stop_routes",
    ),
    "stop_modes": (
        "INSERT INTO fyp_features.gtfs_stop_modes (feed, stop_uid, name, lat, lon, geom, mode, n_routes) "
        "VALUES (:feed, :stop_uid, :name, :lat, :lon, "
        "ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :mode, :n_routes)",
        "stop_modes",
    ),
}


def apply_feed(engine: Any, data: FeedData) -> dict[str, int]:
    """Replace this feed's rows in ALL GTFS tables inside one transaction.

    Any failure rolls the whole feed back, so an invalid feed can never erase
    the previously imported rows.
    """
    from sqlalchemy import text as sql_text

    with engine.begin() as conn:
        for table in _GTFS_TABLES_WITH_FEED:
            conn.execute(sql_text(f"DELETE FROM fyp_features.{table} WHERE feed = :feed"), {"feed": data.feed})
        # gtfs_dep has no feed column; its uids encode the feed.
        conn.execute(
            sql_text("DELETE FROM fyp_features.gtfs_dep WHERE stop_uid LIKE :prefix"),
            {"prefix": f"{data.feed}:%"},
        )
        for statement, attribute in _INSERTS.values():
            rows = getattr(data, attribute)
            for start in range(0, len(rows), _INSERT_BATCH):
                conn.execute(sql_text(statement), rows[start:start + _INSERT_BATCH])
    return data.counts()


# ---------------------------------------------------------------------------
# Import status
# ---------------------------------------------------------------------------


def status_path() -> Path:
    return data_dir() / "import_status.json"


def read_status() -> dict[str, Any]:
    """The recorded import status (empty dict when the file is absent/broken).

    A missing file means "no importer has run on this host" — that is an
    unknown, never a stale.
    """
    path = status_path()
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def write_status(status: dict[str, Any]) -> None:
    path = status_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.part")
    tmp.write_text(json.dumps(status, indent=2, default=str), encoding="utf-8")
    os.replace(tmp, path)


def status_snapshot(today: date | None = None) -> dict[str, Any]:
    """Status enriched with computed staleness per feed.

    ``stale`` is true when the feed was successfully imported before
    ``STALE_AFTER_DAYS`` days ago (or has never succeeded while a status file
    exists — an importer that only ever failed is stale too). ``last_success``
    is the ISO date of the last successful import, or None.
    """
    today = today or datetime.now(UTC).date()
    raw = read_status()
    snapshot: dict[str, Any] = {"generated_at": raw.get("generated_at"), "feeds": {}}
    cutoff = today - timedelta(days=STALE_AFTER_DAYS)
    for feed, entry in (raw.get("feeds") or {}).items():
        last = entry.get("last_success")
        try:
            last_date = date.fromisoformat(last) if last else None
        except ValueError:
            last_date = None
        snapshot["feeds"][feed] = {
            **entry,
            "last_success": last,
            "stale": last_date is None or last_date < cutoff,
        }
    return snapshot


def is_transit_stale() -> bool:
    """True when EVERY core feed is stale (or none ever succeeded).

    A partially fresh dataset is still mapped data; the caller surfaces
    partial staleness from the snapshot rather than a blanket flag.
    """
    snapshot = status_snapshot()
    feeds = snapshot.get("feeds") or {}
    core = [feeds[name] for name in FEEDS if name in feeds]
    if not core:
        return False
    return all(entry.get("stale") for entry in core)


def record_attempt(data: FeedData | None, *, ok: bool, error: str | None, counts: dict[str, int] | None) -> None:
    status = read_status()
    feeds = status.setdefault("feeds", {})
    key = data.feed if data else "unknown"
    previous = feeds.get(key, {})
    feeds[key] = {
        "provider": data.provider if data else previous.get("provider"),
        "endpoint": data.endpoint if data else previous.get("endpoint"),
        "feed_version": data.feed_version if data else previous.get("feed_version"),
        "sha256": data.sha256 if data else previous.get("sha256"),
        "last_attempt": datetime.now(UTC).isoformat(timespec="seconds"),
        # A failed refresh must not clear the date of the last success: the
        # stored rows are still that old dataset, so it is still the truth.
        "last_success": (
            datetime.now(UTC).date().isoformat()
            if ok
            else previous.get("last_success")
        ),
        "status": "ok" if ok else "failed",
        "counts": counts or previous.get("counts", {}),
        "error": error,
        "dedup": dict(data.dedup) if data else previous.get("dedup", {}),
    }
    status["generated_at"] = datetime.now(UTC).isoformat(timespec="seconds")
    write_status(status)


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


def import_feeds(
    engine: Any,
    feeds: list[str],
    *,
    dry_run: bool = False,
    cache_only: bool = False,
    anchor: date | None = None,
) -> list[dict[str, Any]]:
    """Import the requested feeds sequentially; one failure never stops the rest."""
    registry = {**FEEDS, **OPTIONAL_FEEDS}
    unknown = [name for name in feeds if name not in registry]
    if unknown:
        raise GtfsImportError(f"Unknown feed(s): {', '.join(unknown)}")

    results: list[dict[str, Any]] = []
    last_request = time.monotonic()
    for name in feeds:
        spec = registry[name]
        dest = data_dir() / f"{name}.zip"
        result: dict[str, Any] = {"feed": name, "provider": spec["provider"], "endpoint": spec["endpoint"]}
        data: FeedData | None = None
        error: str | None = None
        counts: dict[str, int] | None = None
        elapsed = time.monotonic() - last_request
        if elapsed < MIN_REQUEST_INTERVAL_SECONDS:
            time.sleep(MIN_REQUEST_INTERVAL_SECONDS - elapsed)
        try:
            sha = download_feed(spec["endpoint"], dest, use_cache=cache_only)
            last_request = time.monotonic()
            payload = dest.read_bytes()
            data = parse_feed(
                name, payload,
                provider=spec["provider"], endpoint=spec["endpoint"], sha256=sha,
                anchor=anchor,
            )
            result["feed_version"] = data.feed_version
            result["counts"] = data.counts()
            result["dedup"] = dict(data.dedup)
            if dry_run:
                result["action"] = "dry_run"
                # Nothing changed in the database, so the status file must
                # not claim a successful import.
            else:
                counts = apply_feed(engine, data)
                result["action"] = "imported"
                record_attempt(data, ok=True, error=None, counts=counts)
        except Exception as exc:  # noqa: BLE001 — one feed failing must not stop the rest
            error = str(exc)
            result["action"] = "failed"
            result["error"] = error
            LOGGER.error("Feed %s failed: %s", name, error)
            if data is not None:
                record_attempt(data, ok=False, error=error, counts=None)
            else:
                record_attempt(None, ok=False, error=error, counts=None)
        results.append(result)
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Official-Malaysia-GTFS importer for fyp_features.gtfs_*")
    parser.add_argument("--feeds", help="comma-separated feed names (default: all core feeds)")
    parser.add_argument("--all", action="store_true", help="import every core feed")
    parser.add_argument("--optional", action="store_true", help="include the extra BAS.MY city feeds")
    parser.add_argument("--dry-run", action="store_true", help="download, validate and count without writing")
    parser.add_argument("--cache-only", action="store_true", help="use cached ZIPs; never touch the network")
    parser.add_argument("--data-dir", help="override the local cache/status directory")
    parser.add_argument("--anchor", help="active-service anchor date YYYY-MM-DD (default: today)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")
    if args.data_dir:
        os.environ["GTFS_DATA_DIR"] = args.data_dir

    registry = {**FEEDS, **(OPTIONAL_FEEDS if args.optional else {})}
    if args.feeds:
        feeds = [name.strip() for name in args.feeds.split(",") if name.strip()]
    elif args.optional:
        feeds = list(registry)
    else:
        feeds = list(FEEDS)

    anchor = date.fromisoformat(args.anchor) if args.anchor else None

    engine = _engine()
    results = import_feeds(engine, feeds, dry_run=args.dry_run, cache_only=args.cache_only, anchor=anchor)
    print(json.dumps({"results": results, "status_file": str(status_path())}, indent=2, default=str))
    return 0 if all(r.get("action") != "failed" for r in results) else 1


def _engine() -> Any:
    from sqlalchemy import create_engine

    from sitewise.core.config import settings

    return create_engine(settings.analytics_database_url)


if __name__ == "__main__":
    raise SystemExit(main())
