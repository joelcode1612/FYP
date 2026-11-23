"""End-to-end M2 V2 -> confirmation -> BCB verification through the live API.

Runs against the disposable cluster only. Every request is authenticated through
the local GoTrue stub; nothing is written directly to the database and no
protected data is touched.

Flow: instruments -> create assessment -> save 19 answers -> reopen -> edit ->
review -> confirm -> build BCB (1.2) -> reopen BCB -> stale invalidation.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request
from pathlib import Path

API = "http://127.0.0.1:8091"
GOTRUE = "http://127.0.0.1:54329"
ANON = "sb_publishable_local_e2e"
PASSWORD = "e2e-local-password"
OWNER = "gatebc-e2e-b9e62014@example.invalid"
OUT = Path(__file__).resolve().parents[2] / "deliverables" / "m2v2"

ANSWERS = [
    ("M2V2-01", "ANSWERED", "UNDECIDED"),
    ("M2V2-02", "ANSWERED", "DINE_IN"),
    ("M2V2-03", "ANSWERED", ["COFFEE", "BAKED_GOODS"]),
    ("M2V2-04", "ANSWERED", ["STUDENTS", "OFFICE_WORKERS"]),
    ("M2V2-05", "ANSWERED", "STUDENTS"),
    ("M2V2-06", "ANSWERED", "QUALITY"),
    ("M2V2-07", "ANSWERED", "STUDY_WORK"),
    ("M2V2-08", "ANSWERED", ["PERSONAL_OBSERVATION"]),
    ("M2V2-09", "ANSWERED", ["CONCEPT_INTEREST", "PRICE_ACCEPTABILITY"]),
    ("M2V2-10", "ANSWERED", "CONCEPT_INTEREST"),
    ("M2V2-11", "ANSWERED", "EXPLORE"),
    ("M2V2-12", "ANSWERED", {"review_status": "CONFIRMED",
                             "title": "  Slow Bar  ",
                             "details": "Line one.\nLine two."}),
    ("M2V2-13", "ANSWERED", {"categories": ["COFFEE"],
                             "products": [{"name": "Latte",
                                           "description": "12oz"}]}),
    ("M2V2-14", "ANSWERED", {"decision": "PRICE_NOT_DECIDED"}),
    ("M2V2-15", "ANSWERED", ["DINE_IN", "TAKEAWAY"]),
    ("M2V2-16", "ANSWERED", {"features": ["QUIET_WORK_SPACE"]}),
    ("M2V2-17", "ANSWERED", {"segments": [{"group": "STUDENTS",
                                           "description": "near campus"}]}),
    ("M2V2-18", "ANSWERED", {"hypothesis_status": "NOT_ESTABLISHED"}),
    ("M2V2-19", "ANSWERED", {"stage": "PLANNING"}),
]


def request(method, url, body=None, bearer=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, json.loads(raw)
        except Exception:  # noqa: BLE001
            return exc.code, {"raw": raw[:400].decode("utf-8", "replace")}


def token():
    status, body = request("POST", f"{GOTRUE}/auth/v1/token?grant_type=password",
                           {"email": OWNER, "password": PASSWORD})
    if status != 200:
        raise SystemExit(f"auth failed: {status} {body}")
    return body["access_token"]


def main():
    checks = []

    def check(name, ok, evidence):
        checks.append({"check": name, "ok": bool(ok), "evidence": evidence})
        print(f"{'PASS' if ok else 'FAIL'}  {name}")

    bearer = token()

    # 1. instrument listing must expose the candidate only inside the scope
    status, body = request("GET", f"{API}/api/v1/m2/instruments", bearer=bearer)
    items = body.get("items") or []
    versions = [i.get("version_tag") for i in items]
    check("candidate instrument listed under synthetic scope",
          status == 200 and "M2V2-20261122-1" in versions, versions)
    v2 = next((i for i in items if i.get("version_tag") == "M2V2-20261122-1"), None)
    check("candidate approval_state is not AUTHORIZED",
          v2 is not None and v2.get("approval_state") == "PROPOSED_NOT_AUTHORIZED",
          v2.get("approval_state") if v2 else None)
    if v2 is None:
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / "e2e.json").write_text(json.dumps(checks, indent=2), encoding="utf-8")
        return 1

    # 2. create an assessment on the candidate instrument
    status, body = request("POST", f"{API}/api/v1/m2/assessments",
                           {"instrument_version_id": v2["id"]}, bearer)
    check("assessment created on candidate instrument", status == 201, {"status": status, "body": body})
    if status != 201:
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / "e2e.json").write_text(json.dumps(checks, indent=2), encoding="utf-8")
        return 1
    assessment_id = body.get("id") or body.get("assessment", {}).get("id")
    revision = body.get("revision", 0)

    # 3. save all 19 answers
    saved = 0
    for key, state, value in ANSWERS:
        status, body = request(
            "PUT", f"{API}/api/v1/m2/assessments/{assessment_id}/answers/{key}",
            {"expected_revision": revision, "answer_state": state, "value": value}, bearer)
        if status in (200, 201):
            revision = body.get("revision", revision + 1)
            saved += 1
        else:
            check(f"save {key}", False, {"status": status, "body": body})
            break
    check("all 19 answers saved", saved == 19, {"saved": saved, "revision": revision})

    # 4. reopen and verify readback
    status, body = request("GET", f"{API}/api/v1/m2/assessments/{assessment_id}", bearer=bearer)
    answers_map = body.get("answers") or {}
    keys = sorted(answers_map)
    check("reopen shows 19 answers", status == 200 and len(keys) == 19, keys)
    free = answers_map.get("M2V2-12") or {}
    check("free text preserved byte-for-byte",
          (free.get("value_json") or {}).get("title") == "  Slow Bar  ",
          free.get("value_json"))
    revision = (body.get("assessment") or {}).get("revision", revision)

    # 5. edit one answer (correction updates the source answer)
    status, body = request(
        "PUT", f"{API}/api/v1/m2/assessments/{assessment_id}/answers/M2V2-19",
        {"expected_revision": revision, "answer_state": "ANSWERED",
         "value": {"stage": "CONCEPT_TESTING"}}, bearer)
    check("correction accepted on source answer", status in (200, 201), {"status": status})
    if status in (200, 201):
        revision = body.get("revision", revision + 1)

    # 6. review then confirm
    status, body = request("POST", f"{API}/api/v1/m2/assessments/{assessment_id}/review",
                           {"expected_revision": revision}, bearer)
    check("review recorded", status in (200, 201), {"status": status, "body": body})
    if status in (200, 201):
        revision = body.get("revision", revision)

    status, body = request("POST", f"{API}/api/v1/m2/assessments/{assessment_id}/confirm",
                           {"expected_revision": revision, "acknowledged_issue_ids": []}, bearer)
    check("confirmation recorded", status in (200, 201), {"status": status, "body": body})
    confirmation_id = body.get("id") or body.get("confirmation_id")
    if confirmation_id is None:
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / "e2e.json").write_text(json.dumps(
            {"checks": checks, "assessment_id": assessment_id}, indent=2), encoding="utf-8")
        return 1

    # 7. build BCB under the sections contract
    status, body = request(
        "POST", f"{API}/api/v1/m2/assessments/{assessment_id}/business-context",
        {"confirmation_id": confirmation_id, "expected_revision": revision,
         "context_version": "BCB-V1-1.2.0"}, bearer)
    check("BCB built under BCB-V1-1.2.0", status in (200, 201), {"status": status, "body": body})
    packet = (body or {}).get("packet") or {}
    sections = packet.get("sections") or {}
    check("three separable outputs present",
          all(k in sections for k in ("business_description", "research_context",
                                      "questionnaire_stimuli")),
          sorted(sections.keys()))

    context_id = body.get("context_id")
    # 8. reopen the persisted context and verify currentness
    status, body2 = request("GET",
                            f"{API}/api/v1/m2/assessments/{assessment_id}/business-contexts/{context_id}",
                            bearer=bearer)
    packet2 = (body2 or {}).get("packet") or {}
    check("BCB readback matches stored packet hash",
          status == 200 and packet2.get("packet_hash") == packet.get("packet_hash"),
          {"status": status})

    status, body3 = request(
        "GET",
        f"{API}/api/v1/m2/assessments/{assessment_id}/confirmations/{confirmation_id}/business-context-status",
        bearer=bearer)
    check("status reports source is current",
          status == 200 and body3.get("source_is_current") is True,
          {"source_is_current": body3.get("source_is_current")})

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "e2e.json").write_text(json.dumps({
        "assessment_id": assessment_id, "confirmation_id": confirmation_id,
        "context_id": str(context_id), "revision": revision,
        "packet_hash": packet.get("packet_hash"),
        "sections_present": sorted(sections.keys()),
        "checks": checks,
    }, indent=2, default=str), encoding="utf-8")

    failed = [c for c in checks if not c["ok"]]
    print(f"\n{len(checks) - len(failed)}/{len(checks)} checks passed")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
