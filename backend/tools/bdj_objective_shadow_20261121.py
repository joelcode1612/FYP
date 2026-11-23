"""Phase 0 — shadow comparison: findings vs objective proposals, one source.

SIMULATED PROVIDER ONLY. No network call, no persistence, no application writes.
The "model" is a fixture, so this compares the two *contracts* on one source; it
is not evidence about live model quality.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/bdj_objective_shadow_20261121.py
"""
import json
import uuid
from pathlib import Path

from sitewise.project1.bdj import BDJEngine
from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.objective_proposal import (
    CONTRACT_VERSION, ObjectiveProposal, bind_to_business_context,
    validate_objective_proposal,
)
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.projection import verify_projection
from sitewise.project1.rules import bdj_m2v1_ig_proposal as adopted_rules
from sitewise.services.business_context_v1 import source_hash

DEFINITION = Path(__file__).resolve().parents[1] / "src/sitewise/instruments/m2v1_20261114/definition.json"

# Fixture answers. One uncertainty per literal kind, plus definite answers, so
# both contracts have something to say and something to stay silent about.
ANSWERS = {
    "M2V1-01": "UNDECIDED",
    "M2V1-02": "DINE_IN",
    "M2V1-03": ["COFFEE", "BAKED_GOODS"],
    "M2V1-04": ["STUDENTS", "OFFICE_WORKERS"],
    "M2V1-05": "STUDENTS",
    "M2V1-06": "CONVENIENCE",
    "M2V1-07": "STUDY_WORK",
    "M2V1-08": "UNKNOWN",
    "M2V1-09": ["CONCEPT_INTEREST"],
    "M2V1-10": "CONCEPT_INTEREST",
    "M2V1-11": "UNSURE",
}


def fixture_id(kind, item_key, version_tag):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"fixture|{version_tag}|{kind}|{item_key}"))


def build_source():
    definition = json.loads(DEFINITION.read_text(encoding="utf-8"))
    items = [i for i in definition["items"] if i["item_key"].startswith("M2V1-")]
    if len(items) != 11:
        raise SystemExit("expected 11 M2V1 items, found %d" % len(items))
    version_tag = definition["version_tag"]
    instrument_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"fixture|instrument|{version_tag}"))

    declarations = []
    for item in sorted(items, key=lambda i: i["item_key"]):
        key = item["item_key"]
        declarations.append({
            "item_key": key,
            "question": item["question_text"],
            "answer_state": "ANSWERED",
            "answer_revision_id": fixture_id("answer", key, version_tag),
            "item_version_id": fixture_id("item", key, version_tag),
            "value": ANSWERS[key],
        })

    packet = {
        "schema_version": "project1-m2-projection/1-candidate",
        "instrument_version": version_tag,
        "instrument_id": instrument_id,
        "assessment_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "fixture|assessment")),
        "assessment_revision": 7,
        "confirmed": True,
        "confirmation": {"confirmation_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "fixture|confirmation")),
                         "snapshot_digest": "a" * 64},
        "declarations": declarations,
    }
    packet["source_fingerprint"] = digest(packet)
    return packet, items, version_tag


def build_context(packet):
    ctx = {
        "schema_version": "persisted-business-context/1",
        "context_version": "1.1",
        "confirmation": {"id": packet["confirmation"]["confirmation_id"],
                         "revision": packet["assessment_revision"],
                         "digest": packet["confirmation"]["snapshot_digest"],
                         "status": "CURRENT_CONFIRMED"},
        "m2_answers": [{k: d[k] for k in ("item_key", "answer_revision_id",
                                          "item_version_id", "answer_state", "value")}
                       for d in packet["declarations"]],
        "permissions": {"report_admission": False, "report_release": False,
                        "qj_execution": False, "qg_execution": False},
    }
    ctx["packet_hash"] = source_hash(ctx)
    return ctx


def rec(packet, item_key, status="MOST_SUGGESTED", objective=None, problem=None, reason=None):
    row = next(d for d in packet["declarations"] if d["item_key"] == item_key)
    source_backed = status == "MOST_SUGGESTED"
    return {
        "recommendation_status": status,
        "problem_type": ("SOURCE_CONFIRMED_INFORMATION_GAP" if source_backed
                         else "EXPLORATORY_RESEARCH_NEED"),
        "problem": problem if problem is not None else (
            "The confirmed answer to %s is %s." % (item_key, row["value"]) if source_backed else None),
        "research_objective": objective or (
            "To investigate what %s leaves unresolved for the proposed cafe." % item_key),
        "source_refs": ([{"item_key": item_key,
                          "answer_revision_id": row["answer_revision_id"],
                          "item_version_id": row["item_version_id"]}] if source_backed else []),
        "reason": reason or ("Restates the confirmed uncertainty in %s." % item_key),
        "authority": "CANDIDATE_ONLY",
    }


def simulated_provider(name, payload):
    def run(stage, packet, output_type, **kwargs):
        return json.loads(json.dumps(payload))
    run.name = name
    return run


def main():
    packet, items, version_tag = build_source()
    verify_projection(packet)
    print("=" * 78)
    print("PHASE 0 — SHADOW COMPARISON (simulated provider, no persistence)")
    print("=" * 78)
    print("instrument      :", version_tag)
    print("items verified  : %d / 11" % len(items))
    print("source fp       :", packet["source_fingerprint"][:16], "…")
    print("declarations    : %d (all ANSWERED)" % len(packet["declarations"]))

    # 1. Does the legacy findings contract support M2V1 at all?
    from sitewise.domain import bdj_candidate_rules as legacy_rules
    legacy = BDJEngine(legacy_rules).review(
        packet, recheck_current=lambda: packet["source_fingerprint"])
    legacy_code = next((c.get("reason") for c in legacy["checkpoints"] if c.get("reason")), None)
    print("\nlegacy ruleset  : %s → outcome=%s reason=%s"
          % (legacy_rules.RULE_VERSION, legacy["outcome"], legacy_code))
    print("baseline used   : %s (adopted, M2V1-native)" % adopted_rules.RULE_VERSION)

    # 2. Findings from the adopted ruleset — deterministic, no model.
    findings_result = BDJEngine(adopted_rules).review(
        packet, recheck_current=lambda: packet["source_fingerprint"])
    findings = findings_result["findings"]
    print("\nfindings        : %d %s"
          % (len(findings), [f["rule_id"] for f in findings]))

    # 3. Recommendations from a SIMULATED provider.
    context = build_context(packet)
    simulated = {"contract_version": CONTRACT_VERSION,
                 "recommendations": [rec(packet, "M2V1-01"), rec(packet, "M2V1-08")]}
    prompt = PROMPTS["BDJ_OBJECTIVE"]
    messages = prompt.messages(packet, ObjectiveProposal.model_json_schema())
    output = simulated_provider("SIMULATED_A", simulated)("BDJ", packet, ObjectiveProposal)
    proposal = validate_objective_proposal(output, packet)
    bound = bind_to_business_context(proposal, context_packet=context, context_id="ctx-phase0")
    print("prompt          : %s (%s), %d messages"
          % (prompt.version, prompt.fingerprint[:12], len(messages)))
    print("recommendations : %d %s"
          % (len(proposal.recommendations),
             [r.recommendation_status for r in proposal.recommendations]))
    print("bound context   : %s hash=%s…" % (bound.context_id, bound.context_packet_hash[:12]))

    # 4. Compare by (item_key, answer_revision_id).
    def refs_of(rows):
        out = set()
        for row in rows:
            for ref in row.get("source_refs") or []:
                out.add((ref["item_key"], ref["answer_revision_id"]))
        return out

    finding_refs = refs_of(findings)
    rec_refs = refs_of([r.model_dump() for r in proposal.recommendations])

    per_item, omitted, unsupported = [], [], []
    for decl in packet["declarations"]:
        key = decl["item_key"]
        ident = (key, decl["answer_revision_id"])
        has_finding = ident in finding_refs
        has_rec = ident in rec_refs
        per_item.append({"item_key": key, "value": decl["value"],
                         "finding": has_finding, "recommendation": has_rec,
                         "source_match": has_finding and has_rec})
        if has_finding and not has_rec:
            omitted.append({"item_key": key, "value": decl["value"],
                            "reason": "selective: proposal cites a different gap; "
                                      "detector still records this finding"})
        if has_rec and not has_finding:
            unsupported.append({"item_key": key,
                                "reason": "no deterministic finding on this answer"})

    print("\n%-9s %-18s %-8s %-14s %s" % ("ITEM", "VALUE", "FINDING", "RECOMMENDATION", "SOURCE MATCH"))
    for row in per_item:
        print("%-9s %-18s %-8s %-14s %s" % (
            row["item_key"], str(row["value"])[:18],
            "yes" if row["finding"] else "-", "yes" if row["recommendation"] else "-",
            "match" if row["source_match"] else ""))

    print("\nomitted findings    :", omitted or "none")
    print("unsupported recs    :", unsupported or "none")

    # 5. Negative probe: a simulated proposal that cites a definite answer.
    probe_payload = {"contract_version": CONTRACT_VERSION,
                     "recommendations": [rec(packet, "M2V1-02")]}
    try:
        validate_objective_proposal(probe_payload, packet)
        probe = "ACCEPTED (unexpected)"
    except WorkflowHeld as exc:
        probe = str(exc)
    print("negative probe      : M2V1-02 DINE_IN cited as a gap →", probe)

    report = {
        "phase": 0, "simulated_provider": True, "persisted": False,
        "instrument_version": version_tag, "items_verified": len(items),
        "source_fingerprint": packet["source_fingerprint"],
        "legacy_ruleset": {"version": legacy_rules.RULE_VERSION,
                           "outcome": legacy["outcome"], "reason": legacy_code},
        "baseline_ruleset": adopted_rules.RULE_VERSION,
        "prompt": {"version": prompt.version, "fingerprint": prompt.fingerprint},
        "contract_version": CONTRACT_VERSION,
        "findings": [{"item_key": f["source_refs"][0]["item_key"],
                      "answer_revision_id": f["source_refs"][0]["answer_revision_id"],
                      "rule_id": f["rule_id"]} for f in findings],
        "recommendations": [{"status": r.recommendation_status,
                             "item_key": (r.source_refs[0].item_key if r.source_refs else None),
                             "answer_revision_id": (r.source_refs[0].answer_revision_id
                                                    if r.source_refs else None)}
                            for r in proposal.recommendations],
        "per_item": per_item,
        "omitted_findings": omitted,
        "unsupported_recommendations": unsupported,
        "negative_probe": {"case": "M2V1-02 DINE_IN cited as a gap", "result": probe},
        "verdict": "PASS" if not unsupported else "FAIL",
    }
    out = Path(__file__).resolve().parents[2] / "deliverables/phase0/BDJ_SHADOW_REPORT_20261121.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\nreport          :", out)
    print("VERDICT         :", report["verdict"],
          "(unsupported recommendations are the only automatic failure)")
    return 0 if report["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
