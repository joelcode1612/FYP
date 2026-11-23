"""Phase 2 — governed engine test for propose_objectives (simulated provider).

Covers the engine contract only. No FastAPI route, no persistence, no live call.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase2_engine_test_20261121.py
"""
import json
import uuid
from pathlib import Path

from sitewise.project1.bdj import BDJEngine
from sitewise.project1.contracts import digest
from sitewise.project1.objective_proposal import CONTRACT_VERSION, ObjectiveProposal
from sitewise.project1.projection import verify_projection
from sitewise.project1.rules import bdj_m2v1_ig_proposal as rules
from sitewise.services.business_context_v1 import source_hash

DEFINITION = Path(__file__).resolve().parents[1] / "src/sitewise/instruments/m2v1_20261114/definition.json"
ANSWERS = {"M2V1-01": "UNDECIDED", "M2V1-02": "DINE_IN",
           "M2V1-03": ["COFFEE", "BAKED_GOODS"], "M2V1-04": ["STUDENTS", "OFFICE_WORKERS"],
           "M2V1-05": "STUDENTS", "M2V1-06": "CONVENIENCE", "M2V1-07": "STUDY_WORK",
           "M2V1-08": "UNKNOWN", "M2V1-09": ["CONCEPT_INTEREST"],
           "M2V1-10": "CONCEPT_INTEREST", "M2V1-11": "UNSURE"}


def build():
    definition = json.loads(DEFINITION.read_text(encoding="utf-8"))
    items = sorted([i for i in definition["items"] if i["item_key"].startswith("M2V1-")],
                   key=lambda i: i["item_key"])
    assert len(items) == 11
    tag = definition["version_tag"]
    decls = [{"item_key": i["item_key"], "question": i["question_text"],
              "answer_state": "ANSWERED",
              "answer_revision_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "p2a|" + i["item_key"])),
              "item_version_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "p2i|" + i["item_key"])),
              "value": ANSWERS[i["item_key"]]} for i in items]
    packet = {"schema_version": "project1-m2-projection/1-candidate",
              "instrument_version": tag,
              "instrument_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "p2inst")),
              "assessment_id": str(uuid.uuid4()), "assessment_revision": 7, "confirmed": True,
              "confirmation": {"confirmation_id": str(uuid.uuid4()),
                               "snapshot_digest": "d" * 64},
              "declarations": decls}
    packet["source_fingerprint"] = digest(packet)
    ctx = {"schema_version": "persisted-business-context/1", "context_version": "1.1",
           "confirmation": {"id": packet["confirmation"]["confirmation_id"], "revision": 7,
                            "digest": "d" * 64, "status": "CURRENT_CONFIRMED"},
           "m2_answers": [{k: d[k] for k in ("item_key", "answer_revision_id",
                                             "item_version_id", "answer_state", "value")}
                          for d in decls],
           "permissions": {"report_admission": False, "report_release": False,
                           "qj_execution": False, "qg_execution": False}}
    ctx["packet_hash"] = source_hash(ctx)
    return packet, ctx


def rec(packet, key, status="MOST_SUGGESTED", rule_id=None):
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


def runner(payload):
    return lambda stage, packet, output_type, **kw: json.loads(json.dumps(payload))


def main():
    results = []

    def check(label, fn):
        try:
            results.append({"check": label, "result": "PASS", "detail": str(fn())})
        except Exception as exc:
            results.append({"check": label, "result": "FAIL",
                            "detail": f"{type(exc).__name__}: {str(exc)[:140]}"})
        print("  %-4s %-48s %s" % (results[-1]["result"], label,
                                   str(results[-1]["detail"])[:64]))

    packet, ctx = build()
    verify_projection(packet)
    fp = packet["source_fingerprint"]

    def two_proposals():
        engine = BDJEngine(rules, model_runner=runner(
            {"contract_version": CONTRACT_VERSION,
             "recommendations": [rec(packet, "M2V1-08"), rec(packet, "M2V1-11", "SUGGESTED")]}))
        out = engine.propose_objectives(packet, recheck_current=lambda: fp,
                                        context_packet=ctx, context_id="ctx-p2")
        if out["outcome"] != "reviewed" or len(out["proposals"]) != 2:
            raise AssertionError(f"{out['outcome']} / {len(out['proposals'])}")
        if out["findings"] or out["contract_version"] != "bdj-objective-proposal/1":
            raise AssertionError("contract mismatch")
        return f"reviewed, 2 proposals, 0 findings, ctx={out['context_id']}"

    def zero_recommendations():
        engine = BDJEngine(rules, model_runner=runner(
            {"contract_version": CONTRACT_VERSION, "recommendations": []}))
        out = engine.propose_objectives(packet, recheck_current=lambda: fp,
                                        context_packet=ctx, context_id="ctx-p2")
        cp5 = next(c for c in out["checkpoints"] if c.get("checkpoint") == 5)
        if out["outcome"] != "reviewed" or out["proposals"]:
            raise AssertionError(f"{out['outcome']} / {len(out['proposals'])}")
        if cp5["outcome"] != "bounded_no_recommendation":
            raise AssertionError(cp5)
        return "reviewed, 0 proposals, bounded_no_recommendation"

    def stale_source():
        engine = BDJEngine(rules, model_runner=runner(
            {"contract_version": CONTRACT_VERSION,
             "recommendations": [rec(packet, "M2V1-08")]}))
        out = engine.propose_objectives(packet, recheck_current=lambda: "0" * 64,
                                        context_packet=ctx, context_id="ctx-p2")
        if out["outcome"] != "stale" or out["proposals"]:
            raise AssertionError(out["outcome"])
        return "stale, proposals discarded"

    def invalid_rule():
        bad = {"contract_version": CONTRACT_VERSION,
               "recommendations": [dict(rec(packet, "M2V1-08"), rule_id="BDJ-001")]}
        engine = BDJEngine(rules, model_runner=runner(bad))
        out = engine.propose_objectives(packet, recheck_current=lambda: fp,
                                        context_packet=ctx, context_id="ctx-p2")
        if out["outcome"] != "rejected" or out["proposals"]:
            raise AssertionError(out["outcome"])
        return "rejected, no proposals"

    def no_model():
        out = BDJEngine(rules).propose_objectives(packet, recheck_current=lambda: fp,
                                                  context_packet=ctx, context_id="ctx-p2")
        reason = next((c.get("reason") for c in out["checkpoints"] if c.get("reason")), None)
        if out["outcome"] != "held" or reason != "BDJ_OBJECTIVE_MODEL_REQUIRED":
            raise AssertionError(f"{out['outcome']} / {reason}")
        return "held, BDJ_OBJECTIVE_MODEL_REQUIRED"

    def unbound_context():
        tampered = json.loads(json.dumps(ctx))
        next(row for row in tampered["m2_answers"] if row["item_key"] == "M2V1-08")[
            "answer_revision_id"] = str(uuid.uuid4())
        tampered["packet_hash"] = source_hash({k: v for k, v in tampered.items()
                                               if k != "packet_hash"})
        engine = BDJEngine(rules, model_runner=runner(
            {"contract_version": CONTRACT_VERSION,
             "recommendations": [rec(packet, "M2V1-08")]}))
        out = engine.propose_objectives(packet, recheck_current=lambda: fp,
                                        context_packet=tampered, context_id="ctx-p2")
        if out["outcome"] != "rejected":
            raise AssertionError(out["outcome"])
        return "rejected before persistence (context source mismatch)"

    print("=" * 78)
    print("PHASE 2 — propose_objectives (simulated provider, 11-item source)")
    print("=" * 78)
    print("items:", len(packet["declarations"]), "| fp:", fp[:16], "…")
    check("1. two proposals accepted", two_proposals)
    check("2. zero recommendations handled", zero_recommendations)
    check("3. stale source discards proposals", stale_source)
    check("4. invented rule rejected", invalid_rule)
    check("5. no model → held", no_model)
    check("6. context mismatch rejected", unbound_context)

    passed = sum(1 for r in results if r["result"] == "PASS")
    evidence = {"phase": 2, "scope": "engine only", "provider": "simulated",
                "items": len(packet["declarations"]), "checks": results,
                "passed": passed, "total": len(results),
                "verdict": "PASS" if passed == len(results) else "FAIL",
                "not_covered": ["FastAPI route", "persistence wiring",
                                "authenticated readback", "live provider"]}
    out = Path(__file__).resolve().parents[2] / "deliverables/phase2/BDJ_PHASE2_ENGINE_EVIDENCE_20261121.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\n  %d/%d checks passed" % (passed, len(results)))
    print("  evidence:", out)
    print("  VERDICT:", evidence["verdict"], "(engine only; Phase 2 NOT complete)")
    return 0 if evidence["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
