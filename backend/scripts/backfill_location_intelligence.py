"""Queue Location Intelligence measurements for listings that are not measured.

Why this exists: the informational measurement pipeline was only reachable from
the create / update / address-confirmation paths, and those paths additionally
required a server-confirmed address verdict. Every catalogue listing has a NULL
verdict, so nothing was ever queued and Location Intelligence had no data to
display. This script performs the one-off sweep for the listings that already
exist. New and edited listings are queued automatically by the API.

What it does, and does not do:

* It only ENQUEUES durable ``fyp.property_enrichment_category`` rows. The
  existing ``expanded64-enrichment`` worker thread does the calculating, so
  there is exactly one calculation engine and one write path.
* It never writes a measurement itself, never touches ``fyp.rental_properties``,
  and never changes a score.
* Running it twice is harmless: the enqueue conflict clause skips categories
  that are already current for the current coordinate hash and version.

Usage (from ``backend/``):

    .venv/Scripts/python.exe scripts/backfill_location_intelligence.py
    .venv/Scripts/python.exe scripts/backfill_location_intelligence.py --limit 20
    .venv/Scripts/python.exe scripts/backfill_location_intelligence.py --dry-run

Progress is visible through ``fyp.property_enrichment_category``; the API's
``GET /api/v1/staff/properties/{id}/location-intelligence`` reports the same
state per property.
"""

from __future__ import annotations

import argparse
import json
import sys

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.services.expanded64_enrichment import (
    CATEGORIES,
    VERSION,
    enqueue_all_missing,
)


def _state(session: Session) -> dict:
    return {
        "listings": session.execute(
            text("SELECT count(*) FROM fyp.rental_properties")
        ).scalar_one(),
        "listings_with_coordinates": session.execute(text("""
            SELECT count(*) FROM fyp.rental_properties
            WHERE latitude IS NOT NULL AND longitude IS NOT NULL
              AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180
            """)).scalar_one(),
        "categories": {
            row[0]: row[1]
            for row in session.execute(text("""
                SELECT status, count(*) FROM fyp.property_enrichment_category
                WHERE category LIKE 'expanded64\\_%' GROUP BY status ORDER BY status
                """)).all()
        },
        "calculation_version": VERSION,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=None,
                        help="Queue at most this many listings (default: all).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Report what would be queued without writing.")
    args = parser.parse_args(argv)

    with Session(engine) as session:
        before = _state(session)
        print("before:", json.dumps(before, indent=2))
        if args.dry_run:
            print("\ndry run: nothing was queued.")
            return 0
        result = enqueue_all_missing(session, limit=args.limit)
        session.commit()
        after = _state(session)
        print("\nqueued:", json.dumps(
            {k: v for k, v in result.items() if k != "queued"}, indent=2,
        ))
        print("after:", json.dumps(after, indent=2))
        print(
            f"\n{result['queued_count']} listing(s) queued across "
            f"{len(CATEGORIES)} categories each. The enrichment worker "
            "calculates them in the background; poll the staff Location "
            "Intelligence endpoint for per-property state."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
