"""Scratch probe: DOSM district demographic join for EP-01345 (delete when done)."""

from __future__ import annotations

import json
import sys

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine
from sitewise.db.session import engine

print("analytics engine:", analytics_engine.url.render_as_string(hide_password=True))
print("app engine:", engine.url.render_as_string(hide_password=True))

TABLES = (
    "district_population",
    "district_age_population",
    "hh_income_district",
    "state_population",
    "state_age_population",
    "district_income",
    "household_income",
)

with Session(analytics_engine) as s:
    rows = s.execute(
        text(
            """
            SELECT table_schema, table_name
            FROM information_schema.tables
            WHERE table_name ILIKE '%district%'
               OR table_name ILIKE '%population%'
               OR table_name ILIKE '%income%'
               OR table_name ILIKE '%age%'
               OR table_name ILIKE '%dosm%'
            ORDER BY table_schema, table_name
            """
        )
    ).all()
    print("\n== candidate tables ==")
    for schema, name in rows:
        print(f"  {schema}.{name}")

    print("\n== schemas ==")
    for (sch,) in s.execute(text("SELECT schema_name FROM information_schema.schemata ORDER BY 1")).all():
        print("  ", sch)

with Session(analytics_engine) as s:
    for schema, name in [
        ("public", "district_population"),
        ("public", "district_age_population"),
        ("public", "hh_income_district"),
    ]:
        print(f"\n== {schema}.{name} ==")
        try:
            cols = s.execute(
                text(
                    """
                    SELECT column_name, data_type
                    FROM information_schema.columns
                    WHERE table_schema = :sch AND table_name = :tbl
                    ORDER BY ordinal_position
                    """
                ),
                {"sch": schema, "tbl": name},
            ).all()
            if not cols:
                print("  MISSING (no columns)")
                continue
            for c, t in cols:
                print(f"  {c}: {t}")
            cnt = s.execute(text(f'SELECT count(*) FROM "{schema}"."{name}"')).scalar()
            print("  rows:", cnt)
            print("  distinct state:", s.execute(text(f'SELECT DISTINCT state FROM "{schema}"."{name}" ORDER BY 1 LIMIT 30')).scalars().all())
            kl = s.execute(
                text(f'SELECT * FROM "{schema}"."{name}" WHERE state ILIKE :p OR district ILIKE :p LIMIT 12'),
                {"p": "%uala%umpur%"},
            ).mappings().all()
            for r in kl:
                print("  KL:", dict(r))
        except Exception as exc:  # noqa: BLE001
            print("  ERROR:", type(exc).__name__, str(exc)[:300])
            s.rollback()

with Session(analytics_engine) as s:
    print("\n== EP-01345 analysis row join keys ==")
    row = (
        s.execute(
            text(
                "SELECT canonical_property_id, other_features, analysis_status "
                "FROM sitewise_analytics.subject_features "
                "WHERE canonical_property_id = :pid "
                "ORDER BY imported_at DESC NULLS LAST LIMIT 1"
            ),
            {"pid": "EP-01345"},
        )
        .mappings()
        .first()
    )
    if row is None:
        print("  no subject_features row")
    else:
        extra = row["other_features"] or {}
        print("  district:", repr(extra.get("district")))
        print("  state_dosm:", repr(extra.get("state_dosm")))
        print("  state:", repr(extra.get("state")))
        print("  district_income_join_status:", repr(extra.get("district_income_join_status")))
        print("  keys:", sorted(extra)[:60])

    print("\n== catalogue listing row for EP-01345 ==")
    listing = (
        s.execute(
            text(
                "SELECT id, address, city, state, postcode, latitude, longitude "
                "FROM fyp.catalogue_properties WHERE id = :pid"
            ),
            {"pid": "EP-01345"},
        )
        .mappings()
        .first()
    )
    print("  ", dict(listing) if listing else None)
