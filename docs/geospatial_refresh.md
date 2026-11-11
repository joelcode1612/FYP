# Automated Geospatial Data Collection, Refresh and Feature Computation

Operational guide for the SiteWise geospatial refresh pipeline (branch `joel`).

## 1. What the pipeline does

```text
Overture Maps release (bounded GeoParquet) ─┐
OpenStreetMap regional extract / Overpass ──┤
                                            ▼
                        normalizer (validation, category mapping, bbox)
                                            ▼
                     deduplicator (evidence tiers, ambiguous → review)
                                            ▼
        synchronizer (staged, incremental, idempotent, no destructive writes)
                                            ▼
             affected-property detection (PostGIS ST_DWithin, 1 km)
                                            ▼
   FypPropertyRepository.enrichment_snapshot → property_geospatial_features
                                            ▼
        fyp.property_feature_freshness + source_snapshot (provenance)
                                            ▼
        existing /explore/analysis + /geospatial/.../freshness + admin detail
```

Key invariants:

- **Never a destructive full-table replacement.** Only inserts, targeted
  updates and new additive tables.
- **Idempotent.** Re-running the same snapshot produces zero inserts and zero
  updates; an already-`current` release is skipped entirely.
- **Absence ≠ closure.** Missing rows are recorded in `fnb_a.source_absence`
  as *unproven*; only an explicit `operating_status='closed'` changes
  `in_main_scope`.
- **No zero-for-unknown.** A failed calculation keeps the previous values and
  records `failed`/`unavailable`; API payloads carry an explicit state.
- **Source separation preserved.** OSM rows go to `fnb_a.fnb_outlet`; Overture
  rows go to `fnb_a.overture_places`; confirmed matches are written to
  `fnb_a.overture_match` so the existing `merged` competitor view keeps
  suppressing double-counted venues.

## 2. Files

| Path | Purpose |
|---|---|
| `backend/src/sitewise/ingestion/config.py` | env-driven settings, category/licence vocabulary |
| `.../records.py` | `SourceRecord`, `IngestionStats`, `CollectorBlocked` |
| `.../normalizer.py` | validation, category mapping, bbox, name normalisation |
| `.../deduplicator.py` | evidence-tiered match decisions + ambiguity |
| `.../synchronizer.py` | staged incremental OSM sync + change planning |
| `.../overture_sync.py` | Overture upsert + `overture_match` decisions |
| `.../state.py` | snapshots, runs, freshness, advisory lock |
| `.../schema.py` | additive DDL (CREATE IF NOT EXISTS only) |
| `.../sources/overture_collector.py` | release listing + bounded GeoParquet |
| `.../sources/osm_collector.py` | PBF/Overpass/fixture routes |
| `backend/src/sitewise/services/feature_refresh_service.py` | affected detection + calculation |
| `backend/scripts/run_data_refresh.py` | CLI, scheduler, Windows task XML |
| `backend/alembic/versions/20261111_0003_geo_refresh_state.py` | additive migration |
| `backend/tests/test_geo_refresh.py` | 41 focused tests |
| `backend/tests/fixtures/geo/` | offline fixtures (OSM idempotency, Overture edge cases) |

## 3. Configuration

| Variable | Default | Meaning |
|---|---|---|
| `SITEWISE_REFRESH_BBOX` | `99.5,1.2,104.6,6.8` | min_lon,min_lat,max_lon,max_lat study area |
| `SITEWISE_REFRESH_INFLUENCE_RADIUS_M` | `1000` | affected-property radius |
| `SITEWISE_DEDUP_DISTANCE_M` | `35` | spatial match threshold |
| `SITEWISE_DEDUP_NAME_SIMILARITY` | `0.82` | auto-match score |
| `SITEWISE_AMBIGUOUS_SIMILARITY` | `0.60` | review threshold |
| `SITEWISE_OVERTURE_RELEASE` | *(empty)* | pin a release; empty = latest listed |
| `SITEWISE_OVERTURE_RELEASE_BASE` | Overture S3 `/release/` | release listing base |
| `SITEWISE_MAX_OVERTURE_PARTS` | `16` | bounded parquet parts per refresh |
| `SITEWISE_MAX_RECORDS_PER_SOURCE` | `100000` | hard record cap |
| `SITEWISE_MAX_DOWNLOAD_MB` | `256` | PBF download cap |
| `SITEWISE_OSM_EXTRACT_URL` | Geofabrik MY/SG/BN | regional extract |
| `SITEWISE_OVERPASS_URL` | `overpass-api.de` | Overpass endpoint |
| `SITEWISE_OVERPASS_ENABLED` | `1` | disable the Overpass route |
| `SITEWISE_REFRESH_OFFLINE` | `0` | no network calls |
| `SITEWISE_REFRESH_FIXTURE_DIR` | *(empty)* | offline fixture directory |
| `SITEWISE_CALCULATION_VERSION` | `geo-refresh-v1` | stamped on freshness rows |
| `SITEWISE_SOURCE_CHECK_INTERVAL_S` | `604800` | weekly |
| `SITEWISE_OSM_REFRESH_INTERVAL_S` | `604800` | weekly |
| `SITEWISE_ROADS_REFRESH_INTERVAL_S` | `2592000` | monthly |
| `SITEWISE_DEMOGRAPHICS_INTERVAL_S` | `2592000` | monthly |
| `SITEWISE_REFRESH_BATCH_SIZE` | `500` | write batch size |
| `SITEWISE_REFRESH_LOCK_KEY` | `814220261` | advisory lock key |

## 4. Commands

All commands run from `backend/`.

```bash
# 0. Create the additive tables (idempotent; also done by the Alembic revision)
.venv/Scripts/python.exe scripts/run_data_refresh.py --ensure-schema

# 1. Check source availability (no writes)
.venv/Scripts/python.exe scripts/run_data_refresh.py --check

# 2. Measure a run without writing (real parsing + affected-property count)
.venv/Scripts/python.exe scripts/run_data_refresh.py --once --source all \
    --kind competitors --dry-run

# 3. Offline verification against fixtures (no network)
.venv/Scripts/python.exe scripts/run_data_refresh.py --once --source all \
    --kind competitors --local-fixture tests/fixtures/geo --dry-run

# 4. Real incremental refresh (holds the advisory lock for the whole run)
.venv/Scripts/python.exe scripts/run_data_refresh.py --once --source osm --kind competitors

# 5. Freshness/provenance state
.venv/Scripts/python.exe scripts/run_data_refresh.py --status

# 6. Dedicated scheduler process (weekly sources, monthly roads/demographics)
.venv/Scripts/python.exe scripts/run_data_refresh.py --schedule

# 7. Windows Task Scheduler XML + registration command (not auto-registered)
.venv/Scripts/python.exe scripts/run_data_refresh.py --install-windows-task
schtasks /Create /TN "SiteWiseGeoRefresh" /XML "scripts\SiteWiseGeoRefresh.xml" /F
```

Python installs used by this implementation (already applied to `backend/.venv`):

```bash
.venv/Scripts/python.exe -m pip install "pyarrow>=18" "duckdb>=1.1" "shapely>=2" \
    "geopandas>=1.0" "osmnx>=2.0" "apscheduler>=3.10,<4"
```

`pyosmium` has **no Python 3.13 Windows wheel**; the PBF route is therefore
inactive on this machine and the collector falls back to Overpass/fixtures.

## 5. API surface (additive only)

| Endpoint | Purpose |
|---|---|
| `GET /api/v1/geospatial/property/{id}/freshness` | freshness + provenance for one property (authenticated) |
| `GET /api/v1/explore/analysis?ref=…` | existing payload now includes `freshness` and `provenance` |
| `GET /api/v1/staff/properties/{id}` | admin review detail now includes `freshness` and `provenance` |

The Admin verification detail renders the freshness pill, last successful
refresh, source release, calculation version, last error and the source
licences in the Location Intelligence tab. No duplicate Admin page exists.

## 6. Verified execution (real, measured)

| Run | Result |
|---|---|
| `--check` | Overture: 3 releases listed, latest `2026-10-21.0`. OSM: dated extract `malaysia-singapore-brunei-261109.osm.pbf`, 252,976,835 bytes, `Last-Modified 2026-11-10`. |
| Live Overture, bbox `101.565,3.055,101.605,3.095`, release `2026-10-21.0` | 405 records read, **200 accepted**, 205 rejected (`unsupported_category`), 26.3 s. Accepted sample: “Madeleine Cafe”, “Warung abang”, “Cendol SS15 Subang Jaya”. |
| Live OSM | **Blocked**: `pyosmium` unavailable for Python 3.13; `overpass-api.de` returned HTTP 502; a documented mirror timed out. Parsing/normalisation verified by fixtures + 41 tests. |
| Fixture OSM sync (5 real existing rows) | 0 inserted, 0 updated, **5 unchanged** — idempotency proven against the live table. |
| Fixture dry-run (Overture edge cases) | 4 read, 3 accepted, 1 rejected (`unsupported_category`) — bbox/out-of-area handling correct. |
| Live recalculation of property 89 | competitor 500 m 44→46, 1 km 53→55; **population preserved** (5921.1 / 24593.38); freshness `current`. |
| Test suite | **41 passed** (`tests/test_geo_refresh.py`); full suite: 376 passed, 3 skipped, 2 pre-existing data-dependent failures in `test_personalised_recommendations` (live verification state; module untouched by this change). |
| Lint | `ruff check` clean on all new/modified files. Dart: `dart analyze` clean on `shared_logic` and `fyp_jaspr_web/lib`. |

## 7. Limitations

1. **OSM live collection is blocked in this environment** — no `pyosmium`
   wheel for Python 3.13 (Windows) and the public Overpass endpoint is
   failing. The code path exists and is exercised by fixtures; a Linux worker
   with `pyosmium` (or a working Overpass endpoint) completes it.
2. **Overture reads a bounded subset of parquet parts** (`max_overture_parts`,
   default 16). A full-country refresh should raise the cap or run on a worker
   with local storage; the current cap keeps a refresh small.
3. **Feature calculation covers competitors, demand generators, roads and
   accessibility** — exactly what `enrichment_snapshot` supports. Population
   stays the per-property research dataset; a competitor refresh never
   recomputes or nulls it.
4. **`fyp.property_geospatial_features` has no unique constraint on
   `property_id`** in this deployment (documented in the repository), so the
   write remains UPDATE-then-INSERT and idempotent by construction.
5. **The live `fnb_outlet` table contains 3 pre-existing duplicate natural
   keys**, so a UNIQUE index was not added (it would fail). The staging table
   has the unique constraint; the live table gets a non-unique lookup index.
6. **Google Places is intentionally not part of the pipeline.** The Google key
   is used for address validation only; the automated pipeline must (and does)
   work without it.
