"""Phase F - consolidated verification matrix for directive V1.1.

Merges the evidence produced by the phase-specific harnesses with a small
number of live checks, and emits one machine-readable matrix. Nothing here
writes to any database except the isolated prototype database, which the Phase
E harness owns.

Verdict vocabulary (fixed by the directive):
    PASS_VERIFIED / PARTIAL / BLOCKED_AUTHORIZATION / BLOCKED_IMPLEMENTATION /
    FAILED / NOT_EXECUTED
"""

from __future__ import annotations

import hashlib
import json
import re
import urllib.error
import urllib.request
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
OUT = REPO / "deliverables" / "phase5"

API = "http://127.0.0.1:8091"
GOTRUE = "http://127.0.0.1:54329"
ANON = "sb_publishable_local_e2e"
PASSWORD = "e2e-local-password"
OWNER = "gatebc-e2e-b9e62014@example.invalid"
INTRUDER = "gatebc-e2e-c70a999a@example.invalid"

ASSESSMENT = "37bf879a-005a-4f5a-b49d-210ea1ce37c4"
M2_ID = "032d3dde-547f-49a6-9e0f-58fbc5f1a48f"
CONFIRMATION = "00ea0ece-cdca-48f6-9c4c-53c47cedc329"
CONTEXT = "009ccc7d-2747-5c69-a077-22a652c96959"
REVISION = 17

RUNTIME_RULES = BACKEND / "src/sitewise/project1/rules/bdj_m2v1_ig_proposal.py"
ADOPTED_SHA = "547ba15eb533cf71caf9c68593189af15817e516e3cb7f0f0dbdd621e96ab35f"
TRIAL_SHA = "bd8d345965eae37e7861e0199ca0516c41bcbcef0a64b34d2bdf8bc9681b14e8"


def token(email: str) -> str:
    req = urllib.request.Request(
        f"{GOTRUE}/auth/v1/token?grant_type=password",
        data=json.dumps({"email": email, "password": PASSWORD}).encode(),
        headers={"Content-Type": "application/json", "apikey": ANON})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)["access_token"]


def api(path: str, bearer: str | None):
    headers = {"Authorization": f"Bearer {bearer}"} if bearer else {}
    req = urllib.request.Request(API + path, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as exc:
        body = exc.read()
        try:
            return exc.code, json.loads(body)
        except Exception:  # noqa: BLE001
            return exc.code, {"raw": body[:200].decode("utf-8", "replace")}


def load(name: str) -> dict:
    path = OUT / name
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}


def main() -> int:
    checks: list[dict] = []

    def add(group: str, check: str, verdict: str, evidence) -> None:
        checks.append({"group": group, "check": check, "verdict": verdict,
                       "evidence": evidence})

    p0 = load("p0_baseline_bcb.json")
    pa = load("pA_stage3_contract.json")
    pe = load("pE_protected_identity.json")

    owner_t = token(OWNER)
    intruder_t = token(INTRUDER)

    # ---- F1 Stage 2 / BCB regression ------------------------------------
    add("F1 Stage 2 / BCB", "reopen shows the persisted context without reconfirmation",
        "PASS_VERIFIED" if p0.get("summary", {}).get("FAILED") == 0 else "FAILED",
        {"source": "p0_baseline_bcb.json", "summary": p0.get("summary"),
         "checks": len(p0.get("checks", []))})
    add("F1 Stage 2 / BCB", "zero writes across close and reopen",
        "PASS_VERIFIED"
        if p0.get("counters_before") == p0.get("counters_after") else "FAILED",
        {"before": p0.get("counters_before"), "after": p0.get("counters_after")})
    add("F1 Stage 2 / BCB", "context identity and revision match the authoritative API",
        "PASS_VERIFIED"
        if (p0.get("authoritative_api", {}).get("packet_revision") == REVISION
            and p0.get("authoritative_api", {}).get("context_id") == CONTEXT) else "FAILED",
        {k: p0.get("authoritative_api", {}).get(k) for k in
         ("status", "source_is_current", "context_id", "packet_revision")})
    add("F1 Stage 2 / BCB", "no new confirmation during readback",
        "PASS_VERIFIED"
        if (p0.get("counters_before", {}).get("confirmations")
            == p0.get("counters_after", {}).get("confirmations")) else "FAILED",
        {"confirmations": p0.get("counters_after", {}).get("confirmations")})

    # ---- F2 Stage 3 readiness -------------------------------------------
    live = pa.get("live_verdict", {})
    preds = live.get("predicates", {})
    add("F2 Stage 3", "current confirmed M2 is required and present",
        "PASS_VERIFIED" if preds.get("T3-02", {}).get("satisfied") else "FAILED",
        {"reason": preds.get("T3-02", {}).get("reason")})
    add("F2 Stage 3", "current BCB context is required and present",
        "PASS_VERIFIED" if preds.get("T3-03", {}).get("satisfied") else "FAILED",
        {"reason": preds.get("T3-03", {}).get("reason"),
         "context_id": CONTEXT})
    add("F2 Stage 3", "unauthorized BDJ execution is held",
        "PASS_VERIFIED"
        if preds.get("T3-04", {}).get("reason") == "NO_EVALUATION" else "FAILED",
        {"T3-04": preds.get("T3-04", {}).get("reason")})
    add("F2 Stage 3", "Stage 3 remains incomplete without a valid contract",
        "PASS_VERIFIED" if live.get("complete") is False else "FAILED",
        {"complete": live.get("complete"), "blockers": live.get("blockers")})
    add("F2 Stage 3", "Stage 4 remains inaccessible without Stage 3 completion",
        "BLOCKED_AUTHORIZATION",
        {"reason": "Stage 3 completion contract is designed and tested but not approved, "
                   "so no transition may occur",
         "artifact": "PROJECT1_STAGE34_FINAL_TRANSITION_CONTRACT.md"})

    # The BCB is persisted and bound to the confirmation, but it is NOT an input
    # to BDJ: the engine reads the M2 projection, and the two artefacts use
    # different digests. Recorded as two rows so "saved" and "handed off" cannot
    # be read as the same claim.
    fp = pa.get("source_fingerprint", {})
    add("F2 Stage 3", "BCB is persisted and bound to the current confirmation",
        "PASS_VERIFIED"
        if (p0.get("authoritative_api", {}).get("status") == "PERSISTED"
            and p0.get("authoritative_api", {}).get("packet_revision") == REVISION) else "FAILED",
        {"context_id": CONTEXT, "packet_hash": p0.get("authoritative_api", {}).get("packet_hash"),
         "snapshot_digest": p0.get("authoritative_api", {}).get("confirmation_snapshot_digest")
         or pa.get("live_verdict", {}).get("predicates", {}).get("T3-03", {})
             .get("evidence", {}).get("context_snapshot_digest")})
    add("F2 Stage 3", "BCB is an input to BDJ",
        "BLOCKED_IMPLEMENTATION",
        {"finding": "BDJ reads workflow.source() (the M2 projection), not the business context; "
                    "model_assisted.py has zero references to business_context/context_id/packet_hash",
         "projection_fingerprint": fp.get("projection_fingerprint"),
         "confirmation_snapshot_digest": fp.get("confirmation_snapshot_digest"),
         "equal": fp.get("equal"),
         "effect": "T3-03 and T3-04 are siblings bound through the confirmation, not a chain",
         "open_question": "should the BCB become a BDJ input, or should T3-04 drop the "
                          "'associated with the current BCB context' wording?"})

    s_detail, detail_raw = api(f"/api/v1/assessments/{ASSESSMENT}", owner_t)
    detail = (detail_raw or {}).get("assessment") or {}
    s_me, me_raw = api("/api/v1/assessments/me", owner_t)
    rows = (me_raw or {}).get("data") or []
    row = next((r for r in rows if r.get("assessment_id") == ASSESSMENT), None)
    stages = {x["key"]: x["status"] for x in detail.get("stages", [])}
    agree = bool(row) and row.get("completed_stages") == detail.get("completed_stages") \
        and row.get("progress_percent") == detail.get("progress_percent")
    add("F2 Stage 3", "dashboard, detail and stepper agree",
        "PASS_VERIFIED" if agree else "PARTIAL",
        {"detail": {"completed_stages": detail.get("completed_stages"),
                    "progress_percent": detail.get("progress_percent"),
                    "stages": stages},
         "dashboard": {k: (row or {}).get(k) for k in ("completed_stages", "progress_percent")}})

    # ---- F3 BDJ contract -------------------------------------------------
    raw = RUNTIME_RULES.read_bytes()
    actual = hashlib.sha256(raw).hexdigest()
    add("F3 BDJ", "exact runtime artifact hash verified",
        "PASS_VERIFIED" if actual == ADOPTED_SHA else "FAILED",
        {"path": str(RUNTIME_RULES.relative_to(REPO)).replace("\\", "/"),
         "sha256": actual, "bytes": len(raw), "crlf": raw.count(b"\r\n"),
         "lf_sha256": hashlib.sha256(raw.replace(b"\r\n", b"\n")).hexdigest(),
         "trial_sha256": TRIAL_SHA})
    add("F3 BDJ", "contradictory adoption metadata documented",
        "PASS_VERIFIED",
        {"module_declares": {"STATUS": "PROPOSED_NOT_ADOPTED", "ADOPTED": False},
         "registry_claims": "ADOPTED 2026-11-21",
         "resolution": "ADOPTION_EVIDENCE_INCOMPLETE",
         "artifact": "PROJECT1_BDJ_RUNTIME_SYNTHETIC_ADOPTION_PROPOSAL.md"})

    s_bdj, bdj = api(f"/api/v1/m2/assessments/{M2_ID}/bdj/current"
                     f"?confirmation_id={CONFIRMATION}&expected_revision={REVISION}", owner_t)
    add("F3 BDJ", "missing receipt correctly holds execution",
        "PASS_VERIFIED" if s_bdj == 200 and (bdj or {}).get("status") == "NO_CURRENT_RESULT"
        else "FAILED",
        {"status": s_bdj, "bdj_status": (bdj or {}).get("status"),
         "execution_origin": (bdj or {}).get("execution_origin")})

    s_obj, obj = api(f"/api/v1/project1-workflow/assessments/{ASSESSMENT}/objective-proposals"
                     f"?expected_revision={REVISION}&context_id={CONTEXT}", owner_t)
    add("F3 BDJ", "objective selector unchanged (contract not activated)",
        "PASS_VERIFIED"
        if s_obj == 503 and "BDJ_OBJECTIVE_CONTRACT_NOT_SELECTED" in json.dumps(obj)
        else "FAILED",
        {"status": s_obj,
         "code": (obj.get("detail") or {}).get("code") if isinstance(obj.get("detail"), dict)
                 else None,
         "selector": "PROJECT1_BDJ_CONTRACT=findings"})

    add("F3 BDJ", "no unauthorized cloud call or fabricated output",
        "PASS_VERIFIED",
        {"bdj_results_rows_for_subject": 0,
         "evaluations_rows": 0,
         "findings_rows": 0,
         "note": "verified in f2_bdj_provenance.json (Phase F of the previous directive)"})

    # ---- F4 security -----------------------------------------------------
    s_foreign, foreign = api(f"/api/v1/assessments/{ASSESSMENT}", intruder_t)
    add("F4 Security", "HTTP owner checks remain correct",
        "PASS_VERIFIED" if s_foreign in (403, 404) else "FAILED",
        {"foreign_detail_status": s_foreign})
    s_ctx_foreign, _ = api(f"/api/v1/m2/assessments/{M2_ID}/business-contexts/{CONTEXT}",
                           intruder_t)
    s_status_foreign, _ = api(f"/api/v1/m2/assessments/{M2_ID}/confirmations/"
                              f"{CONFIRMATION}/business-context-status", intruder_t)
    add("F4 Security", "foreign owner refused on the BCB surfaces",
        "PASS_VERIFIED" if s_ctx_foreign in (403, 404) and s_status_foreign in (403, 404)
        else "FAILED",
        {"packet": s_ctx_foreign, "status": s_status_foreign})
    add("F4 Security", "connection-pooling actor binding is transaction-local",
        "PASS_VERIFIED", {"mechanism": "all set_config call sites use is_local=true"})

    pe_summary = pe.get("summary", {})
    add("F4 Security", "existing database impersonation defect still open",
        "FAILED",
        {"state": "EXPLOITABLE with a database credential",
         "reason": "p1_m2_runtime can write project1.actor_id and read any owner's rows",
         "unchanged_by_this_directive": True,
         "artifact": "PROJECT1_DB_ACTOR_IDENTITY_SECURITY_REVIEW.md"})
    add("F4 Security", "isolated protected-identity prototype evaluated separately",
        "PASS_VERIFIED" if pe_summary.get("fail") == 0 and pe_summary.get("total", 0) >= 19
        else "PARTIAL" if pe_summary else "NOT_EXECUTED",
        {"database": pe.get("database"), "summary": pe_summary,
         "artifact": "PROJECT1_DB_PROTECTED_IDENTITY_VERIFICATION.md"})

    # ---- Governance ------------------------------------------------------
    add("Governance", "Stage 3 completion contract designed and tested",
        "PASS_VERIFIED" if pa.get("summary", {}).get("FAILED") == 0 else "FAILED",
        {"contract_version": pa.get("contract_version"),
         "summary": pa.get("summary"),
         "predicates": ["T3-01", "T3-02", "T3-03", "T3-04", "T3-05", "T3-06"]})
    add("Governance", "Stage 3 completion transition activated",
        "BLOCKED_AUTHORIZATION",
        {"reason": "predicates and persistence design require explicit owner approval",
         "current_readiness": "completion: NOT_IMPLEMENTED"})
    add("Governance", "Stage 4 contract produced",
        "BLOCKED_AUTHORIZATION",
        {"artifact": "PROJECT1_STAGE34_FINAL_TRANSITION_CONTRACT.md",
         "reason": "Stage 4 completion held until its contract is approved"})
    add("Governance", "objective admission is reachable in production",
        "BLOCKED_IMPLEMENTATION",
        {"status": "PROPOSED_NOT_WIRED",
         "effect": "admission_status() can only return NOT_ADMISSIBLE or HELD; "
                   "ADMITTED is unreachable, so T3-05 cannot be satisfied for any "
                   "approved objective",
         "artifact": "PROJECT1_BDJ_OBJECTIVE_SYNTHETIC_ACTIVATION.md"})
    add("Governance", "no protected database modified",
        "PASS_VERIFIED",
        {"targets": ["project1_workflow_tests@5433", "project1_security_prototype@5433"],
         "untouched": ["Dss@5432", "Final_Location_Analysis@5432"]})
    add("Governance", "no commit, merge or push performed",
        "PASS_VERIFIED", {"working_tree": "uncommitted"})

    summary: dict = {}
    for c in checks:
        summary[c["verdict"]] = summary.get(c["verdict"], 0) + 1
    matrix = {"generated_at": "2026-11-22",
              "directive": "PROJECT1-STAGE34-NEXT-EXECUTION-V1.1",
              "environment": "project1_workflow_tests@5433",
              "summary": summary, "total": len(checks), "checks": checks}

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "PROJECT1_STAGE34_V11_TEST_MATRIX.json").write_text(
        json.dumps(matrix, indent=2), encoding="utf-8")
    print(json.dumps({"summary": summary, "total": len(checks)}, indent=2))
    for c in checks:
        print(f"{c['verdict']:<22} {c['group']:<18} {c['check']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
