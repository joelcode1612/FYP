"""Read-only consistency assessment of the 58 features outside the v2 recalculation.

The assessment uses the committed Expanded64 parity evidence, the runtime
category contract and the original training CSV. It does not modify any value,
definition or database row.
"""
from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT.parent / "backend"
sys.path.insert(0, str(BACKEND / "src"))

from sitewise.services.expanded64_enrichment import _category  # noqa: E402

PARITY = BACKEND.parent / "docs" / "expanded64-operational-parity.csv"
TRAINING = ROOT / "original_training_data" / "SiteWise_PU_1796_Expanded_Observed.csv"
INVENTORY = ROOT / "expanded64_v2_source_inventory.json"

SIX = {
    "road_length_density_500m_km_km2",
    "osm_walkway_length_density_500m_km_km2",
    "pop_2000m", "pop_3000m",
    "walk_isochrone_area_10min_km2", "worldpop_walk_reachable_10min",
}


def main() -> None:
    with PARITY.open(encoding="utf-8", newline="") as fp:
        parity = {row["Feature"]: row for row in csv.DictReader(fp)}
    with TRAINING.open(encoding="utf-8-sig", newline="") as fp:
        rows = list(csv.DictReader(fp))
    assert len(rows) == 1796
    assert len(parity) == 64

    out = []
    for name, meta in parity.items():
        if name in SIX:
            continue
        non_null = sum(1 for row in rows if row.get(name) not in (None, ""))
        evidence = meta["Training parity result"] or "No parity evidence recorded"
        eligibility = meta["Operational eligibility"] or "Unstated"
        issue = meta["Remaining issue"] or ""
        flag = ""
        if ("0/" in evidence or "Full 1796-row" in evidence or "all fail" in evidence.lower()
                or "Diagnostic only" in eligibility):
            flag = "definition_or_coverage_unresolved"
        justification = (
            "Retain original training values for retraining: the model was trained on them. "
            "No historical value was replaced, and no runtime value was substituted."
        )
        if flag:
            justification += (
                " Runtime parity is unresolved; do not interpret runtime measurements as "
                "equivalent when scoring the original artifact."
            )
        else:
            justification += (
                " Runtime calculator has recorded parity/eligibility evidence; retention is "
                "still required because retraining uses the historical training distribution."
            )
        out.append({
            "feature": name,
            "category": _category(name),
            "training_data_non_null_count": non_null,
            "original_training_source": meta["Original training data source"],
            "current_operational_source": meta["Current operational source or diagnostic candidate"],
            "python_collection_method": meta["Python collection method"],
            "training_parity_result": evidence,
            "operational_eligibility": eligibility,
            "remaining_issue": issue,
            "inconsistency_flag": flag,
            "historical_value_action": "retained_unchanged",
            "justification": justification,
        })

    fields = list(out[0])
    with (ROOT / "expanded64_v2_remaining58_validation.csv").open(
        "w", encoding="utf-8", newline=""
    ) as fp:
        writer = csv.DictWriter(fp, fieldnames=fields)
        writer.writeheader()
        writer.writerows(out)

    inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))
    doc = {
        "generated_at_from_inventory_utc": inventory["generated_at_utc"],
        "definition_version": "expanded64-feature-definitions-v1",
        "features_assessed": len(out),
        "retained_unchanged": len(out),
        "flagged_inconsistent_or_unresolved": sum(1 for r in out if r["inconsistency_flag"]),
        "method": (
            "Read-only cross-check of the committed 64-feature parity evidence, the runtime "
            "category mapping and the original 1,796-row training CSV. No database write, "
            "no value substitution, no definition change."
        ),
        "excluded_from_assessment": sorted(SIX),
    }
    (ROOT / "expanded64_v2_remaining58_validation.json").write_text(
        json.dumps(doc, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print(f"Assessed {len(out)} features; flagged {doc['flagged_inconsistent_or_unresolved']}")


if __name__ == "__main__":
    main()
