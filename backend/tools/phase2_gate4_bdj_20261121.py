"""Gate 4 — bind the PERSISTED BCB context to BDJ proposal generation.

The context is re-read from `m2_business_contexts` as `p1_m2_runtime` inside a
real transaction (not taken from the in-memory construction result), and its
canonical body is re-hashed before use.

Simulated provider only. No live model call. No Dss access.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase2_gate4_bdj_20261121.py
"""
import json
import os
import uuid
from pathlib import Path

TARGET_DB = "project1_workflow_tests"
PORT = 5433
BACKEND = Path(__file__).resolve().parents[1]
ASSESSMENT = uuid.UUID("d82b78ff-dad0-41d8-afa4-0205ad199a20")
CONFIRMATION = uuid.UUID("658dfcc7-75e6-4f76-b245-71678459ba60")
REVISION = 11
CONTEXT_ID = uuid.UUID("79151dfe-c411-54d9-b03c-47b19ce44ecb")
ROLE = "p1_m2_runtime"
ROLE_PW = os.environ.get("PHASE2_M2_ROLE_PW", "m2_runtime_dev_only")


def install():
    for line in (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("DATABASE_URL="):
            base = line.split("=", 1)[1].strip()
            break
    app = base.replace(":5432", f":{PORT}").rsplit("/", 1)[0] + "/" + TARGET_DB
    host = app.split("://", 1)[1].split("@", 1)[1]
    scheme = app.split("://", 1)[0]
    os.environ["DATABASE_URL"] = app
    os.environ["M2_DATABASE_URL"] = f"{scheme}://{ROLE}:{ROLE_PW}@{host}"
    os.environ["M2_EXPECTED_DATABASE"] = TARGET_DB
    os.environ["PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS"] = "1"
    return app, f"{scheme}://{ROLE}:{ROLE_PW}@{host}"


APP_URL, M2_URL = install()


def libpq(dsn):
    return dsn.replace("postgresql+psycopg2://", "postgresql://")


def main():
    import psycopg2
    from sitewise.services.business_context_v1 import source_hash
    from sitewise.project1.bdj import BDJEngine
    from sitewise.project1.rules import bdj_m2v1_ig_proposal as rules
    from sitewise.project1.objective_proposal import CONTRACT_VERSION, ObjectiveProposal

    checks = []

    def check(label, fn):
        try:
            checks.append({"check": label, "result": "PASS", "detail": str(fn())})
        except Exception as exc:
            checks.append({"check": label, "result": "FAIL",
                           "detail": f"{type(exc).__name__}: {str(exc)[:150]}"})
        print("  %-4s %-46s %s" % (checks[-1]["result"], label, str(checks[-1]["detail"])[:62]))

    admin = psycopg2.connect(libpq(APP_URL))
    admin.autocommit = True
    with admin.cursor() as cur:
        cur.execute("select owner_user_id from public.m2_assessments where id=%s", (str(ASSESSMENT),))
        owner = uuid.UUID(str(cur.fetchone()[0]))

    # 1. Read the persisted context through the restricted principal.
    c = psycopg2.connect(libpq(M2_URL))
    c.autocommit = False
    try:
        with c.cursor() as cur:
            cur.execute("select set_config('project1.actor_id', %s, true)", (str(owner),))
            cur.execute("select context_id, confirmation_id, assessment_revision, packet_hash, "
                        "canonical_body, schema_version from public.m2_business_contexts "
                        "where context_id=%s", (str(CONTEXT_ID),))
            stored = cur.fetchone()
    finally:
        c.rollback()
        c.close()
    if stored is None:
        raise SystemExit("persisted context not visible as p1_m2_runtime")
    ctx_id, conf_id, revision, packet_hash, canonical_body, schema_version = stored
    bcb_packet = json.loads(canonical_body)
    # canonical_body excludes packet_hash; the binder requires the claimed hash
    # to be present in the packet it re-hashes.
    bcb_packet["packet_hash"] = str(packet_hash)

    print("=" * 78)
    print("GATE 4 — persisted BCB context → BDJ proposals")
    print("=" * 78)
    print("context:", ctx_id, "| schema:", schema_version, "| hash:", str(packet_hash)[:12])
    print("confirmation:", conf_id, "| revision:", revision)

    def hash_recomputes():
        body = {k: v for k, v in bcb_packet.items() if k != "packet_hash"}
        if source_hash(body) != packet_hash:
            raise AssertionError("canonical body does not hash to the stored packet_hash")
        return "canonical body re-hashes to the stored packet_hash"

    def packet_scope():
        conf = bcb_packet.get("confirmation") or {}
        if str(conf.get("id")) != str(CONFIRMATION) or conf.get("status") != "CURRENT_CONFIRMED":
            raise AssertionError(f"confirmation scope: {conf.get('id')}/{conf.get('status')}")
        if len(bcb_packet.get("m2_answers") or []) != 11:
            raise AssertionError("m2_answers is not 11 items")
        return "11 m2_answers, confirmation CURRENT_CONFIRMED"

    # 2. M2 projection from the same confirmed source.
    from sqlalchemy.orm import Session
    from sqlalchemy import text
    from sitewise.db.m2_session import get_bcb_engine
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sitewise.project1.projection import M2SourceProjection
    from sitewise.project1.contracts import digest

    with Session(get_bcb_engine()) as session:
        session.execute(text("select set_config('project1.actor_id', :a, true)"), {"a": str(owner)})
        packet = M2SourceProjection(SqlModelM2Repository(session)).read(ASSESSMENT, owner, REVISION)
        packet["confirmation"] = {"confirmation_id": str(conf_id),
                                  "snapshot_digest": (bcb_packet.get("confirmation") or {}).get("digest")}
        packet["source_fingerprint"] = digest({k: v for k, v in packet.items()
                                               if k != "source_fingerprint"})
        session.rollback()
    with admin.cursor() as cur:
        cur.execute("select md5(string_agg(id::text || ':' || item_version_id::text, ',' order by id)) "
                    "from public.m2_answer_revisions where assessment_id=%s", (str(ASSESSMENT),))
        before = cur.fetchone()[0]

    def declarations():
        if len(packet["declarations"]) != 11:
            raise AssertionError(f"{len(packet['declarations'])} declarations")
        return f"11 declarations, fingerprint {packet['source_fingerprint'][:12]}"

    # 3. BDJ with a simulated provider.
    def rec(key, status="MOST_SUGGESTED"):
        d = next(x for x in packet["declarations"] if x["item_key"] == key)
        return {"recommendation_status": status,
                "problem_type": ("SOURCE_CONFIRMED_INFORMATION_GAP" if status == "MOST_SUGGESTED"
                                 else "EXPLORATORY_RESEARCH_NEED"),
                "problem": (f"The confirmed answer to {key} is {d['value']}."
                            if status == "MOST_SUGGESTED" else None),
                "research_objective": f"To investigate what {key} leaves unresolved.",
                "source_refs": ([{"item_key": key,
                                  "answer_revision_id": d["answer_revision_id"],
                                  "item_version_id": d["item_version_id"]}]
                                if status == "MOST_SUGGESTED" else []),
                "reason": "Restates the confirmed uncertainty.",
                "authority": "CANDIDATE_ONLY"}

    payload = {"contract_version": CONTRACT_VERSION,
               "recommendations": [rec("M2V1-01"), rec("M2V1-11", "SUGGESTED")]}
    runner = lambda stage, p, t, **kw: json.loads(json.dumps(payload))
    state = {}

    def execute():
        out = BDJEngine(rules, model_runner=runner).propose_objectives(
            packet, recheck_current=lambda: packet["source_fingerprint"],
            context_packet=bcb_packet, context_id=str(ctx_id))
        state["out"] = out
        if out["outcome"] != "reviewed" or len(out["proposals"]) != 2:
            reason = next((c.get("reason") for c in out["checkpoints"] if c.get("reason")), None)
            raise AssertionError(f"{out['outcome']} / {len(out['proposals'])} / reason={reason}")
        return f"reviewed, 2 proposals, ctx={out['context_id']}"

    def binding():
        out = state["out"]
        if str(out["context_packet_hash"]) != str(packet_hash):
            raise AssertionError("context hash not carried through")
        if out["findings"]:
            raise AssertionError("findings must stay empty on the objective contract")
        return "context_packet_hash matches the persisted hash, findings=[]"

    def contracts():
        statuses = [p["recommendation_status"] for p in state["out"]["proposals"]]
        if statuses != ["MOST_SUGGESTED", "SUGGESTED"]:
            raise AssertionError(statuses)
        if any(p["authority"] != "CANDIDATE_ONLY" for p in state["out"]["proposals"]):
            raise AssertionError("authority not CANDIDATE_ONLY")
        most = state["out"]["proposals"][0]
        d = next(x for x in packet["declarations"] if x["item_key"] == "M2V1-01")
        if most["source_refs"][0]["answer_revision_id"] != d["answer_revision_id"]:
            raise AssertionError("source ref does not match the confirmed answer revision")
        return "both categories, CANDIDATE_ONLY, ref matches confirmed revision"

    def zero():
        zero_payload = {"contract_version": CONTRACT_VERSION, "recommendations": []}
        out = BDJEngine(rules, model_runner=lambda s, p, t, **k: json.loads(json.dumps(zero_payload))
                        ).propose_objectives(packet, recheck_current=lambda: packet["source_fingerprint"],
                                             context_packet=bcb_packet, context_id=str(ctx_id))
        cp5 = next(x for x in out["checkpoints"] if x.get("checkpoint") == 5)
        if out["outcome"] != "reviewed" or out["proposals"]:
            raise AssertionError(out["outcome"])
        if cp5["outcome"] != "bounded_no_recommendation":
            raise AssertionError(cp5)
        return "reviewed with 0 proposals, bounded_no_recommendation"

    def wrong_context():
        bad = json.loads(json.dumps(bcb_packet))
        bad["packet_hash"] = "0" * 64
        out = BDJEngine(rules, model_runner=runner).propose_objectives(
            packet, recheck_current=lambda: packet["source_fingerprint"],
            context_packet=bad, context_id=str(ctx_id))
        if out["outcome"] != "rejected":
            raise AssertionError(out["outcome"])
        return "rejected (context hash mismatch)"

    def stale_source():
        out = BDJEngine(rules, model_runner=runner).propose_objectives(
            packet, recheck_current=lambda: "0" * 64,
            context_packet=bcb_packet, context_id=str(ctx_id))
        if out["outcome"] != "stale":
            raise AssertionError(out["outcome"])
        cp5 = next(x for x in out["checkpoints"] if x.get("checkpoint") == 5)
        if cp5.get("outcome") != "stale":
            raise AssertionError(f"checkpoint 5 = {cp5}")
        return "stale (checkpoint 5 = stale), proposals discarded"

    def immutability():
        # Deliberately RLS-free: an RLS-bound read can return zero rows and be
        # mistaken for a modification. The admin snapshot is the ground truth.
        with admin.cursor() as cur:
            cur.execute("select md5(string_agg(id::text || ':' || item_version_id::text, ',' order by id)) "
                        "from public.m2_answer_revisions where assessment_id=%s", (str(ASSESSMENT),))
            after = cur.fetchone()[0]
            cur.execute("select packet_hash from public.m2_business_contexts where context_id=%s",
                        (str(CONTEXT_ID),))
            ctx_after = cur.fetchone()[0]
            cur.execute("select count(*) from public.m2_answer_revisions where assessment_id=%s",
                        (str(ASSESSMENT),))
            n = cur.fetchone()[0]
        if after != before:
            raise AssertionError("M2 answer revisions changed")
        if str(ctx_after) != str(packet_hash):
            raise AssertionError("persisted context changed")
        return f"{n} answer revisions + context hash unchanged (admin snapshot)"

    check("1. canonical body re-hashes", hash_recomputes)
    check("2. packet scope: confirmation + 11 answers", packet_scope)
    check("3. M2 projection declarations", declarations)
    check("4. propose_objectives on persisted context", execute)
    check("5. context hash carried through", binding)
    check("6. both categories, candidate-only", contracts)
    check("7. zero recommendations bounded", zero)
    check("8. wrong context hash rejected", wrong_context)
    check("9. stale source rejected", stale_source)
    check("10. M2 + context unchanged", immutability)

    passed = sum(1 for c in checks if c["result"] == "PASS")
    evidence = {"gate": 4, "target": f"{TARGET_DB}@{PORT}",
                "context_id": str(ctx_id), "packet_hash": str(packet_hash),
                "confirmation": str(CONFIRMATION), "revision": revision,
                "proposals": len((state.get("out") or {}).get("proposals") or []),
                "checks": checks, "passed": passed, "total": len(checks),
                "verdict": "PASS" if passed == len(checks) else "FAIL"}
    out_path = BACKEND.parent / "deliverables/phase2/BDJ_GATE4_BINDING_20261121.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\n  %d/%d checks passed" % (passed, len(checks)))
    print("  evidence:", out_path)
    print("  VERDICT:", evidence["verdict"])
    return 0 if evidence["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
