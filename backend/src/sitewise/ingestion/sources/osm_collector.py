#!/usr/bin/env python3
"""SiteWise P0: Overpass-first OSM POI ingestion with Geofabrik PBF fallback.

Requires Python 3.10+. Overpass and fixture modes use the standard library.
For PBF mode, install osmium (pyosmium): python -m pip install osmium

This script outputs a one-row-per-OSM-object point REPRESENTATION. Ways and
relations are represented by their bounding-box center, not their full polygon.
It is suitable for POI discovery/approximate counting, not precise building
containment or walking-network calculations.

Data: © OpenStreetMap contributors; ODbL 1.0.
"""

from __future__ import annotations

import argparse
from collections import Counter
import csv
from datetime import datetime, timezone
import json
import logging
from pathlib import Path
import sys
import time
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

LOGGER = logging.getLogger("sitewise.osm")

GEOFABRIK_URL = (
    "https://download.geofabrik.de/asia/"
    "malaysia-singapore-brunei-latest.osm.pbf"
)
OVERPASS_ENDPOINTS = (
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
)
USER_AGENT = "SiteWise-OSM-Research-Ingestion/1.0 (respectful cached requests)"

# Purposefully excludes all-building queries: they can overwhelm public Overpass.
# Google-only competitor policy: do not ingest OSM F&B outlets as competitors.
# Classifiers can emit more than one label when a feature has multiple relevant tags.
RULES: dict[str, dict[str, set[str] | None]] = {
    "amenity": {
        "food_court": {"hawker"},
        "school": {"school"}, "kindergarten": {"school"},
        "university": {"university_college"},
        "college": {"university_college"},
        "hospital": {"hospital"}, "clinic": {"healthcare"},
        "doctors": {"healthcare"},
        "marketplace": {"market"},
        "place_of_worship": {"worship"},
        "cinema": {"entertainment"}, "theatre": {"entertainment"},
        "arts_centre": {"entertainment"},
    },
    "shop": {
        "supermarket": {"supermarket"},
        "mall": {"mall"}, "department_store": {"retail"},
        "convenience": {"retail"},
    },
    "tourism": {
        "hotel": {"accommodation"}, "guest_house": {"accommodation"},
        "hostel": {"accommodation"}, "motel": {"accommodation"},
        "attraction": {"tourism"}, "museum": {"tourism"},
        "viewpoint": {"tourism"}, "gallery": {"tourism"},
    },
    "office": {"*": {"office"}},
    "healthcare": {"*": {"healthcare"}},
    "leisure": {
        "sports_centre": {"entertainment"},
        "stadium": {"entertainment"},
    },
}

# Stable, explicit columns so downstream imports can validate a schema.
COLUMNS = [
    "osm_type", "osm_id", "osm_uid", "name", "groups", "primary_group",
    "latitude", "longitude", "coordinate_method", "amenity", "shop",
    "tourism", "office", "healthcare", "leisure", "source_platform",
    "source_method", "source_url", "retrieved_at_utc", "tags_json",
]


def now_utc() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def classify(tags: dict[str, str]) -> list[str]:
    groups: set[str] = set()
    for key, variants in RULES.items():
        value = tags.get(key, "").strip().lower()
        if not value or value in ("no", "private", "vacant"):
            continue
        groups.update(variants.get(value, set()) or variants.get("*", set()))
    return sorted(groups)


def parse_boxes(raw_boxes: list[list[float]]) -> list[tuple[float, float, float, float]]:
    boxes = []
    for raw in raw_boxes:
        south, west, north, east = raw
        if not (-90 <= south < north <= 90 and -180 <= west < east <= 180):
            raise ValueError(f"Invalid south west north east bounding box: {raw}")
        boxes.append((south, west, north, east))
    return boxes


def inside(lat: float, lon: float, boxes: list[tuple[float, float, float, float]]) -> bool:
    return any(s <= lat <= n and w <= lon <= e for s, w, n, e in boxes)


def record(
    osm_type: str, osm_id: int, lat: float, lon: float,
    tags: dict[str, str], method: str, source: str, retrieved: str,
) -> dict[str, Any] | None:
    groups = classify(tags)
    if not groups or not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None
    return {
        "osm_type": osm_type,
        "osm_id": int(osm_id),
        "osm_uid": f"{osm_type}/{osm_id}",
        "name": tags.get("name", ""),
        "groups": "|".join(groups),
        "primary_group": groups[0],
        "latitude": round(lat, 7),
        "longitude": round(lon, 7),
        "coordinate_method": method,
        "amenity": tags.get("amenity", ""),
        "shop": tags.get("shop", ""),
        "tourism": tags.get("tourism", ""),
        "office": tags.get("office", ""),
        "healthcare": tags.get("healthcare", ""),
        "leisure": tags.get("leisure", ""),
        "source_platform": "OPENSTREETMAP",
        "source_method": source,
        "source_url": f"https://www.openstreetmap.org/{osm_type}/{osm_id}",
        "retrieved_at_utc": retrieved,
        "tags_json": json.dumps(tags, ensure_ascii=False, sort_keys=True),
    }


def overpass_query(box: tuple[float, float, float, float]) -> str:
    bbox = ",".join(str(v) for v in box)
    clauses = []
    for key, variants in RULES.items():
        if "*" in variants:
            clauses.append(f'  nwr["{key}"]({bbox});')
        else:
            names = "|".join(sorted(variants))
            clauses.append(f'  nwr["{key}"~"^({names})$"]({bbox});')
    return '[out:json][timeout:90];\n(\n' + "\n".join(clauses) + '\n);\nout center tags;'


def fetch_overpass(query: str, endpoints: tuple[str, ...] = OVERPASS_ENDPOINTS) -> dict:
    data = urlencode({"data": query}).encode("utf-8")
    errors: list[str] = []
    for endpoint in endpoints:
        for attempt in range(2):
            req = Request(endpoint, data=data, headers={
                "User-Agent": USER_AGENT,
                "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                "Accept": "application/json",
            })
            try:
                with urlopen(req, timeout=125) as response:
                    result = json.load(response)
                if not isinstance(result, dict) or not isinstance(result.get("elements"), list):
                    raise ValueError("Overpass returned an invalid JSON response")
                if result.get("remark"):
                    raise ValueError(f"Overpass error: {result['remark']}")
                LOGGER.info("Overpass success: %s, %s elements", endpoint, len(result["elements"]))
                return result
            except HTTPError as exc:
                errors.append(f"{endpoint}: HTTP {exc.code}")
                # Don't repeatedly retry invalid queries or authorization errors.
                if exc.code not in (429, 502, 503, 504):
                    break
                if attempt == 0:
                    retry_after = exc.headers.get("Retry-After", "")
                    pause = min(int(retry_after), 30) if retry_after.isdigit() else 8
                    time.sleep(pause)
            except (URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
                errors.append(f"{endpoint}: {type(exc).__name__}: {exc}")
                if attempt == 0:
                    time.sleep(3)
    raise RuntimeError("All Overpass endpoints failed: " + "; ".join(errors[-8:]))


def overpass_rows(
    boxes: list[tuple[float, float, float, float]],
    fixture: Path | None = None,
) -> Iterable[dict[str, Any]]:
    retrieved = now_utc()
    for box in boxes:
        result = json.loads(fixture.read_text(encoding="utf-8")) if fixture else fetch_overpass(overpass_query(box))
        if result.get("remark"):
            raise RuntimeError(f"Fixture/API contains error: {result['remark']}")
        if not isinstance(result.get("elements"), list):
            raise ValueError("Invalid Overpass JSON: missing elements list")
        for element in result["elements"]:
            osm_type = element.get("type", "")
            if osm_type not in ("node", "way", "relation") or "id" not in element:
                continue
            point = element if osm_type == "node" else element.get("center", {})
            if not isinstance(point, dict) or "lat" not in point or "lon" not in point:
                continue
            lat, lon = float(point["lat"]), float(point["lon"])
            if not inside(lat, lon, boxes):
                continue
            tags = element.get("tags") or {}
            if not isinstance(tags, dict):
                continue
            item = record(osm_type, int(element["id"]), lat, lon, tags,
                          "node" if osm_type == "node" else "bbox_center",
                          "fixture" if fixture else "overpass", retrieved)
            if item:
                yield item


def geometry_bbox_center(geom: dict) -> tuple[float, float]:
    """Return bbox center from a GeoJSON Polygon/MultiPolygon geometry."""
    lats: list[float] = []
    lons: list[float] = []
    def visit(value: Any) -> None:
        if isinstance(value, (list, tuple)):
            if len(value) >= 2 and isinstance(value[0], (int, float)) and isinstance(value[1], (int, float)):
                lons.append(float(value[0]))
                lats.append(float(value[1]))
            else:
                for sub in value:
                    visit(sub)
    visit(geom.get("coordinates", []))
    if not lats:
        raise ValueError("Empty area geometry")
    return (min(lats) + max(lats)) / 2, (min(lons) + max(lons)) / 2


def pbf_rows_to_csv(
    path: Path,
    boxes: list[tuple[float, float, float, float]],
    emit: Any,
) -> None:
    try:
        import osmium
    except ImportError as exc:
        raise RuntimeError(
            "PBF fallback requires pyosmium. Run: python -m pip install osmium"
        ) from exc
    retrieved = now_utc()
    geojson = osmium.geom.GeoJSONFactory()

    class POIHandler(osmium.SimpleHandler):
        def node(self, obj: Any) -> None:
            tags = dict(obj.tags)
            if not classify(tags) or not obj.location.valid():
                return
            lat, lon = obj.location.lat, obj.location.lon
            if inside(lat, lon, boxes):
                item = record("node", obj.id, lat, lon, tags, "node", "geofabrik_pbf", retrieved)
                if item:
                    emit(item)

        def way(self, obj: Any) -> None:
            # Closed ways appear in area() with their own tags/area geometry.
            if obj.is_closed():
                return
            tags = dict(obj.tags)
            if not classify(tags):
                return
            coords = [(ref.lat, ref.lon) for ref in obj.nodes if ref.location.valid()]
            if not coords:
                return
            lat = (min(a for a, _ in coords) + max(a for a, _ in coords)) / 2
            lon = (min(b for _, b in coords) + max(b for _, b in coords)) / 2
            if inside(lat, lon, boxes):
                item = record("way", obj.id, lat, lon, tags, "bbox_center", "geofabrik_pbf", retrieved)
                if item:
                    emit(item)

        def area(self, obj: Any) -> None:
            tags = dict(obj.tags)
            if not classify(tags):
                return
            try:
                geom = json.loads(geojson.create_multipolygon(obj))
                lat, lon = geometry_bbox_center(geom)
            except (ValueError, RuntimeError) as exc:
                LOGGER.debug("Skipping invalid area %s: %s", obj.orig_id(), exc)
                return
            if inside(lat, lon, boxes):
                osm_type = "way" if obj.from_way() else "relation"
                item = record(osm_type, obj.orig_id(), lat, lon, tags,
                              "bbox_center", "geofabrik_pbf", retrieved)
                if item:
                    emit(item)

    LOGGER.info("Reading PBF %s (area support requires two passes)", path)
    POIHandler().apply_file(str(path), locations=True, idx="sparse_file_array")


def download_pbf(path: Path) -> None:
    if path.exists() and path.stat().st_size > 1_000_000:
        LOGGER.info("Using cached Geofabrik PBF: %s", path)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".part")
    LOGGER.info("Downloading Geofabrik extract (hundreds of MB) to %s", path)
    req = Request(GEOFABRIK_URL, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(req, timeout=90) as response, temp.open("wb") as output:
            expected = int(response.headers.get("Content-Length") or "0")
            downloaded = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
                downloaded += len(chunk)
                if downloaded % (50 * 1024 * 1024) < len(chunk):
                    LOGGER.info("Downloaded %.0f MB", downloaded / 1024 / 1024)
        if downloaded <= 1_000_000 or (expected and expected != downloaded):
            raise RuntimeError(f"Incomplete PBF: received {downloaded} bytes, expected {expected}")
        temp.replace(path)
    finally:
        # Don't confuse a partial transfer with a finished cached extract.
        if temp.exists():
            temp.unlink()


def run(args: argparse.Namespace) -> dict[str, Any]:
    boxes = parse_boxes(args.bbox)
    out = args.output
    out.parent.mkdir(parents=True, exist_ok=True)
    csv_tmp = out.with_name(out.name + ".partial")
    meta = out.with_suffix(".summary.json")
    start = time.monotonic()
    counts = Counter()
    seen: set[str] = set()
    result_source = ""
    failures: list[str] = []

    def reset() -> None:
        seen.clear()
        counts.clear()

    def ingest(source: str, writer: Any) -> None:
        nonlocal result_source
        reset()
        def emit(item: dict[str, Any]) -> None:
            if item["osm_uid"] in seen:
                return
            seen.add(item["osm_uid"])
            writer.writerow(item)
            for group in item["groups"].split("|"):
                counts[group] += 1
        if source == "fixture":
            if not args.fixture:
                raise ValueError("--fixture requires a local Overpass JSON filename")
            for item in overpass_rows(boxes, args.fixture):
                emit(item)
        elif source == "overpass":
            for item in overpass_rows(boxes):
                emit(item)
        elif source == "pbf":
            pbf = args.pbf
            if not pbf.is_file():
                if args.no_download:
                    raise RuntimeError(f"PBF missing: {pbf}; remove --no-download to download it")
                download_pbf(pbf)
            pbf_rows_to_csv(pbf, boxes, emit)
        else:
            raise ValueError(f"Unsupported source: {source}")
        if not seen:
            raise RuntimeError(f"{source} produced zero matching POIs: refusing false-success output")
        result_source = source

    sources = (["fixture"] if args.fixture else
               ["overpass", "pbf"] if args.source == "auto" else [args.source])
    try:
        for source in sources:
            try:
                # Clean temporary file for each attempt; no partial results from failures.
                with csv_tmp.open("w", newline="", encoding="utf-8-sig") as handle:
                    writer = csv.DictWriter(handle, fieldnames=COLUMNS)
                    writer.writeheader()
                    ingest(source, writer)
                break
            except (OSError, RuntimeError, ValueError, HTTPError, URLError) as exc:
                failures.append(f"{source}: {exc}")
                LOGGER.warning("Source %s failed: %s", source, exc)
                if source == sources[-1]:
                    raise RuntimeError("No OSM source succeeded. " + "; ".join(failures)) from exc
        csv_tmp.replace(out)
        summary = {
            "status": "success",
            "source": result_source,
            "record_count": len(seen),
            "group_counts": dict(sorted(counts.items())),
            "bounding_boxes_s_w_n_e": boxes,
            "created_at_utc": now_utc(),
            "seconds_elapsed": round(time.monotonic() - start, 2),
            "osm_attribution": "© OpenStreetMap contributors (ODbL 1.0)",
            "source_url": GEOFABRIK_URL if result_source == "pbf" else "Overpass API",
            "source_failures": failures,
            "coordinate_note": "Ways and relations use a bbox center, not precise polygon geometry.",
        }
        meta.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
        return summary
    finally:
        if csv_tmp.exists():
            csv_tmp.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bbox", nargs=4, type=float, action="append", required=True,
                        metavar=("SOUTH", "WEST", "NORTH", "EAST"),
                        help="Repeat for multiple regions; coordinates in WGS84")
    parser.add_argument("--source", choices=("auto", "overpass", "pbf"), default="auto")
    parser.add_argument("--fixture", type=Path, help="Local Overpass JSON, for offline verification")
    parser.add_argument("--pbf", type=Path, default=Path("data/malaysia-singapore-brunei-latest.osm.pbf"))
    parser.add_argument("--no-download", action="store_true", help="Do not auto-fetch the large Geofabrik PBF")
    parser.add_argument("--output", type=Path, default=Path("outputs/sitewise_osm_pois.csv"))
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    try:
        summary = run(args)
    except (RuntimeError, ValueError, OSError) as exc:
        LOGGER.error("Ingestion failed: %s", exc)
        return 1
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
