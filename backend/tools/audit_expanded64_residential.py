"""Compare the original residential PostGIS recipe with expanded64 training rows.

Run from the repository root with backend/src on PYTHONPATH:
    python backend/tools/audit_expanded64_residential.py MD-00510 MD-04816
"""
from __future__ import annotations

import argparse
import ast
import csv
import math
from pathlib import Path

from sqlalchemy import text

from sitewise.db.analytics_session import analytics_engine

ROOT = Path(__file__).resolve().parents[2]
RECIPE = ROOT / "analysis_output/residential_density/scripts/compute_residential_features.py"
BRIDGE = ROOT / "backend/ml_reference/training_expanded_bridge_1796.csv"
METRICS = (
    "residential_building_count_{radius}m",
    "residential_building_density_{radius}m_km2",
    "residential_footprint_coverage_{radius}m_pct",
    "residential_landuse_coverage_{radius}m_pct",
)


def recipe_constants():
    """Reuse the archived formula without importing its legacy database setup."""
    constants = {}
    for node in ast.parse(RECIPE.read_text(encoding="utf-8")).body:
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
            if name in {"SQL", "RES_SET"}:
                constants[name] = ast.literal_eval(node.value)
    return constants["SQL"], constants["RES_SET"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("property_ids", nargs="+")
    args = parser.parse_args()

    with BRIDGE.open(encoding="utf-8-sig", newline="") as stream:
        training = {row["canonical_property_id"]: row for row in csv.DictReader(stream)}
    recipe, tags = recipe_constants()
    # Supply the original recipe with one current coordinate pair through a
    # read-only CTE, without creating its historical temporary input table.
    recipe = recipe.replace(
        "WITH buf AS MATERIALIZED",
        """WITH rsub AS (
            SELECT listing_id AS subject_id, latitude AS lat, longitude AS lon
            FROM fyp.rental_properties
            WHERE listing_id = :property_id
              AND latitude IS NOT NULL AND longitude IS NOT NULL
        ), buf AS MATERIALIZED""",
        1,
    )

    failed = False
    with analytics_engine.connect() as connection:
        connection.exec_driver_sql("SET TRANSACTION READ ONLY")
        connection.exec_driver_sql("SET LOCAL statement_timeout = '15s'")
        for property_id in args.property_ids:
            historical = training.get(property_id)
            if historical is None:
                print(f"{property_id}: no historical comparison row")
                failed = True
                continue

            for radius in (500, 1000):
                statement = text(recipe.format(radius=radius, res_set=tags, where=""))
                row = connection.execute(statement, {"property_id": property_id}).one_or_none()
                if row is None or row.buf_area <= 0:
                    print(f"{property_id} {radius}m: no valid live buffer measurement")
                    failed = True
                    continue

                live = (
                    row.res_count,
                    round(row.res_count / (row.buf_area / 1_000_000), 2),
                    min(100.0, round(100 * row.res_area / row.buf_area, 3)),
                    min(100.0, round(100 * row.landuse_area / row.buf_area, 3)),
                )
                for metric, observed in zip(METRICS, live, strict=True):
                    name = metric.format(radius=radius)
                    expected = historical[name]
                    matched = bool(expected) and math.isclose(
                        observed, float(expected), rel_tol=0, abs_tol=1e-8
                    )
                    print(f"{property_id} {name}: live={observed} training={expected or 'unavailable'} match={matched}")
                    failed |= not matched
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
