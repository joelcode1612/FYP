"""Register M2V2-20261122-1 as an authorized instrument in the isolated PG18 cluster.

Purpose
    Make the 19-item M2 V2 definition resolvable by the normal SiteWise
    assessment workflow inside ``project1_pg18_migrated_tests`` on port 5544.

Reason
    The application reads its questionnaire entirely from
    ``public.m2_item_versions``; nothing in the UI is hard-coded. The isolated
    cluster therefore has to hold a registered instrument row plus its 19 item
    rows before a marketplace assessment can open a real M2 record. The owner
    authorized M2V2 for this test environment on 2026-11-23 (receipt
    ``OWNER-TEST-ENV-M2V2-20261123``), so the row is written as ``AUTHORIZED``
    *in this cluster only*.

Constraint
    The stored ``approval_state`` is governance data, so this tool never
    invents an authorization: ``--apply`` requires the exact receipt string,
    and the receipt is written into the output JSON next to the digest it
    authorized. It also refuses any target that is not an isolated
    ``project1_*`` database on a non-default port, which makes it structurally
    unable to run against ``Dss`` or ``Final_Location_Analysis``. The
    definition file itself is not edited: its own ``adoption`` block still
    declares ``PROPOSED_NOT_AUTHORIZED`` and is recorded verbatim, because the
    candidate provenance must survive the test-environment activation.

    No DDL is performed. No assessment, answer, confirmation or campaign row is
    created. Default mode is a read-only preflight.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

FOLDER = ROOT / "src/sitewise/instruments/m2v2_20261122"
EXPECTED_DATABASE = "project1_pg18_migrated_tests"
ISOLATED_PORT = 5544
FORBIDDEN_DATABASES = {"Dss", "Final_Location_Analysis", "postgres"}
FORBIDDEN_PORTS = {5432}

#: The single string that turns a read-only preflight into a write. It names the
#: decision, the scope and the date, so an accidental ``--apply`` is still an
#: explicit statement about which authorization is being recorded.
AUTHORIZATION_RECEIPT = "OWNER-TEST-ENV-M2V2-20261123"

#: What the definition file itself declares. Recorded verbatim in the receipt so
#: the gap between "candidate" and "authorized here" is visible, not implied.
DEFINITION_DECLARED_STATE = "PROPOSED_NOT_AUTHORIZED"
REGISTERED_STATE = "AUTHORIZED"


def definition():
    """Return (definition, digest, instrument_id, item_rows) for M2V2."""
    data = json.loads((FOLDER / "definition.json").read_text(encoding="utf-8"))
    actual = hashlib.sha256((FOLDER / "source.txt").read_bytes()).hexdigest()
    if actual != data["source_sha256"]:
        raise ValueError("source.txt no longer matches the declared source hash.")
    keys = [q["item_key"] for q in data["items"]]
    if keys != [f"M2V2-{i:02d}" for i in range(1, 20)]:
        raise ValueError(f"unexpected item keys: {keys}")
    if data["adoption"]["approval_state"] != DEFINITION_DECLARED_STATE:
        raise ValueError(
            "The definition no longer declares itself a candidate. Refusing to "
            "infer an authorization that the source does not state.")
    if data["version_tag"] != "M2V2-20261122-1":
        raise ValueError(f"unexpected version_tag: {data['version_tag']}")
    digest = hashlib.sha256(
        json.dumps(data, sort_keys=True, ensure_ascii=False,
                   separators=(",", ":")).encode()
    ).hexdigest()
    iid = uuid5(NAMESPACE_URL, data["code"] + ":" + data["version_tag"] + ":" + digest)
    rows = [dict(id=uuid5(iid, q["item_key"]), instrument_id=iid,
                 **{k: v for k, v in q.items() if k != "title"})
            for q in data["items"]]
    return data, digest, iid, rows


def register(engine, *, apply=False, receipt=None):
    from sqlalchemy import inspect, select, text
    from sitewise.db.models.m2_schema import instruments, items

    if apply and receipt != AUTHORIZATION_RECEIPT:
        raise ValueError("--apply requires the exact authorization receipt.")

    data, digest, iid, rows = definition()
    with engine.begin() as conn:
        if not apply:
            conn.exec_driver_sql("SET TRANSACTION READ ONLY")

        # Ask the server what it is, rather than trusting the DSN we were given.
        database = conn.scalar(text("SELECT current_database()"))
        port = conn.scalar(text("SELECT inet_server_port()"))
        if database in FORBIDDEN_DATABASES or not database.startswith("project1_"):
            raise ValueError(f"Refusing non-isolated database: {database}")
        if port in FORBIDDEN_PORTS:
            raise ValueError(f"Refusing non-disposable port: {port}")
        if database != EXPECTED_DATABASE:
            raise ValueError(f"Expected {EXPECTED_DATABASE}, connected to {database}")
        if port != ISOLATED_PORT:
            raise ValueError(f"Expected port {ISOLATED_PORT}, connected to {port}")

        for table in (instruments, items):
            columns = {c["name"] for c in inspect(conn).get_columns(table.name, schema="public")}
            if not set(table.c.keys()).issubset(columns):
                raise ValueError("Existing M2 schema is incompatible; no DDL permitted.")

        if apply:
            conn.execute(text("SELECT pg_advisory_xact_lock(hashtext(:v))"),
                         {"v": data["version_tag"]})

        current = conn.execute(
            select(instruments).where(instruments.c.code == data["code"],
                                      instruments.c.version_tag == data["version_tag"])
        ).mappings().first()

        promoted_from = None
        if current:
            if current["id"] != iid or current["schema_digest"] != digest:
                raise ValueError(
                    "Conflicting registered version; the immutable source will "
                    "not be overwritten.")
            if current["approval_state"] == DEFINITION_DECLARED_STATE:
                # A candidate row registered earlier by
                # m2v2_register_candidate_20261122. Only the approval_state
                # moves, and only under the receipt.
                if apply:
                    conn.execute(
                        instruments.update()
                        .where(instruments.c.id == iid)
                        .values(approval_state=REGISTERED_STATE))
                    promoted_from = DEFINITION_DECLARED_STATE
            elif current["approval_state"] != REGISTERED_STATE:
                raise ValueError(
                    f"Refusing to touch an instrument whose approval_state is "
                    f"{current['approval_state']!r}.")
            stored = [dict(r) for r in conn.execute(
                select(items).where(items.c.instrument_id == iid)
                .order_by(items.c.sort_order)).mappings()]
            if stored != rows:
                raise ValueError("Stored items do not match the definition.")
        elif apply:
            conn.execute(instruments.insert().values(
                id=iid, code=data["code"], version_tag=data["version_tag"],
                approval_state=REGISTERED_STATE, schema_digest=digest))
            conn.execute(items.insert(), rows)

    counts = {}
    for row in rows:
        counts[row["requiredness"]] = counts.get(row["requiredness"], 0) + 1
    kinds = {}
    for row in rows:
        kinds[row["answer_kind"]] = kinds.get(row["answer_kind"], 0) + 1

    return {
        "database": database, "port": port, "applied": apply,
        "replayed": bool(current) and promoted_from is None,
        "promoted_from": promoted_from,
        "instrument_id": str(iid),
        "code": data["code"], "version": data["version_tag"],
        "approval_state": REGISTERED_STATE,
        "schema_digest": digest, "source_sha256": data["source_sha256"],
        "item_count": len(rows),
        "requiredness_counts": counts,
        "answer_kind_counts": kinds,
        "action_items": kinds.get("ACTION", 0),
        "authorization_receipt": receipt,
        "definition_declared_state": DEFINITION_DECLARED_STATE,
        "authorization_scope": "ISOLATED_PG18_E2E_ONLY",
        "production_adoption": False,
        "scientific_approval": False,
        "customer_fielding_authorized": False,
        "live_schema_changed": False,
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dsn", required=True,
                   help="Cluster-owner DSN for the isolated cluster. Required "
                        "because m2_instrument_versions declares only a SELECT "
                        "RLS policy, so the table owner must write.")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--authorization-receipt")
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()

    from sqlalchemy import create_engine
    from sqlalchemy.engine import make_url

    url = make_url(args.dsn)
    if url.get_backend_name() != "postgresql":
        raise ValueError("Refusing: not a PostgreSQL DSN.")
    if url.host not in {"127.0.0.1", "localhost"}:
        raise ValueError(f"Refusing: host {url.host} is not loopback.")
    if url.database in FORBIDDEN_DATABASES:
        raise ValueError(f"Refusing: {url.database} is a protected database.")
    if url.port in FORBIDDEN_PORTS:
        raise ValueError(f"Refusing: port {url.port} is not disposable.")

    engine = create_engine(args.dsn, connect_args={"connect_timeout": 5})
    try:
        result = register(engine, apply=args.apply,
                          receipt=args.authorization_receipt)
    finally:
        engine.dispose()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
