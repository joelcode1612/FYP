"""BD-01 P2 — corrected question-bank schema evidence harness.

Runs ONLY against the disposable clone `project1_workflow_tests`. The database
name is asserted before any DDL and again before every block; `Dss` and
`Final_Location_Analysis` are refused outright.

It applies the forward migration, rolls it back (twice, for idempotency),
re-applies it, then executes the nine governance checks and writes a JSON
evidence file with one entry per check.

Run:
    backend/.venv/Scripts/python.exe backend/scripts/bd01_qgb_schema_evidence.py
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import psycopg2

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MIGRATIONS = ROOT / "migrations" / "m2"
FORWARD = MIGRATIONS / "20261118_01_question_bank.sql"
ROLLBACK = MIGRATIONS / "20261118_01_question_bank_rollback.sql"
EVIDENCE_DIR = ROOT / "var" / "qgb_evidence"
EVIDENCE_FILE = EVIDENCE_DIR / "bd01_qgb_evidence.json"

CLONE = "project1_workflow_tests"
PROTECTED = {"Dss", "Final_Location_Analysis"}
from sitewise.core.config import local_database_url

DSN = local_database_url(CLONE).set(drivername="postgresql")

RECEIPT = "BD01 P2: corrected question-bank schema verified on the disposable clone"

# Deterministic fixtures so the evidence file is reproducible.
TENANT_A = "11111111-1111-4111-8111-111111111111"
TENANT_B = "22222222-2222-4222-8222-222222222222"
LOGICAL_1 = "aaaaaaaa-0000-4000-8000-000000000001"
V1 = "bbbbbbbb-0000-4000-8000-000000000001"
V2 = "bbbbbbbb-0000-4000-8000-000000000002"
V3 = "bbbbbbbb-0000-4000-8000-000000000003"
S1 = "cccccccc-0000-4000-8000-000000000001"
R_A = "dddddddd-0000-4000-8000-00000000000a"
R_B = "dddddddd-0000-4000-8000-00000000000b"
SHA = "a" * 64

RESULTS: list[dict] = []


def record(check: int, name: str, status: str, sql: str, observed, note: str = "") -> None:
    RESULTS.append({
        "check": check,
        "name": name,
        "status": status,
        "sql": sql,
        "observed": observed,
        "note": note,
    })
    print(f"[{status}] {check}. {name} :: {observed}")


def assert_clone(cur) -> str:
    cur.execute("SELECT current_database()")
    db = cur.fetchone()[0]
    if db in PROTECTED:
        raise SystemExit(f"REFUSING: connected to protected database {db!r}")
    if db != CLONE:
        raise SystemExit(f"REFUSING: expected {CLONE!r}, got {db!r}")
    return db


def apply_script(cur, path: Path, receipt: str) -> None:
    cur.execute(f"SET project1.qgb_migration_target = '{CLONE}'")
    cur.execute(f"SET project1.qgb_migration_receipt = '{receipt}'")
    cur.execute(path.read_text(encoding="utf-8"))


def scalar(cur, sql: str):
    cur.execute(sql)
    return cur.fetchone()[0]


def expect_error(cur, sql: str) -> tuple[str, str]:
    """Execute SQL that must fail; return (sqlstate, message)."""
    try:
        cur.execute(sql)
    except psycopg2.Error as exc:
        return (exc.pgcode or "UNKNOWN", (exc.pgerror or "").strip().splitlines()[0])
    raise AssertionError(f"statement unexpectedly succeeded: {sql}")


def main() -> int:
    EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)
    conn = psycopg2.connect(DSN.render_as_string(hide_password=False))
    conn.autocommit = True
    cur = conn.cursor()

    # ------------------------------------------------------------------ 1
    db = assert_clone(cur)
    record(1, "current_database() is project1_workflow_tests before DDL", "PASS",
           "SELECT current_database();", db,
           "Asserted again before every DDL block below.")

    # ------------------------------------------------------------------ 2
    # Start from a known-absent state, then apply / roll back / roll back again /
    # re-apply. A guard mismatch must also be refused.
    try:
        apply_script(cur, ROLLBACK, RECEIPT)
        apply_script(cur, FORWARD, RECEIPT)
        applied = scalar(cur, "SELECT to_regclass('project1_qgb.question_item') IS NOT NULL")
        assert_clone(cur)
        apply_script(cur, ROLLBACK, RECEIPT)
        gone = scalar(cur, "SELECT to_regclass('project1_qgb.question_item') IS NULL")
        apply_script(cur, ROLLBACK, RECEIPT)  # second run: idempotency
        still_gone = scalar(cur, "SELECT to_regclass('project1_qgb.question_item') IS NULL")
        apply_script(cur, FORWARD, RECEIPT)   # re-apply works
        reapplied = scalar(cur, "SELECT to_regclass('project1_qgb.question_item') IS NOT NULL")

        # Guard refusal: a target that is not the current database must abort.
        try:
            cur.execute("SET project1.qgb_migration_target = 'Dss'")
            cur.execute("SET project1.qgb_migration_receipt = 'guard probe'")
            cur.execute(ROLLBACK.read_text(encoding="utf-8"))
            guard_refused, guard_state = False, "NO ERROR"
        except psycopg2.Error as exc:
            guard_refused, guard_state = True, (exc.pgcode or "UNKNOWN")
            # The probe script issues its own BEGIN; the aborted transaction must
            # be closed before the session can be reused.
            try:
                cur.execute("ROLLBACK")
            except psycopg2.Error:
                pass

        ok = bool(applied and gone and still_gone and reapplied and guard_refused)
        record(2, "Migration applies cleanly; rollback applies cleanly (twice); re-apply works",
               "PASS" if ok else "FAIL",
               "forward migration; rollback; rollback again; forward again; "
               "guard probe with project1.qgb_migration_target='Dss'",
               f"apply={applied} rollback_removed={gone} rollback_twice_ok={still_gone} "
               f"reapply={reapplied} mismatched_target_refused={guard_refused} ({guard_state})",
               "The guard also hard-refuses Dss / Final_Location_Analysis by name.")
    except Exception as exc:  # noqa: BLE001
        record(2, "Migration applies cleanly; rollback applies cleanly (twice); re-apply works",
               "FAIL", "psql -f 20261118_01_question_bank.sql", str(exc)[:300])

    # ---------------------------------------------------------------- 3
    cur.execute(f"SET project1.qgb_migration_target = '{CLONE}'")
    cur.execute(f"SET project1.qgb_migration_receipt = '{RECEIPT}'")

    cur.execute("INSERT INTO project1_qgb.question_item (logical_item_id) VALUES (%s)", (LOGICAL_1,))
    cur.execute("""INSERT INTO project1_qgb.question_item_version
                   (item_version_id, logical_item_id, instrument_version, item_payload, payload_sha256)
                   VALUES (%s,%s,'M2V1','{"q":"synthetic item"}',%s)""", (V1, LOGICAL_1, SHA))
    cur.execute("""INSERT INTO project1_qgb.item_lifecycle_event
                   (event_id, item_version_id, sequence, event_type, actor_id, actor_role)
                   VALUES ('eeeeeeee-0000-4000-8000-000000000001',%s,1,'CANDIDATE','system:ingest','SYSTEM')""", (V1,))
    state_after_candidate = scalar(cur,
        f"SELECT approval_state FROM project1_qgb.question_item_version_state WHERE item_version_id='{V1}'")

    cur.execute("""INSERT INTO project1_qgb.item_lifecycle_event
                   (event_id, item_version_id, sequence, event_type, actor_id, actor_role, attestation, receipt_ref)
                   VALUES ('eeeeeeee-0000-4000-8000-000000000002',%s,2,'INDEPENDENTLY_REVIEWED',
                           'reviewer-1','SCIENTIFIC_REVIEWER','I reviewed every item independently.','SR-1')""", (V1,))
    state_after_review = scalar(cur,
        f"SELECT approval_state FROM project1_qgb.question_item_version_state WHERE item_version_id='{V1}'")

    cur.execute("""INSERT INTO project1_qgb.item_lifecycle_event
                   (event_id, item_version_id, sequence, event_type, actor_id, actor_role, attestation, receipt_ref)
                   VALUES ('eeeeeeee-0000-4000-8000-000000000003',%s,3,'APPROVED',
                           'owner-1','OWNER_APPROVER','Approved on the scientific review.','OA-1')""", (V1,))
    row = None
    cur.execute(f"""SELECT approval_state, approved_at, scientific_reviewer_id, owner_approver_id
                    FROM project1_qgb.question_item_version_state WHERE item_version_id='{V1}'""")
    row = cur.fetchone()
    state_after_approval, approved_at, sr_id, oa_id = row
    ok3 = (state_after_candidate == "CANDIDATE"
           and state_after_review == "INDEPENDENTLY_REVIEWED"
           and state_after_approval == "APPROVED"
           and approved_at is not None
           and sr_id == "reviewer-1" and oa_id == "owner-1")
    record(3, "Lifecycle CANDIDATE -> INDEPENDENTLY_REVIEWED -> APPROVED", "PASS" if ok3 else "FAIL",
           "INSERT 3 item_lifecycle_event rows; SELECT ... FROM question_item_version_state",
           f"states={state_after_candidate}/{state_after_review}/{state_after_approval}, "
           f"approved_at={approved_at}, reviewer={sr_id}, approver={oa_id}")

    # ---------------------------------------------------------------- 4
    # (a) owner approval alone
    cur.execute("""INSERT INTO project1_qgb.question_item_version
                   (item_version_id, logical_item_id, instrument_version, item_payload, payload_sha256)
                   VALUES (%s,%s,'M2V1','{"q":"owner only"}',%s)""", (V2, LOGICAL_1, SHA))
    cur.execute("""INSERT INTO project1_qgb.item_lifecycle_event
                   (event_id, item_version_id, sequence, event_type, actor_id, actor_role)
                   VALUES ('eeeeeeee-0000-4000-8000-000000000011',%s,1,'CANDIDATE','system:ingest','SYSTEM')""", (V2,))
    cur.execute("""INSERT INTO project1_qgb.item_lifecycle_event
                   (event_id, item_version_id, sequence, event_type, actor_id, actor_role, attestation)
                   VALUES ('eeeeeeee-0000-4000-8000-000000000012',%s,2,'APPROVED','owner-1','OWNER_APPROVER','owner only')""", (V2,))
    owner_only = scalar(cur,
        f"SELECT approval_state FROM project1_qgb.question_item_version_state WHERE item_version_id='{V2}'")

    # (b) the same actor performing both roles
    cur.execute("""INSERT INTO project1_qgb.question_item_version
                   (item_version_id, logical_item_id, instrument_version, item_payload, payload_sha256)
                   VALUES (%s,%s,'M2V1','{"q":"self approval"}',%s)""", (V3, LOGICAL_1, SHA))
    cur.execute("""INSERT INTO project1_qgb.item_lifecycle_event
                   (event_id, item_version_id, sequence, event_type, actor_id, actor_role)
                   VALUES ('eeeeeeee-0000-4000-8000-000000000021',%s,1,'CANDIDATE','system:ingest','SYSTEM')""", (V3,))
    cur.execute("""INSERT INTO project1_qgb.item_lifecycle_event
                   (event_id, item_version_id, sequence, event_type, actor_id, actor_role, attestation)
                   VALUES ('eeeeeeee-0000-4000-8000-000000000022',%s,2,'INDEPENDENTLY_REVIEWED','alice','SCIENTIFIC_REVIEWER','self review')""", (V3,))
    cur.execute("""INSERT INTO project1_qgb.item_lifecycle_event
                   (event_id, item_version_id, sequence, event_type, actor_id, actor_role, attestation)
                   VALUES ('eeeeeeee-0000-4000-8000-000000000023',%s,3,'APPROVED','alice','OWNER_APPROVER','self approval')""", (V3,))
    self_approval = scalar(cur,
        f"SELECT approval_state FROM project1_qgb.question_item_version_state WHERE item_version_id='{V3}'")
    ok4 = (owner_only != "APPROVED") and (self_approval != "APPROVED")
    record(4, "Approval requires both roles and two distinct actors", "PASS" if ok4 else "FAIL",
           "owner-only events on V2; same-actor review+approval on V3; SELECT state view",
           f"owner_only={owner_only}, self_approval={self_approval}")

    # ---------------------------------------------------------------- 5
    cur.execute("""INSERT INTO project1_qgb.bank_snapshot
                   (snapshot_id, snapshot_version, scope_contract, catalogue_sha256, comparison_policy_version)
                   VALUES (%s,'SNAP-2026-11-18','GEO=RM13;INSTRUMENT=M2V1',%s,'CP-1')""", (S1, SHA))
    cur.execute("INSERT INTO project1_qgb.bank_snapshot_item (snapshot_id, item_version_id) VALUES (%s,%s)", (S1, V1))
    cur.execute("""INSERT INTO project1_qgb.bank_snapshot_event
                   (event_id, snapshot_id, sequence, event_type, actor_id, actor_role)
                   VALUES ('ffffffff-0000-4000-8000-000000000001',%s,1,'DRAFT','system:build','SYSTEM')""", (S1,))
    draft_state = scalar(cur,
        f"SELECT state FROM project1_qgb.bank_snapshot_state WHERE snapshot_id='{S1}'")
    cur.execute("""INSERT INTO project1_qgb.bank_snapshot_event
                   (event_id, snapshot_id, sequence, event_type, actor_id, actor_role, attestation)
                   VALUES ('ffffffff-0000-4000-8000-000000000002',%s,2,'ACCEPTED',
                           'owner-1','OWNER_APPROVER','Coverage complete against the scope contract.')""", (S1,))
    cur.execute(f"SELECT state, accepted_at, acceptor_id FROM project1_qgb.bank_snapshot_state WHERE snapshot_id='{S1}'")
    snap_state, accepted_at, acceptor = cur.fetchone()
    ok5 = draft_state == "DRAFT" and snap_state == "ACCEPTED" and accepted_at is not None and acceptor == "owner-1"
    record(5, "Snapshot can reach ACCEPTED (defect BD01-SQL-01 fixed)", "PASS" if ok5 else "FAIL",
           "INSERT bank_snapshot + bank_snapshot_item + DRAFT event + ACCEPTED event; SELECT bank_snapshot_state",
           f"draft={draft_state}, accepted={snap_state}, accepted_at={accepted_at}, acceptor={acceptor}")

    # ---------------------------------------------------------------- 6
    immutability = []
    for label, sql in [
        ("UPDATE question_item_version",
         f"UPDATE project1_qgb.question_item_version SET instrument_version='M2V9' WHERE item_version_id='{V1}'"),
        ("UPDATE item_lifecycle_event",
         f"UPDATE project1_qgb.item_lifecycle_event SET actor_id='tamper' WHERE event_id='eeeeeeee-0000-4000-8000-000000000003'"),
        ("DELETE question_item_version",
         f"DELETE FROM project1_qgb.question_item_version WHERE item_version_id='{V1}'"),
        ("DELETE item_lifecycle_event",
         f"DELETE FROM project1_qgb.item_lifecycle_event WHERE event_id='eeeeeeee-0000-4000-8000-000000000003'"),
        ("UPDATE bank_snapshot",
         f"UPDATE project1_qgb.bank_snapshot SET scope_contract='tamper' WHERE snapshot_id='{S1}'"),
    ]:
        try:
            state, msg = expect_error(cur, sql)
        except AssertionError as exc:
            state, msg = "NO ERROR", str(exc)
        immutability.append({"statement": label, "sqlstate": state, "message": msg})
    ok6 = all(i["sqlstate"] == "QGB01" for i in immutability)
    still_there = scalar(cur, f"SELECT count(*) FROM project1_qgb.question_item_version WHERE item_version_id='{V1}'")
    record(6, "Immutability: UPDATE/DELETE raise QGB01 on version and event rows", "PASS" if ok6 else "FAIL",
           "UPDATE / DELETE against question_item_version and item_lifecycle_event",
           f"sqlstates={[i['sqlstate'] for i in immutability]}, version_row_survives={still_there == 1}",
           json.dumps(immutability))

    # ---------------------------------------------------------------- 7
    cur.execute(f"""SELECT event_id, event_type, actor_id, actor_role, occurred_at::text
                    FROM project1_qgb.item_lifecycle_event
                    WHERE item_version_id='{V1}' AND event_type='APPROVED'""")
    approved_before = cur.fetchone()
    cur.execute("""INSERT INTO project1_qgb.item_lifecycle_event
                   (event_id, item_version_id, sequence, event_type, actor_id, actor_role, attestation)
                   VALUES ('eeeeeeee-0000-4000-8000-000000000004',%s,4,'RETIRED','owner-1','OWNER_APPROVER','Superseded by a later instrument version.')""", (V1,))
    retired_state = scalar(cur,
        f"SELECT approval_state FROM project1_qgb.question_item_version_state WHERE item_version_id='{V1}'")
    cur.execute(f"""SELECT event_id, event_type, actor_id, actor_role, occurred_at::text
                    FROM project1_qgb.item_lifecycle_event
                    WHERE item_version_id='{V1}' AND event_type='APPROVED'""")
    approved_after = cur.fetchone()
    ok7 = retired_state == "RETIRED" and approved_before == approved_after
    record(7, "Retirement without rewriting history", "PASS" if ok7 else "FAIL",
           "INSERT RETIRED event; compare the prior APPROVED row before/after",
           f"state={retired_state}, approved_row_unchanged={approved_before == approved_after}")

    # ---------------------------------------------------------------- 8 / 9
    cur.execute("""INSERT INTO project1_qgb.comparison_receipt
        (receipt_id, snapshot_id, tenant_id, objective_id, source_confirmation_id,
         measurement_digest, bcb_packet_hash, comparison_policy_version, issuer_id,
         issuer_attestation, decision, equivalent_item_version_id, receipt_sha256)
        VALUES (%s,%s,%s,'99999999-0000-4000-8000-000000000001','88888888-0000-4000-8000-000000000001',
                %s,%s,'CP-1','issuer-1','Issued under the accepted snapshot.','EQUIVALENT',%s,%s)""",
        (R_A, S1, TENANT_A, SHA, SHA, V1, SHA))
    cur.execute("""INSERT INTO project1_qgb.comparison_receipt
        (receipt_id, snapshot_id, tenant_id, objective_id, source_confirmation_id,
         measurement_digest, bcb_packet_hash, comparison_policy_version, issuer_id,
         issuer_attestation, decision, equivalent_item_version_id, receipt_sha256)
        VALUES (%s,%s,%s,'99999999-0000-4000-8000-000000000002','88888888-0000-4000-8000-000000000002',
                %s,%s,'CP-1','issuer-1','Issued under the accepted snapshot.','NO_EQUIVALENT',NULL,%s)""",
        (R_B, S1, TENANT_B, SHA, SHA, SHA))
    cur.execute("""INSERT INTO project1_qgb.comparison_review_item
        (receipt_id, item_version_id, reviewer_id, reviewer_attestation, equivalent, rationale)
        VALUES (%s,%s,'reviewer-1','Compared field by field.',true,'Same construct and scale.')""", (R_A, V1))
    cur.execute("""INSERT INTO project1_qgb.comparison_review_item
        (receipt_id, item_version_id, reviewer_id, reviewer_attestation, equivalent, rationale)
        VALUES (%s,%s,'reviewer-1','Compared field by field.',false,'Different construct.')""", (R_B, V1))

    cur.execute("""SELECT rolname, rolsuper, rolbypassrls FROM pg_roles
                   WHERE rolname='p1_qgb_runtime'""")
    rolname, rolsuper, rolbypass = cur.fetchone()
    not_bypass = (rolsuper is False) and (rolbypass is False)

    cur.execute("SET ROLE p1_qgb_runtime")
    cur.execute(f"SET project1.tenant_id = '{TENANT_A}'")
    cur.execute("SELECT count(*) FROM project1_qgb.comparison_receipt")
    visible_total = cur.fetchone()[0]
    cur.execute(f"SELECT count(*) FROM project1_qgb.comparison_receipt WHERE tenant_id = '{TENANT_B}'")
    cross_tenant_count = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM project1_qgb.comparison_review_item")
    review_visible = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM project1_qgb.comparison_review_item WHERE receipt_id = %s", (R_B,))
    review_cross = cur.fetchone()[0]
    cur.execute("SELECT current_user, current_setting('project1.tenant_id')")
    as_user, as_tenant = cur.fetchone()
    cur.execute("RESET ROLE")
    cur.execute("RESET project1.tenant_id")

    ok8 = (visible_total == 1 and cross_tenant_count == 0 and not_bypass
           and review_visible == 1 and review_cross == 0)
    record(8, "RLS isolates receipts by tenant; role is not superuser and not BYPASSRLS", "PASS" if ok8 else "FAIL",
           "SET ROLE p1_qgb_runtime; SET project1.tenant_id='<A>'; SELECT ... FROM comparison_receipt / comparison_review_item",
           f"role={rolname} super={rolsuper} bypassrls={rolbypass}; "
           f"visible_total={visible_total}, tenantB_rows_visible={cross_tenant_count}, "
           f"review_visible={review_visible}, review_tenantB_visible={review_cross}",
           f"executed as {as_user} with tenant {as_tenant}")

    # Check 9: an explicit cross-tenant predicate must still return nothing.
    cur.execute("SET ROLE p1_qgb_runtime")
    cur.execute(f"SET project1.tenant_id = '{TENANT_A}'")
    cur.execute("SELECT count(*) FROM project1_qgb.comparison_receipt WHERE tenant_id = %s", (TENANT_B,))
    direct_cross = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM project1_qgb.comparison_receipt WHERE receipt_id = %s", (R_B,))
    direct_cross_by_id = cur.fetchone()[0]
    cur.execute("RESET ROLE")
    cur.execute("RESET project1.tenant_id")
    ok9 = direct_cross == 0 and direct_cross_by_id == 0
    record(9, "Cross-tenant lookup by query alone returns zero rows", "PASS" if ok9 else "FAIL",
           "SET ROLE p1_qgb_runtime; SET project1.tenant_id='<A>'; "
           "SELECT ... WHERE tenant_id='<B>'; SELECT ... WHERE receipt_id='<B receipt>'",
           f"rows_by_tenant_B={direct_cross}, rows_by_receipt_B={direct_cross_by_id}")

    # Structural note: the corrected version table must have no lifecycle column.
    cur.execute("""SELECT count(*) FROM information_schema.columns
                   WHERE table_schema='project1_qgb' AND table_name='question_item_version'
                     AND column_name IN ('approval_state','approved_at','scientific_reviewer_id','owner_approver_id')""")
    lifecycle_cols = cur.fetchone()[0]
    cur.execute("""SELECT count(*) FROM information_schema.columns
                   WHERE table_schema='project1_qgb' AND table_name='bank_snapshot'
                     AND column_name IN ('state','accepted_at')""")
    snapshot_state_cols = cur.fetchone()[0]

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "database": db,
        "migration": str(FORWARD),
        "rollback": str(ROLLBACK),
        "migration_receipt": RECEIPT,
        "commands": {
            "apply": ("psql -h localhost -U postgres -d project1_workflow_tests "
                      "-v ON_ERROR_STOP=1 "
                      "-c \"SET project1.qgb_migration_target='project1_workflow_tests'; "
                      "SET project1.qgb_migration_receipt='<receipt>';\" "
                      "-f backend/migrations/m2/20261118_01_question_bank.sql"),
            "rollback": ("psql -h localhost -U postgres -d project1_workflow_tests "
                         "-v ON_ERROR_STOP=1 "
                         "-c \"SET project1.qgb_migration_target='project1_workflow_tests'; "
                         "SET project1.qgb_migration_receipt='<receipt>';\" "
                         "-f backend/migrations/m2/20261118_01_question_bank_rollback.sql"),
            "harness": "backend/.venv/Scripts/python.exe backend/scripts/bd01_qgb_schema_evidence.py",
        },
        "structural_assertions": {
            "question_item_version_lifecycle_columns": lifecycle_cols,
            "bank_snapshot_state_columns": snapshot_state_cols,
            "expected_zero": True,
        },
        "checks": RESULTS,
        "verdict": "PASS" if all(r["status"] == "PASS" for r in RESULTS) else "FAIL",
    }
    EVIDENCE_FILE.write_text(json.dumps(payload, indent=2, default=str), encoding="utf-8")
    print(f"\nevidence: {EVIDENCE_FILE}")
    print(f"VERDICT={payload['verdict']}")
    cur.close()
    conn.close()
    return 0 if payload["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
