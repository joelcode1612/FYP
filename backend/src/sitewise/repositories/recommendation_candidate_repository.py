"""Read-only candidate source for the personalised recommendation engine.

Verified field mappings (research workbook name -> production column)
====================================================================

============================  ==================================================
Canonical field               Source
============================  ==================================================
canonical_property_id         ``sitewise_app.properties.id`` (TEXT, EP-/MD- ids)
property_type                 ``sitewise_app.properties.property_type``
monthly_rental_myr            ``sitewise_app.properties.rental_rm``  (NOT price)
built_up_sqft                 ``sitewise_app.properties.size_sqft``
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
* Only the published **research catalogue** (``sitewise_app.properties``, 955
  U-class rows) is read here. The 955 imported ``fyp.rental_properties`` rows
  are ``verification_status='pending'`` and are deliberately NOT mixed in:
  presenting them would violate the existing approved+published verification
  policy. ``UNKNOWN_NOT_VERIFIED`` availability is surfaced as a caution and
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
FROM sitewise_app.properties p
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
WHERE p.rental_rm IS NOT NULL AND p.rental_rm > 0
  AND p.size_sqft IS NOT NULL AND p.size_sqft > 0
  AND coalesce(p.source_data->>'property_availability_status', 'UNKNOWN_NOT_VERIFIED')
      NOT IN :unavailable
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
                        limit: int | None = None) -> list[dict[str, Any]]:
        """Return canonical-name dictionaries ready for the domain layer.

        ``max_rent`` / ``min_size`` / ``state`` are *pre-filters* pushed into
        SQL for efficiency; the domain layer re-applies eligibility so the rule
        has a single authoritative implementation regardless of caller.
        """
        filters: list[str] = []
        params: dict[str, Any] = {"unavailable": _EXPLICITLY_UNAVAILABLE}
        if max_rent is not None:
            filters.append("AND p.rental_rm <= CAST(:max_rent AS double precision)")
            params["max_rent"] = float(max_rent)
        if min_size is not None:
            filters.append("AND p.size_sqft >= CAST(:min_size AS double precision)")
            params["min_size"] = float(min_size)
        if state:
            filters.append("AND p.state ILIKE :state")
            params["state"] = state.strip()
        limit_clause = ""
        if limit is not None:
            limit = max(1, int(limit))
            limit_clause = "LIMIT :row_limit"
            params["row_limit"] = limit
        sql = _SELECT.format(
            filters="\n  ".join(filters),
            limit_clause=limit_clause,
        )
        # Build the TextClause ONCE from the complete SQL, then attach the
        # expanding bind. Re-wrapping ``str(statement)`` after the fact loses
        # the bound parameters (and turns the tuple into a driver error).
        statement = text(sql).bindparams(bindparam("unavailable", expanding=True))
        rows = self.session.execute(statement, params).mappings().all()
        return [self._map(row) for row in rows]

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
            # Demand generators (office / education / retail).
            "office_pois_500m": _first_number(
                sources, "office_pois_500m", "office_poi_count_500m"
            ),
            "schools_count_500m": _first_number(
                sources, "schools_count_500m", "schools_count_1km"
            ),
            "universities_count_500m": _first_number(
                sources, "universities_colleges_count_500m", "universities_count_1km"
            ),
            "malls_count_500m": _first_number(sources, "malls_count_500m", "malls_count_1km"),
            # Competition.
            "fnb_competitors_500m": _first_number(
                sources, "fnb_competitors_500m", "competitor_count_500m"
            ),
            "fnb_competitors_1000m": _first_number(
                sources, "fnb_competitors_1000m", "competitor_count_1000m"
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
            "pu_score_source": "sitewise_app.properties.source_data.research_p_association_score",
            "sample_class": _first_text((source, subject), "sample_class"),
            "availability_status": availability,
            "analysis_status": _first_text((source, subject), "analysis_status"),
            "data_completeness_pct": _first_number((source,), "data_completeness_pct"),
            "coordinate_quality": _first_text((source,), "coordinate_quality"),
            "reference_coverage": _first_text((source,), "reference_coverage"),
            "verification": {
                "dataset": "sitewise_app.properties (955 U-class research catalogue rows)",
                "source_schema": "sitewise_app",
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
