-- SiteWise demand generator backfill verification (run AFTER --apply).
-- Uses only canonical fyp.* tables, not sitewise_analytics training rows.
SELECT
  count(*) AS total_properties,
  count(*) FILTER (WHERE g.demand_generator_count_500m IS NOT NULL) AS curated_500m_measured,
  count(*) FILTER (WHERE g.demand_generator_count_1km IS NOT NULL) AS curated_1km_measured,
  count(*) FILTER (WHERE g.office_pois_500m IS NOT NULL) AS offices_500m_measured,
  count(*) FILTER (WHERE g.malls_count_1000m IS NOT NULL) AS malls_1km_measured,
  count(*) FILTER (WHERE g.universities_colleges_count_500m IS NOT NULL) AS universities_500m_measured,
  count(*) FILTER (WHERE g.office_pois_500m > 0) AS properties_near_offices,
  count(*) FILTER (WHERE g.malls_count_1000m > 0) AS properties_near_malls,
  count(*) FILTER (WHERE g.universities_colleges_count_500m > 0) AS properties_near_universities
FROM fyp.rental_properties p
LEFT JOIN fyp.property_geospatial_features g ON g.property_id = p.id;

SELECT p.id, p.name, p.state,
       g.demand_generator_count_500m,
       g.demand_generator_count_1km,
       g.office_pois_500m,
       g.malls_count_1000m,
       g.universities_colleges_count_500m,
       g.schools_count_500m,
       g.supermarkets_count_500m,
       g.retail_pois_500m,
       g.hospitals_count_500m,
       e.status AS enrichment_status
FROM fyp.rental_properties p
LEFT JOIN fyp.property_geospatial_features g ON g.property_id = p.id
LEFT JOIN fyp.property_enrichment_category e
  ON e.property_id = p.id AND e.category = 'demand_generators'
ORDER BY p.id
LIMIT 40;
