"""Scratch probe 4: current evidence payload district block for several properties (delete when done)."""

from __future__ import annotations

import json

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine
from sitewise.repositories.catalog_repository import CatalogRepository

PIDS = ["EP-01345"]
with Session(analytics_engine) as s:
    rows = s.execute(
        text(
            """
            SELECT canonical_property_id,
                   other_features->>'state_dosm' AS st,
                   other_features->>'district'   AS di,
                   other_features->>'district_income_join_status' AS inc
            FROM sitewise_analytics.subject_features
            WHERE canonical_property_id IN ('EP-01345')
               OR (other_features->>'state_dosm' = 'Selangor' AND other_features->>'district' = 'Petaling')
               OR (other_features->>'state_dosm' = 'Johor'   AND other_features->>'district' = 'Johor Bahru')
               OR (other_features->>'state_dosm' = 'Pulau Pinang' AND other_features->>'district' = 'Timur Laut')
               OR (other_features->>'state_dosm' = 'Selangor' AND other_features->>'district' = 'Hulu Langat')
               OR (other_features->>'state_dosm' = 'W.P. Kuala Lumpur' AND other_features->>'district' = 'W.P. Kuala Lumpur')
            ORDER BY 2, 3
            LIMIT 400
            """
        )
    ).all()
    picks = {}
    for pid, st, di, inc in rows:
        key = (st, di)
        if key not in picks:
            picks[key] = pid
    picks[("W.P. Kuala Lumpur", "Kuala Lumpur")] = "EP-01345"

with Session(analytics_engine) as s:
    repo = CatalogRepository(s)
    for (st, di), pid in sorted(picks.items(), key=lambda kv: str(kv[0])):
        ev = repo.get_evidence(pid)
        ds = ev.get("district_statistics") or {}
        pop_metric = next(
            (m for g in ev.get("groups", []) for m in g["metrics"] if m["key"] == "district_population"),
            None,
        )
        print(f"\n### {pid}  state_dosm={st!r} district={di!r}")
        print("   district_statistics.available:", ds.get("available"), "| reason:", ds.get("reason"))
        print("   age_groups:", len(ds.get("age_groups", []) or []))
        print("   district_population:", ds.get("district_population"), ds.get("population_as_of"))
        print("   male/female:", ds.get("male_population"), ds.get("female_population"))
        print("   income:", ds.get("income_median_myr"), ds.get("income_as_of"))
        print("   metric district_population:", json.dumps(pop_metric, ensure_ascii=False) if pop_metric else None)
