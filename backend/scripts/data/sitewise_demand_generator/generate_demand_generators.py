#!/usr/bin/env python3
"""Backfill actual demand-generator counts for SiteWise rental properties.

Read-only CSV export by default. --apply writes only measured values into
fyp.property_geospatial_features, and synchronises the existing demand_generators
lifecycle when that table exists. Never invents POIs from competitor density.

Requires backend dependencies sqlalchemy, psycopg2-binary, python-dotenv.
Works when the operational and analytics schemas reside in separate databases.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import sys
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path

try:
    from sqlalchemy import create_engine, text
    from dotenv import load_dotenv
except ImportError:
    print("Install backend dependencies: cd FYP/backend; py -m pip install -e .", file=sys.stderr)
    raise

# Exact seven categories from backend/src/sitewise/ml/coordinate_features.py.
# OFFICE_BUILDING is intentionally NOT counted as OFFICE: this matches the
# research model's existing feature contract.
POI_CATEGORIES = {
    "office_pois": "OFFICE",
    "schools_count": "SCHOOL",
    "universities_colleges_count": "UNIVERSITY_COLLEGE",
    "retail_pois": "RETAIL",
    "malls_count": "MALL",
    "hospitals_count": "HOSPITAL",
    "supermarkets_count": "SUPERMARKET",
}
RADIUS_LABELS = {"500m": 500, "1000m": 1000}
CATEGORY_COLUMNS = tuple(
    f"{stem}_{suffix}" for stem in POI_CATEGORIES for suffix in RADIUS_LABELS
)
TOTAL_COLUMNS = ("demand_generator_count_500m", "demand_generator_count_1km")
ALL_COLUMNS = TOTAL_COLUMNS + CATEGORY_COLUMNS
CALCULATION_VERSION = "property-enrichment-v2"  # Existing backend contract.


def coordinate_hash(lat: float, lon: float) -> str:
    payload = f"{lat:.6f},{lon:.6f},{CALCULATION_VERSION}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def url_engine(url: str):
    if not url or "postgresql" not in url.lower():
        raise ValueError("Configure a PostgreSQL DATABASE_URL (not an SQLite or placeholder URL).")
    return create_engine(url, pool_pre_ping=True, connect_args={"connect_timeout": 12})


def relation_exists(conn, fullname: str) -> bool:
    return conn.execute(text("SELECT to_regclass(:table) IS NOT NULL"), {"table": fullname}).scalar_one()


def valid_coords(lat, lon) -> bool:
    try:
        x, y = float(lat), float(lon)
    except (TypeError, ValueError):
        return False
    return (math.isfinite(x) and math.isfinite(y) and -90 <= x <= 90
            and -180 <= y <= 180 and not (x == 0 and y == 0))


# Same curated definition and geography distances as PropertyEnrichmentService.
SUBJECT_SQL = text("""
WITH origin AS (
  SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS point
), nearby AS (
  SELECT ST_Distance(s.geom::geography, origin.point::geography) AS d
  FROM demand_gen.subjects s CROSS JOIN origin
  WHERE s.geom IS NOT NULL
    AND s.geom && ST_Expand(origin.point, :bbox)
)
SELECT count(*) FILTER (WHERE d <= 500)::integer AS c500,
       count(*) FILTER (WHERE d <= 1000)::integer AS c1000
FROM nearby
""")

# Same seven training categories/radii, source and 0.012-degree window as
# CoordinateFeatureService.demand_generator_pois. Do NOT sum into the curated
# demand_generator_count: the two source universes differ.
select_parts = ["count(*)::integer AS pois_in_window"]
for stem, category in POI_CATEGORIES.items():
    for label, radius in RADIUS_LABELS.items():
        select_parts.append(
            f"count(*) FILTER (WHERE cat = '{category}' AND d <= {radius})::integer "
            f"AS {stem}_{label}"
        )
POI_SQL = text("""
WITH origin AS (
  SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS point
), nearby AS (
  SELECT p.poi_category AS cat,
         ST_Distance(p.rep_geom::geography, origin.point::geography) AS d
  FROM demand_gen.pois_master p CROSS JOIN origin
  WHERE p.rep_geom IS NOT NULL
    AND p.rep_geom && ST_Expand(origin.point, 0.012)
)
SELECT """ + ",\n       ".join(select_parts) + "\nFROM nearby")


def measure(subject_conn, poi_conn, lat: float, lon: float) -> dict:
    # Bounding box is only a cheap prefilter; actual result is geography metres.
    # The bbox encloses 1000 m anywhere within Malaysia. The source universe
    # used in this FYP is Malaysia, for which latitude is near the equator.
    bbox = 1000 * 1.03 / 111_320 / max(0.1, abs(math.cos(math.radians(lat))))
    subject = subject_conn.execute(SUBJECT_SQL, {"lat": lat, "lon": lon, "bbox": bbox}).mappings().one()
    poi = poi_conn.execute(POI_SQL, {"lat": lat, "lon": lon}).mappings().one()
    values = {
        TOTAL_COLUMNS[0]: int(subject["c500"]),
        TOTAL_COLUMNS[1]: int(subject["c1000"]),
    }
    # No POI rows in the expected near window -> cannot establish source
    # coverage; leave all fourteen specific counts unresolved, not zero.
    covered = (poi["pois_in_window"] or 0) > 0
    for col in CATEGORY_COLUMNS:
        values[col] = int(poi[col]) if covered else None
    return {
        "values": values,
        "poi_coverage": "measured" if covered else "unavailable_no_nearby_source_rows",
        "poi_rows_in_window": int(poi["pois_in_window"] or 0),
    }


def preflight(operational, analytics=None):
    if not relation_exists(operational, "fyp.rental_properties"):
        raise RuntimeError("Missing fyp.rental_properties in the operational database")
    if not relation_exists(operational, "fyp.property_geospatial_features"):
        raise RuntimeError("Missing fyp.property_geospatial_features in the operational database")
    candidates = [("operational", operational)]
    if analytics is not None:
        candidates.append(("analytics", analytics))
    sources = {}
    for name in ("demand_gen.subjects", "demand_gen.pois_master"):
        found = next(((label, c) for label, c in candidates if relation_exists(c, name)), None)
        if found is None:
            raise RuntimeError(f"Source {name} not found in operational or analytics database; cannot create real counts")
        count = int(found[1].execute(text(f"SELECT count(*) FROM {name}")).scalar_one())
        if count == 0:
            raise RuntimeError(f"Source {name} is empty; refusing to fabricate demand counts")
        print(f"[source] {name}: {count:,} rows ({found[0]} database)")
        sources[name] = found[1]
    duplicates = operational.execute(text("""
        SELECT count(*) FROM (
          SELECT property_id FROM fyp.property_geospatial_features
          GROUP BY property_id HAVING count(*) > 1
        ) duplicates
    """)).scalar_one()
    if duplicates:
        raise RuntimeError(f"{duplicates} property IDs have duplicate geospatial rows. Resolve duplicates before writes.")
    return sources


def property_rows(conn, limit=None, ids=None):
    filter_sql = " WHERE p.id = ANY(:ids)" if ids else ""
    query = text("""
      SELECT p.id AS property_id, p.name AS property_name,
             p.state, p.city, p.latitude, p.longitude
      FROM fyp.rental_properties p
    """ + filter_sql + " ORDER BY p.id" + (" LIMIT :limit" if limit else ""))
    params = {}
    if ids:
        params["ids"] = ids
    if limit:
        params["limit"] = limit
    return conn.execute(query, params).mappings().all()


def current_columns(conn) -> set[str]:
    return set(conn.execute(text("""
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'fyp' AND table_name = 'property_geospatial_features'
    """)).scalars().all())


def ensure_category_columns(conn):
    for name in CATEGORY_COLUMNS:
        # Identifiers are constants declared above, not CLI-provided text.
        conn.execute(text(f"ALTER TABLE fyp.property_geospatial_features ADD COLUMN IF NOT EXISTS {name} INTEGER"))


def upsert_measurements(conn, property_id: int, measurements: dict, force: bool):
    values = measurements["values"]
    names = [col for col in ALL_COLUMNS if values[col] is not None]
    if not names:
        return "none"
    existing = conn.execute(text("""
        SELECT property_id FROM fyp.property_geospatial_features
        WHERE property_id = :pid
    """), {"pid": property_id}).first()
    params = {"pid": property_id, **{name: values[name] for name in names}}
    if existing is None:
        cols = ", ".join(["property_id", *names, "last_calculated_at"])
        placeholders = ", ".join([":pid", *(f":{name}" for name in names), "now()"])
        conn.execute(text(f"INSERT INTO fyp.property_geospatial_features ({cols}) VALUES ({placeholders})"), params)
        return "inserted"
    assignments = [f"{name} = :{name}" if force else f"{name} = COALESCE({name}, :{name})" for name in names]
    where_need = " OR ".join(f"{name} IS NULL" for name in names)
    query = "UPDATE fyp.property_geospatial_features SET " + ", ".join(assignments + ["last_calculated_at = now()"])
    query += " WHERE property_id = :pid"
    if not force:
        query += f" AND ({where_need})"
    result = conn.execute(text(query), params)
    return "updated" if result.rowcount else "already_populated"


def save_existing_lifecycle(conn, property_id, lat, lon, values, *, can_mark_current: bool):
    # Existing backend uses this as the status source for add-property. Never
    # overwrite a live worker's `running` row. If old manually-entered values
    # disagree and were preserved, don't label them current.
    if not can_mark_current or not relation_exists(conn, "fyp.property_enrichment_category"):
        return
    payload = {name: values[name] for name in TOTAL_COLUMNS}
    provenance = {
        "source": "demand_gen.subjects",
        "definition": "curated demand-generator register (malls, offices, institutions)",
        "radii_m": [500, 1000],
        "method": "ST_Distance(geography) <= radius_m",
        "backfill": "sitewise_demand_generator_backfill",
    }
    conn.execute(text("""
       INSERT INTO fyp.property_enrichment_category
          (property_id, category, phase, status, measurement, provenance,
           coordinate_hash, calculation_version, attempt_count,
           completed_at, updated_at)
       VALUES (:pid, 'demand_generators', 'postgis', 'current',
               CAST(:measurement AS jsonb), CAST(:provenance AS jsonb),
               :hash, :version, 1, now(), now())
       ON CONFLICT (property_id, category) DO UPDATE
       SET status = 'current', phase = 'postgis',
           measurement = EXCLUDED.measurement, provenance = EXCLUDED.provenance,
           coordinate_hash = EXCLUDED.coordinate_hash,
           calculation_version = EXCLUDED.calculation_version,
           completed_at = now(), updated_at = now(), last_error = NULL
       WHERE fyp.property_enrichment_category.status <> 'running'
    """), {"pid": property_id, "measurement": json.dumps(payload),
            "provenance": json.dumps(provenance),
            "hash": coordinate_hash(lat, lon), "version": CALCULATION_VERSION})


def csv_safe(value):
    """Avoid spreadsheet formula interpretation for untrusted listing strings."""
    if isinstance(value, str) and value.lstrip().startswith(("=", "+", "-", "@")):
        return "'" + value
    return value


def write_report_row(writer, row):
    writer.writerow({key: csv_safe(value) for key, value in row.items()})


def parse_ids(value: str | None):
    if not value:
        return None
    try:
        ids = list(dict.fromkeys(int(x.strip()) for x in value.split(",") if x.strip()))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("--ids must be comma-separated numeric rental_properties IDs") from exc
    if any(x <= 0 for x in ids):
        raise argparse.ArgumentTypeError("--ids must contain positive integers")
    return ids or None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", default=None, help="Path to the FYP/backend directory, for .env loading")
    parser.add_argument("--csv", default="sitewise_demand_generators.csv", help="CSV report output path")
    parser.add_argument("--limit", type=int, default=None, help="First N properties (testing)")
    parser.add_argument("--ids", default=None, help="Optional comma-separated numeric property IDs")
    parser.add_argument("--apply", action="store_true", help="Explicitly write data to fyp.property_geospatial_features")
    parser.add_argument("--force", action="store_true", help="With --apply, replace existing values (for corrected coords/source updates)")
    args = parser.parse_args(argv)
    if args.force and not args.apply:
        parser.error("--force requires --apply")
    if args.limit is not None and args.limit <= 0:
        parser.error("--limit must be positive")
    try:
        ids = parse_ids(args.ids)
    except argparse.ArgumentTypeError as e:
        parser.error(str(e))

    backend = Path(args.backend).resolve() if args.backend else Path(__file__).resolve().parents[2] if "backend" in Path(__file__).parts else Path.cwd()
    env_file = backend / ".env"
    if env_file.is_file():
        load_dotenv(env_file, override=False)
    operational_url = os.getenv("SITEWISE_DATABASE_URL") or os.getenv("DATABASE_URL")
    analytics_url = os.getenv("SITEWISE_DEMAND_SOURCE_DATABASE_URL") or os.getenv("ANALYTICS_DATABASE_URL")
    if not operational_url:
        parser.error(f"DATABASE_URL not set. Use the backend's .env ({env_file}), or set $env:DATABASE_URL")
    start = datetime.now(timezone.utc).isoformat()
    op_engine = url_engine(operational_url)
    analytics_engine = url_engine(analytics_url) if analytics_url and analytics_url != operational_url else None
    try:
        with ExitStack() as stack:
            op = stack.enter_context(op_engine.connect())
            analytics = stack.enter_context(analytics_engine.connect()) if analytics_engine is not None else None
            sources = preflight(op, analytics)
            props = property_rows(op, args.limit, ids)
            # Release preflight SELECT locks before a separate connection performs DDL.
            op.commit()
            if analytics is not None:
                analytics.commit()
            print(f"[properties] {len(props)} rows selected; mode={'APPLY' if args.apply else 'READ-ONLY CSV'}")
            fieldnames = ["property_id", "property_name", "state", "city", "latitude", "longitude",
                          "status", "poi_coverage", "poi_rows_in_window", *ALL_COLUMNS,
                          "measurement_source", "poi_source", "measured_at_utc", "error", "write_result"]
            csv_path = Path(args.csv).resolve()
            csv_path.parent.mkdir(parents=True, exist_ok=True)
            successes = written = skipped = 0
            with csv_path.open("w", newline="", encoding="utf-8-sig") as output:
                writer = csv.DictWriter(output, fieldnames=fieldnames, extrasaction="ignore")
                writer.writeheader()
                if args.apply:
                    # Don't add columns until the two source relations were both
                    # verified. Single transaction for DDL; later per-property
                    # changes are committed individually.
                    with op_engine.begin() as tx:
                        ensure_category_columns(tx)
                else:
                    missing = [col for col in CATEGORY_COLUMNS if col not in current_columns(op)]
                    if missing:
                        print(f"[info] {len(missing)} category columns not yet in fyp.property_geospatial_features; --apply will add them")
                for idx, prop in enumerate(props, start=1):
                    row = dict(prop)
                    row.update({"measured_at_utc": start,
                                "measurement_source": "demand_gen.subjects",
                                "poi_source": "demand_gen.pois_master"})
                    lat, lon = prop["latitude"], prop["longitude"]
                    if not valid_coords(lat, lon):
                        row["status"] = "unavailable_no_valid_coordinates"
                        skipped += 1
                        write_report_row(writer, row)
                        continue
                    lat, lon = float(lat), float(lon)
                    try:
                        measurement = measure(sources["demand_gen.subjects"], sources["demand_gen.pois_master"], lat, lon)
                        values = measurement["values"]
                        row.update(values)
                        row["status"] = "measured"
                        row["poi_coverage"] = measurement["poi_coverage"]
                        row["poi_rows_in_window"] = measurement["poi_rows_in_window"]
                        successes += 1
                        if args.apply:
                            with op_engine.begin() as tx:
                                action = upsert_measurements(tx, int(prop["property_id"]), measurement, args.force)
                                row["write_result"] = action
                                written += action in ("inserted", "updated")
                                # Confirm the actual stored curated totals
                                # before declaring the category current.
                                stored = tx.execute(text("""
                                  SELECT demand_generator_count_500m, demand_generator_count_1km
                                  FROM fyp.property_geospatial_features WHERE property_id=:pid
                                """), {"pid": int(prop["property_id"])}).mappings().one()
                                current = all(stored[col] == values[col] for col in TOTAL_COLUMNS)
                                save_existing_lifecycle(tx, int(prop["property_id"]), lat, lon, values,
                                                        can_mark_current=current)
                        write_report_row(writer, row)
                    except Exception as exc:
                        # A failed PostgreSQL statement aborts its transaction.
                        # Restore the read sessions so later properties can run.
                        op.rollback()
                        if analytics is not None:
                            analytics.rollback()
                        row["status"] = "failed"
                        row["error"] = f"{type(exc).__name__}: {exc}"[:450]
                        write_report_row(writer, row)
                        skipped += 1
                        print(f"[ERROR] property {prop['property_id']}: {type(exc).__name__}: {exc}", file=sys.stderr)
                    if idx % 100 == 0:
                        print(f"[progress] {idx}/{len(props)} measured={successes} written={written} failed_or_skipped={skipped}")
            print(f"[finished] measured={successes}, wrote={written}, unavailable_or_failed={skipped}")
            print(f"[csv] {csv_path}")
            if skipped:
                print("[attention] Review CSV status/error rows. No unavailable data was replaced by zero.")
                return 2
            return 0
    finally:
        op_engine.dispose()
        if analytics_engine is not None:
            analytics_engine.dispose()


if __name__ == "__main__":
    raise SystemExit(main())
