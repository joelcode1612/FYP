"""Read-only access to the imported property catalogue and its analysed evidence.

The catalogue (``sitewise_app.properties``, 2,126 rows) and the geospatial
feature table (``sitewise_analytics.subject_features``) are populated by the
import/analysis pipeline, not by this API. Everything here is a SELECT against
those tables through the analytics session; nothing writes to them.

Evidence is returned as labelled metrics with an explicit per-metric status so
a genuine ``0`` (no bus stops mapped within the walk buffer) is never rendered
as "no data", and a NULL (the district income join did not match) is never
rendered as ``0``.
"""

from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

# Exact column order consumed by lib/data/api_property_repository.dart.
PROPERTY_COLUMNS = (
    "id",
    "title",
    "address",
    "city",
    "state",
    "postcode",
    "rental_rm",
    "size_sqft",
    "latitude",
    "longitude",
    "property_type",
    "image_url",
    "source_url",
    "suitability_score",
    "dataset_validation",
)

_PROPERTY_SELECT = ", ".join(f"p.{c}" for c in PROPERTY_COLUMNS)

# Curated allow-list of the ~140 jsonb keys. Only fields with a documented
# meaning in the analysis pipeline are surfaced; the rest stay server-side.
_JSON_METRICS: tuple[tuple[str, str, str, str, str], ...] = (
    # (jsonb key, group, metric key, label, unit)
    (
        "fnb_competitors_2000m",
        "competition",
        "fnb_competitors_2000m",
        "F&B competitors within 2 km",
        "count",
    ),
    (
        "weekday_departures_500m_walk_am",
        "accessibility",
        "weekday_departures_am",
        "Weekday AM departures within a 500 m walk",
        "departures",
    ),
    (
        "weekday_departures_500m_walk_pm",
        "accessibility",
        "weekday_departures_pm",
        "Weekday PM departures within a 500 m walk",
        "departures",
    ),
    (
        "walk_isochrone_area_10min_km2",
        "accessibility",
        "walk_isochrone_10min",
        "Area reachable on foot in 10 minutes",
        "km²",
    ),
    (
        "drive_isochrone_area_10min_km2",
        "accessibility",
        "drive_isochrone_10min",
        "Area reachable by car in 10 minutes",
        "km²",
    ),
    ("office_pois_500m", "demand", "office_pois_500m", "Offices within 500 m", "count"),
    ("office_pois_1000m", "demand", "office_pois_1000m", "Offices within 1 km", "count"),
    ("retail_pois_1000m", "demand", "retail_pois_1000m", "Retail outlets within 1 km", "count"),
    ("schools_count_1000m", "demand", "schools_1000m", "Schools within 1 km", "count"),
    (
        "universities_colleges_count_1000m",
        "demand",
        "universities_1000m",
        "Universities and colleges within 1 km",
        "count",
    ),
    ("malls_count_1000m", "demand", "malls_1000m", "Malls within 1 km", "count"),
    (
        "supermarkets_count_1000m",
        "demand",
        "supermarkets_1000m",
        "Supermarkets within 1 km",
        "count",
    ),
    ("hospitals_count_1000m", "demand", "hospitals_1000m", "Hospitals within 1 km", "count"),
)

_GROUP_LABELS = {
    "competition": "Competitor pressure",
    "accessibility": "Accessibility and movement",
    "demand": "Catchment demand",
    "built_environment": "Built environment and parking",
}

# Column-backed metrics: (column, group, label, unit).
_COLUMN_METRICS: tuple[tuple[str, str, str, str], ...] = (
    ("competitor_count_500m", "competition", "F&B competitors within 500 m", "count"),
    ("competitor_count_1000m", "competition", "F&B competitors within 1 km", "count"),
    ("nearest_competitor_distance_m", "competition", "Distance to the nearest competitor", "m"),
    ("cafe_count_500m", "competition", "Cafes within 500 m", "count"),
    ("restaurant_count_500m", "competition", "Restaurants within 500 m", "count"),
    ("fast_food_count_500m", "competition", "Fast food within 500 m", "count"),
    ("bus_stops_500m_walk", "accessibility", "Bus stops within a 500 m walk", "count"),
    ("rail_stations_1km_walk", "accessibility", "Rail stations within a 1 km walk", "count"),
    ("nearest_transit_walk_m", "accessibility", "Walk to the nearest transit stop", "m"),
    ("nearest_major_road_m", "accessibility", "Distance to the nearest major road", "m"),
    (
        "road_length_density_500m_km_km2",
        "accessibility",
        "Road length density within 500 m",
        "km/km²",
    ),
    ("district_income_median_myr", "demand", "Median district household income", "RM/month"),
    ("building_count_500m", "built_environment", "Buildings within 500 m", "count"),
    (
        "building_footprint_density_500m",
        "built_environment",
        "Building footprint density within 500 m",
        "ratio",
    ),
    ("parking_facilities_500m", "built_environment", "Parking facilities within 500 m", "count"),
    (
        "nearest_parking_distance_m",
        "built_environment",
        "Distance to the nearest parking facility",
        "m",
    ),
)

_EVIDENCE_SELECT = ", ".join(f"f.{c}" for c, *_ in _COLUMN_METRICS) + (
    ", f.analysis_status, f.reference_coverage, f.feature_snapshot_at,"
    " f.inventory_snapshot_at, f.parking_status, f.self_exclusion_status,"
    " f.other_features"
)

_POPULATION_SQL = """
SELECT population_persons, date
FROM public.district_population
WHERE state = :state AND district = :district
ORDER BY date DESC
LIMIT 1
"""


def _json_safe(value: Any) -> Any:
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    return value


def _number(value: Any) -> float | int | None:
    """Numeric jsonb/column value, or None when it is genuinely absent.

    Non-numeric placeholders (``"NA"``, ``""``) are treated as absent rather
    than coerced to zero.
    """
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float, Decimal)):
        return _json_safe(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def _metric(key: str, label: str, unit: str, value: Any, note: str | None = None) -> dict:
    number = _number(value)
    return {
        "key": key,
        "label": label,
        "unit": unit,
        "value": number,
        # The distinction the workspace must never collapse: a mapped zero is
        # evidence, a NULL is missing evidence.
        "status": "available" if number is not None else "unavailable",
        "note": note,
    }


class CatalogRepository:
    def __init__(self, session: Session):
        self.session = session

    def get_property(self, property_id: str) -> dict | None:
        row = (
            self.session.execute(
                text(f"SELECT {_PROPERTY_SELECT} FROM sitewise_app.properties p WHERE p.id = :pid"),
                {"pid": property_id},
            )
            .mappings()
            .first()
        )
        return {k: _json_safe(v) for k, v in row.items()} if row else None

    def get_properties(self, property_ids: list[str]) -> dict[str, dict]:
        """Bulk lookup used to decorate assessment history rows."""
        if not property_ids:
            return {}
        rows = (
            self.session.execute(
                text(
                    f"SELECT {_PROPERTY_SELECT} FROM sitewise_app.properties p "
                    "WHERE p.id = ANY(:ids)"
                ),
                {"ids": list(dict.fromkeys(property_ids))},
            )
            .mappings()
            .all()
        )
        return {row["id"]: {k: _json_safe(v) for k, v in row.items()} for row in rows}

    def get_property_types(self) -> list[dict]:
        """Distinct catalogue ``property_type`` values with listing counts.

        The web eligibility filter compares ``BusinessPreferences.propertyType``
        against this column verbatim, so the options offered to the user have to
        come from the data. A hand-written list drifts silently: an option that
        matches no row filters every listing out while looking functional.
        """
        rows = (
            self.session.execute(
                text(
                    "SELECT property_type AS value, count(*) AS total "
                    "FROM sitewise_app.properties "
                    "WHERE property_type IS NOT NULL AND property_type <> '' "
                    "GROUP BY property_type "
                    "ORDER BY total DESC, property_type"
                )
            )
            .mappings()
            .all()
        )
        return [{"value": row["value"], "total": int(row["total"])} for row in rows]

    def get_evidence(self, property_id: str) -> dict:
        """Analysed location evidence for one property.

        Returns ``available: False`` with a reason when the analysis pipeline
        has no row for the property - never an empty-but-successful payload
        that a client could mistake for "everything measured zero".
        """
        row = (
            self.session.execute(
                text(
                    f"SELECT {_EVIDENCE_SELECT} "
                    "FROM sitewise_analytics.subject_features f "
                    "WHERE f.canonical_property_id = :pid "
                    "ORDER BY f.imported_at DESC NULLS LAST LIMIT 1"
                ),
                {"pid": property_id},
            )
            .mappings()
            .first()
        )

        if row is None:
            return {
                "property_id": property_id,
                "available": False,
                "reason": (
                    "No analysed location evidence exists for this property. "
                    "The geospatial analysis pipeline has not produced a "
                    "feature row for it, so competitor, accessibility and "
                    "catchment figures cannot be shown."
                ),
                "groups": [],
            }

        extra = row["other_features"] or {}
        if not isinstance(extra, dict):
            extra = {}

        groups: dict[str, list[dict]] = {key: [] for key in _GROUP_LABELS}
        for column, group, label, unit in _COLUMN_METRICS:
            note = None
            if column == "nearest_competitor_distance_m":
                name = extra.get("nearest_competitor_name")
                category = extra.get("nearest_competitor_category")
                note = " · ".join(str(x) for x in (name, category) if x) or None
            elif column == "parking_facilities_500m":
                note = _coverage_note(extra.get("parking_status") or row["parking_status"])
            elif column == "district_income_median_myr":
                note = _coverage_note(extra.get("district_income_join_status"))
            groups[group].append(_metric(column, label, unit, row[column], note))

        for json_key, group, key, label, unit in _JSON_METRICS:
            groups[group].append(_metric(key, label, unit, extra.get(json_key)))

        population = self._district_population(extra)
        groups["demand"].insert(0, population)

        completeness = _number(extra.get("data_completeness_pct"))
        return {
            "property_id": property_id,
            "available": True,
            "analysis_status": row["analysis_status"],
            "reference_coverage": row["reference_coverage"],
            "feature_snapshot_at": _json_safe(row["feature_snapshot_at"]),
            "inventory_snapshot_at": _json_safe(row["inventory_snapshot_at"]),
            "data_completeness_pct": completeness,
            "self_exclusion_status": row["self_exclusion_status"],
            "district": extra.get("district"),
            "state_dosm": extra.get("state_dosm"),
            "coordinate_quality": extra.get("coordinate_quality"),
            "join_status": {
                "property": extra.get("property_join_status"),
                "demand": extra.get("demand_join_status"),
                "accessibility": extra.get("accessibility_join_status"),
                "district_income": extra.get("district_income_join_status"),
            },
            "groups": [
                {"key": key, "label": label, "metrics": metrics}
                for key, label in _GROUP_LABELS.items()
                for metrics in (groups[key],)
                if metrics
            ],
        }

    def _district_population(self, extra: dict) -> dict:
        """Latest DOSM district population, joined on the normalised names.

        ``properties.state`` uses colloquial names ("Penang") while the DOSM
        table uses the normalised ones ("Pulau Pinang"), so the join keys come
        from the analysis row's ``state_dosm``/``district`` - not the listing.
        """
        label = "District population (DOSM)"
        state = extra.get("state_dosm")
        district = extra.get("district")
        if not state or not district:
            return _metric(
                "district_population",
                label,
                "persons",
                None,
                "The analysis row has no resolved district, so no population join was possible.",
            )
        row = (
            self.session.execute(text(_POPULATION_SQL), {"state": state, "district": district})
            .mappings()
            .first()
        )
        if row is None:
            return _metric(
                "district_population",
                label,
                "persons",
                None,
                f"No DOSM population record for {district}, {state}.",
            )
        return _metric(
            "district_population",
            label,
            "persons",
            row["population_persons"],
            f"{district}, {state} · DOSM estimate for {_json_safe(row['date'])}",
        )


def _coverage_note(status: Any) -> str | None:
    if not status:
        return None
    text_value = str(status)
    known = {
        "PARTIAL_COVERAGE": "Partial coverage: the open-data inventory is incomplete here.",
        "NO_MAPPED_FACILITIES": "No facilities mapped in the reference inventory.",
        "UNMATCHED_OR_UNKNOWN": "The district join did not match; value unavailable.",
        "MATCHED": None,
    }
    return known.get(text_value, text_value.replace("_", " ").title())
