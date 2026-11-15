#!/usr/bin/env python
"""Import the DOSM district male/female population into ``public.district_population``.

The Entrepreneur Property Detail page's "Who lives in the wider district?"
section reads its sex split from ``male_persons`` / ``female_persons`` here.
The analytics import that built this table kept only the ``sex=both``,
``ethnicity=overall`` series of the official dataset, so the two sex totals
were never stored and the panel had nothing honest to show.

    cd backend
    .venv\\Scripts\\python.exe scripts/data/import_dosm_district_population_sex.py --dry-run
    .venv\\Scripts\\python.exe scripts/data/import_dosm_district_population_sex.py
    .venv\\Scripts\\python.exe scripts/data/import_dosm_district_population_sex.py --verify-only

Source: ``https://storage.dosm.gov.my/population/population_district.csv``
("Population by District, Sex, Ethnicity and 5-Year Age Groups", DOSM /
open.dosm.gov.my; government of Malaysia, attribution required). Rows are
filtered to ``age=overall`` and ``ethnicity=overall``, the one sex-level series
that corresponds to the district total already stored here - male, female and
both are never mixed, and the five-year bands are not touched.

Integrity gates, applied per (state, district, date) before anything is
written:

* the CSV ``sex=both`` figure, converted from thousands to persons, must equal
  the ``population_persons`` already in the table. That proves the table and
  this file are the same series of the same vintage;
* ``male + female`` must equal ``both`` within 500 persons, which is the
  source's own rounding (each cell is published to 0.1 thousand).

A row failing either gate is reported and skipped rather than written.

Nothing else changes: the two columns are added with ``ADD COLUMN IF NOT
EXISTS``, the existing ``population_persons`` values are never rewritten, only
rows that differ are updated, and re-running the import is a no-op.
"""

from __future__ import annotations

import argparse
import csv
import sys
import urllib.request
from collections import defaultdict
from pathlib import Path

# Allow direct script execution from the backend/ directory.
_BACKEND = Path(__file__).resolve().parents[2]
if str(_BACKEND / "src") not in sys.path:
    sys.path.insert(0, str(_BACKEND / "src"))

from sqlalchemy import text  # noqa: E402
from sqlmodel import Session  # noqa: E402

from sitewise.db.analytics_session import analytics_engine  # noqa: E402

SOURCE_URL = "https://storage.dosm.gov.my/population/population_district.csv"
DEFAULT_CACHE = _BACKEND / "var" / "dosm" / "population_district.csv"

#: Columns the DOSM sex series is written into. Both are nullable: a district
#: the source does not cover stays NULL, never 0.
DDL_STATEMENTS: tuple[str, ...] = (
    "ALTER TABLE public.district_population "
    "ADD COLUMN IF NOT EXISTS male_persons BIGINT",
    "ALTER TABLE public.district_population "
    "ADD COLUMN IF NOT EXISTS female_persons BIGINT",
    """
    ALTER TABLE public.district_population
        DROP CONSTRAINT IF EXISTS ck_district_population_sex,
        ADD CONSTRAINT ck_district_population_sex CHECK (
            (male_persons IS NULL OR male_persons >= 0)
            AND (female_persons IS NULL OR female_persons >= 0))
    """,
)

#: The published cell is in thousands with one decimal, so the male/female sum
#: can differ from the both figure by half a unit per component.
_TOLERANCE_PERSONS = 500

_READ_CHUNK = 1 << 20


def _download(url: str, dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_suffix(dest.suffix + ".part")
    print(f"downloading {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "sitewise-dosm-import/1.0"})
    with urllib.request.urlopen(request, timeout=180) as response, open(partial, "wb") as fh:
        total = int(response.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = response.read(_READ_CHUNK)
            if not chunk:
                break
            fh.write(chunk)
            done += len(chunk)
            if total:
                print(f"  {done * 100 // total}% of {total:,} bytes", end="\r", flush=True)
    partial.replace(dest)
    print(f"  saved {dest} ({dest.stat().st_size:,} bytes)")
    return dest


def _stored_series(session: Session) -> dict[tuple[str, str, str], int]:
    """(state, district, iso date) -> population_persons already in the table."""
    rows = session.execute(
        text("SELECT state, district, date, population_persons FROM public.district_population")
    ).all()
    return {(state, district, date.isoformat()): int(persons) for state, district, date, persons in rows}


def _read_csv(path: Path) -> dict[tuple[str, str, str], dict[str, float]]:
    """The ``overall / overall`` sex series for every district the table holds."""
    series: dict[tuple[str, str, str], dict[str, float]] = defaultdict(dict)
    with open(path, newline="", encoding="utf-8-sig") as fh:
        for row in csv.DictReader(fh):
            if row["age"] != "overall" or row["ethnicity"] != "overall":
                continue
            key = (row["state"], row["district"], row["date"])
            series[key][row["sex"]] = float(row["population"])
    return series


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--csv", type=Path, help="use this local copy of population_district.csv")
    parser.add_argument(
        "--cache",
        type=Path,
        default=DEFAULT_CACHE,
        help=f"where a downloaded copy is kept (default {DEFAULT_CACHE})",
    )
    parser.add_argument("--no-download", action="store_true", help="fail instead of downloading")
    parser.add_argument("--dry-run", action="store_true", help="verify and report, write nothing")
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="check what is already in the table against the source, write nothing",
    )
    args = parser.parse_args(argv)

    path = args.csv
    if path is None:
        path = args.cache
        if not path.exists():
            if args.no_download or args.verify_only:
                print(f"no local copy at {path}", file=sys.stderr)
                return 2
            path = _download(SOURCE_URL, path)
        print(f"using {path}")

    with Session(analytics_engine) as session:
        stored = _stored_series(session)
        series = _read_csv(path)

        # The gate that this file is the same series as the table: the both
        # figure, in persons, must be the number already stored.
        problems: list[str] = []
        updates: list[tuple[str, str, str, int, int]] = []
        for key, persons in sorted(stored.items()):
            values = series.get(key) or {}
            both, male, female = values.get("both"), values.get("male"), values.get("female")
            if both is None or male is None or female is None:
                problems.append(f"{key}: source has no overall/overall male+female series")
                continue
            if int(round(both * 1000)) != persons:
                problems.append(
                    f"{key}: source both {int(round(both * 1000)):,} != stored "
                    f"population_persons {persons:,} (different series or vintage)"
                )
                continue
            male_persons = int(round(male * 1000))
            female_persons = int(round(female * 1000))
            if abs(male_persons + female_persons - persons) > _TOLERANCE_PERSONS:
                problems.append(
                    f"{key}: male+female {male_persons + female_persons:,} is outside "
                    f"{_TOLERANCE_PERSONS} of the district total {persons:,}"
                )
                continue
            updates.append((*key, male_persons, female_persons))

        if problems:
            print(f"{len(problems)} row(s) refused:")
            for problem in problems[:20]:
                print("  ", problem)
            if len(problems) > 20:
                print(f"   ... and {len(problems) - 20} more")

        if args.verify_only:
            current = session.execute(
                text(
                    "SELECT state, district, date, population_persons, male_persons, female_persons "
                    "FROM public.district_population ORDER BY state, district, date"
                )
            ).all()
            missing = [r[:3] for r in current if r[4] is None or r[5] is None]
            drifted = [
                r[:3]
                for r in current
                if r[4] is not None
                and abs(r[4] + r[5] - int(r[3])) > _TOLERANCE_PERSONS
            ]
            print(
                f"table rows={len(current)} missing sex split={len(missing)} "
                f"outside tolerance={len(drifted)} verified-from-source={len(updates)}"
            )
            for row in (missing + drifted)[:10]:
                print("  ", row)
            return 1 if (missing or drifted) else 0

        if args.dry_run:
            print(f"dry run: {len(updates)} of {len(stored)} rows would be written")
            for state, district, date, male, female in updates[:5]:
                print(f"   {state} | {district} | {date}: male {male:,} female {female:,}")
            return 0

        for statement in DDL_STATEMENTS:
            session.execute(text(statement))
        session.commit()

        written = 0
        for state, district, date, male, female in updates:
            result = session.execute(
                text(
                    """
                    UPDATE public.district_population
                       SET male_persons = :male, female_persons = :female
                     WHERE state = :state AND district = :district AND date = CAST(:date AS date)
                       AND (male_persons IS DISTINCT FROM :male
                            OR female_persons IS DISTINCT FROM :female)
                    """
                ),
                {"state": state, "district": district, "date": date, "male": male, "female": female},
            )
            written += int(result.rowcount or 0)
        session.commit()

        districts = {(state, district) for state, district, _date, _m, _f in updates}
        print(
            f"verified {len(updates)}/{len(stored)} rows across {len(districts)} districts; "
            f"{written} row(s) changed (a re-run writes 0)"
        )
        return 0 if not problems else 1


if __name__ == "__main__":
    raise SystemExit(main())
