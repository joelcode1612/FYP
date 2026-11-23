"""Register the M2 V2 *candidate* instrument in existing M2 tables. No DDL.

This is deliberately NOT a copy of ``register_m2_v1.py``: the stored
``approval_state`` is ``PROPOSED_NOT_AUTHORIZED`` and this script refuses to
write ``AUTHORIZED`` at all. Candidate verification runs through the separate,
explicitly isolated synthetic scope in
``sitewise.services.instrument_authorization``, which never rewrites governance
data.

Guards, all of which fail closed:
  * the connected database must be an isolated ``project1_*`` database
  * it must not be ``Dss`` and must not be on port 5432
  * an existing row with a different digest or a different approval state is
    never overwritten
  * default mode is a read-only preflight; ``--apply`` is required to write
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
CANDIDATE_STATE = "PROPOSED_NOT_AUTHORIZED"
EXPECTED_DATABASE = "project1_workflow_tests"
ISOLATED_PORT = 5433
FORBIDDEN_DATABASES = {"Dss", "Final_Location_Analysis", "postgres"}
FORBIDDEN_PORTS = {5432}


def definition():
    data = json.loads((FOLDER / "definition.json").read_text(encoding="utf-8"))
    actual = hashlib.sha256((FOLDER / "source.txt").read_bytes()).hexdigest()
    if actual != data["source_sha256"]:
        raise ValueError("source.txt no longer matches the declared source hash.")
    keys = [q["item_key"] for q in data["items"]]
    if keys != [f"M2V2-{i:02d}" for i in range(1, 20)]:
        raise ValueError(f"unexpected item keys: {keys}")
    if data["adoption"]["approval_state"] != CANDIDATE_STATE:
        raise ValueError("definition is not declared as a candidate instrument.")
    digest = hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=False,
                                       separators=(",", ":")).encode()).hexdigest()
    iid = uuid5(NAMESPACE_URL, data["code"] + ":" + data["version_tag"] + ":" + digest)
    rows = [dict(id=uuid5(iid, q["item_key"]), instrument_id=iid,
                 **{k: v for k, v in q.items() if k != "title"}) for q in data["items"]]
    return data, digest, iid, rows


def register(engine, *, apply=False):
    from sqlalchemy import inspect, select, text
    from sitewise.db.models.m2_schema import instruments, items

    data, digest, iid, rows = definition()
    with engine.begin() as conn:
        if not apply:
            conn.exec_driver_sql("SET TRANSACTION READ ONLY")

        database = conn.scalar(text("SELECT current_database()"))
        port = conn.scalar(text("SELECT inet_server_port()"))
        if database in FORBIDDEN_DATABASES or not database.startswith("project1_"):
            raise ValueError(f"Refusing non-isolated database: {database}")
        if port in FORBIDDEN_PORTS:
            raise ValueError(f"Refusing non-disposable port: {port}")
        if database != EXPECTED_DATABASE:
            raise ValueError(f"Expected {EXPECTED_DATABASE}, connected to {database}")

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

        if current:
            if current["id"] != iid or current["schema_digest"] != digest:
                raise ValueError("Conflicting registered version; immutable source will not be overwritten.")
            if current["approval_state"] != CANDIDATE_STATE:
                raise ValueError(
                    f"Refusing to touch an instrument whose approval_state is "
                    f"{current['approval_state']!r}.")
            stored = [dict(r) for r in conn.execute(
                select(items).where(items.c.instrument_id == iid)
                .order_by(items.c.sort_order)).mappings()]
            if stored != rows:
                raise ValueError("Stored items do not match the candidate definition.")
        elif apply:
            conn.execute(instruments.insert().values(
                id=iid, code=data["code"], version_tag=data["version_tag"],
                approval_state=CANDIDATE_STATE, schema_digest=digest))
            conn.execute(items.insert(), rows)

    return {
        "database": database, "port": port, "applied": apply,
        "replayed": bool(current), "instrument_id": str(iid),
        "version": data["version_tag"], "approval_state": CANDIDATE_STATE,
        "schema_digest": digest, "source_sha256": data["source_sha256"],
        "question_count": 19, "action_count": 0,
        "owner_authorized_for_production": False,
        "synthetic_verification_only": True,
        "live_schema_changed": False,
    }


def privileged_dsn(database: str) -> str:
    """Cluster-owner session on the disposable cluster only.

    Instrument provisioning needs a role that bypasses RLS on
    ``m2_instrument_versions`` (FORCE ROW LEVEL SECURITY is off there, so the
    table owner may write). The configured credential is redirected to the
    isolated port and database, and the redirect refuses anything else.
    """
    from sqlalchemy.engine import make_url

    lines = (ROOT / ".env").read_text(encoding="utf-8", errors="ignore").splitlines()
    raw = next(line.split("=", 1)[1].strip()
               for line in lines if line.startswith("DATABASE_URL="))
    url = make_url(raw)
    if url.get_backend_name() != "postgresql" or url.host not in {"localhost", "127.0.0.1"}:
        raise ValueError("Refusing: configured host is not local.")
    target = url.set(port=ISOLATED_PORT, database=database)
    if target.port != ISOLATED_PORT or target.database in FORBIDDEN_DATABASES:
        raise ValueError("Refusing: not the authorized disposable cluster.")
    # Keep the configured dialect (postgresql+psycopg2); rendering already
    # yields a SQLAlchemy-compatible URL.
    return target.render_as_string(hide_password=False)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--apply", action="store_true")
    p.add_argument("--provisioner", choices=("runtime", "admin"), default="runtime",
                   help="runtime uses the configured app role; admin uses the "
                        "cluster owner, which is required because RLS on "
                        "m2_instrument_versions only declares SELECT.")
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()

    from sqlalchemy import create_engine

    if args.provisioner == "admin":
        raw = privileged_dsn(EXPECTED_DATABASE)
    else:
        from sitewise.core.config import Settings
        from sqlalchemy.engine import make_url

        settings = Settings(_env_file=str(ROOT / ".env"))
        raw = (settings.m2_database_url.get_secret_value()
               or settings.database_url)
        url = make_url(raw)
        if url.database in FORBIDDEN_DATABASES or url.port in FORBIDDEN_PORTS:
            raise ValueError(
                f"Refusing to run against {url.database}@{url.port}. "
                "Point M2_DATABASE_URL at the isolated cluster.")

    engine = create_engine(raw, connect_args={"connect_timeout": 5})
    try:
        result = register(engine, apply=args.apply)
    finally:
        engine.dispose()
    result["provisioner"] = args.provisioner
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
