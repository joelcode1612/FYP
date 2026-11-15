"""Build SiteWise_PU_Residential_Density_1849.xlsx (5 sheets, spec section 7).

Sheets:
  01_Combined_P_U     all 1,849 subjects (894 P + 955 U)
  02_Positive_P       894 P subjects
  03_Unlabelled_U     955 U subjects
  04_Data_Quality     per-subject quality states + mapping-evidence counts (joinable on subject_id)
  05_Methodology      sources, versions, licensing, rules, validation results

Join key: subject_id (never row order).
"""
import json
import os

import pandas as pd

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(BASE, "results", "SiteWise_PU_Residential_Density_1849.xlsx")

df = pd.read_csv(os.path.join(BASE, "data", "residential_quality_1849.csv"))
compute = json.load(open(os.path.join(BASE, "results", "residential_compute_summary.json")))
validation = json.load(open(os.path.join(BASE, "results", "residential_validation_summary.json")))

METRIC_COLS = [
    "residential_building_count_500m", "residential_building_count_1000m",
    "residential_building_density_500m_km2", "residential_building_density_1000m_km2",
    "residential_footprint_coverage_500m_pct", "residential_footprint_coverage_1000m_pct",
    "residential_landuse_coverage_500m_pct", "residential_landuse_coverage_1000m_pct",
]
DWELLING_COLS = ["dwelling_units_500m", "dwelling_units_1000m",
                 "dwelling_unit_density_500m_km2", "dwelling_unit_density_1000m_km2"]
QUALITY_COLS = ["residential_data_quality_500m", "residential_data_quality_1000m",
                "dwelling_data_quality", "dwelling_units_reason", "quality_note"]

main = df[["subject_id", "sample_class"] + METRIC_COLS].copy()
for c in DWELLING_COLS:
    main[c] = pd.NA
main = pd.concat([main, df[QUALITY_COLS]], axis=1)

p = main[main["sample_class"] == "P"].copy()
u = main[main["sample_class"] == "U"].copy()
assert len(p) == 894 and len(u) == 955 and len(main) == 1849

quality = df[["subject_id", "sample_class",
              "residential_data_quality_500m", "residential_data_quality_1000m",
              "dwelling_data_quality",
              "any_building_count_500m", "any_building_count_1000m",
              "residential_building_count_500m", "residential_building_count_1000m",
              "quality_note"]].copy()

def kv(k, v):
    return {"item": k, "value": str(v)}

methodology = [
    kv("Purpose", "Residential building and housing density attributes for 1,849 SiteWise subjects (894 P positive F&B + 955 U unlabelled commercial candidates); distinct from WorldPop/LandScan population density"),
    kv("Reference inputs", "Sitewise_PU_All_Features_1849_Population_Completed.csv sha256 " + compute["master_sha256"][:16] + "... (1,849 rows; coordinate source, verified identical to mrf_2026_11_06.building_density coordinates for all 1,849 subjects)"),
    kv("Source 1 (residential metrics)", "OpenStreetMap polygons via osm2pgsql, table public.planet_osm_polygon (SRID 4326 latlong import). Residential-classified buildings in extract: house 645,699; residential 102,146; terrace 67,151; semidetached_house 47,079; apartments 20,725; detached 12,547. landuse=residential polygons: 22,048. Extract extent 99.66-119.03E, 1.00-7.51N (Malaysia). Extract/import date not recorded in DB; data as of DB snapshot 2026-11. Licensing: ODbL 1.0, (c) OpenStreetMap contributors."),
    kv("Source 2 (reference only)", "Google Open Buildings footprints, table public.open_buildings (12,904,017 footprints, confidence + area, no building classification). NOT used for verified residential metrics because footprints are unclassified; kept separate per spec section 4. Licensing: CC-BY 4.0, Google. Phase-2 total building density (mrf_2026_11_06.building_density, 1,849 rows) is the existing total-building layer used as methodology parity reference only; not modified."),
    kv("Verified residential inclusion rule", "building tag IN (apartments, detached, house, semidetached_house, residential, terrace) - the spec section-4 fixed tag set. Excluded: building=yes (585,326 polygons, unclassified), all other building values (bungalow 2,953, dormitory 993, garage, shed, ...) - conservative: unclassified or out-of-set tags are NOT counted as verified residential."),
    kv("Landuse rule", "residential_landuse_coverage_*_pct uses landuse=residential polygons ONLY as an area metric. Landuse polygons do NOT confirm individual buildings (spec section 4); a landuse-only row is flagged in quality_note."),
    kv("Spatial method", "Buffer = geodesic circle ST_Buffer(point::geography, r, 32)::geometry (r = 500 m, 1000 m). Intersect = planar ST_Intersects/ST_Intersection in SRID 4326 vs planet_osm_polygon.way. Areas = ST_Area(::geography) geodesic m2. Counts = COUNT(DISTINCT osm_id). Overlapping polygons deduplicated by ST_UnaryUnion before area; known OSM way+relation double-tagging deduped in union areas (counts use distinct osm_id)."),
    kv("Density definition", "residential_building_density_*_km2 = count of distinct verified residential buildings / buffer area in km2 (buffer areas ~785,398 m2 at 500 m and ~3,121,593 m2 at 1000 m, geodesic)."),
    kv("Footprint coverage definition", "residential_footprint_coverage_*_pct = geodesic area of union of verified residential footprint intersections with buffer / buffer geodesic area x 100."),
    kv("Landuse coverage definition", "residential_landuse_coverage_*_pct = geodesic area of union of landuse=residential polygon intersections with buffer / buffer geodesic area x 100."),
    kv("Distinct-metrics note", "Building count/density, footprint coverage, landuse coverage, dwelling-unit density and WorldPop population density are DISTINCT definitions and are never treated as equivalent or converted into each other (spec section 6)."),
    kv("Zero vs missing rule", "confirmed_zero (>=10 mapped OSM buildings within 500 m anchor, zero verified residential) = measured zeros retained. manual_review (1-9 mapped buildings) and insufficient_coverage (0 mapped buildings) = metric values NULL, never zero-filled (spec section 6)."),
    kv("Dwelling-unit decision", "dwelling_units_* and dwelling_unit_density_* left NULL for all 1,849 subjects. Reason: OSM carries building:units on only 28 polygons Malaysia-wide (15 within the residential tag set); no licensed national dwelling-unit register available. A residential building is not necessarily one dwelling unit; building counts were NOT converted (spec section 3)."),
    kv("Phase-2 parity probe", "OSM all-building 1000 m counts recomputed for 5 subjects vs mrf_2026_11_06.building_density.osm_footprints_1000m: deltas 0-8 of 189-850 (<4%), one exact match. Differences are buffer-boundary edge effects; this task's method is self-consistent and documented above."),
    kv("Validation", "all_pass=" + str(validation["all_pass"]) + "; failed=" + str(validation["failed_checks"]) + "; independent 10-subject ST_DWithin recalc: counts within 2 for " + str(sum(1 for r in validation["sample_recalc"] if abs(r["prod_count"] - r["recalc_count"]) <= 2)) + "/10, coverage within 1.5pp for " + str(sum(1 for r in validation["sample_recalc"] if abs(r["prod_coverage_pct"] - r["recalc_coverage_pct"]) <= 1.5)) + "/10"),
    kv("Coverage P (500 m)", json.dumps(validation["coverage_P"])),
    kv("Coverage U (500 m)", json.dumps(validation["coverage_U"])),
    kv("Join instructions", "All sheets join back to the master dataset on subject_id (formats: P = Google place id 0x...:0x..., U = MD-#####). Do not rely on row order."),
]

with pd.ExcelWriter(OUT, engine="openpyxl") as xw:
    main.to_excel(xw, sheet_name="01_Combined_P_U", index=False)
    p.to_excel(xw, sheet_name="02_Positive_P", index=False)
    u.to_excel(xw, sheet_name="03_Unlabelled_U", index=False)
    quality.to_excel(xw, sheet_name="04_Data_Quality", index=False)
    pd.DataFrame(methodology).to_excel(xw, sheet_name="05_Methodology", index=False)

print("saved", OUT)
print("rows:", len(main), "| P:", len(p), "| U:", len(u), "| methodology rows:", len(methodology))
