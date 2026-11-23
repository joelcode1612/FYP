"""PROJECT1 — offline QJ / QG question-and-options demonstration.

A companion to bdj_prompt_validation_demo_20261121.py.

Run (no packages or database required):
    python project1_qj_qg_question_options_demo.py
    python project1_qj_qg_question_options_demo.py --objective 2
    python project1_qj_qg_question_options_demo.py --show-prompt
    python project1_qj_qg_question_options_demo.py --json-out question_candidates.json
    python project1_qj_qg_question_options_demo.py --self-test

This is a STANDALONE SYNTHETIC DEMO, NOT the existing Project1 QJ/QG engine.
No LLM, network, database, fielding or real approval/admission is performed.
Question drafts and answer choices are deterministic demo templates, not an
approved questionnaire or proof of scientific/measurement validity.

To test the actual application, have Codex replace `qj_decision` and
`qg_generate` with the verified project services and their real contracts.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
from typing import Any

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
) -> dict[str, Any]:
    decision = qj_decision(
        objective, approved=simulated_owner_approved, admitted=simulated_admitted
    )
    if decision.status in ("HOLD", "ABSTAIN"):
        raise DemoHeld(decision.reason)
    if decision.status == "REUSE_DEMO_BANK":
        draft = deepcopy(DEMO_QUESTION_BANK[objective["topic"]])
        source = "SYNTHETIC_DEMO_BANK_REUSE"
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
    """Inspection only: example messages, never sent to any provider."""
    instruction = (
        "Draft one neutral customer-survey question and response options to assess the approved "
        "research objective. Use only supplied context. Do not claim known demand, prices, "
        "locations or customer facts. The result remains an unreviewed candidate. "
        "Prefer a verified existing question-bank item if one is suitable. "
        "Return structured JSON with question, question_type and options."
    )
    return {
        "system": instruction,
        "user": json.dumps({"objective": objective, "business_context": context}, ensure_ascii=False),
    }


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
    print("SELF-TEST PASS: approval gate, admission gate, 3 candidates, deterministic output, duplicate-options refusal")


def main() -> int:
    parser = argparse.ArgumentParser(description="Offline Project1 research questions + answer options demo")
    parser.add_argument("--objective", default="all", choices=["all", "1", "2", "3"], help="Which synthetic objective to demonstrate")
    parser.add_argument("--show-prompt", action="store_true", help="Print example QG prompt (never sent)")
    parser.add_argument("--json-out", type=Path, help="Write draft candidates to a JSON file")
    parser.add_argument("--self-test", action="store_true", help="Run fail-closed demonstration checks")
    args = parser.parse_args()

    if args.self_test:
        run_self_tests()
        if args.objective == "all" and not args.show_prompt and args.json_out is None:
            return 0

    selected = RESEARCH_OBJECTIVES if args.objective == "all" else (RESEARCH_OBJECTIVES[int(args.objective) - 1],)
    print("=" * 75)
    print("PROJECT1 | SYNTHETIC QJ → QG / BANK-REUSE DEMO")
    print("OFFLINE / NO LLM / NO DATABASE / NO REAL APPROVAL / NOT FOR FIELDING")
    print("=" * 75)
    print("Business concept:", BUSINESS_CONTEXT["concept_description"])
    print("Context fingerprint:", canonical_hash(BUSINESS_CONTEXT)[:16], "(synthetic)")
    results = []
    for idx, objective in enumerate(selected, 1):
        print("\n" + "-" * 75)
        print(f"OBJECTIVE {objective['id']} [{objective['category']}] — SYNTHETIC")
        print("Research objective:", objective["research_objective"])
        print("Source references:", objective["source_refs"] or "none (exploratory)")
        print("Approval/admission: SIMULATED for demonstration only")
        try:
            candidate = make_candidate(
                objective, BUSINESS_CONTEXT,
                simulated_owner_approved=True, simulated_admitted=True,
            )
        except DemoHeld as exc:
            print("REFUSED:", exc)
            continue
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
    if args.json_out:
        output = {"demo_contract": DEMO_CONTRACT, "warning": "SYNTHETIC DEMO; NOT APPROVED; NOT PRODUCTION QJ/QG OUTPUT", "candidates": results}
        args.json_out.write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print("JSON written to:", args.json_out)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, DemoHeld) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
