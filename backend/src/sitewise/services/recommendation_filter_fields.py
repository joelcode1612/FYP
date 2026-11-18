"""Advanced recommendation filters backed by measurements that exist.

Only fields with real, documented values in the deployed analytics database
are exposed here. A missing measurement stays ``None`` — it is NEVER coerced
to zero, and a filter selection never matches a property whose measurement
is absent.

All values for a result set are read in ONE query (``DISTINCT ON`` picks the
latest U-class analysis row per catalogue property), so a facet or a page
never triggers per-card geospatial lookups.
"""

from __future__ import annotations

from typing import Any, Iterable

from sqlalchemy import text
from sqlmodel import Session

#: field key -> (customer-facing label, kind, group, source description)
FIELDS: dict[str, tuple[str, str, str, str]] = {
    "floor_level": (
        "Floor level",
        "value",
        "property",
        "Research record of the unit's floor level where one was supplied.",
    ),
    "transit_walk_m": (
        "Public transport access",
        "max",
        "geospatial",
        "Walking distance to the nearest mapped public transport stop (metres).",
    ),
    "nearby_parking_500m": (
        "Nearby public parking",
        "min",
        "geospatial",
        "Count of mapped public parking facilities within 500 m. This is NOT "
        "on-site parking, which the research catalogue does not record.",
    ),
    "fnb_competition_500m": (
        "F&B competition",
        "max",
        "geospatial",
        "Count of other F&B outlets within a 500 m radius.",
    ),
    "demand_generator": (
        "Nearby demand generators",
        "choice",
        "geospatial",
        "Presence of mapped offices, universities or shopping malls within "
        "the stated radius.",
    ),
    "surrounding_population_1000m": (
        "Surrounding population",
        "range",
        "geospatial",
        "WorldPop 2025 resident population within 1 km. Only properties with "
        "a documented measurement are counted; a low-coverage buffer is a "
        "lower bound, not an exact figure.",
    ),
}

#: Demand-generator choices are presence tests over real POI counts.
DEMAND_OPTIONS: dict[str, str] = {
    "malls_1000m": "Shopping malls within 1 km",
    "offices_500m": "Offices within 500 m",
    "universities_500m": "Universities / colleges within 500 m",
}

_ADVANCED_SQL = text("""
SELECT DISTINCT ON (f.canonical_property_id)
       f.canonical_property_id,
       f.nearest_transit_walk_m,
       f.parking_facilities_500m,
       f.competitor_count_500m,
       f.other_features
FROM sitewise_analytics.subject_features AS f
WHERE btrim(f.sample_class) = 'U'
  AND f.canonical_property_id = ANY(:ids)
ORDER BY f.canonical_property_id, f.imported_at DESC NULLS LAST
""")


_ALL_SQL = text("""
SELECT DISTINCT ON (f.canonical_property_id)
       f.canonical_property_id,
       f.nearest_transit_walk_m,
       f.parking_facilities_500m,
       f.competitor_count_500m,
       f.other_features
FROM sitewise_analytics.subject_features AS f
WHERE btrim(f.sample_class) = 'U'
ORDER BY f.canonical_property_id, f.imported_at DESC NULLS LAST
""")


def _number(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        result = float(value)
    else:
        try:
            result = float(str(value).strip())
        except (TypeError, ValueError):
            return None
    return result if result >= 0 else None


def _text(data: dict, *keys: str) -> str | None:
    for key in keys:
        value = data.get(key)
        if value is None or isinstance(value, bool):
            continue
        result = str(value).strip()
        if result and result.lower() not in {"null", "nan", "n/a", "unknown", "not provided"}:
            return result
    return None


def _build(rows: Iterable[Any]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for row in rows:
        extra = row["other_features"] if isinstance(row["other_features"], dict) else {}
        demand: dict[str, bool] = {}
        for key in DEMAND_OPTIONS:
            count = _number(extra.get(key))
            # A genuine zero is measured and therefore NOT a nearby generator.
            demand[key] = count is not None and count > 0
        population = extra.get("worldpop_property_2025")
        result[str(row["canonical_property_id"])] = {
            "floor_level": _text(extra, "property_floor_level", "floor_level"),
            "transit_walk_m": _number(row["nearest_transit_walk_m"]),
            "nearby_parking_500m": _number(row["parking_facilities_500m"]),
            "fnb_competition_500m": _number(row["competitor_count_500m"]),
            "demand": demand,
            "surrounding_population_1000m": (
                _number(population.get("pop_1000m"))
                if isinstance(population, dict)
                else None
            ),
        }
    return result


def load_advanced(ids: Iterable[str], session: Session) -> dict[str, dict[str, Any]]:
    """One batched read of the verified advanced values for catalogue ids."""
    wanted = [str(value) for value in dict.fromkeys(ids) if value]
    if not wanted:
        return {}
    rows = session.execute(_ADVANCED_SQL, {"ids": wanted}).mappings().all()
    return _build(rows)


def load_all(session: Session) -> dict[str, dict[str, Any]]:
    """All advanced values in ONE query — used by the cached facet read."""
    return _build(session.execute(_ALL_SQL).mappings().all())


def value_of(advanced: dict[str, Any], key: str) -> Any:
    """The comparable value of one advanced field for a single property."""
    if key == "demand_generator":
        return advanced.get("demand", {})
    return advanced.get(key)


def selected(criteria: Any, key: str) -> Any:
    """The entrepreneur's current selection for an advanced field."""
    return {
        "floor_level": getattr(criteria, "floor_level", None),
        "transit_walk_m": getattr(criteria, "transit_max_m", None),
        "nearby_parking_500m": getattr(criteria, "nearby_parking_min", None),
        "fnb_competition_500m": getattr(criteria, "fnb_competition_max", None),
        "demand_generator": getattr(criteria, "demand_generator", None),
        "surrounding_population_1000m": getattr(
            criteria, "population_min_1000m", None
        ),
    }.get(key)


def matches(
    advanced: dict[str, Any], criteria: Any, *, excluding: str | None = None
) -> bool:
    """Whether one row satisfies every advanced selection except ``excluding``."""
    for key in FIELDS:
        if key == excluding:
            continue
        want = selected(criteria, key)
        if want is None or (isinstance(want, str) and not want.strip()):
            continue
        value = value_of(advanced, key)
        if key == "demand_generator":
            if not isinstance(value, dict) or not value.get(str(want).strip(), False):
                return False
            continue
        # NULL is an unmeasured value, never zero: it cannot satisfy a range.
        if value is None:
            return False
        kind = FIELDS[key][1]
        if kind == "value":
            if str(value).strip() != str(want).strip():
                return False
            continue
        try:
            limit = float(want)
        except (TypeError, ValueError):
            return False
        if key == "surrounding_population_1000m":
            upper = getattr(criteria, "population_max_1000m", None)
            if value < limit or (upper is not None and value > float(upper)):
                return False
        elif kind == "max" and value > limit:
            return False
        elif kind == "min" and value < limit:
            return False
        elif kind == "value" and str(value).strip() != str(want).strip():
            return False
    return True
