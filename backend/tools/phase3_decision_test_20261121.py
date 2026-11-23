"""Phase 3 decision-layer verification — approve / reject on disposable PostgreSQL.

Scope: the decision contract only. Phase 3 is NOT complete: there is no engine,
no route and no Jaspr end-to-end run yet, so this proves the persistence and
authorisation rules the UI will call.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase3_decision_test_20261121.py
"""
import json
import uuid
from pathlib import Path

import psycopg2
from sqlalchemy import create_engine, text

from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.objective_adapter import (
    admissible_for_qg, decide, migrate, migrate_decisions, persist, read_decision,
)
from sitewise.project1.objective_proposal import (
    CONTRACT_VERSION, bind_to_business_context, validate_objective_proposal,
)
from sitewise.services.business_context_v1 import source_hash

def _admin_url():
    env_path = Path(__file__).resolve().parents[1] / ".env"
    for line in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("DATABASE_URL="):
            url = line.split("=", 1)[1].strip().replace("postgresql+psycopg2://", "postgresql://")
            return url.rsplit("/", 1)[0].replace(":5432", ":5433") + "/postgres"
    raise SystemExit("DATABASE_URL missing")


ADMIN = _admin_url()
DB = "p1_phase1_scratch"
ROLE = "p1_phase1_runner"
PW = "phase1_dev_only"
ADMIN_URL = ADMIN.replace("postgresql://", "postgresql+psycopg2://", 1).rsplit("/", 1)[0] + "/" + DB
RUNNER_URL = f"postgresql+psycopg2://{ROLE}:{PW}@localhost:5433/{DB}"

OWNER = uuid.uuid4()
OTHER = uuid.uuid4()
ASSESSMENT = uuid.uuid4()
CONFIRMATION = uuid.uuid4()
EVALUATION = uuid.uuid4()


def admin(sql, params=None):
    conn = psycopg2.connect(ADMIN.rsplit("/", 1)[0] + "/" + DB)
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params or ())
            return cur.fetchall() if cur.description else None
    finally:
        conn.close()


def build():
    values = {"M2V1-01": "UNDECIDED", "M2V1-08": "UNKNOWN", "M2V1-11": "UNSURE"}
    decls = [{"item_key": k, "question": "Question for " + k, "answer_state": "ANSWERED",
              "answer_revision_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "p3a|" + k)),
              "item_version_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "p3i|" + k)),
              "value": v} for k, v in sorted(values.items())]
    packet = {"schema_version": "project1-m2-projection/1-candidate",
              "instrument_version": "M2V1-20261114-1",
              "instrument_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "p3inst")),
              "assessment_id": str(ASSESSMENT), "assessment_revision": 7, "confirmed": True,
              "confirmation": {"confirmation_id": str(CONFIRMATION),
                               "snapshot_digest": "c" * 64},
              "declarations": decls}
    packet["source_fingerprint"] = digest(packet)
    ctx = {"schema_version": "persisted-business-context/1", "context_version": "1.1",
           "confirmation": {"id": str(CONFIRMATION), "revision": 7,
                            "digest": "c" * 64, "status": "CURRENT_CONFIRMED"},
           "m2_answers": [{k: d[k] for k in ("item_key", "answer_revision_id",
                                             "item_version_id", "answer_state", "value")}
                          for d in decls],
           "permissions": {"report_admission": False, "report_release": False,
                           "qj_execution": False, "qg_execution": False}}
    ctx["packet_hash"] = source_hash(ctx)
    return packet, ctx


def payload(packet):
    def rec(key, status):
        row = next(d for d in packet["declarations"] if d["item_key"] == key)
        return {"recommendation_status": status,
                "problem_type": ("SOURCE_CONFIRMED_INFORMATION_GAP"
                                 if status == "MOST_SUGGESTED"
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
            "recommendations": [rec("M2V1-08", "MOST_SUGGESTED"),
                                rec("M2V1-11", "SUGGESTED"),
                                rec("M2V1-01", "MOST_SUGGESTED")]}


def main():
    results = []

    def check(label, fn):
        try:
            results.append({"check": label, "result": "PASS", "detail": str(fn())})
        except Exception as exc:
            results.append({"check": label, "result": "FAIL",
                            "detail": f"{type(exc).__name__}: {str(exc)[:160]}"})
        print("  %-4s %-50s %s" % (results[-1]["result"], label,
                                   str(results[-1]["detail"])[:70]))

    admin_engine = create_engine(ADMIN_URL)
    migrate(admin_engine)
    migrate_decisions(admin_engine)
    admin(f"GRANT USAGE ON SCHEMA public TO {ROLE}; "
          f"GRANT SELECT, INSERT, UPDATE, DELETE ON public.m2_bdj_objective_proposals TO {ROLE}; "
          f"GRANT SELECT, INSERT ON public.m2_bdj_objective_decisions TO {ROLE};")
    runner = create_engine(RUNNER_URL)

    packet, ctx = build()
    bound = bind_to_business_context(
        validate_objective_proposal(payload(packet), packet),
        context_packet=ctx, context_id="ctx-p3")
    ids = [r["proposal_id"] for r in persist(
        runner, bound, owner_user_id=OWNER, evaluation_id=EVALUATION,
        assessment_id=ASSESSMENT, confirmation_revision=7, confirmation_id=CONFIRMATION,
        source_fingerprint=packet["source_fingerprint"],
        prompt_version="BDJ-OBJECTIVE-3-CAND", execution_mode="SIMULATED")]
    p_approve, p_reject, p_pending = ids
    fp, ctx_hash = packet["source_fingerprint"], bound.context_packet_hash

    def migration_shape():
        cols = admin("SELECT count(*) FROM information_schema.columns "
                     "WHERE table_name='m2_bdj_objective_decisions'")[0][0]
        uniq = admin("SELECT count(*) FROM pg_constraint c JOIN pg_class t ON c.conrelid=t.oid "
                     "WHERE t.relname='m2_bdj_objective_decisions' AND c.contype='u'")[0][0]
        state_check = admin("SELECT pg_get_constraintdef(oid) FROM pg_constraint "
                            "WHERE conname='ck_proposal_review_state'")[0][0]
        if cols < 9 or uniq < 1 or "APPROVED" not in state_check:
            raise AssertionError(f"cols={cols} uniq={uniq} check={state_check[:40]}")
        return f"{cols} columns, {uniq} unique, review_state allows APPROVED"

    def approve():
        out = decide(runner, p_approve, actor_id=OWNER, decision="APPROVED",
                     source_fingerprint=fp, context_packet_hash=ctx_hash,
                     note="Objective accepted for QJ")
        if not out["created"]:
            raise AssertionError("first approval not created")
        row = read_decision(runner, p_approve, OWNER)
        state = admin("SELECT review_state FROM m2_bdj_objective_proposals "
                      "WHERE proposal_id=%s", (p_approve,))[0][0]
        if row["decision"] != "APPROVED" or row["decided_by"] != OWNER or state != "APPROVED":
            raise AssertionError(f"row={row} state={state}")
        return f"decision=APPROVED, actor recorded, review_state={state}"

    def approve_retry():
        out = decide(runner, p_approve, actor_id=OWNER, decision="APPROVED",
                     source_fingerprint=fp, context_packet_hash=ctx_hash)
        n = admin("SELECT count(*) FROM m2_bdj_objective_decisions WHERE proposal_id=%s",
                  (p_approve,))[0][0]
        if out["created"] or n != 1:
            raise AssertionError(f"created={out['created']} rows={n}")
        return f"created=False, decision rows={n}"

    def reject_separate():
        out = decide(runner, p_reject, actor_id=OWNER, decision="REJECTED",
                     source_fingerprint=fp, context_packet_hash=ctx_hash,
                     note="Not the priority now")
        proposal_exists = admin("SELECT count(*) FROM m2_bdj_objective_proposals "
                                "WHERE proposal_id=%s", (p_reject,))[0][0]
        state = admin("SELECT review_state FROM m2_bdj_objective_proposals "
                      "WHERE proposal_id=%s", (p_reject,))[0][0]
        if not out["created"] or proposal_exists != 1 or state != "REJECTED":
            raise AssertionError(f"created={out['created']} exists={proposal_exists} state={state}")
        return "decision=REJECTED, proposal retained, review_state=REJECTED"

    def reject_retry():
        out = decide(runner, p_reject, actor_id=OWNER, decision="REJECTED",
                     source_fingerprint=fp, context_packet_hash=ctx_hash)
        n = admin("SELECT count(*) FROM m2_bdj_objective_decisions WHERE proposal_id=%s",
                  (p_reject,))[0][0]
        if out["created"] or n != 1:
            raise AssertionError(f"created={out['created']} rows={n}")
        return f"created=False, decision rows={n}"

    def flip_refused():
        try:
            decide(runner, p_approve, actor_id=OWNER, decision="REJECTED",
                   source_fingerprint=fp, context_packet_hash=ctx_hash)
        except WorkflowHeld as exc:
            if str(exc) != "PROPOSAL_ALREADY_DECIDED":
                raise
            return "approve→reject refused (PROPOSAL_ALREADY_DECIDED)"
        raise AssertionError("a second, different decision was accepted")

    def cross_owner():
        try:
            decide(runner, p_pending, actor_id=OTHER, decision="APPROVED",
                   source_fingerprint=fp, context_packet_hash=ctx_hash)
        except WorkflowHeld as exc:
            if str(exc) != "PROPOSAL_DECISION_FORBIDDEN":
                raise
        else:
            raise AssertionError("another owner could decide")
        n = admin("SELECT count(*) FROM m2_bdj_objective_decisions WHERE proposal_id=%s",
                  (p_pending,))[0][0]
        if n != 0:
            raise AssertionError("row written by an unauthorised actor")
        return "refused, no decision row, proposal still pending"

    def stale_refused():
        try:
            decide(runner, p_pending, actor_id=OWNER, decision="APPROVED",
                   source_fingerprint="0" * 64, context_packet_hash=ctx_hash)
        except WorkflowHeld as exc:
            if str(exc) != "PROPOSAL_DECISION_STALE":
                raise
            return "refused (PROPOSAL_DECISION_STALE), no row"
        raise AssertionError("stale fingerprint was accepted")

    def qg_gate():
        ok_a, why_a = admissible_for_qg(runner, p_approve, source_fingerprint=fp)
        ok_r, why_r = admissible_for_qg(runner, p_reject, source_fingerprint=fp)
        ok_p, why_p = admissible_for_qg(runner, p_pending, source_fingerprint=fp)
        ok_s, why_s = admissible_for_qg(runner, p_approve, source_fingerprint="0" * 64)
        if not (ok_a and not ok_r and not ok_p and not ok_s):
            raise AssertionError(f"{ok_a}/{ok_r}/{ok_p}/{ok_s}")
        return f"approved={why_a}, rejected={why_r}, pending={why_p}, stale={why_s}"

    check("1. decision migration applied", migration_shape)
    check("2. approve persists with actor and timestamp", approve)
    check("3. duplicate approve is idempotent", approve_retry)
    check("4. reject persists without deleting proposal", reject_separate)
    check("5. duplicate reject is idempotent", reject_retry)
    check("6. contradictory second decision refused", flip_refused)
    check("7. unauthorised actor refused", cross_owner)
    check("8. stale source refused", stale_refused)
    check("9. QG gate admits only approved+current", qg_gate)

    passed = sum(1 for r in results if r["result"] == "PASS")
    evidence = {"phase": "3-decision-layer", "phase3_complete": False,
                "target": f"localhost:5433/{DB}", "checks": results,
                "passed": passed, "total": len(results),
                "verdict": "PASS" if passed == len(results) else "FAIL",
                "not_covered": ["engine propose_objectives", "FastAPI route",
                                "Jaspr end-to-end approve/reject",
                                "objective-admission adapter for M2_UNCERTAINTY_LINK_REQUIRED"]}
    out = Path(__file__).resolve().parents[2] / "deliverables/phase3/BDJ_PHASE3_DECISION_EVIDENCE_20261121.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\n  %d/%d checks passed" % (passed, len(results)))
    print("  evidence:", out)
    print("  VERDICT:", evidence["verdict"], "(decision layer only; Phase 3 NOT complete)")
    return 0 if evidence["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
