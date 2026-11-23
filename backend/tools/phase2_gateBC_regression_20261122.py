"""Gate B/C section 4 — regression checks around the objective-proposal work.

Two sub-commands, both read-only against the authorised disposable cluster
(``project1_workflow_tests@127.0.0.1:5433``):

``routes``
    Dump the application's complete HTTP surface (method + path + the request
    and response schema names) so two checkouts can be diffed. This is the
    evidence that adding objective proposals did not alter an existing route:
    the diff must contain additions only.

``bcb-read``
    Prove that reading a persisted business context does not create a build
    record and does not mutate build state. The whole
    ``public.m2_business_context_builds`` table is fingerprinted before and
    after a series of reads (owner read, owner status, foreign read, unknown
    id) and the snapshots must be byte-identical.

Nothing here writes to a protected database, calls a cloud model, or edits a
.env file.
"""
from __future__ import annotations

import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
TARGET_DB = "project1_workflow_tests"
PORT = 5433
HOST = "127.0.0.1"
M2_PW = "m2_runtime_dev_only"
ENGINE_PW = "p1ai_engine_dev_only"
M2_PREFIX = "/api/v1/m2"

sys.path.insert(0, str(BACKEND / "src"))


def sqlalchemy_dsn(url, role=None, password=None):
    if role:
        url = url.set(username=role, password=password)
    return url.render_as_string(hide_password=False)


def psycopg_dsn(url, role=None, password=None):
    return sqlalchemy_dsn(url, role, password).replace(
        "postgresql+psycopg2://", "postgresql://", 1)


def target_url():
    from sqlalchemy.engine import make_url

    lines = (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines()
    raw = next(l.split("=", 1)[1].strip() for l in lines if l.startswith("DATABASE_URL="))
    configured = make_url(raw)
    if configured.host not in {"localhost", HOST}:
        raise SystemExit("REFUSED: configured host is not local")
    target = configured.set(host=HOST, port=PORT, database=TARGET_DB)
    if target.database != TARGET_DB or target.port != PORT:
        raise SystemExit("REFUSED: not the authorised disposable target")
    return target


def set_environment(url):
    import os

    os.environ.update({
        "DATABASE_URL": sqlalchemy_dsn(url, "p1_m2_runtime", M2_PW),
        "M2_DATABASE_URL": sqlalchemy_dsn(url, "p1_m2_runtime", M2_PW),
        "M2_EXPECTED_DATABASE": TARGET_DB,
        "PROJECT1_RUNTIME_DATABASE_URL": sqlalchemy_dsn(url, "p1ai_engine", ENGINE_PW),
        "PROJECT1_ISOLATED_DATABASE_NAME": TARGET_DB,
        "PROJECT1_ISOLATED_DATABASE_PORT": str(PORT),
        "PROJECT1_WORKFLOW_ENABLED": "true",
        "M2_BCB_PERSISTENCE_ENABLED": "true",
        # The /m2 surface (including business-context readback) is opt-in and is
        # absent from the persistent .env, so it is enabled for this process only.
        "M2_UPSTREAM_ENABLED": "true",
        "PROJECT1_BDJ_CONTRACT": "objective",
        "PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS": "1",
        "M2_PROTECTED_IDENTITY_ENABLED": "false",
        "PROJECT1_SYNTHETIC_BDJ_TRIAL_ENABLED": "false",
        "TOKENHARBOR_ENABLED": "false",
    })


# ---------------------------------------------------------------------------
# routes
# ---------------------------------------------------------------------------
def route_surface(out_path):
    """Method+path+schema surface, independent of any database connection."""
    from sitewise.main import app

    schema = app.openapi()
    surface = {}
    for path, operations in schema.get("paths", {}).items():
        for method, operation in operations.items():
            if method not in {"get", "post", "put", "patch", "delete"}:
                continue
            body = operation.get("requestBody") or {}
            request = None
            for media in body.get("content", {}).values():
                ref = media.get("schema", {}).get("$ref")
                if ref:
                    request = ref.rsplit("/", 1)[-1]
            responses = {}
            for status, response in operation.get("responses", {}).items():
                ref = (response.get("content", {}).get("application/json", {})
                       .get("schema", {}).get("$ref"))
                responses[status] = ref.rsplit("/", 1)[-1] if ref else None
            surface[f"{method.upper()} {path}"] = {
                "operation_id": operation.get("operationId"),
                "request_schema": request,
                "response_schemas": responses,
                "tags": operation.get("tags"),
            }
    payload = {"total_paths": len(schema.get("paths", {})),
               "total_operations": len(surface), "operations": surface}
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    print(f"{payload['total_paths']} paths / {payload['total_operations']} operations -> {out}")
    return payload


# ---------------------------------------------------------------------------
# bcb-read
# ---------------------------------------------------------------------------
BUILDS = "public.m2_business_context_builds"


def builds_snapshot(cur):
    """Every build row, every column, plus a whole-table digest."""
    cur.execute(f"SELECT * FROM {BUILDS} ORDER BY confirmation_id")
    rows = [{k: str(v) for k, v in dict(r).items()} for r in cur.fetchall()]
    blob = json.dumps(rows, sort_keys=True, separators=(",", ":"))
    cur.execute(f"SELECT count(*) c, coalesce(sum(attempt_count),0) a,"
                f" coalesce(max(updated_at)::text,'') u FROM {BUILDS}")
    agg = dict(cur.fetchone())
    return {"rows": rows, "row_count": len(rows),
            "sum_attempt_count": int(agg["a"]), "max_updated_at": str(agg["u"]),
            "digest": hashlib.sha256(blob.encode()).hexdigest()}


def builds_columns(cur):
    cur.execute("""
        SELECT column_name, data_type FROM information_schema.columns
        WHERE table_schema='public' AND table_name='m2_business_context_builds'
        ORDER BY ordinal_position""")
    return [dict(r) for r in cur.fetchall()]


def bcb_read(url, evidence_path):
    import psycopg2
    from psycopg2.extras import RealDictCursor

    from tools import phase2_gateBC_http_e2e_20261122 as harness

    steps, verdicts = [], {}

    def step(name, result, **detail):
        entry = {"step": name, "result": result}
        entry.update({k: v for k, v in detail.items() if v is not None})
        steps.append(entry)
        print(f"  {result:<6} {name[:56]:<56} {str(detail.get('note',''))[:56]}")
        return entry

    conn = psycopg2.connect(psycopg_dsn(url))
    conn.autocommit = True
    cur = conn.cursor(cursor_factory=RealDictCursor)

    cur.execute("SELECT current_database() db, inet_server_port() port, current_user cu")
    ident = dict(cur.fetchone())
    if ident["db"] != TARGET_DB or ident["port"] != PORT:
        raise SystemExit(f"REFUSED: server identity mismatch {ident}")
    step("R0 server identity", "PASS", note=f"{ident['db']}@{HOST}:{ident['port']} as {ident['cu']}")

    columns = builds_columns(cur)
    step("R1 build table shape", "PASS",
         note=", ".join(c["column_name"] for c in columns))

    scenarios = {}
    for name in ("primary", "fresh"):
        spec = harness.configure(name, cur)
        scenarios[name] = {
            "assessment": spec["assessment"], "owner": spec["owner"],
            "confirmation": spec["confirmation"], "context": spec["context"],
            "packet_hash": harness.EXPECTED_PACKET_HASH,
            # The identity layer refuses an email that belongs to another UUID,
            # so each scenario's owner must present its own address.
            "email": f"gatebc-e2e-{spec['owner'][:8]}@example.invalid",
        }
    step("R2 scenarios bound", "PASS",
         note=", ".join(f"{k}:{v['context'][:8]}" for k, v in scenarios.items()))

    # Identity fixture so the same owner principal resolves as in Gate B/C.
    for name, spec in scenarios.items():
        harness.configure(name, cur)
        harness.provision_fixture(cur)
    step("R3 disposable identity fixture", "PASS",
         note="users rows present for both owners")

    before = builds_snapshot(cur)
    step("R4 builds fingerprint BEFORE", "PASS",
         note=f"rows={before['row_count']} attempts={before['sum_attempt_count']} "
              f"digest={before['digest'][:16]}")

    app, token = harness.build_app()

    from fastapi.testclient import TestClient

    client = TestClient(app, raise_server_exceptions=False)

    def call(spec, path, *, subject=None, email=None):
        """Absolute-path GET; the BCB routes are not under the workflow prefix."""
        headers = {"Authorization": f"Bearer {token(subject or spec['owner'],
                                                    email or spec['email'])}"}
        return client.get(path, headers=headers)

    results = []
    for name, spec in scenarios.items():
        harness.configure(name, cur)
        read = call(spec, f"{M2_PREFIX}/assessments/{spec['assessment']}"
                          f"/business-contexts/{spec['context']}")
        status = call(spec, f"{M2_PREFIX}/assessments/{spec['assessment']}/confirmations/"
                            f"{spec['confirmation']}/business-context-status")
        foreign = call(spec, f"{M2_PREFIX}/assessments/{spec['assessment']}"
                             f"/business-contexts/{spec['context']}",
                       subject="11111111-2222-3333-4444-555555555555",
                       email="gatebc-regression-foreign@example.invalid")
        unknown = call(spec, f"{M2_PREFIX}/assessments/{spec['assessment']}"
                             f"/business-contexts/{'0'*8}-0000-4000-8000-{'0'*12}")
        entry = {"scenario": name, "read_status": read.status_code,
                 "status_status": status.status_code,
                 "foreign_status": foreign.status_code,
                 "unknown_status": unknown.status_code,
                 "read_code": harness.code_of(read),
                 "foreign_code": harness.code_of(foreign),
                 "unknown_code": harness.code_of(unknown)}
        entry["read_replayed"] = (read.json() or {}).get("replayed") if read.status_code == 200 else None
        entry["read_packet_hash"] = (read.json() or {}).get("packet_hash") if read.status_code == 200 else None
        if read.status_code >= 500:
            # The read route has no handler for a response-model failure, so the
            # body is the framework's generic text. Keep it as evidence only.
            entry["read_body"] = read.text[:200]
        results.append(entry)
        step(f"R5 {name} reads", "PASS" if read.status_code == 200 and status.status_code == 200
             else "FAIL",
             note=f"read={read.status_code} status={status.status_code} "
                  f"foreign={foreign.status_code} unknown={unknown.status_code}")
    step("R6 read responses", "PASS" if all(r["read_status"] == 200 for r in results) else "FAIL",
         note=json.dumps(results))

    after = builds_snapshot(cur)
    step("R7 builds fingerprint AFTER", "PASS",
         note=f"rows={after['row_count']} attempts={after['sum_attempt_count']} "
              f"digest={after['digest'][:16]}")

    unchanged = (before["digest"] == after["digest"]
                 and before["row_count"] == after["row_count"]
                 and before["sum_attempt_count"] == after["sum_attempt_count"]
                 and before["max_updated_at"] == after["max_updated_at"])
    step("R8 read did not create or mutate a build", "PASS" if unchanged else "FAIL",
         note="whole-table digest identical across 8 read requests")

    # Source-level corroboration: only construction may initialise a build row.
    source = (BACKEND / "src/sitewise/services/persisted_business_context_service.py").read_text(
        encoding="utf-8")
    construct_calls = source.count("self._select(unit, selection, actor)")
    read_calls = source.count("self._select(unit, selection, actor, initialize_build=False)")
    step("R9 initialisation is construction-only", "PASS"
         if construct_calls == 1 and read_calls == 1 else "FAIL",
         note=f"construct initialises={construct_calls}, read forbids={read_calls}")

    # Each persisted context still has exactly one build row.
    cur.execute(f"SELECT confirmation_id, status, attempt_count, updated_at FROM {BUILDS}"
                f" WHERE confirmation_id = ANY(%s::uuid[]) ORDER BY confirmation_id",
                ([s["confirmation"] for s in scenarios.values()],))
    rows = [{k: str(v) for k, v in dict(r).items()} for r in cur.fetchall()]
    step("R10 one build row per context", "PASS" if len(rows) == len(scenarios) else "FAIL",
         note=json.dumps(rows))

    # Root cause of a failing readback, if any: the response model requires a
    # datetime, and ``_row()`` never populates ``created_at`` while the column is
    # nullable with no default. This is a property of the stored data, so it is
    # measured rather than assumed, and it is independent of build initialisation.
    cur.execute("""
        SELECT column_name, is_nullable, column_default FROM information_schema.columns
        WHERE table_schema='public' AND table_name='m2_business_contexts'
          AND column_name='created_at'""")
    created_at_column = dict(cur.fetchone())
    cur.execute("SELECT context_id, created_at FROM public.m2_business_contexts"
                " WHERE context_id = ANY(%s::uuid[]) ORDER BY context_id",
                ([s["context"] for s in scenarios.values()],))
    created_at_rows = [{k: str(v) for k, v in dict(r).items()} for r in cur.fetchall()]
    null_created = [r for r in created_at_rows if r["created_at"] == "None"]
    step("R11 stored created_at population", "INFO",
         note=f"nullable={created_at_column['is_nullable']} "
              f"default={created_at_column['column_default']} "
              f"null={len(null_created)}/{len(created_at_rows)}")

    readback_ok = all(r["read_status"] == 200 for r in results)
    verdicts["M2_BCB_READ_CREATES_NO_BUILD_ROW"] = "PASS" if unchanged else "FAIL"
    verdicts["M2_BCB_READ_STATE_IMMUTABLE"] = "PASS" if unchanged else "FAIL"
    verdicts["M2_BCB_OWNER_AUTHORIZATION_PRESERVED"] = (
        "PASS" if all(r["foreign_status"] in (403, 404) for r in results) else "FAIL")
    verdicts["M2_BCB_CONSTRUCTION_READBACK_PRESERVED"] = (
        "PASS" if readback_ok and unchanged else "FAIL")
    if not readback_ok:
        # Reported separately so a pre-existing surface defect cannot be
        # mistaken for a Gate B/C regression. Baseline equivalence is recorded
        # in the checkpoint report, not asserted here.
        verdicts["M2_BCB_READBACK_DEFECT_CLASSIFICATION"] = (
            "PRE_EXISTING_CREATED_AT_NULL" if null_created else "UNEXPLAINED")

    evidence = {"generated_at": datetime.now(timezone.utc).isoformat(),
                "target": {"database": TARGET_DB, "host": HOST, "port": PORT,
                           "admin_user": ident["cu"]},
                "build_columns": columns, "scenarios": scenarios,
                "reads": results, "before": before, "after": after,
                "created_at_column": created_at_column,
                "created_at_rows": created_at_rows,
                "verdicts": verdicts, "steps": steps}
    out = Path(evidence_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    print(json.dumps(verdicts, indent=2))
    print(f"evidence -> {out}")
    conn.close()
    return 0 if "FAIL" not in verdicts.values() else 1


def main(argv):
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["routes", "bcb-read"])
    parser.add_argument("--out", default=None)
    args = parser.parse_args(argv)

    if args.mode == "routes":
        # Same disposable environment as the read probe: the workflow and /m2
        # surfaces are opt-in, so comparing them requires the flags on in both
        # checkouts. No connection is opened while building the schema.
        set_environment(target_url())
        out = args.out or str(ROOT / "deliverables/phase2/BDJ_ROUTE_SURFACE_WORKTREE_20261122.json")
        route_surface(out)
        return 0

    url = target_url()
    set_environment(url)
    out = args.out or str(ROOT / "deliverables/phase2/BDJ_GATEBC_REGRESSION_20261122.json")
    return bcb_read(url, out)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
