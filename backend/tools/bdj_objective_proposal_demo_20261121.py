"""Offline harness for the new BDJ objective-proposal contract (v1).

Run:
    .venv/Scripts/python.exe tools/bdj_objective_proposal_demo_20261121.py

No database, no network, no provider call. The "model" is a fixture: this proves
the contract, the prompt and the validator, not a live model judgement.
"""
import json
import uuid

from sitewise.project1.contracts import digest
from sitewise.project1.objective_proposal import (
    CONTRACT_VERSION, ObjectiveProposal, bind_to_business_context,
    validate_objective_proposal,
)
from sitewise.project1.prompts import PROMPTS
from sitewise.services.business_context_v1 import source_hash


def build_packet():
    def decl(key, question, value):
        return {"item_key": key, "question": question, "answer_state": "ANSWERED",
                "answer_revision_id": str(uuid.uuid4()),
                "item_version_id": str(uuid.uuid4()), "value": value}

    packet = {
        "schema_version": "project1-m2-projection/1-candidate",
        "instrument_version": "M2V1-20261114-1",
        "instrument_id": str(uuid.uuid4()),
        "assessment_id": str(uuid.uuid4()),
        "assessment_revision": 7,
        "confirmed": True,
        "declarations": [
            decl("M2V1-01", "Which area are you currently considering for your proposed cafe?", "UNDECIDED"),
            decl("M2V1-02", "How do you currently plan to serve customers?", "DINE_IN"),
            decl("M2V1-03", "Which product categories do you currently intend to offer?", ["COFFEE", "BAKED_GOODS"]),
            decl("M2V1-04", "Which groups of customers do you currently intend to serve?", ["STUDENTS", "OFFICE_WORKERS"]),
            decl("M2V1-05", "Among the customer groups you selected, which one is your primary intended group?", "STUDENTS"),
            decl("M2V1-06", "Which aspect do you currently plan to emphasize most in your cafe concept?", "CONVENIENCE"),
            decl("M2V1-07", "Which customer occasion do you mainly intend your cafe concept to support?", "STUDY_WORK"),
            decl("M2V1-08", "Which sources of information have you used to form your current expectations?", "UNKNOWN"),
            decl("M2V1-09", "Which aspects of your proposed cafe would you like to investigate with customers?", ["CONCEPT_INTEREST"]),
            decl("M2V1-10", "Which selected topic is most important for you to investigate first?", "CONCEPT_INTEREST"),
            decl("M2V1-11", "Which statement best describes your current position regarding this research?", "UNSURE"),
        ],
    }
    packet["source_fingerprint"] = digest(packet)
    return packet


def build_context(packet):
    """Minimal stand-in for BusinessContextBuilderV1's packet shape."""
    ctx = {
        "schema_version": "persisted-business-context/1",
        "context_version": "1.1",
        "confirmation": {"id": str(uuid.uuid4()),
                         "revision": packet["assessment_revision"],
                         "digest": "b" * 64, "status": "CURRENT_CONFIRMED"},
        "m2_answers": [{k: d[k] for k in ("item_key", "answer_revision_id",
                                          "item_version_id", "answer_state", "value")}
                       for d in packet["declarations"]],
        "permissions": {"report_admission": False, "report_release": False,
                        "qj_execution": False, "qg_execution": False},
    }
    ctx["packet_hash"] = source_hash(ctx)
    return ctx


def most(packet, *, ref_item="M2V1-08", objective=None, problem="Customer information "
         "availability is unknown.", revision=None, version=None):
    source = next(d for d in packet["declarations"] if d["item_key"] == ref_item)
    return {
        "contract_version": CONTRACT_VERSION,
        "recommendations": [{
            "recommendation_status": "MOST_SUGGESTED",
            "problem_type": "SOURCE_CONFIRMED_INFORMATION_GAP",
            "problem": problem,
            "research_objective": objective or (
                "To investigate prospective customers' stated preferences relevant to the "
                "proposed cafe concept."),
            "source_refs": [{"item_key": ref_item,
                             "answer_revision_id": revision or source["answer_revision_id"],
                             "item_version_id": version or source["item_version_id"]}],
            "reason": "The declared evidence inventory is unknown.",
            "authority": "CANDIDATE_ONLY"}]}


def suggested(packet, *, refs=None, problem=None, objective=None):
    return {
        "contract_version": CONTRACT_VERSION,
        "recommendations": [{
            "recommendation_status": "SUGGESTED",
            "problem_type": "EXPLORATORY_RESEARCH_NEED",
            "problem": problem,
            "research_objective": objective or (
                "To explore the factors that influence prospective customers' cafe "
                "selection preferences."),
            "source_refs": refs or [],
            "reason": "Could provide supplementary context; no confirmed M2 answer "
                      "establishes that this is an existing problem.",
            "authority": "CANDIDATE_ONLY"}]}


def run(label, packet, payload, expect):
    try:
        out = validate_objective_proposal(payload, packet)
        actual = "ACCEPT"
        detail = "%d recommendation(s): %s" % (
            len(out.recommendations),
            [r.recommendation_status for r in out.recommendations])
    except Exception as exc:
        actual = type(exc).__name__ if not exc.__class__.__name__ == "WorkflowHeld" else str(exc)
        detail = actual
    ok = actual == expect
    print("  %-4s %-46s expect=%-32s got=%s" % ("PASS" if ok else "FAIL", label, expect, actual))
    return ok, detail


def main():
    packet = build_packet()
    prompt = PROMPTS["BDJ_OBJECTIVE"]
    messages = prompt.messages(packet, ObjectiveProposal.model_json_schema())

    print("=" * 78)
    print("1. NEW PROMPT  version=%s  fingerprint=%s" % (prompt.version, prompt.fingerprint[:12]))
    print("=" * 78)
    print(prompt.role)
    print()
    print(prompt.instruction)
    print()
    print("messages: %d  roles: %s" % (len(messages), [m["role"] for m in messages]))
    print("--- user payload the model sees ---")
    print(messages[-1]["content"])

    print()
    print("=" * 78)
    print("2. ACCEPTED OUTPUT — problem + research objective")
    print("=" * 78)
    accepted = ObjectiveProposal.model_validate(
        {"contract_version": CONTRACT_VERSION,
         "recommendations": most(packet)["recommendations"] + suggested(packet)["recommendations"]})
    print(json.dumps(accepted.model_dump(mode="json"), indent=2))

    print()
    print("=" * 78)
    print("3. VALIDATION MATRIX (expected vs actual)")
    print("=" * 78)
    bad_revision = str(uuid.uuid4())
    results = [
        run("A. MOST_SUGGESTED on M2V1-08 UNKNOWN", packet, most(packet), "ACCEPT"),
        run("B. SUGGESTED, no source, problem null", packet, suggested(packet), "ACCEPT"),
        run("C. legacy status CLARIFY", packet,
            {"contract_version": CONTRACT_VERSION, "recommendations": [
                {**most(packet)["recommendations"][0], "recommendation_status": "CLARIFY"}]},
            "ValidationError"),
        run("D. MOST_SUGGESTED without source_refs", packet,
            {**most(packet), "recommendations": [
                {**most(packet)["recommendations"][0], "source_refs": []}]},
            "BDJ_OBJECTIVE_SOURCE_REQUIRED"),
        run("E. SUGGESTED carrying a source ref", packet,
            suggested(packet, refs=most(packet)["recommendations"][0]["source_refs"]),
            "BDJ_OBJECTIVE_SOURCE_NOT_ALLOWED"),
        run("F. MOST_SUGGESTED with a stale revision", packet,
            most(packet, revision=bad_revision), "BDJ_OBJECTIVE_SOURCE_INVALID"),
        run("G. objective written as a question", packet,
            most(packet, objective="What do customers prefer in a cafe?"),
            "BDJ_OBJECTIVE_PHRASING_INVALID"),
        run("H. objective claims guaranteed success", packet,
            most(packet, objective="To guarantee success by proving market demand."),
            "BDJ_OBJECTIVE_CLAIM_NOT_ALLOWED"),
        run("I. gap claimed from M2V1-02 DINE_IN", packet,
            most(packet, ref_item="M2V1-02"), "BDJ_OBJECTIVE_SOURCE_NOT_SUPPORTING"),
        run("J. SUGGESTED that asserts a problem", packet,
            suggested(packet, problem="Customers do not know the brand."),
            "BDJ_OBJECTIVE_PROBLEM_NOT_ALLOWED"),
    ]
    passed = sum(1 for ok, _ in results if ok)
    print("\n  %d/%d scenarios behaved as designed" % (passed, len(results)))

    print()
    print("=" * 78)
    print("4. BUSINESS-CONTEXT BINDING (deterministic, server-side)")
    print("=" * 78)
    context = build_context(packet)
    accepted_proposal = validate_objective_proposal(most(packet), packet)
    bound = bind_to_business_context(accepted_proposal, context_packet=context,
                                     context_id="ctx-1")
    print("  bound   : %s  context=%s  hash=%s…  proposals=%d" % (
        bound.contract_version, bound.context_id, bound.context_packet_hash[:12],
        len(bound.proposals)))

    def run_bind(label, ctx, expect):
        try:
            bind_to_business_context(accepted_proposal, context_packet=ctx, context_id="ctx-1")
            actual = "ACCEPT"
        except Exception as exc:
            actual = str(exc) if exc.__class__.__name__ == "WorkflowHeld" else type(exc).__name__
        ok = actual == expect
        print("  %-4s %-44s expect=%-34s got=%s"
              % ("PASS" if ok else "FAIL", label, expect, actual))
        return ok

    def reseal(ctx):
        ctx["packet_hash"] = source_hash({k: v for k, v in ctx.items() if k != "packet_hash"})
        return ctx

    stale = build_context(packet)
    next(row for row in stale["m2_answers"] if row["item_key"] == "M2V1-08")[
        "answer_revision_id"] = str(uuid.uuid4())
    reseal(stale)

    tampered = build_context(packet)
    tampered["packet_hash"] = "0" * 64

    not_current = build_context(packet)
    not_current["confirmation"]["status"] = "SUPERSEDED"
    reseal(not_current)

    binding = [
        run_bind("K. current confirmed context", context, "ACCEPT"),
        run_bind("L. context built from different answers", stale,
                 "BDJ_OBJECTIVE_CONTEXT_SOURCE_MISMATCH"),
        run_bind("M. context hash does not recompute", tampered,
                 "BDJ_OBJECTIVE_CONTEXT_HASH_INVALID"),
        run_bind("N. context is not the current one", not_current,
                 "BDJ_OBJECTIVE_CONTEXT_NOT_CURRENT"),
    ]
    passed += sum(1 for ok in binding if ok)
    total = len(results) + len(binding)
    print("\n  %d/%d scenarios behaved as designed" % (passed, total))
    print("  VERDICT:", "PASS" if passed == total else "FAIL")


if __name__ == "__main__":
    main()
