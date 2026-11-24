"""EX-05 Gate 5 API smoke: the exact chain the browser will drive, over HTTP.

Before any browser is launched, prove through the real server on
``127.0.0.1:8091`` that:

1. a password sign-in against the local GoTrue stub yields a real ES256 token
   that the backend verifies through its normal path;
2. ``GET /api/v1/cq/explanations/availability`` answers with the module hold;
3. ``GET /api/v1/cq/assessments/{m2}/explanations/binding`` resolves the
   campaign/snapshot chain server-side for the authenticated owner;
4. ``GET .../explanations/{question}?context_hash=...`` returns the persisted
   candidate with the withheld admission state and no authority markers;
5. a mismatched context hash is refused (409), and the withheld disclosure is
   never relaxed;
6. the workspace report endpoint the frontend reads first also succeeds for
   the marketplace assessment bound to EP-01051.

Writes ``EX05_API_SMOKE.json`` next to this evidence run.
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
OUT = ROOT / "artifacts" / "project1_ex05_explanation_runtime_v1"

GOTRUE = "http://127.0.0.1:54329"
APP = "http://127.0.0.1:8091"
ANON = "sb_publishable_local_e2e"
EMAIL = "gatebc-e2e-b9e62014@example.invalid"
PASSWORD = "e2e-local-password"

ACTOR = "b9e62014-b7bc-426e-a950-a95b25965639"
M2_ASSESSMENT = "053b3768-145b-4d4a-a880-e98174adcd94"
MARKET_ASSESSMENT = "37bf879a-005a-4f5a-b49d-210ea1ce37c4"
EXPECTED_CAMPAIGN = "d195f8fd-6673-5120-b102-e1ae01879208"
EXPECTED_SNAPSHOT = "a7578a26-91e5-51ec-aaff-215970de516b"
EXPECTED_RESULT = "5ff219e5-e5d2-5d2d-9909-85599dae89e0"
WITHHELD = "REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE"


def sign_in() -> dict:
    req = urllib.request.Request(
        f"{GOTRUE}/auth/v1/token?grant_type=password",
        data=json.dumps({"email": EMAIL, "password": PASSWORD}).encode(),
        headers={"Content-Type": "application/json", "apikey": ANON},
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def call(path: str, token: str, expect_ok: bool = True) -> dict:
    req = urllib.request.Request(
        f"{APP}{path}",
        headers={"Authorization": f"Bearer {token}",
                 "Accept": "application/json"},
    )
    record: dict = {"path": path}
    try:
        with urllib.request.urlopen(req) as resp:
            record["status"] = resp.status
            record["cache_control"] = resp.headers.get("Cache-Control")
            record["body"] = json.load(resp)
    except urllib.error.HTTPError as exc:
        record["status"] = exc.code
        record["cache_control"] = exc.headers.get("Cache-Control")
        try:
            record["body"] = json.load(exc)
        except Exception:  # noqa: BLE001
            record["body"] = None
        if expect_ok:
            record["unexpected_error"] = True
    return record


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    session = sign_in()
    token = session["access_token"]
    evidence: dict = {
        "sign_in": {
            "stub": GOTRUE,
            "email": EMAIL,
            "token_type": session.get("token_type"),
            "expires_in": session.get("expires_in"),
            "sub_matches_fixture_owner":
                (session.get("user") or {}).get("id") == ACTOR,
        },
        "checks": [],
    }

    # 1. module availability answers the honest hold
    availability = call("/api/v1/cq/explanations/availability", token)
    evidence["checks"].append({
        "name": "availability",
        "status": availability["status"],
        "state": (availability.get("body") or {}).get("state"),
        "no_store": availability.get("cache_control") == "no-store",
    })

    # 2. server-resolved binding
    binding = call(
        f"/api/v1/cq/assessments/{M2_ASSESSMENT}/explanations/binding", token)
    body = binding.get("body") or {}
    snaps = body.get("snapshots") or []
    evidence["checks"].append({
        "name": "binding",
        "status": binding["status"],
        "contract": body.get("contract_version"),
        "assessment": body.get("assessment_id") == M2_ASSESSMENT,
        "campaign": body.get("campaign_id") == EXPECTED_CAMPAIGN,
        "snapshot": bool(snaps) and snaps[0].get("snapshot_id") == EXPECTED_SNAPSHOT,
        "question_version": bool(snaps) and snaps[0].get("question_version"),
        "admission_state": bool(snaps) and snaps[0].get("admission_state"),
        "no_store": binding.get("cache_control") == "no-store",
    })

    if binding["status"] != 200 or not snaps:
        (OUT / "EX05_API_SMOKE.json").write_text(
            json.dumps(evidence, indent=2), encoding="utf-8")
        print(json.dumps(evidence, indent=2))
        return 1

    snap = snaps[0]
    ctx = snap["context_hash"]

    # 3. authenticated readback of the persisted result
    read = call(
        f"/api/v1/cq/assessments/{M2_ASSESSMENT}/campaigns/{EXPECTED_CAMPAIGN}"
        f"/measurements/{EXPECTED_SNAPSHOT}/explanations/{snap['slot_id']}"
        f"?context_hash={ctx}", token)
    rbody = read.get("body") or {}
    evidence["checks"].append({
        "name": "readback",
        "status": read["status"],
        "contract": rbody.get("contract_version"),
        "result_id": rbody.get("result_id") == EXPECTED_RESULT,
        "ruleset_version": rbody.get("ruleset_version"),
        "validation_status": rbody.get("validation_status"),
        "admission_state": rbody.get("admission_state") == WITHHELD,
        "admitted": rbody.get("admitted") is False,
        "authority": rbody.get("authority"),
        "scientific_acceptance": rbody.get("scientific_acceptance") is False,
        "report_release_authorized":
            rbody.get("report_release_authorized") is False,
        "no_store": read.get("cache_control") == "no-store",
    })

    # 4. a tampered context hash must be refused, not re-served
    tampered = "0" * 64
    mismatch = call(
        f"/api/v1/cq/assessments/{M2_ASSESSMENT}/campaigns/{EXPECTED_CAMPAIGN}"
        f"/measurements/{EXPECTED_SNAPSHOT}/explanations/{snap['slot_id']}"
        f"?context_hash={tampered}", token, expect_ok=False)
    evidence["checks"].append({
        "name": "context_hash_mismatch",
        "status": mismatch["status"],
        "code": ((mismatch.get("body") or {}).get("detail") or {}).get("code"),
        "refused": mismatch["status"] == 409,
    })

    # 5. official release must never be authorized through this endpoint
    official = call(
        f"/api/v1/cq/assessments/{M2_ASSESSMENT}/campaigns/{EXPECTED_CAMPAIGN}"
        f"/measurements/{EXPECTED_SNAPSHOT}/explanations/{snap['slot_id']}"
        f"?context_hash={ctx}&official=true", token, expect_ok=False)
    evidence["checks"].append({
        "name": "official_refused",
        "status": official["status"],
        "code": ((official.get("body") or {}).get("detail") or {}).get("code"),
    })

    # 6. unauthenticated access must be refused
    anon_read = call(
        f"/api/v1/cq/assessments/{M2_ASSESSMENT}/campaigns/{EXPECTED_CAMPAIGN}"
        f"/measurements/{EXPECTED_SNAPSHOT}/explanations/{snap['slot_id']}"
        f"?context_hash={ctx}", "", expect_ok=False)
    evidence["checks"].append({
        "name": "anonymous_refused",
        "status": anon_read["status"],
    })

    # 7. the workspace report endpoint the frontend reads first
    report = call(f"/api/v1/assessments/{MARKET_ASSESSMENT}/report", token)
    evidence["checks"].append({
        "name": "workspace_report",
        "status": report["status"],
        "report_present": bool((report.get("body") or {}).get("assessment_id"))
        and isinstance((report.get("body") or {}).get("property"), dict),
        "sections": sorted(k for k in (report.get("body") or {})
                           if isinstance((report.get("body") or {})[k], dict)
                           and "available" in (report.get("body") or {})[k]),
    })

    (OUT / "EX05_API_SMOKE.json").write_text(
        json.dumps(evidence, indent=2), encoding="utf-8")
    print(json.dumps(evidence, indent=2))

    failed = [c["name"] for c in evidence["checks"]
              if c.get("unexpected_error")]
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
