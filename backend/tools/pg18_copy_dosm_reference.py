"""Copy the three DOSM district reference tables into the PG18 test database.

Aggregate government statistics only — no property record, no personal data.
Restored in full because a partial district table would report wrong
demographics for any district it only half covers.

Source: read-only session on Final_Location_Analysis.
Target: project1_pg18_migrated_tests @ 5544 (identity proven by the server).
"""

from __future__ import annotations

import io
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import psycopg2

BACKEND = Path(__file__).resolve().parents[1]
RECEIPT = BACKEND / "var" / "e2e" / "pg18" / "copy_dosm_receipt.json"

TABLES = ["district_population", "district_age_population", "hh_income_district"]
EXPECTED = {"district_population": 175, "district_age_population": 3150, "hh_income_district": 74}


def _pw() -> str:
    for line in (BACKEND / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith("DATABASE_URL="):
            return line.split("://", 1)[1].split("@", 1)[0].split(":", 1)[1]
    raise SystemExit("no DATABASE_URL")


def columns(conn, schema: str, table: str) -> list[str]:
    with conn.cursor() as cur:
        cur.execute(
            "select a.attname from pg_attribute a "
            "join pg_class c on c.oid = a.attrelid "
            "join pg_namespace n on n.oid = c.relnamespace "
            "where n.nspname=%s and c.relname=%s "
            "and a.attnum>0 and not a.attisdropped order by a.attnum",
            (schema, table),
        )
        return [r[0] for r in cur.fetchall()]


def main() -> int:
    src = psycopg2.connect(
        host="127.0.0.1", port=5432, dbname="Final_Location_Analysis",
        user="postgres", password=_pw(), connect_timeout=10,
        options="-c default_transaction_read_only=on",
    )
    tgt = psycopg2.connect(
        host="127.0.0.1", port=5544, dbname="project1_pg18_migrated_tests",
        user="postgres", password="p1_pg18_dev_only_5544", connect_timeout=10,
    )

    with src.cursor() as cur:
        cur.execute("select current_database(), inet_server_port(), current_setting('transaction_read_only')")
        s = cur.fetchone()
    with tgt.cursor() as cur:
        cur.execute("select current_database(), inet_server_port()")
        t = cur.fetchone()
    if s != ("Final_Location_Analysis", 5432, "on"):
        raise SystemExit(f"REFUSED: source not read-only FLA: {s}")
    if t != ("project1_pg18_migrated_tests", 5544):
        raise SystemExit(f"REFUSED: target not the PG18 test DB: {t}")

    receipt: dict[str, object] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "tables": {},
    }

    for table in TABLES:
        with tgt.cursor() as cur:
            cur.execute(f'select count(*) from public."{table}"')
            if cur.fetchone()[0]:
                raise SystemExit(f"REFUSED: public.{table} already populated")

        cols = columns(src, "public", table)
        buf = io.StringIO()
        with src.cursor() as scur:
            scur.copy_expert(
                f'COPY (SELECT {", ".join(cols)} FROM public."{table}") '
                "TO STDOUT WITH (FORMAT csv)",
                buf,
            )
        buf.seek(0)
        with tgt.cursor() as tcur:
            tcur.copy_expert(
                f'COPY public."{table}" ({", ".join(cols)}) FROM STDIN WITH (FORMAT csv)',
                buf,
            )
        tgt.commit()
        with tgt.cursor() as tcur:
            tcur.execute(f'select count(*) from public."{table}"')
            landed = tcur.fetchone()[0]
        receipt["tables"][f"public.{table}"] = {
            "rows": landed,
            "expected": EXPECTED[table],
            "ok": landed == EXPECTED[table],
        }

    with tgt.cursor() as cur:
        cur.execute("grant select on all tables in schema public to sitewise_e2e")
    tgt.commit()

    ok = all(v["ok"] for v in receipt["tables"].values())
    receipt["verdict"] = "DOSM_VERIFIED" if ok else "DOSM_FAILED"
    RECEIPT.write_text(json.dumps(receipt, indent=2), encoding="utf-8")
    print(json.dumps(receipt, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
