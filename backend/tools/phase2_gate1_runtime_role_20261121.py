"""Gate 1 — disposable M2 runtime principal + RLS, applied and verified.

Applies:
  * BCB persistence tables (from the versioned metadata, no hand-written DDL);
  * `20261121_90_m2_runtime_role_disposable.sql` (disposable-only role + RLS).

Then verifies the connected principal, grants, RLS enforcement and refusals.
No password is logged. Dss is never touched.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase2_gate1_runtime_role_20261121.py
"""
import importlib
import json
from pathlib import Path

import psycopg2
from sqlalchemy import MetaData, create_engine, inspect, text

TARGET_DB = "project1_workflow_tests"
PORT = 5433
ROLE = "p1_m2_runtime"
ROLE_PW = "m2_runtime_dev_only"   # disposable cluster only; never printed
RECEIPT = "gate1-disposable-runtime-role-20261121"
BACKEND = Path(__file__).resolve().parents[1]
MIGRATION = BACKEND / "migrations/project1_ai/20261121_90_m2_runtime_role_disposable.sql"


def base_url():
    for line in (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("DATABASE_URL="):
            u = line.split("=", 1)[1].strip().replace("postgresql+psycopg2://", "postgresql://")
            return u.rsplit("/", 1)[0].replace(":5432", f":{PORT}")
    raise SystemExit("DATABASE_URL missing")


def url(db=TARGET_DB, user=None, pw=None):
    base = base_url()
    if user:
        scheme, rest = base.split("://", 1)
        host = rest.split("@", 1)[1]
        return f"{scheme}://{user}:{pw}@{host}/{db}"
    return f"{base}/{db}"


def preflight():
    u = url()
    if f":{PORT}/" not in u or TARGET_DB not in u:
        raise SystemExit("REFUSED: not the authorized disposable target")
    if not any(h in u for h in ("@localhost", "@127.0.0.1")):
        raise SystemExit("REFUSED: host is not the local isolated cluster")


def main():
    preflight()
    checks = []

    def check(label, fn):
        try:
            checks.append({"check": label, "result": "PASS", "detail": str(fn())})
        except Exception as exc:
            checks.append({"check": label, "result": "FAIL",
                           "detail": f"{type(exc).__name__}: {str(exc)[:160]}"})
        print("  %-4s %-46s %s" % (checks[-1]["result"], label, str(checks[-1]["detail"])[:66]))

    # 1. BCB persistence tables from the versioned metadata.
    engine = create_engine(url().replace("postgresql://", "postgresql+psycopg2://", 1))
    created = []
    for name in ("sitewise.db.models.business_context_schema",
                 "sitewise.db.models.m2_schema"):
        module = importlib.import_module(name)
        for attr in vars(module).values():
            if isinstance(attr, MetaData):
                attr.create_all(engine)
                created.append(name)
    bcb_tables = [t for t in inspect(engine).get_table_names() if t.startswith("m2_business")]
    print("BCB tables:", bcb_tables or "none", "| metadata modules:", len(set(created)))

    # 2. Apply the disposable role migration with its guards satisfied.
    conn = psycopg2.connect(url())
    conn.autocommit = True
    applied = "already present"
    try:
        with conn.cursor() as cur:
            cur.execute("select 1 from pg_roles where rolname=%s", (ROLE,))
            if not cur.fetchone():
                cur.execute("SET project1.migration_target = %s", (TARGET_DB,))
                cur.execute("SET project1.migration_receipt = %s", (RECEIPT,))
                cur.execute(MIGRATION.read_text(encoding="utf-8"))
                applied = "applied"
            cur.execute(f'ALTER ROLE "{ROLE}" PASSWORD %s', (ROLE_PW,))
    except Exception as exc:
        try:
            with conn.cursor() as c:
                c.execute("ROLLBACK")
        except Exception:
            pass
        raise SystemExit("role migration failed: " + str(exc).splitlines()[0])
    print("role migration:", applied)

    def principal():
        r = conn.cursor()
        r.execute("select rolcanlogin, rolsuper, rolbypassrls, rolinherit, rolcreatedb, rolcreaterole "
                  "from pg_roles where rolname=%s", (ROLE,))
        can, sup, bypass, inherit, cdb, crole = r.fetchone()
        if not can or sup or bypass or inherit or cdb or crole:
            raise AssertionError(f"attributes can={can} super={sup} bypass={bypass} inherit={inherit}")
        return "LOGIN, NOINHERIT, NOSUPERUSER, NOBYPASSRLS, NOCREATEDB, NOCREATEROLE"

    def grants():
        r = conn.cursor()
        r.execute("select count(*) from information_schema.role_table_grants where grantee=%s", (ROLE,))
        n = r.fetchone()[0]
        r.execute("select count(*) from information_schema.role_table_grants where grantee=%s "
                  "and privilege_type='DELETE'", (ROLE,))
        d = r.fetchone()[0]
        if n < 10 or d != 0:
            raise AssertionError(f"grants={n} delete={d}")
        return f"{n} table grants, 0 DELETE"

    def rls():
        r = conn.cursor()
        r.execute("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace "
                  "where n.nspname='public' and c.relname like 'm2_%' and c.relrowsecurity")
        enabled = r.fetchone()[0]
        r.execute("select count(*) from pg_policies where schemaname='public' and policyname='owner_scope'")
        pol = r.fetchone()[0]
        if enabled < 5 or pol < 5:
            raise AssertionError(f"rls_tables={enabled} owner_scope_policies={pol}")
        return f"{enabled} tables with RLS, {pol} owner_scope policies"

    def refuses_without_actor():
        c = psycopg2.connect(url(user=ROLE, pw=ROLE_PW))
        c.autocommit = True
        with c.cursor() as cur:
            cur.execute("select count(*) from public.m2_assessments")
            n = cur.fetchone()[0]
        c.close()
        if n != 0:
            raise AssertionError(f"unbound actor saw {n} rows")
        return "0 rows with no project1.actor_id (fail closed)"

    def scopes_to_actor():
        r = conn.cursor()
        r.execute("select owner_user_id, id from public.m2_assessments limit 1")
        owner, aid = r.fetchone()
        c = psycopg2.connect(url(user=ROLE, pw=ROLE_PW))
        c.autocommit = True
        with c.cursor() as cur:
            cur.execute("select set_config('project1.actor_id', %s, false)", (str(owner),))
            cur.execute("select count(*) from public.m2_assessments where id=%s", (str(aid),))
            own = cur.fetchone()[0]
            cur.execute("select count(*) from public.m2_assessments where id<>%s", (str(aid),))
            other = cur.fetchone()[0]
        c.close()
        if own != 1 or other != 0:
            raise AssertionError(f"own={own} other={other}")
        return "own row visible, other owner's rows invisible"

    def cannot_write_other_owner():
        r = conn.cursor()
        r.execute("select id from public.m2_assessments limit 1")
        aid = r.fetchone()[0]
        c = psycopg2.connect(url(user=ROLE, pw=ROLE_PW))
        c.autocommit = True
        try:
            with c.cursor() as cur:
                cur.execute("select set_config('project1.actor_id', %s, false)", (str(uuid4()),))
                cur.execute("update public.m2_assessments set revision=revision where id=%s", (str(aid),))
                if cur.rowcount != 0:
                    raise AssertionError(f"updated {cur.rowcount} row(s) of another owner")
            return "WITH CHECK refused the write (0 rows)"
        finally:
            c.close()

    print()
    check("1. principal attributes", principal)
    check("2. grants (no DELETE)", grants)
    check("3. RLS enabled + policies", rls)
    check("4. unbound actor sees nothing", refuses_without_actor)
    check("5. actor scoping", scopes_to_actor)
    check("6. cross-owner write refused", cannot_write_other_owner)

    passed = sum(1 for c in checks if c["result"] == "PASS")
    evidence = {"gate": 1, "target": f"{TARGET_DB}@{PORT}", "role": ROLE,
                "role_migration": MIGRATION.name, "migration_state": applied,
                "bcb_tables": bcb_tables, "checks": checks,
                "passed": passed, "total": len(checks),
                "verdict": "PASS" if passed == len(checks) else "FAIL"}
    out = BACKEND.parent / "deliverables/phase2/BDJ_GATE1_RUNTIME_ROLE_20261121.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\n  %d/%d checks passed" % (passed, len(checks)))
    print("  evidence:", out)
    print("  VERDICT:", evidence["verdict"])
    return 0 if evidence["verdict"] == "PASS" else 1


def uuid4():
    import uuid
    return uuid.uuid4()


if __name__ == "__main__":
    raise SystemExit(main())
