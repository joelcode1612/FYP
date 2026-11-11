"""Normalization, category mapping and geographic validation.

All transformations are pure functions so the tests can exercise them without
a network or a database. Rejected rows are counted with an explicit reason —
a rejected row is never silently treated as a zero competitor count.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Any

from sitewise.ingestion.config import (
    MAIN_SCOPE_CATEGORIES,
    OSM_FNB_TAGS,
    OSM_LICENCE,
    OVERTURE_FNB_CATEGORIES,
    OVERTURE_LICENCE,
    RefreshConfig,
)
from sitewise.ingestion.records import SourceRecord

_SPACE = re.compile(r"\s+")
_PUNCT = re.compile(r"[^\w\s]", flags=re.UNICODE)

#: Business-type words that carry no identity signal for name matching.
_GENERIC_WORDS = frozenset({
    "restaurant", "cafe", "kedai", "makan", "food", "court", "store",
    "shop", "sdn", "bhd", "the", "and", "of", "restoran", "gerai",
})


def normalize_name(value: str | None) -> str:
    """Stable comparable name: NFKC, lower-case, punctuation-stripped."""
    if not value:
        return ""
    text = unicodedata.normalize("NFKC", value).lower()
    text = _PUNCT.sub(" ", text)
    return _SPACE.sub(" ", text).strip()


def name_tokens(value: str) -> frozenset[str]:
    return frozenset(t for t in value.split() if t and t not in _GENERIC_WORDS)


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle metres from WGS84 degrees (matching, never replacing,
    the authoritative PostGIS ``ST_DWithin(geography)`` contract)."""
    import math

    r = 6_371_008.8
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


def _text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _number(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def valid_coordinates(lat: Any, lon: Any, config: RefreshConfig) -> tuple[float, float] | None:
    """Return validated coordinates or None. Rejects NaN/inf/out-of-range
    and enforces the configured study-area bbox (never a global import)."""
    import math

    lat_f, lon_f = _number(lat), _number(lon)
    if lat_f is None or lon_f is None:
        return None
    if not (math.isfinite(lat_f) and math.isfinite(lon_f)):
        return None
    if not (-90 <= lat_f <= 90 and -180 <= lon_f <= 180):
        return None
    if not config.contains(lat_f, lon_f):
        return None
    return (lat_f, lon_f)


def valid_geometry(lat: float, lon: float) -> bool:
    """Point geometry validity via Shapely when available; otherwise the
    coordinate range check above is sufficient for a WGS84 point."""
    try:
        from shapely.geometry import Point

        return Point(lon, lat).is_valid and not Point(lon, lat).is_empty
    except ImportError:  # pragma: no cover - optional dependency
        return True


def osm_category(tags: dict[str, Any]) -> tuple[str, str] | None:
    """Return (canonical_category, raw_category) for a supported OSM tag set."""
    for (key, value), canonical in OSM_FNB_TAGS.items():
        if str(tags.get(key, "")).lower() == value:
            return (canonical, f"{key}={value}")
    return None


def overture_category(raw: str | None, categories: Any = None) -> tuple[str, str] | None:
    """Overture place categories are strings or a ``{primary, alternate}``
    object. Only the documented last path segment is matched."""
    primary = ""
    if isinstance(categories, dict):
        primary = str(categories.get("primary") or "")
    elif isinstance(categories, list) and categories:
        primary = str(categories[0])
    raw_text = primary or _text(raw) or ""
    segment = raw_text.rstrip("/").split("/")[-1].strip().lower().replace(" ", "_")
    canonical = OVERTURE_FNB_CATEGORIES.get(segment)
    return (canonical, raw_text) if canonical else None


def normalize_osm(
    raw: dict[str, Any],
    *,
    release: str,
    snapshot_at: str,
    config: RefreshConfig,
) -> tuple[SourceRecord | None, str | None]:
    """Normalize one OSM element (Overpass JSON ``element`` or GeoJSON feature).
    Provider ids, tags, version/timestamp and licence are preserved."""
    tags = raw.get("tags")
    if not isinstance(tags, dict):
        props = raw.get("properties")
        tags = props.get("tags", props) if isinstance(props, dict) else {}
    if isinstance(tags, str):
        import json

        try:
            tags = json.loads(tags)
        except ValueError:
            tags = {}
    category = osm_category(tags)
    if category is None:
        return None, "unsupported_category"

    lat = raw.get("lat")
    lon = raw.get("lon")
    geometry_type = str(raw.get("type") or "node")
    if lat is None or lon is None:
        center = raw.get("center") or {}
        lat, lon = center.get("lat"), center.get("lon")
    if lat is None or lon is None:
        geometry = raw.get("geometry") or {}
        coords = geometry.get("coordinates") if isinstance(geometry, dict) else None
        if isinstance(coords, list) and len(coords) >= 2:
            lon, lat = coords[0], coords[1]
            geometry_type = str(geometry.get("type") or "point")
    coords = valid_coordinates(lat, lon, config)
    if coords is None:
        return None, "invalid_or_out_of_study_area_coordinates"
    if not valid_geometry(*coords):
        return None, "invalid_geometry"

    raw_id = raw.get("id")
    if raw_id is None:
        return None, "missing_source_identifier"
    # Match the EXISTING fnb_a.fnb_outlet natural id vocabulary
    # (source_table 'point'/'polygon', e.g. 'point/12736533428') so a
    # refreshed OSM version updates the same row instead of duplicating it.
    source_table = "point" if geometry_type in {"node", "point"} else "polygon"
    source_id = f"{source_table}/{raw_id}"
    name = _text(tags.get("name")) or _text(tags.get("brand"))
    if not name:
        return None, "missing_business_name"

    addr_parts = [
        _text(tags.get("addr:housenumber")),
        _text(tags.get("addr:street")),
        _text(tags.get("addr:city")),
    ]
    address = ", ".join(p for p in addr_parts if p) or None
    status = _text(tags.get("opening_hours"))
    operating = None
    if str(tags.get("amenity", "")).lower() in {"closed", "vacant"} or tags.get("disused") or status and status.lower() in {"closed", "off"}:
        operating = "closed"
    elif status:
        operating = "open"

    return (
        SourceRecord(
            source_name="openstreetmap",
            source_record_id=source_id,
            source_release=release,
            source_snapshot_at=snapshot_at,
            source_licence=OSM_LICENCE,
            name=name,
            normalized_name=normalize_name(name),
            category=category[0],
            category_raw=category[1],
            latitude=coords[0],
            longitude=coords[1],
            operating_status=operating,
            address=address,
            postcode=_text(tags.get("addr:postcode")),
            city=_text(tags.get("addr:city")),
            phone=_text(tags.get("phone")),
            website=_text(tags.get("website")),
            source_updated_at=_text(raw.get("timestamp")),
            source_version=int(raw["version"]) if str(raw.get("version", "")).isdigit() else None,
            source_tags={str(k): str(v) for k, v in tags.items()},
            explicit_cross_refs=tuple(
                ref for ref in (
                    _text(tags.get("ref:overture")),
                    _text(tags.get("overture:id")),
                    _text(tags.get("ref:google")),
                ) if ref
            ),
            geometry_type=source_table,
        ),
        None,
    )


def normalize_overture(
    raw: dict[str, Any],
    *,
    release: str,
    snapshot_at: str,
    config: RefreshConfig,
) -> tuple[SourceRecord | None, str | None]:
    """Normalize one Overture ``theme=places/type=place`` row."""
    # The current Overture places schema exposes ``taxonomy.primary`` (or a
    # flattened ``taxonomy_primary``) plus ``basic_category``; older fixtures
    # used a ``categories`` object. All three shapes are accepted.
    category = overture_category(
        raw.get("category")
        or raw.get("taxonomy_primary")
        or raw.get("basic_category"),
        raw.get("categories") if "categories" in raw else None,
    )
    if category is None:
        return None, "unsupported_category"
    coords = valid_coordinates(raw.get("latitude"), raw.get("longitude"), config)
    if coords is None:
        # GeoParquet rows carry Overture's ``bbox`` struct instead of scalar
        # coordinates; the centroid is the representative point.
        bbox = raw.get("bbox") or {}
        if isinstance(bbox, dict):
            # Overture GeoParquet uses xmin/xmax/ymin/ymax; fixture authors
            # often write minx/maxx/miny/maxy. Both are accepted.
            def _edge(*names):
                for name in names:
                    if bbox.get(name) is not None:
                        return float(bbox[name])
                return None

            xmin, xmax = _edge("xmin", "minx"), _edge("xmax", "maxx")
            ymin, ymax = _edge("ymin", "miny"), _edge("ymax", "maxy")
            if None not in (xmin, xmax, ymin, ymax):
                coords = valid_coordinates(
                    (ymin + ymax) / 2.0, (xmin + xmax) / 2.0, config
                )
    if coords is None:
        geo = raw.get("geometry") or {}
        # Overture GeoParquet ships WKB geometry; sources that expose GeoJSON
        # features directly are also accepted.
        gcoords = geo.get("coordinates") if isinstance(geo, dict) else None
        if isinstance(gcoords, list) and len(gcoords) >= 2 and isinstance(gcoords[0], (int, float)):
            coords = valid_coordinates(gcoords[1], gcoords[0], config)
    if coords is None:
        return None, "invalid_or_out_of_study_area_coordinates"
    if not valid_geometry(*coords):
        return None, "invalid_geometry"

    raw_id = _text(raw.get("id")) or _text(raw.get("overture_id"))
    if raw_id is None:
        return None, "missing_source_identifier"
    names = raw.get("names") if isinstance(raw.get("names"), dict) else {}
    name = _text(raw.get("name")) or _text(names.get("primary"))
    if not name:
        return None, "missing_business_name"
    addresses = raw.get("addresses") if isinstance(raw.get("addresses"), list) else []
    address = None
    if addresses and isinstance(addresses[0], dict):
        a = addresses[0]
        address = ", ".join(
            p for p in (
                _text(a.get("freeform")),
                _text(a.get("locality")),
                _text(a.get("region")),
                _text(a.get("postcode")),
            ) if p
        ) or None
    status = _text(raw.get("operating_status"))
    # NULL/unknown operating status must stay UNKNOWN — never "open".
    operating = {"open": "open", "closed": "closed", "permanently_closed": "closed"}.get(
        (status or "").lower()
    )
    return (
        SourceRecord(
            source_name="overture",
            source_record_id=f"overture/{raw_id}",
            source_release=release,
            source_snapshot_at=snapshot_at,
            source_licence=OVERTURE_LICENCE,
            name=name,
            normalized_name=normalize_name(name),
            category=category[0],
            category_raw=category[1],
            latitude=coords[0],
            longitude=coords[1],
            operating_status=operating,
            address=_text(raw.get("address")) or address,
            postcode=_text(raw.get("postcode")),
            city=_text(raw.get("city")),
            phone=_text(raw.get("phone")),
            website=_text(raw.get("website")),
            source_updated_at=_text(raw.get("update_time")) or _text(raw.get("version")),
            source_tags={str(k): str(v)[:200] for k, v in raw.items()
                         if k in {"confidence", "categories", "brand", "sources"}},
            explicit_cross_refs=tuple(
                str(v) for v in (raw.get("osm_id"), raw.get("source_osm_id")) if v
            ),
        ),
        None,
    )


def in_main_scope(category: str) -> bool:
    return category in MAIN_SCOPE_CATEGORIES
