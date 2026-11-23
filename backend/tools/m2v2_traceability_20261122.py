"""Emit the field-level M2 -> BCB traceability matrix from the real builder.

Every row is produced by running ``build_sections`` over a fully populated set of
confirmed declarations and walking the result. Nothing is hand-maintained, so the
matrix cannot drift from the implementation.

Writes ``deliverables/m2v2/m2_to_bcb_traceability.json`` and a Markdown table.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
OUT = REPO / "deliverables" / "m2v2"
sys.path.insert(0, str(BACKEND / "src"))

from sitewise.services.bcb_sections import build_sections  # noqa: E402

CONFIRMATION = "conf-trace-0001"

SAMPLE = {
    "M2V2-01": "UNDECIDED",
    "M2V2-02": "DINE_IN",
    "M2V2-03": ["COFFEE", "BAKED_GOODS"],
    "M2V2-04": ["STUDENTS", "OFFICE_WORKERS"],
    "M2V2-05": "STUDENTS",
    "M2V2-06": "QUALITY",
    "M2V2-07": "STUDY_WORK",
    "M2V2-08": ["PERSONAL_OBSERVATION"],
    "M2V2-09": ["CONCEPT_INTEREST", "PRICE_ACCEPTABILITY"],
    "M2V2-10": "CONCEPT_INTEREST",
    "M2V2-11": "EXPLORE",
    "M2V2-12": {"review_status": "CONFIRMED", "title": "Slow Bar",
                "details": "Focus on filter coffee."},
    "M2V2-13": {"categories": ["COFFEE"],
                "products": [{"name": "Latte", "description": "12oz"}]},
    "M2V2-14": {"decision": "PRICED", "product_ref": "Latte",
                "size_quantity": "12oz", "amount_myr": "12.50"},
    "M2V2-15": ["DINE_IN", "TAKEAWAY"],
    "M2V2-16": {"features": ["QUIET_WORK_SPACE"], "other_feature_text": None},
    "M2V2-17": {"segments": [{"group": "STUDENTS", "description": "near campus"}]},
    "M2V2-18": {"hypothesis_status": "HYPOTHESIS_IDENTIFIED",
                "hypothesis_text": "Students want quiet study space"},
    "M2V2-19": {"stage": "PLANNING", "decision_explanation": "Lease not signed"},
}


def declarations(item_map):
    out = []
    for key, value in SAMPLE.items():
        out.append({
            "item_key": key,
            "answer_state": "ANSWERED",
            "value": value,
            "answer_revision_id": f"rev-{key}",
            "item_version_id": f"iv-{key}",
            "source_hash": f"hash-{key}",
            "question": item_map[key]["question_text"],
        })
    return out


def walk(node, path, rows):
    if isinstance(node, dict):
        ref = node.get("ref")
        if isinstance(ref, dict) and ref.get("item_key"):
            rows.append({
                "bcb_field": path,
                "m2_item": ref["item_key"],
                "item_version_id": ref["item_version_id"],
                "answer_revision_id": ref["answer_revision_id"],
                "confirmation_id": ref["confirmation_id"],
                "answer_state": ref["answer_state"],
            })
            return
        for key, value in node.items():
            walk(value, f"{path}.{key}" if path else key, rows)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            walk(value, f"{path}[{i}]", rows)


def main() -> int:
    definition = json.loads((BACKEND / "src/sitewise/instruments/m2v2_20261122"
                             / "definition.json").read_text(encoding="utf-8"))
    item_map = {q["item_key"]: q for q in definition["items"]}
    sections = build_sections(declarations(item_map), item_map, CONFIRMATION)

    rows = []
    for section in ("business_description", "research_context",
                    "questionnaire_stimuli"):
        walk(sections[section], section, rows)

    covered = {r["m2_item"] for r in rows}
    all_items = set(item_map)
    report = {
        "contract": sections["contract"],
        "instrument": definition["version_tag"],
        "instrument_digest": None,
        "confirmation_id": CONFIRMATION,
        "row_count": len(rows),
        "items_with_bcb_projection": sorted(covered),
        "items_without_projection": sorted(all_items - covered),
        "rows": rows,
    }

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "m2_to_bcb_traceability.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8")

    lines = ["| BCB field | M2 item | item_version_id | answer_revision_id |",
             "|---|---|---|---|"]
    for r in rows:
        lines.append(f"| `{r['bcb_field']}` | `{r['m2_item']}` | "
                     f"`{r['item_version_id']}` | `{r['answer_revision_id']}` |")
    (OUT / "m2_to_bcb_traceability.md").write_text("\n".join(lines) + "\n",
                                                   encoding="utf-8")

    print(json.dumps({k: v for k, v in report.items() if k != "rows"}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
