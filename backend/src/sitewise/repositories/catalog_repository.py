"""Read-only access to the imported property catalogue and its analysed evidence.

The catalogue (the ``fyp.catalogue_properties`` view over the canonical
``fyp.rental_properties`` rows, 955 research rows) and the geospatial
feature table (``sitewise_analytics.subject_features``, 1,849 rows) are
populated by the import/analysis pipeline, not by this API. Everything here is
a SELECT against those tables through the analytics session; nothing writes to
them.

``suitability_score`` is the workbook's uncalibrated P-versus-U association
score rescaled to 0-100. It is a relative ranking input, never a calibrated
probability of business success; the raw value and its ``score_type`` stay in
``source_data``.

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
SELECT population_persons, male_persons, female_persons, date
FROM public.district_population
WHERE state = :state AND district = :district
ORDER BY date DESC
LIMIT 1
"""

#: Every (state, district) pair the DOSM district datasets actually publish.
#: The district name is the only key that survives the three spellings in the
#: study (population, age bands and household income), so all lookups of a
#: district go through this domain.
_DOSM_DISTRICTS = """
    (SELECT state, district FROM public.district_population
     UNION SELECT state, district FROM public.district_age_population
     UNION SELECT state, district FROM public.hh_income_district)
"""

#: A district name resolves only when the domain holds it for exactly one
#: state; the count makes that an established fact rather than an assumption
#: about Malaysian district names, which are unique today.
_DISTRICT_NAME_SQL = f"""
SELECT count(DISTINCT state) AS states, min(state) AS state
FROM {_DOSM_DISTRICTS} dosm_districts
WHERE dosm_districts.district = :district
"""

_DISTRICT_PAIR_SQL = f"""
SELECT 1 AS found
FROM {_DOSM_DISTRICTS} dosm_districts
WHERE dosm_districts.state = :state AND dosm_districts.district = :district
LIMIT 1
"""

# DOSM publishes district ages as five-year bands. The six displayed groups
# are a lossless aggregation of exactly those bands - no redistribution,
# no interpolation. Keys mirror open.dosm.gov.my population_district.
_AGE_GROUPS: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    ("0-14", "0–14 years", ("0-4", "5-9", "10-14")),
    ("15-24", "15–24 years", ("15-19", "20-24")),
    ("25-34", "25–34 years", ("25-29", "30-34")),
    ("35-49", "35–49 years", ("35-39", "40-44", "45-49")),
    ("50-64", "50–64 years", ("50-54", "55-59", "60-64")),
    ("65+", "65+ years", ("65-69", "70-74", "75-79", "80-84", "85+")),
)

#: The table holds the ``sex=both``, ``ethnicity=overall`` series of the
#: official ``population_district`` dataset only, so one row per band per date:
#: there is no male/female/both or ethnicity subtotal here to double-count.
_AGE_ROWS_SQL = """
SELECT age, population_persons, date
FROM public.district_age_population
WHERE state = :state
  AND district = :district
  AND date = (
    SELECT max(date) FROM public.district_age_population
    WHERE state = :state AND district = :district
  )
"""

_INCOME_SQL = """
SELECT income_median, date
FROM public.hh_income_district
WHERE state = :state AND district = :district
ORDER BY date DESC
LIMIT 1
"""

#: The property's district as the population pipeline established it: a
#: point-in-polygon assignment against ``public.malaysia_admin_hierarchy``
#: (GADM level 2, smallest containing area) written as DOSM's own district
#: name and flagged with the match status. Only a ``MATCHED`` row is trusted.
#:
#: Why not the analysis row's labels: ``other_features.district`` and
#: ``state_dosm`` are copied out of the source workbook, and for 458 of the 955
#: catalogued properties the label is not a DOSM district key at all - the
#: federal territory is labelled "Kuala Lumpur" while DOSM publishes it as the
#: district "W.P. Kuala Lumpur", "Johor Baharu" stands for "Johor Bahru",
#: "Hulu Langat" for "Ulu Langat", and some rows carry a state that disagrees
#: with their own district. Joining the demographics on those labels matched no
#: row, which is what made the district panel read "District data not
#: available" for Kuala Lumpur listings. Nothing here matches on substrings: an
#: unlisted district stays unresolved.
_VERIFIED_DISTRICT_SQL = """
SELECT p.dosm_district_key
FROM fyp_features.property_population_spatial p
WHERE p.source_record_type = 'SITEWISE_U_PROPERTY'
  AND p.source_record_id = :pid
  AND p.geography_match_status = 'MATCHED'
  AND p.dosm_district_key IS NOT NULL
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


def _district_caption(state: Any, district: Any) -> str:
    """"Petaling, Selangor" - or one name when the district IS the federal
    territory, which DOSM publishes under the same label twice."""
    return ", ".join(dict.fromkeys(part for part in (district, state) if part))


def _persons(value: Any) -> int | None:
    """A headcount as whole people, or None when the source has no figure.

    DOSM publishes district population in thousands; the analytics import
    already stores whole persons, so this only pins the type the client sees.
    A zero is a measured zero and stays zero.
    """
    number = _number(value)
    return None if number is None else int(round(number))


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
                text(f"SELECT {_PROPERTY_SELECT} FROM fyp.catalogue_properties p WHERE p.id = :pid"),
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
                    f"SELECT {_PROPERTY_SELECT} FROM fyp.catalogue_properties p "
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
                    "FROM fyp.catalogue_properties "
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

        # Nearby-resident estimates (WorldPop) live inside the stored
        # provenance block, not at the jsonb top level. They are a real
        # measurement with a documented source, so they are surfaced with that
        # source note; a property without the block stays "unavailable".
        pop_block = extra.get("landscan_property_2024_licence_pending")
        if isinstance(pop_block, dict):
            for radius_m, key, label in (
                (500, "pop_500m", "Estimated residents within 500 m"),
                (1000, "pop_1000m", "Estimated residents within 1 km"),
            ):
                coverage = _number(pop_block.get(f"worldpop_coverage_{radius_m}m_pct"))
                note = None
                if _number(pop_block.get(key)) is not None:
                    note = (
                        "WorldPop 2025 constrained 100 m estimate"
                        + (
                            f" · {coverage:.0f}% of the area covered"
                            if coverage is not None
                            else ""
                        )
                    )
                groups["demand"].append(
                    _metric(key, label, "people", pop_block.get(key), note)
                )

        dosm_keys = self._dosm_district_keys(property_id, extra)
        population = self._district_population(dosm_keys, extra)
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
            "district_statistics": self._district_statistics(dosm_keys, extra),
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

    def _dosm_district_keys(
        self, property_id: str, extra: dict
    ) -> tuple[str, str, str] | None:
        """DOSM ``(state, district, match_method)`` for this property.

        The verified point-in-polygon district wins. A property with no matched
        geometry row is joined on its analysis-row pair, and only when that
        exact pair is one DOSM publishes. ``None`` means the administrative
        district is not established: the caller then reports the section as
        unavailable instead of guessing at a district.
        """
        verified = self.session.execute(
            text(_VERIFIED_DISTRICT_SQL), {"pid": property_id}
        ).scalar()
        if verified:
            found = (
                self.session.execute(
                    text(_DISTRICT_NAME_SQL), {"district": str(verified)}
                )
                .mappings()
                .first()
            )
            if found and found["state"] is not None and int(found["states"]) == 1:
                return str(found["state"]), str(verified), "VERIFIED_DISTRICT_GEOMETRY"

        label_state = extra.get("state_dosm")
        label_district = extra.get("district")
        if label_state and label_district:
            found = (
                self.session.execute(
                    text(_DISTRICT_PAIR_SQL),
                    {"state": str(label_state), "district": str(label_district)},
                )
                .mappings()
                .first()
            )
            if found:
                return str(label_state), str(label_district), "EXACT_LABEL_PAIR"
        return None

    def _district_statistics(
        self, dosm_keys: tuple[str, str, str] | None, extra: dict
    ) -> dict:
        """Official DOSM district demographics for the property's district.

        Each block - the population with its sex split, the age bands, the
        household income - is resolved on its own terms, because the datasets
        do not cover the same districts or the same years: a district whose
        income is published while its age bands are not (W.P. Putrajaya)
        reports the figure DOSM actually holds instead of collapsing the whole
        section, and every value travels with its own reference year.

        The age distribution is a regrouping of the published five-year bands
        into the six displayed groups - a lossless relabelling of the source
        categories, never a redistribution into the 500 m / 1 km catchments. A
        band the source does not hold makes its group null rather than a
        smaller number, and shares are only computed when all six groups are
        present, so a partial import cannot be read as a distribution.
        """
        if dosm_keys is None:
            return {
                "available": False,
                "district": extra.get("district"),
                "state": extra.get("state_dosm"),
                "match_method": None,
                "age_groups": [],
                "total_population": 0,
                "reason": (
                    "This property has no matched administrative district, and "
                    "its recorded district label is not one the DOSM district "
                    "datasets publish, so no district demographics were joined."
                ),
            }

        state, district, method = dosm_keys
        params = {"state": state, "district": district}
        base = {
            "district": district,
            "state": state,
            "match_method": method,
            "labelled_district": extra.get("district"),
            "labelled_state": extra.get("state_dosm"),
        }

        age_rows = (
            self.session.execute(text(_AGE_ROWS_SQL), params).mappings().all()
        )
        population_row = (
            self.session.execute(text(_POPULATION_SQL), params).mappings().first()
        )
        income_row = (
            self.session.execute(text(_INCOME_SQL), params).mappings().first()
        )
        if not age_rows and population_row is None and income_row is None:
            return {
                **base,
                "available": False,
                "age_groups": [],
                "total_population": 0,
                "reason": (
                    f"The DOSM district datasets publish no population, age or "
                    f"income records for {_district_caption(state, district)}."
                ),
            }

        age_groups: list[dict] = []
        as_of: str | None = None
        if age_rows:
            by_band: dict[str, int] = {}
            for row in age_rows:
                if row["age"] is None or row["population_persons"] is None:
                    continue
                as_of = _json_safe(row["date"])
                by_band[str(row["age"])] = int(row["population_persons"])
            for key, label, bands in _AGE_GROUPS:
                present = [band for band in bands if band in by_band]
                persons = sum(by_band[band] for band in present) if present else None
                age_groups.append(
                    {
                        "key": key,
                        "label": label,
                        "persons": persons,
                        "bands_missing": [b for b in bands if b not in present],
                    }
                )
            complete = all(group["persons"] is not None for group in age_groups)
            total = sum(group["persons"] or 0 for group in age_groups)
            for group in age_groups:
                group["share"] = (
                    round(group["persons"] / total, 4)
                    if complete and total and group["persons"] is not None
                    else None
                )
            age_note = (
                None
                if complete
                else "Some five-year bands are missing from the DOSM import, so "
                "these groups are partial and no share is claimed."
            )
        else:
            total = 0
            age_note = (
                f"No DOSM district age bands are published for {_district_caption(state, district)}."
            )

        return {
            **base,
            "available": True,
            "age_as_of": as_of,
            "age_year": str(as_of)[:4] if as_of else None,
            "age_note": age_note,
            "age_groups_complete": bool(age_rows)
            and all(group["persons"] is not None for group in age_groups),
            "total_population": total,
            "age_groups": age_groups,
            "district_population": _persons(
                population_row["population_persons"] if population_row else None
            ),
            "male_population": _persons(
                population_row["male_persons"] if population_row else None
            ),
            "female_population": _persons(
                population_row["female_persons"] if population_row else None
            ),
            "population_as_of": (
                _json_safe(population_row["date"]) if population_row else None
            ),
            "population_note": (
                None
                if population_row is not None
                else f"No DOSM district population estimate is published for {_district_caption(state, district)}."
            ),
            "income_median_myr": (
                float(income_row["income_median"])
                if income_row is not None and income_row["income_median"] is not None
                else None
            ),
            "income_as_of": _json_safe(income_row["date"]) if income_row else None,
            "income_note": (
                None
                if income_row is not None and income_row["income_median"] is not None
                else f"No DOSM household-income estimate is published for {_district_caption(state, district)}."
            ),
            "reason": None,
        }

    def _district_population(
        self, dosm_keys: tuple[str, str, str] | None, extra: dict
    ) -> dict:
        """Latest DOSM district population, joined on the verified district.

        ``properties.state`` uses colloquial names ("Penang") and the analysis
        row's district label is often not a DOSM key, so neither label pair is
        trusted on its own - see ``_VERIFIED_DISTRICT_SQL``.
        """
        label = "District population (DOSM)"
        if dosm_keys is None:
            return _metric(
                "district_population",
                label,
                "persons",
                None,
                "No matched administrative district exists for this property, so no "
                "DOSM population join was possible.",
            )
        state, district, _method = dosm_keys
        row = (
            self.session.execute(
                text(_POPULATION_SQL), {"state": state, "district": district}
            )
            .mappings()
            .first()
        )
        if row is None:
            return _metric(
                "district_population",
                label,
                "persons",
                None,
                f"No DOSM population record for {_district_caption(state, district)}.",
            )
        return _metric(
            "district_population",
            label,
            "persons",
            row["population_persons"],
            f"{_district_caption(state, district)} · DOSM estimate for "
            f"{_json_safe(row['date'])}",
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
