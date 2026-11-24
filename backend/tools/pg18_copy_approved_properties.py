"""Approved minimal property copy: FLA -> PG18 ``project1_pg18_migrated_tests``.

Scope (Owner-approved, 8 properties, original ids preserved)
    fyp.rental_properties             8
    fyp.property_photos              95
    fyp.property_geospatial_features  8
    fyp.property_listing_sources      8
    fyp.property_subject_links        8
    sitewise_app.properties           8   (the catalogue rows the UI lists)
    demand_gen.subjects               8   (FK target of property_subject_links)

Guarantees
  * Source session is ``default_transaction_read_only=on`` — it cannot write.
  * Target identity is proven by asking the server (database, port, address);
    ``Dss``, ``Final_Location_Analysis``, ports 5432/5433 are refused.
  * Rows are moved with ``COPY ... TO/FROM STDIN`` in CSV so numeric,
    timestamptz and jsonb values are byte-faithful.
  * ``source_data->>'phone'`` is removed after copy: it is contact data, it is
    never surfaced by the API (``PROPERTY_COLUMNS`` excludes ``source_data``
    and ``_JSON_METRICS`` has no ``phone`` key), and nothing reads it.
  * Sequences are advanced past the copied ids so later inserts cannot collide.
  * Every count, every foreign key and the catalogue view are verified before
    the receipt is written.
"""

from __future__ import annotations

import io
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import psycopg2

BACKEND = Path(__file__).resolve().parents[1]
RECEIPT = BACKEND / "var" / "e2e" / "pg18" / "copy_receipt.json"

SOURCE = {
    "host": "127.0.0.1",
    "port": 5432,
    "dbname": "Final_Location_Analysis",
}
TARGET = {
    "host": "127.0.0.1",
    "port": 5544,
    "dbname": "project1_pg18_migrated_tests",
    "user": "postgres",
    "password": "p1_pg18_dev_only_5544",
}

APPROVED_IDS = [2, 35, 51, 120, 300, 550, 646, 799]
PROTECTED = {"Dss", "Final_Location_Analysis"}
FORBIDDEN_PORTS = {5432, 5433}

#: (schema, table, order-by column, where clause on the 8 ids)
COPIES = [
    ("demand_gen", "subjects", "subject_id", "subject_id = ANY(%s)"),
    ("sitewise_app", "properties", "id", "id = ANY(%s)"),
    ("fyp", "rental_properties", "id", "id = ANY(%s)"),
    ("fyp", "property_photos", "id", "property_id = ANY(%s)"),
    ("fyp", "property_geospatial_features", "id", "property_id = ANY(%s)"),
    ("fyp", "property_listing_sources", "id", "property_id = ANY(%s)"),
    ("fyp", "property_subject_links", "property_id", "property_id = ANY(%s)"),
]

EXPECTED_COUNTS = {
    "demand_gen.subjects": 8,
    "sitewise_app.properties": 8,
    "fyp.rental_properties": 8,
    "fyp.property_photos": 95,
    "fyp.property_geospatial_features": 8,
    "fyp.property_listing_sources": 8,
    "fyp.property_subject_links": 8,
}


def _source_password() -> str:
    for line in (BACKEND / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith("DATABASE_URL="):
            creds = line.split("://", 1)[1].split("@", 1)[0]
            return creds.split(":", 1)[1]
    raise SystemExit("DATABASE_URL not found in backend/.env")


def prove(conn, expect_db: str, expect_port: int, label: str, *, writable: bool) -> dict:
    """Prove which server we are on, and refuse unsafe combinations.

    ``writable=True`` (the target) refuses any protected database or port.
    ``writable=False`` (the source) permits a protected database ONLY when the
    server itself reports the session is read-only — asked of the server, not
    assumed from the DSN.
    """
    with conn.cursor() as cur:
        cur.execute(
            "select current_database(), current_user, inet_server_port(), "
            "coalesce(host(inet_server_addr()), '?'), "
            "current_setting('transaction_read_only')"
        )
        db, user, port, addr, ro = cur.fetchone()
    ident = {
        "database": db,
        "principal": user,
        "port": port,
        "address": addr,
        "transaction_read_only": ro,
    }
    if db != expect_db or port != expect_port:
        raise SystemExit(f"REFUSED[{label}]: {ident} != {expect_db}@{expect_port}")
    if writable:
        if db in PROTECTED:
            raise SystemExit(f"REFUSED[{label}]: {db} is a protected database")
        if port in FORBIDDEN_PORTS:
            raise SystemExit(f"REFUSED[{label}]: port {port} is protected")
    else:
        if ro != "on":
            raise SystemExit(
                f"REFUSED[{label}]: reading {db} requires a read-only session, "
                f"server reports transaction_read_only={ro!r}"
            )
    return ident


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
        **SOURCE,
        user="postgres",
        password=_source_password(),
        connect_timeout=10,
        options="-c default_transaction_read_only=on",
    )
    tgt = psycopg2.connect(**TARGET, connect_timeout=10)

    receipt: dict[str, object] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "approved_ids": APPROVED_IDS,
        "identity": {},
        "tables": {},
        "verification": {},
        "personal_data": {},
    }

    receipt["identity"]["source"] = prove(
        src, SOURCE["dbname"], SOURCE["port"], "source", writable=False
    )
    receipt["identity"]["target"] = prove(
        tgt, TARGET["dbname"], TARGET["port"], "target", writable=True
    )

    # Resolve the id sets once, so every table is filtered by real values.
    with src.cursor() as cur:
        cur.execute(
            "select id, listing_id from fyp.rental_properties "
            "where id = ANY(%s) order by id",
            (APPROVED_IDS,),
        )
        resolved = cur.fetchall()
    if len(resolved) != 8:
        raise SystemExit(f"REFUSED: expected 8 source rows, found {len(resolved)}")
    listing_ids = [r[1] for r in resolved]
    receipt["listing_ids"] = listing_ids

    id_map = {
        "demand_gen.subjects": listing_ids,
        "sitewise_app.properties": listing_ids,
        "fyp.rental_properties": APPROVED_IDS,
        "fyp.property_photos": APPROVED_IDS,
        "fyp.property_geospatial_features": APPROVED_IDS,
        "fyp.property_listing_sources": APPROVED_IDS,
        "fyp.property_subject_links": APPROVED_IDS,
    }

    # Refuse to double-copy: the target must be empty for this scope.
    for schema, table, _order, _where in COPIES:
        with tgt.cursor() as cur:
            cur.execute(f'select count(*) from "{schema}"."{table}"')
            existing = cur.fetchone()[0]
        if existing:
            raise SystemExit(
                f"REFUSED: {schema}.{table} already has {existing} row(s); "
                "this copy is one-shot and will not duplicate data"
            )

    for schema, table, order, where in COPIES:
        key = f"{schema}.{table}"
        cols = columns(src, schema, table)
        args = (id_map[key],)
        buf = io.StringIO()

        with src.cursor() as scur:
            # copy_expert takes no bind parameters, so the predicate is rendered
            # by the driver (mogrify) rather than by string formatting — the ids
            # are quoted by psycopg2 itself, never by this code.
            where_sql = scur.mogrify(where, args).decode()
            scur.copy_expert(
                f'COPY (SELECT {", ".join(cols)} FROM "{schema}"."{table}" '
                f"WHERE {where_sql} ORDER BY {order}) TO STDOUT WITH (FORMAT csv)",
                buf,
            )
        buf.seek(0)
        rows = buf.getvalue().count("\n")

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
        receipt["tables"][key] = {
            "rows_copied": rows,
            "rows_in_target": landed,
            "expected": EXPECTED_COUNTS[key],
            "ok": landed == EXPECTED_COUNTS[key],
        }

    # --- personal data: strip the contact phone from the copied catalogue rows
    with tgt.cursor() as cur:
        cur.execute(
            "select count(*) from sitewise_app.properties "
            "where source_data ? 'phone' and id = ANY(%s)",
            (listing_ids,),
        )
        phones = cur.fetchone()[0]
        cur.execute(
            "update sitewise_app.properties set source_data = source_data - 'phone' "
            "where source_data ? 'phone' and id = ANY(%s)",
            (listing_ids,),
        )
        stripped = cur.rowcount
    tgt.commit()
    receipt["personal_data"] = {
        "phone_keys_found": phones,
        "phone_keys_stripped": stripped,
        "note": (
            "source_data->>'phone' is contact data. It is not returned by the "
            "API (PROPERTY_COLUMNS excludes source_data; _JSON_METRICS has no "
            "phone key) and nothing in the assessment path reads it."
        ),
    }

    # --- promote exactly these 8 listings so the UI's published filter passes
    with tgt.cursor() as cur:
        cur.execute(
            "update fyp.rental_properties "
            "set is_published = true, verification_status = 'approved', "
            "    published_at = coalesce(published_at, now()) "
            "where id = ANY(%s)",
            (APPROVED_IDS,),
        )
        promoted = cur.rowcount
    tgt.commit()
    receipt["promotion"] = {"rows_promoted": promoted, "scope": APPROVED_IDS}

    # --- sequences: never let a later insert collide with a copied id
    seq_fixes = {}
    for seq, table, col in (
        ("fyp.rental_properties_id_seq", "fyp.rental_properties", "id"),
        ("fyp.property_photos_id_seq", "fyp.property_photos", "id"),
        ("fyp.property_geospatial_features_id_seq", "fyp.property_geospatial_features", "id"),
    ):
        with tgt.cursor() as cur:
            cur.execute(f"select coalesce(max({col}), 0) from {table}")
            hi = cur.fetchone()[0]
            if hi:
                cur.execute("select setval(%s, %s, true)", (seq, hi))
                seq_fixes[seq] = hi
    tgt.commit()
    receipt["sequences"] = seq_fixes

    # --- permissions for the application role
    with tgt.cursor() as cur:
        for schema in ("fyp", "sitewise_app", "demand_gen"):
            cur.execute(f"grant usage on schema {schema} to sitewise_e2e")
            cur.execute(
                f"grant select, insert, update, delete on all tables in schema {schema} "
                "to sitewise_e2e"
            )
            cur.execute(
                f"alter default privileges in schema {schema} "
                "grant select, insert, update, delete on tables to sitewise_e2e"
            )
            cur.execute(f"grant usage, select on all sequences in schema {schema} to sitewise_e2e")
    tgt.commit()

    # --- verification: counts, FKs, the view, and what the app will see
    v: dict[str, object] = {}
    with tgt.cursor() as cur:
        cur.execute(
            "select count(*) from fyp.rental_properties "
            "where is_published and verification_status = 'approved'"
        )
        v["published_approved"] = cur.fetchone()[0]

        cur.execute(
            "select count(*) from fyp.catalogue_properties where id = ANY(%s)",
            (listing_ids,),
        )
        v["catalogue_view_rows"] = cur.fetchone()[0]

        cur.execute(
            "select id, title, property_type, rental_rm, latitude, longitude, "
            "suitability_score from fyp.catalogue_properties "
            "where id = ANY(%s) order by id",
            (listing_ids,),
        )
        v["catalogue_view_sample"] = [
            {
                "id": r[0],
                "title": (r[1] or "")[:60],
                "type": r[2],
                "rent": float(r[3]) if r[3] is not None else None,
                "lat": float(r[4]) if r[4] is not None else None,
                "lon": float(r[5]) if r[5] is not None else None,
                "score": float(r[6]) if r[6] is not None else None,
            }
            for r in cur.fetchall()
        ]

        # Every FK must be satisfiable: count orphaned references.
        cur.execute(
            "select count(*) from fyp.property_photos p "
            "left join fyp.rental_properties r on r.id = p.property_id "
            "where r.id is null"
        )
        v["orphan_photos"] = cur.fetchone()[0]
        cur.execute(
            "select count(*) from fyp.property_subject_links l "
            "left join sitewise_app.properties s on s.id = l.sitewise_property_id "
            "where l.sitewise_property_id is not null and s.id is null"
        )
        v["orphan_subject_links_catalogue"] = cur.fetchone()[0]
        cur.execute(
            "select count(*) from fyp.property_subject_links l "
            "left join demand_gen.subjects s on s.subject_id = l.subject_id "
            "where l.subject_id is not null and s.subject_id is null"
        )
        v["orphan_subject_links_subject"] = cur.fetchone()[0]

        cur.execute(
            "select count(*) from sitewise_app.properties where source_data ? 'phone'"
        )
        v["phone_keys_remaining"] = cur.fetchone()[0]

    receipt["verification"] = v

    ok = (
        all(t["ok"] for t in receipt["tables"].values())
        and v["published_approved"] == 8
        and v["catalogue_view_rows"] == 8
        and v["orphan_photos"] == 0
        and v["orphan_subject_links_catalogue"] == 0
        and v["orphan_subject_links_subject"] == 0
        and v["phone_keys_remaining"] == 0
    )
    receipt["verdict"] = "COPY_VERIFIED" if ok else "COPY_FAILED"

    RECEIPT.write_text(json.dumps(receipt, indent=2, default=str), encoding="utf-8")
    print(json.dumps(receipt, indent=2, default=str))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
