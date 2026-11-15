"""Compute residential building/landuse density features for all 1,849 P+U subjects.

Method (locked after parity probe vs mrf_2026_11_06.building_density):
- Buffer: geodesic circle ST_Buffer(point::geography, r, 32)::geometry (SRID 4326)
- Intersect: planar in 4326 against public.planet_osm_polygon.way (SRID 4326 latlong import)
- Areas: ST_Area(geom::geography) geodesic m2
- Counts: COUNT(DISTINCT osm_id); overlapping polygons deduplicated by ST_UnaryUnion for areas
- Residential inclusion rule (spec section 4 fixed tag set):
    building IN ('apartments','detached','house','semidetached_house','residential','terrace')
- Landuse coverage: landuse='residential' polygons (NOT treated as building classification)
- Unclassified footprints (building='yes' etc.) and Google Open Buildings stay separate.

Usage:
  python compute_residential_features.py --radius 500   -> data/res_features_500m.csv
  python compute_residential_features.py --radius 1000  -> data/res_features_1km.csv
  python compute_residential_features.py --merge        -> data/residential_features_1849.csv + results summary
"""
import argparse
import hashlib
import json
import os
import sys

sys.path.insert(0, r"C:\Users\Lenovo\OneDrive\Desktop\JOEL\FYP\competitor_scraper")
from dotenv import load_dotenv

load_dotenv(r"C:\Users\Lenovo\OneDrive\Desktop\JOEL\FYP\competitor_scraper\.env")
import psycopg2
import pandas as pd

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASTER = r"C:\Users\Lenovo\Downloads\Sitewise_PU_All_Features_1849_Population_Completed.csv"
RES_SET = "('apartments','detached','house','semidetached_house','residential','terrace')"
RADII = {500: "500m", 1000: "1km"}

SQL = """
WITH buf AS MATERIALIZED (
    SELECT subject_id,
           ST_Buffer(ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography, {radius}, 32)::geometry AS buf,
           ST_Area(ST_Buffer(ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography, {radius}, 32)::geometry::geography) AS buf_area
    FROM rsub
    {where}
),
ix AS (
    SELECT b.subject_id, b.buf_area,
           (p.building IN {res_set}) AS is_res,
           (p.landuse = 'residential') AS is_lu,
           (p.building IS NOT NULL AND p.building <> 'no') AS is_bldg,
           p.osm_id,
           CASE WHEN (p.building IN {res_set}) OR (p.landuse = 'residential')
                THEN ST_Intersection(p.way, b.buf) END AS geom
    FROM buf b
    JOIN public.planet_osm_polygon p
      ON ((p.building IS NOT NULL AND p.building <> 'no') OR p.landuse = 'residential')
     AND ST_Intersects(p.way, b.buf)
),
agg AS (
    SELECT subject_id,
           buf_area,
           count(DISTINCT osm_id) FILTER (WHERE is_res) AS res_count,
           count(DISTINCT osm_id) FILTER (WHERE is_bldg) AS any_building,
           ST_Collect(geom) FILTER (WHERE is_res) AS res_geom,
           ST_Collect(geom) FILTER (WHERE is_lu) AS lu_geom
    FROM ix
    GROUP BY subject_id, buf_area
)
SELECT subject_id,
       buf_area,
       COALESCE(res_count, 0) AS res_count,
       COALESCE(any_building, 0) AS any_building,
       COALESCE(ST_Area(ST_UnaryUnion(res_geom)::geography), 0) AS res_area,
       COALESCE(ST_Area(ST_UnaryUnion(lu_geom)::geography), 0) AS landuse_area
FROM agg
"""


def load_subjects(cur):
    m = pd.read_csv(MASTER, usecols=["subject_id", "sample_class", "latitude", "longitude"])
    m["subject_id"] = m["subject_id"].astype(str)
    assert len(m) == 1849 and m["subject_id"].is_unique
    assert m[["latitude", "longitude"]].notna().all().all()
    assert m["latitude"].between(0.5, 7.6).all() and m["longitude"].between(99.0, 119.5).all()
    cur.execute("CREATE TEMP TABLE rsub(subject_id text PRIMARY KEY, lat double precision, lon double precision)")
    cur.executemany("INSERT INTO rsub VALUES (%s, %s, %s)",
                    [(r.subject_id, float(r.latitude), float(r.longitude)) for r in m.itertuples()])
    return m


def run_radius(radius):
    sfx = RADII[radius]
    conn = psycopg2.connect(os.environ["DATABASE_URL"])
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET work_mem = '256MB'")
    cur.execute("SET max_parallel_workers_per_gather = 4")
    m = load_subjects(cur)
    ids = m["subject_id"].tolist()
    print(f"radius {radius}: {len(m)} subjects loaded, computing in chunks of 100...", flush=True)
    frames = []
    CHUNK = 100
    for i in range(0, len(ids), CHUNK):
        chunk = ids[i:i + CHUNK]
        cur.execute(SQL.format(radius=radius, res_set=RES_SET, where="WHERE subject_id = ANY(%s)"), (chunk,))
        got = cur.fetchall()
        frames.append(pd.DataFrame(got, columns=["subject_id", f"buffer_area_{sfx}_m2",
                                                 f"residential_building_count_{sfx}",
                                                 f"any_building_count_{sfx}",
                                                 f"residential_footprint_area_{sfx}_m2",
                                                 f"residential_landuse_area_{sfx}_m2"]))
        print(f"radius {radius}: chunk {i // CHUNK + 1}/{(len(ids) + CHUNK - 1) // CHUNK} done "
              f"({len(got)} subjects with intersects)", flush=True)
    conn.close()
    df = pd.concat(frames, ignore_index=True)
    path = os.path.join(BASE, "data", f"res_features_{sfx}.csv")
    df.to_csv(path, index=False)
    print(f"radius {radius}: total {len(df)} subjects; saved {path}", flush=True)


def merge():
    m = pd.read_csv(MASTER, usecols=["subject_id", "sample_class"])
    m["subject_id"] = m["subject_id"].astype(str)
    out = m.copy()
    for sfx in ("500m", "1km"):
        part = pd.read_csv(os.path.join(BASE, "data", f"res_features_{sfx}.csv"))
        part["subject_id"] = part["subject_id"].astype(str)
        out = out.merge(part, on="subject_id", how="left")

    for sfx in ("500m", "1km"):
        out[f"residential_building_count_{sfx}"] = out[f"residential_building_count_{sfx}"].fillna(0).astype(int)
        out[f"any_building_count_{sfx}"] = out[f"any_building_count_{sfx}"].fillna(0).astype(int)
        out[f"residential_building_density_{sfx}_km2"] = (
            out[f"residential_building_count_{sfx}"] / (out[f"buffer_area_{sfx}_m2"] / 1e6)
        ).round(2)
        out[f"residential_footprint_coverage_{sfx}_pct"] = (
            100.0 * out[f"residential_footprint_area_{sfx}_m2"].fillna(0) / out[f"buffer_area_{sfx}_m2"]
        ).round(3).clip(upper=100.0)
        out[f"residential_landuse_coverage_{sfx}_pct"] = (
            100.0 * out[f"residential_landuse_area_{sfx}_m2"].fillna(0) / out[f"buffer_area_{sfx}_m2"]
        ).round(3).clip(upper=100.0)

    out_path = os.path.join(BASE, "data", "residential_features_1849.csv")
    out.to_csv(out_path, index=False)

    summary = {
        "master_csv": MASTER,
        "master_sha256": hashlib.sha256(open(MASTER, "rb").read()).hexdigest(),
        "subjects": len(out),
        "sample_class_counts": out["sample_class"].value_counts().to_dict(),
        "radii_m": [500, 1000],
        "method": {
            "buffer": "ST_Buffer(point::geography, r, 32)::geometry, SRID 4326",
            "intersect": "planar ST_Intersects in SRID 4326 vs planet_osm_polygon.way",
            "areas": "ST_Area(::geography) geodesic m2; union via ST_UnaryUnion (dedup)",
            "counts": "COUNT(DISTINCT osm_id)",
            "residential_tag_set": ["apartments", "detached", "house", "semidetached_house", "residential", "terrace"],
            "landuse_rule": "landuse='residential' polygons only",
            "excluded": ["building=yes (unclassified)", "other building values (bungalow, dormitory, ...)",
                         "Google Open Buildings footprints (unclassified)"],
        },
        "parity_probe_5_subjects": "OSM all-building 1000m counts vs mrf_2026_11_06.building_density.osm_footprints_1000m: deltas 0..8 (<4%), one exact",
        "totals": {
            "subjects_with_res_buildings_500m": int((out["residential_building_count_500m"] > 0).sum()),
            "subjects_with_res_buildings_1km": int((out["residential_building_count_1km"] > 0).sum()),
            "subjects_any_building_500m": int((out["any_building_count_500m"] > 0).sum()),
            "subjects_any_building_1km": int((out["any_building_count_1km"] > 0).sum()),
            "subjects_landuse_res_500m": int((out["residential_landuse_coverage_500m_pct"] > 0).sum()),
            "subjects_landuse_res_1km": int((out["residential_landuse_coverage_1km_pct"] > 0).sum()),
        },
    }
    with open(os.path.join(BASE, "results", "residential_compute_summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps(summary["totals"], indent=2))
    print("saved", out_path)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--radius", type=int, choices=[500, 1000])
    ap.add_argument("--merge", action="store_true")
    a = ap.parse_args()
    if a.merge:
        merge()
    elif a.radius:
        run_radius(a.radius)
    else:
        ap.error("use --radius or --merge")
