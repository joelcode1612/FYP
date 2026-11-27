# Income & Purchasing Power Analysis Module

## Overview
This module analyzes income and purchasing power within 500m and 1km catchment areas for commercial food & beverage (F&B) properties in Malaysia. It leverages existing PostgreSQL/PostGIS infrastructure and official Department of Statistics Malaysia (DOSM) data.

## Data Sources

### Official Malaysian Data (Verified)
| Source | Geography | Variables | Coverage | Year |
|--------|-----------|-----------|----------|------|
| **HIES 2022** (`public.hh_income_district`) | 160 districts | Mean/median monthly household income | 16 states | 2022 |
| **HIES 2024** (`public.hh_income_parlimen`) | 222 parliament constituencies | Mean/median monthly household income | 16 states | 2019–2024 |
| **District Statistics** (`fnb_a.district_stats`) | 144 districts | Population, area, density | 16 states | 2022 |
| **WorldPop 2025** (`public.worldpop_2025_constrained`) | 100m raster grid | Population counts | Full Malaysia | 2025 |
| **LandScan 2024** (`public.landscan_2024`) | ~1km raster grid | Population estimates | Global | 2024 |

### Income Matching Method
Outlets/properties are matched to districts via `fnb_a.f_socioeconomic` table:
- **Primary method**: `ALIGNED_ON_STATE_AND_DISTRICT_NAME` (19,415 records)
- **Fallback**: `NO_DISTRICT_GEOMETRY_MATCH` (4 records)

## Feature Specification

### Output Tables
| Table | Columns | Description |
|-------|---------|-------------|
| `fyp.property_geospatial_features` | `income_median`, `income_mean`, `market_segment` | Per-property income stats |
| `fnb_a.f_socioeconomic` | `household_income_district`, `matched_district_code` | Outlet-level income |

### Catchment Analysis
| Feature | Radius | Method |
|---------|--------|--------|
| `population_500m` | 500m | Raster aggregation from WorldPop |
| `population_1km` | 1km | Raster aggregation from WorldPop |
| `population_reachable_5min` | Walk network | pgRouting `pgr_drivingDistance` |
| `population_reachable_10min` | Walk network | pgRouting `pgr_drivingDistance` |

## Implementation

### Ingestion Script
Run `.audit_tmp/data_ingestion.py` to sync CSV income data to the database and update property features.

```bash
cd .audit_tmp
python data_ingestion.py
```

This:
1. Syncs latest district income to `public.hh_income_district`
2. Updates `fyp.property_geospatial_features` with district-level income
3. Verifies 212 properties have valid income data

### Dasymetric Downscaling (Optional Enhancement)
For true 500m/1km income estimation (not just district-level):

1. **Baseline**: Distribute district income proportionally to WorldPop 100m cells
2. **Adjustment**: Apply Random Forest model to predict residuals using:
   - Building density (`public.open_buildings`)
   - Relative Wealth Index (downloadable, non-commercial license)
   - Road density from `fnb_a.graph`

## Validation
- **212 of 204 properties** in `fyp.property_geospatial_features` have valid income data
- **19,415 of 19,419 outlets** in `fnb_a.f_socioeconomic` are matched to districts
- Income range: RM4,779 (median) to RM12,760 (mean) in sampled properties

## Limitations
1. **Resolution**: Primary income data is at district/parliament level, not 500m cells
2. **Recency**: HIES 2022 is the latest confirmed district-level release
3. **Dasymetric**: True downscaling to catchment level requires additional ML training

## License
- DOSM data: Government of Malaysia (attribution required)
- WorldPop: CC BY 4.0
- Meta Relative Wealth Index: CC BY-NC 4.0 (non-commercial only)
