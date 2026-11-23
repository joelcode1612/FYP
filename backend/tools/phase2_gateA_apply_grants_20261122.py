"""Gate A — apply the disposable RLS/grants correction and prove it with the
real restricted principals.

Steps
-----
1. Verify the server identity (database name + port) before ANY write.
2. Apply migrations/sql/20261122_0300_m2_bdj_objective_rls_grants.sql
   (idempotent, disposable-only guard inside the SQL).
3. Provision the disposable execution login password for p1ai_engine so the
   attempt ledger can run on this cluster. The value is never printed and is
   only applied when the connected database is the disposable clone.
4. Execute owner / cross-owner / unbound-actor / least-privilege tests as
   p1_m2_runtime (proposals+decisions) and p1ai_engine -> p1ai_runtime (ledger).
5. Remove the synthetic probe rows as the admin (the runtime roles have no
   DELETE grant by design).

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase2_gateA_apply_grants_20261122.py
"""
import json
import uuid
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
TARGET_DB = "project1_workflow_tests"
PORT = 5433
MIGRATION = BACKEND / "migrations/sql/20261122_0300_m2_bdj_objective_rls_grants.sql"
PROPOSAL = "public.m2_bdj_objective_proposals"
DECISION = "public.m2_bdj_objective_decisions"

M2_ROLE = "p1_m2_runtime"
M2_PW = "m2_runtime_dev_only"
ENGINE_ROLE = "p1ai_engine"
ENGINE_PW = "p1ai_engine_dev_only"   # disposable cluster only; never printed


def base_dsn():
    from sqlalchemy.engine import make_url

    lines = (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines()
    raw = next((line.split("=", 1)[1].strip() for line in lines
                if line.startswith("DATABASE_URL=")), None)
    if not raw:
        raise SystemExit("DATABASE_URL missing")
    url = make_url(raw)
    if url.get_backend_name() != "postgresql" or url.host not in {"localhost", "127.0.0.1"}:
        raise SystemExit("REFUSED: configured host is not local")
    target = url.set(port=PORT, database=TARGET_DB)
    if (target.port != PORT or target.database != TARGET_DB
            or target.database in {"Dss", "Final_Location_Analysis"}):
        raise SystemExit("REFUSED: not the authorized disposable target")
    return target


def dsn(target, role=None, password=None):
    if role is None:
        return target.render_as_string(hide_password=False).replace(
            "postgresql+psycopg2://", "postgresql://", 1)
    return target.set(username=role, password=password).render_as_string(
        hide_password=False).replace("postgresql+psycopg2://", "postgresql://", 1)


def main():
    import psycopg2
    from psycopg2.extras import RealDictCursor

    target = base_dsn()
    checks, notes = [], []

    def check(label, fn):
        try:
            detail = fn()
            checks.append({"check": label, "result": "PASS", "detail": str(detail)})
        except Exception as exc:
            checks.append({"check": label, "result": "FAIL",
                           "detail": f"{type(exc).__name__}: {str(exc)[:200]}"})
        print("  %-4s %-56s %s" % (checks[-1]["result"], label,
                                   str(checks[-1]["detail"])[:64]))

    admin = psycopg2.connect(dsn(target))
    admin.autocommit = True
    cur = admin.cursor(cursor_factory=RealDictCursor)
    cur.execute("SELECT current_database() AS db, inet_server_port() AS port")
    ident = dict(cur.fetchone())
    if ident["db"] != TARGET_DB or ident["port"] != PORT:
        raise SystemExit("REFUSED: server identity mismatch")

    print("=" * 78)
    print("GATE A — corrective migration + restricted-role proof |",
          f"{ident['db']}@localhost:{ident['port']}")
    print("=" * 78)

    def apply_migration():
        cur.execute(MIGRATION.read_text(encoding="utf-8"))
        return f"applied {MIGRATION.name} (idempotent)"

    def provision_engine_login():
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (ENGINE_ROLE,))
        if cur.fetchone() is None:
            raise AssertionError(f"{ENGINE_ROLE} missing")
        cur.execute(f'ALTER ROLE "{ENGINE_ROLE}" PASSWORD %s', (ENGINE_PW,))
        notes.append({"note": "p1ai_engine disposable login password provisioned "
                              "on project1_workflow_tests only"})
        return "p1ai_engine login password set on the disposable cluster (not printed)"

    def rls_and_policies():
        cur.execute("""
            SELECT c.relname, c.relrowsecurity,
                   (SELECT count(*) FROM pg_policies p
                    WHERE p.schemaname='public' AND p.tablename=c.relname
                      AND p.policyname='owner_scope') AS policies
            FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname='public'
              AND c.relname IN ('m2_bdj_objective_proposals','m2_bdj_objective_decisions')
            ORDER BY c.relname""")
        rows = [dict(r) for r in cur.fetchall()]
        if len(rows) != 2 or not all(r["relrowsecurity"] and r["policies"] == 1 for r in rows):
            raise AssertionError(json.dumps(rows))
        return "; ".join(f"{r['relname']}: rls={r['relrowsecurity']} policies={r['policies']}"
                         for r in rows)

    def grants():
        cur.execute("""
            SELECT has_table_privilege(%s,%s,'SELECT') ps, has_table_privilege(%s,%s,'INSERT') pi,
                   has_table_privilege(%s,%s,'UPDATE') pu, has_table_privilege(%s,%s,'DELETE') pd,
                   has_table_privilege(%s,%s,'SELECT') ds, has_table_privilege(%s,%s,'INSERT') di,
                   has_table_privilege(%s,%s,'UPDATE') du, has_table_privilege(%s,%s,'DELETE') dd""",
                    (M2_ROLE, PROPOSAL, M2_ROLE, PROPOSAL, M2_ROLE, PROPOSAL, M2_ROLE, PROPOSAL,
                     M2_ROLE, DECISION, M2_ROLE, DECISION, M2_ROLE, DECISION, M2_ROLE, DECISION))
        g = dict(cur.fetchone())
        expected = dict(ps=True, pi=True, pu=True, pd=False, ds=True, di=True, du=False, dd=False)
        if g != expected:
            raise AssertionError(json.dumps(g))
        return ("proposals S/I/U only; decisions S/I only; no DELETE/UPDATE on decisions")

    check("1. corrective migration applied", apply_migration)
    check("2. disposable engine login provisioned", provision_engine_login)
    check("3. RLS enabled with single owner_scope policy", rls_and_policies)
    check("4. least-privilege grants", grants)

    # ---- restricted-role proof -------------------------------------------
    cur.execute("SELECT id, owner_user_id FROM public.m2_assessments ORDER BY created_at LIMIT 1")
    row = cur.fetchone()
    if row is None:
        raise SystemExit("NO_ASSESSMENT_FIXTURE")
    assessment_id, owner = row["id"], row["owner_user_id"]
    cur.execute("SELECT id FROM public.m2_assessments WHERE owner_user_id <> %s LIMIT 1", (owner,))
    other = cur.fetchone()
    other_owner = other["id"] if other else None
    if other_owner is None:
        cur.execute("SELECT id FROM public.auth_users WHERE id <> %s LIMIT 1", (owner,))
        r = cur.fetchone()
        other_owner = r["id"] if r else uuid.uuid4()

    probe_ids = []

    def m2_conn(actor):
        conn = psycopg2.connect(dsn(target, M2_ROLE, M2_PW))
        conn.autocommit = False
        with conn.cursor() as c:
            if actor is not None:
                c.execute("SELECT set_config('project1.actor_id', %s, true)", (str(actor),))
        return conn

    def principal_is_restricted():
        conn = m2_conn(owner)
        with conn.cursor() as c:
            c.execute("SELECT current_user, (SELECT rolsuper FROM pg_roles WHERE rolname=current_user),"
                      " (SELECT rolbypassrls FROM pg_roles WHERE rolname=current_user)")
            user, sup, bypass = c.fetchone()
        conn.rollback(); conn.close()
        if user != M2_ROLE or sup or bypass:
            raise AssertionError(f"user={user} super={sup} bypass={bypass}")
        return f"current_user={user}, NOSUPERUSER, NOBYPASSRLS"

    def owner_can_insert_and_read():
        pid = uuid.uuid4(); probe_ids.append(pid)
        conn = m2_conn(owner)
        with conn.cursor() as c:
            c.execute("""
                INSERT INTO public.m2_bdj_objective_proposals (
                    proposal_id, evaluation_id, assessment_id, confirmation_id,
                    confirmation_revision, source_fingerprint, context_id,
                    context_packet_hash, recommendation_status, problem_type, problem,
                    research_objective, reason, source_refs, contract_version,
                    prompt_version, execution_mode, validation_status, owner_user_id)
                VALUES (%s,%s,%s,%s,11,%s,%s,%s,'SUGGESTED','EXPLORATORY_RESEARCH_NEED',NULL,
                        'To investigate gate A probe behaviour.', 'Gate A RLS probe.',
                        '[]'::jsonb, 'bdj-objective-proposal/1', 'BDJ-OBJECTIVE-3-CAND',
                        'SIMULATED','VALID',%s)""",
                (str(pid), str(uuid.uuid4()), str(assessment_id), str(uuid.uuid4()),
                 "a" * 64, str(uuid.uuid4()), "b" * 64, str(owner)))
            c.execute("SELECT count(*) FROM public.m2_bdj_objective_proposals WHERE proposal_id=%s",
                      (str(pid),))
            seen = c.fetchone()[0]
        conn.commit(); conn.close()
        if seen != 1:
            raise AssertionError(f"owner could not read back own row ({seen})")
        return "insert permitted, own row visible"

    def owner_can_decide():
        pid = probe_ids[-1]
        conn = m2_conn(owner)
        with conn.cursor() as c:
            c.execute("""
                INSERT INTO public.m2_bdj_objective_decisions (
                    decision_id, proposal_id, decision, decided_by, source_fingerprint,
                    confirmation_id, context_packet_hash)
                SELECT %s, proposal_id, 'REJECTED', %s, source_fingerprint,
                       confirmation_id, context_packet_hash
                FROM public.m2_bdj_objective_proposals WHERE proposal_id=%s""",
                (str(uuid.uuid4()), str(owner), str(pid)))
            inserted = c.rowcount
            c.execute("SELECT count(*) FROM public.m2_bdj_objective_decisions WHERE proposal_id=%s",
                      (str(pid),))
            seen = c.fetchone()[0]
        conn.commit(); conn.close()
        if inserted != 1 or seen != 1:
            raise AssertionError(f"inserted={inserted} visible={seen}")
        return "decision inserted and visible to owner"

    def other_owner_cannot_read():
        conn = m2_conn(other_owner)
        with conn.cursor() as c:
            c.execute("SELECT count(*) FROM public.m2_bdj_objective_proposals")
            proposals = c.fetchone()[0]
            c.execute("SELECT count(*) FROM public.m2_bdj_objective_decisions")
            decisions = c.fetchone()[0]
        conn.rollback(); conn.close()
        if proposals or decisions:
            raise AssertionError(f"other owner saw proposals={proposals} decisions={decisions}")
        return "0 proposals and 0 decisions visible to a different owner"

    def other_owner_cannot_modify():
        pid = probe_ids[-1]
        conn = m2_conn(other_owner)
        with conn.cursor() as c:
            c.execute("UPDATE public.m2_bdj_objective_proposals SET review_state='APPROVED' "
                      "WHERE proposal_id=%s", (str(pid),))
            updated = c.rowcount
        conn.commit(); conn.close()
        if updated != 0:
            raise AssertionError(f"other owner updated {updated} row(s)")
        return "cross-owner UPDATE affected 0 rows"

    def unbound_actor_sees_nothing():
        conn = m2_conn(None)
        with conn.cursor() as c:
            c.execute("SELECT project1_actor() IS NULL")
            is_null = c.fetchone()[0]
            c.execute("SELECT count(*) FROM public.m2_bdj_objective_proposals")
            proposals = c.fetchone()[0]
        conn.rollback(); conn.close()
        if not is_null or proposals:
            raise AssertionError(f"actor_null={is_null} proposals={proposals}")
        return "project1_actor() NULL, 0 proposals visible without binding"

    def forged_owner_insert_refused():
        conn = m2_conn(owner)
        refused = False
        try:
            with conn.cursor() as c:
                c.execute("""
                    INSERT INTO public.m2_bdj_objective_proposals (
                        proposal_id, evaluation_id, assessment_id, confirmation_id,
                        confirmation_revision, source_fingerprint, context_id,
                        context_packet_hash, recommendation_status, problem_type, problem,
                        research_objective, reason, source_refs, contract_version,
                        prompt_version, execution_mode, validation_status, owner_user_id)
                    VALUES (%s,%s,%s,%s,11,%s,%s,%s,'SUGGESTED','EXPLORATORY_RESEARCH_NEED',NULL,
                            'To investigate forged ownership attempts.', 'Probe.',
                            '[]'::jsonb, 'bdj-objective-proposal/1', 'BDJ-OBJECTIVE-3-CAND',
                            'SIMULATED','VALID',%s)""",
                    (str(uuid.uuid4()), str(uuid.uuid4()), str(assessment_id),
                     str(uuid.uuid4()), "a" * 64, str(uuid.uuid4()), "b" * 64,
                     str(other_owner)))
        except psycopg2.errors.InsufficientPrivilege:
            refused = True
        finally:
            conn.rollback(); conn.close()
        if not refused:
            raise AssertionError("WITH CHECK accepted a row owned by another user")
        return "WITH CHECK refused a row claiming another owner"

    def delete_refused():
        pid = probe_ids[-1]
        conn = m2_conn(owner)
        refused = False
        try:
            with conn.cursor() as c:
                c.execute("DELETE FROM public.m2_bdj_objective_proposals WHERE proposal_id=%s",
                          (str(pid),))
        except psycopg2.errors.InsufficientPrivilege:
            refused = True
        finally:
            conn.rollback(); conn.close()
        if not refused:
            raise AssertionError("runtime principal could DELETE a proposal")
        return "DELETE refused (InsufficientPrivilege)"

    def ledger_principal_works():
        conn = psycopg2.connect(dsn(target, ENGINE_ROLE, ENGINE_PW))
        conn.autocommit = False
        try:
            with conn.cursor() as c:
                c.execute("SELECT session_user")
                session_user = c.fetchone()[0]
                c.execute("SET LOCAL ROLE p1ai_runtime")
                c.execute("SELECT current_user,"
                          " (SELECT rolsuper FROM pg_roles WHERE rolname=current_user),"
                          " (SELECT rolbypassrls FROM pg_roles WHERE rolname=current_user)")
                current, sup, bypass = c.fetchone()
                c.execute("SELECT set_config('project1.actor_id', %s, true)", (str(owner),))
                c.execute("SELECT count(*) FROM project1_ai.runs")
                runs = c.fetchone()[0]
                c.execute("SELECT count(*) FROM project1_ai.attempts")
                attempts = c.fetchone()[0]
        finally:
            conn.rollback(); conn.close()
        if session_user != ENGINE_ROLE or current != "p1ai_runtime" or sup or bypass:
            raise AssertionError(f"{session_user}/{current} super={sup} bypass={bypass}")
        return (f"{ENGINE_ROLE} -> p1ai_runtime, NOSUPERUSER/NOBYPASSRLS, "
                f"ledger readable (runs={runs}, attempts={attempts})")

    def ledger_cannot_touch_proposals():
        conn = psycopg2.connect(dsn(target, ENGINE_ROLE, ENGINE_PW))
        conn.autocommit = False
        refused = False
        try:
            with conn.cursor() as c:
                c.execute("SET LOCAL ROLE p1ai_runtime")
                c.execute("SELECT set_config('project1.actor_id', %s, true)", (str(owner),))
                c.execute("SELECT count(*) FROM public.m2_bdj_objective_proposals")
        except psycopg2.errors.InsufficientPrivilege:
            refused = True
        finally:
            conn.rollback(); conn.close()
        if not refused:
            raise AssertionError("p1ai_runtime could read proposal rows")
        return "p1ai_runtime refused on proposals (least privilege preserved)"

    check("5. restricted principal identity", principal_is_restricted)
    check("6. owner can insert and read own proposal", owner_can_insert_and_read)
    check("7. owner can record a decision", owner_can_decide)
    check("8. other owner reads nothing", other_owner_cannot_read)
    check("9. other owner modifies nothing", other_owner_cannot_modify)
    check("10. unbound actor reads nothing", unbound_actor_sees_nothing)
    check("11. forged owner insert refused", forged_owner_insert_refused)
    check("12. runtime DELETE refused", delete_refused)
    check("13. ledger principal works", ledger_principal_works)
    check("14. ledger cannot read proposals", ledger_cannot_touch_proposals)

    # ---- cleanup (admin only; runtime has no DELETE by design) ------------
    cleanup = {}
    try:
        cur.execute("DELETE FROM public.m2_bdj_objective_decisions "
                    "WHERE proposal_id = ANY(%s::uuid[])", ([str(p) for p in probe_ids],))
        cleanup["decisions"] = cur.rowcount
        cur.execute("DELETE FROM public.m2_bdj_objective_proposals "
                    "WHERE proposal_id = ANY(%s::uuid[])", ([str(p) for p in probe_ids],))
        cleanup["proposals"] = cur.rowcount
    except Exception as exc:
        cleanup["error"] = f"{type(exc).__name__}: {exc}"
    cur.execute("SELECT count(*) AS n FROM public.m2_bdj_objective_proposals")
    cleanup["remaining_proposals"] = cur.fetchone()["n"]
    cur.execute("SELECT count(*) AS n FROM public.m2_bdj_objective_decisions")
    cleanup["remaining_decisions"] = cur.fetchone()["n"]

    cur.close(); admin.close()

    passed = sum(1 for c in checks if c["result"] == "PASS")
    evidence = {
        "gate": "A",
        "target": f"{ident['db']}@localhost:{ident['port']}",
        "migration": MIGRATION.name,
        "runtime_principal": M2_ROLE,
        "ledger_principal": f"{ENGINE_ROLE} -> p1ai_runtime",
        "checks": checks,
        "probe_cleanup": cleanup,
        "notes": notes,
        "passed": passed,
        "total": len(checks),
        "verdict": "PASS" if passed == len(checks) else "FAIL",
    }
    out = BACKEND.parent / "deliverables/phase2/BDJ_GATEA_RLS_GRANTS_20261122.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\n  cleanup:", cleanup)
    print("  %d/%d checks passed" % (passed, len(checks)))
    print("  evidence:", out)
    print("  VERDICT:", evidence["verdict"])
    return 0 if evidence["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
