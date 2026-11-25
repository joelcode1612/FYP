-- Exact SQL templates executed by the SiteWise runtime calculators.
-- Source version: expanded64-feature-definitions-v1
-- These are the statements issued by:
--   backend/src/sitewise/ml/coordinate_features.py (road_geometry, population_rings)
--   backend/src/sitewise/ml/expanded64_network.py  (_routed_hull, _hull_population override)
-- Parameters :lon and :lat are the original subject coordinates.
-- No statement writes to the database; all run inside SET TRANSACTION READ ONLY.

-- 1) road_geometry: 500 m road and walkway length density (the two v2 features).
-- Class lists are expanded from expanded64_feature_definitions.py:
--   ALL_CLASSES = ROAD_CLASSES + WALK_CLASSES (living_street appears in both)
--   ROAD_CLASSES = ('motorway','trunk','primary','secondary','tertiary','unclassified',
--                   'residential','living_street','service','motorway_link','trunk_link',
--                   'primary_link','secondary_link','tertiary_link','road')
--   WALK_CLASSES = ('footway','path','steps','pedestrian','corridor','living_street','track')
--   MAJOR_CLASSES = ('motorway','trunk','primary','secondary','motorway_link','trunk_link',
--                    'primary_link','secondary_link')
WITH g AS (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom),
b AS (SELECT geom,
             ST_Buffer(geom::geography, 500)::geometry  AS g500,
             ST_Buffer(geom::geography, 1000)::geometry AS g1000
      FROM g),
c5 AS (SELECT r.highway, ST_Length(ST_Intersection(r.way, b.g500)::geography) AS len
       FROM b JOIN fyp_features.roads_v2 r ON r.way && b.g500
       WHERE r.highway IN ('motorway','trunk','primary','secondary','tertiary','unclassified',
                           'residential','living_street','service','motorway_link','trunk_link',
                           'primary_link','secondary_link','tertiary_link','road',
                           'footway','path','steps','pedestrian','corridor','track')),
c1 AS (SELECT r.highway, ST_Length(ST_Intersection(r.way, b.g1000)::geography) AS len
       FROM b JOIN fyp_features.roads_v2 r ON r.way && b.g1000
       WHERE r.highway IN ('motorway','trunk','primary','secondary','tertiary','unclassified',
                           'residential','living_street','service','motorway_link','trunk_link',
                           'primary_link','secondary_link','tertiary_link','road',
                           'footway','path','steps','pedestrian','corridor','track')),
m AS (SELECT (SELECT sum(len) FILTER (WHERE highway IN ('motorway','trunk','primary','secondary',
              'tertiary','unclassified','residential','living_street','service','motorway_link',
              'trunk_link','primary_link','secondary_link','tertiary_link','road')) FROM c5) AS road_m_500,
             (SELECT sum(len) FILTER (WHERE highway IN ('motorway','trunk','primary','secondary',
              'tertiary','unclassified','residential','living_street','service','motorway_link',
              'trunk_link','primary_link','secondary_link','tertiary_link','road')) FROM c1) AS road_m_1000,
             (SELECT sum(len) FILTER (WHERE highway IN ('footway','path','steps','pedestrian',
              'corridor','living_street','track')) FROM c5) AS walk_m_500),
near AS (SELECT min(ST_Distance(b.geom::geography, r.way::geography)) AS nearest_major_m
         FROM b JOIN fyp_features.roads_v2 r ON r.way && ST_Expand(b.geom, 0.05)
         WHERE r.highway IN ('motorway','trunk','primary','secondary','motorway_link','trunk_link',
                             'primary_link','secondary_link')),
inter AS (SELECT count(j.node)::int AS junctions_500
          FROM b LEFT JOIN fyp_features.road_junctions_v2 j
            ON ST_DWithin(j.geom, b.geom, 0.0045))
SELECT m.road_m_500, m.road_m_1000, m.walk_m_500,
       near.nearest_major_m, inter.junctions_500
FROM m, near, inter;

-- Runtime arithmetic (Python, not SQL):
--   road_length_density_500m_km_km2 = round(road_m_500 / 1000 / 0.785398163, 3)
--   osm_walkway_length_density_500m_km_km2 = round(walk_m_500 / 1000 / 0.785398163, 3)
-- The denominator is the flat research circle, NOT ST_Area(geography buffer).

-- 2) population_rings: whole 100 m pixel by centroid inside 2000 m / 3000 m.
-- Parameters: window=0.045, nodata=-99999, sphere_radius=6378137.0.
WITH o AS (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom),
tiles AS (SELECT ST_Clip(w.rast, ST_Expand(o.geom, :window), true) AS rast
          FROM o, public.worldpop_2025_constrained w
          WHERE w.rast && ST_Expand(o.geom, :window)),
px AS (SELECT (pg.val = :nodata) AS nodata, pg.val AS val,
              ST_DistanceSphere(pg.geom, o.geom, :sphere_radius) AS d
       FROM o, tiles t
       CROSS JOIN LATERAL ST_PixelAsCentroids(t.rast, 1) AS pg(geom, val, p, q))
SELECT count(*) FILTER (WHERE nodata = FALSE)::int AS valid_pixels,
       sum(val) FILTER (WHERE nodata = FALSE AND d <= 500)::float8 AS pop_500m,
       count(*) FILTER (WHERE nodata = FALSE AND d <= 500)::int AS pop_pixels_500m,
       sum(val) FILTER (WHERE nodata = FALSE AND d <= 1000)::float8 AS pop_1000m,
       count(*) FILTER (WHERE nodata = FALSE AND d <= 1000)::int AS pop_pixels_1000m,
       sum(val) FILTER (WHERE nodata = FALSE AND d <= 2000)::float8 AS pop_2000m,
       count(*) FILTER (WHERE nodata = FALSE AND d <= 2000)::int AS pop_pixels_2000m,
       sum(val) FILTER (WHERE nodata = FALSE AND d <= 3000)::float8 AS pop_3000m,
       count(*) FILTER (WHERE nodata = FALSE AND d <= 3000)::int AS pop_pixels_3000m
FROM px;

-- 3) Expanded64CoordinateExtractor._routed_hull: 600 s pedestrian reach hull.
-- The SQL is generated with format(); the edge query below is the generated
-- text for the first subject. Keep the 1200 s search budget and the <=600 s
-- vertex filter exactly as in the runtime calculator.
WITH origin AS (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom),
snap AS (
    SELECT v.vid, v.comp, origin.geom,
           ST_Distance(v.geom::geography, origin.geom::geography) AS stub_m
    FROM origin CROSS JOIN LATERAL (
        SELECT vid, comp, geom FROM public.ur_walknode
        ORDER BY geom <-> origin.geom LIMIT 1
    ) v
    WHERE ST_DWithin(v.geom, origin.geom, 0.025)
),
network AS (
    SELECT *, format(
        'SELECT id, source, target, walk_cost AS cost, walk_reverse_cost AS reverse_cost
         FROM public.psense_edges
         WHERE scomp_walk = %L
           AND cls NOT IN (''motorway'', ''motorway_link'')
           AND ST_DWithin(geom, ST_SetSRID(ST_MakePoint(%L, %L), 4326), 0.025)',
        comp, ST_X(geom), ST_Y(geom)) AS edge_sql
    FROM snap
),
vertices AS (
    SELECT v.geom
    FROM network n
    CROSS JOIN LATERAL pgr_drivingDistance(n.edge_sql, n.vid::bigint, 1200::float8, true) d
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
FROM measured WHERE area > 0;

-- 4) Expanded64CoordinateExtractor._hull_population: area-weighted WorldPop sum.
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
FROM overlap WHERE area > 0;
