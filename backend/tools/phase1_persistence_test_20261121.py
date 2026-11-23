"""Phase 1 verification — proposal persistence on a disposable cluster.

Target: the separate cluster on port 5433 (databases: postgres, dss_uc_stage_tests).
A dedicated scratch database `p1_phase1_scratch` and a restricted role
`p1_phase1_runner` are created if absent. `Dss` and `Final_Location_Analysis`
are never referenced.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase1_persistence_test_20261121.py
"""
import json
import os
import re
import uuid
from pathlib import Path

import psycopg2
from sqlalchemy import create_engine, text

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.objective_adapter import (
    migrate, persist, read, rollback_candidate,
)
from sitewise.project1.objective_proposal import (
    CONTRACT_VERSION, ObjectiveProposal, bind_to_business_context,
    validate_objective_proposal,
)
from sitewise.services.business_context_v1 import source_hash

def _admin_url():
    """Admin DSN for the disposable cluster.

    The :5433 cluster accepts the same superuser credentials as :5432, so the
    password is taken from `.env` rather than guessed. Only the port and the
    database name are rewritten.
    """
    explicit = os.environ.get("PHASE1_ADMIN_URL")
    if explicit:
        return explicit
    env_path = Path(__file__).resolve().parents[1] / ".env"
    url = ""
    for line in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("DATABASE_URL="):
            url = line.split("=", 1)[1].strip()
            break
    if not url:
        raise SystemExit("DATABASE_URL not found; set PHASE1_ADMIN_URL instead")
    url = url.replace("postgresql+psycopg2://", "postgresql://")
    head, _ = url.rsplit("/", 1)
    head = head.replace(":5432", ":5433").replace("@localhost", "@localhost")
    return head + "/postgres"


ADMIN = _admin_url()
SCRATCH_DB = os.environ.get("PHASE1_DB_NAME", "p1_phase1_scratch")
RUNNER_ROLE = os.environ.get("PHASE1_ROLE", "p1_phase1_runner")
RUNNER_PW = os.environ.get("PHASE1_ROLE_PW", "phase1_dev_only")
RUNNER_URL = (f"postgresql+psycopg2://{RUNNER_ROLE}:{RUNNER_PW}@localhost:5433/{SCRATCH_DB}")


def url_for(db: str) -> str:
    """Swap only the path segment; never touch the user or the scheme."""
    return ADMIN.rsplit("/", 1)[0] + "/" + db


ADMIN_SCRATCH_URL = ADMIN.rsplit("/", 1)[0] + "/" + SCRATCH_DB


def sqlalchemy_url(db: str) -> str:
    """SQLAlchemy needs the explicit psycopg2 dialect; libpq does not."""
    return url_for(db).replace("postgresql://", "postgresql+psycopg2://", 1)


ADMIN_SCRATCH_URL = sqlalchemy_url(SCRATCH_DB)

OWNER = uuid.uuid4()
OTHER = uuid.uuid4()
ASSESSMENT = uuid.uuid4()
CONFIRMATION = uuid.uuid4()
EVALUATION = uuid.uuid4()


def admin(sql, params=None, db="postgres"):
    conn = psycopg2.connect(url_for(db))
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params or ())
            return cur.fetchall() if cur.description else None
    finally:
        conn.close()


def ensure_infrastructure():
    if not re.fullmatch(r"[a-z_][a-z0-9_]{0,62}", RUNNER_ROLE):
        raise SystemExit("invalid role name")
    if not admin("SELECT 1 FROM pg_roles WHERE rolname = %s", (RUNNER_ROLE,)):
        admin('CREATE ROLE "%s" LOGIN PASSWORD %%s' % RUNNER_ROLE, (RUNNER_PW,))
    exists = admin("SELECT 1 FROM pg_database WHERE datname = %s", (SCRATCH_DB,))
    if not exists:
        if not re.fullmatch(r"[a-z_][a-z0-9_]{0,62}", SCRATCH_DB):
            raise SystemExit("invalid database name")
        admin(f'CREATE DATABASE "{SCRATCH_DB}"')
    return "created" if not exists else "reused"


def build_source():
    version_tag = "M2V1-20261114-1"
    values = {"M2V1-01": "UNDECIDED", "M2V1-02": "DINE_IN", "M2V1-08": "UNKNOWN",
              "M2V1-11": "UNSURE"}
    questions = {"M2V1-01": "Which area are you currently considering?",
                 "M2V1-02": "How do you currently plan to serve customers?",
                 "M2V1-08": "Which sources of information have you used?",
                 "M2V1-11": "Which statement describes your research position?"}
    decls = [{"item_key": k, "question": questions[k], "answer_state": "ANSWERED",
              "answer_revision_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "a|" + k)),
              "item_version_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "i|" + k)),
              "value": values[k]} for k in sorted(values)]
    packet = {"schema_version": "project1-m2-projection/1-candidate",
              "instrument_version": version_tag,
              "instrument_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "instrument")),
              "assessment_id": str(ASSESSMENT), "assessment_revision": 7,
              "confirmed": True,
              "confirmation": {"confirmation_id": str(CONFIRMATION),
                               "snapshot_digest": "a" * 64},
              "declarations": decls}
    from sitewise.project1.contracts import digest
    packet["source_fingerprint"] = digest(packet)
    return packet


def build_context(packet):
    ctx = {"schema_version": "persisted-business-context/1", "context_version": "1.1",
           "confirmation": {"id": str(CONFIRMATION), "revision": 7,
                            "digest": packet["confirmation"]["snapshot_digest"],
                            "status": "CURRENT_CONFIRMED"},
           "m2_answers": [{k: d[k] for k in ("item_key", "answer_revision_id",
                                             "item_version_id", "answer_state", "value")}
                          for d in packet["declarations"]],
           "permissions": {"report_admission": False, "report_release": False,
                           "qj_execution": False, "qg_execution": False}}
    ctx["packet_hash"] = source_hash(ctx)
    return ctx


def proposal_payload(packet):
    def rec(key, status="MOST_SUGGESTED"):
        row = next(d for d in packet["declarations"] if d["item_key"] == key)
        return {"recommendation_status": status,
                "problem_type": ("SOURCE_CONFIRMED_INFORMATION_GAP" if status == "MOST_SUGGESTED"
                                 else "EXPLORATORY_RESEARCH_NEED"),
                "problem": ("The confirmed answer to %s is %s." % (key, row["value"])
                            if status == "MOST_SUGGESTED" else None),
                "research_objective": "To investigate what %s leaves unresolved." % key,
                "source_refs": ([{"item_key": key,
                                  "answer_revision_id": row["answer_revision_id"],
                                  "item_version_id": row["item_version_id"]}]
                                if status == "MOST_SUGGESTED" else []),
                "reason": "Restates the confirmed uncertainty." if status == "MOST_SUGGESTED"
                          else "Exploratory; no confirmed answer establishes this need.",
                "authority": "CANDIDATE_ONLY"}
    return {"contract_version": CONTRACT_VERSION,
            "recommendations": [rec("M2V1-08"), rec("M2V1-11", "SUGGESTED")]}


def main():
    results = []

    def check(label, fn):
        try:
            detail = fn()
            results.append({"check": label, "result": "PASS", "detail": detail})
        except Exception as exc:
            results.append({"check": label, "result": "FAIL",
                            "detail": f"{type(exc).__name__}: {str(exc)[:160]}"})
        print("  %-4s %-46s %s" % (results[-1]["result"], label,
                                   str(results[-1]["detail"])[:80]))

    print("=" * 78)
    print("PHASE 1 — PROPOSAL PERSISTENCE (disposable cluster :5433)")
    print("=" * 78)
    state = ensure_infrastructure()
    print("scratch database:", SCRATCH_DB, "(", state, ")")
    print("restricted role :", RUNNER_ROLE)

    admin_engine = create_engine(ADMIN_SCRATCH_URL)
    migrate(admin_engine)
    admin(f"GRANT USAGE ON SCHEMA public TO {RUNNER_ROLE}; "
          f"GRANT SELECT, INSERT, UPDATE, DELETE ON public.m2_bdj_objective_proposals "
          f"TO {RUNNER_ROLE};", db=SCRATCH_DB)

    runner = create_engine(RUNNER_URL)
    packet = build_source()
    context = build_context(packet)
    payload = proposal_payload(packet)
    proposal = validate_objective_proposal(payload, packet)
    bound = bind_to_business_context(proposal, context_packet=context, context_id="ctx-p1")

    def migration_shape():
        cols = admin("SELECT count(*) FROM information_schema.columns WHERE table_name="
                     "'m2_bdj_objective_proposals'", db=SCRATCH_DB)[0][0]
        checks = admin("SELECT count(*) FROM pg_constraint c JOIN pg_class t ON "
                       "c.conrelid=t.oid WHERE t.relname='m2_bdj_objective_proposals' "
                       "AND c.contype='c'", db=SCRATCH_DB)[0][0]
        if cols < 20 or checks < 3:
            raise AssertionError(f"columns={cols} checks={checks}")
        return f"{cols} columns, {checks} check constraints"

    def no_approved_objects():
        rows = admin("SELECT table_name FROM information_schema.tables WHERE table_name IN "
                     "('m2_confirmed_uncertainties','m2_bdj_findings')", db=SCRATCH_DB)
        if rows:
            raise AssertionError(f"unexpected tables: {rows}")
        return "no objective/finding tables created by this adapter"

    def valid_write():
        out = persist(runner, bound, owner_user_id=OWNER, evaluation_id=EVALUATION,
                      assessment_id=ASSESSMENT, confirmation_revision=7,
                      confirmation_id=CONFIRMATION,
                      source_fingerprint=packet["source_fingerprint"],
                      prompt_version="BDJ-OBJECTIVE-3-CAND",
                      execution_mode="SIMULATED", model_provider="tokenharbor",
                      model_requested="deepseek-v4.1-flash-1017", model_returned=None)
        if not all(r["created"] for r in out):
            raise AssertionError(f"not all created: {out}")
        count = admin("SELECT count(*) FROM m2_bdj_objective_proposals", db=SCRATCH_DB)[0][0]
        return f"{len(out)} rows, created=True, total={count}"

    def duplicate_retry():
        out = persist(runner, bound, owner_user_id=OWNER, evaluation_id=EVALUATION,
                      assessment_id=ASSESSMENT, confirmation_revision=7,
                      confirmation_id=CONFIRMATION,
                      source_fingerprint=packet["source_fingerprint"],
                      prompt_version="BDJ-OBJECTIVE-3-CAND", execution_mode="SIMULATED")
        if any(r["created"] for r in out):
            raise AssertionError(f"duplicate created a row: {out}")
        count = admin("SELECT count(*) FROM m2_bdj_objective_proposals", db=SCRATCH_DB)[0][0]
        return f"created=False, ids stable, total={count}"

    def restricted_readback():
        pid = out_ids[0]
        row = read(runner, pid, OWNER)
        if row is None or row["recommendation_status"] != "MOST_SUGGESTED":
            raise AssertionError("readback missing")
        if row["review_state"] != "CANDIDATE":
            raise AssertionError("review_state not CANDIDATE")
        if row["source_refs"][0]["item_key"] != "M2V1-08":
            raise AssertionError("source ref lost")
        who = runner.connect().execute(text("select current_user")).scalar_one()
        return f"read as {who}, state={row['review_state']}, refs={len(row['source_refs'])}"

    def source_integrity():
        bad = {"contract_version": CONTRACT_VERSION,
               "recommendations": [dict(payload["recommendations"][1],
                                        source_refs=payload["recommendations"][0]["source_refs"])]}
        try:
            validate_objective_proposal(bad, packet)
        except WorkflowHeld as exc:
            first = str(exc)
        else:
            raise AssertionError("SUGGESTED with a source ref was accepted")
        stale = build_context(packet)
        next(r for r in stale["m2_answers"] if r["item_key"] == "M2V1-08")[
            "answer_revision_id"] = str(uuid.uuid4())
        stale["packet_hash"] = source_hash({k: v for k, v in stale.items() if k != "packet_hash"})
        try:
            bind_to_business_context(proposal, context_packet=stale, context_id="ctx-p1")
        except WorkflowHeld as exc:
            second = str(exc)
        else:
            raise AssertionError("stale context accepted")
        return f"{first} / {second}"

    def cross_owner():
        pid = out_ids[0]
        if read(runner, pid, OTHER) is not None:
            raise AssertionError("other owner could read the proposal")
        if rollback_candidate(runner, pid, OTHER):
            raise AssertionError("other owner could delete the proposal")
        return "read=None, rollback refused"

    def guarded_rollback():
        pid = out_ids[0]
        admin("UPDATE m2_bdj_objective_proposals SET review_state='REVIEWED' "
              "WHERE proposal_id=%s", (pid,), db=SCRATCH_DB)
        if rollback_candidate(runner, pid, OWNER):
            raise AssertionError("reviewed row was deleted")
        admin("UPDATE m2_bdj_objective_proposals SET review_state='CANDIDATE' "
              "WHERE proposal_id=%s", (pid,), db=SCRATCH_DB)
        if not rollback_candidate(runner, pid, OWNER):
            raise AssertionError("candidate row was not removed")
        remaining = admin("SELECT count(*) FROM m2_bdj_objective_proposals",
                          db=SCRATCH_DB)[0][0]
        return f"reviewed protected, candidate removed, remaining={remaining}"

    def target_guard():
        foreign = create_engine(sqlalchemy_url("dss_uc_stage_tests"))
        try:
            migrate(foreign)
        except WorkflowHeld as exc:
            if str(exc) != "PROPOSAL_DB_TARGET_REFUSED":
                raise
            return "refused to migrate dss_uc_stage_tests"
        raise AssertionError("migrated a non-allowlisted database")

    out_ids = []
    check("1. migration applied (columns + constraints)", migration_shape)
    check("2. no approved-objective or finding tables", no_approved_objects)
    check("3. valid proposal write", valid_write)
    out_ids = [r["proposal_id"] for r in persist(
        runner, bound, owner_user_id=OWNER, evaluation_id=EVALUATION,
        assessment_id=ASSESSMENT, confirmation_revision=7, confirmation_id=CONFIRMATION,
        source_fingerprint=packet["source_fingerprint"],
        prompt_version="BDJ-OBJECTIVE-3-CAND", execution_mode="SIMULATED")]
    check("4. duplicate retry is idempotent", duplicate_retry)
    check("5. restricted-role readback", restricted_readback)
    check("6. source integrity (status/ref/context)", source_integrity)
    check("7. cross-owner refusal", cross_owner)
    check("8. guarded rollback", guarded_rollback)
    check("9. database-target guard", target_guard)

    passed = sum(1 for r in results if r["result"] == "PASS")
    evidence = {"phase": 1, "target": f"localhost:5433/{SCRATCH_DB}",
                "role": RUNNER_ROLE, "checks": results,
                "passed": passed, "total": len(results),
                "verdict": "PASS" if passed == len(results) else "FAIL"}
    out = Path(__file__).resolve().parents[2] / "deliverables/phase1/BDJ_PHASE1_EVIDENCE_20261121.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\n  %d/%d checks passed" % (passed, len(results)))
    print("  evidence:", out)
    print("  VERDICT:", evidence["verdict"])
    return 0 if evidence["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
