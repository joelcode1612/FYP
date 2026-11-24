"""Copy the 24 expanded64 feature rows for the approved 8 properties.

The live recommender scores candidates from three feature sources. Without
them the score silently loses population/demand/competition inputs, so they
are copied for exactly the same 8 catalogue ids as the property copy:

    sitewise_analytics.subject_features          8
    demand_gen.features                          8
    fyp_features.property_population_spatial     8

Read-only on the source, write-only on the verified PG18 target.
"""

from __future__ import annotations

import io
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import psycopg2

BACKEND = Path(__file__).resolve().parents[1]
RECEIPT = BACKEND / "var" / "e2e" / "pg18" / "copy_features_receipt.json"

LISTING_IDS = [
    "MD-04816",
    "MD-03209",
    "MD-02817",
    "EP-02638",
    "EP-02087",
    "MD-02123",
    "MD-03578",
    "MD-01160",
]

COPIES = [
    ("sitewise_analytics", "subject_features", "subject_id", "subject_id"),
    ("demand_gen", "features", "subject_id", "subject_id"),
    ("fyp_features", "property_population_spatial", "source_record_id", "source_record_id"),
]


def _source_password() -> str:
    for line in (BACKEND / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith("DATABASE_URL="):
            creds = line.split("://", 1)[1].split("@", 1)[0]
            return creds.split(":", 1)[1]
    raise SystemExit("DATABASE_URL not found in backend/.env")


def columns(conn, schema: str, table: str) -> list[str]:
    with conn.cursor() as cur:
        cur.execute(
            "select a.attname from pg_attribute a "
            "join pg_class c on c.oid = a.attrelid "
            "join pg_namespace n on n.oid = c.relnamespace "
            "where n.nspname = %s and c.relname = %s "
            "and a.attnum > 0 and not a.attisdropped order by a.attnum",
            (schema, table),
        )
        return [r[0] for r in cur.fetchall()]


def main() -> int:
    src = psycopg2.connect(
        host="127.0.0.1",
        port=5432,
        dbname="Final_Location_Analysis",
        user="postgres",
        password=_source_password(),
        connect_timeout=10,
        options="-c default_transaction_read_only=on",
    )
    tgt = psycopg2.connect(
        host="127.0.0.1",
        port=5544,
        dbname="project1_pg18_migrated_tests",
        user="postgres",
        password="p1_pg18_dev_only_5544",
        connect_timeout=10,
    )

    with src.cursor() as cur:
        cur.execute("select current_database(), inet_server_port(), "
                    "current_setting('transaction_read_only')")
        s = cur.fetchone()
    with tgt.cursor() as cur:
        cur.execute("select current_database(), inet_server_port()")
        t = cur.fetchone()
    if s[0] != "Final_Location_Analysis" or s[1] != 5432 or s[2] != "on":
        raise SystemExit(f"REFUSED: source not read-only FLA: {s}")
    if t[0] != "project1_pg18_migrated_tests" or t[1] != 5544:
        raise SystemExit(f"REFUSED: target not the PG18 test DB: {t}")

    receipt: dict[str, object] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "listing_ids": LISTING_IDS,
        "tables": {},
    }

    for schema, table, key, where_col in COPIES:
        key_name = f"{schema}.{table}"
        with tgt.cursor() as cur:
            cur.execute(f'select count(*) from "{schema}"."{table}"')
            if cur.fetchone()[0]:
                raise SystemExit(f"REFUSED: {key_name} already populated")

        cols = columns(src, schema, table)
        buf = io.StringIO()
        with src.cursor() as scur:
            where_sql = scur.mogrify(f"{where_col} = ANY(%s)", (LISTING_IDS,)).decode()
            scur.copy_expert(
                f'COPY (SELECT {", ".join(cols)} FROM "{schema}"."{table}" '
                f"WHERE {where_sql} ORDER BY {key}) TO STDOUT WITH (FORMAT csv)",
                buf,
            )
        buf.seek(0)
        with tgt.cursor() as tcur:
            tcur.copy_expert(
                f'COPY "{schema}"."{table}" ({", ".join(cols)}) '
                "FROM STDIN WITH (FORMAT csv)",
                buf,
            )
        tgt.commit()
        with tgt.cursor() as tcur:
            tcur.execute(f'select count(*) from "{schema}"."{table}"')
            landed = tcur.fetchone()[0]
        receipt["tables"][key_name] = {"rows": landed, "ok": landed == 8}

    with tgt.cursor() as cur:
        for schema in ("sitewise_analytics", "demand_gen", "fyp_features"):
            cur.execute(f"grant usage on schema {schema} to sitewise_e2e")
            cur.execute(
                f"grant select, insert, update, delete on all tables in schema {schema} "
                "to sitewise_e2e"
            )
            cur.execute(
                f"alter default privileges in schema {schema} "
                "grant select, insert, update, delete on tables to sitewise_e2e"
            )
    tgt.commit()

    ok = all(v["ok"] for v in receipt["tables"].values())
    receipt["verdict"] = "FEATURES_VERIFIED" if ok else "FEATURES_FAILED"
    RECEIPT.write_text(json.dumps(receipt, indent=2), encoding="utf-8")
    print(json.dumps(receipt, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
