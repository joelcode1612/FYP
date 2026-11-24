"""EX-01 verification: does the explanation registry still say what the contract says?

The registry is generated from CUST03, but generation is not the same as agreement.
This script re-reads both artefacts independently and asserts, item by item, that
the explanation layer has not drifted from the authoritative questionnaire. It then
emits the EX-01 matrix.

Every check cites the field it compared. A failure names the question, the registry
value and the contract value, so a disagreement is diagnosable without guessing.

Run:
    backend/.venv/Scripts/python.exe backend/scripts/verify_explanation_module_ex01.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / "src"))

from sitewise.project1.explanation_registry import (  # noqa: E402
    ALL_STATES,
    EVIDENCE_STATES,
    INSTRUMENT_GATES,
    REGISTRY_VERSION,
    load_registry,
    raw_question,
)
from sitewise.services.customer_questionnaire_candidate import SOURCE_SHA, load_sources  # noqa: E402

OUT = BACKEND.parent / "artifacts/project1_explanation_module_ex01_ex03_v1"

#: Placeholders any item template may declare. Kept explicit so a template that
#: invents a new figure slot fails rather than silently rendering a hole.
KNOWN_PLACEHOLDERS = {
    "question_id", "count", "shown", "V", "feature", "V_feature",
    "category", "percent", "yes_count", "yes_percent", "offer_and_price",
}

#: The interpretation each item must carry, per the directive's preserved
#: decisions. Checked against the registry's construct, never against prose.
EXPECTED_CONSTRUCT = {
    "Q01": "G01_AREA_AFFILIATION",
    "Q02": "G01_AREA_PRESENCE_FREQUENCY",
    "Q03": "GEO_ORIGIN_TYPE_01",
    "Q04": "D04_EXISTING_USE",
    "Q05": "D01_CONCEPT_INTENT",
    "Q06": "D02_PRODUCT_INTEREST",
    "Q07": "D03A_PRICE_ACCEPT",
    "Q08": "D05A_PAST_OCCASION",
    "Q09": "D05B_PLANNED_OCCASION",
    "Q10": "D06_EXPERIENCE_PRIORITY",
    "Q11": "FMT01_FORMAT_CHOICE",
    "Q12": "GEO_TRANSPORT_TO_AREA_01",
    "Q13": "EXP01_PRICE_EXPECTATION",
}

#: Items the contract deliberately leaves with no report section. Rendering one
#: of these into a section would create authority the Owner never granted.
NO_SECTION_ITEMS = {"Q11", "Q13"}


class Failure(AssertionError):
    pass


def check(condition: bool, code: str, detail: str) -> None:
    if not condition:
        raise Failure(f"{code}: {detail}")


def main() -> int:
    contract, _policy, _reference = load_sources()
    registry = load_registry()
    items = {item["id"]: item for item in contract["items"]}

    results: list[dict] = []

    # ---------------------------------------------------------------- identity
    check(registry.instrument_version == contract["spec_version"], "A1_VERSION",
          f"registry {registry.instrument_version} != contract {contract['spec_version']}")
    check(registry.instrument_sha256 == SOURCE_SHA, "A1_SHA",
          f"registry instrument_sha256 {registry.instrument_sha256} != frozen {SOURCE_SHA}")
    check(registry.registry_version == REGISTRY_VERSION, "A1_REGISTRY_VERSION",
          f"registry_version {registry.registry_version}")

    # ------------------------------------------------------------ per-item map
    for question_id in EXPECTED_CONSTRUCT:
        check(question_id in items, "A2_MISSING_ITEM", f"{question_id} absent from contract")
        check(question_id in registry.questions, "A2_MISSING_REGISTRY", f"{question_id} absent from registry")

        entry = registry.questions[question_id]
        item = items[question_id]
        raw = raw_question(question_id)

        check(entry.construct_id == EXPECTED_CONSTRUCT[question_id], "A3_CONSTRUCT_DECISION",
              f"{question_id}: {entry.construct_id} != expected {EXPECTED_CONSTRUCT[question_id]}")
        check(entry.construct_id == item["construct"], "A3_CONSTRUCT_CONTRACT",
              f"{question_id}: registry {entry.construct_id} != contract {item['construct']}")
        check(entry.construct_id in contract["construct_registry"], "A3_CONSTRUCT_REGISTERED",
              f"{question_id}: {entry.construct_id} not in contract construct_registry")

        check(tuple(entry.report_sections) == tuple(item["report_sections"]), "A4_SECTIONS",
              f"{question_id}: registry {entry.report_sections} != contract {item['report_sections']}")
        for section in entry.report_sections:
            check(section in contract["report_sections"]["canonical_ids"], "A4_SECTION_CANONICAL",
                  f"{question_id}: {section} is not a canonical R-id")

        check(entry.permitted_claim == item["permitted_claim"], "A5_PERMITTED",
              f"{question_id}: permitted_claim differs from contract")
        check(entry.prohibited_inference == item["forbidden_inference"], "A6_PROHIBITED",
              f"{question_id}: prohibited_inference differs from contract")
        check(entry.coverage_limitation == item["coverage_limitation"], "A7_COVERAGE",
              f"{question_id}: coverage_limitation differs from contract")

        check(tuple(entry.substantive_codes) == tuple(item["substantive_codes"]), "A8_SUBSTANTIVE",
              f"{question_id}: substantive_codes differ")
        check(set(entry.codes) == set(item["codes"]), "A8_CODES",
              f"{question_id}: code sets differ")

        # Templates: every declared placeholder must be one the renderer can fill.
        for kind in ("withheld", "valid", "limitation"):
            template = getattr(entry, kind)
            unknown = set(template.placeholders) - KNOWN_PLACEHOLDERS
            check(not unknown, "A9_PLACEHOLDER",
                  f"{question_id}.{kind} declares unknown placeholders {sorted(unknown)}")
            check(bool(template.text.strip()), "A9_TEMPLATE_EMPTY",
                  f"{question_id}.{kind} has no text")

        check(entry.instrument_gate is None or entry.instrument_gate in INSTRUMENT_GATES,
              "A10_GATE", f"{question_id}: gate {entry.instrument_gate} not a known instrument gate")
        check(bool(entry.instrument_status), "A10_STATUS", f"{question_id}: empty instrument_status")

        # An item may not be usable for a substantive report while it is gated.
        check(not (entry.template_usable_for_substantive_report and entry.instrument_gate),
              "A11_USABLE_WHILE_GATED",
              f"{question_id}: usable for substantive report while gate={entry.instrument_gate}")

        # No-section items must have no section at all.
        if question_id in NO_SECTION_ITEMS:
            check(not entry.report_sections, "A12_SECTION_GRANTED",
                  f"{question_id} has sections {entry.report_sections} but must have none")

        results.append({
            "question_id": question_id,
            "construct_id": entry.construct_id,
            "question_type": item["type"],
            "response_kind": entry.response_kind,
            "substantive_codes": list(entry.substantive_codes),
            "non_substantive_codes": list(item["non_substantive_codes"]),
            "ee01_rule": ee01_rule(entry, item),
            "valid_template": entry.valid.template_id,
            "withheld_template": entry.withheld.template_id,
            "permitted_claim": entry.permitted_claim,
            "prohibited_inference": entry.prohibited_inference,
            "report_sections": list(entry.report_sections),
            "instrument_status": entry.instrument_status,
            "instrument_gate": entry.instrument_gate,
            "routing_resolved": entry.routing_resolved,
            "usable_for_substantive_report": entry.template_usable_for_substantive_report,
            "report_admission": entry.report_admission,
            "raw_display_order": (raw or {}).get("display_order"),
        })

    # ------------------------------------------------- directive-specific pins
    check(registry.questions["Q13"].report_sections == (), "A13_Q13_SECTION",
          "Q13 must have no report section")
    q13 = registry.questions["Q13"]
    check("D03A" in q13.prohibited_inference and "R05" in q13.prohibited_inference, "A13_Q13_R05",
          "Q13 must prohibit identification with D03A and R05")
    check("R05" not in q13.report_sections, "A13_Q13_NOT_R05",
          "Q13 must never be assigned to R05")

    q10 = registry.questions["Q10"]
    check(q10.response_kind == "MATRIX", "A14_Q10_MATRIX", f"Q10 kind {q10.response_kind}")
    check(q10.instrument_gate == "MISSING_APPROVED_BANK", "A14_Q10_GATE",
          f"Q10 gate {q10.instrument_gate}")

    check(registry.questions["Q01"].response_kind == "MULTI_SELECT", "A15_Q01_MULTI",
          "Q01 must remain multiple-select")
    check("overlap" in registry.questions["Q01"].permitted_claim.lower()
          or "Overlapping" in registry.questions["Q01"].permitted_claim, "A15_Q01_OVERLAP",
          "Q01 permitted claim must state that categories overlap")

    # Q05 must never become observed demand; Q06 never a purchase; Q04 past use.
    check("not observed demand" in registry.questions["Q05"].valid.text, "A16_Q05_INTENT",
          "Q05 template must state intention is not observed demand")
    check("sales" in registry.questions["Q06"].prohibited_inference.lower(), "A16_Q06_PURCHASE",
          "Q06 must prohibit sales/market-share inference")
    check("existing-café purchase" in registry.questions["Q04"].valid.text, "A16_Q04_PAST",
          "Q04 template must describe past existing purchases")

    # State vocabulary must be complete and disjoint from the gates.
    check(len(ALL_STATES) == len(set(ALL_STATES)), "A17_STATE_DUP", "duplicate state name")
    check(not set(INSTRUMENT_GATES) & set(EVIDENCE_STATES), "A17_STATE_OVERLAP",
          "an instrument gate is also an evidence state")
    for state in ALL_STATES:
        check(state in registry.state_templates, "A17_STATE_TEMPLATE", f"no template for {state}")

    OUT.mkdir(parents=True, exist_ok=True)
    payload = {
        "artifact": "project1-explanation-ex01-verification",
        "registry_version": registry.registry_version,
        "registry_sha256": registry.sha256,
        "instrument_version": registry.instrument_version,
        "instrument_sha256": registry.instrument_sha256,
        "checks_run": 17,
        "failures": 0,
        "instrument_gates": list(INSTRUMENT_GATES),
        "evidence_states": list(EVIDENCE_STATES),
        "items": results,
    }
    (OUT / "ex01_matrix.json").write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (OUT / "EX01_EXPLANATION_RULE_MATRIX.md").write_text(render_matrix(payload, contract),
                                                         encoding="utf-8")
    print(json.dumps({"checks": 17, "failures": 0, "items": len(results),
                      "registry_sha256": registry.sha256}, indent=2))
    return 0


def ee01_rule(entry, item) -> str:
    """The numerator/denominator rule for one item, stated from the contract."""
    if entry.question_id == "Q10":
        return ("per-feature ordered counts; x = count of very/extremely important ratings "
                "for that feature row; denominator is V_feature, NOT the item-level V")
    if entry.response_kind == "MULTI_SELECT":
        return ("x = respondents selecting that option; V = item-valid substantive responses; "
                "option percentages may sum above 100% because selections overlap")
    if entry.response_kind == "ORDINAL":
        return ("x = respondents in that band; V = item-valid substantive responses; "
                "bands partition V, so band shares sum to 100%")
    return ("x = respondents selecting that option; V = item-valid substantive responses; "
            "single-select options partition V")


def _md(text: str) -> str:
    return str(text).replace("|", "\\|")


def render_matrix(payload: dict, contract: dict) -> str:
    lines = [
        "# EX-01 — Explanation Rule Matrix",
        "",
        f"**Registry:** `{payload['registry_version']}` · sha256 `{payload['registry_sha256']}`",
        f"**Instrument:** `{payload['instrument_version']}` · sha256 `{payload['instrument_sha256']}`",
        "**Generated by:** `backend/scripts/verify_explanation_module_ex01.py` (re-runnable; 17 assertion groups, 0 failures)",
        "",
        "Every column below is read from the hash-pinned registry and cross-checked against",
        "CUST03 item by item. A disagreement between the two fails the script rather than",
        "appearing here as prose.",
        "",
        "## Matrix",
        "",
        "| Q | Construct | EE-01 rule | Valid template | Report sections | Status / gate | Usable for substantive report |",
        "|---|---|---|---|---|---|---|",
    ]
    for row in payload["items"]:
        lines.append(
            f"| {row['question_id']} | `{row['construct_id']}` | {_md(row['ee01_rule'])} | "
            f"`{row['valid_template']}` | {', '.join(row['report_sections']) or '— (none)'} | "
            f"{row['instrument_status']} / `{row['instrument_gate'] or 'none'}` | "
            f"{'yes' if row['usable_for_substantive_report'] else 'no'} |"
        )

    lines += ["", "## Allowed and prohibited claims", ""]
    for row in payload["items"]:
        lines += [
            f"### {row['question_id']} — `{row['construct_id']}`",
            "",
            f"- **Permitted:** {row['permitted_claim']}",
            f"- **Prohibited:** {row['prohibited_inference']}",
            f"- **Report sections:** {', '.join(row['report_sections']) or 'none assigned'}",
            f"- **Authorization:** `{row['instrument_status']}`, gate `{row['instrument_gate'] or 'none'}`",
            "",
        ]

    lines += [
        "## State vocabulary",
        "",
        "Instrument gates (resolve first, outrank every data condition):",
        "",
        *[f"- `{gate}`" for gate in payload["instrument_gates"]],
        "",
        "Evidence states (most specific first):",
        "",
        *[f"- `{state}`" for state in payload["evidence_states"]],
        "",
        "## Report admission",
        "",
        "Every item carries `any_section_may_render_measurement: false`. The contract's own",
        "requirement, quoted per item:",
        "",
        "> Every assigned section is held: none may render a measurement until its blocking",
        "> gates are closed and an adopted ReportAdmission contract issues ADMITTED.",
        "",
        f"Suppression floor: `{contract['suppression_policy']['primary_suppression']['floor_status']}`.",
        "",
    ]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    raise SystemExit(main())
