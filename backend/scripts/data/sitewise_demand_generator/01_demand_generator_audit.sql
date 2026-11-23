-- SiteWise demand-generator audit (READ-ONLY)
-- Paste into Supabase SQL Editor or run with psql against the operational database.
-- No migration, no writes. Run each SELECT separately if your client limits results.

-- 1. Confirm source and canonical target availability in THIS database.
-- When the backend uses separate operational/analytics databases, source tables
-- may be found only in the other database. Use the Python bridge for that case.
SELECT
  to_regclass('fyp.rental_properties') AS rental_properties,
  to_regclass('fyp.property_geospatial_features') AS property_geospatial_features,
  to_regclass('demand_gen.subjects') AS curated_demand_generators,
  to_regclass('demand_gen.pois_master') AS categorised_pois,
  to_regclass('fyp.property_enrichment_category') AS enrichment_status;

-- 2. Count existing/missing operational measurements. NULL means not measured;
-- a genuine numeric 0 can be measured in an area with no nearby generators.
SELECT
  count(*) AS total_properties,
  count(*) FILTER (WHERE p.latitude IS NOT NULL AND p.longitude IS NOT NULL) AS properties_with_coordinates,
  count(*) FILTER (WHERE g.property_id IS NULL) AS properties_without_geo_row,
  count(*) FILTER (WHERE g.demand_generator_count_500m IS NULL) AS missing_demand_500m,
  count(*) FILTER (WHERE g.demand_generator_count_1km IS NULL) AS missing_demand_1km,
  count(*) FILTER (WHERE g.demand_generator_count_500m IS NOT NULL
                     AND g.demand_generator_count_1km IS NOT NULL) AS demand_totals_available
FROM fyp.rental_properties AS p
LEFT JOIN fyp.property_geospatial_features AS g ON g.property_id = p.id;

-- 3. Check available demand POI columns before/after the backfill.
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'fyp' AND table_name = 'property_geospatial_features'
  AND (column_name LIKE 'demand_generator_%' OR
       column_name IN ('office_pois_500m','office_pois_1000m',
                        'schools_count_500m','schools_count_1000m',
                        'universities_colleges_count_500m','universities_colleges_count_1000m',
                        'retail_pois_500m','retail_pois_1000m',
                        'malls_count_500m','malls_count_1000m',
                        'hospitals_count_500m','hospitals_count_1000m',
                        'supermarkets_count_500m','supermarkets_count_1000m'))
ORDER BY column_name;

-- 4. What the Add Property enrichment pipeline currently reports.
-- Omit this query when the status table in query 1 is missing.
SELECT status, count(*) AS property_count
FROM fyp.property_enrichment_category
WHERE category = 'demand_generators'
GROUP BY status ORDER BY status;
