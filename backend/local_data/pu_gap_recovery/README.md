# SiteWise — PU gap-recovery local datasets (pu_gap_recovery)

Source of these datasets: `Sitewise_PU_Gap_Recovery` (OneDrive copy retained
untouched). This directory holds the *provenance manifests* in Git; the heavy
data itself stays at a configurable external path.

## Layout

```
manifests/                  committed here (small, provenance only)
  download_manifest.csv     all 43 WorldPop GeoTIFFs with sha256 + source URL
  stac_item.json            STAC metadata of the WorldPop download batch
data/                       git-ignored; the large files live at the
                            configured external path instead (see below)
```

## External dataset path (spec section 3)

The rasters are ~1.2 GB in total and the total-population product is ALREADY
ingested in PostgreSQL (`public.worldpop_2025_constrained`, 2,677 tiles of the
identical `mys_pop_2025_CN_100m_R2025A_v1.tif` grid), so the runtime feature
path needs **no local files at all** and no duplicate copy is made. The
original 43 age-sex GeoTIFFs remain available offline at:

```
SITEWISE_PU_GAP_DATA_ROOT=C:\Users\Lenovo\OneDrive\Desktop\JOEL\Prompt File\Sitewise_PU_Gap_Recovery\data
```

(see `.env.example`). Nothing in the backend hardcodes that Windows path.

## Dataset classification (spec section 2 step 5)

| Item | Kind | Reusable? |
|---|---|---|
| `raw_worldpop/*.tif` (43 age-sex bands, 100 m, EPSG:4326, CC-BY-4.0) | raw geospatial raster | YES — but the *total* band is already in PostGIS; the age split feeds the research table, not the 47-feature PU contract |
| `age_chunks/chunk_*.csv`, `age_extract.csv` | precomputed per-subject records (1,849 PU training subjects) | NO for new locations (spec section 7) |
| `master_1849.csv`, `task_*.csv`, `fill_decisions.csv`, `recovery_records.csv`, `payload_*.csv` | precomputed per-subject records + audit trail | NO for new locations; training-input provenance only |
| `manifests/*` | provenance (sha256, licence, source URL) | YES — committed here |

## Dataset-to-feature mapping: the 47-feature PU contract

Contract source: the selected artifact `sitewise_selected_pu_model.joblib`
(feature set `baseline_47`), loaded via `sitewise.ml.model_loader` — never a
hand-written schema. Parity reference: `backend/ml_reference/
example_property_47.json` (subject MD-00510), verified live 2026-11-15.

### Implemented for new properties (verified method, licence-clean)

| Feature(s) | Source | Method | Parity evidence (MD-00510) |
|---|---|---|---|
| `pop_500m`, `pop_1000m`, `pop_2000m`, `pop_3000m` | `public.worldpop_2025_constrained` (PostGIS, CC-BY-4.0) | geodesic `ST_Buffer` ring → `ST_Clip` → `ST_SummaryStats`, coverage = valid cells / ring area ÷ pixel area (`PropertyEnrichmentService._worldpop_population`) | 1071.595/1071.6; 6431.75/6430.9; 35457.2/35472.8 (0.04 %); 108700.9/108745.1 (0.04 %); coverage 84.78 % reproduced exactly |
| `competitor_count_500m/1000m`, cafe/restaurant/fast-food counts | `fnb_a.fnb_outlet`, `fnb_a.overture_places` (existing contract) | geodesic `ST_DWithin` (existing enrichment categories) | office_pois_500m=1, retail_pois_500m=2, schools_count_500m=1 reproduced exactly from `demand_gen.pois_master` with `active_for_analysis` |
| `parking_facilities_500m/1km`, `nearest_parking_distance_m` | `public.psense_parking` | existing `parking` enrichment category | training value 6 facilities/500 m, 83.07 m nearest — same table |
| transit stops, demand generators, major-road distance | `fnb_a.transit_pois`, `demand_gen.subjects`, `fnb_a.major_roads` | existing `roads_transport` / `demand_generators` categories | — |

Wiring: `fyp.property_enrichment_category` (state + JSONB measurement +
provenance) and `fyp.property_geospatial_features` (wide measurement columns),
written by the existing two-phase enrichment lifecycle that runs after property
creation. Population quality is reported per radius
(`worldpop_coverage_*_pct`, `LOW_COVERAGE` + lower-bound note below 99 %),
matching the training pipeline's own treatment.

### Available in the database but method NOT verified (not implemented)

| Feature(s) | Source present | Why not wired |
|---|---|---|
| `road_length_density_500m/1km_km_km2`, `road_intersection_density_500m_km2` | `fyp_features.roads_v2` (1.92 M OSM ways), `road_junctions_v2` | recomputing gives 26.2 km/500 m vs training 36.939 km/km² — the training class filter is unknown; a wrong filter silently corrupts the contract |
| `osm_walkway_length_density_500m_km_km2` | `fyp_features.walk_edges` (1.15 M edges) | same: 24.6 km raw vs training 21.15 km/km² (class filter unknown) |
| `worldpop_walk_reachable_10min`, `walk_isochrone_area_10min_km2` | `fyp_features.walk_edges/vertices`, pgrouting 4.0.1 installed | the recovery's 10-min isochrone (snap → 600 s drivingDistance → hull, `rcv_2026_11_09.rx_walk_iso` params) is documented but not re-derivable as a verified method in this pass |
| `drive_isochrone_area_10min_km2` | — | training used the OSRM public demo (external service, no local verified equivalent) |
| `nearest_transit_walk_m`, `bus_stops_500m_walk`, `rail_stations_1km_walk`, `weekday_departures_500m_walk_am`, `weekday_transit_routes_1km_walk` | `fyp_features.gtfs_stops/stop_times/trips` (736,719 stop-times), walk network | walk-shed distances need the same unverified isochrone/routing method |

### Licence-blocked (must stay unresolved)

| Feature(s) | Reason |
|---|---|
| `landscan_ambient_pop_1000m/2000m/3000m` | `landscan_ml_training_eligible = NO_PENDING_LICENCE` for all 1,849 training rows. The values appear in no database table; the `public.landscan_2024` raster remains a *display-only* fallback in the enrichment chain (coarse ~1 km, never `ml_eligible`) and is ordered AFTER the WorldPop provider so it answers only where WorldPop has no coverage. PU inference therefore reports these three features as missing for every new property — honestly unavailable, never imputed, never borrowed (see `sitewise/ml/feature_bridge.py`). |

## What this does NOT do

* No second property table, repository, or feature pipeline: the integration
  extends `PropertyEnrichmentService._population` only.
* No copying of P/U training values to new properties; new properties get no
  subject link (`owner_properties_with_subject_link = 0` verified live).
* No retraining, no artifact or SHAP changes, no new feature tables or columns:
  the four-ring values beyond 500 m/1 km live in the category's JSONB
  measurement, and the wide table keeps its existing contract.
