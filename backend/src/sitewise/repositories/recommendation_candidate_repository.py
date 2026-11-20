"""Read-only candidate source for the personalised recommendation engine.

Verified field mappings (research workbook name -> production column)
====================================================================

============================  ==================================================
Canonical field               Source
============================  ==================================================
canonical_property_id         ``fyp.catalogue_properties.id`` (TEXT, EP-/MD- ids;
                              canonical column ``fyp.rental_properties.catalogue_id``)
property_type                 ``fyp.catalogue_properties.property_type``
monthly_rental_myr            ``fyp.catalogue_properties.rental_rm``  (NOT price)
built_up_sqft                 ``fyp.catalogue_properties.size_sqft``
state / district              ``p.state`` / ``p.source_data->>'district'``
floor_level_text,             NOT typed columns. Present for a SUBSET of rows
unit_position, frontage_ft,   in ``subject_features.other_features`` under the
depth_ft                      ``property_*`` keys. Mapped only when recorded;
                              absent values stay ``None`` (unknown), never 0.
population (500 m / 1 km)     ``fyp_features.property_population_spatial``
F&B competitors               ``p.source_data->>'fnb_competitors_500m/1000m'``
demand generators             ``sitewise_analytics.subject_features.other_features``
transit / walkability         ``...other_features`` + typed subject columns
parking                       ``...other_features`` + ``parking_status``
PU association score          ``p.source_data->>'research_p_association_score'``
============================  ==================================================

Two deliberate data-integrity decisions:

* ``fyp_features.property_population_spatial`` holds TWO rows per catalogue id
  (``SITEWISE_U_PROPERTY`` and ``PROPERTY_UNLABELED``). A deterministic LATERAL
  resolves exactly one. ``SITEWISE_U_PROPERTY`` is preferred because it is
  byte-identical to the PU model's training record for U-class properties
  (verified against the supplied ``example_property_47.json`` for MD-00510);
  the previous alphabetical ``ORDER BY source_record_type`` picked the
  ``PROPERTY_UNLABELED`` twin, which differs in the 4th significant digit.
* Only the published **research catalogue** (the ``fyp.catalogue_properties``
  view, 955 U-class rows) is read here. Those rows are the SAME canonical
  ``fyp.rental_properties`` records with ``is_published = false`` and are
  deliberately NOT mixed into the owner-listing flows: the approved+published
  verification policy for entrepreneur-facing listings is untouched.
  ``UNKNOWN_NOT_VERIFIED`` availability is surfaced as a caution and
  never as confirmed availability.

Layer 1 provenance
------------------
``research_p_association_score`` is the ORIGINAL PU model's stored output for
these exact 47-feature baseline vectors (verified byte-for-byte against live
``pu_model`` inference for MD-00510). It is a real research prediction, not a
demonstration value. Live inference for arbitrary catalogue ids is impossible
from the current database because 8 of the 47 saved features (population rings,
LandScan ambient population, WorldPop walk-reachable) are not stored as
columns; the existing ``/ml/...`` endpoints remain the live-inference path and
fail closed when features cannot be resolved. No score is fabricated here.
"""
from __future__ import annotations

import math
from collections.abc import Mapping
from typing import Any

from sqlalchemy import bindparam, text
from sqlmodel import Session

#: Availability values that must never enter a recommendation.
_EXPLICITLY_UNAVAILABLE = (
    "UNAVAILABLE", "NOT_AVAILABLE", "RENTED", "LET", "TAKEN", "CLOSED",
    "WITHDRAWN", "EXPIRED", "SOLD",
)

#: Search-time eligibility (Recommendations). Compare deliberately resolves
#: WITHOUT these pre-filters: a shortlisted id that later became unavailable
#: must be reported with its recorded status, never silently dropped.
_ELIGIBILITY_SQL = """p.rental_rm IS NOT NULL AND p.rental_rm > 0
  AND p.size_sqft IS NOT NULL AND p.size_sqft > 0
  AND coalesce(p.source_data->>'property_availability_status', 'UNKNOWN_NOT_VERIFIED')
      NOT IN :unavailable"""

#: Operational commercial properties (fyp.rental_properties) resolved by
#: numeric id for Compare. The verified catalogue link (match_verified) is the
#: authoritative catalogue-to-operational mapping; the import-time
#: ``catalogue_id`` column is the recorded fallback. Geospatial measurements
#: ride the linked catalogue subject so BOTH id universes share one contract.
_OPERATIONAL_SELECT = """
SELECT
    rp.id::text                  AS property_id,
    rp.name                      AS title,
    coalesce(rp.address_formatted, rp.address) AS address,
    rp.city                      AS city,
    rp.state                     AS state,
    rp.postcode                  AS postcode,
    rp.property_type             AS property_type,
    rp.rental_price              AS monthly_rental_myr,
    rp.size_sqft                 AS built_up_sqft,
    rp.latitude                  AS latitude,
    rp.longitude                 AS longitude,
    rp.catalogue_image_url       AS image_url,
    rp.catalogue_source_data     AS source_data,
    coalesce(lk.sitewise_property_id, rp.catalogue_id) AS catalogue_ref,
    rp.availability              AS operational_availability,
    rp.floor_level               AS operational_floor_level,
    rp.has_parking               AS operational_has_parking,
    rp.unit_position             AS operational_unit_position,
    to_jsonb(sf)                 AS subject_doc,
    to_jsonb(pop)                AS population_doc,
    rp.id                        AS listing_id,
    TRUE                         AS listing_detail_available
FROM fyp.rental_properties rp
LEFT JOIN LATERAL (
    SELECT l.sitewise_property_id
    FROM fyp.property_subject_links l
    WHERE l.property_id = rp.id AND l.match_verified IS TRUE
    LIMIT 1
) lk ON TRUE
LEFT JOIN LATERAL (
    SELECT f.*
    FROM sitewise_analytics.subject_features f
    WHERE f.canonical_property_id = coalesce(lk.sitewise_property_id, rp.catalogue_id)
      AND btrim(f.sample_class) = 'U'
    ORDER BY f.imported_at DESC NULLS LAST
    LIMIT 1
) sf ON TRUE
LEFT JOIN LATERAL (
    SELECT q.*
    FROM fyp_features.property_population_spatial q
    WHERE q.source_record_id = coalesce(lk.sitewise_property_id, rp.catalogue_id)
    ORDER BY (q.source_record_type <> 'SITEWISE_U_PROPERTY'), q.source_record_type
    LIMIT 1
) pop ON TRUE
WHERE rp.id = ANY(CAST(:property_ids AS bigint[]))
  AND rp.is_published IS TRUE
  AND rp.verification_status = 'approved'
ORDER BY rp.id
"""

_SELECT = """
SELECT
    p.id                         AS property_id,
    p.title                      AS title,
    p.address                    AS address,
    p.city                       AS city,
    p.state                      AS state,
    p.postcode                   AS postcode,
    p.property_type              AS property_type,
    p.rental_rm                  AS monthly_rental_myr,
    p.size_sqft                  AS built_up_sqft,
    p.latitude                   AS latitude,
    p.longitude                  AS longitude,
    p.image_url                  AS image_url,
    p.source_data                AS source_data,
    to_jsonb(sf)                 AS subject_doc,
    to_jsonb(pop)                AS population_doc,
    link.listing_id              AS listing_id,
    link.detail_available        AS listing_detail_available
FROM fyp.catalogue_properties p
LEFT JOIN LATERAL (
    SELECT l.property_id AS listing_id,
           (rp.is_published AND rp.verification_status = 'approved') AS detail_available
    FROM fyp.property_subject_links l
    JOIN fyp.rental_properties rp ON rp.id = l.property_id
    WHERE l.sitewise_property_id = p.id
      AND l.match_verified IS TRUE
    LIMIT 1
) link ON TRUE
LEFT JOIN LATERAL (
    SELECT f.*
    FROM sitewise_analytics.subject_features f
    WHERE f.canonical_property_id = p.id
      AND btrim(f.sample_class) = 'U'
    ORDER BY f.imported_at DESC NULLS LAST
    LIMIT 1
) sf ON TRUE
LEFT JOIN LATERAL (
    SELECT q.*
    FROM fyp_features.property_population_spatial q
    WHERE q.source_record_id = p.id
    ORDER BY (q.source_record_type <> 'SITEWISE_U_PROPERTY'), q.source_record_type
    LIMIT 1
) pop ON TRUE
WHERE {eligibility}
  {filters}
ORDER BY p.id
{limit_clause}
"""


def _as_float(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _first_number(sources: tuple[Mapping[str, Any], ...], *keys: str) -> float | None:
    """First resolvable numeric value across provenance-ranked sources.

    A missing or non-numeric value stays ``None``; it is never coerced to 0.
    """
    for key in keys:
        for source in sources:
            if source and key in source:
                number = _as_float(source[key])
                if number is not None:
                    return number
    return None


def _first_text(sources: tuple[Mapping[str, Any], ...], *keys: str) -> str | None:
    for key in keys:
        for source in sources:
            value = source.get(key) if source else None
            if isinstance(value, str) and value.strip():
                return value.strip()
    return None


class RecommendationCandidateRepository:
    """One read-only query; one row per eligible catalogue property."""

    def __init__(self, analytics_session: Session):
        self.session = analytics_session

    def list_candidates(self, *, max_rent: float | None = None,
                        min_size: float | None = None,
                        state: str | None = None,
                        property_ids: list[str] | None = None,
                        limit: int | None = None,
                        skip_eligibility: bool = False) -> list[dict[str, Any]]:
        """Return canonical-name dictionaries ready for the domain layer.

        ``property_ids`` restricts the read to an explicit id set (used by
        Compare for at most three catalogue ids). It is pushed into the SAME
        query — no second repository and no full-catalogue scan.
        ``max_rent`` / ``min_size`` / ``state`` are pre-filters pushed into
        SQL for efficiency; the domain layer re-applies eligibility so the rule
        has a single authoritative implementation regardless of caller.
        ``skip_eligibility`` (Compare only) resolves targeted ids WITHOUT the
        search eligibility: a shortlisted property whose recorded status later
        became RENTED is reported with that status, not silently dropped.
        """
        filters: list[str] = []
        params: dict[str, Any] = {}
        if not skip_eligibility:
            params["unavailable"] = _EXPLICITLY_UNAVAILABLE
        if max_rent is not None:
            filters.append("AND p.rental_rm <= CAST(:max_rent AS double precision)")
            params["max_rent"] = float(max_rent)
        if min_size is not None:
            filters.append("AND p.size_sqft >= CAST(:min_size AS double precision)")
            params["min_size"] = float(min_size)
        if state:
            filters.append("AND p.state ILIKE :state")
            params["state"] = state.strip()
        if property_ids is not None:
            ids = list(dict.fromkeys(str(value) for value in property_ids if value))
            if not ids:
                return []
            filters.append("AND p.id = ANY(:property_ids)")
            params["property_ids"] = ids
        limit_clause = ""
        if limit is not None:
            limit = max(1, int(limit))
            limit_clause = "LIMIT :row_limit"
            params["row_limit"] = limit
        # Filters keep their ``AND`` prefixes; only a leading ``AND`` (which
        # appears when the eligibility clause is skipped for Compare) is
        # stripped so the WHERE stays syntactically valid.
        where_parts: list[str] = []
        if not skip_eligibility:
            where_parts.append(_ELIGIBILITY_SQL)
        where_parts.extend(filters)
        where_sql = ("\n  ".join(where_parts).strip() or "TRUE").removeprefix("AND ")
        sql = _SELECT.format(
            eligibility=where_sql,
            filters="",
            limit_clause=limit_clause,
        )
        # Build the TextClause ONCE from the complete SQL, then attach the
        # expanding bind. Re-wrapping ``str(statement)`` after the fact loses
        # the bound parameters (and turns the tuple into a driver error).
        statement = text(sql)
        if not skip_eligibility:
            statement = statement.bindparams(bindparam("unavailable", expanding=True))
        rows = self.session.execute(statement, params).mappings().all()
        return [self._map(row) for row in rows]

    def list_operational_candidates(
        self, property_ids: list[str], *, operational_session: Session
    ) -> list[dict[str, Any]]:
        """Resolve numeric operational ids (approved + published ONLY).

        Rows are mapped through the SAME ``_map`` pipeline as catalogue rows so
        both id universes expose identical metric keys. Unpublished or
        unapproved ids are deliberately absent from the result — the caller
        reports them as unresolved with the access reason, never leaking a
        pending listing's data.
        """
        ids = list(dict.fromkeys(str(value) for value in property_ids if value))
        if not ids:
            return []
        raw_rows = operational_session.execute(
            text(_OPERATIONAL_SELECT), {"property_ids": ids}
        ).mappings().all()
        result: list[dict[str, Any]] = []
        for raw in raw_rows:
            mapped = self._map(dict(raw))
            availability = _first_text((raw,), "operational_availability")
            floor_raw = raw.get("operational_floor_level")
            floor_text = None
            if floor_raw is not None:
                floor_num = _as_float(floor_raw)
                if floor_num is not None:
                    floor_text = str(int(floor_num)) if float(floor_num).is_integer() else str(floor_num)
            parking = raw.get("operational_has_parking")
            mapped["availability_status"] = (availability or "").strip() or "UNKNOWN_NOT_VERIFIED"
            mapped["operational_listing"] = True
            mapped["operational_catalogue_ref"] = _first_text(
                (raw,), "catalogue_ref"
            )
            # Physical attributes come from the OPERATIONAL row itself; the
            # catalogue extras are research annotations, not listing facts.
            mapped["floor_level_text"] = floor_text
            mapped["unit_position"] = _first_text((raw,), "operational_unit_position")
            mapped["recorded_has_parking"] = (
                bool(parking) if parking in (0, 1, True, False) else None
            )
            result.append(mapped)
        return result

    def _map(self, row: Mapping[str, Any]) -> dict[str, Any]:
        raw = dict(row)
        source = raw.get("source_data") or {}
        subject = raw.get("subject_doc") or {}
        population = raw.get("population_doc") or {}
        extra = subject.get("other_features") or {}
        if not isinstance(extra, dict):
            extra = {}
        if not isinstance(source, dict):
            source = {}
        if not isinstance(subject, dict):
            subject = {}
        if not isinstance(population, dict):
            population = {}

        # Ranked provenance: catalogue workbook values first (they are the
        # model's own source), then the subject feature row / other_features,
        # then the population raster row.
        sources = (source, extra, subject, population)

        availability = _first_text((source,), "property_availability_status")
        availability = availability or "UNKNOWN_NOT_VERIFIED"
        confirmed = availability.upper() in {"AVAILABLE", "VERIFIED_AVAILABLE", "CONFIRMED"}

        # Radius provenance for the two demand metrics whose recorded keys
        # may exist at 500 m OR 1 km. The display layer MUST know which radius
        # a value came from — a 1 km count is never silently presented as a
        # 500 m measurement. Additive keys only; the recommendation feature
        # mapping itself is unchanged.
        universities_500 = _first_number(sources, "universities_colleges_count_500m")
        universities_1km = _first_number(sources, "universities_count_1km")
        malls_500 = _first_number(sources, "malls_count_500m")
        malls_1km = _first_number(sources, "malls_count_1km")

        pu_score = _first_number((source,), "research_p_association_score")
        if pu_score is not None and not 0.0 <= pu_score <= 1.0:
            pu_score = None

        return {
            "property_id": str(raw.get("property_id") or ""),
            "title": str(raw.get("title") or ""),
            "address": str(raw.get("address") or ""),
            "city": str(raw.get("city") or ""),
            "state": str(raw.get("state") or ""),
            "district": _first_text((source,), "district", "state_dosm") or "",
            "postcode": str(raw.get("postcode") or ""),
            "property_type": (
                str(raw.get("property_type")).strip() if raw.get("property_type") else None
            ),
            "monthly_rental_myr": _as_float(raw.get("monthly_rental_myr")),
            "built_up_sqft": _as_float(raw.get("built_up_sqft")),
            # Physical attributes: recorded for a subset of subjects under
            # ``property_*`` keys in other_features. Never parsed out of the
            # free-text title, and never defaulted to zero.
            "floor_level": None,
            "floor_level_text": _first_text(
                (extra,), "property_floor_level", "floor_level"
            ),
            "unit_position": _first_text(
                (extra,), "property_unit_position", "unit_position"
            ),
            "frontage_ft": _first_number((extra,), "property_frontage_ft", "frontage_ft"),
            "depth_ft": _first_number((extra,), "property_depth_ft", "depth_ft"),
            "latitude": _as_float(raw.get("latitude")),
            "longitude": _as_float(raw.get("longitude")),
            "image_url": raw.get("image_url"),
            # Geospatial: population 500 m / 1 km catchments.
            "population_500m": _first_number(
                (population,), "pop_ring_0_500m", "pop_total_200m"
            ),
            "population_1000m": _first_number((population, extra), "pop_total_1km"),
            # Exact 500 m ring only. ``pop_total_200m`` is a DIFFERENT radius
            # and is deliberately not used as a 500 m fallback here.
            "population_500m_exact": _first_number(
                (population,), "pop_ring_0_500m"
            ),
            # Demand generators (office / education / retail).
            "office_pois_500m": _first_number(
                sources, "office_pois_500m", "office_poi_count_500m"
            ),
            "schools_count_500m": _first_number(
                sources, "schools_count_500m", "schools_count_1km"
            ),
            "universities_count_500m": universities_500 if universities_500 is not None else universities_1km,
            "universities_count_500m_radius_m": (
                500 if universities_500 is not None
                else (1000 if universities_1km is not None else None)
            ),
            "malls_count_500m": malls_500 if malls_500 is not None else malls_1km,
            "malls_count_500m_radius_m": (
                500 if malls_500 is not None else (1000 if malls_1km is not None else None)
            ),
            # Competition.
            "fnb_competitors_500m": _first_number(
                sources, "fnb_competitors_500m", "competitor_count_500m"
            ),
            "fnb_competitors_1000m": _first_number(
                sources, "fnb_competitors_1000m", "competitor_count_1000m"
            ),
            "nearest_competitor_distance_m": _first_number(
                (subject, extra), "nearest_competitor_distance_m"
            ),
            "cafe_count_500m": _first_number(sources, "cafe_count_500m"),
            "restaurant_count_500m": _first_number(sources, "restaurant_count_500m"),
            "fast_food_count_500m": _first_number(sources, "fast_food_count_500m"),
            "bakery_count_500m": _first_number(
                sources, "bakery_dessert_beverage_count_500m"
            ),
            # Accessibility / walkability.
            "bus_stops_500m_walk": _first_number(
                sources, "bus_stops_500m_walk", "transit_stops_500m_walk"
            ),
            "rail_stations_1km_walk": _first_number(
                sources, "rail_stations_1km_walk", "transit_stops_1km_walk"
            ),
            "nearest_transit_walk_m": _first_number(sources, "nearest_transit_walk_m"),
            "walk_isochrone_area_10min_km2": _first_number(
                sources, "walk_isochrone_area_10min_km2"
            ),
            "nearest_major_road_m": _first_number(sources, "nearest_major_road_m"),
            # Parking.
            "parking_facilities_500m": _first_number(sources, "parking_facilities_500m"),
            "nearest_parking_distance_m": _first_number(
                sources, "nearest_parking_distance_m"
            ),
            "parking_status": _first_text((subject, extra), "parking_status"),
            "building_footprint_density_500m": _first_number(
                sources, "building_footprint_density_500m"
            ),
            # Layer 1 PU research association (stored model output).
            "pu_association_score": pu_score,
            "pu_model_method": _first_text((source,), "model_method"),
            "pu_feature_set": _first_text((source,), "model_feature_set"),
            "pu_score_type": _first_text((source,), "score_type"),
            "pu_score_source": "fyp.rental_properties.catalogue_source_data.research_p_association_score",
            "sample_class": _first_text((source, subject), "sample_class"),
            "availability_status": availability,
            "analysis_status": _first_text((source, subject), "analysis_status"),
            "data_completeness_pct": _first_number((source,), "data_completeness_pct"),
            "coordinate_quality": _first_text((source,), "coordinate_quality"),
            "reference_coverage": _first_text((source,), "reference_coverage"),
            "verification": {
                "dataset": "fyp.catalogue_properties (955 U-class research catalogue rows)",
                "source_schema": "fyp_catalogue",
                "availability_status": availability,
                "confirmed_available": confirmed,
                "pending_verification": False,
                "policy": (
                    "Approved + published fyp.rental_properties are the only "
                    "listings the product treats as verified; this engine reads "
                    "the separate research catalogue and never presents its "
                    "UNKNOWN_NOT_VERIFIED availability as confirmed."
                ),
                "excludes": "fyp.rental_properties rows with verification_status='pending'",
            },
            # Verified mapping to the commercial listing entity (bigint) the
            # explore/detail routes navigate with. ``None`` means NO verified
            # link exists - the row stays research-catalogue-only and the
            # client must not guess a numeric id. ``detail_available`` mirrors
            # the explore policy (approved + published only): every imported
            # catalogue listing is verification_status='pending', so detail
            # navigation is explicitly reported unavailable rather than 404ing
            # the client after a click.
            "listing_ref": (
                {
                    "listing_id": int(raw["listing_id"]),
                    "match_verified": True,
                    "detail_available": bool(raw.get("listing_detail_available")),
                    "detail_note": (
                        "Listing exists and is identity-verified, but is NOT "
                        "approved+published; GET /explore/properties/{listing_id} "
                        "stays 404 until an administrator publishes it."
                    )
                    if not bool(raw.get("listing_detail_available"))
                    else None,
                }
                if raw.get("listing_id") is not None
                else None
            ),
        }
