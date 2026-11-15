"""Parity probe: reproduce Phase-2 OSM footprint counts for a few subjects.

Compares our buffer construction (geodesic ST_Buffer on geography, projected to
EPSG:3857 for planar intersection) against mrf_2026_11_06.building_density
osm_footprints_1000m / building_count_500m so the residential pipeline uses the
same spatial method as the existing total-building layer.
"""
import os
import sys

sys.path.insert(0, r"C:\Users\Lenovo\OneDrive\Desktop\JOEL\FYP\competitor_scraper")
from dotenv import load_dotenv

load_dotenv(r"C:\Users\Lenovo\OneDrive\Desktop\JOEL\FYP\competitor_scraper\.env")
import psycopg2
import pandas as pd

RES_SET = "('apartments','detached','house','semidetached_house','residential','terrace')"

conn = psycopg2.connect(os.environ["DATABASE_URL"])
cur = conn.cursor()

cur.execute(
    "SELECT subject_id, latitude, longitude, building_count_500m, osm_footprints_1000m "
    "FROM mrf_2026_11_06.building_density ORDER BY subject_id LIMIT 5"
)
probe = cur.fetchall()
subs = [(r[0], r[1], r[2]) for r in probe]
print("probe subjects:", [(r[0][:20], r[3], r[4]) for r in probe])

cur.execute("CREATE TEMP TABLE rsub(subject_id text PRIMARY KEY, geog geography)")
for sid, lat, lon in subs:
    cur.execute("INSERT INTO rsub VALUES (%s, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography)", (sid, lon, lat))

# 1000m OSM-all-building footprint count (parity target: osm_footprints_1000m)
cur.execute("""
WITH buf AS (
    SELECT subject_id, ST_Buffer(geog, 1000)::geometry AS buf
    FROM rsub
)
SELECT b.subject_id, count(DISTINCT p.osm_id)
FROM buf b
JOIN public.planet_osm_polygon p
  ON p.building IS NOT NULL AND p.building <> 'no'
 AND ST_Intersects(p.way, b.buf)
GROUP BY b.subject_id
""")
mine_all = dict(cur.fetchall())

# 1000m residential-set count for context
cur.execute("""
WITH buf AS (
    SELECT subject_id, ST_Buffer(geog, 1000)::geometry AS buf
    FROM rsub
)
SELECT b.subject_id, count(DISTINCT p.osm_id)
FROM buf b
JOIN public.planet_osm_polygon p
  ON p.building IN %s
 AND ST_Intersects(p.way, b.buf)
GROUP BY b.subject_id
""" % RES_SET)
mine_res = dict(cur.fetchall())

p2_osm = {r[0]: r[4] for r in probe}
print(f"{'subject':24s} {'phase2_osm_1000':>15s} {'mine_osm_1000':>14s} {'mine_res_1000':>14s}")
for sid, _lat, _lon in subs:
    print(f"{sid[:24]:24s} {p2_osm.get(sid, -1):>15d} {mine_all.get(sid, 0):>14d} {mine_res.get(sid, 0):>14d}")

# geodesic buffer area check vs Phase-2 buffer_area columns
cur.execute("""
SELECT subject_id, ST_Area(ST_Buffer(geog, 500)) AS a500, ST_Area(ST_Buffer(geog, 1000)) AS a1000
FROM rsub
""")
for sid, a5, a10 in cur.fetchall():
    print(f"buffer area {sid[:20]}: mine500={a5:.0f} mine1000={a10:.0f}")

conn.close()
