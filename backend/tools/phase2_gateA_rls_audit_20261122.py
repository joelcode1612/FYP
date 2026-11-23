"""Gate A — read-only security audit of BDJ proposal/decision storage.

Reads only. No DDL, no grants, no row writes. The target is derived from the
configured DATABASE_URL and re-pointed to the disposable clone; the server is
asked for its own database name and port before any catalog query runs.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase2_gateA_rls_audit_20261122.py
"""
import json
import os
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
TARGET_DB = "project1_workflow_tests"
PORT = 5433

PROPOSAL = "public.m2_bdj_objective_proposals"
DECISION = "public.m2_bdj_objective_decisions"
PROBE_TABLES = [
    PROPOSAL,
    DECISION,
    "public.m2_business_contexts",
    "public.m2_business_context_builds",
    "public.m2_assessments",
    "project1_ai.runs",
    "project1_ai.attempts",
    "project1_ai.attempt_receipts",
]
ROLES = ["p1ai_runtime", "p1ai_engine", "p1_m2_runtime"]


def install_process_environment():
    from sqlalchemy.engine import make_url

    lines = (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines()
    base = next((line.split("=", 1)[1].strip() for line in lines
                 if line.startswith("DATABASE_URL=")), None)
    if not base:
        raise RuntimeError("DATABASE_URL_MISSING")
    base_url = make_url(base)
    if (base_url.get_backend_name() != "postgresql"
            or base_url.host not in {"localhost", "127.0.0.1"}):
        raise RuntimeError("DISPOSABLE_SOURCE_HOST_REFUSED")
    target = base_url.set(port=PORT, database=TARGET_DB)
    if (target.host not in {"localhost", "127.0.0.1"} or target.port != PORT
            or target.database != TARGET_DB
            or target.database in {"Dss", "Final_Location_Analysis"}):
        raise RuntimeError("DISPOSABLE_TARGET_REFUSED")
    return target.render_as_string(hide_password=False), f"{target.host}:{target.port}/{target.database}"


APP_URL, TARGET_LABEL = install_process_environment()
os.environ["DATABASE_URL"] = APP_URL
os.environ["M2_EXPECTED_DATABASE"] = TARGET_DB


def main():
    import psycopg2
    from psycopg2.extras import RealDictCursor

    findings, checks = [], []

    def check(label, fn):
        try:
            detail = fn()
            checks.append({"check": label, "result": "PASS", "detail": detail})
        except Exception as exc:  # audit findings are data, not failures
            checks.append({"check": label, "result": "FAIL",
                           "detail": f"{type(exc).__name__}: {str(exc)[:180]}"})
        print("  %-4s %-52s %s" % (checks[-1]["result"], label,
                                   str(checks[-1]["detail"])[:70]))

    conn = psycopg2.connect(APP_URL.replace("postgresql+psycopg2://", "postgresql://", 1))
    conn.autocommit = True
    cur = conn.cursor(cursor_factory=RealDictCursor)

    cur.execute("SELECT current_database() AS db, inet_server_port() AS port, "
                "current_user AS cu, session_user AS su")
    identity = dict(cur.fetchone())
    if identity["db"] != TARGET_DB or identity["port"] != PORT:
        conn.close()
        raise SystemExit("REFUSED: server identity is not the disposable target")

    print("=" * 78)
    print("GATE A — read-only RLS/privilege audit |", TARGET_LABEL)
    print("=" * 78)

    def table_facts():
        cur.execute("""
            SELECT n.nspname AS schema, c.relname AS table, pg_get_userbyid(c.relowner) AS owner,
                   c.relrowsecurity AS rls, c.relforcerowsecurity AS force_rls,
                   c.reltuples::bigint AS approx_rows
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE (n.nspname, c.relname) IN (
                ('public','m2_bdj_objective_proposals'),
                ('public','m2_bdj_objective_decisions'))
            ORDER BY c.relname""")
        rows = [dict(r) for r in cur.fetchall()]
        if len(rows) != 2:
            raise AssertionError(f"expected 2 tables, found {len(rows)}")
        for row in rows:
            row["approx_rows"] = int(row["approx_rows"])
        findings.append({"kind": "table_facts", "rows": rows})
        return "; ".join(f"{r['table']}: owner={r['owner']} rls={r['rls']} force={r['force_rls']}"
                         for r in rows)

    def policies():
        cur.execute("""
            SELECT schemaname, tablename, policyname, cmd, roles::text AS roles,
                   qual, with_check
            FROM pg_policies
            WHERE schemaname IN ('public','project1_ai')
              AND (policyname = 'owner_scope'
                   OR tablename IN ('m2_bdj_objective_proposals',
                                    'm2_bdj_objective_decisions'))
            ORDER BY schemaname, tablename, policyname""")
        rows = [dict(r) for r in cur.fetchall()]
        findings.append({"kind": "policies", "rows": rows})
        proposal = [r for r in rows if r["tablename"] == "m2_bdj_objective_proposals"]
        return f"{len(rows)} matching policies; proposal table policies={len(proposal)}"

    def role_facts():
        cur.execute("""
            SELECT rolname, rolcanlogin, rolsuper, rolbypassrls, rolinherit,
                   rolcreatedb, rolcreaterole
            FROM pg_roles WHERE rolname = ANY(%s) ORDER BY rolname""", (ROLES,))
        rows = [dict(r) for r in cur.fetchall()]
        cur.execute("""
            SELECT r.rolname AS role, m.rolname AS member
            FROM pg_auth_members am
            JOIN pg_roles r ON r.oid = am.roleid
            JOIN pg_roles m ON m.oid = am.member
            WHERE r.rolname = ANY(%s) OR m.rolname = ANY(%s)""", (ROLES, ROLES))
        memberships = [dict(r) for r in cur.fetchall()]
        findings.append({"kind": "roles", "rows": rows, "memberships": memberships})
        missing = sorted(set(ROLES) - {r["rolname"] for r in rows})
        if missing:
            raise AssertionError(f"missing roles: {missing}")
        return ", ".join(f"{r['rolname']}(login={r['rolcanlogin']},super={r['rolsuper']},"
                         f"bypass={r['rolbypassrls']})" for r in rows)

    def privilege_matrix():
        matrix = {}
        for role in ("p1_m2_runtime", "p1ai_runtime"):
            matrix[role] = {}
            for table in PROBE_TABLES:
                cur.execute("""
                    SELECT has_table_privilege(%s, %s, 'SELECT') AS s,
                           has_table_privilege(%s, %s, 'INSERT') AS i,
                           has_table_privilege(%s, %s, 'UPDATE') AS u,
                           has_table_privilege(%s, %s, 'DELETE') AS d,
                           has_table_privilege(%s, %s, 'TRUNCATE') AS t""",
                            (role, table, role, table, role, table, role, table, role, table))
                row = dict(cur.fetchone())
                matrix[role][table] = {k: bool(v) for k, v in row.items()}
        findings.append({"kind": "privileges", "matrix": matrix})
        proposal = matrix["p1_m2_runtime"][PROPOSAL]
        return ("p1_m2_runtime on proposals: " + ",".join(
            k for k, v in proposal.items() if v) or "none")

    def schema_usage():
        usage = {}
        for role in ("p1_m2_runtime", "p1ai_runtime"):
            usage[role] = {}
            for schema in ("public", "project1_ai"):
                cur.execute("SELECT has_schema_privilege(%s, %s, 'USAGE')", (role, schema))
                usage[role][schema] = bool(cur.fetchone()["has_schema_privilege"])
        findings.append({"kind": "schema_usage", "usage": usage})
        return json.dumps(usage)

    def constraints():
        cur.execute("""
            SELECT conname, contype, pg_get_constraintdef(oid) AS definition
            FROM pg_constraint
            WHERE conrelid = %s::regclass ORDER BY contype, conname""", (PROPOSAL,))
        proposal = [dict(r) for r in cur.fetchall()]
        cur.execute("""
            SELECT conname, contype, pg_get_constraintdef(oid) AS definition
            FROM pg_constraint
            WHERE conrelid = %s::regclass ORDER BY contype, conname""", (DECISION,))
        decision = [dict(r) for r in cur.fetchall()]
        findings.append({"kind": "constraints", "proposal": proposal, "decision": decision})
        fks = [r["definition"] for r in decision if r["contype"] == "f"]
        return f"proposal constraints={len(proposal)}, decision={len(decision)}, fk={len(fks)}"

    def row_counts():
        counts = {}
        for table in (PROPOSAL, DECISION):
            cur.execute(f"SELECT count(*) AS n FROM {table}")
            counts[table] = int(cur.fetchone()["n"])
        findings.append({"kind": "row_counts", "counts": counts})
        return json.dumps(counts)

    def actor_binding_surface():
        cur.execute("SELECT to_regnamespace('project1_identity') AS ns")
        namespace = cur.fetchone()["ns"]
        cur.execute("""
            SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'project1_identity' ORDER BY p.proname""")
        functions = [r["proname"] for r in cur.fetchall()]
        cur.execute("SELECT current_setting('project1.actor_id', true) AS actor")
        actor_setting = cur.fetchone()["actor"]
        findings.append({"kind": "actor_binding", "namespace": namespace,
                         "functions": functions, "actor_setting": actor_setting})
        return f"namespace={namespace} functions={functions}"

    def ledger_tables():
        cur.execute("""
            SELECT c.relname, pg_get_userbyid(c.relowner) AS owner, c.relrowsecurity
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'project1_ai'
              AND c.relname IN ('runs','attempts','attempt_receipts')
            ORDER BY c.relname""")
        rows = [dict(r) for r in cur.fetchall()]
        findings.append({"kind": "ledger_tables", "rows": rows})
        return "; ".join(f"{r['relname']}(owner={r['owner']},rls={r['rowsecurity']})" for r in rows)

    def owner_scope_template():
        """The existing owner policy text, so a corrective migration can mirror it."""
        cur.execute("""
            SELECT tablename, qual, with_check FROM pg_policies
            WHERE schemaname = 'public' AND policyname = 'owner_scope'
            ORDER BY tablename LIMIT 3""")
        rows = [dict(r) for r in cur.fetchall()]
        findings.append({"kind": "owner_scope_template", "rows": rows})
        return f"{len(rows)} owner_scope examples captured"

    check("1. proposal/decision table facts", table_facts)
    check("2. policies (owner_scope + target tables)", policies)
    check("3. runtime roles and memberships", role_facts)
    check("4. privilege matrix (S/I/U/D/T)", privilege_matrix)
    check("5. schema USAGE", schema_usage)
    check("6. constraints and foreign keys", constraints)
    check("7. preserved historical rows", row_counts)
    check("8. actor-binding surface", actor_binding_surface)
    check("9. project1_ai ledger tables", ledger_tables)
    check("10. owner_scope policy template", owner_scope_template)

    cur.close()
    conn.close()

    out = BACKEND.parent / "deliverables/phase2/BDJ_GATEA_RLS_AUDIT_20261122.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"gate": "A", "mode": "READ_ONLY_AUDIT",
                               "target": TARGET_LABEL, "identity": identity,
                               "checks": checks, "findings": findings},
                              indent=2, ensure_ascii=False), encoding="utf-8")
    print("\n  evidence:", out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
