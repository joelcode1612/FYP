"""Persist an Expanded64 association index for properties that lack one.

Why this exists: a prediction is written by ``run_next`` at the moment its
measurements finish. A property whose measurements were already complete when
the current artifact became active never passes through that path again, so it
has measurements and no prediction. Without this sweep those listings would
show "not scored" until something else happened to re-queue them.

This script reuses the production write path exactly —
``_save_expanded_prediction`` — so there is still one inference engine, one SHAP
explanation path and one persistence format. It does not train, re-measure,
delete a prediction or change a measurement.

What it deliberately does NOT do:

* It does not touch a property whose stored prediction already names the active
  model. Re-running the script therefore costs one pass, not one pass per
  invocation.
* It does not score a property whose measurements are pending, running or
  incomplete for the active contract. ``_save_expanded_prediction`` returns
  without writing in that case, and the queue will score it when it finishes.
* It does not hold one transaction across the whole sweep: each property gets
  its own session, so a single failure cannot roll back the rest and a long
  sweep cannot pin locks on the catalogue.

Usage (from ``backend/``):

    .venv/Scripts/python.exe scripts/backfill_expanded64_predictions.py
    .venv/Scripts/python.exe scripts/backfill_expanded64_predictions.py --dry-run
    .venv/Scripts/python.exe scripts/backfill_expanded64_predictions.py --limit 100
    .venv/Scripts/python.exe scripts/backfill_expanded64_predictions.py --property 42
"""

from __future__ import annotations

import argparse
import json
import sys

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.ml.pu_expanded import active_expanded_model_name
from sitewise.services.expanded64_enrichment import (
    VERSION,
    _save_expanded_prediction,
    persisted_association,
)


def _candidates(session: Session, model_name: str, limit: int | None) -> list[tuple[int, float, float]]:
    """Properties with current measurements but no prediction for this artifact.

    A property qualifies when it has at least one measurement snapshot at the
    current calculation version and its stored ``pu_inference_snapshot.expanded64``
    either does not exist or names a different artifact. Both conditions are
    cheap JSON reads on an indexed primary key, so the sweep does not have to
    load a vector to decide.
    """
    sql = """
        SELECT p.id, p.latitude, p.longitude
        FROM fyp.rental_properties p
        JOIN fyp.property_geospatial_features g ON g.property_id = p.id
        WHERE p.latitude IS NOT NULL AND p.longitude IS NOT NULL
          AND p.latitude BETWEEN -90 AND 90 AND p.longitude BETWEEN -180 AND 180
          AND g.expanded64_measurements IS NOT NULL
          AND EXISTS (
              SELECT 1 FROM jsonb_each(g.expanded64_measurements) AS e(key, value)
              WHERE e.key LIKE 'expanded64\\_%'
                AND e.value ->> 'calculation_version' = :version
          )
          AND COALESCE(
                g.pu_inference_snapshot -> 'expanded64' ->> 'model_name',
                ''
              ) IS DISTINCT FROM :model
        ORDER BY p.id
    """
    if limit is not None:
        sql += " LIMIT :limit"
    rows = session.execute(
        text(sql),
        ({"version": VERSION, "model": model_name, "limit": limit} if limit is not None
         else {"version": VERSION, "model": model_name}),
    ).all()
    return [(int(pid), float(lat), float(lon)) for pid, lat, lon in rows]


def _scored(model_name: str) -> int:
    with Session(engine) as session:
        return session.execute(text("""
            SELECT count(*) FROM fyp.property_geospatial_features
            WHERE pu_inference_snapshot -> 'expanded64' ->> 'model_name' = :model
              AND pu_inference_snapshot -> 'expanded64' ->> 'available' = 'true'
            """), {"model": model_name}).scalar_one()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=None,
                        help="Score at most this many properties.")
    parser.add_argument("--property", type=int, default=None, dest="property_id",
                        help="Score exactly this property id.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Report what would be scored without writing.")
    args = parser.parse_args(argv)

    model_name = active_expanded_model_name()

    if args.property_id is not None:
        with Session(engine) as session:
            row = session.execute(text("""
                SELECT id, latitude, longitude FROM fyp.rental_properties WHERE id=:id
                """), {"id": args.property_id}).first()
        if row is None:
            print(f"property {args.property_id} does not exist.")
            return 1
        candidates = [(int(row[0]), float(row[1]), float(row[2]))]
    else:
        with Session(engine) as session:
            candidates = _candidates(session, model_name, args.limit)

    print(json.dumps({
        "active_model": model_name,
        "calculation_version": VERSION,
        "candidates": len(candidates),
        "already_scored": _scored(model_name),
    }, indent=2))

    if not candidates:
        print("\nEvery measured property already has a prediction for the active model.")
        return 0
    if args.dry_run:
        print("\ndry run: nothing was written.")
        return 0

    written, skipped, failed = 0, 0, []
    unavailable: dict[str, int] = {}
    for property_id, latitude, longitude in candidates:
        try:
            with Session(engine) as session:
                # Classify before scoring. A property whose required inputs are
                # genuinely absent cannot be scored for as long as those inputs
                # stay absent, so it is counted and reported here instead of
                # being pushed through inference on every sweep. Nothing is
                # persisted for it: the reason already lives in the enrichment
                # category rows and is surfaced by the analysis projection, and
                # it is re-derived from the measurements, so it can never go
                # stale and scoring resumes by itself once the inputs arrive.
                state = persisted_association(
                    session, property_id, latitude, longitude, read_score=False
                )
                missing = sorted(state.get("_required_missing") or ())
                if state["calculation_status"] not in ("running", "pending") and missing:
                    for name in missing:
                        unavailable[name] = unavailable.get(name, 0) + 1
                    skipped += 1
                    continue

                before = session.execute(text("""
                    SELECT pu_inference_snapshot -> 'expanded64' ->> 'calculated_at'
                    FROM fyp.property_geospatial_features WHERE property_id=:id
                    """), {"id": property_id}).scalar()
                _save_expanded_prediction(session, property_id, latitude, longitude)
                after = session.execute(text("""
                    SELECT pu_inference_snapshot -> 'expanded64' ->> 'calculated_at'
                    FROM fyp.property_geospatial_features WHERE property_id=:id
                    """), {"id": property_id}).scalar()
            # ``_save_expanded_prediction`` is a no-op when the vector is not
            # ready; the row is counted as skipped rather than written so the
            # summary does not claim work that did not happen.
            if after is not None and after != before:
                written += 1
            else:
                skipped += 1
        except Exception as exc:  # one bad property must not stop the sweep
            failed.append({"property_id": property_id, "error": type(exc).__name__})

    print(json.dumps({
        "written": written,
        "skipped": skipped,
        "unavailable_missing_inputs": dict(
            sorted(unavailable.items(), key=lambda item: -item[1])
        ),
        "failed": failed,
        "already_scored": _scored(model_name),
    }, indent=2))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
