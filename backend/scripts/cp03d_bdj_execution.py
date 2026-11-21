"""CP-03D: one authorized, ledger-backed cloud BDJ execution + independent audit.

Reuses ModelRunner, PostgresAttemptLedger, TokenHarbor and the adopted BDJ prompt.
No second model execution service. One bounded synthetic attempt only.
"""
import json
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sqlalchemy import create_engine, text  # noqa: E402
from sqlmodel import Session  # noqa: E402

from sitewise.core.config import settings  # noqa: E402
from sitewise.project1.contracts import BDJOutput, WorkflowHeld, digest  # noqa: E402
from sitewise.project1.disclosure import SyntheticBdjAuthorization, SyntheticBdjDisclosure  # noqa: E402
from sitewise.project1.ledger import PostgresAttemptLedger  # noqa: E402
from sitewise.project1.prompts import PROMPTS  # noqa: E402
from sitewise.project1.projection import M2SourceProjection  # noqa: E402
from sitewise.project1.provider import ENDPOINT, MODEL, ModelRunner, TokenHarbor  # noqa: E402
from sitewise.repositories.m2_repository import SqlModelM2Repository  # noqa: E402

ACTOR = uuid.UUID("11111111-1111-4111-8111-111111111111")  # synthetic test identity
ASSESSMENT = uuid.UUID("da90aa4a-f9cf-4145-9acf-7de36c9d6fad")
REV = 12

results = {}


def check(name, ok, detail=""):
    results[name] = (ok, detail)
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")


def build_packet():
    engine = create_engine(settings.m2_database_url.get_secret_value(), hide_parameters=True)
    with Session(engine) as s:
        s.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {"a": str(ACTOR)})
        return M2SourceProjection(SqlModelM2Repository(s)).read(ASSESSMENT, ACTOR, REV)


def provision_run(engine, run_id, source_fp, policy_fp, work_id):
    with engine.connect() as c:
        c.execute(text("SET LOCAL ROLE p1ai_runtime"))
        c.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {"a": str(ACTOR)})
        c.execute(text(
            "INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,assessment_revision,"
            "source_fingerprint,policy_fingerprint,work_identity) VALUES (:r,:o,:a,:rev,:s,:p,:w)"),
            {"r": run_id, "o": ACTOR, "a": ASSESSMENT, "rev": REV, "s": source_fp, "p": policy_fp, "w": work_id})
        c.commit()


def audit_readback(run_id):
    url = settings.project1_audit_database_url.get_secret_value()
    if not url:
        return None
    engine = create_engine(url, hide_parameters=True)
    with engine.connect() as c:
        c.execute(text("SET LOCAL ROLE p1ai_audit"))
        cu = c.execute(text("SELECT current_user")).scalar()
        rows = c.execute(text(
            "SELECT a.attempt_no,a.stage,a.prompt_version,a.prompt_hash,a.request_hash,"
            "r.outcome,r.output_digest FROM project1_ai.attempts a "
            "LEFT JOIN project1_ai.attempt_receipts r ON r.run_id=a.run_id AND r.attempt_no=a.attempt_no "
            "WHERE a.run_id=:id ORDER BY a.attempt_no"), {"id": run_id}).mappings().all()
    return cu, [dict(x) for x in rows]


def main() -> int:
    # 1. Build source packet.
    packet = build_packet()
    check("packet_built", len(packet["declarations"]) > 0,
          f"declarations={len(packet['declarations'])} fp={packet['source_fingerprint'][:12]}")
    check("synthetic_actor", str(ACTOR).startswith("11111111-1111-4111-8111"),
          "source is the synthetic non-human test identity")

    runtime_engine = create_engine(settings.project1_runtime_database_url.get_secret_value(),
                                   hide_parameters=True)
    policy_fp = PROMPTS["BDJ"].fingerprint
    run_id = uuid.uuid4()
    work_id = uuid.uuid4().hex + uuid.uuid4().hex[:32]
    provision_run(runtime_engine, run_id, packet["source_fingerprint"], policy_fp, work_id)
    check("run_provisioned", True, f"run_id={run_id}")

    # 2. Explicit synthetic-only authorization (source/destination/model/budget).
    auth = SyntheticBdjAuthorization(
        run_id=str(run_id), source_fingerprint=packet["source_fingerprint"],
        operator_receipt="CP-03D synthetic non-human BDJ diagnostic; one attempt; TokenHarbor only.")
    disclosure = SyntheticBdjDisclosure(auth)

    # 3. Fail-closed adapter checks (no dispatch).
    def expect_hold(name, fn, code):
        try:
            fn(); check(name, False, "did not hold")
        except WorkflowHeld as exc:
            check(name, str(exc) == code, f"code={exc}")

    expect_hold("disclosure_source_mismatch",
                lambda: SyntheticBdjDisclosure(SyntheticBdjAuthorization(str(run_id), "0" * 64, "receipt-1234"))
                .require_current("BDJ", packet, ENDPOINT, MODEL), "DISCLOSURE_SOURCE_MISMATCH")
    expect_hold("disclosure_model_mismatch",
                lambda: SyntheticBdjDisclosure(SyntheticBdjAuthorization(str(run_id), packet["source_fingerprint"], "receipt-1234", model="other-model"))
                .require_current("BDJ", packet, ENDPOINT, MODEL), "DISCLOSURE_MODEL_MISMATCH")
    expect_hold("disclosure_stage_not_authorized",
                lambda: disclosure.require_current("QJ", packet, ENDPOINT, MODEL), "DISCLOSURE_STAGE_NOT_AUTHORIZED")
    expect_hold("disclosure_real_data_refused",
                lambda: SyntheticBdjDisclosure(SyntheticBdjAuthorization(str(run_id), packet["source_fingerprint"], "receipt-1234", data_class="REAL_PERSONAL"))
                .require_current("BDJ", packet, ENDPOINT, MODEL), "DISCLOSURE_REAL_DATA_NOT_AUTHORIZED")

    # 4. Execute exactly one governed call.
    provider = TokenHarbor(settings.tokenharbor_api_key, enabled=True,
                           structured_mode=settings.tokenharbor_structured_mode, timeout=30)
    ledger = PostgresAttemptLedger(runtime_engine, ACTOR, run_id)
    runner = ModelRunner(provider, ledger, PROMPTS, disclosure=disclosure)
    output = None
    try:
        output = runner("BDJ", packet, BDJOutput)
        check("model_runner_returned", True, f"issues={len(output.get('issues', []))}")
    except WorkflowHeld as exc:
        check("model_runner_returned", False, f"held code={exc}")

    # 5. Source fidelity: every finding source_ref must match a real declaration.
    if output is not None:
        decls = {(d["item_key"], d["answer_revision_id"], d["item_version_id"]) for d in packet["declarations"]}
        bad = []
        for issue in output.get("issues", []):
            for ref in issue.get("source_refs", []):
                if (ref["item_key"], ref["answer_revision_id"], ref["item_version_id"]) not in decls:
                    bad.append(ref)
        check("source_fidelity", not bad, f"bad_refs={len(bad)}")
        check("structured_validation", isinstance(output, dict) and "issues" in output and "overall_note" in output,
              "validated against BDJOutput")

    # 6. Second reserve for same stage must fail closed (no second dispatch).
    try:
        ledger.reserve("BDJ", "x", "c" * 64, "d" * 64)
        check("single_attempt_enforced", False, "second reserve allowed")
    except WorkflowHeld as exc:
        check("single_attempt_enforced", str(exc) == "MODEL_STAGE_ALREADY_RESERVED", f"code={exc}")

    # 7. Independent audit read-back via p1ai_audit.
    rb = audit_readback(run_id)
    if rb is None:
        check("audit_readback", False, "PROJECT1_AUDIT_DATABASE_URL missing")
    else:
        cu, rows = rb
        ok = cu == "p1ai_audit" and len(rows) == 1 and rows[0]["outcome"] in {"returned", "rejected", "unknown_outcome"}
        check("audit_readback", ok, f"identity={cu} rows={len(rows)} outcome={rows[0]['outcome'] if rows else None}")

    # 8. Persist sanitized output record (evidence; no raw source text stored).
    if output is not None:
        out_dir = Path(__file__).resolve().parents[1] / "backups" / f"cp03d_{run_id}"
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "bdj_output.json").write_text(json.dumps({
            "run_id": str(run_id), "assessment_id": str(ASSESSMENT), "assessment_revision": REV,
            "source_fingerprint": packet["source_fingerprint"], "policy_fingerprint": policy_fp,
            "model_requested": MODEL, "endpoint": ENDPOINT,
            "output": output, "output_digest": digest(output),
        }, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"evidence={out_dir}")

    hard = [k for k, (ok, _) in results.items() if not ok and k != "model_runner_returned"]
    verdict = "PASS" if (not hard and results.get("model_runner_returned", (False,))[0]) else "FAIL"
    print(f"VERDICT={verdict}")
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
