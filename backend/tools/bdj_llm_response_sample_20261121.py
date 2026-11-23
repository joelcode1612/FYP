"""Show the exact JSON the BDJ model is required to return, and prove it validates.

Run:
    .venv/Scripts/python.exe tools/bdj_llm_response_sample_20261121.py

No database, no network, no provider call.
"""
import json
import uuid

from sitewise.project1.bdj import validate_candidates
from sitewise.project1.contracts import BDJOutput, digest
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


def ref(declaration, quote):
    return {"item_key": declaration["item_key"],
            "answer_revision_id": declaration["answer_revision_id"],
            "item_version_id": declaration["item_version_id"],
            "quote": quote}


def main():
    packet = build_packet()
    d01, _, d11 = packet["declarations"]
    answers = {d["item_key"]: {"id": d["answer_revision_id"],
                               "answer_state": d["answer_state"],
                               "value_json": d["value"]}
               for d in packet["declarations"]}
    allowed = sorted({p["rule_id"] for p in rules.evaluate_candidate_issues(answers)})

    schema = BDJOutput.model_json_schema()
    print("=" * 72)
    print("1. REQUIRED SHAPE (BDJOutput.model_json_schema, strict, extra=forbid)")
    print("=" * 72)
    print(json.dumps({"required": schema["required"],
                      "additionalProperties": schema.get("additionalProperties"),
                      "finding_required": schema["$defs"]["Finding"]["required"],
                      "source_ref_required": schema["$defs"]["SourceRef"]["required"],
                      "kind_enum": schema["$defs"]["Finding"]["properties"]["kind"]["enum"],
                      "item_key_pattern": schema["$defs"]["SourceRef"]["properties"]["item_key"]["pattern"]},
                     indent=2))

    content = {
        "issues": [
            {"rule_id": "M2V1_EXPLICIT_PLANNING_UNDECIDED",
             "kind": "INFORMATION_GAP",
             "source_refs": [ref(d01, "UNDECIDED")],
             "observed_condition": "The confirmed response to M2V1-01 is UNDECIDED.",
             "counterargument": "An undecided response is valid and is not a contradiction or business defect.",
             "justification": "This restates the exact source code only; no additional business fact is inferred.",
             "next_action": "Entrepreneur may clarify this response if relevant; do not alter the answer."},
            {"rule_id": "M2V1_RESEARCH_PURPOSE_UNSURE",
             "kind": "INFORMATION_GAP",
             "source_refs": [ref(d11, "UNSURE")],
             "observed_condition": "The confirmed response to M2V1-11 is UNSURE.",
             "counterargument": "An unsure decision status is valid and establishes no defect.",
             "justification": "This restates the exact source code only.",
             "next_action": "Entrepreneur may clarify the research purpose if relevant."},
        ],
        "overall_note": "Only literal declared uncertainty observations are proposed. No demand, viability or scientific acceptance is established.",
    }

    print()
    print("=" * 72)
    print("2. message.content — the JSON string the model must emit")
    print("=" * 72)
    print(json.dumps(content, indent=2))

    print()
    print("=" * 72)
    print("3. ADMISSIBILITY (real validate_candidates)")
    print("=" * 72)
    try:
        out = validate_candidates(content, packet, set(allowed))
        print("  ACCEPTED  issues=%d  rules=%s" % (len(out.issues), [i.rule_id for i in out.issues]))
    except Exception as exc:
        print("  REJECTED ", type(exc).__name__, exc)

    print()
    print("=" * 72)
    print("4. full provider envelope (choices[0].message.content is a STRING)")
    print("=" * 72)
    envelope = {
        "id": "chatcmpl-demo", "object": "chat.completion", "created": 1795000000,
        "model": "deepseek-v4.1-flash-1017",
        "choices": [{"index": 0, "finish_reason": "stop",
                     "message": {"role": "assistant", "content": json.dumps(content)}}],
        "usage": {"prompt_tokens": 1180, "completion_tokens": 320,
                  "total_tokens": 1500, "cost": 0.00021, "cost_currency": "USD"},
    }
    print(json.dumps(envelope, indent=2)[:900] + "\n  … (content truncated for display)")


if __name__ == "__main__":
    main()
