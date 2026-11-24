"""Read-only probe: what does ``fyp`` actually depend on in the source DB?

Answers, by asking the server rather than guessing:

  1. Does ``Final_Location_Analysis`` have PostGIS, and in which schema?
  2. What is the real type of ``fyp.rental_properties.geom``?
  3. Which extension-owned objects does the ``fyp`` schema rely on?
  4. Can the exact Explore predicate execute as written?

Nothing here writes. The source is opened with a session-level
``default_transaction_read_only=on`` so a mistake cannot mutate it.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import psycopg2

SOURCE_DB = "Final_Location_Analysis"
SOURCE_PORT = 5432
SOURCE_HOST = "127.0.0.1"


def _password() -> str:
    env_path = Path(__file__).resolve().parents[1] / ".env"
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("DATABASE_URL="):
            url = line.split("=", 1)[1]
            # postgresql+psycopg2://user:pass@host:port/db
            creds = url.split("://", 1)[1].split("@", 1)[0]
            return creds.split(":", 1)[1]
    raise SystemExit("DATABASE_URL not found in backend/.env")


def main() -> int:
    dsn = (
        f"host={SOURCE_HOST} port={SOURCE_PORT} dbname={SOURCE_DB} "
        f"user=postgres password={_password()} "
        f"options='-c default_transaction_read_only=on'"
    )
    out: dict[str, object] = {}

    with psycopg2.connect(dsn, connect_timeout=10) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT current_database(), inet_server_port(), "
                "coalesce(host(inet_server_addr()),'?'), version()"
            )
            db, port, addr, ver = cur.fetchone()
            out["identity"] = {
                "database": db,
                "port": port,
                "address": addr,
                "version": ver.split(",")[0],
            }
            if db != SOURCE_DB or port != SOURCE_PORT:
                print(json.dumps({"REFUSED": out["identity"]}, indent=2))
                return 2

            cur.execute(
                "SELECT extname, extversion, n.nspname "
                "FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace "
                "ORDER BY extname"
            )
            out["extensions"] = [
                {"name": r[0], "version": r[1], "schema": r[2]}
                for r in cur.fetchall()
            ]

            cur.execute(
                "SELECT n.nspname FROM pg_namespace n "
                "WHERE n.nspname IN ('fyp','fnb_a','demand_gen','sitewise_analytics',"
                "'fyp_features','public') ORDER BY 1"
            )
            out["schemas_present"] = [r[0] for r in cur.fetchall()]

            # Where do the ST_ functions the repository calls actually live?
            cur.execute(
                "SELECT p.proname, n.nspname, e.extname "
                "FROM pg_proc p "
                "JOIN pg_namespace n ON n.oid = p.pronamespace "
                "LEFT JOIN pg_depend d ON d.objid = p.oid AND d.deptype = 'e' "
                "LEFT JOIN pg_extension e ON e.oid = d.refobjid "
                "WHERE p.proname IN ('st_expand','st_dwithin','st_setsrid',"
                "'st_makepoint','st_distance','st_distance_sphere','st_area') "
                "ORDER BY 1, 2"
            )
            out["st_functions"] = [
                {"name": r[0], "schema": r[1], "extension": r[2]}
                for r in cur.fetchall()
            ]

            # Real column type of geom, and whether a generated expression exists.
            cur.execute(
                "SELECT a.attname, format_type(a.atttypid, a.atttypmod), "
                "a.attgenerated, a.attnotnull "
                "FROM pg_attribute a "
                "JOIN pg_class c ON c.oid = a.attrelid "
                "JOIN pg_namespace n ON n.oid = c.relnamespace "
                "WHERE n.nspname='fyp' AND c.relname='rental_properties' "
                "AND a.attnum > 0 AND NOT a.attisdropped "
                "ORDER BY a.attnum"
            )
            out["rental_properties_columns"] = [
                {"name": r[0], "type": r[1], "generated": r[2], "notnull": r[3]}
                for r in cur.fetchall()
            ]

            # Extension objects referenced by fyp-owned relations (indexes etc.).
            cur.execute(
                "SELECT DISTINCT e.extname, d.classid::regclass::text AS objclass, "
                "count(*) "
                "FROM pg_depend d "
                "JOIN pg_extension e ON e.oid = d.refobjid "
                "JOIN pg_class c ON c.oid = d.objid "
                "JOIN pg_namespace n ON n.oid = c.relnamespace "
                "WHERE n.nspname = 'fyp' "
                "GROUP BY 1, 2 ORDER BY 1"
            )
            out["fyp_extension_dependencies"] = [
                {"extension": r[0], "object_class": r[1], "count": r[2]}
                for r in cur.fetchall()
            ]

            # Can the exact Explore predicate execute? LIMIT 0 keeps it free.
            try:
                cur.execute(
                    "SELECT p.id FROM fyp.rental_properties p "
                    "WHERE p.is_published AND p.verification_status = 'approved' "
                    "AND p.geom && ST_Expand(p.geom, 0.005) "
                    "AND ST_DWithin(p.geom::geography, p.geom::geography, 500) "
                    "LIMIT 0"
                )
                out["explore_predicate_executes"] = True
            except Exception as exc:  # noqa: BLE001 - we want the message
                out["explore_predicate_executes"] = False
                out["explore_predicate_error"] = str(exc).strip().splitlines()[0]

    print(json.dumps(out, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
