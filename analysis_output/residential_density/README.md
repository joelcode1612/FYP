# Sitewise Residential Building & Housing Density (P + U, 1,849 subjects)

Spec: "SiteWise — Collect Residential Building and Housing Density for P and U Datasets".
Deliverable: `results/SiteWise_PU_Residential_Density_1849.xlsx` (5 sheets: Combined P_U 1,849 / Positive P 894 / Unlabelled U 955 / Data Quality / Methodology).

## Run order

1. `scripts/compute_residential_features.py` — PostGIS computation for all 1,849 subjects (buffers, residential counts, footprint/landuse coverage). CSV-only output; no persistent DB writes.
2. `scripts/classify_residential_quality.py` — spec §6 quality states (calculated / confirmed_zero / manual_review / insufficient_coverage / unavailable_dwelling).
3. `tests/residential_validation.py` — spec §8 validation incl. independent 10-subject ST_DWithin recalculation.
4. `scripts/build_residential_workbook.py` — 5-sheet workbook with embedded methodology and validation results.
5. `scripts/probe_parity.py` — optional; parity probe vs the Phase-2 total-building layer (`mrf_2026_11_06.building_density`).

## Data sources

- Verified residential metrics: OSM polygons (`public.planet_osm_polygon`, SRID 4326), tag set fixed by spec: `building ∈ {apartments, detached, house, semidetached_house, residential, terrace}`; `landuse=residential` used only for the landuse coverage metric. ODbL 1.0.
- Kept separate (not counted as residential): `building=yes` and other unclassified tags; Google Open Buildings footprints (`public.open_buildings`, unclassified).
- Dwelling units: not available from any licensed source in scope → all dwelling fields NULL with reason (no conversion from building counts).

## Honest-coverage rules

- `confirmed_zero`: ≥10 mapped OSM buildings within the 500 m anchor, zero verified residential → measured zeros kept.
- `manual_review` (1–9 mapped buildings) and `insufficient_coverage` (0 mapped buildings): metric values NULL, never zero-filled.
- P and U treated identically; all sheets join back on `subject_id`.
