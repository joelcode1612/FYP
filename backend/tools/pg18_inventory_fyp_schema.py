"""Read-only inventory of the ``fyp`` schema in the source database.

Lists every table, its row count, and — for the tables the application's
catalogue/Explore path actually reads — the column types, so the copy plan can
be built from measurement instead of from the repository's assumptions.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import psycopg2

SOURCE_DB = "Final_Location_Analysis"
SOURCE_PORT = 5432

#: Tables the application reads on the assessment-selector / catalogue path.
WATCHED = {
    "catalogue_properties",
    "rental_properties",
    "property_photos",
    "property_geospatial_features",
    "property_listing_sources",
    "property_subject_links",
    "property_features",
    "property_listing_verification",
    "property_enrichment_category",
    "property_feature_freshness",
}


def _password() -> str:
    env_path = Path(__file__).resolve().parents[1] / ".env"
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("DATABASE_URL="):
            creds = line.split("://", 1)[1].split("@", 1)[0]
            return creds.split(":", 1)[1]
    raise SystemExit("DATABASE_URL not found in backend/.env")


def main() -> int:
    conn = psycopg2.connect(
        host="127.0.0.1",
        port=SOURCE_PORT,
        dbname=SOURCE_DB,
        user="postgres",
        password=_password(),
        connect_timeout=10,
        options="-c default_transaction_read_only=on",
    )
    out: dict[str, object] = {}
    with conn, conn.cursor() as cur:
        cur.execute("SELECT current_database(), inet_server_port()")
        db, port = cur.fetchone()
        if db != SOURCE_DB or port != SOURCE_PORT:
            print(json.dumps({"REFUSED": [db, port]}, indent=2))
            return 2

        cur.execute(
            "SELECT c.relname, c.relkind "
            "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
            "WHERE n.nspname='fyp' AND c.relkind IN ('r','v','m','p') "
            "ORDER BY c.relname"
        )
        relations = cur.fetchall()

        tables: dict[str, object] = {}
        for name, kind in relations:
            info: dict[str, object] = {"kind": kind}
            try:
                cur.execute(f'SELECT count(*) FROM fyp."{name}"')
                info["rows"] = cur.fetchone()[0]
            except Exception as exc:  # noqa: BLE001
                conn.rollback()
                info["rows"] = None
                info["error"] = str(exc).strip().splitlines()[0]
            if name in WATCHED:
                try:
                    cur.execute(
                        "SELECT a.attname, format_type(a.atttypid, a.atttypmod) "
                        "FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid "
                        "JOIN pg_namespace n ON n.oid = c.relnamespace "
                        "WHERE n.nspname='fyp' AND c.relname=%s "
                        "AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum",
                        (name,),
                    )
                    info["columns"] = [{"name": r[0], "type": r[1]} for r in cur.fetchall()]
                except Exception as exc:  # noqa: BLE001
                    conn.rollback()
                    info["columns_error"] = str(exc).strip().splitlines()[0]
            tables[name] = info

    out["fyp_tables"] = tables
    out["table_count"] = len(tables)

    # Catalogue id shape — the selector's property_ref must match this.
    with conn, conn.cursor() as cur:
        try:
            cur.execute("SELECT id FROM fyp.catalogue_properties ORDER BY id LIMIT 5")
            out["catalogue_id_samples"] = [r[0] for r in cur.fetchall()]
            cur.execute("SELECT count(*) FROM fyp.catalogue_properties")
            out["catalogue_rows"] = cur.fetchone()[0]
        except Exception as exc:  # noqa: BLE001
            conn.rollback()
            out["catalogue_error"] = str(exc).strip().splitlines()[0]

    print(json.dumps(out, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
