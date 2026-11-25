# Expanded64_v2 — runtime feature definition handoff to ChatGPT

**Definition version:** `expanded64-feature-definitions-v1`
**Repository state:** `joel` branch, runtime implementation prepared; no model retrained, no training data or artifact modified.

This document is the authoritative handoff for recalculating the historical training features with exactly the definitions the SiteWise runtime uses. The constants are owned by `backend/src/sitewise/ml/expanded64_feature_definitions.py`; the calculators quote below are the live implementations. Do **not** substitute the 1 km `public.ur_road` recipe for the two 500 m features: that recipe belongs to the original Expanded64 artifact and is deliberately left unchanged.

---

## 1. Feature contract (six recovered inputs)

| Feature | Calculator group | Source | Units | Precision |
|---|---|---|---|---|
| `road_length_density_500m_km_km2` | `road_geometry` | `fyp_features.roads_v2` | km road / km² | 3 decimals |
| `osm_walkway_length_density_500m_km_km2` | `road_geometry` | `fyp_features.roads_v2` | km walkway / km² | 3 decimals |
| `pop_2000m` | `population_rings` | `public.worldpop_2025_constrained` | people | 1 decimal |
| `pop_3000m` | `population_rings` | `public.worldpop_2025_constrained` | people | 1 decimal |
| `walk_isochrone_area_10min_km2` | `isochrone_population` (walk) | `public.psense_edges` + `ur_walknode` + `psense_verts` | km² | 4 decimals |
| `worldpop_walk_reachable_10min` | `isochrone_population` (walk) | same hull + `public.worldpop_2025_constrained` | people | 3 decimals (Expanded64 override) |

The other 58 inputs keep their existing definitions. The 12 `pop_age_*` band features and `drive_isochrone_area_10min_km2` are **unchanged**, including WorldPop age-band grouping (`0–14`, `15–24`, `25–34`, `35–49`, `50–64`, `65+`) and the free-flow drive graph (`ur_carnode`, `scomp_strong`, 0.25° window, 900 s budget, 600 s vertex filter).

---

## 2. Road and walkway density at 500 m

**Source file:** `backend/src/sitewise/ml/coordinate_features.py`, `CoordinateFeatureExtractor.road_geometry`.

### Class filters (`expanded64_feature_definitions.py`)

```python
ROAD_CLASSES = (
    "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
    "residential", "living_street", "service", "motorway_link", "trunk_link",
    "primary_link", "secondary_link", "tertiary_link", "road",
)
WALK_CLASSES = (
    "footway", "path", "steps", "pedestrian", "corridor", "living_street", "track",
)
ALL_CLASSES = tuple(dict.fromkeys(ROAD_CLASSES + WALK_CLASSES))  # filter for the CTEs
CIRCLE_500_KM2 = 0.785398163
CIRCLE_1000_KM2 = 3.141592654
JUNCTION_SEARCH_DEG = 0.0045
MAJOR_ROAD_SEARCH_DEG = 0.05
```

### Exact SQL (`:lat`, `:lon` are bound parameters; `IN (...)` lists expanded from the tuples above)

```sql
WITH g AS (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom),
b AS (SELECT geom,
             ST_Buffer(geom::geography, 500)::geometry  AS g500,
             ST_Buffer(geom::geography, 1000)::geometry AS g1000
      FROM g),
c5 AS (SELECT r.highway, ST_Length(ST_Intersection(r.way, b.g500)::geography) AS len
       FROM b JOIN fyp_features.roads_v2 r ON r.way && b.g500
       WHERE r.highway IN (...ALL_CLASSES...)),
c1 AS (SELECT r.highway, ST_Length(ST_Intersection(r.way, b.g1000)::geography) AS len
       FROM b JOIN fyp_features.roads_v2 r ON r.way && b.g1000
       WHERE r.highway IN (...ALL_CLASSES...)),
m AS (SELECT (SELECT sum(len) FILTER (WHERE highway IN (...ROAD_CLASSES...)) FROM c5) AS road_m_500,
              (SELECT sum(len) FILTER (WHERE highway IN (...ROAD_CLASSES...)) FROM c1) AS road_m_1000,
              (SELECT sum(len) FILTER (WHERE highway IN (...WALK_CLASSES...)) FROM c5) AS walk_m_500),
near AS (SELECT min(ST_Distance(b.geom::geography, r.way::geography)) AS nearest_major_m
         FROM b JOIN fyp_features.roads_v2 r ON r.way && ST_Expand(b.geom, 0.05)
         WHERE r.highway IN (...MAJOR_CLASSES...)),
inter AS (SELECT count(j.node)::int AS junctions_500
          FROM b LEFT JOIN fyp_features.road_junctions_v2 j
            ON ST_DWithin(j.geom, b.geom, 0.0045))
SELECT m.road_m_500, m.road_m_1000, m.walk_m_500,
       near.nearest_major_m, inter.junctions_500
FROM m, near, inter
```

### Runtime arithmetic (verbatim)

```python
"road_length_density_500m_km_km2": None if road_m_500 is None
else round(road_m_500 / 1000 / CIRCLE_500_KM2, 3),
"osm_walkway_length_density_500m_km_km2": None if walk_m_500 is None
else round(walk_m_500 / 1000 / CIRCLE_500_KM2, 3),
```

**Geometry and buffer methodology.**
1. Origin is EPSG:4326. The 500 m and 1000 m buffers are **geography** buffers (`ST_Buffer(geom::geography, 500/1000)`) cast back to geometry. Clipping is `ST_Intersection(way, buffer)`; length is `ST_Length(clipped::geography)` in metres.
2. The `&&` operator is only a bounding-box prefilter; it is **not** the inclusion test. Inclusion is the intersection itself, so a line partially inside the buffer contributes exactly its clipped length.
3. **The denominator is the research flat-circle area, not the geodesic buffer area**: `0.785398163 km²` for 500 m and `3.141592654 km²` for 1 km. Do not use `ST_Area(buffer::geography)` for these two features.
4. `living_street` occurs in both `ROAD_CLASSES` and `WALK_CLASSES`; both sums include it. There is no double-count correction.
5. Junctions are counted with `ST_DWithin(j.geom, b.geom, 0.0045)` in **degrees**, not metres; nearest major road uses a 0.05° bbox prefilter and geodesic distance in metres.
6. A `NULL` aggregate (no source geometry in the window) stays `None`. It must not become `0.0` in the training recalculation.

**Do not reuse this for `road_length_density_1km_km_km2`.** The validated original recipe for that feature is `Expanded64CoordinateExtractor.road_geometry` (`backend/src/sitewise/ml/expanded64_network.py:27-47`): `public.ur_road`, no highway filter, `ST_Intersects`, `ST_Length(line::geography) * 1000 / ST_Area(buffer::geography)`, rounded to 3 decimals. It remains untouched.

---

## 3. Population within 2 km and 3 km

**Source file:** `coordinate_features.py`, `CoordinateFeatureExtractor.population_rings`.

### Constants

```python
POP_RADII = (500, 1000, 2000, 3000)
POP_NODATA = -99999
POP_SPHERE_RADIUS_M = 6378137.0
POP_WINDOW_DEG = 0.045
POP_INCLUSION_RULE = (
    "PIXEL_CENTRE_INSIDE_HAVERSINE_RADIUS_WHOLE_PIXEL_R6378137M_NODATA_MINUS99999_EXCLUDED"
)
```

### Exact SQL (the `select` fragment is generated for all four radii)

```sql
WITH o AS (SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom),
tiles AS (SELECT ST_Clip(w.rast, ST_Expand(o.geom, :window), true) AS rast
          FROM o, public.worldpop_2025_constrained w
          WHERE w.rast && ST_Expand(o.geom, :window)),
px AS (SELECT (pg.val = :nodata) AS nodata, pg.val AS val,
              ST_DistanceSphere(pg.geom, o.geom, :sphere_radius) AS d
       FROM o, tiles t
       CROSS JOIN LATERAL ST_PixelAsCentroids(t.rast, 1) AS pg(geom, val, p, q))
SELECT count(*) FILTER (WHERE nodata = FALSE)::int AS valid_pixels,
       sum(val) FILTER (WHERE nodata = FALSE AND d <= 2000)::float8 AS pop_2000m,
       count(*) FILTER (WHERE nodata = FALSE AND d <= 2000)::int AS pop_pixels_2000m,
       sum(val) FILTER (WHERE nodata = FALSE AND d <= 3000)::float8 AS pop_3000m,
       count(*) FILTER (WHERE nodata = FALSE AND d <= 3000)::int AS pop_pixels_3000m
       -- the generated SQL also selects the 500 m and 1000 m analogues
FROM px
```

Parameters: `window = 0.045`, `nodata = -99999`, `sphere_radius = 6378137.0`. Outputs are rounded to **1 decimal** (`round(value, 1)`).

**Methodology.** A whole 100 m pixel contributes its full raster value when its **centroid** lies within the named radius measured by `ST_DistanceSphere` on a 6378137 m sphere. NoData pixels never contribute. This is deliberately not an area-weighted partial-pixel sum. A ring with zero valid pixels is unresolved (`None`), never zero. Valid-pixel counts are recorded per radius (`worldpop_valid_pixels_2000m`, `worldpop_valid_pixels_3000m`) and are the coverage guard used at runtime.

**Known historical discrepancy:** 6378137 m reproduces 178/178 P and 177/186 U rows at 2 km (169/186 at 3 km); the four known failures are one-cell boundary differences of 0.007–0.060 m. ChatGPT should use the definition above for the **v2** retraining so training and runtime agree; it must not be described as exact parity with the original Expanded64 training columns.

---

## 4. 10-minute walk isochrone area and reachable population

**Source file:** `backend/src/sitewise/ml/expanded64_network.py`, `Expanded64CoordinateExtractor._network`, `_routed_hull`, `_isochrone` and its `_hull_population` override (the base `coordinate_features.py::_hull_population` is not used by this extractor).

### Exact SQL — routing hull

```sql
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
FROM measured WHERE area > 0
```

**Methodology.** Nearest `ur_walknode` in the `scomp_walk` component; directed `pgr_drivingDistance` with a 1200 s budget (the wider budget avoids truncation) and a strict `agg_cost <= 600` filter for hull vertices; `ST_ConcaveHull(..., 0.90, false)` (no holes), wrapped in `ST_Multi`; only `MULTIPOLYGON` results with area > 0 are accepted. Area is geodesic `ST_Area(::geography) / 1e6` km², rounded to 4 decimals. The edge-window is 0.025°; motorway and motorway_link edges are excluded for walking only.

### Exact SQL — population inside the hull

```sql
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
```

`coverage_pct` is the raster-overlap share of the hull; it is recorded as provenance and used as the runtime guard. The Expanded64 extractor's override rounds population to **3 decimals** (not 1 decimal as the base extractor does). A hull with fewer than 3 reach vertices or a non-polygonal hull yields no area. A null raster result leaves the area valid but the population unresolved. Neither case becomes zero.

**Known historical discrepancy:** 46/48 coordinate replay and 1796/1796 archived values, with the walk-graph snapshot changed at two properties (MD-02554, EP-02087). Recalculate the v2 training rows with the runtime recipe above rather than attempting to patch the old snapshot.

---

## 5. Eligibility gating (important)

All six features are **measured and persisted now** by the existing enrichment worker into `fyp.property_geospatial_features.expanded64_measurements`, keyed by `expanded64_network` / `expanded64_population`, with state `calculated_unvalidated` in the Location Intelligence response. They are **excluded from the scoring vector** while the original `sitewise_pu_64_expanded` artifact is active (`VALIDATED_COORDINATE_INPUTS` in `ml/pu_expanded.py`). After the v2 training rows have been recalculated with these definitions and the artifact is validated, activation is a configuration change only:

```
SITEWISE_EXPANDED64_V2_MODEL_NAME=Expanded64_v2
```

with the artifact placed at `backend/src/sitewise/ml/Expanded64_v2.joblib`. No second engine, model card, or database table is introduced. Under v2, `coordinate_input_validated` admits the six features only when the recorded `definition_version` matches `expanded64-feature-definitions-v1` and the corresponding coverage guard passes (valid raster pixels / measured clipped length / polygonal hull with positive raster coverage).

---

## 6. Missing-data contract

- Unavailable means `None` plus an explicit reason; never `0.0` and never a neighbouring property's value.
- Zero is admitted only as a measured zero under the existing coverage guards (e.g. transit zero inside GTFS coverage, residential zero confirmed by a non-empty building inventory).
- The 12 age features and the driving isochrone calculator are preserved byte-for-byte in behaviour; do not alter their band definitions, radii, or routing parameters.
