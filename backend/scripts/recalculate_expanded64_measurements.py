"""Re-queue measurements that were calculated under a different model contract.

Why this exists: eligibility is model-dependent. The original
``sitewise_pu_64_expanded`` artifact admits a narrow set of coordinate inputs,
so a measurement it rejected is stored with ``state: calculated_unvalidated``.
Expanded64_v2 admits the whole 64-feature contract, so the same stored
measurement is now a model input — but the stored snapshot was written under
the old contract and still says otherwise. The numbers are fine; the verdict
attached to them is not.

This script finds the categories whose stored snapshot records a different
``model_name`` than the active artifact and re-queues exactly those. It does not
recalculate anything itself, does not delete a measurement, and does not touch
``fyp.rental_properties``. The existing ``expanded64-enrichment`` worker thread
(or ``drain_location_intelligence.py``) does the work, so there is still one
calculation engine and one write path.

What it deliberately does NOT do:

* It does not re-queue a category that is already pending or running — the
  enqueue conflict clause skips those, so running this while a backfill is in
  flight is safe.
* It does not re-queue a category whose snapshot already names the active
  model. Switching back and forth between artifacts therefore costs one pass
  per switch, not one pass per invocation.
* It never overwrites the measurements of a property whose coordinates changed:
  that is the queue's own stale-detection job, fenced by ``coordinate_hash``.

Usage (from ``backend/``):

    .venv/Scripts/python.exe scripts/recalculate_expanded64_measurements.py
    .venv/Scripts/python.exe scripts/recalculate_expanded64_measurements.py --dry-run
    .venv/Scripts/python.exe scripts/recalculate_expanded64_measurements.py --category network
    .venv/Scripts/python.exe scripts/recalculate_expanded64_measurements.py --limit 50
"""

from __future__ import annotations

import argparse
import json
import sys

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.ml.pu_expanded import (
    active_expanded_model_name,
    uses_v2_feature_definitions,
)
from sitewise.services.expanded64_enrichment import CATEGORIES, VERSION, enqueue


def _mismatched(session: Session, model_name: str, categories: list[str]) -> list[tuple[int, str]]:
    """(property_id, category) pairs whose snapshot names another artifact.

    The snapshot key is ``expanded64_<category>`` and its ``model_name`` is
    written by ``_calculate``; a snapshot without one predates the field and is
    treated as mismatched, because its verdict cannot be attributed to the
    active artifact.
    """
    rows = session.execute(text("""
        SELECT g.property_id, k.category
        FROM fyp.property_geospatial_features g
        CROSS JOIN LATERAL (
            SELECT unnest(CAST(:categories AS text[])) AS category
        ) k
        WHERE g.expanded64_measurements IS NOT NULL
          AND g.expanded64_measurements ? ('expanded64_' || k.category)
          AND COALESCE(
                g.expanded64_measurements -> ('expanded64_' || k.category) ->> 'model_name',
                ''
              ) IS DISTINCT FROM :model
        ORDER BY g.property_id, k.category
        """), {"categories": categories, "model": model_name}).all()
    return [(int(property_id), str(category)) for property_id, category in rows]


def _queue_states(session: Session) -> dict:
    return {
        row[0]: row[1]
        for row in session.execute(text("""
            SELECT status, count(*) FROM fyp.property_enrichment_category
            WHERE category LIKE 'expanded64\\_%' GROUP BY status ORDER BY status
            """)).all()
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--category", default=None, choices=sorted(CATEGORIES),
                        help="Only this category (default: all eight).")
    parser.add_argument("--limit", type=int, default=None,
                        help="Re-queue at most this many property/category pairs.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Report what would be re-queued without writing.")
    args = parser.parse_args(argv)

    model_name = active_expanded_model_name()
    categories = [args.category] if args.category else list(CATEGORIES)

    with Session(engine) as session:
        pairs = _mismatched(session, model_name, categories)
        if args.limit is not None:
            pairs = pairs[: args.limit]
        properties = len({pid for pid, _ in pairs})
        print(json.dumps({
            "active_model": model_name,
            "uses_v2_feature_definitions": uses_v2_feature_definitions(model_name),
            "calculation_version": VERSION,
            "categories": categories,
            "mismatched_pairs": len(pairs),
            "mismatched_properties": properties,
            "queue_before": _queue_states(session),
        }, indent=2))

        if not pairs:
            print("\nEvery stored snapshot already names the active model. Nothing to do.")
            return 0
        if args.dry_run:
            print("\ndry run: nothing was queued.")
            return 0

        queued = 0
        failed: list[dict] = []
        for property_id, category in pairs:
            try:
                with session.begin_nested():
                    if enqueue(session, property_id, category=category, force=True):
                        queued += 1
            except Exception as exc:  # one bad listing must not stop the sweep
                failed.append({
                    "property_id": property_id,
                    "category": category,
                    "error": type(exc).__name__,
                })
        session.commit()
        print(json.dumps({
            "requeued": queued,
            "skipped": len(pairs) - queued - len(failed),
            "failed": failed,
            "queue_after": _queue_states(session),
        }, indent=2))
        print(
            "\nThe enrichment worker recalculates the queued categories. "
            "Measurements that were already correct are replaced by an "
            "identical value with the active model's verdict; no measurement "
            "is deleted in the meantime."
        )
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
