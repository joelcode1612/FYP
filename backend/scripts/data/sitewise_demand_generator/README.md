# SiteWise — Demand Generator Data Backfill

## Purpose

Compute **real** location-based demand-generator counts for all FYP rental properties, rather than inventing numbers or treating F&B competition as customer demand.

**Verified from GitHub `joel` branch (2026-11-21):**
- `backend/src/sitewise/services/property_enrichment_service.py`: operational curated `demand_gen.subjects` -> `demand_generator_count_500m` / `_1km` in `fyp.property_geospatial_features`.
- `backend/src/sitewise/ml/coordinate_features.py`: seven distinct `demand_gen.pois_master` types at 500 m / 1 km, preserved exactly as named there.
- `backend/src/sitewise/services/recommendation_filter_fields.py`: three demand choices previously came from `sitewise_analytics.subject_features.other_features`, which can be stale or missing after adding a property.
- `fyp.rental_properties` is the canonical source of property coordinates.

The tool **does not have your live database**. It produces a CSV of actual counts **when run on your machine or server**. Counts in this package are intentionally absent.

## Inputs and outputs

| Source | Output | Meaning |
| --- | --- | --- |
| `demand_gen.subjects.geom` | `demand_generator_count_500m`, `demand_generator_count_1km` | Curated demand-generator register; **not** sum of individual POI categories |
| `demand_gen.pois_master.rep_geom` + `poi_category` | `office_pois_500m`/`_1000m`; `schools_count_500m`/`_1000m`; `universities_colleges_count_500m`/`_1000m`; `retail_pois_500m`/`_1000m`; `malls_count_500m`/`_1000m`; `hospitals_count_500m`/`_1000m`; `supermarkets_count_500m`/`_1000m` | Seven model-aligned categories, 14 counts in total |

**Crucial:** The training feature `OFFICE` intentionally excludes `OFFICE_BUILDING`. All counts use the same geography-distance measure as the current production code. The POI generator marks all 14 category values unavailable if its 0.012-degree source window contains no records. A measured zero remains zero if coverage is present.

## Windows PowerShell run instructions

Put the extracted folder inside your FYP repository at:

`C:\Users\Lenovo\AndroidStudioProjects\FYP\backend\scripts\data\sitewise_demand_generator`

From a PowerShell terminal (no `.ps1` needed):

```powershell
cd C:\Users\Lenovo\AndroidStudioProjects\FYP\backend
py -m pip install sqlalchemy psycopg2-binary python-dotenv
```

The script loads database URLs from `backend/.env` (or equivalent environment variables). It uses `DATABASE_URL` / `SITEWISE_DATABASE_URL` for `fyp.rental_properties` and target `fyp.property_geospatial_features`. For the source tables it probes the operational database, then `ANALYTICS_DATABASE_URL` / `SITEWISE_DEMAND_SOURCE_DATABASE_URL` if available. **Never share your .env or credentials in chat.** If your Supabase direct connection fails on IPv4, use the documented pooler URL configured with your own project credentials; no credentials are bundled here.

### A. Generate CSV only (default, no database writes)

```powershell
py scripts\data\sitewise_demand_generator\generate_demand_generators.py --backend . --limit 5 --csv demand_preview.csv
py scripts\data\sitewise_demand_generator\generate_demand_generators.py --backend . --csv demand_all.csv
```

The first command tests five properties; the second exports all rental properties (no arbitrary 916/955 cap). Inspect `status`, `poi_coverage`, `error`, `demand_generator_count_500m`, and the 14 POI category columns. Input data must exist; source tables absent or empty cause the script to stop rather than invent values.

### B. Backfill missing values (explicit database write)

```powershell
py scripts\data\sitewise_demand_generator\generate_demand_generators.py --backend . --apply --csv demand_backfill_result.csv
```

The script:
1. checks both source tables and target schema;
2. refuses duplicate `property_id` rows;
3. adds only the **14 missing integer demand POI columns** on `fyp.property_geospatial_features` (never drops or recreates the table);
4. inserts missing geospatial rows or fills NULL demand columns, preserving existing non-NULL values;
5. updates an existing `fyp.property_enrichment_category` row for `demand_generators` when the stored curated measurements match the computed measurements; other enrichment categories are left untouched;
6. produces a CSV audit with per-property provenance and statuses.

**Coordinate changes and corrected sources:** By default previously populated counts are not replaced. Use `--force` only after reviewing the new source data and/or correcting property coordinates:

```powershell
py scripts\data\sitewise_demand_generator\generate_demand_generators.py --backend . --apply --force --csv demand_recalculated.csv
```

Test one property first:

```powershell
py scripts\data\sitewise_demand_generator\generate_demand_generators.py --backend . --ids 123 --apply --csv demand_property_123.csv
```

Replace `123` with a real `fyp.rental_properties.id`. The tool does **not** delete records, modify PU model artifacts, alter competitors, or overwrite the `sitewise_analytics.subject_features` training snapshot. Database backup before --apply is recommended.

### C. Make recommendations use the new FYP demand values

The existing recommendation filter reads its three demand choices from `sitewise_analytics.subject_features.other_features`. The new FYP measurements won't automatically become the filter source. Apply the **separate, optional source patch** after you verify the backfill:

```powershell
cd C:\Users\Lenovo\AndroidStudioProjects\FYP
py backend\scripts\data\sitewise_demand_generator\patch_recommendation_demand_reader.py --root . --dry-run
py backend\scripts\data\sitewise_demand_generator\patch_recommendation_demand_reader.py --root . --apply
```

This changes only three backend source files and creates a timestamped backup under `.sitewise-demand-generator-backup`. It uses the already-injected **operational session** in both `/recommendations/search` and `/recommendations/facets`, joins `fyp.property_subject_links` for verified catalogue IDs, and prefers measured FYP values over older analytics snapshots. The fallback remains available when FYP data has not yet been backfilled. It does not rewrite or duplicate the training data. It retains the three existing UI options: malls within 1 km, offices within 500 m, and universities within 500 m. The other category counts are available for future property-detail visualisations.

After patch:

```powershell
py -m compileall backend\src\sitewise\services\recommendation_search_service.py backend\src\sitewise\services\recommendation_filter_fields.py backend\src\sitewise\api\v1\recommendations.py
```

Restart FastAPI (usually your unified SiteWise server on port 8090) and request `/api/v1/recommendations/facets` and `/api/v1/recommendations/search` with a valid user token. Cached previous search results may take up to the current backend cache expiry before new values appear.

### D. Verify measurements

Run `01_demand_generator_audit.sql` **before** and `02_verify_after_apply.sql` **after** the import using Supabase SQL Editor or psql. If source tables are in a different database, Supabase SQL Editor on the operational database cannot read them directly; the Python tool supports two connections.

### E. Local automated tests

```powershell
cd C:\Users\Lenovo\AndroidStudioProjects\FYP\backend\scripts\data\sitewise_demand_generator
py -m unittest -v test_generate_demand_generators.py
```

Tests validate the seven source categories, correct measured-versus-unavailable semantics, exact coordinate hash and CSV safety. Integration testing requires access to your real PostGIS database.

## Interpretation

Do not treat `demand_generator_count` as a demand score or probability of an F&B outlet succeeding. It is a **count of selected nearby places**. A shopping mall, office, school or hospital may generate different customer patterns and opening-hour demand; the current backend does not know their foot-traffic volume from this measurement. F&B competitor counts remain a separate contextual feature and do not automatically determine footfall or true demand.
