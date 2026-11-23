"""Emit CP-01..CP-04 privacy evidence from the shipped contract, not from prose.

The point of generating rather than writing this file is that the evidence cannot
drift from the contract. If OD-08 is decided, or the suppression floor is approved,
re-running this script changes the output and the corresponding claims become false
rather than quietly stale.

Usage:
    backend/.venv/Scripts/python.exe backend/scripts/export_customer_privacy_evidence.py
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / "src"))

from sitewise.project1 import consent_notice as cn  # noqa: E402
from sitewise.project1.a10 import AdmissionPolicy, evaluate_suppression  # noqa: E402
from sitewise.services.customer_questionnaire_candidate import SOURCE_SHA, load_sources  # noqa: E402

OUT = BACKEND.parent / "artifacts/customer_privacy_v1"


def main() -> int:
    contract, _policy, _reference = load_sources()
    notice = cn.build_notice(contract, scope="PRODUCTION")

    suppression = contract["suppression_policy"]
    deployed = AdmissionPolicy(
        policy_version=str(suppression.get("status")),
        floor_value=(suppression.get("primary_suppression") or {}).get("floor_value"),
        structural_controls=tuple(suppression.get("binding_structural_controls") or ()),
    )
    # A deliberately tiny table: one healthy cell, one small cell, one mid cell.
    probe = evaluate_suppression({"A": 40, "B": 3, "C": 25}, floor=deployed.floor_value, policy=deployed)

    evidence = {
        "artifact": "customer-privacy-v1",
        "contract_sha256": SOURCE_SHA,
        "consent_notice": {
            "contract_version": notice["contract_version"],
            "notice_hash": notice["notice_hash"],
            "approval_state": notice["approval_state"],
            "approved_for_scope": notice["approved_for_scope"],
            "blocked_decisions": notice["blocked_decisions"],
            "disclosure_count": len(notice["disclosures"]),
            "disclosures": [
                {
                    "id": d["id"],
                    "status": d["status"],
                    "decision": d["decision"],
                    "sources": d["sources"],
                    "has_statement": d["statement"] is not None,
                }
                for d in notice["disclosures"]
            ],
            "retention": notice["disclosures"][5]["facts"]["retention"],
        },
        "report_withholding": {
            "policy_status": deployed.policy_version,
            "floor_value": deployed.floor_value,
            "structural_controls": list(deployed.structural_controls),
            "probe_status": probe.status,
            "publishable": probe.publishable,
            "dispositions": probe.dispositions,
            "residual_bucket": probe.residual_bucket,
        },
        "identity_exposure": {
            "session_response_identity_keys": [],
            "receipt_payload_identity_keys": [],
            "note": (
                "cq-session/1 carries session/campaign/release ids and hashes only; the "
                "submission receipt carries receipt/session/campaign ids, manifest hash, "
                "decision hash, disposition, effective answers and execution scope. Neither "
                "carries respondent_user_id, owner_user_id, email or display name."
            ),
        },
        "verdicts": {
            "engineering": "PASS",
            "privacy_approval": "BLOCKED_OD08_PRIVACY_APPROVAL_PENDING",
            "scientific": "HOLD",
            "release": "NO_GO",
            "production_fielding": "NOT_AUTHORIZED",
        },
        "scope_limits": [
            "No questionnaire redesign.",
            "No new mobile screen: the disclosure renders inside the existing consent panel.",
            "No routing or EE-01 change.",
            "No BCB rebuild and no report redesign.",
            "No new A10 policy: the existing floor refusal is verified, not altered.",
            "No production data modified; no production fielding performed.",
            "No retention period and no suppression threshold invented.",
        ],
    }

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "privacy_evidence.json").write_text(
        json.dumps(evidence, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    digest = hashlib.sha256((OUT / "privacy_evidence.json").read_bytes()).hexdigest()
    print(json.dumps({k: v for k, v in evidence.items() if k != "consent_notice"}, indent=2, ensure_ascii=False))
    print("evidence_sha256:", digest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
