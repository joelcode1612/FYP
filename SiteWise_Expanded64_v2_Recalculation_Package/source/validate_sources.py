"""Read-only inventory of the PostGIS/WorldPop sources used by the six calculators.

Run from the package root with ``DATABASE_URL`` set to the local PostgreSQL
instance (credentials are supplied by the caller, never stored in this file).
Nothing here writes to the database.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = ROOT / "sql"
LOGS = ROOT / "logs"
LOGS.mkdir(exist_ok=True)
SQL_DIR.mkdir(exist_ok=True)

logging.basicConfig(
    filename=LOGS / "source_inventory.log",
    filemode="w",
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("source_inventory")

QUERIES: dict[str, str] = {
    "server_identity": """
        SELECT current_database() AS database, inet_server_port() AS port,
               current_user AS db_user, version() AS version
    """,
    "roads_v2": """
        SELECT count(*) AS rows,
               count(*) FILTER (WHERE way IS NULL) AS null_geometry,
               count(*) FILTER (WHERE NOT ST_IsValid(way)) AS invalid_geometry,
               count(DISTINCT ST_SRID(way)) AS srid_count,
               min(ST_SRID(way)) AS srid_min,
               count(*) FILTER (WHERE highway IS NULL) AS null_highway,
               ST_AsText(ST_Extent(way)) AS extent,
               count(*) FILTER (WHERE highway IN (
                 'motorway','trunk','primary','secondary','tertiary','unclassified',
                 'residential','living_street','service','motorway_link','trunk_link',
                 'primary_link','secondary_link','tertiary_link','road','footway',
                 'path','steps','pedestrian','corridor','track')) AS calculator_class_rows
        FROM fyp_features.roads_v2
    """,
    "roads_v2_highway_distribution": """
        SELECT highway, count(*) AS rows
        FROM fyp_features.roads_v2 GROUP BY highway ORDER BY rows DESC LIMIT 40
    """,
    "roads_v2_duplicate_geometry": """
        WITH g AS (SELECT md5(ST_AsEWKB(way)) AS fingerprint FROM fyp_features.roads_v2)
        SELECT count(*) AS duplicate_groups,
               coalesce(sum(rows - 1), 0) AS duplicate_rows
        FROM (SELECT fingerprint, count(*) AS rows FROM g GROUP BY fingerprint HAVING count(*) > 1) d
    """,
    "road_junctions_v2": """
        SELECT count(*) AS rows,
               count(*) FILTER (WHERE geom IS NULL) AS null_geometry,
               count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalid_geometry,
               min(ST_SRID(geom)) AS srid,
               ST_AsText(ST_Extent(geom)) AS extent
        FROM fyp_features.road_junctions_v2
    """,
    "worldpop_2025_constrained": """
        SELECT count(*) AS tiles,
               min(ST_SRID(rast)) AS srid_min, max(ST_SRID(rast)) AS srid_max,
               min((ST_Metadata(rast)).scalex) AS pixel_x_m,
               min((ST_Metadata(rast)).scaley) AS pixel_y_m,
               min((ST_Metadata(rast)).numbands) AS bands,
               min(ST_BandNoDataValue(rast, 1)) AS nodata,
               ST_AsText(ST_Extent(ST_ConvexHull(rast))) AS extent,
               obj_description('public.worldpop_2025_constrained'::regclass, 'pg_class') AS table_comment
        FROM public.worldpop_2025_constrained
    """,
    "worldpop_stats": """
        SELECT count(*) AS sampled_tiles,
               sum((ST_SummaryStats(rast, 1, true)).count) AS value_pixels,
               max((ST_SummaryStats(rast, 1, true)).min) AS min_value,
               max((ST_SummaryStats(rast, 1, true)).max) AS max_value
        FROM public.worldpop_2025_constrained
    """,
    "psense_edges": """
        SELECT count(*) AS edges,
               count(*) FILTER (WHERE cost IS NOT NULL) AS cost_present,
               count(*) FILTER (WHERE reverse_cost IS NOT NULL) AS reverse_cost_present,
               count(*) FILTER (WHERE walk_cost IS NOT NULL) AS walk_cost_present,
               count(*) FILTER (WHERE walk_reverse_cost IS NOT NULL) AS walk_reverse_cost_present,
               count(*) FILTER (WHERE scomp_strong IS NOT NULL) AS strong_component_edges,
               count(*) FILTER (WHERE scomp_walk IS NOT NULL) AS walk_component_edges,
               count(*) FILTER (WHERE cls IN ('motorway','motorway_link')) AS walk_excluded_edges,
               count(*) FILTER (WHERE geom IS NULL) AS null_geometry,
               count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalid_geometry,
               min(ST_SRID(geom)) AS srid_min, max(ST_SRID(geom)) AS srid_max,
               ST_AsText(ST_Extent(geom)) AS extent
        FROM public.psense_edges
    """,
    "ur_walknode": """
        SELECT count(*) AS nodes,
               count(*) FILTER (WHERE comp IS NOT NULL) AS component_nodes,
               count(*) FILTER (WHERE geom IS NULL) AS null_geometry,
               count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalid_geometry,
               min(ST_SRID(geom)) AS srid_min, max(ST_SRID(geom)) AS srid_max,
               ST_AsText(ST_Extent(geom)) AS extent
        FROM public.ur_walknode
    """,
    "psense_verts": """
        SELECT count(*) AS vertices,
               count(DISTINCT vid) AS distinct_vids,
               count(*) FILTER (WHERE geom IS NULL) AS null_geometry,
               count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalid_geometry,
               min(ST_SRID(geom)) AS srid_min, max(ST_SRID(geom)) AS srid_max,
               ST_AsText(ST_Extent(geom)) AS extent
        FROM public.psense_verts
    """,
    "postgis_version": """
        SELECT postgis_full_version() AS version
    """,
    "source_version_tables": """
        SELECT n.nspname AS schema, c.relname AS table_name
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE (n.nspname='fyp_features' AND c.relname LIKE '%road%')
           OR (n.nspname='public' AND c.relname LIKE '%worldpop%')
           OR (n.nspname='public' AND c.relname LIKE '%gtfs%')
        ORDER BY 1,2 LIMIT 80
    """,
    "object_comments": """
        SELECT c.relname AS table_name, obj_description(c.oid, 'pg_class') AS comment
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE (n.nspname,c.relname) IN (
          ('fyp_features','roads_v2'), ('fyp_features','road_junctions_v2'),
          ('public','worldpop_2025_constrained'), ('public','psense_edges'),
          ('public','ur_walknode'), ('public','psense_verts'))
        ORDER BY c.relname
    """,
}


def serialise(rows):
    return [dict(r) for r in rows.mappings()] if rows is not None else []


def main() -> None:
    url = make_url(os.environ["DATABASE_URL"])
    engine = create_engine(url)
    log.info("Connected to %s@%s:%s/%s", url.username, url.host, url.port, url.database)
    result = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "database": url.database,
        "server": f"{url.host}:{url.port}",
        "definition_version": "expanded64-feature-definitions-v1",
        "queries": {},
    }
    sql_dump = ["-- Executed read-only source inventory SQL (no credentials included)\n"]
    with engine.connect() as conn:
        conn.exec_driver_sql("SET TRANSACTION READ ONLY")
        conn.exec_driver_sql("SET LOCAL statement_timeout = '120s'")
        for name, sql in QUERIES.items():
            log.info("Running %s", name)
            sql_dump.append(f"\n-- {name}\n{sql.strip()};\n")
            try:
                with conn.begin_nested():
                    rows = conn.execute(text(sql))
                    result["queries"][name] = serialise(rows)
                log.info("Completed %s: %d row(s)", name, len(result["queries"][name]))
            except Exception as exc:  # noqa: BLE001 - report, never guess
                result["queries"][name] = {"error": f"{type(exc).__name__}: {exc}"[:500]}
                log.warning("Failed %s: %s", name, type(exc).__name__)
    (SQL_DIR / "01_source_inventory.sql").write_text("".join(sql_dump), encoding="utf-8")
    out = ROOT / "expanded64_v2_source_inventory.json"
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False, default=str), encoding="utf-8")
    log.info("Wrote %s", out)


if __name__ == "__main__":
    main()
