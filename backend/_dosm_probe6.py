"""Scratch probe 6: existing verified district assignment per property (delete when done)."""

from __future__ import annotations

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine

with Session(analytics_engine) as s:
    print("== fyp_features.property_population_spatial columns ==")
    cols = s.execute(
        text(
            "SELECT column_name, data_type FROM information_schema.columns "
            "WHERE table_schema='fyp_features' AND table_name='property_population_spatial' "
            "ORDER BY ordinal_position"
        )
    ).all()
    print("  ", [c for c, _ in cols])

    print("\n== rows for EP-01345 / MD-00510 ==")
    rows = s.execute(
        text(
            "SELECT source_record_type, source_record_id, original_identifier, state, "
            "gadm_state_name, gadm_admin2_name, dosm_district_key, geography_match_status "
            "FROM fyp_features.property_population_spatial "
            "WHERE original_identifier IN ('EP-01345','MD-00510') OR source_record_id IN ('EP-01345','MD-00510')"
        )
    ).mappings().all()
    for r in rows:
        print("  ", dict(r))

    print("\n== record types and id forms ==")
    print("  ", s.execute(text("SELECT source_record_type, count(*) FROM fyp_features.property_population_spatial GROUP BY 1")).all())

    print("\n== dosm_district_key domain vs DOSM age domain ==")
    rows = s.execute(
        text(
            """
            WITH keys AS (
              SELECT DISTINCT dosm_district_key AS k
              FROM fyp_features.property_population_spatial
              WHERE dosm_district_key IS NOT NULL
            )
            SELECT keys.k,
                   (SELECT count(*) FROM (SELECT DISTINCT state, district FROM public.district_age_population) a
                     WHERE a.district = keys.k) AS matches_in_age_domain
            FROM keys ORDER BY 1
            """
        )
    ).all()
    amb = [k for k, n in rows if n != 1]
    print(f"  distinct keys={len(rows)}  keys matching exactly one age-domain district={len(rows)-len(amb)}")
    print("  problematic:", amb[:30])

    print("\n== does the age domain have names unique across states? (all tables) ==")
    for tbl in ("district_age_population", "district_population", "hh_income_district"):
        r = s.execute(
            text(f"SELECT district, count(DISTINCT state) n FROM public.{tbl} GROUP BY district HAVING count(DISTINCT state)>1")
        ).all()
        print(f"  {tbl}: {r if r else 'all district names unique'}")

    print("\n== public.malaysia_admin_hierarchy ==")
    cols = s.execute(
        text("SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='malaysia_admin_hierarchy' ORDER BY ordinal_position")
    ).all()
    print("  cols:", cols)
    if cols:
        n = s.execute(text("SELECT count(*) FROM public.malaysia_admin_hierarchy")).scalar()
        print("  rows:", n)
        for r in s.execute(text("SELECT * FROM public.malaysia_admin_hierarchy LIMIT 2")).mappings().all():
            d = dict(r)
            d.pop("geom", None)
            print("  ", d)
        print("  KL point-in-polygon EP-01345:")
        pip = s.execute(
            text(
                """
                SELECT * FROM public.malaysia_admin_hierarchy
                WHERE ST_Contains(geom, ST_SetSRID(ST_MakePoint(101.69704547, 3.1658575), 4326))
                """
            )
        ).mappings().all()
        for r in pip:
            d = dict(r)
            d.pop("geom", None)
            print("    ", d)
    print("\n== subject_features: how many rows have canonical_property_id (U) vs not ==")
    print("  ", s.execute(text("SELECT count(*) FILTER (WHERE canonical_property_id IS NOT NULL) with_cid, count(*) total FROM sitewise_analytics.subject_features")).all())
