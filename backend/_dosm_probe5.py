"""Scratch probe 5: validate male/female rows in the official CSV against the DB domain.

Delete when done.
"""

from __future__ import annotations

import csv
import gzip
import io
import os
from collections import defaultdict

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine

CSV_PATH = os.path.expandvars("$LOCALAPPDATA/Temp/population_district.csv")

with analytics_engine.connect() as conn:
    domain = {(st, di, dt.isoformat()) for st, di, dt in conn.execute(
        text("SELECT state, district, date FROM public.district_population")
    )}
    districts = {(st, di) for st, di, _ in domain}
    existing_cols = {
        r[0]
        for r in conn.execute(
            text(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema='public' AND table_name='district_population'"
            )
        )
    }
print("DB domain rows:", len(domain), "districts:", len(districts), "cols:", sorted(existing_cols))

series: dict[tuple[str, str, str], dict[str, float]] = defaultdict(dict)
ages_seen = set()
sexes_seen = set()
with gzip.open(CSV_PATH, "rt", encoding="utf-8-sig") if CSV_PATH.endswith(".gz") else open(CSV_PATH, newline="", encoding="utf-8-sig") as fh:
    for row in csv.DictReader(fh):
        key = (row["state"], row["district"], row["date"])
        if key not in domain:
            continue
        sexes_seen.add(row["sex"])
        if row["age"] == "overall" and row["ethnicity"] == "overall":
            series[key][row["sex"]] = float(row["population"])
        ages_seen.add(row["age"])

print("sexes in matched rows:", sorted(sexes_seen))
print("age labels sample:", sorted(ages_seen)[:6], "...", sorted(ages_seen)[-3:])
print("matched series:", len(series), "of", len(domain))

bad = []
kl = []
for key, vals in sorted(series.items()):
    both, male, female = vals.get("both"), vals.get("male"), vals.get("female")
    if both is None or male is None or female is None:
        bad.append((key, "missing component", both, male, female))
        continue
    if abs(male + female - both) > 0.5:
        bad.append((key, "M+F != both", both, male, female))
    if key[0] == "W.P. Kuala Lumpur":
        kl.append((key[2], both, male, female, int(round(both * 1000)), int(round(male * 1000)), int(round(female * 1000))))

print("\nW.P. Kuala Lumpur (date, both_k, male_k, female_k, both_persons, male_persons, female_persons):")
for row in kl:
    print("  ", row)
print("\nintegrity problems:", len(bad))
for b in bad[:10]:
    print("  ", b)

with analytics_engine.connect() as conn:
    db_pop = {
        (st, di, dt.isoformat()): persons
        for st, di, dt, persons in conn.execute(
            text("SELECT state, district, date, population_persons FROM public.district_population")
        )
    }
mismatch = []
for key, vals in series.items():
    if vals.get("both") is None:
        continue
    csv_persons = int(round(vals["both"] * 1000))
    if csv_persons != db_pop.get(key):
        mismatch.append((key, csv_persons, db_pop.get(key)))
print("\nCSV 'both' vs DB population_persons mismatches:", len(mismatch))
for m in mismatch[:10]:
    print("  ", m)
