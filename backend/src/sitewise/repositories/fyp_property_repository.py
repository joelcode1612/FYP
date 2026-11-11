"""Read repository for the ``fyp`` operational property schema.

Every query is parameterized (bound values only — no string interpolation of
user input) and read-only. The engine is the main application session
(``sitewise.db.session.get_db``): the live database hosts ``public``,
``fyp``, ``fnb_a``, ``demand_gen``, ``fyp_features`` and ``sitewise_app``
together (verified 2026-11-09).

Gating rule (task §6C): entrepreneur-facing reads expose ONLY rows with
``verification_status = 'approved' AND is_published``. The 955 pending
research imports stay invisible. Nothing here publishes, approves, or
mutates any row.

Spatial queries follow ONE canonical competitor contract (see
``_COMPETITOR_PREDICATE``): a degree-space ``&&`` pre-filter keeps the existing
GIST index on ``fnb_a.fnb_outlet.geom`` usable, and the authoritative radius
test is geodesic (``ST_DWithin(...::geography)``). Distances are geodesic too.
Foursquare is not integrated (no dataset/licence in this deployment); Overture
rows come from ``fnb_a.overture_places`` and are deduplicated against OSM via
the confirmed ``fnb_a.overture_match`` decisions.
"""

import math
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

# 500 m / 1 km are the documented research radii (property_geospatial_features
# columns); 250 m supports the UI's fine-grained marker view.
_ALLOWED_RADII_M = (250, 500, 1000)
_M_PER_DEGREE = 111_320.0

# ---------------------------------------------------------------------------
# Canonical F&B competitor contract — ONE definition for live queries, the
# enrichment service and the feature ETL. Changing it changes every competitor
# number in the product.
#
#   * population : ``fnb_a.fnb_outlet`` rows with a geometry, inside the target
#                  region AND inside the main F&B scope (``in_main_scope``
#                  excludes the 1,307 unclassified rows).
#   * radius     : geodesic metres; padded degree ``&&`` pre-filter for the
#                  GIST index, then ``ST_DWithin(geography)`` decides.
#   * sources    : ``osm`` (default, backward compatible), ``overture``,
#                  ``merged`` (Overture rows already MATCHed to an OSM outlet
#                  are suppressed so a business is never counted twice).
# ---------------------------------------------------------------------------
COMPETITOR_SOURCES = ("osm", "overture", "merged")

_COMPETITOR_PREDICATE = "o.geom IS NOT NULL AND o.in_target_region AND o.in_main_scope"

#: Overture rows are competitors only inside the study area and with a
#: normalized F&B category. ``operating_status IS NULL`` means UNKNOWN — never
#: "open" (163,296 of 163,297 rows carry NULL in this release).
_OVERTURE_PREDICATE = (
    "v.longitude IS NOT NULL AND v.latitude IS NOT NULL AND v.in_study_area "
    "AND v.fnb_category_normalized IS NOT NULL"
)

#: A confirmed MATCH means the Overture row IS an OSM outlet — exclude it from
#: merged results so the same business is not counted twice.
_OVERTURE_NOT_MATCHED = (
    "NOT EXISTS (SELECT 1 FROM fnb_a.overture_match m "
    "WHERE m.overture_id = v.overture_id AND m.decision = 'MATCH')"
)


def _radius_args(lat: float, lon: float, radius_m: int) -> dict[str, Any]:
    """Bind values for a geodesic radius with a padded degree pre-filter."""
    pad = radius_m * 1.02 / _M_PER_DEGREE
    cos_lat = max(0.02, abs(math.cos(math.radians(lat))))
    return {
        "lat": float(lat),
        "lon": float(lon),
        "pad": pad,
        "lonpad": radius_m * 1.02 / (_M_PER_DEGREE * cos_lat),
        "radius_m": float(radius_m),
    }


def _osm_radius_sql() -> str:
    return (
        f"{_COMPETITOR_PREDICATE} "
        "AND o.geom && ST_Expand(ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :pad) "
        "AND ST_DWithin(o.geom::geography, "
        "ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography, :radius_m)"
    )


def _overture_radius_sql() -> str:
    return (
        f"{_OVERTURE_PREDICATE} "
        "AND v.longitude BETWEEN :lon - :lonpad AND :lon + :lonpad "
        "AND v.latitude BETWEEN :lat - :pad AND :lat + :pad "
        "AND ST_DistanceSphere("
        "ST_SetSRID(ST_MakePoint(v.longitude, v.latitude), 4326), "
        "ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)) <= :radius_m"
    )

_SORTS: dict[str, str] = {
    "newest": "p.created_at DESC NULLS LAST, p.id DESC",
    "price_asc": "p.rental_price ASC NULLS LAST, p.id ASC",
    "price_desc": "p.rental_price DESC NULLS LAST, p.id DESC",
    "size_asc": "p.size_sqft ASC NULLS LAST, p.id ASC",
    "size_desc": "p.size_sqft DESC NULLS LAST, p.id DESC",
    "psf_asc": "p.psf ASC NULLS LAST, p.id ASC",
}

_LIST_COLUMNS = """
    p.id               AS property_id,
    p.name,
    p.property_type,
    p.description,
    p.address,
    p.city,
    p.state,
    p.latitude,
    p.longitude,
    p.rental_price,
    p.size_sqft,
    p.psf,
    p.availability,
    p.tenure,
    p.furnishing,
    p.floor_level,
    p.bathrooms,
    p.is_fnb_suitable,
    p.has_parking,
    p.is_corner_lot,
    p.is_freehold,
    p.verification_status,
    p.is_published,
    p.published_at,
    p.created_at,
    photo.url          AS primary_image,
    g.competitor_count_500m,
    g.competitor_count_1km,
    g.demand_generator_count_500m,
    g.demand_generator_count_1km,
    g.population_500m,
    g.population_1km,
    g.population_level,
    g.accessibility_score,
    g.income_median,
    g.market_segment,
    g.overall_location_score,
    (l.subject_id IS NOT NULL AND l.match_verified) AS has_research_link
"""

_PUBLISHED_FILTER = "p.is_published AND p.verification_status = 'approved'"

# ---------------------------------------------------------------------------
# Nearby-property contract (Explore default filter) — ONE definition.
#
# This counts OTHER ELIGIBLE COMMERCIAL LISTINGS within a geodesic radius of
# each row. It is deliberately a DIFFERENT dataset from the F&B competitor
# counts (`competitor_count_500m`), which aggregate fnb_a research outlets and
# must never be shown as nearby-property numbers.
#
#   * neighbours   : approved + published `fyp.rental_properties` rows with a
#                    usable generated geometry; each counted once (`o.id <> p.id`).
#   * radius       : geodesic metres; a padded degree `&&` pre-filter keeps the
#                    GIST index on `fyp.rental_properties.geom` usable, then
#                    `ST_DWithin(...::geography)` decides (inclusive at the
#                    boundary, like every other radius in this repository).
#   * shape        : one correlated LATERAL per candidate row inside a single
#                    statement — set-based SQL, no per-card application queries.
#                    The base WHERE narrows candidates first, so rows excluded
#                    by other filters never pay for a proximity scan.
# ---------------------------------------------------------------------------
_NEARBY_LATERAL = """
LEFT JOIN LATERAL (
    SELECT count(*)::int AS nearby_count
    FROM fyp.rental_properties o
    WHERE o.id <> p.id
      AND o.is_published AND o.verification_status = 'approved'
      AND o.geom IS NOT NULL
      AND o.geom && ST_Expand(p.geom, :nearby_pad)
      AND ST_DWithin(o.geom::geography, p.geom::geography, :nearby_radius_m)
) nearby ON TRUE"""

_NEARBY_COUNT_COLUMN = ", nearby.nearby_count AS nearby_property_count"


def _meters_to_degrees(meters: float) -> float:
    """Meter→degree conversion for geometry-space radius predicates.

    NOTE: this is a plain ratio (``m / 111_320``), NOT ``math.degrees()`` —
    that function converts radians and would inflate the radius ~57×.
    """
    return meters / _M_PER_DEGREE


class FypPropertyRepository:
    """Read-only access to ``fyp.rental_properties`` and its related tables."""

    def __init__(self, session: Session):
        self.session = session

    # ------------------------------------------------------------- explore

    def list_published(self, params: dict[str, Any]) -> dict:
        """Paginated, filtered, sorted read of APPROVED + PUBLISHED listings.

        One query, one lateral join per row — no N+1. Competitor/population
        figures come from the precomputed ``property_geospatial_features``
        row when one exists (``null`` otherwise: never a fabricated 0).

        Optional spatial filter (``min_nearby_properties`` +
        ``nearby_radius_m``): keeps only listings with at least that many
        OTHER approved + published listings within the geodesic radius. The
        filter applies before ``LIMIT``/``OFFSET`` and the ``total`` in
        ``meta`` counts the same filtered set, so pagination stays consistent.
        Rows without usable coordinates can never satisfy the spatial filter
        (a NULL generated geometry makes the lateral count 0) and are excluded
        rather than given invented coordinates. When the filter is absent the
        lateral is not built at all and the response is byte-compatible with
        previous consumers.
        """
        where = ["p.is_published", "p.verification_status = 'approved'"]
        args: dict[str, Any] = {}
        if params.get("q"):
            where.append(
                "(p.name ILIKE :q OR p.address ILIKE :q OR p.city ILIKE :q "
                "OR p.property_type ILIKE :q)"
            )
            args["q"] = f"%{params['q']}%"
        for column, key in (
            ("p.state", "state"),
            ("p.city", "city"),
            ("p.property_type", "property_type"),
            ("p.availability", "availability"),
        ):
            if params.get(key):
                where.append(f"{column} = :{key}")
                args[key] = params[key]
        if params.get("min_price") is not None:
            where.append("p.rental_price >= :min_price")
            args["min_price"] = params["min_price"]
        if params.get("max_price") is not None:
            where.append("p.rental_price <= :max_price")
            args["max_price"] = params["max_price"]
        if params.get("min_size") is not None:
            where.append("p.size_sqft >= :min_size")
            args["min_size"] = params["min_size"]
        if params.get("max_size") is not None:
            where.append("p.size_sqft <= :max_size")
            args["max_size"] = params["max_size"]
        if params.get("fnb_suitable"):
            where.append("p.is_fnb_suitable = 1")

        # Spatial filter: bound values only, radius validated against the
        # same whitelist as every other radius endpoint in this repository.
        nearby_min = params.get("min_nearby_properties")
        nearby_active = nearby_min is not None
        nearby_radius_m = int(params.get("nearby_radius_m") or 500)
        nearby_lateral = ""
        select_columns = _LIST_COLUMNS
        if nearby_active:
            self._validate_radius(nearby_radius_m)
            nearby_lateral = _NEARBY_LATERAL
            select_columns += _NEARBY_COUNT_COLUMN
            args["min_nearby_properties"] = int(nearby_min)
            args["nearby_radius_m"] = float(nearby_radius_m)
            # Padded degree pre-filter window (2% slack) for the GIST index.
            args["nearby_pad"] = nearby_radius_m * 1.02 / _M_PER_DEGREE
            where.append("nearby.nearby_count >= :min_nearby_properties")

        order = _SORTS.get(params.get("sort") or "newest", _SORTS["newest"])
        where_sql = " AND ".join(where)
        limit = int(params.get("limit") or 24)
        offset = int(params.get("offset") or 0)

        total = self.session.execute(
            text(
                f"SELECT count(*) FROM fyp.rental_properties p "
                f"{nearby_lateral} WHERE {where_sql}"
            ),
            args,
        ).scalar_one()

        rows = (
            self.session.execute(
                text(
                    f"""
                    SELECT {select_columns}
                    FROM fyp.rental_properties p
                    {nearby_lateral}
                    LEFT JOIN LATERAL (
                        SELECT url FROM fyp.property_photos ph
                        WHERE ph.property_id = p.id
                        ORDER BY ph.is_primary DESC, ph.id
                        LIMIT 1
                    ) photo ON TRUE
                    LEFT JOIN fyp.property_geospatial_features g
                        ON g.property_id = p.id
                    LEFT JOIN fyp.property_subject_links l
                        ON l.property_id = p.id AND l.match_verified
                    WHERE {where_sql}
                    ORDER BY {order}
                    LIMIT :limit OFFSET :offset
                    """
                ),
                {**args, "limit": limit, "offset": offset},
            )
            .mappings()
            .all()
        )
        meta: dict[str, Any] = {"total": int(total), "limit": limit, "offset": offset}
        if nearby_active:
            meta["min_nearby_properties"] = int(nearby_min)
            meta["nearby_radius_m"] = nearby_radius_m
        return {
            "data": [dict(row) for row in rows],
            "meta": meta,
        }

    def get_published(self, property_id: int) -> dict | None:
        """One approved+published listing with the same shape as the list."""
        row = (
            self.session.execute(
                text(
                    f"""
                    SELECT {_LIST_COLUMNS}
                    FROM fyp.rental_properties p
                    LEFT JOIN LATERAL (
                        SELECT url FROM fyp.property_photos ph
                        WHERE ph.property_id = p.id
                        ORDER BY ph.is_primary DESC, ph.id
                        LIMIT 1
                    ) photo ON TRUE
                    LEFT JOIN fyp.property_geospatial_features g
                        ON g.property_id = p.id
                    LEFT JOIN fyp.property_subject_links l
                        ON l.property_id = p.id AND l.match_verified
                    WHERE p.id = :pid AND {_PUBLISHED_FILTER}
                    """
                ),
                {"pid": property_id},
            )
            .mappings()
            .first()
        )
        return dict(row) if row else None

    def get_photos(self, property_id: int) -> list[dict]:
        """All stored photo URLs for one property (possibly empty — the
        photos table is empty live)."""
        rows = self.session.execute(
            text(
                """
                SELECT id, url, caption, is_primary, created_at
                FROM fyp.property_photos WHERE property_id = :pid ORDER BY is_primary DESC, id
                """
            ),
            {"pid": property_id},
        ).mappings().all()
        return [dict(r) for r in rows]

    def get_listing_sources(self, property_id: int) -> list[dict]:
        """Where the listing was imported from (platform + observed state)."""
        rows = self.session.execute(
            text(
                """
                SELECT source_platform, source_listing_id, source_url,
                       source_availability, source_observed_at, source_checked_at
                FROM fyp.property_listing_sources
                WHERE property_id = :pid ORDER BY source_checked_at DESC NULLS LAST
                """
            ),
            {"pid": property_id},
        ).mappings().all()
        return [dict(r) for r in rows]

    def get_geo_features(self, property_id: int) -> dict | None:
        row = (
            self.session.execute(
                text(
                    """
                    SELECT * FROM fyp.property_geospatial_features
                    WHERE property_id = :pid
                    """
                ),
                {"pid": property_id},
            )
            .mappings()
            .first()
        )
        return dict(row) if row else None

    def get_amenities(self, property_id: int) -> dict | None:
        row = (
            self.session.execute(
                text(
                    """
                    SELECT suitable_for, nearby_landmarks, amenities, remarks
                    FROM fyp.property_features WHERE property_id = :pid
                    """
                ),
                {"pid": property_id},
            )
            .mappings()
            .first()
        )
        return dict(row) if row else None

    # ----------------------------------------------- research linkage (U set)

    def get_research_evidence(self, property_id: int) -> dict | None:
        """Verified research linkage for one property.

        Returns the verified subject link plus the linked
        ``sitewise_analytics.subject_features`` row. These are *research
        features and status flags* — there is no verified success-probability
        column, and none is invented here. ``null`` when the property has no
        verified link (all 227 published rows: the 955-link set is the
        pending U candidates).
        """
        row = (
            self.session.execute(
                text(
                    """
                    SELECT l.subject_id, l.sitewise_property_id, l.match_method,
                           l.match_evidence, l.verified_at,
                           sf.sample_class, sf.competitor_count_500m,
                           sf.competitor_count_1000m,
                           sf.cafe_count_500m, sf.restaurant_count_500m,
                           sf.fast_food_count_500m,
                           sf.nearest_competitor_distance_m,
                           sf.bus_stops_500m_walk, sf.rail_stations_1km_walk,
                           sf.nearest_transit_walk_m, sf.nearest_major_road_m,
                           sf.road_length_density_500m_km_km2,
                           sf.building_footprint_density_500m,
                           sf.building_count_500m, sf.parking_facilities_500m,
                           sf.nearest_parking_distance_m,
                           sf.district_income_median_myr,
                           sf.analysis_status, sf.parking_status,
                           sf.reference_coverage, sf.feature_snapshot_at
                    FROM fyp.property_subject_links l
                    JOIN sitewise_analytics.subject_features sf
                        ON sf.subject_id = l.subject_id
                    WHERE l.property_id = :pid AND l.match_verified
                    """
                ),
                {"pid": property_id},
            )
            .mappings()
            .first()
        )
        return dict(row) if row else None

    def get_population(self, property_id: int) -> dict | None:
        """DOSM/population-raster intelligence via the verified subject link.

        ``fyp_features.property_population_spatial`` is keyed by
        ``(source_record_type, source_record_id)``; property links resolve
        through the ``PROPERTY_UNLABELED`` / ``SITEWISE_U_PROPERTY`` record
        types (verified live: 1,910 rows join through subject links).
        """
        row = (
            self.session.execute(
                text(
                    """
                    SELECT p.pop_total_200m, p.pop_total_1km, p.pop_total_3km,
                           p.pop_ring_0_500m, p.pop_ring_500_1km,
                           p.pop_density_km2, p.pop_density_500m_km2,
                           p.pct_age_20_34_1km, p.pct_age_15_64_1km,
                           p.estimated_households_1km,
                           p.residential_building_count_500m,
                           p.residential_building_count_1km,
                           p.office_floor_area_500m_m2,
                           p.schools_count_1km, p.malls_count_1km,
                           p.universities_count_1km, p.hospitals_count_1km,
                           p.office_poi_count_500m,
                           p.population_source, p.population_source_year,
                           p.population_quality_flag
                    FROM fyp.property_subject_links l
                    JOIN fyp_features.property_population_spatial p
                        ON p.source_record_id = l.subject_id
                        AND p.source_record_type IN
                            ('PROPERTY_UNLABELED', 'SITEWISE_U_PROPERTY')
                    WHERE l.property_id = :pid AND l.match_verified
                    ORDER BY p.source_record_type
                    LIMIT 1
                    """
                ),
                {"pid": property_id},
            )
            .mappings()
            .first()
        )
        return dict(row) if row else None

    # ------------------------------------------- live spatial lookups (PostGIS)

    def _coords(self, property_id: int) -> tuple[float, float] | None:
        row = self.session.execute(
            text(
                """
                SELECT latitude, longitude FROM fyp.rental_properties
                WHERE id = :pid AND latitude IS NOT NULL AND longitude IS NOT NULL
                """
            ),
            {"pid": property_id},
        ).first()
        return (float(row[0]), float(row[1])) if row else None

    @staticmethod
    def _validate_radius(radius_m: int) -> None:
        if radius_m not in _ALLOWED_RADII_M:
            raise ValueError(f"radius_m must be one of {_ALLOWED_RADII_M}")

    # --- canonical competitor reads ---------------------------------------

    @staticmethod
    def _osm_columns() -> str:
        return """
            o.outlet_key::text          AS competitor_key,
            o.outlet_key::text          AS outlet_key,
            'openstreetmap'             AS provider,
            o.source_record_id          AS provider_record_id,
            o.outlet_name               AS name,
            o.outlet_name               AS outlet_name,
            coalesce(o.main_category, o.outlet_category) AS category,
            coalesce(o.main_category, o.outlet_category) AS outlet_category,
            o.brand,
            o.addr_street               AS street_address,
            o.addr_street               AS addr_street,
            o.addr_city                 AS city,
            o.addr_city                 AS addr_city,
            o.latitude, o.longitude,
            'unknown'                   AS operating_status,
            o.source_licence            AS source_licence,
            o.source_snapshot_at::date::text AS source_snapshot,
            o.study_region,
            ST_DistanceSphere(o.geom,
                ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)) AS distance_m
        """

    @staticmethod
    def _overture_columns() -> str:
        return """
            v.overture_id               AS competitor_key,
            v.overture_id               AS outlet_key,
            'overture'                  AS provider,
            v.overture_id               AS provider_record_id,
            v.name_primary              AS name,
            v.name_primary              AS outlet_name,
            v.fnb_category_normalized   AS category,
            v.fnb_category_normalized   AS outlet_category,
            NULL::text                  AS brand,
            NULL::text                  AS street_address,
            NULL::text                  AS addr_street,
            NULL::text                  AS city,
            NULL::text                  AS addr_city,
            v.latitude, v.longitude,
            CASE
                WHEN v.operating_status IS NULL OR btrim(v.operating_status) = ''
                THEN 'unknown'
                ELSE v.operating_status
            END                         AS operating_status,
            v.overture_licence          AS source_licence,
            v.overture_release          AS source_snapshot,
            NULL::text                  AS study_region,
            ST_DistanceSphere(
                ST_SetSRID(ST_MakePoint(v.longitude, v.latitude), 4326),
                ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)) AS distance_m
        """

    def _competitor_rows(
        self,
        lat: float,
        lon: float,
        radius_m: int,
        *,
        source: str = "osm",
        limit: int = 50,
    ) -> list[dict]:
        """Canonical competitor rows for one coordinate, by source mode."""
        self._validate_radius(radius_m)
        if source not in COMPETITOR_SOURCES:
            raise ValueError(f"source must be one of {COMPETITOR_SOURCES}")
        args = _radius_args(lat, lon, radius_m)
        args["limit"] = max(1, min(int(limit), 100))

        parts: list[str] = []
        if source in ("osm", "merged"):
            parts.append(
                f"""
                SELECT {self._osm_columns()}
                FROM fnb_a.fnb_outlet o
                WHERE {_osm_radius_sql()}
                """
            )
        if source in ("overture", "merged"):
            exclusion = f" AND {_OVERTURE_NOT_MATCHED}" if source == "merged" else ""
            parts.append(
                f"""
                SELECT {self._overture_columns()}
                FROM fnb_a.overture_places v
                WHERE {_overture_radius_sql()}{exclusion}
                """
            )
        sql = " UNION ALL ".join(parts) + " ORDER BY distance_m LIMIT :limit"
        rows = self.session.execute(text(sql), args).mappings().all()
        return [dict(r) for r in rows]

    def list_competitors(
        self,
        property_id: int,
        radius_m: int = 500,
        limit: int = 50,
        source: str = "osm",
    ) -> dict:
        """Nearby F&B competitors for a property, in the requested source mode.

        ``source`` defaults to ``osm`` so existing clients keep the exact
        behaviour they had. ``merged`` deduplicates Overture rows already
        MATCHed to an OSM outlet, so a business is never listed twice.
        """
        coords = self._coords(property_id)
        if coords is None:
            return {
                "data": [],
                "meta": {"radius_m": radius_m, "available": False, "source": source},
            }
        lat, lon = coords
        rows = self._competitor_rows(lat, lon, radius_m, source=source, limit=limit)
        return {
            "data": rows,
            "meta": {
                "radius_m": radius_m,
                "available": True,
                "count": len(rows),
                "latitude": lat,
                "longitude": lon,
                "source": source,
                "contract": "fnb_outlet in_target_region AND in_main_scope, geodesic radius",
            },
        }

    def competitor_counts(self, lat: float, lon: float) -> dict:
        """Canonical live F&B counts at 500 m and 1 km for arbitrary coordinates."""
        counts: dict[str, int | None] = {}
        for label, radius in (("500m", 500), ("1km", 1000)):
            args = _radius_args(lat, lon, radius)
            counts[f"competitor_count_{label}"] = int(
                self.session.execute(
                    text(f"SELECT count(*) FROM fnb_a.fnb_outlet o WHERE {_osm_radius_sql()}"),
                    args,
                ).scalar_one()
            )
        return counts

    def competitor_counts_by_source(self, lat: float, lon: float, radius_m: int = 500) -> dict:
        """Raw per-provider counts plus the deduplicated merged count.

        ``overture_raw`` counts every Overture place in range; ``overture_unique``
        removes those already MATCHed to an OSM outlet; ``merged`` is
        ``osm + overture_unique`` — the number a user should see.
        """
        self._validate_radius(radius_m)
        args = _radius_args(lat, lon, radius_m)
        row = self.session.execute(
            text(
                f"""
                SELECT
                  (SELECT count(*) FROM fnb_a.fnb_outlet o
                    WHERE {_osm_radius_sql()}) AS osm,
                  (SELECT count(*) FROM fnb_a.overture_places v
                    WHERE {_overture_radius_sql()}) AS overture_raw,
                  (SELECT count(*) FROM fnb_a.overture_places v
                    WHERE {_overture_radius_sql()} AND {_OVERTURE_NOT_MATCHED})
                    AS overture_unique
                """
            ),
            args,
        ).mappings().one()
        osm = int(row["osm"])
        raw = int(row["overture_raw"])
        unique = int(row["overture_unique"])
        return {
            "radius_m": radius_m,
            "osm": osm,
            "overture_raw": raw,
            "overture_unique": unique,
            "merged": osm + unique,
            "duplicates_removed": raw - unique,
        }

    def list_demand_generators(
        self, property_id: int, radius_m: int = 1000, limit: int = 50
    ) -> dict:
        """Demand generators (malls, transit hubs, offices…) within radius.

        Source: ``demand_gen.subjects`` (geom-indexed study-area subjects).
        """
        coords = self._coords(property_id)
        if coords is None:
            return {"data": [], "meta": {"radius_m": radius_m, "available": False}}
        lat, lon = coords
        if radius_m not in _ALLOWED_RADII_M:
            raise ValueError(f"radius_m must be one of {_ALLOWED_RADII_M}")
        args = _radius_args(lat, lon, radius_m)
        args["limit"] = min(int(limit), 100)
        rows = self.session.execute(
            text(
                """
                SELECT s.subject_id, s.subject_name, s.subject_category,
                       s.latitude, s.longitude,
                       ST_DistanceSphere(s.geom,
                           ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)) AS distance_m
                FROM demand_gen.subjects s
                WHERE s.geom IS NOT NULL
                  AND s.geom && ST_Expand(
                      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :pad)
                  AND ST_DWithin(s.geom::geography,
                      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                      :radius_m)
                ORDER BY distance_m
                LIMIT :limit
                """
            ),
            args,
        ).mappings().all()
        return {
            "data": [dict(r) for r in rows],
            "meta": {
                "radius_m": radius_m,
                "available": True,
                "count": len(rows),
                "latitude": lat,
                "longitude": lon,
            },
        }

    # ------------------------------------------------------- enrichment

    def enrichment_snapshot(self, lat: float, lon: float) -> dict:
        """Compute every feature the live database can actually support.

        Real values only. Anything the database cannot compute for arbitrary
        coordinates is returned as ``None`` with an explicit ``*_status`` of
        ``unavailable`` — never a fabricated 0. Population is the current
        example: WorldPop/LandScan exist only as per-property rows
        (``fyp_features.property_population_spatial``), not as a raster, so a
        new coordinate has no legitimate population value.
        """
        counts = self.competitor_counts(lat, lon)
        demand = {}
        for label, radius in (("500m", 500), ("1km", 1000)):
            args = _radius_args(lat, lon, radius)
            demand[f"demand_generator_count_{label}"] = int(
                self.session.execute(
                    text(
                        """
                        SELECT count(*) FROM demand_gen.subjects s
                        WHERE s.geom IS NOT NULL
                          AND s.geom && ST_Expand(
                              ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :pad)
                          AND ST_DWithin(s.geom::geography,
                              ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                              :radius_m)
                        """
                    ),
                    args,
                ).scalar_one()
            )

        roads = self.session.execute(
            text(
                """
                SELECT
                  coalesce(sum(ST_Length(ST_Intersection(
                      r.geom,
                      ST_Buffer(ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                                :radius_m)::geometry)::geography)), 0) / 1000.0
                      AS road_km_1km,
                  min(ST_DistanceSphere(r.geom,
                      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326))) AS nearest_road_m
                FROM fnb_a.major_roads r
                WHERE r.geom IS NOT NULL
                  AND r.geom && ST_Expand(
                      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :pad)
                  AND ST_DWithin(r.geom::geography,
                      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                      :radius_m)
                """
            ),
            _radius_args(lat, lon, 1000),
        ).mappings().one()

        return {
            **counts,
            **demand,
            "accessibility_road_km_1km": float(roads["road_km_1km"] or 0.0),
            "nearest_major_road_m": (
                float(roads["nearest_road_m"]) if roads["nearest_road_m"] is not None else None
            ),
            "population_500m": None,
            "population_1km": None,
            "population_status": "unavailable",
            "competitor_status": "ok",
            "demand_status": "ok",
            "accessibility_status": "ok",
            "calculated_at": datetime.now(timezone.utc),
            "contract": "competitors: fnb_outlet in_target_region AND in_main_scope (geodesic)",
        }

    def upsert_geospatial_features(self, property_id: int, values: dict) -> dict:
        """Persist one property's feature row in ``fyp.property_geospatial_features``.

        The table has no unique constraint on ``property_id`` in this
        deployment, so the write is UPDATE-then-INSERT (idempotent, never a
        duplicate row) rather than ``ON CONFLICT``.
        """
        payload = {
            "population_500m": values.get("population_500m"),
            "population_1km": values.get("population_1km"),
            "competitor_count_500m": values.get("competitor_count_500m"),
            "competitor_count_1km": values.get("competitor_count_1km"),
            "demand_generator_count_500m": values.get("demand_generator_count_500m"),
            "demand_generator_count_1km": values.get("demand_generator_count_1km"),
            "accessibility_road_km_1km": values.get("accessibility_road_km_1km"),
            "nearest_major_road_m": values.get("nearest_major_road_m"),
            "last_calculated_at": values.get("calculated_at") or datetime.now(timezone.utc),
        }
        updated = self.session.execute(
            text(
                """
                UPDATE fyp.property_geospatial_features SET
                    population_500m = :population_500m,
                    population_1km = :population_1km,
                    competitor_count_500m = :competitor_count_500m,
                    competitor_count_1km = :competitor_count_1km,
                    demand_generator_count_500m = :demand_generator_count_500m,
                    demand_generator_count_1km = :demand_generator_count_1km,
                    accessibility_road_km_1km = :accessibility_road_km_1km,
                    nearest_major_road_m = :nearest_major_road_m,
                    last_calculated_at = :last_calculated_at
                WHERE property_id = :property_id
                """
            ),
            {**payload, "property_id": property_id},
        ).rowcount
        if not updated:
            self.session.execute(
                text(
                    """
                    INSERT INTO fyp.property_geospatial_features (
                        property_id, population_500m, population_1km,
                        competitor_count_500m, competitor_count_1km,
                        demand_generator_count_500m, demand_generator_count_1km,
                        accessibility_road_km_1km, nearest_major_road_m,
                        last_calculated_at
                    ) VALUES (
                        :property_id, :population_500m, :population_1km,
                        :competitor_count_500m, :competitor_count_1km,
                        :demand_generator_count_500m, :demand_generator_count_1km,
                        :accessibility_road_km_1km, :nearest_major_road_m,
                        :last_calculated_at
                    )
                    """
                ),
                {**payload, "property_id": property_id},
            )
        self.session.commit()
        row = self.session.execute(
            text(
                "SELECT * FROM fyp.property_geospatial_features WHERE property_id = :pid "
                "ORDER BY id DESC LIMIT 1"
            ),
            {"pid": property_id},
        ).mappings().first()
        return dict(row) if row else {}

    # ------------------------------------------------- owner listing write

    def create_owner_listing(self, *, owner_user_id, payload: dict) -> dict:
        """Insert an owner-submitted listing into ``fyp.rental_properties``.

        New rows are always ``verification_status='pending'`` and
        ``is_published=false`` — publication stays an administrative decision.
        ``owner_user_id`` is the verified Supabase identity UUID (additive
        column); the legacy integer ``owner_id`` is left NULL. ``geom`` is a
        GENERATED column (from latitude/longitude) and must not be written.
        """
        lat = float(payload["latitude"])
        lon = float(payload["longitude"])
        size = payload.get("size_sqft")
        price = payload.get("rental_price")
        psf = None
        if size and float(size) > 0 and price is not None:
            psf = round(float(price) / float(size), 2)
        row = self.session.execute(
            text(
                """
                INSERT INTO fyp.rental_properties (
                    owner_user_id, name, property_type, description, address,
                    city, state, postcode, latitude, longitude, rental_price,
                    size_sqft, psf, availability, has_parking, is_fnb_suitable,
                    floor_level, frontage_ft, verification_status, is_published,
                    address_validation_status, address_formatted,
                    address_validated_at
                ) VALUES (
                    :owner_user_id, :name, :property_type, :description, :address,
                    :city, :state, :postcode, :latitude, :longitude,
                    :rental_price, :size_sqft, :psf, :availability, :has_parking,
                    :is_fnb_suitable, :floor_level, :frontage_ft,
                    'pending', false, :address_validation_status,
                    :address_formatted, :address_validated_at
                )
                RETURNING id, name, address, city, state, postcode, latitude,
                          longitude, rental_price, size_sqft, property_type,
                          availability, verification_status, is_published,
                          address_validation_status, address_formatted, created_at
                """
            ),
            {
                "owner_user_id": str(owner_user_id),
                "name": payload["name"],
                "property_type": payload.get("property_type") or "Shop",
                "description": payload.get("description"),
                "address": payload.get("address"),
                "city": payload.get("city"),
                "state": payload.get("state"),
                "postcode": (payload.get("postcode") or "").strip() or None,
                "latitude": lat,
                "longitude": lon,
                "rental_price": price,
                "size_sqft": size,
                "psf": psf,
                "availability": payload.get("availability"),
                "has_parking": 1 if payload.get("has_parking") else 0,
                "is_fnb_suitable": 1 if payload.get("is_fnb_suitable") else 0,
                "floor_level": payload.get("floor_level"),
                "frontage_ft": payload.get("frontage_ft"),
                "address_validation_status": payload.get(
                    "address_validation_status"
                ),
                "address_formatted": payload.get("address_formatted"),
                "address_validated_at": payload.get("address_validated_at"),
            },
        ).mappings().one()
        self.session.commit()
        return dict(row)

    def owner_listings(self, owner_user_id) -> list[dict]:
        rows = self.session.execute(
            text(
                """
                SELECT id, name, address, city, state, postcode, latitude,
                       longitude, rental_price, size_sqft, property_type,
                       availability, verification_status, is_published,
                       address_validation_status, created_at
                FROM fyp.rental_properties
                WHERE owner_user_id = :owner
                ORDER BY created_at DESC
                """
            ),
            {"owner": str(owner_user_id)},
        ).mappings().all()
        return [dict(r) for r in rows]

    # ------------------------------------------------- owner draft lifecycle

    #: Columns the Add-Property wizard may write. Everything else is decided
    #: administratively (verification_status / is_published) or derived (psf,
    #: geom is a GENERATED column and must never be written).
    _OWNER_WRITABLE = (
        "name",
        "property_type",
        "description",
        "address",
        "city",
        "state",
        "postcode",
        "latitude",
        "longitude",
        "rental_price",
        "size_sqft",
        "availability",
        "floor_level",
        "frontage_ft",
        "has_parking",
        "is_fnb_suitable",
    )

    _LISTING_SELECT = (
        "SELECT id, owner_user_id, name, property_type, description, address, "
        "city, state, postcode, latitude, longitude, rental_price, size_sqft, psf, "
        "availability, floor_level, frontage_ft, has_parking, is_fnb_suitable, "
        "verification_status, rejection_reason, is_published, "
        "address_validation_status, address_formatted, address_validated_at, "
        "created_at, updated_at "
        "FROM fyp.rental_properties"
    )

    def owner_listing(self, property_id: int) -> dict | None:
        """One listing row (any status) — callers enforce ownership."""
        row = self.session.execute(
            text(f"{self._LISTING_SELECT} WHERE id = :pid"),
            {"pid": property_id},
        ).mappings().first()
        return dict(row) if row else None

    @staticmethod
    def _numeric(value) -> float | None:
        """The wizard collects floor_level/frontage as text; the columns are
        numeric. Unparseable text degrades to NULL instead of an insert error."""
        if value is None or value == "":
            return None
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

    def create_owner_draft(self, *, owner_user_id, payload: dict) -> dict:
        """Persist a NEW draft listing (``verification_status='draft'``).

        Drafts are minimally validated: only ``name`` is required (the column
        is NOT NULL); everything else may arrive empty — an incomplete draft
        is the point. Drafts never enter the admin queue: ``is_published``
        stays false and the verification workflow only starts on an explicit
        submit.
        """
        from sitewise.core.exceptions import ConflictError

        name = (payload.get("name") or "").strip()
        if not name:
            raise ConflictError("A draft property needs at least a name.")
        row = self.session.execute(
            text(
                """
                INSERT INTO fyp.rental_properties (
                    owner_user_id, name, property_type, description, address,
                    city, state, postcode, latitude, longitude, rental_price,
                    size_sqft, availability, floor_level, frontage_ft,
                    has_parking, is_fnb_suitable,
                    verification_status, is_published
                ) VALUES (
                    :owner_user_id, :name,
                    COALESCE(NULLIF(:property_type, ''), 'Shop'),
                    NULLIF(:description, ''),
                    NULLIF(:address, ''), NULLIF(:city, ''), NULLIF(:state, ''),
                    NULLIF(:postcode, ''), :latitude, :longitude, :rental_price,
                    :size_sqft, NULLIF(:availability, ''), :floor_level,
                    :frontage_ft, :has_parking, :is_fnb_suitable,
                    'draft', false
                )
                RETURNING id
                """
            ),
            {
                "owner_user_id": str(owner_user_id),
                "name": name[:160],
                "property_type": (payload.get("property_type") or "").strip()[:60],
                "description": payload.get("description"),
                "address": payload.get("address"),
                "city": payload.get("city"),
                "state": payload.get("state"),
                "postcode": (payload.get("postcode") or "").strip()[:5],
                "latitude": payload.get("latitude"),
                "longitude": payload.get("longitude"),
                "rental_price": payload.get("rental_price"),
                "size_sqft": payload.get("size_sqft"),
                "availability": (payload.get("availability") or "").strip()[:60],
                "floor_level": self._numeric(payload.get("floor_level")),
                "frontage_ft": self._numeric(payload.get("frontage_ft")),
                "has_parking": 1 if payload.get("has_parking") else 0,
                "is_fnb_suitable": 1 if payload.get("is_fnb_suitable") else 0,
            },
        )
        new_id = row.scalar_one()
        self.session.commit()
        return self.owner_listing(int(new_id))  # type: ignore[return-value]

    def update_owner_listing(self, property_id: int, fields: dict) -> dict | None:
        """Whitelisted partial update of one owned listing.

        ``psf`` is recomputed whenever price and size are both known, matching
        the create path. Ownership and state-transition rules live in the API
        layer; this method only writes.
        """
        if not fields:
            return self.owner_listing(property_id)
        sets: list[str] = []
        params: dict[str, Any] = {"pid": property_id}
        for column in self._OWNER_WRITABLE:
            if column not in fields:
                continue
            value = fields[column]
            params[column] = value
            if column in ("address", "city", "state", "postcode", "availability",
                          "property_type", "description", "name"):
                sets.append(f"{column} = NULLIF(:{column}, '')")
            elif column in ("floor_level", "frontage_ft"):
                # Numeric columns fed by free-text wizard fields.
                sets.append(f"{column} = :{column}")
                params[column] = self._numeric(value)
            else:
                sets.append(f"{column} = :{column}")
        if "rental_price" in fields or "size_sqft" in fields:
            current = self.owner_listing(property_id) or {}
            price = fields.get("rental_price", current.get("rental_price"))
            size = fields.get("size_sqft", current.get("size_sqft"))
            if price and size and float(size) > 0:
                sets.append("psf = :psf")
                params["psf"] = round(float(price) / float(size), 2)
        if not sets:
            return self.owner_listing(property_id)
        sets.append("updated_at = now()")
        row = self.session.execute(
            text(
                f"UPDATE fyp.rental_properties SET {', '.join(sets)} "
                "WHERE id = :pid RETURNING id"
            ),
            params,
        )
        if row.scalar_one_or_none() is None:
            self.session.rollback()
            return None
        self.session.commit()
        return self.owner_listing(property_id)

    def set_address_validation(
        self,
        property_id: int,
        *,
        status: str,
        formatted_address: str | None,
        latitude: float | None = None,
        longitude: float | None = None,
    ) -> None:
        """Persist a SERVER-obtained Google Address Validation verdict.

        Called INSIDE the caller's transaction (no commit here) so the verdict
        and the lifecycle transition land atomically. Coordinates are replaced
        only when the provider returned a validated premise and real numbers —
        a partial verdict never overwrites the owner's pin.
        """
        sets = [
            "address_validation_status = :status",
            "address_formatted = :formatted",
            "address_validated_at = now()",
            "updated_at = now()",
        ]
        params: dict[str, Any] = {
            "pid": property_id,
            "status": status,
            "formatted": formatted_address,
        }
        if (
            status == "validated"
            and latitude is not None
            and longitude is not None
            and -90 <= float(latitude) <= 90
            and -180 <= float(longitude) <= 180
        ):
            sets.append("latitude = :lat")
            sets.append("longitude = :lon")
            params["lat"] = float(latitude)
            params["lon"] = float(longitude)
        self.session.execute(
            text(
                f"UPDATE fyp.rental_properties SET {', '.join(sets)} "
                "WHERE id = :pid"
            ),
            params,
        )

    def set_listing_verification_status(
        self,
        property_id: int,
        status: str,
        rejection_reason: str | None = None,
    ) -> None:
        """Mirror a lifecycle event onto the listing row.

        Called INSIDE the caller's transaction (no commit here) so the
        verification tables and the listing row land atomically.
        """
        self.session.execute(
            text(
                "UPDATE fyp.rental_properties "
                "SET verification_status = :status, "
                "rejection_reason = :reason, updated_at = now() "
                "WHERE id = :pid"
            ),
            {"pid": property_id, "status": status, "reason": rejection_reason},
        )

    # ------------------------------------------------- property photos

    _PHOTO_SELECT = (
        "SELECT id, property_id, url, caption, is_primary, created_at "
        "FROM fyp.property_photos"
    )

    def listing_photos(self, property_id: int) -> list[dict]:
        """Display photos of one listing, primary first."""
        rows = self.session.execute(
            text(
                f"{self._PHOTO_SELECT} WHERE property_id = :pid "
                "ORDER BY is_primary DESC, id"
            ),
            {"pid": property_id},
        ).mappings().all()
        return [dict(r) for r in rows]

    def add_listing_photo(
        self, property_id: int, url: str, caption: str, is_primary: bool
    ) -> dict:
        """Attach one uploaded photo. The FIRST photo of a listing always
        becomes primary; an explicit primary request demotes the others."""
        photo_count = self.session.execute(
            text(
                "SELECT count(*) FROM fyp.property_photos WHERE property_id = :pid"
            ),
            {"pid": property_id},
        ).scalar_one()
        make_primary = is_primary or photo_count == 0
        if make_primary:
            self.session.execute(
                text(
                    "UPDATE fyp.property_photos SET is_primary = false "
                    "WHERE property_id = :pid"
                ),
                {"pid": property_id},
            )
        row = self.session.execute(
            text(
                "INSERT INTO fyp.property_photos "
                "(property_id, url, caption, is_primary) "
                "VALUES (:pid, :url, :caption, :primary) "
                "RETURNING id, property_id, url, caption, is_primary, created_at"
            ),
            {
                "pid": property_id,
                "url": url,
                "caption": caption or "",
                "primary": make_primary,
            },
        ).mappings().one()
        self.session.commit()
        return dict(row)

    def delete_listing_photo(
        self, property_id: int, photo_id: int
    ) -> dict | None:
        """Remove one photo row; returns the deleted row (for object
        cleanup) or None. Promotes the oldest remaining photo when the
        primary was removed."""
        row = self.session.execute(
            text(
                f"{self._PHOTO_SELECT} WHERE property_id = :pid AND id = :phid "
                "FOR UPDATE"
            ),
            {"pid": property_id, "phid": photo_id},
        ).mappings().first()
        if row is None:
            self.session.rollback()
            return None
        self.session.execute(
            text("DELETE FROM fyp.property_photos WHERE id = :phid"),
            {"phid": photo_id},
        )
        if row["is_primary"]:
            self.session.execute(
                text(
                    "UPDATE fyp.property_photos SET is_primary = true "
                    "WHERE id = (SELECT id FROM fyp.property_photos "
                    "WHERE property_id = :pid ORDER BY id LIMIT 1)"
                ),
                {"pid": property_id},
            )
        self.session.commit()
        return dict(row)

    def set_primary_listing_photo(self, property_id: int, photo_id: int) -> bool:
        """Make one photo primary; returns False when it is not this
        listing's photo."""
        owned = self.session.execute(
            text(
                "SELECT count(*) FROM fyp.property_photos "
                "WHERE id = :phid AND property_id = :pid"
            ),
            {"pid": property_id, "phid": photo_id},
        ).scalar_one()
        if not owned:
            self.session.rollback()
            return False
        self.session.execute(
            text(
                "UPDATE fyp.property_photos SET is_primary = "
                "(id = :phid) WHERE property_id = :pid"
            ),
            {"pid": property_id, "phid": photo_id},
        )
        self.session.commit()
        return True

    # ------------------------------------------------- catalogue integration

    def resolve_reference(self, ref: str) -> dict | None:
        """Resolve a property reference from EITHER id universe.

        * numeric string → ``fyp.rental_properties.id`` (operational table)
        * workbook id (``EP-xxxxx`` / ``MD-xxxxx``) →
          ``sitewise_app.properties.id`` (imported catalogue)

        Both branches return the same coordinate/price shape so downstream
        spatial queries are universe-agnostic.
        """
        ref = (ref or "").strip()
        if not ref:
            return None
        if ref.isdigit():
            row = (
                self.session.execute(
                    text(
                        """
                        SELECT id AS property_id, name, property_type, address,
                               city, state, latitude, longitude, rental_price,
                               size_sqft, 'fyp' AS source_schema
                        FROM fyp.rental_properties
                        WHERE id = :ref
                          AND is_published AND verification_status = 'approved'
                        """
                    ),
                    {"ref": int(ref)},
                )
                .mappings()
                .first()
            )
            return dict(row) if row else None
        row = (
            self.session.execute(
                text(
                    """
                    SELECT id AS property_id, title AS name, property_type,
                           address, city, state, latitude, longitude,
                           rental_rm AS rental_price, size_sqft,
                           suitability_score, 'sitewise_app' AS source_schema
                    FROM sitewise_app.properties WHERE id = :ref
                    """
                ),
                {"ref": ref},
            )
            .mappings()
            .first()
        )
        return dict(row) if row else None

    # --------------------------------------------------------- filter options

    def filter_options(self) -> dict:
        """Distinct filter facet values over the APPROVED + PUBLISHED set.

        Read from the database rather than hardcoded, so a filter can never
        offer an option that silently matches nothing.
        """
        states = [
            r[0]
            for r in self.session.execute(
                text(
                    "SELECT DISTINCT p.state FROM fyp.rental_properties p "
                    f"WHERE {_PUBLISHED_FILTER} AND p.state IS NOT NULL ORDER BY p.state"
                )
            )
        ]
        cities = [
            r[0]
            for r in self.session.execute(
                text(
                    "SELECT DISTINCT p.city FROM fyp.rental_properties p "
                    f"WHERE {_PUBLISHED_FILTER} AND p.city IS NOT NULL ORDER BY p.city"
                )
            )
        ]
        types = [
            r[0]
            for r in self.session.execute(
                text(
                    "SELECT DISTINCT p.property_type FROM fyp.rental_properties p "
                    f"WHERE {_PUBLISHED_FILTER} ORDER BY p.property_type"
                )
            )
        ]
        availability = [
            r[0]
            for r in self.session.execute(
                text(
                    "SELECT DISTINCT p.availability FROM fyp.rental_properties p "
                    f"WHERE {_PUBLISHED_FILTER} AND p.availability IS NOT NULL "
                    "ORDER BY p.availability"
                )
            )
        ]
        total = int(
            self.session.execute(
                text(
                    "SELECT count(*) FROM fyp.rental_properties p "
                    f"WHERE {_PUBLISHED_FILTER}"
                )
            ).scalar_one()
        )
        return {
            "states": states,
            "cities": cities,
            "property_types": types,
            "availability": availability,
            "published_total": total,
        }
