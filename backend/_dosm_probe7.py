"""Scratch probe 7: resolution coverage for the 955 catalogue properties (delete when done)."""

from __future__ import annotations

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine

SQL = """
WITH dom AS (SELECT DISTINCT state, district FROM public.district_age_population),
u AS (
  SELECT c.id,
         p.dosm_district_key,
         p.geography_match_status,
         p.gadm_state_name,
         f.other_features->>'state_dosm' AS lbl_state,
         f.other_features->>'district'   AS lbl_district
  FROM fyp.catalogue_properties c
  LEFT JOIN fyp_features.property_population_spatial p
         ON p.source_record_id = c.id AND p.source_record_type = 'SITEWISE_U_PROPERTY'
  LEFT JOIN LATERAL (
    SELECT other_features FROM sitewise_analytics.subject_features s
    WHERE s.canonical_property_id = c.id
    ORDER BY s.imported_at DESC NULLS LAST LIMIT 1
  ) f ON true
)
SELECT count(*) total,
       count(*) FILTER (WHERE dosm_district_key IS NOT NULL) with_key,
       count(*) FILTER (WHERE dosm_district_key IS NOT NULL AND geography_match_status='MATCHED') matched_key,
       count(*) FILTER (WHERE dosm_district_key IS NOT NULL AND geography_match_status<>'MATCHED') unmatched_key,
       count(*) FILTER (WHERE geography_match_status IS NULL) no_spatial_row,
       count(*) FILTER (WHERE dosm_district_key IS NOT NULL AND geography_match_status='MATCHED'
                        AND EXISTS (SELECT 1 FROM dom WHERE dom.district = u.dosm_district_key)) key_resolves,
       count(*) FILTER (WHERE dosm_district_key IS NOT NULL AND geography_match_status='MATCHED'
                        AND EXISTS (SELECT 1 FROM dom WHERE dom.district = u.dosm_district_key)
                        AND lbl_district = dosm_district_key) key_equals_label,
       count(*) FILTER (WHERE dosm_district_key IS NOT NULL AND geography_match_status='MATCHED'
                        AND EXISTS (SELECT 1 FROM dom WHERE dom.district = u.dosm_district_key)
                        AND lbl_district IS DISTINCT FROM dosm_district_key) label_disagrees,
       count(*) FILTER (WHERE dosm_district_key IS NULL AND EXISTS (SELECT 1 FROM dom WHERE dom.state=u.lbl_state AND dom.district=u.lbl_district)) label_only_exact,
       count(*) FILTER (WHERE (dosm_district_key IS NOT NULL AND geography_match_status='MATCHED'
                        AND NOT EXISTS (SELECT 1 FROM dom WHERE dom.district = u.dosm_district_key))
                        OR (dosm_district_key IS NULL AND NOT EXISTS (SELECT 1 FROM dom WHERE dom.state=u.lbl_state AND dom.district=u.lbl_district))
                       ) unresolved_now
FROM u
"""

with Session(analytics_engine) as s:
    row = s.execute(text(SQL)).mappings().first()
    print(dict(row))

    print("\n== dosm_district_key values on MATCHED U rows and their resolution ==")
    rows = s.execute(
        text(
            """
            SELECT p.dosm_district_key k,
                   (SELECT count(DISTINCT state) FROM public.district_age_population a WHERE a.district = p.dosm_district_key) states,
                   count(*) n
            FROM fyp_features.property_population_spatial p
            JOIN fyp.catalogue_properties c ON c.id = p.source_record_id
            WHERE p.source_record_type = 'SITEWISE_U_PROPERTY'
            GROUP BY 1,2 ORDER BY 3 DESC
            """
        )
    ).all()
    for r in rows:
        print("  ", tuple(r))

    print("\n== disagreeing-label examples (spatial key wins) ==")
    rows = s.execute(
        text(
            """
            SELECT p.dosm_district_key, f.other_features->>'state_dosm', f.other_features->>'district', count(*)
            FROM fyp.catalogue_properties c
            JOIN fyp_features.property_population_spatial p
              ON p.source_record_id = c.id AND p.source_record_type='SITEWISE_U_PROPERTY'
                 AND p.geography_match_status='MATCHED'
            JOIN LATERAL (SELECT other_features FROM sitewise_analytics.subject_features s
                          WHERE s.canonical_property_id = c.id
                          ORDER BY s.imported_at DESC NULLS LAST LIMIT 1) f ON true
            WHERE f.other_features->>'district' IS DISTINCT FROM p.dosm_district_key
            GROUP BY 1,2,3 ORDER BY 4 DESC LIMIT 15
            """
        )
    ).all()
    for r in rows:
        print("  spatial=%-22 label=(%s | %s) n=%s" % r)

    print("\n== spatial rows per property (duplicates?) ==")
    print("  ", s.execute(
        text("SELECT n_rows, count(*) FROM (SELECT source_record_id, count(*) n_rows FROM fyp_features.property_population_spatial WHERE source_record_type='SITEWISE_U_PROPERTY' GROUP BY 1) x GROUP BY 1 ORDER BY 1")
    ).all())
