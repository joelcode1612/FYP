"""Read-only demo: what BDJ receives, and how invalid model output fails closed.

Run:
    .venv/Scripts/python.exe tools/bdj_prompt_validation_demo_20261121.py

No database, no network, no provider call. Everything below is executed against
the real prompt builder, the real adopted rules module and the real BDJEngine.
"""
import json
import uuid

from sitewise.project1.bdj import BDJEngine
from sitewise.project1.contracts import BDJOutput, digest
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.rules import bdj_m2v1_ig_proposal as rules


def build_packet():
    def decl(key, value):
        return {"item_key": key, "answer_state": "ANSWERED",
                "answer_revision_id": str(uuid.uuid4()),
                "item_version_id": str(uuid.uuid4()), "value": value}

    packet = {
        "schema_version": "project1-m2-projection/1-candidate",
        "instrument_version": "M2V1-20261114-1",
        "instrument_id": str(uuid.uuid4()),
        "assessment_id": str(uuid.uuid4()),
        "assessment_revision": 7,
        "confirmed": True,
        "confirmation": {"confirmation_id": str(uuid.uuid4()),
                         "snapshot_digest": "a" * 64},
        "declarations": [decl("M2V1-01", "UNDECIDED"),
                         decl("M2V1-02", "DINE_IN"),
                         decl("M2V1-11", "UNSURE")],
    }
    packet["source_fingerprint"] = digest(packet)
    return packet


def finding(packet, rule_id, quote):
    first = packet["declarations"][0]
    return {"rule_id": rule_id, "kind": "INFORMATION_GAP",
            "source_refs": [{"item_key": first["item_key"],
                             "answer_revision_id": first["answer_revision_id"],
                             "item_version_id": first["item_version_id"],
                             "quote": quote}],
            "observed_condition": "The confirmed response to M2V1-01 is UNDECIDED.",
            "counterargument": "An undecided response is valid.",
            "justification": "Restates the exact source code only.",
            "next_action": "Entrepreneur may clarify if relevant."}


def main():
    packet = build_packet()
    answers = {d["item_key"]: {"id": d["answer_revision_id"],
                               "answer_state": d["answer_state"],
                               "value_json": d["value"]}
               for d in packet["declarations"]}
    proposals = rules.evaluate_candidate_issues(answers)
    allowed = sorted({p["rule_id"] for p in proposals})
    model_packet = {**packet, "rule_catalogue": allowed}

    prompt = PROMPTS["BDJ"]
    messages = prompt.messages(model_packet, BDJOutput.model_json_schema())
    system = messages[0]["content"]
    prose = system.split('{"')[0]

    print("=" * 72)
    print("1. PROMPT BUILD  version=%s  fingerprint=%s" % (prompt.version, prompt.fingerprint[:12]))
    print("=" * 72)
    print("--- system[0] prose ---")
    print(prose.strip())
    print("--- system[0] tail ---")
    print("<JSON schema of BDJOutput: %d chars>" % (len(system) - len(prose)))
    print("--- example pair ---")
    print("user     :", messages[1]["content"])
    print("assistant:", messages[2]["content"])
    print("--- final user message (source_data) ---")
    print(messages[-1]["content"])
    print("message count:", len(messages), "| roles:", [m["role"] for m in messages])

    print()
    print("=" * 72)
    print("2. DOES THE REVIEW DTO LEAK INTO THE PROMPT?")
    print("=" * 72)
    blob = json.dumps(messages)
    for key in ("evaluation_state", "snapshot_digest", "activity", "answers",
                "contract_version", "source_status", "trust_class"):
        print("  %-20s in prompt: %s" % (key, key in blob))
    print("  rule_catalogue present:", "rule_catalogue" in blob)
    print("  declarations present  :", "M2V1-01" in blob)

    print()
    print("=" * 72)
    print("3. VALIDATION / FALLBACK BEHAVIOUR (real engine, fake runner)")
    print("=" * 72)

    scenarios = [
        ("A. model returns no issues", {"issues": [], "overall_note": "nothing found"}),
        ("B. model invents rule BDJ-001", {"issues": [finding(packet, "BDJ-001", "UNDECIDED")],
                                           "overall_note": "invented"}),
        ("C. wrong quote (question text)", {"issues": [finding(packet, allowed[0], "Not decided yet")],
                                            "overall_note": "bad quote"}),
        ("D. compliant finding", {"issues": [finding(packet, allowed[0], "UNDECIDED")],
                                  "overall_note": "ok"}),
    ]
    for label, payload in scenarios:
        engine = BDJEngine(rules, model_runner=lambda *a, _p=payload, **k: _p)
        result = engine.review(packet, recheck_current=lambda: packet["source_fingerprint"])
        cps = ",".join("%s=%s" % (c.get("checkpoint"), c.get("outcome")) for c in result["checkpoints"])
        print("\n%s" % label)
        print("  outcome        :", result["outcome"])
        print("  findings       :", len(result["findings"]),
              [f["rule_id"] for f in result["findings"]])
        print("  checkpoints    :", cps)
        print("  authority      :", result["finding_authority"], "/", result["status_contract"])

    print()
    print("=" * 72)
    print("4. DETERMINISTIC FINDINGS (no model at all)")
    print("=" * 72)
    bare = BDJEngine(rules, model_runner=None).review(
        packet, recheck_current=lambda: packet["source_fingerprint"])
    print("  outcome :", bare["outcome"])
    print("  findings:", [f["rule_id"] for f in bare["findings"]])


if __name__ == "__main__":
    main()
