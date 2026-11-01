#!/usr/bin/env python3
"""Collect Google Maps ratings/review counts through the local Docker scraper API.

The Docker container serves the gosom/google-maps-scraper API on localhost:8080.
This script runs on the Windows host, submits one job per unique property coordinate,
then calculates property-level 1 km rating/review features from the returned CSV.

Required Python package: openpyxl
"""

from __future__ import annotations

import argparse
import hashlib
import csv
import io
import json
import math
import random
import re
import subprocess
import shutil
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

try:
    from openpyxl import Workbook, load_workbook
    from openpyxl.styles import Font, PatternFill
    from openpyxl.utils import get_column_letter
except ImportError:
    print("Missing dependency: openpyxl. Install it with: python -m pip install openpyxl")
    raise


# -----------------------------------------------------------------------------
# CONFIGURATION - change these paths if your folders have moved.
# -----------------------------------------------------------------------------
DEFAULT_INPUT = Path(r"C:\Users\Lenovo\Documents\Qoder\2026-10-30\a9ec8342\gm_batch\Property_CompetitorFeatures_Enhanced_with_google_maps.xlsx")
DEFAULT_OUTPUT = Path(r"C:\Users\Lenovo\Documents\Qoder\2026-10-30\a9ec8342\gm_batch\Property_CompetitorFeatures_Enhanced_with_google_maps_final.xlsx")
# Optional CSV report of failed/incomplete rows; the Excel workbook is always the input.
DEFAULT_RETRY_QUEUE: Path | None = None
DEFAULT_SCRAPER_DIR = Path(
    r"C:\Users\Lenovo\Documents\Qoder\2026-10-30\a9ec8342\google-maps-scraper-kit"
)
DEFAULT_API_BASE = "http://127.0.0.1:18081"

TIMEZONE = ZoneInfo("Asia/Kuala_Lumpur")
COLLECTION_WINDOWS = ((7, 9), (17, 19))  # Malaysia Time, end hour is exclusive
DEFAULT_RADIUS_M = 1000
DEFAULT_DEPTH = 5
DEFAULT_MAX_TIME_SECONDS = 300
REQUEST_PAUSE_MIN_SECONDS = 8
REQUEST_PAUSE_MAX_SECONDS = 12
POLL_SECONDS = 10

# The four fixed F&B groups from the project. Each keyword includes the property's
# coordinates and state so the scraper searches around the actual property.
KEYWORD_TEMPLATES = [
    "cafes and coffee shops near {lat},{lon}, {state}, Malaysia",
    "kopitiam and coffee bars near {lat},{lon}, {state}, Malaysia",
    "restaurants and casual dining near {lat},{lon}, {state}, Malaysia",
    "mamak, kedai makan and local eateries near {lat},{lon}, {state}, Malaysia",
    "fast food and takeaway near {lat},{lon}, {state}, Malaysia",
    "burger and fried chicken shops near {lat},{lon}, {state}, Malaysia",
    "bakeries and pastry shops near {lat},{lon}, {state}, Malaysia",
    "dessert shops, bubble tea, ice cream and juice bars near {lat},{lon}, {state}, Malaysia",
    "food courts, hawker centres and food stalls near {lat},{lon}, {state}, Malaysia",
    "tea houses and tea rooms near {lat},{lon}, {state}, Malaysia",
]

# Match only the scraper's displayed category, never the business name or query.
# Rules are full matches after punctuation/underscores are converted to spaces.
# Narrow groups precede general restaurants. Unmatched categories are excluded
# and retained in category_audit for manual review, not guessed from names.
FNB_CATEGORY_RULES = {
    "fast_food_takeaway": [
        r"(?:.* )?fast food restaurant", r"(?:.* )?takeaway(?: restaurant)?",
        r"(?:meal|food) takeaway", r"(?:hamburger|burger|fried chicken|chicken wings|hot dog|sandwich|kebab) (?:restaurant|shop|stand)",
        r"(?:fish and chips|pizza) takeaway",
    ],
    "bakeries_desserts": [
        r"(?:.* )?bakery", r"bakery and cake shop", r"(?:cake|pastry|pie|cookie|donut|doughnut|cupcake|confectionery|chocolate) shop",
        r"(?:.* )?dessert (?:shop|restaurant|cafe)",
        r"(?:ice cream|frozen yogurt) shop", r"bubble tea (?:store|shop)",
        r"juice (?:shop|bar)", r"patisserie", r"kedai (?:roti|kek)",
    ],
    "cafes_coffee": [
        r"(?:.* )?cafe", r"coffee (?:shop|stand|bar)", r"espresso bar", r"coffeehouse",
        r"tea (?:house|room)", r"kopitiam", r"cafeteria", r"kafe", r"kedai kopi",
    ],
    "restaurants_casual_dining": [
        r"(?:.* )?restaurant", r"diner", r"bistro", r"brasserie",
        r"food court", r"hawker (?:centre|center|stall)", r"food (?:stall|stand)",
        r"kedai makan", r"mamak(?: stall)?", r"restoran", r"warung", r"gerai makanan", r"canteen",
    ],
}
PRICE_GROUPS = {
    "cafe": "cafes_coffee",
    "restaurant": "restaurants_casual_dining",
    "fast_food": "fast_food_takeaway",
    "bakery_dessert_beverage": "bakeries_desserts",
}
PRICE_RADII = ((500, "500m"), (1000, "1km"))
PRICE_HEADERS = [
    f"avg_{prefix}_price_{label}_rm"
    for prefix in PRICE_GROUPS for _, label in PRICE_RADII
] + [
    f"{prefix}_priced_count_{label}"
    for prefix in PRICE_GROUPS for _, label in PRICE_RADII
]
FEATURE_METHOD_VERSION = "category_validated_rm_midpoint_v2"
AUDIT_HEADERS = ["property_latitude", "property_longitude", "place_id", "cid", "title",
                 "category", "fnb_group", "distance_m", "included", "decision",
                 "review_rating", "review_count", "job_id", "feature_method",
                 "raw_price_range", "price_low_rm", "price_high_rm",
                 "representative_price_rm", "price_parse_status"]

OUTPUT_HEADERS = [
    "canonical_property_id",
    "latitude",
    "longitude",
    "state",
    "avg_competitor_rating_1km",
    "avg_competitor_review_count_1km",
    "rated_competitor_count_1km",
    "rating_scrape_status",
    "scrape_timestamp_myt",
    "feature_method",
    "accepted_fnb_count_1km",
    "excluded_category_count",
    "missing_category_count",
] + PRICE_HEADERS

SUCCESS_STATUSES = {"SCRAPED", "NO_RESULTS", "NO_FNB_RESULTS"}
MALAYSIA_BOUNDS = (0.8, 7.5, 99.5, 119.5)  # min_lat, max_lat, min_lon, max_lon


# -----------------------------------------------------------------------------
# General helpers
# -----------------------------------------------------------------------------
def norm_header(value: Any) -> str:
    text = str(value or "").strip().lower()
    return re.sub(r"[^a-z0-9]+", "", text)


def parse_float(value: Any) -> float | None:
    if value is None:
        return None
    text = str(value).strip().replace(",", "")
    if not text or text.lower() in {"none", "null", "nan", "n/a", "na", "-"}:
        return None
    try:
        number = float(text)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def parse_review_count(value: Any) -> int | None:
    """Parse an exact numeric Google review count; do not approximate '1.2K'."""
    if value is None:
        return None
    text = str(value).strip().replace(",", "")
    if not text or text.lower() in {"none", "null", "nan", "n/a", "na", "-"}:
        return None
    if re.search(r"[kKmMbB]", text):
        return None  # abbreviated count is not an exact count
    match = re.fullmatch(r"\s*(\d+)(?:\.0+)?\s*", text)
    if not match:
        return None
    try:
        result = int(match.group(1))
    except ValueError:
        return None
    return result if result >= 0 else None


def parse_price_rm(value: Any) -> tuple[float | None, float | None, float | None, str]:
    """Return (representative, low, high, status). Never convert price-level symbols.

    A numeric RM/MYR range uses its midpoint as an estimated spend per business.
    It is not a menu-item price. Unbounded ranges and foreign/unknown currencies
    cannot produce an RM estimate and remain missing.
    """
    text = str(value or "").strip().replace("\u00a0", " ")
    if not text or text.lower() in {"none", "null", "nan", "n/a", "na", "-"}:
        return None, None, None, "MISSING_PRICE"
    text = re.sub(r"[\u2010-\u2015\u2212]", "-", text)
    number = r"(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?"
    match = re.fullmatch(
        rf"(?:(?:price|cost)\s+per\s+(?:person|pax)\s*:?\s*)?"
        rf"(?:RM|MYR)\s*({number})"
        rf"(?:\s*-\s*(?:(?:RM|MYR)\s*)?({number}))?"
        rf"(?:\s*(?:per\s+(?:person|pax)|/\s*(?:person|pax)))?",
        text, flags=re.IGNORECASE,
    )
    if not match:
        return None, None, None, "UNSUPPORTED_OR_NON_RM_PRICE"
    low = parse_float(match.group(1))
    high = parse_float(match.group(2)) if match.group(2) is not None else low
    if low is None or high is None or low <= 0 or high < low:
        return None, None, None, "INVALID_RM_PRICE"
    midpoint = (low + high) / 2
    return midpoint, low, high, "RM_RANGE_MIDPOINT" if match.group(2) else "EXACT_RM_PRICE"


def valid_rating(value: Any) -> float | None:
    rating = parse_float(value)
    if rating is None or not (1.0 <= rating <= 5.0):
        return None
    return rating


def valid_malaysia_coordinate(lat: float | None, lon: float | None) -> bool:
    if lat is None or lon is None:
        return False
    min_lat, max_lat, min_lon, max_lon = MALAYSIA_BOUNDS
    return min_lat <= lat <= max_lat and min_lon <= lon <= max_lon


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    earth_radius_m = 6_371_008.8
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * earth_radius_m * math.asin(math.sqrt(min(1.0, a)))


def normalize_name(value: Any) -> str:
    text = unicodedata.normalize("NFKD", str(value or ""))
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.casefold()
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return " ".join(text.split())


def now_myt_text() -> str:
    return datetime.now(TIMEZONE).isoformat(timespec="seconds")


def inside_collection_window() -> bool:
    current = datetime.now(TIMEZONE)
    return any(start <= current.hour < end for start, end in COLLECTION_WINDOWS)


def http_json(method: str, url: str, payload: dict[str, Any] | None = None,
              timeout: int = 60) -> Any:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {"Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            if not raw:
                return {}
            return json.loads(raw.decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} calling {url}: {body[:1000]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Cannot reach scraper API at {url}: {exc}") from exc


def http_bytes(url: str, timeout: int = 180) -> bytes:
    request = urllib.request.Request(url, headers={"Accept": "text/csv,*/*"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} downloading results: {body[:1000]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Could not download scraper results: {exc}") from exc


# -----------------------------------------------------------------------------
# Input workbook inspection
# -----------------------------------------------------------------------------
def find_source_sheet(input_path: Path):
    """Read rows even when the workbook omits worksheet dimension metadata."""
    from itertools import chain, islice

    wb = load_workbook(input_path, read_only=True, data_only=True)
    candidates = []
    aliases = {
        "id": {"canonicalpropertyid", "canonicalid", "propertyid"},
        "lat": {"latitude", "lat", "propertylatitude"},
        "lon": {"longitude", "lon", "lng", "long", "propertylongitude"},
        "state": {"state", "propertystate"},
    }
    try:
        for ws in wb.worksheets:
            # Stream once; repeated ws.cell() calls reread a read-only sheet.
            iterator = ws.iter_rows(values_only=True)
            preview = list(islice(iterator, 15))
            source_header = None
            for header_row, values in enumerate(preview, start=1):
                headers = [norm_header(value) for value in values]
                mapping = {}
                for key, names in aliases.items():
                    for idx, header in enumerate(headers):
                        if header in names:
                            mapping[key] = idx
                            break
                if {"id", "lat", "lon"}.issubset(mapping):
                    source_header = (header_row, mapping)
                    break
            if source_header is None:
                continue

            header_row, mapping = source_header
            rows = []
            for excel_row, values in enumerate(
                chain(preview[header_row:], iterator), start=header_row + 1
            ):
                def value(key):
                    col = mapping.get(key)
                    return values[col] if col is not None and col < len(values) else None

                prop_id = value("id")
                lat = parse_float(value("lat"))
                lon = parse_float(value("lon"))
                if prop_id is None and lat is None and lon is None:
                    continue
                rows.append({
                    "source_excel_row": excel_row,
                    "canonical_property_id": prop_id,
                    "latitude": lat,
                    "longitude": lon,
                    "state": str(value("state") or "").strip(),
                })
            candidates.append((len(rows), ws.title, header_row, rows))
    finally:
        wb.close()

    if not candidates:
        raise RuntimeError(
            "Could not find a worksheet with canonical_property_id/property_id, latitude and longitude."
        )
    _, sheet_name, header_row, rows = max(candidates, key=lambda item: item[:3])
    return sheet_name, header_row, rows


# -----------------------------------------------------------------------------
# Docker engine and scraper job
# -----------------------------------------------------------------------------
def ensure_engine(api_base: str, scraper_dir: Path, auto_start: bool = True) -> None:
    health_url = api_base.rstrip("/") + "/api/v1/jobs"
    try:
        http_json("GET", health_url, timeout=8)
        print("[OK] Google Maps scraper API is responding.")
        return
    except Exception as exc:
        if not auto_start:
            raise RuntimeError(f"Scraper API is unavailable at {health_url}: {exc}") from exc

    if not scraper_dir.exists():
        raise RuntimeError(f"Scraper kit folder not found: {scraper_dir}")

    print("[INFO] Scraper API is offline. Starting Docker Compose...")
    try:
        subprocess.run(
            ["docker", "compose", "up", "-d"],
            cwd=str(scraper_dir),
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("Docker CLI not found. Install/start Docker Desktop first.") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"docker compose up failed:\n{exc.stdout}\n{exc.stderr}") from exc

    deadline = time.time() + 90
    last_error = None
    while time.time() < deadline:
        try:
            http_json("GET", health_url, timeout=8)
            print("[OK] Docker scraper API is ready.")
            return
        except Exception as exc:
            last_error = exc
            time.sleep(3)
    raise RuntimeError(
        f"Scraper API did not become ready at {health_url} within 90 seconds. "
        f"Check that --api-base uses the host port shown by docker compose ps. Last error: {last_error}"
    )


def make_keywords(lat: float, lon: float, state: str) -> list[str]:
    safe_state = state or "Malaysia"
    return [
        template.format(lat=f"{lat:.6f}", lon=f"{lon:.6f}", state=safe_state)
        for template in KEYWORD_TEMPLATES
    ]


def run_scraper_job(api_base: str, lat: float, lon: float, state: str,
                    depth: int, radius_m: int, max_time: int) -> tuple[list[dict[str, str]], str]:
    base = api_base.rstrip("/")
    job_payload = {
        "name": f"fnb-rating-{int(time.time())}",
        "keywords": make_keywords(lat, lon, state),
        "lang": "en",
        "zoom": 16,
        "lat": f"{lat:.7f}",
        "lon": f"{lon:.7f}",
        "fast_mode": False,
        "radius": radius_m,
        "depth": depth,
        "email": False,  # not needed for ratings/review-count features
        "max_time": max_time,
    }

    # Reconnect to an identical in-flight job after an interrupted host script.
    existing_jobs = http_json("GET", base + "/api/v1/jobs", timeout=30)
    match_fields = ("keywords", "lang", "zoom", "lat", "lon", "fast_mode", "radius", "depth", "email")
    matching_jobs = []
    for existing in existing_jobs:
        status = str(existing.get("Status", existing.get("status", ""))).lower()
        data = existing.get("Data", existing.get("data", {})) or {}
        if (status in {"pending", "working"}
                and all(data.get(key) == job_payload[key] for key in match_fields)
                and data.get("max_time") in {max_time, max_time * 1_000_000_000}):
            matching_jobs.append(existing)
    if matching_jobs:
        created = next((job for job in matching_jobs if job.get("Status") == "working"), matching_jobs[0])
        print("[RESUME] Reconnecting to an existing scraper job.")
    else:
        created = http_json("POST", base + "/api/v1/jobs", job_payload, timeout=60)
    job_id = created.get("id") or created.get("ID")
    if not job_id:
        raise RuntimeError(f"Scraper did not return a job id: {created}")

    print(f"[JOB] {job_id} | {len(KEYWORD_TEMPLATES)} search phrases | radius={radius_m}m | depth={depth}")
    # Queuing behind another Docker job must not consume the processing allowance.
    queue_deadline = time.time() + 3600
    deadline = None
    final_status = "unknown"
    previous_status = None
    last_payload: dict[str, Any] = {}

    while True:
        last_payload = http_json("GET", f"{base}/api/v1/jobs/{job_id}", timeout=30)
        final_status = str(last_payload.get("Status", last_payload.get("status", "unknown"))).lower()
        if final_status != previous_status:
            print(f"[STATUS] {job_id}: {final_status}")
            previous_status = final_status
        if final_status in {"ok", "failed", "error", "cancelled", "canceled"}:
            break
        if final_status in {"pending", "queued"}:
            if deadline is None and time.time() >= queue_deadline:
                break
        elif deadline is None:
            deadline = time.time() + max_time + 120
        if deadline is not None and time.time() >= deadline:
            break
        time.sleep(POLL_SECONDS)

    if final_status != "ok":
        error_text = json.dumps(last_payload, ensure_ascii=False).lower()
        blocked_terms = ("captcha", "unusual traffic", "blocked", "rate limit", "too many requests")
        status = "BLOCKED" if any(term in error_text for term in blocked_terms) else "FAILED"
        raise ScrapeJobError(status, f"Job {job_id} ended with status={final_status}; details={last_payload}")

    csv_bytes = http_bytes(f"{base}/api/v1/jobs/{job_id}/download")
    csv_text = csv_bytes.decode("utf-8-sig", errors="replace")
    reader = csv.DictReader(io.StringIO(csv_text))
    results = [dict(row) for row in reader]
    return results, job_id


class ScrapeJobError(RuntimeError):
    def __init__(self, status: str, message: str):
        super().__init__(message)
        self.status = status


# -----------------------------------------------------------------------------
# Deduplicate results and compute 1 km metrics
# -----------------------------------------------------------------------------
def feature_method(radius_m: int) -> str:
    settings = json.dumps([FNB_CATEGORY_RULES, KEYWORD_TEMPLATES, radius_m,
                           PRICE_GROUPS, PRICE_RADII, "explicit_RM_range_midpoint"], sort_keys=True)
    digest = hashlib.sha256(settings.encode("utf-8")).hexdigest()[:12]
    return f"{FEATURE_METHOD_VERSION}:{digest}"


def classify_fnb_category(category: Any) -> tuple[str | None, str]:
    label = normalize_name(category)
    if not label or label in {"none", "null", "nan", "n a"}:
        return None, "MISSING_CATEGORY"
    # Prevent category suffix rules from accepting venues outside this study's scope.
    if re.search(r"\b(?:equipment|supplier|supplies|wholesale|wholesaler|internet|gaming)\b", label):
        return None, "CATEGORY_NOT_IN_SCOPE"
    for group, patterns in FNB_CATEGORY_RULES.items():
        if any(re.fullmatch(pattern, label) for pattern in patterns):
            return group, "CATEGORY_MATCH"
    return None, "CATEGORY_NOT_IN_SCOPE"


def get_aliases(record: dict[str, str]) -> list[str]:
    aliases = []
    for field in ("place_id", "cid", "data_id"):
        value = str(record.get(field, "") or "").strip()
        if value and value.lower() not in {"nan", "none", "null"}:
            aliases.append(f"{field}:{value.casefold()}")

    name = normalize_name(record.get("title", ""))
    lat = parse_float(record.get("latitude"))
    lon = parse_float(record.get("longitude"))
    # A name/location fallback must not merge distinct Google place IDs at one site.
    if not aliases and name and lat is not None and lon is not None:
        aliases.append(f"fallback:{name}:{lat:.5f}:{lon:.5f}")
    return aliases


def deduplicate_competitors(records: list[dict[str, str]]) -> list[dict[str, Any]]:
    """Dedupe across keyword searches while retaining distinct branches."""
    by_internal_id: dict[int, dict[str, Any]] = {}
    alias_to_id: dict[str, int] = {}
    next_id = 0

    for raw in records:
        aliases = get_aliases(raw)
        matched_ids = {alias_to_id[a] for a in aliases if a in alias_to_id}
        if matched_ids:
            internal_id = min(matched_ids)
            # If aliases now connect previously separate records, merge them.
            for other_id in sorted(matched_ids - {internal_id}):
                other = by_internal_id.pop(other_id, {})
                target = by_internal_id[internal_id]
                for key, value in other.items():
                    if target.get(key) in (None, "") and value not in (None, ""):
                        target[key] = value
                for alias, mapped_id in list(alias_to_id.items()):
                    if mapped_id == other_id:
                        alias_to_id[alias] = internal_id
        else:
            internal_id = next_id
            next_id += 1
            by_internal_id[internal_id] = {}

        target = by_internal_id[internal_id]
        for key, value in raw.items():
            if value not in (None, "") and target.get(key) in (None, ""):
                target[key] = value
        for alias in aliases:
            alias_to_id[alias] = internal_id

    return list(by_internal_id.values())


def compute_rating_features(property_lat: float, property_lon: float,
                            raw_records: list[dict[str, str]], radius_m: int) -> tuple[dict[str, Any], str]:
    unique_records = deduplicate_competitors(raw_records)
    located_records = []
    incomplete = False
    audit = []
    excluded_categories = 0
    missing_categories = 0
    prices = {(group, distance): [] for group in PRICE_GROUPS.values()
              for distance, _ in PRICE_RADII}

    for record in unique_records:
        comp_lat = parse_float(record.get("latitude"))
        comp_lon = parse_float(record.get("longitude"))
        group, decision = classify_fnb_category(record.get("category"))
        distance = (haversine_m(property_lat, property_lon, comp_lat, comp_lon)
                    if valid_malaysia_coordinate(comp_lat, comp_lon) else None)
        price, low, high, price_status = parse_price_rm(record.get("price_range"))
        if group is not None and distance is not None and price is not None:
            for limit, _ in PRICE_RADII:
                if distance <= limit:
                    prices[group, limit].append(price)
        included = False
        if decision == "CATEGORY_NOT_IN_SCOPE":
            excluded_categories += 1
        elif distance is not None and distance > radius_m:
            decision = "OUTSIDE_RADIUS"
        elif group is None:
            missing_categories += 1
            incomplete = True
        elif distance is None:
            decision = "MISSING_OR_INVALID_COORDINATE"
            incomplete = True
        else:
            decision = "INCLUDED"
            included = True
            located_records.append({
                "rating": valid_rating(record.get("review_rating")),
                "review_count": parse_review_count(record.get("review_count")),
            })
        audit.append([
            property_lat, property_lon, record.get("place_id"), record.get("cid"),
            record.get("title"), record.get("category"), group,
            round(distance, 2) if distance is not None else None, included, decision,
            valid_rating(record.get("review_rating")), parse_review_count(record.get("review_count")),
            record.get("price_range"), low, high, price, price_status,
        ])

    ratings = [r["rating"] for r in located_records if r["rating"] is not None]
    review_counts = [r["review_count"] for r in located_records if r["review_count"] is not None]

    result = {
        "avg_competitor_rating_1km": round(sum(ratings) / len(ratings), 3) if ratings else None,
        "avg_competitor_review_count_1km": round(sum(review_counts) / len(review_counts), 2) if review_counts else None,
        "rated_competitor_count_1km": len(ratings),
        "accepted_fnb_count_1km": len(located_records),
        "excluded_category_count": excluded_categories,
        "missing_category_count": missing_categories,
        "feature_method": feature_method(radius_m),
        "_category_audit": audit,
    }
    for prefix, group in PRICE_GROUPS.items():
        for limit, label in PRICE_RADII:
            values = prices[group, limit]
            result[f"avg_{prefix}_price_{label}_rm"] = round(sum(values) / len(values), 2) if values else None
            result[f"{prefix}_priced_count_{label}"] = len(values)

    if not raw_records:
        status = "NO_RESULTS"
    elif incomplete:
        status = "PARTIAL"
    elif not located_records:
        status = "NO_FNB_RESULTS"
    else:
        status = "SCRAPED"
    return result, status


# -----------------------------------------------------------------------------
# Excel output and retry queue
# -----------------------------------------------------------------------------
def create_or_resume_output(output_path: Path, source_rows: list[dict[str, Any]]):
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        wb = load_workbook(output_path)
        if "rating_features" in wb.sheetnames:
            ws = wb["rating_features"]
            existing_ids = [ws.cell(r, 1).value for r in range(2, ws.max_row + 1)]
            source_ids = [r["canonical_property_id"] for r in source_rows]
            same_locations = all(
                (parse_float(ws.cell(idx, 2).value), parse_float(ws.cell(idx, 3).value),
                 str(ws.cell(idx, 4).value or "")) ==
                (row["latitude"], row["longitude"], row["state"])
                for idx, row in enumerate(source_rows, start=2)
            )
            if existing_ids == source_ids and same_locations:
                return wb, ws
        wb.close()
        backup = output_path.with_name(output_path.stem + datetime.now(TIMEZONE).strftime(".before-rebuild-%Y%m%d-%H%M%S-%f") + output_path.suffix)
        shutil.copy2(output_path, backup)
        print(f"[BACKUP] Previous output: {backup}")

    wb = Workbook()
    ws = wb.active
    ws.title = "rating_features"
    ws.append(OUTPUT_HEADERS)
    for row in source_rows:
        ws.append([
            row["canonical_property_id"],
            row["latitude"],
            row["longitude"],
            row["state"],
            None,
            None,
            None,
            "PENDING",
            None,
        ])
    format_output_sheet(ws)
    wb.save(output_path)
    return wb, ws


def format_output_sheet(ws) -> None:
    ws.freeze_panes = "A2"
    ws.auto_filter.ref = ws.dimensions
    for cell in ws[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", fgColor="17365D")
    widths = [24, 13, 13, 18, 25, 33, 25, 28, 26, 42, 26, 25, 25] + [36] * len(PRICE_HEADERS)
    for idx, width in enumerate(widths, start=1):
        ws.column_dimensions[get_column_letter(idx)].width = width
    for r in range(2, ws.max_row + 1):
        for col, header in enumerate(OUTPUT_HEADERS, start=1):
            if header.startswith("avg_") and header.endswith("_rm"):
                ws.cell(r, col).number_format = '"RM" #,##0.00'


def prepare_output_method(wb, ws, output_path: Path, radius_m: int) -> None:
    """Invalidate old features so keyword-only results cannot be resumed as validated."""
    method = feature_method(radius_m)
    outdated = [r for r in range(2, ws.max_row + 1) if ws.cell(r, 10).value != method]
    if outdated:
        if any(ws.cell(r, 8).value not in (None, "PENDING") for r in outdated):
            backup = output_path.with_name(output_path.stem + datetime.now(TIMEZONE).strftime(".before-category-update-%Y%m%d-%H%M%S-%f") + output_path.suffix)
            shutil.copy2(output_path, backup)
            print(f"[BACKUP] Previous output: {backup}")
        outdated_coords = {tuple(round(float(ws.cell(r, c).value), 6) if ws.cell(r, c).value is not None else None
                                 for c in (2, 3)) for r in outdated}
        clear_metrics_for_group(ws, outdated, "PENDING")
        for r in outdated:
            ws.cell(r, 10).value = method
        if "category_audit" in wb.sheetnames:
            audit_ws = wb["category_audit"]
            for r in range(audit_ws.max_row, 1, -1):
                if (audit_ws.cell(r, 1).value, audit_ws.cell(r, 2).value) in outdated_coords:
                    audit_ws.delete_rows(r)
        print(f"[METHOD] Reset {len(outdated)} rows for category validation.")
    for col, header in enumerate(OUTPUT_HEADERS, start=1):
        ws.cell(1, col).value = header
    if "category_audit" not in wb.sheetnames:
        audit_ws = wb.create_sheet("category_audit")
        audit_ws.freeze_panes = "A2"
    for col, header in enumerate(AUDIT_HEADERS, start=1):
        wb["category_audit"].cell(1, col).value = header
    if "feature_definitions" not in wb.sheetnames:
        definitions = wb.create_sheet("feature_definitions")
        definitions.append(["feature", "definition"])
    else:
        definitions = wb["feature_definitions"]
        definitions.delete_rows(2, max(0, definitions.max_row - 1))
    for header in PRICE_HEADERS:
        definition = ("Estimated mean RM spend across unique category-validated businesses in this radius. "
                      "Uses explicit RM/MYR amounts or the midpoint of a bounded numeric RM range. "
                      "Not an observed mean menu-item price; missing/symbol-only prices excluded."
                      if header.startswith("avg_") else
                      "Number of unique category-validated businesses in this radius with a usable numeric RM price. "
                      "Independent of whether a rating is available. Zero means no usable observed prices.")
        definitions.append([header, definition])
    definitions.freeze_panes = "A2"
    definitions.column_dimensions["A"].width = 55
    definitions.column_dimensions["B"].width = 110
    format_output_sheet(ws)
    wb.save(output_path)


def save_category_audit(wb, lat: float, lon: float, metrics: dict[str, Any], job_id: str) -> None:
    ws = wb["category_audit"]
    for r in range(ws.max_row, 1, -1):
        if (ws.cell(r, 1).value, ws.cell(r, 2).value) == (lat, lon):
            ws.delete_rows(r)
    for record in metrics["_category_audit"]:
        ws.append(record[:12] + [job_id, metrics["feature_method"]] + record[12:])
    ws.auto_filter.ref = ws.dimensions


def write_retry_queue(path: Path | None, source_rows: list[dict[str, Any]], ws) -> None:
    if path is None:
        return
    retry_statuses = {"PARTIAL", "BLOCKED", "FAILED", "INVALID_COORDINATE"}
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.writer(f)
        writer.writerow(["source_excel_row", "canonical_property_id", "latitude", "longitude", "state", "rating_scrape_status"])
        for idx, source in enumerate(source_rows, start=2):
            status = str(ws.cell(idx, 8).value or "")
            if status in retry_statuses:
                writer.writerow([
                    source["source_excel_row"], source["canonical_property_id"],
                    source["latitude"], source["longitude"], source["state"], status,
                ])


def apply_metrics_to_group(ws, output_rows: list[int], metrics: dict[str, Any], status: str) -> None:
    timestamp = now_myt_text()
    for row_no in output_rows:
        ws.cell(row_no, 5).value = metrics.get("avg_competitor_rating_1km")
        ws.cell(row_no, 6).value = metrics.get("avg_competitor_review_count_1km")
        ws.cell(row_no, 7).value = metrics.get("rated_competitor_count_1km")
        ws.cell(row_no, 8).value = status
        ws.cell(row_no, 9).value = timestamp
        for col, key in enumerate(OUTPUT_HEADERS[9:], start=10):
            ws.cell(row_no, col).value = metrics.get(key)


def clear_metrics_for_group(ws, output_rows: list[int], status: str) -> None:
    timestamp = now_myt_text()
    for row_no in output_rows:
        for col in (5, 6, 7):
            ws.cell(row_no, col).value = None
        for col in range(11, len(OUTPUT_HEADERS) + 1):
            ws.cell(row_no, col).value = None
        ws.cell(row_no, 8).value = status
        ws.cell(row_no, 9).value = timestamp


# -----------------------------------------------------------------------------
# Main pipeline
# -----------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Collect Google Maps ratings/review counts for F&B competitors within 1 km using Docker."
    )
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--retry-queue", type=Path, default=DEFAULT_RETRY_QUEUE,
                        help="Optional CSV report of failed/incomplete rows; not an input file.")
    parser.add_argument("--scraper-dir", type=Path, default=DEFAULT_SCRAPER_DIR)
    parser.add_argument("--api-base", default=DEFAULT_API_BASE)
    parser.add_argument("--radius", type=int, default=DEFAULT_RADIUS_M)
    parser.add_argument("--depth", type=int, default=DEFAULT_DEPTH)
    parser.add_argument("--max-time", type=int, default=DEFAULT_MAX_TIME_SECONDS)
    parser.add_argument("--no-auto-start", action="store_true", help="Do not start Docker Compose automatically.")
    parser.add_argument("--enforce-time-window", action="store_true", help="Restrict collection to 07:00-09:00 / 17:00-19:00 MYT; default allows any time.")
    parser.add_argument("--ignore-time-window", action="store_true", help="Do not enforce the 07:00-09:00 / 17:00-19:00 MYT windows.")
    args = parser.parse_args()

    if not args.input.exists():
        print(f"[ERROR] Input workbook not found: {args.input}")
        return 2
    if args.radius <= 0 or args.depth <= 0 or args.max_time <= 0:
        print("[ERROR] radius, depth and max-time must be positive values.")
        return 2
    if args.radius != 1000:
        print("[ERROR] These output columns use fixed 500m/1km distances. Use --radius 1000.")
        return 2

    if args.enforce_time_window and not args.ignore_time_window and not inside_collection_window():
        now_text = datetime.now(TIMEZONE).strftime("%Y-%m-%d %H:%M:%S MYT")
        print(f"[STOP] Current time is {now_text}. Collection is restricted to 07:00-09:00 or 17:00-19:00 MYT.")
        print("Run during a collection window, omit --enforce-time-window, or use --ignore-time-window.")
        return 2

    print(f"[INPUT] Reading workbook: {args.input}", flush=True)
    try:
        source_sheet, header_row, source_rows = find_source_sheet(args.input)
    except Exception as exc:
        print(f"[ERROR] Input inspection failed: {exc}")
        return 2

    if not source_rows:
        print("[ERROR] No property records were found in the selected worksheet.")
        return 2

    print(f"[INPUT] {args.input}")
    print(f"[INPUT] Worksheet: {source_sheet} | Header row: {header_row} | Property records: {len(source_rows)}")
    print(f"[OUTPUT] {args.output}")

    try:
        ensure_engine(args.api_base, args.scraper_dir, auto_start=not args.no_auto_start)
    except Exception as exc:
        print(f"[ERROR] Docker scraper is unavailable: {exc}")
        return 2

    wb, ws = create_or_resume_output(args.output, source_rows)
    prepare_output_method(wb, ws, args.output, args.radius)
    print("[METHOD] Category validation enabled. Only matching F&B categories within the radius are included.")
    print("[PRICE] RM-range midpoints are estimates. Missing and symbol-only prices remain blank; priced counts show coverage.")

    # Group exact/near-identical coordinates to avoid repeating the same Google Maps job.
    groups: dict[tuple[float, float], list[int]] = defaultdict(list)
    invalid_rows: list[int] = []
    for idx, row in enumerate(source_rows, start=2):
        lat, lon = row["latitude"], row["longitude"]
        if not valid_malaysia_coordinate(lat, lon):
            invalid_rows.append(idx)
            if str(ws.cell(idx, 8).value or "") != "INVALID_COORDINATE":
                clear_metrics_for_group(ws, [idx], "INVALID_COORDINATE")
            continue
        key = (round(lat, 6), round(lon, 6))
        groups[key].append(idx)

    for idx in invalid_rows:
        print(f"[INVALID] Excel output row {idx}: property coordinate missing or outside Malaysia bounds.")

    # Coordinate group is skipped only when every mapped property row already succeeded.
    work_groups = []
    for coord, output_rows in groups.items():
        statuses = [str(ws.cell(r, 8).value or "PENDING") for r in output_rows]
        if all(status in SUCCESS_STATUSES for status in statuses):
            continue
        work_groups.append((coord, output_rows))

    print(f"[PLAN] Unique valid coordinate groups: {len(groups)} | To process/resume: {len(work_groups)}")

    processed_source_rows = 0
    successful_jobs = 0
    failed_jobs = 0
    for group_index, ((lat, lon), output_rows) in enumerate(work_groups, start=1):
        first_source = source_rows[output_rows[0] - 2]
        state = first_source["state"] or "Malaysia"
        property_ids = [source_rows[r - 2]["canonical_property_id"] for r in output_rows]
        print(
            f"\n[{group_index}/{len(work_groups)}] Searching coordinate {lat:.6f},{lon:.6f} "
            f"for {len(output_rows)} property row(s); IDs={property_ids[:3]}"
        )

        try:
            raw_records, job_id = run_scraper_job(
                args.api_base, lat, lon, state, args.depth, args.radius, args.max_time
            )
            metrics, status = compute_rating_features(lat, lon, raw_records, args.radius)
            save_category_audit(wb, lat, lon, metrics, job_id)
            apply_metrics_to_group(ws, output_rows, metrics, status)
            successful_jobs += 1
            print(
                f"[RESULT] {status} | unique rows returned={len(deduplicate_competitors(raw_records))} "
                f"| avg rating={metrics['avg_competitor_rating_1km']} "
                f"| avg review count={metrics['avg_competitor_review_count_1km']} "
                f"| rated competitors={metrics['rated_competitor_count_1km']} | job={job_id}"
            )
            print(f"[CATEGORY] Accepted within radius={metrics['accepted_fnb_count_1km']} "
                  f"| excluded by category={metrics['excluded_category_count']} "
                  f"| missing category within radius/unknown location={metrics['missing_category_count']}")
            priced = sum(metrics[f"{prefix}_priced_count_1km"] for prefix in PRICE_GROUPS)
            print(f"[PRICE] Businesses with usable numeric RM prices within 1km: {priced}")
        except ScrapeJobError as exc:
            clear_metrics_for_group(ws, output_rows, exc.status)
            failed_jobs += 1
            print(f"[ERROR] {exc}")
        except Exception as exc:
            clear_metrics_for_group(ws, output_rows, "FAILED")
            failed_jobs += 1
            print(f"[ERROR] {exc}")

        processed_source_rows += len(output_rows)
        # Save after each group and after every configured source-record threshold.
        # Saving each group means an interrupted run can resume without losing completed work.
        format_output_sheet(ws)
        wb.save(args.output)
        write_retry_queue(args.retry_queue, source_rows, ws)

        if processed_source_rows < sum(len(g[1]) for g in work_groups):
            pause = random.uniform(REQUEST_PAUSE_MIN_SECONDS, REQUEST_PAUSE_MAX_SECONDS)
            print(f"[WAIT] Pausing {pause:.1f}s before the next property-coordinate job.")
            time.sleep(pause)

    format_output_sheet(ws)
    wb.save(args.output)
    write_retry_queue(args.retry_queue, source_rows, ws)
    wb.close()

    print("\n========== FINAL SUMMARY ==========")
    print(f"Source properties: {len(source_rows)}")
    print(f"Unique valid coordinate groups: {len(groups)}")
    print(f"Successful scraper jobs: {successful_jobs}")
    print(f"Failed/blocked scraper jobs: {failed_jobs}")
    print(f"Invalid-coordinate property rows: {len(invalid_rows)}")
    print(f"Output workbook: {args.output}")
    if args.retry_queue is not None:
        print(f"Retry report: {args.retry_queue}")
    print("Feature definitions:")
    print("  avg_competitor_rating_1km = mean of valid 1.0-5.0 ratings for unique, located competitors within 1 km.")
    print("  avg_competitor_review_count_1km = mean of exact, available review counts for unique, located competitors within 1 km.")
    print("  rated_competitor_count_1km = number of unique, located competitors within 1 km with a valid rating.")
    print("Failed/blocked jobs remain blank, not zero. Review rating and review count are averaged independently.")
    print("Price means use explicit RM values or bounded RM-range midpoints; symbols are never converted to RM.")
    print("No usable price: average stays blank and priced count is zero. See category_audit and feature_definitions.")
    return 0 if failed_jobs == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
