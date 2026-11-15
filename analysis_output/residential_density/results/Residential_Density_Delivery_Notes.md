# Residential Building & Housing Density — Delivery Notes (P + U, 1,849 subjects)

Spec: SiteWise — Collect Residential Building and Housing Density for P and U Datasets
Workbook: `results/SiteWise_PU_Residential_Density_1849.xlsx` (5 sheets; join on `subject_id`, never row order)

## Inputs (verified)

- `Sitewise_PU_All_Features_1849_Population_Completed.csv` (sha256 dd352b48…) — coordinate source for all 1,849 subjects; coordinates verified byte-identical to `mrf_2026_11_06.building_density` (max diff 0.0 m). P = 894 (Google place-id subjects), U = 955 (MD-##### subjects).
- `Sitewise_Positive_FNB_Population_894_Complete.csv` — 894 rows, subject_id complete (spec-named "(2)" variant not present on disk; this is the located equivalent).

## Sources

| Source | Use | Licensing |
|---|---|---|
| OSM polygons `public.planet_osm_polygon` (SRID 4326, osm2pgsql) | verified residential metrics: `building ∈ {apartments, detached, house, semidetached_house, residential, terrace}`; `landuse=residential` for landuse coverage only | ODbL 1.0, © OpenStreetMap contributors; extract date not recorded in DB (data as of 2026-11 snapshot) |
| Google Open Buildings `public.open_buildings` (12.9M footprints) | NOT used for residential metrics — unclassified; kept separate per spec §4 | CC-BY 4.0, Google |
| Phase-2 layer `mrf_2026_11_06.building_density` | methodology parity reference only; not modified | — |

## Method (one documented rule, identical for P and U)

- Buffer: geodesic circle `ST_Buffer(point::geography, r, 32)` (r = 500 m, 1000 m); intersect planar in 4326; areas geodesic; counts = `COUNT(DISTINCT osm_id)`; overlapping footprints deduplicated by `ST_UnaryUnion`.
- Definitions: building density = distinct verified residential buildings / buffer km²; footprint coverage = union of verified residential footprint ∩ buffer / buffer area × 100; landuse coverage = union of `landuse=residential` ∩ buffer / buffer area × 100. Count/density, footprint coverage, landuse coverage, dwelling-unit density and WorldPop population density are distinct definitions — never equated or converted.
- Parity probe vs Phase-2 total-building counts (5 subjects): deltas 0–8 of 189–850 (<4%), one exact; differences are buffer-boundary edge effects.

## Feature coverage (real values where source coverage permits)

500 m / 1000 m quality states:

| State (500m anchor) | P (894) | U (955) |
|---|---|---|
| calculated | 817 | 856 |
| confirmed_zero (≥10 mapped buildings, 0 verified residential) | 73 | 56 |
| manual_review (1–9 mapped buildings; values NULL, zero not asserted) | 2 | 27 |
| insufficient_coverage (0 mapped buildings; values NULL) | 2 | 16 |

1000 m: calculated 881 P / 908 U. Verified-residential buildings present at 500 m: 1,673 subjects (median count 91; P median 82.5, U median 109.5; max 2,355). Landuse=residential intersects 500 m buffer for 1,694 subjects. 82 subjects: landuse present but zero verified residential buildings (flagged in `quality_note` — landuse does not confirm buildings, spec §4).

Trustworthy 500 m values: 1,802/1,849 (97.5%); 47 subjects left NULL (never zero-filled).

## Dwelling units

All 1,849 `dwelling_units_*` / `dwelling_unit_density_*` fields NULL, `dwelling_data_quality = unavailable_dwelling`. Reason: OSM carries `building:units` on 28 polygons Malaysia-wide (15 in the residential tag set); no licensed national dwelling-unit register available. Building counts were NOT converted to dwelling units (spec §3). A residential building is not necessarily one dwelling unit.

## Validation (§8) — all pass

- 894 P + 955 U = 1,849 unique subject_ids; sets match master; no duplicates/losses; sheets partition exactly (P∪U = combined).
- Counts non-negative integers; count(500m) ≤ count(1000m); union areas nested.
- Coverage percentages within [0, 100].
- Zero ≠ missing: confirmed_zero rows carry measured zeros; manual_review/insufficient rows NULL.
- Density recompute from count/buffer on 200-row samples: match.
- P and U coverage stats computed independently (table above).
- Independent spatial recalc of 10 subjects (5 P + 5 U, ST_DWithin geography formulation): counts 9 exact + 1 within ±2; coverage exact to 3 dp on 10/10.
- No claim of complete coverage: 47 subjects honestly insufficient (listed with reasons in Data Quality sheet).

## Files

- `results/SiteWise_PU_Residential_Density_1849.xlsx` — deliverable workbook
- `data/residential_features_1849.csv`, `data/residential_quality_1849.csv` — intermediate layers (join on subject_id)
- `scripts/compute_residential_features.py` (`--radius 500|1000`, `--merge`), `scripts/classify_residential_quality.py`, `scripts/build_residential_workbook.py`, `scripts/probe_parity.py`, `tests/residential_validation.py`
- `results/residential_compute_summary.json`, `results/residential_validation_summary.json`
- No persistent DB writes (temp tables only); no production tables created; WorldPop untouched; PU model untouched.
