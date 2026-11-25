"""Coordinate-based extraction of the geospatial features a new listing needs.

The features below existed only as stored research values reachable through a
verified ``subject_id`` link, which a newly created listing can never have. Each
method here re-runs the *original* research definition — the arithmetic that
produced the columns the active model was trained on — against the
property-agnostic source tables in local PostGIS, so a new listing is measured
the same way the model was taught:

============================  =================================================
group                         source
============================  =================================================
:meth:`road_geometry`         ``fyp_features.roads_v2`` + ``road_junctions_v2``
:meth:`transit_accessibility` ``we_edges`` pgrouting tree + ``stop_snap`` + GTFS
:meth:`isochrone_population`  concave hull of the walk tree + WorldPop raster
:meth:`drive_isochrone`       ``public.psense_edges`` drive tree + hull
:meth:`residential_density`   ``public.planet_osm_polygon`` building/landuse
:meth:`population_rings`      ``public.worldpop_2025_constrained`` pixel centres
:meth:`demand_generator_pois` ``demand_gen.pois_master`` categories
:meth:`competitor_counts`     ``fnb_a.outlets`` + classified ``fnb_class``
:meth:`parking_facilities`    ``public.psense_parking`` de-duplicated facilities
============================  =================================================

Nothing here depends on the research dataset, on ``subject_id``, or on another
property's stored values. A feature that cannot be measured comes back ``None``
with the source that was attempted and why it failed; it is never imputed with
zero and never copied from a neighbouring property. Groups are independent, so a
failed raster or routing lookup blanks only its own features.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from math import isfinite
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

#: Class lists exactly as the research pipeline defines them.
ROAD_CLASSES = (
    "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
    "residential", "living_street", "service", "motorway_link", "trunk_link",
    "primary_link", "secondary_link", "tertiary_link", "road",
)
MAJOR_CLASSES = (
    "motorway", "trunk", "primary", "secondary", "motorway_link", "trunk_link",
    "primary_link", "secondary_link",
)
WALK_CLASSES = ("footway", "path", "steps", "pedestrian", "corridor", "living_street", "track")
ALL_CLASSES = tuple(dict.fromkeys(ROAD_CLASSES + WALK_CLASSES))
RESIDENTIAL_BUILDING_TAGS = (
    "apartments", "detached", "house", "semidetached_house", "residential", "terrace",
)

#: Flat circle areas used by the research workbook (not the geodesic area).
CIRCLE_500_KM2 = 0.785398163
CIRCLE_1000_KM2 = 3.141592654

#: Walk tree: 900 s over ``cost_s``; metres derived with the 1.35 stride factor.
WALK_TREE_SECONDS = 900.0
WALK_M_PER_SECOND = 1.35
#: ``STEP nearest_ext``: Dijkstra to stops within 0.03 deg when the tree is empty.
NEAREST_EXTENSION_DEG = 0.03
#: GTFS stop platforms are only trusted when snapped to the network within this.
STOP_SNAP_MAX_M = 200
#: ``STEP b`` weekday morning peak window (07:00-09:00).
AM_PEAK_START_S = 25200
AM_PEAK_END_S = 32400

#: ``recover_accessibility.py`` drive tree (psense graph, seconds, 10 min hull).
DRIVE_GRAPH = "public.psense_edges"
DRIVE_TREE_SECONDS = 900.0
DRIVE_WINDOW_DEG = 0.50
ISO_10MIN_S = 600.0
HULL_RATIO = 0.90
#: A vertex further out than this share of the window radius means the window
#: clipped the tree, so the hull would be a partial measurement.
WINDOW_TRUNCATION_FACTOR = 0.92

GROUP_ROAD = "road_geometry"
GROUP_TRANSIT = "transit_accessibility"
GROUP_ISO = "isochrone_population"
GROUP_DRIVE = "drive_isochrone"
GROUP_RESIDENTIAL = "residential_density"
GROUP_POPULATION = "population_rings"
GROUP_POI = "demand_generator_pois"
GROUP_COMPETITORS = "competitor_counts"
GROUP_PARKING = "parking_facilities"
GROUPS = (
    GROUP_ROAD,
    GROUP_TRANSIT,
    GROUP_ISO,
    GROUP_DRIVE,
    GROUP_RESIDENTIAL,
    GROUP_POPULATION,
    GROUP_POI,
    GROUP_COMPETITORS,
    GROUP_PARKING,
)

#: WorldPop inclusion rule and raster version recorded on the research table.
POP_RADII = (500, 1000, 2000, 3000)
POP_NODATA = -99999
POP_SPHERE_RADIUS_M = 6378137.0
POP_WINDOW_DEG = 0.045
POP_INCLUSION_RULE = (
    "PIXEL_CENTRE_INSIDE_HAVERSINE_RADIUS_WHOLE_PIXEL_R6378137M_NODATA_MINUS99999_EXCLUDED")
POP_RASTER_VERSION = "R2025A v1 / mys_pop_2025_CN_100m_R2025A_v1.tif / public.worldpop_2025_constrained"
#: ``demand_gen.pois_master`` categories the model counts, at the model's radii.
POI_CATEGORIES = {
    "office_pois": "OFFICE",
    "schools_count": "SCHOOL",
    "universities_colleges_count": "UNIVERSITY_COLLEGE",
    "retail_pois": "RETAIL",
    "malls_count": "MALL",
    "hospitals_count": "HOSPITAL",
    "supermarkets_count": "SUPERMARKET",
}
POI_RADIUS_LABELS = {"500m": 500, "1000m": 1000}
#: 1 km needs ~0.009° of latitude; 0.012° keeps the box outside every ring.
POI_WINDOW_DEG = 0.012
#: ``recover_competitors.py`` class sets behind the ten competitor features.
COMPETITOR_RADIUS_LABELS = {"500m": 500, "1000m": 1000}
COMPETITOR_CLASS_PREFIXES = {
    "cafe": "cafe",
    "restaurant": "restaurant",
    "fast_food": "fast_food",
}
#: 1 km needs ~0.009°; the outlets are points, so a small margin is enough.
COMPETITOR_WINDOW_DEG = 0.012
BAKERY_DESSERT_BEVERAGE_CLASSES = ("bakery_pastry", "ice_cream_dessert", "beverage_tea_coffee")
#: ``psense_parking`` rows flagged as the survivor of a de-duplicated facility.
#: The box is wider than the 1 km ring so a sparse coordinate still yields a real
#: ``nearest_parking_distance_m`` instead of a truncated one.
PARKING_WINDOW_DEG = 0.05

STATUS_READY = "ready"
STATUS_PARTIAL = "partial"
STATUS_UNAVAILABLE = "unavailable"
STATUS_FAILED = "failed"

_WALK_GRAPH_SQL = ("SELECT id, source, target, cost_s AS cost, cost_s AS reverse_cost "
                   "FROM fyp_features.we_edges")


@dataclass
class GroupResult:
    """One feature group: values, per-feature provenance and failure detail."""

    name: str
    values: dict[str, float | None] = field(default_factory=dict)
    sources: dict[str, str] = field(default_factory=dict)
    status: str = STATUS_FAILED
    reason: str | None = None
    attempted_source: str | None = None
    notes: dict[str, Any] = field(default_factory=dict)

    @property
    def missing(self) -> list[str]:
        return [name for name, value in self.values.items() if value is None]

    def as_dict(self) -> dict[str, Any]:
        """JSON-safe payload for the enrichment category measurement column."""
        return {
            "group": self.name,
            "status": self.status,
            "reason": self.reason,
            "attempted_source": self.attempted_source,
            "values": self.values,
            "sources": self.sources,
            "notes": self.notes,
        }


def _classes(names: tuple[str, ...]) -> str:
    return "(" + ", ".join(f"'{name}'" for name in names) + ")"


def _number(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if isfinite(number) else None


def _round(value: Any, digits: int) -> float | None:
    number = _number(value)
    return None if number is None else round(number, digits)


class CoordinateFeatureExtractor:
    """Measure the research-defined accessibility features at any coordinate."""

    def __init__(self, session: Session) -> None:
        self.session = session
        self._raster_error: str | None = None

    # ------------------------------------------------------------------ roads
    def road_geometry(self, lat: float, lon: float) -> GroupResult:
        """Road/walkway length density, intersection density, nearest major road.

        Clipped geodesic length of the OSM road snapshot inside a 500 m / 1 km
        geography buffer divided by the research flat-circle area, as ``STEP
        roads`` and ``STEP inter`` computed ``road_metrics_v2``. Re-running this
        at reference property EP-01386 reproduces the stored ``road_m_500`` of
        28795.7 m exactly.
        """
        attempted = "fyp_features.roads_v2 + fyp_features.road_junctions_v2 (OpenStreetMap, ODbL)"
        result = GroupResult(GROUP_ROAD, attempted_source=attempted)
        sql = text(f"""
            WITH g AS (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom),
            b AS (SELECT geom,
                         ST_Buffer(geom::geography, 500)::geometry  AS g500,
                         ST_Buffer(geom::geography, 1000)::geometry AS g1000
                  FROM g),
            c5 AS (SELECT r.highway, ST_Length(ST_Intersection(r.way, b.g500)::geography) AS len
                   FROM b JOIN fyp_features.roads_v2 r ON r.way && b.g500
                   WHERE r.highway IN {_classes(ALL_CLASSES)}),
            c1 AS (SELECT r.highway, ST_Length(ST_Intersection(r.way, b.g1000)::geography) AS len
                   FROM b JOIN fyp_features.roads_v2 r ON r.way && b.g1000
                   WHERE r.highway IN {_classes(ALL_CLASSES)}),
            m AS (SELECT (SELECT sum(len) FILTER (WHERE highway IN {_classes(ROAD_CLASSES)}) FROM c5) AS road_m_500,
                          (SELECT sum(len) FILTER (WHERE highway IN {_classes(ROAD_CLASSES)}) FROM c1) AS road_m_1000,
                          (SELECT sum(len) FILTER (WHERE highway IN {_classes(WALK_CLASSES)}) FROM c5) AS walk_m_500),
            near AS (SELECT min(ST_Distance(b.geom::geography, r.way::geography)) AS nearest_major_m
                     FROM b JOIN fyp_features.roads_v2 r ON r.way && ST_Expand(b.geom, 0.05)
                     WHERE r.highway IN {_classes(MAJOR_CLASSES)}),
            inter AS (SELECT count(j.node)::int AS junctions_500
                      FROM b LEFT JOIN fyp_features.road_junctions_v2 j
                        ON ST_DWithin(j.geom, b.geom, 0.0045))
            SELECT m.road_m_500, m.road_m_1000, m.walk_m_500,
                   near.nearest_major_m, inter.junctions_500
            FROM m, near, inter
            """)
        try:
            with self.session.begin_nested():
                row = self.session.execute(sql, {"lat": lat, "lon": lon}).mappings().one()
        except Exception as exc:  # noqa: BLE001 - reported, never faked
            result.reason = f"{type(exc).__name__}: {str(exc)[:240]}"
            return result

        road_m_500 = _number(row["road_m_500"])
        road_m_1000 = _number(row["road_m_1000"])
        walk_m_500 = _number(row["walk_m_500"])
        junctions = _number(row["junctions_500"])
        result.values = {
            "road_length_density_500m_km_km2": None if road_m_500 is None
            else round(road_m_500 / 1000 / CIRCLE_500_KM2, 3),
            "road_length_density_1km_km_km2": None if road_m_1000 is None
            else round(road_m_1000 / 1000 / CIRCLE_1000_KM2, 3),
            "osm_walkway_length_density_500m_km_km2": None if walk_m_500 is None
            else round(walk_m_500 / 1000 / CIRCLE_500_KM2, 3),
            "road_intersection_density_500m_km2": None if junctions is None
            else round(junctions / CIRCLE_500_KM2, 3),
            "nearest_major_road_m": _round(row["nearest_major_m"], 1),
        }
        result.sources = {name: attempted for name in result.values}
        result.notes = {
            "road_m_500": road_m_500,
            "road_m_1000": road_m_1000,
            "walkway_m_500": walk_m_500,
            "junction_count_500m": junctions,
            "denominator": "flat circle area 0.785398163 / 3.141592654 km2 as in the "
                           "research workbook (not geodesic buffer area)",
        }
        result.status = _status(result)
        if result.status == STATUS_UNAVAILABLE:
            result.reason = "no_road_geometry_within_buffer"
        return result

    # ---------------------------------------------------------------- transit
    def transit_accessibility(self, lat: float, lon: float) -> GroupResult:
        """Walk-shed transit counts, nearest stop, weekday routes and departures.

        Re-runs ``STEP stops`` / ``STEP a`` / ``STEP b`` / ``STEP nearest_ext``
        for a single coordinate: snap to the walk network, take the 900 s
        ``pgr_drivingDistance`` tree over ``we_edges.cost_s``, convert seconds to
        metres with the 1.35 stride factor, and count *distinct stop coordinates
        rounded to 4 dp* (the research's facility dedup), never stop ids.
        """
        attempted = ("fyp_features.we_edges + stop_snap + gtfs_stop_routes + gtfs_dep "
                     "(OpenStreetMap walk network, official GTFS feeds)")
        result = GroupResult(GROUP_TRANSIT, attempted_source=attempted)
        start_node, snap_m = self._walk_start_node(lat, lon)
        if start_node is None:
            result.status = STATUS_UNAVAILABLE
            result.reason = "NO_WALK_NETWORK_REACHABLE_FROM_COORDINATE"
            return result
        result.notes = {
            "start_node": start_node,
            "snap_m": snap_m,
            "walk_tree_seconds": WALK_TREE_SECONDS,
            "metres_per_walk_second": WALK_M_PER_SECOND,
        }
        sql = text(f"""
            WITH reach AS (
                SELECT d.node AS node_id, d.agg_cost
                FROM pgr_drivingDistance('{_WALK_GRAPH_SQL}',
                    CAST(:start_node AS bigint), CAST({WALK_TREE_SECONDS} AS float8), false) d),
            w AS (SELECT ss.stop_uid, ss.mode, ss.geom,
                         r.agg_cost * {WALK_M_PER_SECOND} AS walk_m
                  FROM reach r
                  JOIN fyp_features.stop_snap ss ON ss.node_id = r.node_id
                  WHERE ss.snap_m <= {STOP_SNAP_MAX_M} AND r.agg_cost <= {WALK_TREE_SECONDS}),
            dedup AS (SELECT walk_m, mode, stop_uid,
                             round(ST_Y(geom)::numeric, 4) || ',' || round(ST_X(geom)::numeric, 4) AS dk
                      FROM w),
            cnt AS (SELECT count(DISTINCT CASE WHEN walk_m <= 500  THEN dk END)::int AS tr500,
                           count(DISTINCT CASE WHEN walk_m <= 1000 THEN dk END)::int AS tr1000,
                           min(walk_m) AS nearest_s
                    FROM dedup),
            act AS (SELECT DISTINCT route_uid FROM fyp_features.gtfs_active_trips
                    WHERE daytype = 'WEEKDAY'),
            rt AS (SELECT count(DISTINCT sr.route_uid)::int AS routes_1km
                   FROM (SELECT DISTINCT stop_uid, walk_m FROM dedup WHERE walk_m <= 1000) s
                   JOIN fyp_features.gtfs_stop_routes sr ON sr.stop_uid = s.stop_uid
                   JOIN act a ON a.route_uid = sr.route_uid),
            dp AS (SELECT count(*)::int AS dep_am
                   FROM (SELECT DISTINCT stop_uid FROM dedup WHERE walk_m <= 500) s
                   JOIN fyp_features.gtfs_dep d ON d.stop_uid = s.stop_uid
                   WHERE d.daytype = 'WEEKDAY'
                     AND d.dep_s BETWEEN {AM_PEAK_START_S} AND {AM_PEAK_END_S})
            SELECT cnt.tr500, cnt.tr1000, cnt.nearest_s, rt.routes_1km, dp.dep_am,
                   (SELECT count(*) FROM reach) AS tree_nodes
            FROM cnt, rt, dp
            """)
        try:
            with self.session.begin_nested():
                row = self.session.execute(sql, {"start_node": start_node}).mappings().one()
        except Exception as exc:  # noqa: BLE001
            result.reason = f"{type(exc).__name__}: {str(exc)[:240]}"
            return result

        result.notes["walk_tree_nodes"] = _number(row["tree_nodes"])
        nearest_m = _number(row["nearest_s"])
        routes_1km = _number(row["routes_1km"])
        dep_am = _number(row["dep_am"])
        values = {
            "transit_stops_500m_walk": _number(row["tr500"]),
            "transit_stops_1km_walk": _number(row["tr1000"]),
            # ``min(walk_m)`` is already metres (agg_cost * 1.35 in STEP stops).
            "nearest_transit_walk_m": None if nearest_m is None else round(nearest_m, 1),
            "weekday_transit_routes_1km_walk": routes_1km,
            "weekday_departures_500m_walk_am": dep_am,
        }
        if nearest_m is None:
            # STEP nearest_ext: the walk tree reaches no stop, so route to the
            # stops within 0.03 deg — how the research measured rural subjects
            # whose nearest stop is kilometres away. Routes/departures stay 0
            # because a stop outside the 900 s shed contributes no shed service.
            extension = self._nearest_extension_seconds(start_node, lat, lon)
            result.notes["nearest_extension_used"] = extension is not None
            if extension is not None:
                values["nearest_transit_walk_m"] = round(extension * WALK_M_PER_SECOND, 1)
                values["weekday_transit_routes_1km_walk"] = 0.0
                values["weekday_departures_500m_walk_am"] = 0.0
        result.values = values
        result.sources = {name: attempted for name in values}
        result.status = _status(result)
        if result.status != STATUS_READY:
            result.reason = ("NO_TRANSIT_STOP_WITHIN_WALK_TREE_OR_3KM_EXTENSION"
                             if values["nearest_transit_walk_m"] is None
                             else "partial_transit_coverage")
        return result

    def _nearest_extension_seconds(self, start_node: int, lat: float, lon: float) -> float | None:
        row = self._row(f"""
            WITH ends AS (SELECT array_agg(DISTINCT ss.node_id) AS nodes
                          FROM fyp_features.stop_snap ss
                          CROSS JOIN (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom) p
                          WHERE ss.snap_m <= {STOP_SNAP_MAX_M}
                            AND ST_DWithin(ss.geom, p.geom, {NEAREST_EXTENSION_DEG})),
            d AS (SELECT e.end_vid, e.agg_cost
                  FROM ends, pgr_dijkstra('{_WALK_GRAPH_SQL}', CAST(:start_node AS bigint),
                                          ends.nodes, false) e
                  WHERE e.end_vid IS NOT NULL AND e.node = e.end_vid)
            SELECT round(min(agg_cost)::numeric, 1)::float8 AS nearest_s, count(*) AS routes
            FROM d
            """, {"start_node": start_node, "lat": lat, "lon": lon})
        if row is None:
            return None
        return _number(row["nearest_s"])

    # --------------------------------------------------------------- isochrone
    def isochrone_population(self, lat: float, lon: float) -> GroupResult:
        """10-minute walk-shed area and the population reachable inside it.

        ``STEP iso`` hull (concave, ratio 0.90, vertices reached within 600 s of
        the walk tree) and ``STEP worldpop`` area-weighted partial-pixel WorldPop
        sum. The raster sum runs separately so that a missing or unreadable
        raster tile still leaves the measured area in place.
        """
        attempted = "fyp_features.we_edges walk tree + public.worldpop_2025_constrained (WorldPop, CC-BY-4.0)"
        result = GroupResult(GROUP_ISO, attempted_source=attempted)
        start_node, snap_m = self._walk_start_node(lat, lon)
        if start_node is None:
            result.status = STATUS_UNAVAILABLE
            result.reason = "NO_WALK_NETWORK_REACHABLE_FROM_COORDINATE"
            return result
        row = self._row(f"""
            WITH reach AS (
                SELECT d.node AS node_id, d.agg_cost
                FROM pgr_drivingDistance('{_WALK_GRAPH_SQL}',
                    CAST(:start_node AS bigint), CAST({WALK_TREE_SECONDS} AS float8), false) d),
            pts AS (SELECT v.geom, r.agg_cost
                    FROM reach r JOIN fyp_features.walk_vertices v ON v.node_id = r.node_id),
            o AS (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom),
            far AS (SELECT max(ST_Distance(p.geom::geography, o.geom::geography))::float8 AS far_m
                    FROM pts p, o),
            h AS (SELECT ST_Multi(ST_ConcaveHull(ST_Collect(geom) FILTER (WHERE agg_cost <= {ISO_10MIN_S}),
                                                 {HULL_RATIO}, false)) AS g600,
                         count(*) FILTER (WHERE agg_cost <= {ISO_10MIN_S})::int AS n600,
                         count(*)::int AS n, max(agg_cost)::float8 AS max_s
                  FROM pts)
            SELECT h.n, h.n600, h.max_s, far.far_m,
                   round((ST_Area(h.g600::geography) / 1e6)::numeric, 4)::float8 AS area_km2,
                   encode(ST_AsEWKB(h.g600), 'hex') AS hull
            FROM h, far
            """, {"start_node": start_node, "lat": lat, "lon": lon})
        if row is None:
            result.status = STATUS_FAILED
            result.reason = "walk tree from the snap node returned no vertices"
            return result
        vertices = _number(row["n"]) or 0
        far_m = _number(row["far_m"])
        result.notes = {
            "start_node": start_node,
            "snap_m": snap_m,
            "walk_tree_nodes": vertices,
            "hull_nodes_10min": _number(row["n600"]),
            "max_walk_seconds": _round(row["max_s"], 1),
            "furthest_vertex_m": far_m,
            "concave_hull_ratio": HULL_RATIO,
        }
        area = _round(row["area_km2"], 4)
        result.values = {"walk_isochrone_area_10min_km2": area}
        result.sources = {"walk_isochrone_area_10min_km2": "fyp_features.we_edges walk tree (OSM, ODbL)"}
        hull = row["hull"]
        if area is None:
            result.reason = "ISO_HULL_FAILED" if vertices >= 3 else "ISO_TOO_FEW_NODES"
        if hull:
            population = self._hull_population(hull)
            result.values["worldpop_walk_reachable_10min"] = population["population"]
            result.sources["worldpop_walk_reachable_10min"] = (
                "public.worldpop_2025_constrained (WorldPop 2025 constrained, CC-BY-4.0)")
            result.notes["worldpop_hull_coverage_pct"] = population["coverage_pct"]
            if population["population"] is None:
                detail = self._raster_error or "no_worldpop_raster_under_hull"
                result.reason = f"{result.reason}; {detail}" if result.reason else detail
        result.status = _status(result)
        return result

    def _hull_population(self, hull_hex: str) -> dict[str, float | None]:
        """Area-weighted WorldPop sum over a hull (``STEP worldpop`` method)."""
        try:
            row = self._row("""
                WITH h AS (SELECT ST_SetSRID(ST_GeomFromWKB(decode(:hull, 'hex')), 4326) AS g,
                                 ST_Area(ST_SetSRID(ST_GeomFromWKB(decode(:hull, 'hex')), 4326)::geography)
                                     AS area_m2),
                px AS (SELECT pg.val AS val, pg.geom AS geom
                       FROM h, public.worldpop_2025_constrained w
                       CROSS JOIN LATERAL ST_Clip(w.rast, ST_Expand(h.g, 0.01), true) AS c(rast)
                       CROSS JOIN LATERAL ST_PixelAsPolygons(c.rast, 1, true) AS pg(geom, val, p, q)
                       WHERE ST_Intersects(w.rast, h.g) AND ST_Intersects(pg.geom, h.g)),
                frac AS (SELECT sum(val * ST_Area(ST_Intersection(px.geom, h.g)) / ST_Area(px.geom)) AS pop,
                                 sum(ST_Area(ST_Intersection(px.geom, h.g)) / ST_Area(px.geom)) AS covered
                          FROM px, h)
                SELECT round(frac.pop::numeric, 1)::float8 AS population,
                       round((frac.covered * 10000.0 / greatest(h.area_m2, 1))::numeric, 2)::float8
                           AS coverage_pct
                FROM frac, h
                """, {"hull": hull_hex})
        except Exception as exc:  # noqa: BLE001 - the area stays valid without the raster
            self._raster_error = f"{type(exc).__name__}: {str(exc)[:200]}"
            return {"population": None, "coverage_pct": None}
        if row is None:
            return {"population": None, "coverage_pct": None}
        return {"population": _number(row["population"]), "coverage_pct": _number(row["coverage_pct"])}

    # ------------------------------------------------------------- drive isochrone
    def drive_isochrone(self, lat: float, lon: float) -> GroupResult:
        """10-minute drive-shed area from the routed drive graph.

        The research column came from ``recover_accessibility.py`` (the v2
        workbook left it empty): snap to the psense drive network, take the 900 s
        tree with ``directed => true`` over the origin's strongly connected
        component inside a 0.5 deg window, and measure the concave hull of the
        vertices reachable within 600 s.
        """
        attempted = f"{DRIVE_GRAPH} + public.psense_verts (OpenStreetMap drive graph, ODbL)"
        result = GroupResult(GROUP_DRIVE, attempted_source=attempted)
        snap = self._row("""
            WITH o AS (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS g),
            e AS (SELECT e.source, e.target, e.scomp_strong, o.g
                  FROM o, public.psense_edges e
                  WHERE e.scomp_strong IS NOT NULL AND ST_DWithin(e.geom, o.g, :deg)
                  ORDER BY e.geom <-> o.g LIMIT 1)
            SELECT v.vid, e.scomp_strong AS comp,
                   round(ST_Distance(v.geom::geography, e.g::geography)::numeric, 1)::float8 AS snap_m
            FROM e, public.psense_verts v
            WHERE v.vid IN (e.source, e.target)
            ORDER BY v.geom <-> e.g LIMIT 1
            """, {"lat": lat, "lon": lon, "deg": DRIVE_WINDOW_DEG})
        if snap is None:
            result.status = STATUS_UNAVAILABLE
            result.reason = "SOURCE_NOT_COVERED: no drive-network edge within the search window"
            return result
        row = self._row(f"""
            WITH t AS (SELECT d.node::int AS vid, d.agg_cost AS sec
                       FROM pgr_drivingDistance(
                         'SELECT id, source, target, cost, reverse_cost FROM public.psense_edges
                           WHERE scomp_strong = :comp
                             AND ST_DWithin(geom, ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :deg)',
                         CAST(:vid AS bigint), CAST({DRIVE_TREE_SECONDS} AS float8), true) d),
            p AS (SELECT v.geom, t.sec,
                         ST_Distance(v.geom::geography,
                                     ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography) AS far
                  FROM t JOIN public.psense_verts v ON v.vid = t.vid),
            h AS (SELECT ST_Multi(ST_ConcaveHull(ST_Collect(geom) FILTER (WHERE sec <= {ISO_10MIN_S}),
                                                 {HULL_RATIO}, false)) AS g600,
                         count(*) FILTER (WHERE sec <= {ISO_10MIN_S})::int AS n600,
                         count(*)::int AS n, max(far)::float8 AS far_m
                  FROM p)
            SELECT n, n600, round(far_m::numeric, 1)::float8 AS far_m,
                   round((ST_Area(g600::geography) / 1e6)::numeric, 4)::float8 AS area_km2
            FROM h
            """, {"comp": int(snap["comp"]), "vid": int(snap["vid"]), "lat": lat, "lon": lon,
                  "deg": DRIVE_WINDOW_DEG})
        if row is None:
            result.status = STATUS_FAILED
            result.reason = "drive tree query returned no rows"
            return result
        far_m = _number(row["far_m"])
        result.notes = {
            "drive_vertex": int(snap["vid"]),
            "drive_snap_m": _number(snap["snap_m"]),
            "drive_reachable_vertices": _number(row["n"]),
            "hull_nodes_10min": _number(row["n600"]),
            "furthest_vertex_m": far_m,
            "window_truncation_suspected": bool(
                far_m is not None and far_m > DRIVE_WINDOW_DEG * 111320 * WINDOW_TRUNCATION_FACTOR),
        }
        area = _round(row["area_km2"], 4)
        result.values = {"drive_isochrone_area_10min_km2": area}
        result.sources = {"drive_isochrone_area_10min_km2": attempted}
        result.status = _status(result)
        if result.status == STATUS_UNAVAILABLE:
            result.reason = ("ISO_TOO_FEW_NODES" if (row["n"] or 0) < 3 else "ISO_HULL_FAILED")
        return result

    # -------------------------------------------------------------- residential
    def residential_density(self, lat: float, lon: float) -> GroupResult:
        """Residential building counts, density and footprint/landuse coverage.

        The method locked in ``Sitewise_Residential_Density``: geodesic buffer
        with 32 quadrant segments, ``COUNT(DISTINCT osm_id)`` over the six
        residential building tags, ``ST_UnaryUnion`` before area, density per km²
        and coverage as a percentage of the *buffer* area clipped to 100. When the
        ring holds no building polygon at all the features stay ``None`` — these
        eight are the only ones the model is designed to impute with its own
        median plus missingness indicator, so an honest gap costs nothing while a
        fabricated zero would distort the score.
        """
        attempted = "public.planet_osm_polygon (OpenStreetMap building/landuse, ODbL)"
        result = GroupResult(GROUP_RESIDENTIAL, attempted_source=attempted)
        names = [f"residential_building_count_{r}" for r in ("500m", "1000m")] \
            + [f"residential_building_density_{r}_km2" for r in ("500m", "1000m")] \
            + [f"residential_footprint_coverage_{r}_pct" for r in ("500m", "1000m")] \
            + [f"residential_landuse_coverage_{r}_pct" for r in ("500m", "1000m")]
        result.values = {name: None for name in names}
        result.sources = {name: attempted for name in names}
        result.notes = {"residential_building_tag_set": list(RESIDENTIAL_BUILDING_TAGS)}
        # Match classify_residential_quality.py: a zero at either radius is
        # trusted only when the 500 m ring itself establishes confirmed zero.
        inner = self._residential_radius(lat, lon, 500)
        outer = self._residential_radius(lat, lon, 1000)
        confirmed_zero = bool(
            inner and inner["res_count"] == 0 and inner["any_building"] >= 10
        )
        for suffix, row in (("500m", inner), ("1000m", outer)):
            if row is None:
                continue
            count = _number(row["res_count"])
            area = _number(row["buffer_area_m2"])
            result.notes[f"any_building_count_{suffix}"] = row["any_building"]
            if count is None or not area or (count == 0 and not confirmed_zero):
                continue
            result.values[f"residential_building_count_{suffix}"] = count
            result.values[f"residential_building_density_{suffix}_km2"] = round(
                count / (area / 1e6), 2
            )
            for field, metric in (
                ("footprint_area_m2", "footprint"), ("landuse_area_m2", "landuse")
            ):
                # The original union-area aggregate reports measured absence
                # as zero once the radius has passed the coverage gate.
                surface = _number(row[field]) if row[field] is not None else 0.0
                if surface is not None:
                    result.values[f"residential_{metric}_coverage_{suffix}_pct"] = round(
                        min(100.0, 100.0 * surface / area), 3
                    )
        result.status = _status(result)
        if result.status != STATUS_READY:
            result.reason = "residential polygon data missing or sparse under training coverage rules"
        return result

    def _residential_radius(self, lat: float, lon: float, radius: int) -> dict[str, Any] | None:
        sql = text(f"""
            WITH b AS (SELECT ST_Buffer(ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                                        :radius, 32)::geometry AS buf),
            ix AS (SELECT p.osm_id,
                          (p.building IN {_classes(RESIDENTIAL_BUILDING_TAGS)}) AS is_res,
                          (p.landuse = 'residential') AS is_lu,
                          (p.building IS NOT NULL AND p.building <> 'no') AS is_bldg,
                          CASE WHEN p.building IN {_classes(RESIDENTIAL_BUILDING_TAGS)}
                                 OR p.landuse = 'residential'
                               THEN ST_Intersection(p.way, b.buf) END AS geom
                  FROM b JOIN public.planet_osm_polygon p ON p.way && b.buf
                  WHERE ((p.building IS NOT NULL AND p.building <> 'no')
                         OR p.landuse = 'residential')
                    AND ST_Intersects(p.way, b.buf))
            SELECT (SELECT ST_Area(buf::geography) FROM b) AS buffer_area_m2,
                   count(DISTINCT osm_id) FILTER (WHERE is_res)::int AS res_count,
                   count(DISTINCT osm_id) FILTER (WHERE is_bldg)::int AS any_building,
                   count(*) FILTER (WHERE is_lu)::int AS landuse_polygons,
                   ST_Area(ST_UnaryUnion(ST_Collect(geom) FILTER (WHERE is_res))::geography)
                       AS footprint_area_m2,
                   ST_Area(ST_UnaryUnion(ST_Collect(geom) FILTER (WHERE is_lu))::geography)
                       AS landuse_area_m2
            FROM ix
            """)
        try:
            with self.session.begin_nested():
                row = self.session.execute(
                    sql, {"lat": lat, "lon": lon, "radius": radius}
                ).mappings().first()
        except Exception:  # noqa: BLE001 - this group is model-imputable, never fatal
            return None
        if row is None:
            return None
        # ``count`` over zero rows is 0 while the ring genuinely has no polygons;
        # only report a residential count when some building/landuse was seen.
        if (row["any_building"] or 0) == 0 and (row["landuse_polygons"] or 0) == 0:
            row = dict(row)
            row["res_count"] = None
        return dict(row)

    # ------------------------------------------------------------- population
    def population_rings(self, lat: float, lon: float) -> GroupResult:
        """WorldPop population inside 500 m, 1, 2 and 3 km metre-radius rings.

        The research columns carry their own inclusion rule
        (``sw_positive_fnb_population_features.worldpop_pixel_inclusion_rule``):
        *PIXEL_CENTRE_INSIDE_HAVERSINE_RADIUS_WHOLE_PIXEL_R6378137M_NODATA_
        MINUS99999_EXCLUDED*. A 100 m pixel therefore contributes its whole
        population value when its centre lies within a haversine buffer of the
        exact radius (the training scripts specify a 6378137 m sphere), and
        NoData never contributes. This is deliberately *not* the area-weighted
        partial-pixel sum the geodesic buffer used before, which lands 1-4 %
        away from the values the model was trained on.
        """
        attempted = "public.worldpop_2025_constrained (WorldPop R2025A v1 MYS 2025 constrained 100 m, CC-BY-4.0)"
        names = [f"pop_{r}m" for r in POP_RADII]
        result = GroupResult(GROUP_POPULATION, attempted_source=attempted)
        result.values = {name: None for name in names}
        result.sources = {name: attempted for name in names}
        select = ",\n                   ".join(
            f"sum(val) FILTER (WHERE nodata = FALSE AND d <= {r})::float8 AS pop_{r}m"
            f", count(*) FILTER (WHERE nodata = FALSE AND d <= {r})::int AS pop_pixels_{r}m"
            for r in POP_RADII
        )
        sql = f"""
            WITH o AS (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom),
            tiles AS (SELECT ST_Clip(w.rast, ST_Expand(o.geom, :window), true) AS rast
                      FROM o, public.worldpop_2025_constrained w
                      WHERE w.rast && ST_Expand(o.geom, :window)),
            px AS (SELECT (pg.val = :nodata) AS nodata, pg.val AS val,
                          ST_DistanceSphere(pg.geom, o.geom, :sphere_radius) AS d
                   FROM o, tiles t
                   CROSS JOIN LATERAL ST_PixelAsCentroids(t.rast, 1) AS pg(geom, val, p, q))
            SELECT count(*) FILTER (WHERE nodata = FALSE)::int AS valid_pixels,
                   {select}
            FROM px
            """
        row = self._row(sql, {"lat": lat, "lon": lon, "window": POP_WINDOW_DEG,
                              "nodata": POP_NODATA, "sphere_radius": POP_SPHERE_RADIUS_M})
        if row is None:  # pragma: no cover - the aggregate always returns one row
            result.status = STATUS_FAILED
            result.reason = "population raster query returned no row"
            return result
        result.notes = {
            "worldpop_pixel_inclusion_rule": POP_INCLUSION_RULE,
            "worldpop_raster_version": POP_RASTER_VERSION,
            "worldpop_window_deg": POP_WINDOW_DEG,
            "worldpop_pixel_note": (
                "ST_PixelAsCentroids enumerates only pixels that carry a value, so the "
                "per-ring counts below are valid-pixel counts and a ring with no valid "
                "pixel is unresolved rather than zero"),
        }
        valid = row["valid_pixels"] or 0
        for radius in POP_RADII:
            name = f"pop_{radius}m"
            result.values[name] = _round(row[name], 1)
            pixels = _number(row[f"pop_pixels_{radius}m"]) or 0
            result.notes[f"worldpop_valid_pixels_{radius}m"] = int(pixels)
        if not valid:
            result.status = STATUS_UNAVAILABLE
            result.reason = (
                f"no WorldPop pixels inside a {POP_WINDOW_DEG}° window; the raster "
                "does not cover this coordinate, so the rings are unresolved rather than zero")
            return result
        result.status = _status(result)
        if result.status == STATUS_PARTIAL:
            result.reason = "no valid WorldPop pixels within one or more ring radii"
        return result

    # ---------------------------------------------------------- demand gen POI
    def demand_generator_pois(self, lat: float, lon: float) -> GroupResult:
        """Office, school, university, retail, mall, hospital and supermarket counts.

        Seven ``demand_gen.pois_master`` categories at 500 m and 1 km, counted with
        the same geography distance the research feature used and the same exact
        ``poi_category`` test. The exactness matters: ``OFFICE`` and
        ``OFFICE_BUILDING`` are separate categories in this table and the model's
        ``office_pois_*`` counts only the former (verified on 200 research
        properties).  No operating-status filter is applied because the research
        feature had none; the in-window row count is recorded so a zero can be
        read as a measurement rather than an assumption.
        """
        attempted = "demand_gen.pois_master (OpenStreetMap + Google Places demand-generator catalogue)"
        names = [f"{stem}_{label}" for stem in POI_CATEGORIES for label in POI_RADIUS_LABELS]
        result = GroupResult(GROUP_POI, attempted_source=attempted)
        result.values = {name: None for name in names}
        result.sources = {
            f"{stem}_{label}": (
                f"demand_gen.pois_master poi_category='{category}' within {metres} m")
            for stem, category in POI_CATEGORIES.items()
            for label, metres in POI_RADIUS_LABELS.items()
        }
        select = ",\n                   ".join(
            f"count(*) FILTER (WHERE cat = '{category}' AND d <= {metres})::int "
            f"AS {stem}_{label}"
            for stem, category in POI_CATEGORIES.items()
            for label, metres in POI_RADIUS_LABELS.items()
        )
        sql = f"""
            WITH o AS (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom),
            near AS (SELECT p.poi_category AS cat,
                          ST_Distance(p.rep_geom::geography, o.geom::geography) AS d
                   FROM o JOIN demand_gen.pois_master p ON p.rep_geom && ST_Expand(o.geom, :window))
            SELECT count(*)::int AS pois_in_window,
                   {select}
            FROM near
            """
        row = self._row(sql, {"lat": lat, "lon": lon, "window": POI_WINDOW_DEG})
        result.notes = {
            "poi_radius_source": "rep_geom geography distance <= 500 / 1000 m",
            "poi_window_deg": POI_WINDOW_DEG,
            "poi_rows_in_window": (row or {}).get("pois_in_window"),
            "poi_status_filter": "none (the research feature applied none beyond category and radius)",
        }
        if row is None:  # pragma: no cover - the aggregate always returns one row
            result.status = STATUS_FAILED
            result.reason = "POI query returned no row"
            return result
        for stem in POI_CATEGORIES:
            for label in POI_RADIUS_LABELS:
                result.values[f"{stem}_{label}"] = _number(row[f"{stem}_{label}"])
        if not row["pois_in_window"]:
            result.status = STATUS_UNAVAILABLE
            result.reason = (
                f"no demand_gen.pois_master rows inside a {POI_WINDOW_DEG}° window; "
                "the POI catalogue does not cover this coordinate")
            return result
        result.status = _status(result)
        return result

    # ------------------------------------------------------------- competitors
    def competitor_counts(self, lat: float, lon: float) -> GroupResult:
        """F&B competitor counts by class at 500 m and 1 km.

        The model's ten ``fnb_*``/``cafe_*``/``restaurant_*``/``fast_food_*``/
        ``bakery_dessert_beverage_*`` columns came from the classified outlet
        catalogue: ``fnb_a.outlets`` supplies the geometry and
        ``rcv_2026_11_09.rx_competitor_outlets`` the ``fnb_class`` label, joined
        on ``candidate_id``. That classification overlay covers all 19,419
        catalogue outlets (verified 1:1, no orphans, national extent), so the
        count at a brand-new coordinate is the same measurement the training
        features were, including the deliberate absence of a status filter.
        ``bakery_dessert_beverage_count_*`` is the union of three classes, exactly
        as ``recover_competitors.py`` defined it.
        """
        attempted = "fnb_a.outlets + rcv_2026_11_09.rx_competitor_outlets (classified F&B outlet catalogue)"
        result = GroupResult(GROUP_COMPETITORS, attempted_source=attempted)
        bdb = _classes(BAKERY_DESSERT_BEVERAGE_CLASSES)
        select = ",\n                   ".join(
            [
                f"count(*) FILTER (WHERE d <= {metres})::int AS fnb_competitors_{label}"
                for label, metres in COMPETITOR_RADIUS_LABELS.items()
            ]
            + [
                f"count(*) FILTER (WHERE cls = '{cls}' AND d <= {metres})::int "
                f"AS {stem}_count_{label}"
                for stem, cls in COMPETITOR_CLASS_PREFIXES.items()
                for label, metres in COMPETITOR_RADIUS_LABELS.items()
            ]
            + [
                f"count(*) FILTER (WHERE cls IN {bdb} AND d <= {metres})::int "
                f"AS bakery_dessert_beverage_count_{label}"
                for label, metres in COMPETITOR_RADIUS_LABELS.items()
            ])
        sql = f"""
            WITH o AS (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom),
            near AS (SELECT x.fnb_class AS cls,
                          ST_Distance(a.geom::geography, o.geom::geography) AS d,
                          (a.permitted_for_ml_dataset IS NOT TRUE) AS restricted
                   FROM o
                   JOIN fnb_a.outlets a ON a.geom && ST_Expand(o.geom, :window)
                   JOIN rcv_2026_11_09.rx_competitor_outlets x ON x.candidate_id = a.candidate_id)
            SELECT count(*)::int AS outlets_in_window,
                   count(*) FILTER (WHERE restricted)::int AS outlets_not_permitted,
                   {select}
            FROM near
            """
        names = (["fnb_competitors_500m", "fnb_competitors_1000m"]
                 + [f"{stem}_count_{label}" for stem in COMPETITOR_CLASS_PREFIXES
                    for label in COMPETITOR_RADIUS_LABELS]
                 + [f"bakery_dessert_beverage_count_{label}"
                    for label in COMPETITOR_RADIUS_LABELS])
        result.values = {name: None for name in names}
        result.sources = {name: attempted for name in names}
        row = self._row(sql, {"lat": lat, "lon": lon, "window": COMPETITOR_WINDOW_DEG})
        result.notes = {
            "competitor_class_filter": "fnb_class equality, no operating-status filter (as in the research feature)",
            "competitor_bakery_dessert_beverage_classes": list(BAKERY_DESSERT_BEVERAGE_CLASSES),
            "competitor_window_deg": COMPETITOR_WINDOW_DEG,
            "competitor_outlets_in_window": (row or {}).get("outlets_in_window"),
            "competitor_outlets_in_window_not_permitted": (row or {}).get("outlets_not_permitted"),
        }
        if row is None:  # pragma: no cover - the aggregate always returns one row
            result.status = STATUS_FAILED
            result.reason = "competitor query returned no row"
            return result
        for name in names:
            result.values[name] = _number(row[name])
        if not row["outlets_in_window"]:
            result.status = STATUS_UNAVAILABLE
            result.reason = (
                f"no classified F&B outlet inside a {COMPETITOR_WINDOW_DEG}° window; "
                "the outlet catalogue does not cover this coordinate")
            return result
        result.status = _status(result)
        return result

    # ----------------------------------------------------------------- parking
    def parking_facilities(self, lat: float, lon: float) -> GroupResult:
        """Parking facility counts at 500 m and 1 km plus the nearest distance.

        ``public.psense_parking`` rows flagged ``kept`` — the survivor of each
        de-duplicated facility. Verified against 120 research properties: ``kept``
        reproduces all three stored features exactly, while every-row counts match
        only 110/89 and an ``amenity='parking'`` filter only 47/22. The search box
        is wider than the 1 km ring so that a sparse area reports a real nearest
        distance instead of a truncated one; a coordinate with no facility in the
        whole box comes back unresolved, never as zero.
        """
        attempted = "public.psense_parking WHERE kept (OpenStreetMap parking, ODbL)"
        names = ["parking_facilities_500m", "parking_facilities_1km", "nearest_parking_distance_m"]
        result = GroupResult(GROUP_PARKING, attempted_source=attempted)
        result.values = {name: None for name in names}
        result.sources = {name: attempted for name in names}
        sql = """
            WITH o AS (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom),
            near AS (SELECT ST_Distance(k.geom::geography, o.geom::geography) AS d
                     FROM o JOIN public.psense_parking k ON k.geom && ST_Expand(o.geom, :window)
                     WHERE k.kept)
            SELECT count(*)::int AS rows_in_window,
                   count(*) FILTER (WHERE d <= 500)::int AS parking_facilities_500m,
                   count(*) FILTER (WHERE d <= 1000)::int AS parking_facilities_1km,
                   min(d)::float8 AS nearest_parking_distance_m
            FROM near
            """
        row = self._row(sql, {"lat": lat, "lon": lon, "window": PARKING_WINDOW_DEG})
        result.notes = {
            "parking_row_filter": "kept (de-duplication survivor), no amenity sub-filter",
            "parking_window_deg": PARKING_WINDOW_DEG,
            "parking_rows_in_window": (row or {}).get("rows_in_window"),
        }
        if row is None:  # pragma: no cover - the aggregate always returns one row
            result.status = STATUS_FAILED
            result.reason = "parking query returned no row"
            return result
        result.values["parking_facilities_500m"] = _number(row["parking_facilities_500m"])
        result.values["parking_facilities_1km"] = _number(row["parking_facilities_1km"])
        nearest = _round(row["nearest_parking_distance_m"], 1)
        if nearest is not None:
            result.values["nearest_parking_distance_m"] = nearest
        if not row["rows_in_window"]:
            result.status = STATUS_UNAVAILABLE
            result.reason = (
                f"no kept psense_parking facility inside a {PARKING_WINDOW_DEG}° window")
            return result
        if nearest is None:  # pragma: no cover - rows_in_window would be non-zero
            result.status = STATUS_PARTIAL
            result.reason = "nearest parking distance could not be measured"
            return result
        result.status = _status(result)
        return result

    # ------------------------------------------------------------------ shared
    def _walk_start_node(self, lat: float, lon: float) -> tuple[int | None, float | None]:
        """Nearest walk-graph vertex that is an endpoint of ``we_edges``, and its distance.

        ``walk_vertices`` is the vertex table of the routed graph: every distinct
        endpoint id in ``we_edges`` resolves there, while ``walk_nodes`` covers
        only a fraction of them.  Snapping there is what makes the start node a
        node the 900 s tree can actually leave.
        """
        cached = getattr(self, "_start_node_cache", None)
        if cached is not None and cached[0] == (lat, lon):
            return cached[1], cached[2]
        snap = self._row("""
            SELECT v.node_id,
                   round(ST_Distance(v.geom, s.geom::geography)::numeric, 1)::float8 AS snap_m
            FROM fyp_features.walk_vertices v
            CROSS JOIN (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom) s
            WHERE EXISTS (SELECT 1 FROM fyp_features.we_edges e
                          WHERE e.source = v.node_id OR e.target = v.node_id)
            ORDER BY v.geom <-> s.geom
            LIMIT 1
            """, {"lat": lat, "lon": lon})
        node = int(snap["node_id"]) if snap else None
        self._start_node_cache = ((lat, lon), node, _number(snap["snap_m"]) if snap else None)
        return node, self._start_node_cache[2]

    def _row(self, sql: str, params: dict[str, Any]) -> dict[str, Any] | None:
        """Run a read-only query and return its first row, or ``None`` when empty.

        A database error is raised, never folded into "no data": §7 requires the
        reported reason to distinguish an unmeasured coordinate from a failed
        query.  ``extract()`` catches the raise per group so one broken source
        cannot erase the features another source produced.
        """
        with self.session.begin_nested():
            found = self.session.execute(text(sql), params).mappings().first()
        return dict(found) if found is not None else None

    def extract(self, lat: float, lon: float, *, selected: set[str] | None = None) -> dict[str, GroupResult]:
        """Run every group, isolating each one's failure from the others."""
        groups = (
            (GROUP_ROAD, self.road_geometry),
            (GROUP_TRANSIT, self.transit_accessibility),
            (GROUP_ISO, self.isochrone_population),
            (GROUP_DRIVE, self.drive_isochrone),
            (GROUP_RESIDENTIAL, self.residential_density),
            (GROUP_POPULATION, self.population_rings),
            (GROUP_POI, self.demand_generator_pois),
            (GROUP_COMPETITORS, self.competitor_counts),
            (GROUP_PARKING, self.parking_facilities),
        )
        results: dict[str, GroupResult] = {}
        for name, runner in groups:
            if selected is not None and name not in selected:
                continue
            try:
                results[name] = runner(lat, lon)
            except Exception as exc:  # noqa: BLE001 - reported, never faked
                failed = GroupResult(name)
                failed.status = STATUS_FAILED
                failed.reason = f"{type(exc).__name__}: {str(exc)[:300]}"
                results[name] = failed
        return results


def _status(result: GroupResult) -> str:
    missing = result.missing
    if not result.values:
        return STATUS_FAILED
    if not missing:
        return STATUS_READY
    if len(missing) == len(result.values):
        return STATUS_UNAVAILABLE
    return STATUS_PARTIAL
