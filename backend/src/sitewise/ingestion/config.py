"""Configuration for the bounded geospatial refresh pipeline.

Everything is environment-driven so the same code runs as a one-shot CLI, a
cron job, an APScheduler process or a Windows Scheduled Task. No credentials
are needed for the open-data sources; the Google Places/Address Validation
key (``google_maps_api_key``) stays a SEPARATE optional commercial source and
is never required for the primary pipeline to succeed.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default).strip()


def _env_int(name: str, default: int) -> int:
    try:
        return int(_env(name, str(default)))
    except ValueError:
        return default


def _env_float(name: str, default: float) -> float:
    try:
        return float(_env(name, str(default)))
    except ValueError:
        return default


def _env_bbox(name: str, default: str) -> tuple[float, float, float, float]:
    """Parse ``min_lon,min_lat,max_lon,max_lat``; fall back on malformed input."""
    try:
        parts = tuple(float(p) for p in _env(name, default).split(","))
        if len(parts) != 4:
            raise ValueError
        min_lon, min_lat, max_lon, max_lat = parts
        if not (-180 <= min_lon < max_lon <= 180 and -90 <= min_lat < max_lat <= 90):
            raise ValueError
        return (min_lon, min_lat, max_lon, max_lat)
    except ValueError:
        parts = tuple(float(p) for p in default.split(","))
        return (parts[0], parts[1], parts[2], parts[3])


#: OSM tags that map onto the research F&B scope. ``in_main_scope`` on existing
#: rows excludes unclassified venues; new rows keep the same vocabulary.
OSM_FNB_TAGS: dict[tuple[str, str], str] = {
    ("amenity", "restaurant"): "restaurant",
    ("amenity", "cafe"): "cafe",
    ("amenity", "fast_food"): "fast_food",
    ("amenity", "food_court"): "food_court",
    ("shop", "bakery"): "bakery_pastry",
    ("shop", "pastry"): "bakery_pastry",
    ("amenity", "bar"): "bar_pub",
    ("amenity", "pub"): "bar_pub",
    ("amenity", "ice_cream"): "ice_cream_dessert",
    ("shop", "ice_cream"): "ice_cream_dessert",
    ("amenity", "canteen"): "canteen",
}

#: Overture ``places`` category values (last path segment, lower-cased).
OVERTURE_FNB_CATEGORIES: dict[str, str] = {
    "restaurant": "restaurant",
    "restaurants": "restaurant",
    "cafe": "cafe",
    "coffee_shop": "cafe",
    "coffee": "cafe",
    "fast_food": "fast_food",
    "fast_food_restaurant": "fast_food",
    "food_court": "food_court",
    "bakery": "bakery_pastry",
    "pastry_shop": "bakery_pastry",
    "ice_cream_shop": "ice_cream_dessert",
    "bar": "bar_pub",
    "pub": "bar_pub",
    "bubble_tea": "beverage_tea_coffee",
    "tea_house": "beverage_tea_coffee",
}

#: Categories that count as competitors in the research contract. The two
#: extra categories below are retained for provenance but excluded from the
#: canonical ``in_main_scope`` competitor population unless the existing data
#: already classified them that way.
MAIN_SCOPE_CATEGORIES = frozenset({
    "restaurant", "cafe", "fast_food", "food_court", "bakery_pastry",
    "bar_pub", "ice_cream_dessert", "beverage_tea_coffee", "canteen",
})


@dataclass(frozen=True)
class RefreshConfig:
    # Study area — Peninsular Malaysia + Johor by default; override per run.
    bbox: tuple[float, float, float, float] = field(
        default_factory=lambda: _env_bbox(
            "SITEWISE_REFRESH_BBOX", "99.5,1.2,104.6,6.8"
        )
    )
    # Maximum radius (metres) used for affected-property detection. 1 km is
    # the largest research radius (500 m / 1 km features).
    influence_radius_m: int = field(
        default_factory=lambda: _env_int("SITEWISE_REFRESH_INFLUENCE_RADIUS_M", 1000)
    )
    # Dedup thresholds.
    dedup_distance_m: float = field(
        default_factory=lambda: _env_float("SITEWISE_DEDUP_DISTANCE_M", 35.0)
    )
    dedup_name_similarity: float = field(
        default_factory=lambda: _env_float("SITEWISE_DEDUP_NAME_SIMILARITY", 0.82)
    )
    ambiguous_similarity: float = field(
        default_factory=lambda: _env_float("SITEWISE_AMBIGUOUS_SIMILARITY", 0.60)
    )
    # Network / volume limits. The pipeline NEVER downloads a global dataset.
    overture_release_base: str = field(
        default_factory=lambda: _env(
            "SITEWISE_OVERTURE_RELEASE_BASE",
            "https://overturemaps-us-west-2.s3.amazonaws.com/release/",
        )
    )
    overture_release: str = field(
        default_factory=lambda: _env("SITEWISE_OVERTURE_RELEASE", "")
    )
    osm_extract_url: str = field(
        default_factory=lambda: _env(
            "SITEWISE_OSM_EXTRACT_URL",
            "https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf",
        )
    )
    overpass_url: str = field(
        default_factory=lambda: _env(
            "SITEWISE_OVERPASS_URL", "https://overpass-api.de/api/interpreter"
        )
    )
    request_timeout_s: int = field(
        default_factory=lambda: _env_int("SITEWISE_REFRESH_TIMEOUT_S", 20)
    )
    max_download_mb: int = field(
        default_factory=lambda: _env_int("SITEWISE_MAX_DOWNLOAD_MB", 256)
    )
    max_records_per_source: int = field(
        default_factory=lambda: _env_int("SITEWISE_MAX_RECORDS_PER_SOURCE", 100_000)
    )
    # Overture place data ships as a fixed number of parquet parts; reading a
    # bounded subset keeps a refresh small while row-group bbox pruning skips
    # non-overlapping data inside each part.
    max_overture_parts: int = field(
        default_factory=lambda: _env_int("SITEWISE_MAX_OVERTURE_PARTS", 16)
    )
    # Fixtures / offline mode.
    fixture_dir: str = field(
        default_factory=lambda: _env("SITEWISE_REFRESH_FIXTURE_DIR", "")
    )
    offline: bool = field(
        default_factory=lambda: _env("SITEWISE_REFRESH_OFFLINE", "0") == "1"
    )
    overpass_enabled: bool = field(
        default_factory=lambda: _env("SITEWISE_OVERPASS_ENABLED", "1") == "1"
    )
    # Feature calculation version — stored with each freshness row so a
    # contract change can be distinguished from stale data.
    calculation_version: str = field(
        default_factory=lambda: _env("SITEWISE_CALCULATION_VERSION", "geo-refresh-v1")
    )
    # Scheduler intervals (seconds). Defaults: weekly / weekly / monthly.
    source_check_interval_s: int = field(
        default_factory=lambda: _env_int("SITEWISE_SOURCE_CHECK_INTERVAL_S", 604800)
    )
    osm_refresh_interval_s: int = field(
        default_factory=lambda: _env_int("SITEWISE_OSM_REFRESH_INTERVAL_S", 604800)
    )
    roads_refresh_interval_s: int = field(
        default_factory=lambda: _env_int("SITEWISE_ROADS_REFRESH_INTERVAL_S", 2592000)
    )
    demographics_refresh_interval_s: int = field(
        default_factory=lambda: _env_int("SITEWISE_DEMOGRAPHICS_INTERVAL_S", 2592000)
    )
    batch_size: int = field(
        default_factory=lambda: _env_int("SITEWISE_REFRESH_BATCH_SIZE", 500)
    )
    # A lock key shared by every refresh process on this database.
    advisory_lock_key: int = field(
        default_factory=lambda: _env_int("SITEWISE_REFRESH_LOCK_KEY", 814220261)
    )

    @property
    def osm_terms(self) -> list[tuple[str, str]]:
        return list(OSM_FNB_TAGS)

    def contains(self, lat: float, lon: float) -> bool:
        min_lon, min_lat, max_lon, max_lat = self.bbox
        return min_lon <= lon <= max_lon and min_lat <= lat <= max_lat


OSM_LICENCE = "ODbL 1.0 (OpenStreetMap contributors)"
OVERTURE_LICENCE = "CDLA Permissive 2.0 / ODbL (Overture Maps Foundation)"
