"""Scrack probe 3: sex-disaggregated DOSM data + ambiguity of district names (delete when done)."""

from __future__ import annotations

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine

DEMO = [
    ("public", "district_demographic"),
    ("public", "state_population"),
    ("public", "population_malaysia"),
    ("fnb_a", "district_stats"),
    ("fnb_a", "district_income"),
    ("fnb_a", "district_population"),
    ("popfeat", "district"),
    ("public", "gadm_districts"),
    ("public", "labor_force_statistics_district"),
    ("public", "hh_income_parlimen"),
    ("public", "dun_income"),
]

with Session(analytics_engine) as s:
    for sch, tbl in DEMO:
        print(f"\n== {sch}.{tbl} ==")
        try:
            cols = s.execute(
                text(
                    "SELECT column_name, data_type FROM information_schema.columns "
                    "WHERE table_schema=:s AND table_name=:t ORDER BY ordinal_position"
                ),
                {"s": sch, "t": tbl},
            ).all()
            if not cols:
                print("  (absent)")
                continue
            print("  cols:", ", ".join(f"{c}:{t}" for c, t in cols))
            n = s.execute(text(f'SELECT count(*) FROM "{sch}"."{tbl}"')).scalar()
            print("  rows:", n)
            sample = s.execute(text(f'SELECT * FROM "{sch}"."{tbl}" LIMIT 2')).mappings().all()
            for r in sample:
                print("  ", dict(r))
        except Exception as exc:  # noqa: BLE001
            print("  ERROR:", str(exc)[:200])
            s.rollback()

    print("\n== district names shared by >1 state in the DOSM age table ==")
    rows = s.execute(
        text("SELECT district, count(DISTINCT state) n, array_agg(DISTINCT state) FROM public.district_age_population GROUP BY district HAVING count(DISTINCT state) > 1")
    ).all()
    print("  ", rows or "none")

    print("\n== any 'Kuala Lumpur' district value anywhere? ==")
    for tbl in ("district_population", "district_age_population", "hh_income_district"):
        r = s.execute(
            text(f"SELECT DISTINCT state, district FROM public.{tbl} WHERE district ILIKE '%uala%umpur%'")
        ).all()
        print(f"  {tbl}: {r}")

    print("\n== KL age bands, latest date: full band list + sum vs district_population ==")
    rows = s.execute(
        text(
            """
            SELECT age, population_persons FROM public.district_age_population
            WHERE state='W.P. Kuala Lumpur' AND district='W.P. Kuala Lumpur'
              AND date = (SELECT max(date) FROM public.district_age_population
                          WHERE state='W.P. Kuala Lumpur' AND district='W.P. Kuala Lumpur')
            ORDER BY age
            """
        )
    ).all()
    total = sum(int(p) for _, p in rows)
    print("  bands:", [a for a, _ in rows])
    print("  sum of bands:", total)
    latest_pop = s.execute(
        text(
            "SELECT date, population_persons FROM public.district_population "
            "WHERE state='W.P. Kuala Lumpur' AND district='W.P. Kuala Lumpur' ORDER BY date DESC LIMIT 2"
        )
    ).all()
    print("  district_population latest:", latest_pop)
    years = s.execute(
        text(
            "SELECT DISTINCT date FROM public.district_age_population "
            "WHERE state='W.P. Kuala Lumpur' ORDER BY 1"
        )
    ).scalars().all()
    print("  age dates:", years)
    per_date = s.execute(
        text(
            "SELECT date, count(*), sum(population_persons) FROM public.district_age_population "
            "WHERE state='W.P. Kuala Lumpur' GROUP BY 1 ORDER BY 1"
        )
    ).all()
    print("  per-date rows/sum:", per_date)

    print("\n== subject_features district keys that resolve under the DOSM domain ==")
    rows = s.execute(
        text(
            """
            WITH keys AS (
              SELECT DISTINCT other_features->>'state_dosm' st, other_features->>'district' di
              FROM sitewise_analytics.subject_features
            )
            SELECT keys.st, keys.di,
                   (p.district IS NOT NULL) AS pop_exact,
                   (a.district IS NOT NULL) AS age_exact,
                   (i.district IS NOT NULL) AS income_exact
            FROM keys
            LEFT JOIN (SELECT DISTINCT state, district FROM public.district_population) p
                   ON p.state = keys.st AND p.district = keys.di
            LEFT JOIN (SELECT DISTINCT state, district FROM public.district_age_population) a
                   ON a.state = keys.st AND a.district = keys.di
            LEFT JOIN (SELECT DISTINCT state, district FROM public.hh_income_district) i
                   ON i.state = keys.st AND i.district = keys.di
            ORDER BY keys.st NULLS LAST, keys.di NULLS LAST
            """
        )
    ).all()
    for r in rows:
        print("  ", tuple(r))
