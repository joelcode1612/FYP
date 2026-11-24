"""Read-only survey: where does a ``fyp.rental_properties.geom`` actually exist?

The Explore repository requires ``p.geom`` plus PostGIS ``ST_*`` functions, but
``Final_Location_Analysis`` (the DB the app points at) has neither. Before
deciding anything, measure every local cluster: which databases contain a
``fyp.rental_properties`` table, how many rows, and whether it carries ``geom``.

Read-only by construction: every session sets ``default_transaction_read_only``.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import psycopg2

CLUSTERS = [(5432, "PostgreSQL 16"), (5433, "PostgreSQL 18 legacy"), (5544, "PG18 E2E")]


def _password() -> str:
    env_path = Path(__file__).resolve().parents[1] / ".env"
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("DATABASE_URL="):
            creds = line.split("://", 1)[1].split("@", 1)[0]
            return creds.split(":", 1)[1]
    raise SystemExit("DATABASE_URL not found in backend/.env")


def _connect(port: int, dbname: str):
    return psycopg2.connect(
        host="127.0.0.1",
        port=port,
        dbname=dbname,
        user="postgres",
        password=_password(),
        connect_timeout=8,
        options="-c default_transaction_read_only=on",
    )


def survey() -> dict:
    result: dict[str, object] = {}
    for port, label in CLUSTERS:
        entry: dict[str, object] = {"label": label, "databases": {}}
        try:
            with _connect(port, "postgres") as admin:
                with admin.cursor() as cur:
                    cur.execute(
                        "SELECT datname FROM pg_database "
                        "WHERE datistemplate = false AND datallowconn ORDER BY 1"
                    )
                    dbs = [r[0] for r in cur.fetchall()]
        except Exception as exc:  # noqa: BLE001
            entry["error"] = str(exc).strip().splitlines()[0]
            result[str(port)] = entry
            continue

        for db in dbs:
            info: dict[str, object] = {}
            try:
                with _connect(port, db) as conn:
                    with conn.cursor() as cur:
                        cur.execute(
                            "SELECT to_regclass('fyp.rental_properties') IS NOT NULL"
                        )
                        has_table = cur.fetchone()[0]
                        if not has_table:
                            continue
                        cur.execute(
                            "SELECT count(*) FROM pg_attribute a "
                            "JOIN pg_class c ON c.oid = a.attrelid "
                            "JOIN pg_namespace n ON n.oid = c.relnamespace "
                            "WHERE n.nspname='fyp' AND c.relname='rental_properties' "
                            "AND a.attname='geom' AND a.attnum > 0 AND NOT a.attisdropped"
                        )
                        info["has_geom"] = cur.fetchone()[0] == 1
                        cur.execute("SELECT count(*) FROM fyp.rental_properties")
                        info["rows"] = cur.fetchone()[0]
                        cur.execute(
                            "SELECT extname FROM pg_extension WHERE extname='postgis'"
                        )
                        info["postgis"] = bool(cur.fetchall())
                        cur.execute(
                            "SELECT count(*) FROM fyp.rental_properties "
                            "WHERE is_published AND verification_status = 'approved'"
                        )
                        info["published_approved"] = cur.fetchone()[0]
            except Exception as exc:  # noqa: BLE001
                info["error"] = str(exc).strip().splitlines()[0]
            entry["databases"][db] = info
        result[str(port)] = entry
    return result


if __name__ == "__main__":
    print(json.dumps(survey(), indent=2, default=str))
    sys.exit(0)
