"""Compare the ``public`` schema of Dss and Final_Location_Analysis.

The PG18 baseline was restored from ``Dss``. If ``Dss`` is not a faithful copy
of the schema the application actually runs against (``Final_Location_Analysis``
— the DB ``backend/.env`` names), then every table that diverges is a latent
failure in the E2E environment.

Read-only on both. Reports, per table: present/absent, and the exact column
type differences.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import psycopg2

TABLES = [
    "favorite_property",
    "users",
    "user_profile",
    "property",
    "assessment",
    "assessment_answer",
    "assessment_section",
    "property_photo",
    "property_geospatial_feature",
    "saved_search",
]


def _pw() -> str:
    for line in (Path(__file__).resolve().parents[1] / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith("DATABASE_URL="):
            return line.split("://", 1)[1].split("@", 1)[0].split(":", 1)[1]
    raise SystemExit("no DATABASE_URL")


def cols(conn, table: str) -> dict[str, str]:
    with conn.cursor() as cur:
        cur.execute(
            "select a.attname, format_type(a.atttypid, a.atttypmod) "
            "from pg_attribute a join pg_class c on c.oid = a.attrelid "
            "join pg_namespace n on n.oid = c.relnamespace "
            "where n.nspname='public' and c.relname=%s "
            "and a.attnum > 0 and not a.attisdropped order by a.attnum",
            (table,),
        )
        return dict(cur.fetchall())


def main() -> int:
    out: dict[str, object] = {}
    conns = {}
    for db in ("Dss", "Final_Location_Analysis"):
        conns[db] = psycopg2.connect(
            host="127.0.0.1", port=5432, dbname=db, user="postgres",
            password=_pw(), connect_timeout=10,
            options="-c default_transaction_read_only=on",
        )

    for table in TABLES:
        a = cols(conns["Dss"], table)
        b = cols(conns["Final_Location_Analysis"], table)
        if not a and not b:
            out[table] = {"status": "absent_in_both"}
            continue
        if not a:
            out[table] = {"status": "absent_in_Dss", "fla_columns": len(b)}
            continue
        if not b:
            out[table] = {"status": "absent_in_FLA", "dss_columns": len(a)}
            continue
        diffs = {
            k: {"Dss": a.get(k), "FLA": b.get(k)}
            for k in sorted(set(a) | set(b))
            if a.get(k) != b.get(k)
        }
        out[table] = {
            "status": "identical" if not diffs else "DIVERGENT",
            "dss_columns": len(a),
            "fla_columns": len(b),
            "differences": diffs,
        }

    # Table-level presence across the whole public schema.
    presence = {}
    for db in ("Dss", "Final_Location_Analysis"):
        with conns[db].cursor() as cur:
            cur.execute(
                "select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace "
                "where n.nspname='public' and c.relkind='r' order by 1"
            )
            presence[db] = {r[0] for r in cur.fetchall()}
    out["_summary"] = {
        "dss_tables": len(presence["Dss"]),
        "fla_tables": len(presence["Final_Location_Analysis"]),
        "only_in_FLA": sorted(presence["Final_Location_Analysis"] - presence["Dss"])[:40],
        "only_in_Dss": sorted(presence["Dss"] - presence["Final_Location_Analysis"])[:40],
    }

    print(json.dumps(out, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
