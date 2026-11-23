"""LIVE diagnostic: send the objective-proposal prompt to the real provider.

This is a DIAGNOSTIC, not a governed execution. It deliberately bypasses the
attempt ledger, the disclosure gate and the result store:

  * no `project1_ai.runs` row
  * no `bdj_results` row, no sealed payload
  * no execution receipt, so nothing here can be cited as evidence of a
    governed BDJ run

What it does prove: what the configured cloud model actually returns for
`BDJ-OBJECTIVE-1-CAND`, and whether that response passes
`validate_objective_proposal`.

Usage (from backend/):
    PYTHONPATH=src .venv/Scripts/python.exe tools/bdj_objective_proposal_live_20261121.py --live
    ... --live --model mimo-v2.6-flash:free --mode json_object

Without --live it only prints the request it would send.
"""
import argparse
import json
import sys
import uuid

from sitewise.core.config import settings
from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.objective_proposal import (
    CONTRACT_VERSION, ObjectiveProposal, validate_objective_proposal,
)
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.provider import ENDPOINT, MODEL, TokenHarbor


def build_packet():
    # Mirrors M2SourceProjection: a declaration carries `question` as well as the
    # value and identifiers. Omitting it starves the model of the item's meaning.
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", action="store_true", help="actually dispatch to the provider")
    ap.add_argument("--model", default=None, help="default: the adopted constant %s" % MODEL)
    ap.add_argument("--mode", default=None, help="json_schema (default) or json_object")
    args = ap.parse_args()

    packet = build_packet()
    prompt = PROMPTS["BDJ_OBJECTIVE"]
    messages = prompt.messages(packet, ObjectiveProposal.model_json_schema())
    model = args.model or MODEL
    mode = args.mode or settings.tokenharbor_structured_mode
    payload_bytes = len(json.dumps({"model": model, "messages": messages,
                                    "response_format": {"type": mode}}).encode())

    print("=" * 78)
    print("LIVE DIAGNOSTIC — NOT A GOVERNED EXECUTION")
    print("=" * 78)
    print("prompt          : %s (%s)" % (prompt.version, prompt.fingerprint[:12]))
    print("endpoint        : %s" % ENDPOINT)
    print("model requested : %s" % model)
    print("structured mode : %s" % mode)
    print("messages        : %d  payload ~%d bytes" % (len(messages), payload_bytes))
    print("key configured  : %s" % bool(settings.tokenharbor_api_key.get_secret_value()))
    print("provider enabled: %s" % settings.tokenharbor_enabled)
    print("identity exception: %s" % settings.tokenharbor_model_identity_exception)

    if not args.live:
        print("\nDRY RUN — add --live to dispatch. Nothing was sent.")
        return 2

    if not settings.tokenharbor_enabled or not settings.tokenharbor_api_key.get_secret_value():
        print("\nREFUSED: provider disabled or no key in .env "
              "(TOKENHARBOR_ENABLED / TOKENHARBOR_API_KEY). Nothing was sent.")
        return 2

    provider = TokenHarbor(
        settings.tokenharbor_api_key,
        enabled=settings.tokenharbor_enabled,
        structured_mode=mode,
        timeout=max(1, min(settings.tokenharbor_timeout_seconds, 60)),
        identity_exception=settings.tokenharbor_model_identity_exception,
        model=model,
    )

    print("\n--- dispatch ---")
    try:
        output = provider.complete(messages, ObjectiveProposal)
    except WorkflowHeld as exc:
        print("HELD:", exc)
        print("execution:", json.dumps(provider.last_execution, indent=2, default=str))
        return 1

    execution = provider.last_execution or {}
    print("model_returned :", execution.get("model_returned"))
    print("identity       :", (provider.last_identity or {}).get("classification"))
    print("http_status    :", execution.get("http_status"))
    print("usage          :", execution.get("usage"))
    print("cost           :", execution.get("provider_reported_cost"),
          execution.get("cost_currency"))
    print("response_sha256:", str(execution.get("response_sha256"))[:16], "…")
    print("schema         :", execution.get("schema_validation"))

    print("\n--- raw model output ---")
    print(json.dumps(output, indent=2))

    print("\n--- contract validation ---")
    try:
        validated = validate_objective_proposal(output, packet)
    except WorkflowHeld as exc:
        print("REJECTED:", exc)
        return 1
    except Exception as exc:
        print("REJECTED:", type(exc).__name__, str(exc)[:300])
        return 1

    for rec in validated.recommendations:
        print("ACCEPTED %-15s %s" % (rec.recommendation_status, rec.research_objective))
        print("         problem:", rec.problem)
        print("         sources:", [r.item_key for r in rec.source_refs] or "none")
    print("\nVERDICT: PASS — the cloud response satisfies %s" % CONTRACT_VERSION)
    return 0


if __name__ == "__main__":
    sys.exit(main())
