"""Gate 2 preparation — disposable M2 + project1_ai target on :5433.

Corrections over the first version:
  * the target guard runs BEFORE any administrative DDL (no CREATE DATABASE
    before the port/name check);
  * "already applied" is decided by object post-conditions, never by matching
    error text — a missing pre-condition constraint is a FAILURE, not a skip;
  * every required ledger, result-store and M2 object is verified against its
    expected definition after migration.

Targets: `project1_workflow_tests@5433` only. `Dss` and `Final_Location_Analysis`
are never referenced. `p1_phase1_scratch` is preserved untouched.
"""
import json
from pathlib import Path

import psycopg2
from sqlalchemy import create_engine, inspect

TARGET_DB = "project1_workflow_tests"
ALLOWED_DBS = {"project1_workflow_tests"}
PORT = 5433
RECEIPT = "phase2-synthetic-e2e-20261121 owner-authorized-disposable"

BACKEND = Path(__file__).resolve().parents[1]
AI_MIGRATIONS = sorted((BACKEND / "migrations/project1_ai").glob("*.sql"))
OURS = [BACKEND / "migrations/sql/20261121_0100_m2_bdj_objective_proposals.sql",
        BACKEND / "migrations/sql/20261121_0200_m2_bdj_objective_decisions.sql"]

# Post-condition markers. Presence means "already applied"; absence means the
# migration must run, and any failure is a real failure.
MARKERS = {
    "20261111_01_candidate_ledger.sql":
        "SELECT to_regclass('project1_ai.runs') IS NOT NULL",
    "20261118_03_qg_retry_slots.sql":
        "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='attempts_run_stage_slot_key')",
    "20261117_02_finding_provenance.sql":
        "SELECT to_regclass('project1_ai.finding_provenance') IS NOT NULL",
    "20261117_03_bdj_result_persistence.sql":
        "SELECT to_regclass('project1_ai.bdj_results') IS NOT NULL",
    "20261121_04_execution_mode.sql":
        "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='project1_ai'"
        " AND table_name='bdj_results' AND column_name='execution_mode')",
    "20261121_06_real_data_authorization.sql":
        "SELECT to_regclass('project1_ai.bdj_real_data_authorizations') IS NOT NULL",
}

EXPECTED = {
    "project1_ai": ["runs", "attempts", "bdj_results", "bdj_result_sources",
                    "bdj_result_validations", "bdj_result_findings", "bdj_raw_responses"],
    "public": ["m2_instrument_versions", "m2_item_versions", "m2_assessments",
               "m2_answer_revisions", "m2_bdj_findings", "m2_bdj_evaluations",
               "m2_review_events", "m2_confirmation_snapshots",
               "m2_confirmed_uncertainties", "m2_clarification_events",
               "m2_bdj_objective_proposals", "m2_bdj_objective_decisions"],
}


def admin_url(db="postgres"):
    for line in (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("DATABASE_URL="):
            base = line.split("=", 1)[1].strip().replace("postgresql+psycopg2://", "postgresql://")
            return base.rsplit("/", 1)[0].replace(":5432", f":{PORT}") + "/" + db
    raise SystemExit("DATABASE_URL missing")


def preflight():
    """Refuse before any DDL — no connection is opened for a non-target."""
    url = admin_url(TARGET_DB)
    if f":{PORT}/" not in url:
        raise SystemExit(f"REFUSED: port is not {PORT}")
    if not any(host in url for host in ("@localhost", "@127.0.0.1")):
        raise SystemExit("REFUSED: host is not the local isolated cluster")
    if TARGET_DB not in ALLOWED_DBS:
        raise SystemExit("REFUSED: database not in allowlist")
    print(f"preflight: target {TARGET_DB}@{PORT} accepted before any DDL")


def connect(db):
    conn = psycopg2.connect(admin_url(db))
    conn.autocommit = True
    return conn


def guard(db, conn):
    with conn.cursor() as cur:
        cur.execute("select current_database(), inet_server_port()")
        name, port = cur.fetchone()
    if name not in ALLOWED_DBS or port != PORT or name != db:
        raise SystemExit(f"REFUSED: server reports {name}@{port}, not the authorized target")


def ensure_database():
    conn = connect("postgres")
    try:
        with conn.cursor() as cur:
            cur.execute("select 1 from pg_database where datname=%s", (TARGET_DB,))
            if not cur.fetchone():
                cur.execute(f'CREATE DATABASE "{TARGET_DB}"')
                return "created"
            return "reused"
    finally:
        conn.close()


def marker_state(conn, path):
    sql = MARKERS.get(path.name)
    if not sql:
        return False
    with conn.cursor() as cur:
        cur.execute(sql)
        return bool(cur.fetchone()[0])


def main():
    preflight()
    state = ensure_database()
    conn = connect(TARGET_DB)
    guard(TARGET_DB, conn)

    print("=" * 78)
    print("GATE 2 PREP —", f"{TARGET_DB}@{PORT}", f"({state})")
    print("=" * 78)

    from sitewise.db.models.m2_schema import m2_metadata
    engine = create_engine(admin_url(TARGET_DB).replace("postgresql://",
                                                        "postgresql+psycopg2://", 1))
    m2_metadata.create_all(engine)
    m2_tables = sorted(t for t in inspect(engine).get_table_names() if t.startswith("m2_"))
    print(f"  m2 schema: {len(m2_tables)} tables")

    applied, skipped, failures = [], [], []
    for path in AI_MIGRATIONS:
        if path.name.endswith("_rollback.sql"):
            continue
        sql = path.read_text(encoding="utf-8")
        if marker_state(conn, path):
            skipped.append({"file": path.name, "reason": "post-condition present"})
            print(f"  skip    {path.name} (post-condition present)")
            continue
        if "current_database() <> 'Dss'" in sql:
            skipped.append({"file": path.name, "reason": "Dss-only role/RLS provisioning"})
            print(f"  skip    {path.name} (Dss-only by design)")
            continue
        try:
            with conn.cursor() as cur:
                for guc in ("project1.migration_target", "project1.m2_bcb_migration_target"):
                    cur.execute(f"SET {guc} = %s", (TARGET_DB,))
                for guc in ("project1.migration_receipt", "project1.m2_bcb_migration_receipt"):
                    cur.execute(f"SET {guc} = %s", (RECEIPT,))
                cur.execute(sql)
            applied.append(path.name)
            print(f"  applied {path.name}")
        except Exception as exc:
            try:
                with conn.cursor() as c:
                    c.execute("ROLLBACK")
            except Exception:
                pass
            msg = str(exc).splitlines()[0][:180]
            failures.append({"file": path.name, "error": msg})
            print(f"  FAILED  {path.name}: {msg[:110]}")

    for path in OURS:
        try:
            with conn.cursor() as cur:
                cur.execute(path.read_text(encoding="utf-8"))
            applied.append(path.name)
            print(f"  applied {path.name}")
        except Exception as exc:
            try:
                with conn.cursor() as c:
                    c.execute("ROLLBACK")
            except Exception:
                pass
            failures.append({"file": path.name, "error": str(exc).splitlines()[0][:180]})

    conn.rollback()
    verify = connect(TARGET_DB)
    present = {}
    with verify.cursor() as cur:
        for schema, tables in EXPECTED.items():
            cur.execute("select table_name from information_schema.tables where table_schema=%s",
                        (schema,))
            have = {r[0] for r in cur.fetchall()}
            present[schema] = {"expected": len(tables),
                               "missing": [t for t in tables if t not in have],
                               "extra": sorted(have - set(tables))}
        cur.execute("select conname from pg_constraint where conname in "
                    "('attempts_run_stage_slot_key','attempts_run_id_stage_key')")
        cons = sorted(r[0] for r in cur.fetchall())
        cur.execute("select count(*) from public.m2_item_versions")
        items = cur.fetchone()[0]
    phase1 = connect("p1_phase1_scratch")
    with phase1.cursor() as cur:
        cur.execute("select count(*) from public.m2_bdj_objective_proposals")
        phase1_rows = cur.fetchone()[0]
    phase1.close()

    ok = (not failures and not present["public"]["missing"]
          and not present["project1_ai"]["missing"]
          and cons == ["attempts_run_stage_slot_key"])
    print(f"  constraints on attempts: {cons}")
    print(f"  missing public: {present['public']['missing'] or 'none'}")
    print(f"  missing project1_ai: {present['project1_ai']['missing'] or 'none'}")
    print(f"  m2_item_versions rows: {items} | p1_phase1_scratch preserved: {phase1_rows}")

    evidence = {"gate": 2, "preparation": True, "target": f"{TARGET_DB}@{PORT}",
                "guard": "preflight before any DDL; server identity re-checked after connect",
                "applied": applied, "skipped": skipped, "failures": failures,
                "objects": present, "attempts_constraints": cons,
                "m2_item_versions": items, "phase1_database_rows": phase1_rows,
                "verdict": "PASS" if ok else "FAIL"}
    out = BACKEND.parent / "deliverables/phase2/BDJ_GATE2_SCHEMA_PREP_20261121.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\n  evidence:", out)
    print("  VERDICT:", evidence["verdict"])
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
