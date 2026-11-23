"""BDJ prompt/validation demo: offline by default; opt-in synthetic cloud test.

Run:
    .venv/Scripts/python.exe tools/bdj_prompt_validation_cloud_demo_20261121.py
    .venv/Scripts/python.exe tools/bdj_prompt_validation_cloud_demo_20261121.py --show-cloud-request
    .venv/Scripts/python.exe tools/bdj_prompt_validation_cloud_demo_20261121.py --live

By default: no database, network, or provider call. The optional --live mode
uses the existing Project1 TokenHarbor provider, but with SYNTHETIC data ONLY.
This tests the LEGACY BDJOutput (findings), NOT the new objective-proposal
contract, and is NOT a governed ledger/disclosure/API execution.
No real entrepreneur data, persistence, or fielding is used.
"""
import argparse
import json
import sys
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


def cloud_diagnostic(packet, messages, *, model_override=None, mode_override=None,
                     send=False):
    """Optional legacy-BDJ cloud diagnostic using the actual Project1 provider.

    --live is the sole call site that can send a network request. No ledger,
    persistence, disclosure, or application production authorization is implied.
    """
    from sitewise.core.config import settings
    from sitewise.project1.contracts import WorkflowHeld
    from sitewise.project1.provider import ENDPOINT, MODEL, TokenHarbor

    model = model_override or MODEL
    mode = mode_override or settings.tokenharbor_structured_mode
    print("\n" + "=" * 72)
    print("5. CLOUD LLM REQUEST — LEGACY BDJ FINDINGS / SYNTHETIC ONLY")
    print("=" * 72)
    print("endpoint       :", ENDPOINT)
    print("model          :", model)
    print("prompt version :", PROMPTS["BDJ"].version)
    print("structured mode:", mode)
    print("message roles  :", [m["role"] for m in messages])
    print("request bytes  :", len(json.dumps({"model": model, "messages": messages,
                                                 "response_format": {"type": mode}}).encode()))
    print("provider enabled:", settings.tokenharbor_enabled)
    print("api key present:", bool(settings.tokenharbor_api_key.get_secret_value()))
    print("governance     : DEMO ONLY — no ledger, no owner-data disclosure authority")

    if not send:
        print("DRY RUN — no network request. Add --live for a synthetic cloud test.")
        return 0
    if not settings.tokenharbor_enabled or not settings.tokenharbor_api_key.get_secret_value():
        print("REFUSED — TokenHarbor is disabled or API key is unavailable. Nothing sent.")
        return 2
    try:
        provider = TokenHarbor(
            settings.tokenharbor_api_key,
            enabled=settings.tokenharbor_enabled,
            structured_mode=mode,
            timeout=max(1, min(settings.tokenharbor_timeout_seconds, 60)),
            identity_exception=settings.tokenharbor_model_identity_exception,
            model=model,
        )
        # This line performs the real cloud request when --live was supplied.
        output = provider.complete(messages, BDJOutput)
    except WorkflowHeld as exc:
        print("CLOUD PROVIDER HELD:", str(exc))
        return 1
    except Exception as exc:
        # Do not echo response bodies or credentials in unexpected errors.
        print("CLOUD PROVIDER ERROR:", type(exc).__name__)
        return 1

    print("Cloud execution metadata (no secrets):")
    exec_info = provider.last_execution or {}
    for k in ("http_status", "model_returned", "usage", "response_sha256",
              "schema_validation"):
        print(" ", k, ":", exec_info.get(k))
    # Validate via the real engine rather than trusting the cloud output.
    verified = BDJEngine(rules, model_runner=lambda *a, **k: output).review(
        packet, recheck_current=lambda: packet["source_fingerprint"])
    print("BDJ validation outcome:", verified["outcome"])
    print("Accepted findings:", len(verified["findings"]))
    print("Checkpoints:", verified["checkpoints"])
    print("No findings here are approved; this is a legacy diagnostic only.")
    return 0 if verified["outcome"] in ("completed", "COMPLETED", "success", "SUCCESS", "reviewed", "REVIEWED") else 1


def main():
    parser = argparse.ArgumentParser(description="Legacy BDJ prompt demo, cloud opt-in")
    parser.add_argument("--live", action="store_true",
                        help="Make a REAL cloud request using ONLY the synthetic BDJ packet")
    parser.add_argument("--show-cloud-request", action="store_true",
                        help="Print safe cloud request metadata without dispatching")
    parser.add_argument("--model", default=None,
                        help="Optional model override (normally existing Project1 provider default)")
    parser.add_argument("--mode", choices=["json_object", "json_schema"], default=None,
                        help="Use only modes supported by your provider/model")
    args = parser.parse_args()
    if args.live and args.show_cloud_request:
        parser.error("Use --live or --show-cloud-request, not both")
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

    if args.live or args.show_cloud_request:
        return cloud_diagnostic(packet, messages, model_override=args.model,
                                mode_override=args.mode, send=args.live)
    print("\nOFFLINE DEFAULT — no cloud call was made.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
