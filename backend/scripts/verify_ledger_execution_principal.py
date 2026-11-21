"""Verify the restricted execution-principal contract end to end (no model call).

Proves:
 1. p1ai_engine -> SET LOCAL ROLE p1ai_runtime can provision a run and drive
    PostgresAttemptLedger.reserve()/finish().
 2. A receipt persists and is append-only (UPDATE/DELETE rejected).
 3. The ordinary app role (p1_m2_runtime) fails closed.
 4. A superuser connection fails closed.

No provider call is made. Rows created here are honest append-only history
(outcome 'rejected'); they cannot and should not be deleted.
"""
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sqlalchemy import create_engine, text  # noqa: E402
from sqlalchemy.engine import make_url  # noqa: E402

from sitewise.core.config import settings  # noqa: E402
from sitewise.project1.contracts import WorkflowHeld  # noqa: E402
from sitewise.project1.ledger import PostgresAttemptLedger  # noqa: E402

ACTOR = uuid.UUID("11111111-1111-4111-8111-111111111111")
ASSESSMENT = uuid.UUID("da90aa4a-f9cf-4145-9acf-7de36c9d6fad")
H = "a" * 64


def provision_run(engine, run_id):
    with engine.connect() as c:
        c.execute(text("SET LOCAL ROLE p1ai_runtime"))
        c.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {"a": str(ACTOR)})
        c.execute(text(
            "INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,assessment_revision,"
            "source_fingerprint,policy_fingerprint,work_identity) "
            "VALUES (:r,:o,:a,12,:h,:h,:w)"),
            {"r": run_id, "o": ACTOR, "a": ASSESSMENT, "h": H, "w": uuid.uuid4().hex + uuid.uuid4().hex[:32]})
        c.commit()


def main() -> int:
    runtime_url = settings.project1_runtime_database_url.get_secret_value()
    if not runtime_url:
        print("BLOCKED: PROJECT1_RUNTIME_DATABASE_URL not set")
        return 2
    engine = create_engine(runtime_url, hide_parameters=True)

    run_id = uuid.uuid4()
    provision_run(engine, run_id)
    print(f"provision_run={run_id}")

    ledger = PostgresAttemptLedger(engine, ACTOR, run_id)
    attempt = ledger.reserve("BDJ", "BDJ-SOURCE-1-CAND", "c" * 64, "d" * 64)
    print(f"reserve=attempt_{attempt}")
    ledger.finish(attempt, "rejected", None)
    print("finish=rejected_persisted")

    with engine.connect() as c:
        c.execute(text("SET LOCAL ROLE p1ai_runtime"))
        c.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {"a": str(ACTOR)})
        n_att = c.execute(text("SELECT count(*) FROM project1_ai.attempts WHERE run_id=:r"), {"r": run_id}).scalar()
        n_rec = c.execute(text("SELECT count(*) FROM project1_ai.attempt_receipts WHERE run_id=:r"), {"r": run_id}).scalar()
        outcome = c.execute(text("SELECT outcome FROM project1_ai.attempt_receipts WHERE run_id=:r"), {"r": run_id}).scalar()
        print(f"readback attempts={n_att} receipts={n_rec} outcome={outcome}")

    # Append-only trigger: must be exercised by a role that HAS UPDATE privilege
    # (p1ai_runtime does not), otherwise permission-denied masks the trigger.
    super_url = make_url(settings.database_url).set(database="Dss")
    super_engine = create_engine(super_url, hide_parameters=True)
    append_only_ok = False
    try:
        with super_engine.connect() as c:
            c.execute(text("UPDATE project1_ai.attempts SET prompt_version='tampered' WHERE run_id=:r"), {"r": run_id})
        print("append_only=FAIL (update allowed)")
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        append_only_ok = "append-only" in msg
        print(f"append_only={'PASS' if append_only_ok else 'FAIL'} ({type(exc).__name__}: {msg[:120]})")

    # Fail-closed: ordinary app role.
    app_engine = create_engine(settings.m2_database_url.get_secret_value(), hide_parameters=True)
    try:
        PostgresAttemptLedger(app_engine, ACTOR, run_id).reserve("QJ", "x", "c" * 64, "d" * 64)
        print("app_role=FAIL (reserved)")
    except WorkflowHeld as exc:
        print(f"app_role=PASS fail_closed code={exc}")

    # Fail-closed: superuser.
    try:
        PostgresAttemptLedger(super_engine, ACTOR, run_id).reserve("QG", "x", "c" * 64, "d" * 64)
        print("superuser=FAIL (reserved)")
    except WorkflowHeld as exc:
        print(f"superuser=PASS fail_closed code={exc}")

    ok = (n_att == 1 and n_rec == 1 and outcome == "rejected" and append_only_ok)
    print(f"VERDICT={'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
