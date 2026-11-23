"""PROJECT1 — QJ / QG question-and-options demonstration (offline by default).

A companion to bdj_prompt_validation_demo_20261121.py.

Run (no packages or database required):
    python project1_qj_qg_question_options_demo.py
    python project1_qj_qg_question_options_demo.py --objective 2
    python project1_qj_qg_question_options_demo.py --show-prompt
    python project1_qj_qg_question_options_demo.py --json-out question_candidates.json
    python project1_qj_qg_question_options_cloud_demo.py --self-test
    python project1_qj_qg_question_options_cloud_demo.py --show-cloud-request
    python project1_qj_qg_question_options_cloud_demo.py --live --objective 2

This is a STANDALONE SYNTHETIC DEMO, NOT the existing Project1 QJ/QG engine.
Offline mode makes no network requests. --live EXPLICITLY sends only the hardcoded
SYNTHETIC objective/context to a configured OpenAI-compatible chat-completions API.
No database, fielding, or real approval/admission is performed in either mode.
Cloud responses remain unreviewed candidate questions, not scientifically approved.

To test the actual application, have Codex replace `qj_decision` and
`qg_generate` with the verified project services and their real contracts.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
from urllib.parse import urlsplit
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

DEMO_CONTRACT = "project1-qj-qg-offline-demo/1"

# Editable synthetic declaration (never loaded from a real user's database).
BUSINESS_CONTEXT: dict[str, Any] = {
    "assessment_id": "SYNTHETIC-ASSESSMENT-001",
    "confirmation_id": "SYNTHETIC-CONFIRMATION-001",
    "confirmed_revision": 11,
    "concept_description": "a proposed café offering specialty coffee and pastries",
    "proposed_offerings": ["Specialty coffee", "Pastries"],
    "customer_information_state": "UNKNOWN",
}

# These are synthetic exploratory BDJ proposal examples, NOT stored BDJ output.
# No MOST_SUGGESTED is asserted here: that requires verified source refs proving
# an explicit information gap in the real confirmed M2 source packet.
# approval and admission below are SIMULATED specifically to demonstrate QJ/QG.
RESEARCH_OBJECTIVES: tuple[dict[str, Any], ...] = (
    {
        "id": "DEMO-OBJ-01",
        "category": "SUGGESTED",
        "research_objective": "To assess prospective customers' stated interest in the proposed café concept.",
        "source_refs": [],
        "topic": "concept_interest",
    },
    {
        "id": "DEMO-OBJ-02",
        "category": "SUGGESTED",
        "research_objective": "To explore factors that prospective customers consider when choosing a café.",
        "source_refs": [],
        "topic": "selection_factors",
    },
    {
        "id": "DEMO-OBJ-03",
        "category": "SUGGESTED",
        "research_objective": "To explore stated preferences regarding the proposed café offerings.",
        "source_refs": [],
        "topic": "offering_preferences",
    },
)

# A simulated question bank entry, not a claim about Project1's actual bank.
DEMO_QUESTION_BANK: dict[str, dict[str, Any]] = {
    "concept_interest": {
        "question": "Based on this description, how interested would you be in visiting the proposed café?",
        "question_type": "single_choice",
        "options": [
            "Not at all interested",
            "Slightly interested",
            "Moderately interested",
            "Very interested",
            "Extremely interested",
            "Not sure",
        ],
    }
}


class DemoHeld(ValueError):
    """Explicit gate refusal in the synthetic demonstration."""


def canonical_hash(data: Any) -> str:
    payload = json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class DemoDecision:
    status: str
    reason: str


def qj_decision(objective: dict[str, Any], *, approved: bool, admitted: bool) -> DemoDecision:
    """Simplified demo gate: approved AND admitted, then bank-first, otherwise QG."""
    if not approved:
        return DemoDecision("HOLD", "OBJECTIVE_NOT_APPROVED")
    if not admitted:
        return DemoDecision("HOLD", "OBJECTIVE_NOT_ADMITTED")
    if not objective.get("research_objective") or objective.get("topic") not in {
        "concept_interest", "selection_factors", "offering_preferences"
    }:
        return DemoDecision("ABSTAIN", "UNSUPPORTED_OR_INSUFFICIENT_CONTEXT")
    if objective["topic"] in DEMO_QUESTION_BANK:
        return DemoDecision("REUSE_DEMO_BANK", "MATCHING_DEMO_QUESTION_AVAILABLE")
    return DemoDecision("GENERATE_DEMO", "NO_MATCHING_DEMO_BANK_QUESTION")


def qg_generate(objective: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    """Deterministic demonstration templates, not an AI/cloud provider."""
    topic = objective["topic"]
    if topic == "selection_factors":
        question = {
            "question": "Which of the following factors matter most when you choose a café? (Select up to two.)",
            "question_type": "multiple_choice",
            "max_selections": 2,
            "options": [
                "Location and convenience",
                "Menu and available offerings",
                "Atmosphere",
                "Service and waiting time",
                "Other factor",
                "Not sure",
            ],
        }
    elif topic == "offering_preferences":
        offerings = context.get("proposed_offerings", [])
        if not isinstance(offerings, list) or not (1 <= len(offerings) <= 4):
            raise DemoHeld("OFFERINGS_NOT_ESTABLISHED")
        if any(not isinstance(x, str) or not x.strip() for x in offerings):
            raise DemoHeld("INVALID_DECLARED_OFFERING")
        question = {
            "question": "Which of the proposed café offerings would you consider ordering? (Select all that apply.)",
            "question_type": "multiple_choice",
            "options": list(offerings) + ["None of these", "Not sure"],
        }
    else:
        raise DemoHeld("QUESTION_TEMPLATE_UNAVAILABLE")
    return question


def validate_candidate(candidate: dict[str, Any], objective: dict[str, Any]) -> None:
    """Basic demonstration-only structural checks. NOT QG scientific admission."""
    if candidate.get("objective_id") != objective["id"]:
        raise DemoHeld("OBJECTIVE_ID_MISMATCH")
    if candidate.get("authority") != "CANDIDATE_ONLY":
        raise DemoHeld("CANDIDATE_AUTHORITY_INVALID")
    if candidate.get("status") != "DRAFT_UNREVIEWED":
        raise DemoHeld("REVIEW_STATUS_INVALID")
    if not isinstance(candidate.get("question"), str) or not candidate["question"].strip().endswith("?") and "(Select" not in candidate.get("question", ""):
        raise DemoHeld("QUESTION_TEXT_INVALID")
    options = candidate.get("options")
    if not isinstance(options, list) or not 3 <= len(options) <= 9:
        raise DemoHeld("OPTIONS_COUNT_INVALID")
    if any(not isinstance(opt, str) or not opt.strip() for opt in options):
        raise DemoHeld("OPTIONS_TEXT_INVALID")
    if len({s.strip().casefold() for s in options}) != len(options):
        raise DemoHeld("OPTIONS_DUPLICATE")
    if candidate.get("question_type") not in ("single_choice", "multiple_choice"):
        raise DemoHeld("QUESTION_TYPE_INVALID")
    if candidate["question_type"] == "multiple_choice" and "None of these" in options and "Not sure" in options:
        # Must tell the frontend that these choices cannot coexist with substantive choices.
        if set(candidate.get("exclusive_options", [])) != {"None of these", "Not sure"}:
            raise DemoHeld("EXCLUSIVE_OPTIONS_REQUIRED")


def make_candidate(
    objective: dict[str, Any], context: dict[str, Any],
    *, simulated_owner_approved: bool, simulated_admitted: bool,
    cloud_runner: Callable[[dict[str, Any], dict[str, Any]], dict[str, Any]] | None = None,
) -> dict[str, Any]:
    decision = qj_decision(
        objective, approved=simulated_owner_approved, admitted=simulated_admitted
    )
    if decision.status in ("HOLD", "ABSTAIN"):
        raise DemoHeld(decision.reason)
    if decision.status == "REUSE_DEMO_BANK":
        draft = deepcopy(DEMO_QUESTION_BANK[objective["topic"]])
        source = "SYNTHETIC_DEMO_BANK_REUSE"
    elif cloud_runner is not None:
        draft = cloud_runner(objective, context)
        source = "CLOUD_LLM_SYNTHETIC_DIAGNOSTIC_UNREVIEWED"
    else:
        draft = qg_generate(objective, context)
        source = "SYNTHETIC_DETERMINISTIC_QG_TEMPLATE"
    if draft["question_type"] == "multiple_choice":
        draft["exclusive_options"] = [
            opt for opt in draft["options"] if opt in ("Not sure", "None of these")
        ]
    candidate = {
        "demo_contract": DEMO_CONTRACT,
        "objective_id": objective["id"],
        "research_objective": objective["research_objective"],
        "recommendation_category": objective["category"],
        "authority": "CANDIDATE_ONLY",
        "status": "DRAFT_UNREVIEWED",
        "simulation": {
            "owner_decision": "SIMULATED_APPROVED",
            "objective_admission": "SIMULATED_ADMITTED",
            "qj": decision.status,
            "qj_reason": decision.reason,
            "question_source": source,
        },
        "source_context_hash": canonical_hash(context),
        **draft,
    }
    validate_candidate(candidate, objective)
    return candidate


def sample_prompt(objective: dict[str, Any], context: dict[str, Any]) -> dict[str, str]:
    """Build minimal synthetic QG messages; sent only with explicit --live."""
    instruction = (
        "Draft one neutral customer-survey question and response options to assess the approved "
        "research objective. Use only supplied context. Do not claim known demand, prices, "
        "locations or customer facts. The result remains an unreviewed candidate. "
        "Question-bank reuse was checked by the synthetic QJ gate before this request. "
        "Return ONLY a JSON object with question (string), question_type "
        "(single_choice or multiple_choice), options (3 to 9 distinct strings), "
        "and optional max_selections (integer). No markdown fences, no other fields. "
        "Use neutral wording, answer choices that do not overlap unnecessarily, and "
        "a Not sure option where sensible. Do not fabricate respondent facts."
    )
    return {
        "system": instruction,
        "user": json.dumps({
            "objective": {"id": objective["id"], "topic": objective["topic"],
                          "research_objective": objective["research_objective"]},
            "business_context": {"concept_description": context["concept_description"],
                                 "proposed_offerings": context["proposed_offerings"]},
            "source_type": "SYNTHETIC_DEMO_NOT_REAL_ENTREPRENEUR_DATA",
        }, ensure_ascii=False),
    }



def build_cloud_request(objective: dict[str, Any], context: dict[str, Any],
                        model: str, *, response_format: str = "json_object") -> dict[str, Any]:
    """Produce the exact synthetic chat-completions JSON sent with --live."""
    prompt = sample_prompt(objective, context)
    request = {
        "model": model,
        "messages": [{"role": "system", "content": prompt["system"]},
                     {"role": "user", "content": prompt["user"]}],
        "temperature": 0.2,
    }
    if response_format == "json_object":
        request["response_format"] = {"type": "json_object"}
    elif response_format != "none":
        raise DemoHeld("UNSUPPORTED_RESPONSE_FORMAT")
    return request


def cloud_qg_generate(objective: dict[str, Any], context: dict[str, Any],
                      *, endpoint: str, api_key: str, model: str,
                      response_format: str = "json_object") -> dict[str, Any]:
    """Real cloud HTTP transport, called ONLY by the explicit --live branch.

    This is NOT the Project1 governed QG runner. No retry and no database writes.
    """
    parsed = urlsplit(endpoint)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise DemoHeld("HTTPS_CHAT_COMPLETIONS_URL_REQUIRED")
    if not api_key or not model:
        raise DemoHeld("CLOUD_CREDENTIALS_OR_MODEL_MISSING")
    payload = build_cloud_request(objective, context, model, response_format=response_format)
    http_request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": f"Bearer {api_key}",
                 "Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(http_request, timeout=30) as response:
            response_bytes = response.read(131073)
    except urllib.error.HTTPError as exc:
        raise DemoHeld(f"CLOUD_HTTP_{exc.code}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise DemoHeld("CLOUD_TRANSPORT_FAILED") from exc
    if len(response_bytes) > 131072:
        raise DemoHeld("CLOUD_RESPONSE_TOO_LARGE")
    try:
        envelope = json.loads(response_bytes)
        content = envelope["choices"][0]["message"]["content"]
        if not isinstance(content, str):
            raise ValueError("Content must be JSON text")
        draft = json.loads(content)
    except (ValueError, TypeError, KeyError, IndexError) as exc:
        raise DemoHeld("CLOUD_RESPONSE_NOT_VALID_JSON") from exc
    if not isinstance(draft, dict):
        raise DemoHeld("CLOUD_DRAFT_NOT_OBJECT")
    allowed = {"question", "question_type", "options", "max_selections"}
    if set(draft) - allowed:
        raise DemoHeld("CLOUD_DRAFT_UNEXPECTED_FIELDS")
    if "max_selections" in draft and (type(draft["max_selections"]) is not int or
                                      not 1 <= draft["max_selections"] <= 9):
        raise DemoHeld("CLOUD_DRAFT_MAX_SELECTIONS_INVALID")
    return draft


def run_self_tests() -> None:
    obj = RESEARCH_OBJECTIVES[0]
    try:
        make_candidate(obj, BUSINESS_CONTEXT, simulated_owner_approved=False, simulated_admitted=True)
    except DemoHeld as exc:
        assert str(exc) == "OBJECTIVE_NOT_APPROVED"
    else:
        raise AssertionError("Unapproved objective was accepted")
    try:
        make_candidate(obj, BUSINESS_CONTEXT, simulated_owner_approved=True, simulated_admitted=False)
    except DemoHeld as exc:
        assert str(exc) == "OBJECTIVE_NOT_ADMITTED"
    else:
        raise AssertionError("Unadmitted objective was accepted")
    for objective in RESEARCH_OBJECTIVES:
        result = make_candidate(objective, BUSINESS_CONTEXT, simulated_owner_approved=True, simulated_admitted=True)
        assert result["authority"] == "CANDIDATE_ONLY"
        assert result["status"] == "DRAFT_UNREVIEWED"
        assert len(result["options"]) >= 3
        assert result == make_candidate(objective, BUSINESS_CONTEXT, simulated_owner_approved=True, simulated_admitted=True)
    altered = make_candidate(RESEARCH_OBJECTIVES[2], BUSINESS_CONTEXT, simulated_owner_approved=True, simulated_admitted=True)
    altered["options"].append(altered["options"][0])
    try:
        validate_candidate(altered, RESEARCH_OBJECTIVES[2])
    except DemoHeld as exc:
        assert str(exc) == "OPTIONS_DUPLICATE"
    else:
        raise AssertionError("Duplicate answer option was accepted")
    sample_cloud = {"question": "Which consideration matters most when choosing a café?",
                    "question_type": "single_choice", "options": ["Location", "Menu", "Other", "Not sure"]}
    cloud_candidate = make_candidate(
        RESEARCH_OBJECTIVES[1], BUSINESS_CONTEXT,
        simulated_owner_approved=True, simulated_admitted=True,
        cloud_runner=lambda _o, _c: dict(sample_cloud),
    )
    assert cloud_candidate["simulation"]["question_source"] == "CLOUD_LLM_SYNTHETIC_DIAGNOSTIC_UNREVIEWED"
    assert cloud_candidate["question"] == sample_cloud["question"]
    print("SELF-TEST PASS: approval, admission, 3 offline drafts, deterministic output, "
          "duplicate refusal, injected cloud response validated")


def main() -> int:
    parser = argparse.ArgumentParser(description="Project1 QJ/QG demo: offline by default, opt-in synthetic cloud diagnostic")
    parser.add_argument("--objective", default="all", choices=["all", "1", "2", "3"], help="Which synthetic objective to demonstrate")
    parser.add_argument("--show-prompt", action="store_true", help="Print example QG prompt (never sent)")
    parser.add_argument("--json-out", type=Path, help="Write draft candidates to a JSON file")
    parser.add_argument("--self-test", action="store_true", help="Run offline validation checks")
    parser.add_argument("--live", action="store_true", help="Explicitly make cloud calls for synthetic QG-only drafts")
    parser.add_argument("--show-cloud-request", action="store_true", help="Print request JSON without sending")
    parser.add_argument("--response-format", choices=["json_object", "none"], default="json_object",
                        help="Chat Completions response_format mode (model support varies)")
    args = parser.parse_args()

    if args.live and args.self_test:
        parser.error("Run --self-test and --live separately")
    if args.live and args.show_cloud_request:
        parser.error("Choose --live OR --show-cloud-request, not both")

    model = os.environ.get("QG_DEMO_LLM_MODEL", "")
    endpoint = os.environ.get("QG_DEMO_CHAT_COMPLETIONS_URL", "")
    if args.live and (not model or not endpoint or not os.environ.get("QG_DEMO_LLM_API_KEY")):
        parser.error("Set QG_DEMO_LLM_MODEL, QG_DEMO_CHAT_COMPLETIONS_URL (HTTPS), and QG_DEMO_LLM_API_KEY")

    if args.self_test:
        run_self_tests()
        if args.objective == "all" and not args.show_prompt and args.json_out is None:
            return 0

    selected = RESEARCH_OBJECTIVES if args.objective == "all" else (RESEARCH_OBJECTIVES[int(args.objective) - 1],)
    print("=" * 75)
    print("PROJECT1 | SYNTHETIC QJ → QG / BANK-REUSE DEMO")
    print("MODE:", "LIVE CLOUD — SYNTHETIC ONLY" if args.live else
          "REQUEST PREVIEW — NO NETWORK" if args.show_cloud_request else "OFFLINE — NO NETWORK")
    print("NO DATABASE / NO REAL APPROVAL / NOT FOR FIELDING / NOT GOVERNED QG")
    print("=" * 75)
    print("Business concept:", BUSINESS_CONTEXT["concept_description"])
    print("Context fingerprint:", canonical_hash(BUSINESS_CONTEXT)[:16], "(synthetic)")
    results = []
    cloud_attempted = 0
    cloud_succeeded = 0
    cloud_failed = 0
    for idx, objective in enumerate(selected, 1):
        print("\n" + "-" * 75)
        print(f"OBJECTIVE {objective['id']} [{objective['category']}] — SYNTHETIC")
        print("Research objective:", objective["research_objective"])
        print("Source references:", objective["source_refs"] or "none (exploratory)")
        print("Approval/admission: SIMULATED for demonstration only")
        try:
            if args.show_cloud_request:
                decision = qj_decision(objective, approved=True, admitted=True)
                if decision.status == "GENERATE_DEMO":
                    print("Cloud request JSON (NOT SENT):")
                    print(json.dumps(build_cloud_request(
                        objective, BUSINESS_CONTEXT, model or "SET_QG_DEMO_LLM_MODEL",
                        response_format=args.response_format), indent=2, ensure_ascii=False))
                else:
                    print("Bank-first QJ: cloud call skipped because", decision.status)
            is_cloud_objective = args.live and qj_decision(
                objective, approved=True, admitted=True).status == "GENERATE_DEMO"
            if is_cloud_objective:
                cloud_attempted += 1
            runner = (lambda obj, ctx: cloud_qg_generate(
                obj, ctx, endpoint=endpoint,
                api_key=os.environ.get("QG_DEMO_LLM_API_KEY", ""),
                model=model, response_format=args.response_format)) if args.live else None
            candidate = make_candidate(
                objective, BUSINESS_CONTEXT,
                simulated_owner_approved=True, simulated_admitted=True,
                cloud_runner=runner,
            )
        except DemoHeld as exc:
            print("REFUSED:", exc)
            if args.live and is_cloud_objective:
                cloud_failed += 1
            continue
        if args.live and is_cloud_objective:
            cloud_succeeded += 1
        results.append(candidate)
        print("QJ decision:", candidate["simulation"]["qj"], "|", candidate["simulation"]["qj_reason"])
        print("Draft source:", candidate["simulation"]["question_source"])
        print("QUESTION:", candidate["question"])
        print("TYPE:", candidate["question_type"])
        for index, option in enumerate(candidate["options"], 1):
            print(f"  {index}. {option}")
        if candidate.get("exclusive_options"):
            print("Exclusive choices:", ", ".join(candidate["exclusive_options"]))
        print("Validation: STRUCTURAL PASS (scientific review NOT performed)")
        if args.show_prompt:
            print("Example prompt (NOT sent):")
            print(json.dumps(sample_prompt(objective, BUSINESS_CONTEXT), indent=2, ensure_ascii=False))

    print("\n" + "=" * 75)
    print(f"Drafts produced: {len(results)} | All remain CANDIDATE_ONLY / DRAFT_UNREVIEWED")
    if args.live:
        print("Cloud requests attempted:", cloud_attempted,
              "| structurally valid:", cloud_succeeded, "| refused/failed:", cloud_failed)
        print("Cloud calls run only for QJ GENERATE_DEMO objectives; bank reuse stays offline.")
    if args.json_out:
        output = {"demo_contract": DEMO_CONTRACT, "mode": "synthetic_cloud_diagnostic" if args.live else "offline", "warning": "SYNTHETIC DEMO; NOT APPROVED; NOT PRODUCTION QJ/QG OUTPUT", "candidates": results}
        args.json_out.write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print("JSON written to:", args.json_out)
    if args.live and (cloud_attempted == 0 or cloud_failed or cloud_succeeded != cloud_attempted):
        print("LIVE DIAGNOSTIC INCOMPLETE — no call made or some cloud outputs refused.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, DemoHeld) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
