# SiteWise — Expanded64_v2 Historical Feature Recalculation Package

**Definition version:** `expanded64-feature-definitions-v1`
**Source database:** `Final_Location_Analysis` on local PostgreSQL 18.4 / PostGIS 3.6.2 (read-only during extraction)
**Subjects:** 1,796 (880 positive `P`, 916 unlabeled `U`)
**Target measurements:** 10,776 = 1,796 × 6, subject to actual source coverage

This package contains the executed recalculation of the six features that are being standardised for the separate Expanded64_v2 retraining. It does **not** retrain a model, replace artifacts, activate Expanded64_v2, or modify any production record or score.

## Deliverables

| File | Contents |
|---|---|
| `expanded64_v2_recalculated_features.csv` | One row per original subject with the six recalculated values, definition version and provenance (per-group status, pixel counts, hull validity, snap distance, raster coverage, reasons). |
| `expanded64_v2_feature_comparison.csv` | Per-feature original/recalculated counts, exact and tolerance matches, MAD/median/RMSE, extrema, distribution statistics, Pearson and Spearman correlations, and P-vs-U coverage. |
| `expanded64_v2_subject_comparison.csv` | 10,776 rows: subject, class, feature, original value, recalculated value, difference. |
| `expanded64_v2_missing_features.csv` | Every subject/feature whose recalculation was unavailable, with the recorded reason and status. |
| `expanded64_v2_source_inventory.json` | Read-only inventory of the five source tables, PostGIS version and source-version tables. |
| `expanded64_v2_extraction_summary.json` | Run identity, counts, per-feature outcome summary and governance assertions. |
| `expanded64_v2_remaining58_validation.csv` / `.json` | Read-only assessment of the other 58 features; 18 are flagged unresolved and all historical values are retained unchanged. |
| `expanded64_v2_runtime_feature_handoff.md` | Exact calculator SQL, geometry filters, units, buffer methodology and parity caveats for the ML workstream. |
| `original_training_data/SiteWise_PU_1796_Expanded_Observed.csv` | Unmodified source dataset (1,796 rows; 74 columns; 880 P / 916 U). |
| `sql/` | Executed read-only source-inventory SQL, extraction note and verbatim calculator SQL. |
| `source/` | Executed Python scripts: source validation, extraction, export/comparison, remaining-58 assessment. |
| `logs/` | Timestamped source-inventory and extraction logs. |
| `checkpoints/` | Resumable per-subject JSONL records; one line per completed subject. |

## Method

1. **Dataset verification.** `SiteWise_PU_1796_Expanded_Observed.csv` was checked against the active `sitewise_pu_64_expanded` artifact: 64/64 feature names present, 1,796 unique subject ids, valid coordinates, and the frozen SHAP background has the identical 64-name order.
2. **Source validation.** `source/validate_sources.py` ran read-only counts/validity/extent checks. Findings are in the inventory JSON; none of the runtime definitions were changed.
3. **Extraction.** `source/extract_expanded64_v2.py` imported `Expanded64CoordinateExtractor` and `CoordinateFeatureExtractor` from the SiteWise runtime and selected only `road_geometry`, `population_rings` and `isochrone_population`. Every statement ran inside `SET TRANSACTION READ ONLY`; subjects were processed in controlled batches with eight worker slices, each with its own append-only checkpoint. Failed subjects were logged individually and left NULL.
4. **Export/comparison.** `source/export_and_compare.py` produced the four CSVs and the summary JSON.

## Tolerance and comparison notes

Original training values carry full precision, while runtime calculators round their output (500 m densities: 3 decimals; population rings: 1 decimal; walk isochrone area: 4 decimals; walk-reachable population: 3 decimals). `tolerance_match_count` uses one half of the last reported unit for each feature, stated explicitly in `expanded64_v2_feature_comparison.csv`. Exact matches are reported separately and are expected to be rare for rounded features. Correlations are computed only on paired finite values; they describe association, not equivalence of definitions.

## Known source issues (reported, not silently fixed)

- `fyp_features.roads_v2`: 1,922,416 rows, no invalid geometries, 28 duplicate geometry groups (29 rows). Not altered.
- `fyp_features.road_junctions_v2`: coverage is limited to Peninsular Malaysia (~100.25–104.23 E, 1.38–5.54 N) while `roads_v2` spans 99.66–119.26 E. Junction density is not one of the six features.
- `public.worldpop_2025_constrained`: 2,677 tiles, 100 m pixels, SRID 4326, nodata −99999; extent covers Malaysia. Some subjects can still fall outside raster coverage and remain NULL.
- `public.psense_edges`: 1,592,732 edges, all cost fields present; 1,576,859 in a walk component, 17,999 motorway/motorway_link edges excluded from walking. Per-subject snap distance, hull node count and failure reasons are exported.
- The 600 s hull budget was kept at the runtime's 1200 s search budget with `agg_cost <= 600` vertex filter. A trial confirmed identical area and hull WKB when the search budget was lowered to 600 on sample subjects, but the extraction used the unmodified runtime query.

## Reproducing the extraction

Install `requirements.txt`, then from the package root:

```bash
export DATABASE_URL='postgresql+psycopg2://<user>:<password>@localhost:5432/Final_Location_Analysis'
python source/validate_sources.py
python source/extract_expanded64_v2.py --batch-size 25 --workers 8
python source/export_and_compare.py
python source/validate_remaining58.py
```

`DATABASE_URL` is supplied by the caller. No credential is stored in this package, its scripts, SQL, logs or checkpoints. Re-running the extraction skips subject ids already present in any `checkpoints/extraction_progress*.jsonl` file; delete those files only if a full recomputation is intended.

## Restrictions honoured

- Original training dataset and coordinates unchanged; every original subject id preserved.
- No historical value was substituted for a failed recalculation; unavailable measurements stay NULL with reasons.
- No fabricated zeros, no silent sample exclusion.
- No production property record, prediction score, model artifact or recommendation architecture was changed.
- Expanded64_v2 was not activated; retraining remains the responsibility of the downstream ML workstream.
