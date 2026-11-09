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

Spatial queries use the existing GIST index on ``fnb_a.fnb_outlet.geom``:
radius predicates run in **geometry space** with a meter→degree conversion
(~111,320 m per degree of latitude; Malaysia spans ~2–3°, error well under
5 % at the 500 m / 1 km scales used), while displayed distances use exact
``ST_DistanceSphere``. A geography cast would bypass the index.
"""

from typing import Any

from sqlalchemy import text
from sqlmodel import Session

# 500 m / 1 km are the documented research radii (property_geospatial_features
# columns); 250 m supports the UI's fine-grained marker view.
_ALLOWED_RADII_M = (250, 500, 1000)
_M_PER_DEGREE = 111_320.0

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

        order = _SORTS.get(params.get("sort") or "newest", _SORTS["newest"])
        where_sql = " AND ".join(where)
        limit = int(params.get("limit") or 24)
        offset = int(params.get("offset") or 0)

        total = self.session.execute(
            text(f"SELECT count(*) FROM fyp.rental_properties p WHERE {where_sql}"),
            args,
        ).scalar_one()

        rows = (
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
        return {
            "data": [dict(row) for row in rows],
            "meta": {"total": int(total), "limit": limit, "offset": offset},
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
    def _radius_clause(radius_m: int) -> tuple[str, dict[str, Any]]:
        if radius_m not in _ALLOWED_RADII_M:
            raise ValueError(f"radius_m must be one of {_ALLOWED_RADII_M}")
        # Geometry-space predicate keeps the GIST index usable; the exact
        # display distance is computed separately with ST_DistanceSphere.
        radius_deg = _meters_to_degrees(radius_m)
        clause = (
            "o.geom IS NOT NULL AND o.in_target_region "
            "AND ST_DWithin(o.geom, ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :rdeg)"
        )
        return clause, {"lat": None, "lon": None, "rdeg": radius_deg}

    def list_competitors(
        self, property_id: int, radius_m: int = 500, limit: int = 50
    ) -> dict:
        """Live F&B competitor outlets within ``radius_m`` of the property.

        Source: ``fnb_a.fnb_outlet`` (19,419 outlets live, GIST-indexed
        geom). Names/locations are real research records — unlike the
        precomputed counts, this returns the actual competitor rows.
        """
        coords = self._coords(property_id)
        if coords is None:
            return {"data": [], "meta": {"radius_m": radius_m, "available": False}}
        lat, lon = coords
        clause, args = self._radius_clause(radius_m)
        args.update({"lat": lat, "lon": lon, "limit": min(int(limit), 100)})
        rows = self.session.execute(
            text(
                f"""
                SELECT * FROM (
                    SELECT DISTINCT ON (o.outlet_key)
                        o.outlet_key, o.outlet_name, o.outlet_category,
                        o.brand, o.addr_street, o.addr_city,
                        o.latitude, o.longitude,
                        ST_DistanceSphere(o.geom,
                            ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)) AS distance_m
                    FROM fnb_a.fnb_outlet o
                    WHERE {clause}
                    ORDER BY o.outlet_key, ST_DistanceSphere(o.geom,
                            ST_SetSRID(ST_MakePoint(:lon, :lat), 4326))
                ) d
                ORDER BY d.distance_m
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

    def competitor_counts(self, lat: float, lon: float) -> dict:
        """Exact live F&B counts at 500 m and 1 km for arbitrary coordinates.

        Used by the cross-universe analysis endpoint: the two radius counts
        are one indexed query each, never loaded for list requests.
        """
        counts: dict[str, int | None] = {}
        for label, radius in (("500m", 500), ("1km", 1000)):
            clause, args = self._radius_clause(radius)
            args.update({"lat": lat, "lon": lon})
            counts[f"competitor_count_{label}"] = int(
                self.session.execute(
                    text(
                        f"SELECT count(*) FROM fnb_a.fnb_outlet o WHERE {clause}"
                    ),
                    args,
                ).scalar_one()
            )
        return counts

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
        rows = self.session.execute(
            text(
                """
                SELECT s.subject_id, s.subject_name, s.subject_category,
                       s.latitude, s.longitude,
                       ST_DistanceSphere(s.geom,
                           ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)) AS distance_m
                FROM demand_gen.subjects s
                WHERE s.geom IS NOT NULL
                  AND ST_DWithin(s.geom,
                      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :rdeg)
                ORDER BY distance_m
                LIMIT :limit
                """
            ),
            {
                "lat": lat,
                "lon": lon,
                "rdeg": _meters_to_degrees(radius_m),
                "limit": min(int(limit), 100),
            },
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
