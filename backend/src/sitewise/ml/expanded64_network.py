"""Coordinate measurements recovered from the original p_sense training jobs."""
from __future__ import annotations

from sitewise.ml.coordinate_features import (
    GROUP_DRIVE,
    GROUP_ISO,
    GROUP_TRANSIT,
    GROUP_PARKING,
    STATUS_UNAVAILABLE,
    CoordinateFeatureExtractor,
    GroupResult,
    _number,
    _status,
)

_ORIGIN = "SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom"
_WALK_COSTS = "walk_cost AS cost, walk_reverse_cost AS reverse_cost"
_DRIVE_COSTS = "cost, reverse_cost"
_DISTANCE_COSTS = "len_m AS cost, len_m AS reverse_cost"
# Original GTFS snapshot reference date, from gtfs_validation.json.
_GTFS_WEEKDAY = "20261113"


class Expanded64CoordinateExtractor(CoordinateFeatureExtractor):
    """Recover the production recipes without reading subject-specific features."""

    def road_geometry(self, lat: float, lon: float) -> GroupResult:
        result = super().road_geometry(lat, lon)
        road = self._row(f"""
            WITH origin AS ({_ORIGIN}),
            b AS (SELECT ST_Buffer(geom::geography, 1000)::geometry AS geom FROM origin),
            clipped AS (
                SELECT ST_Intersection(r.geom, b.geom) AS line, b.geom AS buffer
                FROM b JOIN public.ur_road r ON ST_Intersects(r.geom, b.geom)
            )
            SELECT round((sum(ST_Length(line::geography)) * 1000
                / max(ST_Area(buffer::geography)))::numeric, 3)::float8 AS density
            FROM clipped WHERE GeometryType(line) IN ('LINESTRING', 'MULTILINESTRING')
            """, {"lat": lat, "lon": lon})
        name = "road_length_density_1km_km_km2"
        result.values[name] = _number(road["density"]) if road else None
        result.sources[name] = (
            "public.ur_road (OSM); clipped line length / geodesic 1 km buffer area"
        )
        if result.values[name] is not None:
            result.status = _status(result)
        return result

    @staticmethod
    def _network(profile: str, costs: str, window: float) -> str:
        walk = profile == "walk"
        nodes = "ur_walknode" if walk else "ur_carnode"
        component = "scomp_walk" if walk else "scomp_strong"
        excluded = "AND cls NOT IN (''motorway'', ''motorway_link'')" if walk else ""
        # format() quotes the generated edge query's typed coordinates and component.
        return f"""
            origin AS ({_ORIGIN}),
            snap AS (
                SELECT v.vid, v.comp, origin.geom,
                       ST_Distance(v.geom::geography, origin.geom::geography) AS stub_m
                FROM origin CROSS JOIN LATERAL (
                    SELECT vid, comp, geom FROM public.{nodes}
                    ORDER BY geom <-> origin.geom LIMIT 1
                ) v
                WHERE ST_DWithin(v.geom, origin.geom, {window})
            ),
            network AS (
                SELECT *, format(
                    'SELECT id, source, target, {costs}
                     FROM public.psense_edges
                     WHERE {component} = %L {excluded}
                       AND ST_DWithin(geom, ST_SetSRID(ST_MakePoint(%L, %L), 4326), {window})',
                    comp, ST_X(geom), ST_Y(geom)) AS edge_sql
                FROM snap
            )
        """

    def _routed_hull(self, lat: float, lon: float, *, walk: bool):
        profile = "walk" if walk else "drive"
        costs = _WALK_COSTS if walk else _DRIVE_COSTS
        window = 0.025 if walk else 0.25
        budget = 1200 if walk else 900
        return self._row(f"""
            WITH {self._network(profile, costs, window)},
            vertices AS (
                SELECT v.geom
                FROM network n
                CROSS JOIN LATERAL pgr_drivingDistance(n.edge_sql, n.vid::bigint, {budget}::float8, true) d
                JOIN public.psense_verts v ON v.vid = d.node
                WHERE d.agg_cost <= 600
            ),
            hull AS (SELECT ST_Multi(ST_ConcaveHull(ST_Collect(geom), 0.90, false)) AS geom,
                            count(*) AS nodes FROM vertices),
            measured AS (
                SELECT nodes, geom, ST_Area(geom::geography) AS area
                FROM hull WHERE GeometryType(geom) = 'MULTIPOLYGON'
            )
            SELECT nodes, round((area / 1e6)::numeric, 4)::float8 AS area,
                   encode(ST_AsEWKB(geom), 'hex') AS hull,
                   (SELECT stub_m FROM snap) AS snap_m
            FROM measured WHERE area > 0
            """, {"lat": lat, "lon": lon})

    def _isochrone(self, lat: float, lon: float, *, walk: bool) -> GroupResult:
        group = GROUP_ISO if walk else GROUP_DRIVE
        profile = "walk" if walk else "drive"
        source = f"public.psense_edges + public.ur_carnode/ur_walknode (OSM pgRouting {profile})"
        result = GroupResult(group, attempted_source=source)
        name = f"{profile}_isochrone_area_10min_km2"
        result.values[name] = None
        row = self._routed_hull(lat, lon, walk=walk)
        if not row:
            result.status = STATUS_UNAVAILABLE
            result.reason = "The original routing graph produced no polygonal 600-second hull"
            return result
        result.values[name] = _number(row["area"])
        result.sources[name] = source
        result.notes.update(nodes=row["nodes"], snap_m=row["snap_m"], hull_ratio=0.90)
        if walk:
            population = self._hull_population(row["hull"])
            result.values["worldpop_walk_reachable_10min"] = population["population"]
            result.sources["worldpop_walk_reachable_10min"] = (
                f"{source} + public.worldpop_2025_constrained; area-weighted intersecting pixels"
            )
            result.notes["worldpop_hull_coverage_pct"] = population["coverage_pct"]
        result.status = _status(result)
        return result

    def isochrone_population(self, lat: float, lon: float) -> GroupResult:
        return self._isochrone(lat, lon, walk=True)

    def drive_isochrone(self, lat: float, lon: float) -> GroupResult:
        return self._isochrone(lat, lon, walk=False)

    def transit_accessibility(self, lat: float, lon: float) -> GroupResult:
        source = "public.psense_edges + public.ug_stop_snap + public.ur_facility/ur_fac_route/ur_fac_service"
        result = GroupResult(GROUP_TRANSIT, attempted_source=source)
        row = self._row(f"""
            WITH {self._network("walk", _DISTANCE_COSTS, 0.030)},
            hit AS (
                SELECT d.node, d.agg_cost + n.stub_m AS distance
                FROM network n
                CROSS JOIN LATERAL pgr_drivingDistance(n.edge_sql, n.vid::bigint, 3000::float8, true) d
            ),
            facilities AS (
                SELECT f.dk, round(min(h.distance + s.snap_m)::numeric, 1) AS distance
                FROM hit h JOIN public.ug_stop_snap s ON s.vid = h.node AND s.snap_m <= 200
                JOIN public.ur_stop_dk d USING (canon_uid)
                JOIN public.ur_facility f USING (dk)
                GROUP BY f.dk
            ),
            counts AS (
                SELECT min(distance)::float8 AS nearest_transit_walk_m,
                       count(*) FILTER (WHERE distance <= 500) AS transit_stops_500m_walk,
                       count(*) FILTER (WHERE distance <= 1000) AS transit_stops_1km_walk
                FROM facilities
            )
            SELECT counts.*,
                   (SELECT count(DISTINCT r.route_uid) FROM facilities f
                    JOIN public.ur_fac_route r USING (dk)
                    WHERE f.distance <= 1000 AND r.ymd = :weekday) AS weekday_transit_routes_1km_walk,
                   (SELECT sum(s.dep_am) FROM facilities f JOIN public.ur_fac_service s USING (dk)
                    WHERE f.distance <= 500) AS weekday_departures_500m_walk_am,
                   EXISTS (SELECT 1 FROM public.ur_facility f, origin o
                           WHERE f.geom && ST_Expand(o.geom, 0.035)
                             AND ST_DWithin(f.geom::geography, o.geom::geography, 3000))
                       AS gtfs_coordinate_covered
            FROM counts WHERE EXISTS (SELECT 1 FROM hit WHERE distance > (SELECT stub_m FROM snap))
            """, {"lat": lat, "lon": lon, "weekday": _GTFS_WEEKDAY})
        if row is None:
            result.status = STATUS_UNAVAILABLE
            result.reason = "No traversable walking network at the coordinate"
            return result
        result.notes["gtfs_coordinate_covered"] = bool(row.pop("gtfs_coordinate_covered"))
        if row["transit_stops_500m_walk"] == 0 and result.notes["gtfs_coordinate_covered"]:
            # Within coverage, a catchment that reaches no facilities has no departures.
            row["weekday_departures_500m_walk_am"] = 0
        result.values = {name: _number(value) for name, value in row.items()}
        result.sources = {name: source for name in row}
        result.status = _status(result)
        return result

    def parking_facilities(self, lat: float, lon: float) -> GroupResult:
        """Rebuild the refined parking workbook measurement from facility geometry."""
        source = "public.psense_parking (kept facilities; OSM and official park-and-ride inventory)"
        result = GroupResult(GROUP_PARKING, attempted_source=source)
        row = self._row(f"""
            WITH origin AS ({_ORIGIN}),
            facilities AS (
                SELECT p.facility_id, min(ST_Distance(p.geom::geography, o.geom::geography)) AS distance
                FROM origin o JOIN public.psense_parking p
                  ON p.geom && ST_Expand(o.geom, 0.034)
                WHERE p.kept AND ST_DWithin(p.geom::geography, o.geom::geography, 3000)
                GROUP BY p.facility_id
            )
            SELECT count(*) FILTER (WHERE distance <= 500) AS parking_facilities_500m,
                   count(*) FILTER (WHERE distance <= 1000) AS parking_facilities_1km,
                   round(min(distance)::numeric, 1)::float8 AS nearest_parking_distance_m
            FROM facilities HAVING count(*) > 0
            """, {"lat": lat, "lon": lon})
        if row is None:
            result.status = STATUS_UNAVAILABLE
            result.reason = "No kept parking facility within 3 km"
            return result
        result.values = {name: _number(value) for name, value in row.items()}
        result.sources = {name: source for name in row}
        result.status = _status(result)
        return result

    def _hull_population(self, hull_hex: str):
        """Explicit pixel-window overlay from the original p_pop/u_pop scripts."""
        row = self._row("""
            WITH hull AS (SELECT ST_GeomFromEWKB(decode(:hull, 'hex')) AS geom),
            tiles AS (
                SELECT w.rast, h.geom, m.*
                FROM hull h JOIN public.worldpop_2025_constrained w ON ST_Intersects(w.rast, h.geom)
                CROSS JOIN LATERAL ST_Metadata(w.rast) m
            ),
            cells AS (
                SELECT t.geom, ST_Value(t.rast, i, j) AS val,
                       ST_PixelAsPolygon(t.rast, i, j) AS cell
                FROM tiles t
                CROSS JOIN LATERAL generate_series(
                    greatest(1, floor((ST_XMin(geom) - upperleftx) / scalex + 1)::int),
                    least(width, ceil((ST_XMax(geom) - upperleftx) / scalex + 1)::int)
                ) i
                CROSS JOIN LATERAL generate_series(
                    greatest(1, floor((upperlefty - ST_YMax(geom)) / -scaley + 1)::int),
                    least(height, ceil((upperlefty - ST_YMin(geom)) / -scaley + 1)::int)
                ) j
            ),
            overlap AS (
                SELECT *, ST_Area(ST_Intersection(geom, cell)) AS area
                FROM cells WHERE val IS NOT NULL AND ST_Intersects(geom, cell)
            )
            SELECT round(sum(val * area / NULLIF(ST_Area(cell), 0))::numeric, 3)::float8 AS population,
                   round((100 * sum(area) / NULLIF(max(ST_Area(geom)), 0))::numeric, 2)::float8
                       AS coverage_pct
            FROM overlap WHERE area > 0
            """, {"hull": hull_hex})
        return row or {"population": None, "coverage_pct": None}
