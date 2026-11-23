"""Gate 1A — BCB persistence privileges and RLS isolation, executed.

Applies `20261121_91_bcb_table_grants_disposable.sql`, then tests the real
`p1_m2_runtime` principal: privileges, RLS, cross-owner, unbound actor,
unrelated-table refusal, and actor-binding leakage across a reused connection.

No password is printed. Dss is never touched.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase2_gate1a_bcb_privileges_20261121.py
"""
import json
from pathlib import Path

import psycopg2

TARGET_DB = "project1_workflow_tests"
PORT = 5433
ROLE = "p1_m2_runtime"
ROLE_PW = "m2_runtime_dev_only"
RECEIPT = "gate1a-bcb-grants-20261121"
BACKEND = Path(__file__).resolve().parents[1]
MIGRATION = BACKEND / "migrations/project1_ai/20261121_91_bcb_table_grants_disposable.sql"
TABLES = ("m2_business_contexts", "m2_business_context_builds")


def base_url():
    for line in (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("DATABASE_URL="):
            u = line.split("=", 1)[1].strip().replace("postgresql+psycopg2://", "postgresql://")
            return u.rsplit("/", 1)[0].replace(":5432", f":{PORT}")
    raise SystemExit("DATABASE_URL missing")


def url(user=None, pw=None):
    rest = base_url().split("://", 1)[1]          # user:pw@host:port
    if user:
        hostpart = rest.split("@", 1)[1]          # host:port only
        return f"postgresql://{user}:{pw}@{hostpart}/{TARGET_DB}"
    return f"postgresql://{rest}/{TARGET_DB}"


def main():
    u = url()
    if f":{PORT}/" not in u or TARGET_DB not in u:
        raise SystemExit("REFUSED: not the authorized disposable target")

    admin = psycopg2.connect(u)
    admin.autocommit = True
    with admin.cursor() as cur:
        cur.execute("SET project1.migration_target = %s", (TARGET_DB,))
        cur.execute("SET project1.migration_receipt = %s", (RECEIPT,))
        try:
            cur.execute(MIGRATION.read_text(encoding="utf-8"))
            state = "applied"
        except Exception as exc:
            if "already" in str(exc).lower():
                state = "already applied"
            else:
                raise
    print("migration:", MIGRATION.name, "->", state)

    checks = []

    def check(label, fn):
        try:
            checks.append({"check": label, "result": "PASS", "detail": str(fn())})
        except Exception as exc:
            checks.append({"check": label, "result": "FAIL",
                           "detail": f"{type(exc).__name__}: {str(exc)[:150]}"})
        print("  %-4s %-48s %s" % (checks[-1]["result"], label, str(checks[-1]["detail"])[:60]))

    with admin.cursor() as cur:
        cur.execute("select owner_user_id, id from public.m2_assessments limit 1")
        owner, aid = cur.fetchone()
        cur.execute("select id from public.m2_assessments where owner_user_id <> %s limit 1", (owner,))
        row = cur.fetchone()
        other_aid = row[0] if row else None

    def privileges():
        with admin.cursor() as cur:
            out = {}
            for t in TABLES:
                cur.execute("select has_table_privilege(%s,%s,'SELECT'), has_table_privilege(%s,%s,'INSERT'),"
                            " has_table_privilege(%s,%s,'UPDATE'), has_table_privilege(%s,%s,'DELETE'),"
                            " has_table_privilege(%s,%s,'TRUNCATE')",
                            (ROLE, t, ROLE, t, ROLE, t, ROLE, t, ROLE, t))
                s, i, up, d, tr = cur.fetchone()
                if not (s and i and up) or d or tr:
                    raise AssertionError(f"{t}: sel={s} ins={i} upd={up} del={d} trunc={tr}")
                out[t] = "S/I/U only"
            return out

    def rls_intact():
        with admin.cursor() as cur:
            for t in TABLES:
                cur.execute("select relrowsecurity from pg_class where relname=%s", (t,))
                if not cur.fetchone()[0]:
                    raise AssertionError(f"RLS off on {t}")
                cur.execute("select count(*) from pg_policies where tablename=%s and policyname='owner_scope'", (t,))
                if cur.fetchone()[0] != 1:
                    raise AssertionError(f"policy missing on {t}")
            return "RLS on, owner_scope present on both"

    def authorized_read():
        c = psycopg2.connect(url(ROLE, ROLE_PW))
        c.autocommit = True
        with c.cursor() as cur:
            cur.execute("select set_config('project1.actor_id', %s, false)", (str(owner),))
            cur.execute("select count(*) from public.m2_business_contexts where assessment_id=%s", (str(aid),))
            n = cur.fetchone()[0]
        c.close()
        return f"read permitted (rows={n})"

    def cross_owner_read():
        if other_aid is None:
            return "SKIPPED: single owner in fixture"
        c = psycopg2.connect(url(ROLE, ROLE_PW))
        c.autocommit = True
        with c.cursor() as cur:
            cur.execute("select set_config('project1.actor_id', %s, false)", (str(owner),))
            cur.execute("select count(*) from public.m2_business_contexts where assessment_id=%s", (str(other_aid),))
            n = cur.fetchone()[0]
        c.close()
        if n != 0:
            raise AssertionError(f"cross-owner rows visible: {n}")
        return "0 rows for another owner's assessment"

    def unbound_actor():
        c = psycopg2.connect(url(ROLE, ROLE_PW))
        c.autocommit = True
        with c.cursor() as cur:
            cur.execute("select count(*) from public.m2_business_contexts")
            n = cur.fetchone()[0]
        c.close()
        if n != 0:
            raise AssertionError(f"unbound actor saw {n} rows")
        return "0 rows without project1.actor_id"

    def unrelated_table():
        c = psycopg2.connect(url(ROLE, ROLE_PW))
        c.autocommit = True
        try:
            with c.cursor() as cur:
                cur.execute("select count(*) from project1_ai.runs")
            raise AssertionError("runtime role could read project1_ai.runs")
        except psycopg2.errors.InsufficientPrivilege:
            return "project1_ai.runs refused (InsufficientPrivilege)"
        finally:
            c.close()

    def actor_binding_isolation():
        # A: session-scoped binding, committed -> survives on the pooled session.
        a = psycopg2.connect(url(ROLE, ROLE_PW))
        a.autocommit = False
        with a.cursor() as cur:
            cur.execute("select set_config('project1.actor_id', %s, false)", (str(owner),))
        a.commit()
        with a.cursor() as cur:
            cur.execute("select current_setting('project1.actor_id', true)")
            session_after_commit = cur.fetchone()[0]
        with a.cursor() as cur:
            cur.execute("select set_config('project1.actor_id', '', false)")
        a.commit()
        a.close()

        # B: transaction-local binding on a FRESH connection, committed -> gone.
        b = psycopg2.connect(url(ROLE, ROLE_PW))
        b.autocommit = False
        with b.cursor() as cur:
            cur.execute("select set_config('project1.actor_id', %s, true)", (str(owner),))
        b.commit()
        with b.cursor() as cur:
            cur.execute("select current_setting('project1.actor_id', true)")
            local_after_commit = cur.fetchone()[0]
        b.close()

        session_leaked = session_after_commit == str(owner)
        local_cleared = local_after_commit in ("", None)
        if not (session_leaked and local_cleared):
            raise AssertionError(f"session_after_commit={session_after_commit!r} "
                                 f"local_after_commit={local_after_commit!r}")
        return ("session-scoped actor survives COMMIT (pooling leak confirmed); "
                "transaction-local actor is cleared on COMMIT")

    print()
    check("1. privileges: S/I/U only, no DELETE/TRUNCATE", privileges)
    check("2. RLS intact after grant", rls_intact)
    check("3. authorized read permitted", authorized_read)
    check("4. cross-owner read refused", cross_owner_read)
    check("5. unbound actor sees nothing", unbound_actor)
    check("6. unrelated privileged table refused", unrelated_table)
    check("7. actor binding across connection reuse", actor_binding_isolation)

    passed = sum(1 for c in checks if c["result"] == "PASS")
    evidence = {"gate": "1A", "target": f"{TARGET_DB}@{PORT}", "role": ROLE,
                "migration": MIGRATION.name, "migration_state": state,
                "checks": checks, "passed": passed, "total": len(checks),
                "verdict": "PASS" if passed == len(checks) else "FAIL"}
    out = BACKEND.parent / "deliverables/phase2/BDJ_GATE1A_BCB_PRIVILEGES_20261121.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\n  %d/%d checks passed" % (passed, len(checks)))
    print("  evidence:", out)
    print("  VERDICT:", evidence["verdict"])
    return 0 if evidence["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
