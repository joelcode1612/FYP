"""Collect expanded64 model inputs from an operational property or coordinates."""
from __future__ import annotations

import argparse
import csv
import json
import math
from collections import defaultdict
from pathlib import Path

from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine
from sitewise.ml.coordinate_features import (
    GROUP_COMPETITORS, GROUP_DRIVE, GROUP_ISO, GROUP_PARKING, GROUP_POI,
    GROUP_POPULATION, GROUP_RESIDENTIAL, GROUP_ROAD, GROUP_TRANSIT,
)
from sitewise.ml.expanded64_network import Expanded64CoordinateExtractor
from sitewise.ml.property_features import FeatureResolutionError
from sitewise.ml.pu_expanded import collect_expanded_coordinates, expanded_rental_prediction


def replay_training(session, path, groups, per_stratum, subject_ids=(), *, parking_points=False):
    """Replay the collector against frozen training coordinates and measurements."""
    strata = defaultdict(list)
    with path.open(encoding="utf-8-sig", newline="") as stream:
        for row in csv.DictReader(stream):
            if not subject_ids or row["subject_id"] in subject_ids:
                strata[row["sample_class"], row["state_dosm"]].append(row)

    if subject_ids:
        found = {row["subject_id"] for records in strata.values() for row in records}
        if missing := set(subject_ids) - found:
            raise FeatureResolutionError(f"Training subject IDs not found: {', '.join(sorted(missing))}")

    if not strata:
        raise FeatureResolutionError("The training reference CSV has no records")

    extractor = Expanded64CoordinateExtractor(session)
    selected = set(groups)
    if parking_points:
        selected.remove(GROUP_PARKING)
    rows = []
    for (sample_class, state), records in sorted(strata.items()):
        records.sort(key=lambda row: row["subject_id"])
        count = len(records) if subject_ids else min(per_stratum, len(records))
        for index in range(count):
            row = records[(2 * index + 1) * len(records) // (2 * count)]
            lat, lon = float(row["latitude"]), float(row["longitude"])
            groups_found = extractor.extract(lat, lon, selected=selected)
            if parking_points:
                groups_found[GROUP_PARKING] = extractor.parking_facilities(
                    lat, lon, archive_point_inventory=True,
                )
            rows.append({
                "subject_id": row["subject_id"],
                "sample_class": sample_class,
                "state": state,
                "coordinates": {"latitude": lat, "longitude": lon},
                "groups": {
                    group: {
                        "status": result.status,
                        "reason": result.reason,
                        "notes": result.notes,
                        "sources": result.sources,
                        "features": {
                            name: compare_training_value(row.get(name), value)
                            for name, value in result.values.items() if name in row
                        },
                    }
                    for group, result in groups_found.items()
                },
            })

    return {"reference_count": len(rows), "groups": list(groups), "references": rows}


def compare_training_value(raw, observed):
    expected = float(raw) if raw else None
    if expected is not None and not math.isfinite(expected):
        expected = None
    matches = (
        expected is not None and observed is not None
        and math.isclose(expected, observed, rel_tol=0, abs_tol=1e-6)
    )
    return {"training": expected, "collected": observed, "matches": matches}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    location = parser.add_mutually_exclusive_group(required=True)
    location.add_argument("--property-id", type=int, help="Operational listing ID")
    location.add_argument("--coordinates", type=float, nargs=2, metavar=("LAT", "LON"))
    location.add_argument("--replay-training", type=Path, metavar="CSV")
    parser.add_argument(
        "--replay-group", action="append", default=[],
        choices=(GROUP_ROAD, GROUP_TRANSIT, GROUP_ISO, GROUP_DRIVE, GROUP_RESIDENTIAL,
                 GROUP_POPULATION, GROUP_POI, GROUP_COMPETITORS, GROUP_PARKING),
        help="Collection group to replay against the frozen training CSV; repeat to select multiple",
    )
    parser.add_argument("--per-stratum", type=int, default=1)
    parser.add_argument(
        "--replay-subject", action="append", default=[], metavar="ID",
        help="Replay a named training subject instead of sampling; repeat to select more",
    )
    parser.add_argument(
        "--replay-parking-points", action="store_true",
        help="Compare the archived U parking point-inventory recipe",
    )
    parser.add_argument("--age-raster-dir", help="Override SITEWISE_AGE_RASTER_DIR for this run")
    parser.add_argument("--explain", action="store_true", help="Run SHAP if inference succeeds")
    args = parser.parse_args()
    if args.replay_training is not None and (not args.replay_group or args.per_stratum < 1):
        parser.error("--replay-training requires --replay-group and a positive --per-stratum")
    if args.replay_subject and args.replay_training is None:
        parser.error("--replay-subject requires --replay-training")
    if args.replay_parking_points and (
        args.replay_training is None or GROUP_PARKING not in args.replay_group
    ):
        parser.error("--replay-parking-points requires a parking_facilities training replay")
    options = {
        "age_raster_dir": args.age_raster_dir,
        "diagnostics": True,
        "explain": args.explain,
    }
    try:
        with Session(analytics_engine) as session:
            session.connection().exec_driver_sql("SET TRANSACTION READ ONLY")
            session.connection().exec_driver_sql("SET LOCAL statement_timeout = '20s'")
            if args.replay_training is not None:
                result = replay_training(
                    session, args.replay_training, args.replay_group, args.per_stratum,
                    set(args.replay_subject), parking_points=args.replay_parking_points,
                )
            elif args.property_id is not None:
                result = expanded_rental_prediction(session, args.property_id, **options)
            else:
                result = collect_expanded_coordinates(session, *args.coordinates, **options)
    except FeatureResolutionError as exc:
        parser.error(str(exc))
    print(json.dumps(result, indent=2, allow_nan=False))
    return 0 if args.replay_training is not None or result["available"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
