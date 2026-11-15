"""Scratch probe 2: district name domains + existing normalisation (delete when done)."""

from __future__ import annotations

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine

with Session(analytics_engine) as s:
    print("== DOSM district domains ==")
    for tbl in ("district_population", "district_age_population", "hh_income_district"):
        rows = s.execute(
            text(f"SELECT state, district, count(*), max(date) FROM public.{tbl} GROUP BY 1,2 ORDER BY 1,2")
        ).all()
        print(f"\n-- public.{tbl} --")
        for st, di, n, mx in rows:
            print(f"   state={st!r:24} district={di!r:26} rows={n:5} max_date={mx}")

    print("\n== subject_features join-key domains ==")
    rows = s.execute(
        text(
            """
            SELECT other_features->>'state_dosm' AS state_dosm,
                   other_features->>'district'    AS district,
                   count(*)
            FROM sitewise_analytics.subject_features
            GROUP BY 1,2 ORDER BY 3 DESC
            """
        )
    ).all()
    for st, di, n in rows:
        print(f"   state_dosm={st!r:24} district={di!r:26} subjects={n}")

    print("\n== how the income join succeeded for EP-01345 ==")
    row = (
        s.execute(
            text(
                """
                SELECT other_features->>'district_income_match_method' AS method,
                       other_features->>'district_income_join_status'  AS status,
                       other_features->>'district_income_year'         AS year,
                       other_features->>'district_income_median_myr'   AS median,
                       other_features->>'district'                     AS district,
                       other_features->>'state_dosm'                   AS state_dosm
                FROM sitewise_analytics.subject_features
                WHERE canonical_property_id = 'EP-01345'
                LIMIT 1
                """
            )
        )
        .mappings()
        .first()
    )
    print("  ", dict(row) if row else None)

    print("\n== income join status distribution ==")
    rows = s.execute(
        text(
            """
            SELECT other_features->>'district_income_match_method' AS method,
                   other_features->>'district_income_join_status'  AS status,
                   count(*)
            FROM sitewise_analytics.subject_features
            GROUP BY 1,2 ORDER BY 3 DESC
            """
        )
    ).all()
    for r in rows:
        print("  ", tuple(r))

    print("\n== vw_latest_district_statistics ==")
    try:
        d = s.execute(text("SELECT pg_get_viewdef('public.vw_latest_district_statistics'::regclass, true)")).scalar()
        print(d)
        cols = s.execute(
            text(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema='public' AND table_name='vw_latest_district_statistics' ORDER BY ordinal_position"
            )
        ).scalars().all()
        print("  cols:", cols)
        print("  KL:", s.execute(
            text("SELECT * FROM public.vw_latest_district_statistics WHERE state ILIKE '%uala%' OR district ILIKE '%uala%' LIMIT 5")
        ).mappings().all())
    except Exception as exc:
        print("  ERROR:", str(exc)[:300])
        s.rollback()

    print("\n== public.district_demographic ==")
    try:
        cols = s.execute(
            text("SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='district_demographic' ORDER BY ordinal_position")
        ).all()
        print("  cols:", cols)
        print("  rows:", s.execute(text("SELECT count(*) FROM public.district_demographic")).scalar())
        print("  sample:", [dict(r) for r in s.execute(text("SELECT * FROM public.district_demographic LIMIT 3")).mappings().all()])
    except Exception as exc:
        print("  ERROR:", str(exc)[:200])
        s.rollback()

    print("\n== fyp.rental_properties state values (sample) ==")
    rows = s.execute(text("SELECT state, count(*) FROM fyp.rental_properties GROUP BY 1 ORDER BY 2 DESC LIMIT 20")).all()
    for r in rows:
        print("  ", tuple(r))
