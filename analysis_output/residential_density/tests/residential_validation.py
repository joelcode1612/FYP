"""Spec section-8 validation for the residential density dataset.

Checks:
 1. row counts: 1,849 combined; 894 P; 955 U; unique subject_ids; set equality with master
 2. counts non-negative integers; count_500m <= count_1000m
 3. coverage percentages within [0, 100]; footprint and landuse coverage nested (500 <= 1000)
 4. zero-vs-missing rule: confirmed_zero rows carry measured zeros; manual_review /
    insufficient_coverage rows carry NULLs (never zero-filled)
 5. density = count / buffer km2 (recomputed, tolerance 0.02)
 6. P and U coverage stats computed independently
 7. dwelling-unit fields NULL everywhere with reason text present
 8. independent spatial recalculation of 10 subjects (5 P, 5 U) via ST_DWithin geography
    (different formulation than the production buffer-join)

Writes results/residential_validation_summary.json (embedded in the workbook).
"""
import json
import os
import random
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, r"C:\Users\Lenovo\OneDrive\Desktop\JOEL\FYP\competitor_scraper")
from dotenv import load_dotenv

load_dotenv(r"C:\Users\Lenovo\OneDrive\Desktop\JOEL\FYP\competitor_scraper\.env")
import psycopg2

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASTER = r"C:\Users\Lenovo\Downloads\Sitewise_PU_All_Features_1849_Population_Completed.csv"
METRICS = ["_count", "_density_km2", "_footprint_coverage_pct", "_landuse_coverage_pct"]

df = pd.read_csv(os.path.join(BASE, "data", "residential_quality_1849.csv"))
master = pd.read_csv(MASTER, usecols=["subject_id"])
master["subject_id"] = master["subject_id"].astype(str)
checks = {}
fails = []


def check(name, ok, detail=""):
    checks[name] = {"pass": bool(ok), "detail": detail}
    if not ok:
        fails.append(name)


# 1. counts
p = df[df["sample_class"] == "P"]
u = df[df["sample_class"] == "U"]
check("combined_rows_1849", len(df) == 1849, str(len(df)))
check("positive_rows_894", len(p) == 894, str(len(p)))
check("unlabelled_rows_955", len(u) == 955, str(len(u)))
check("unique_subject_ids", df["subject_id"].is_unique and df["subject_id"].nunique() == 1849)
check("subject_set_matches_master", set(df["subject_id"]) == set(master["subject_id"]))
check("no_dupe_rows", not df.duplicated(subset=["subject_id"]).any())

# 2. counts
cnt_ok, nest_ok = True, True
for sfx in ("500m", "1000m"):
    c = df[f"residential_building_count_{sfx}"]
    if not c.dropna().apply(lambda v: float(v).is_integer() and v >= 0).all():
        cnt_ok = False
nest_ok = (df["residential_building_count_1000m"].fillna(0) >= df["residential_building_count_500m"].fillna(0)).all()
check("counts_nonneg_int", cnt_ok)
check("count_500_le_1000", nest_ok)

# 3. coverage ranges + nesting
cov_ok = True
for sfx in ("500m", "1000m"):
    for col in ("residential_footprint_coverage_%s_pct", "residential_landuse_coverage_%s_pct"):
        v = df[col % sfx].dropna()
        if not v.between(0, 100).all():
            cov_ok = False
# Union areas must be nested (bigger buffer contains the smaller circle); coverage
# percentages are NOT monotone since the denominator grows ~4x with radius.
nest_f = (df["residential_footprint_area_1000m_m2"].fillna(0) >= df["residential_footprint_area_500m_m2"].fillna(0) - 1e-6).all()
nest_l = (df["residential_landuse_area_1000m_m2"].fillna(0) >= df["residential_landuse_area_500m_m2"].fillna(0) - 1e-6).all()
check("coverage_0_100", cov_ok)
check("union_area_nested_500_le_1000", bool(nest_f and nest_l))

# 4. zero-vs-missing
z_ok, m_ok = True, True
cz = df["residential_data_quality_500m"] == "confirmed_zero"
z_ok = (df.loc[cz, "residential_building_count_500m"].fillna(-1) == 0).all() and len(df[cz]) > 0
for q in ("manual_review", "insufficient_coverage"):
    sel = df["residential_data_quality_500m"] == q
    for col in ("residential_building_count_500m", "residential_building_density_500m_km2",
                "residential_footprint_coverage_500m_pct", "residential_landuse_coverage_500m_pct"):
        if df.loc[sel, col].notna().any():
            m_ok = False
check("confirmed_zero_has_measured_zeros", z_ok, f"{int(cz.sum())} rows")
check("sparse_rows_are_null_not_zero", m_ok)

# 5. density recompute
den = df[df["residential_data_quality_500m"] == "calculated"].head(200)
den_calc = den["residential_building_count_500m"] / (den["buffer_area_500m_m2"] / 1e6)
check("density_recompute_500m", bool(np.allclose(den_calc, den["residential_building_density_500m_km2"], atol=0.02)))
den1 = df[(df["residential_data_quality_1000m"] == "calculated")].head(200)
den1_calc = den1["residential_building_count_1000m"] / (den1["buffer_area_1000m_m2"] / 1e6)
check("density_recompute_1000m", bool(np.allclose(den1_calc, den1["residential_building_density_1000m_km2"], atol=0.02)))

# 6. independent P/U coverage stats
def cov_stats(sub):
    return {
        "calculated_500m": int((sub["residential_data_quality_500m"] == "calculated").sum()),
        "confirmed_zero_500m": int((sub["residential_data_quality_500m"] == "confirmed_zero").sum()),
        "manual_review_500m": int((sub["residential_data_quality_500m"] == "manual_review").sum()),
        "insufficient_coverage_500m": int((sub["residential_data_quality_500m"] == "insufficient_coverage").sum()),
        "res_buildings_present_500m": int((sub["residential_building_count_500m"].fillna(0) > 0).sum()),
        "median_res_count_500m": float(sub["residential_building_count_500m"].dropna().median()),
        "median_res_density_500m_km2": float(sub["residential_building_density_500m_km2"].dropna().median()),
        "median_footprint_cov_500m_pct": float(sub["residential_footprint_coverage_500m_pct"].dropna().median()),
        "median_landuse_cov_500m_pct": float(sub["residential_landuse_coverage_500m_pct"].dropna().median()),
    }

p_stats, u_stats = cov_stats(p), cov_stats(u)

# 7. dwelling
dcols = ["dwelling_units_500m", "dwelling_units_1000m", "dwelling_unit_density_500m_km2", "dwelling_unit_density_1000m_km2"]
d_present = [c for c in dcols if c in df.columns]
d_all_null = all(df[c].isna().all() for c in d_present) if d_present else True
check("dwelling_fields_all_null", d_all_null, f"columns present: {d_present}")
check("dwelling_reason_present", df["dwelling_units_reason"].notna().all())

# 8. independent spatial recalculation
rng = random.Random(20261115)
calc_p = p[p["residential_data_quality_500m"] == "calculated"]["subject_id"].tolist()
calc_u = u[u["residential_data_quality_500m"] == "calculated"]["subject_id"].tolist()
sample_p = rng.sample(calc_p, min(5, len(calc_p)))
sample_u = rng.sample(calc_u, min(5, len(calc_u)))
sample_ids = sample_p + sample_u

master_full = pd.read_csv(MASTER, usecols=["subject_id", "latitude", "longitude"])
master_full["subject_id"] = master_full["subject_id"].astype(str)
coords = master_full.set_index("subject_id")[["latitude", "longitude"]].to_dict("index")

RES_SET = "('apartments','detached','house','semidetached_house','residential','terrace')"
conn = psycopg2.connect(os.environ["DATABASE_URL"])
cur = conn.cursor()
recalc = []
for sid in sample_ids:
    lat, lon = coords[sid]["latitude"], coords[sid]["longitude"]
    cur.execute(f"""
        WITH pt AS (SELECT ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography AS g,
                           ST_Expand(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 0.011) AS bb),
        buf AS (SELECT ST_Buffer(g, 500, 32)::geometry AS b, ST_Area(ST_Buffer(g, 500, 32)::geometry::geography) AS a FROM pt)
        SELECT (SELECT count(DISTINCT p.osm_id) FROM public.planet_osm_polygon p, pt
                WHERE p.building IN {RES_SET} AND p.way && pt.bb
                  AND ST_DWithin(p.way::geography, (SELECT g FROM pt), 500)),
               (SELECT a FROM buf),
               (SELECT COALESCE(ST_Area(ST_UnaryUnion(ST_Collect(ST_Intersection(p.way, b.b)))::geography), 0)
                FROM public.planet_osm_polygon p, buf b
                WHERE p.building IN {RES_SET} AND ST_Intersects(p.way, b.b))
    """, (lon, lat, lon, lat))
    n, a, fa = cur.fetchone()
    cov = 100.0 * fa / a if a else 0.0
    row = df[df["subject_id"] == sid].iloc[0]
    recalc.append({
        "subject_id": sid, "sample_class": row["sample_class"],
        "prod_count": int(row["residential_building_count_500m"]), "recalc_count": int(n),
        "prod_coverage_pct": float(row["residential_footprint_coverage_500m_pct"]),
        "recalc_coverage_pct": round(cov, 3),
    })
conn.close()

count_match = sum(1 for r in recalc if abs(r["prod_count"] - r["recalc_count"]) <= 2)
cov_match = sum(1 for r in recalc if abs(r["prod_coverage_pct"] - r["recalc_coverage_pct"]) <= 1.5)
check("sample_recalc_counts_within_2", count_match == len(recalc), f"{count_match}/{len(recalc)}")
check("sample_recalc_coverage_within_1.5pp", cov_match == len(recalc), f"{cov_match}/{len(recalc)}")

summary = {
    "all_pass": not fails,
    "failed_checks": fails,
    "checks": checks,
    "coverage_P": p_stats,
    "coverage_U": u_stats,
    "dwelling_gap": {
        "rows": len(df),
        "dwelling_units_available": 0,
        "reason": "no reliable licensed dwelling-unit source; OSM building:units covers 28 polygons nationwide; building counts not converted (spec prohibition)",
    },
    "sample_recalc": recalc,
}
with open(os.path.join(BASE, "results", "residential_validation_summary.json"), "w") as f:
    json.dump(summary, f, indent=2)

print(json.dumps({"all_pass": not fails, "failed": fails}, indent=2))
print("P:", json.dumps(p_stats))
print("U:", json.dumps(u_stats))
print("recalc:", count_match, "/", len(recalc), "counts;", cov_match, "/", len(recalc), "coverage")
