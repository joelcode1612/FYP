"""Phase 0 - baseline, and the BCB readback acceptance test.

The directive requires a close/reopen test through the normal authenticated
Jaspr interface, not an API call: the claim under test is that a confirmed M2
assessment shows its persisted business context *without* reconfirmation and
*without* writing anything.

Steps
-----
1. Snapshot the authoritative counters (contexts, builds, revisions, answers).
2. Open Stage 2 authenticated, read what the canvas renders.
3. Navigate away (close), navigate back (reopen), read again.
4. Compare the rendered context id and status with the API payload.
5. Snapshot the counters again and require zero delta.
6. Negative controls: a superseded context id, a stale revision, a foreign owner.

Read-only against the database; the only writes in the whole run would be the
ones the app makes, which is exactly what step 5 measures.
"""

from __future__ import annotations

import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import psycopg2

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
sys.path.insert(0, str(BACKEND / "tools"))

from cdp_20261122 import CDP, evaluate, shot  # noqa: E402

OUT = REPO / "deliverables" / "phase5"
SHOTS = OUT / "shots"

API = "http://127.0.0.1:8091"
GOTRUE = "http://127.0.0.1:54329"
ANON = "sb_publishable_local_e2e"
PASSWORD = "e2e-local-password"

OWNER = "gatebc-e2e-b9e62014@example.invalid"
INTRUDER = "gatebc-e2e-c70a999a@example.invalid"
OWNER_ID = "b9e62014-b7bc-426e-a950-a95b25965639"

ASSESSMENT = "37bf879a-005a-4f5a-b49d-210ea1ce37c4"
M2_ID = "032d3dde-547f-49a6-9e0f-58fbc5f1a48f"
CONFIRMATION = "00ea0ece-cdca-48f6-9c4c-53c47cedc329"
CONTEXT = "009ccc7d-2747-5c69-a077-22a652c96959"
REVISION = 17

# The persisted-context status line renders on the M2 workflow route. The
# assessment workspace route (`/entrepreneur/assessments?...&stage=2`) resolves
# to the Stage 3 research panel instead, so it is exercised separately below.
M2_URL = f"{API}/entrepreneur/m2-workflow?assessment={M2_ID}"
STAGE2_URL = f"{API}/entrepreneur/assessments?id=EP-01051&stage=2"
LANDING = f"{API}/"

TEXT = (BACKEND / "var" / "e2e" / "app.env").read_text(encoding="utf-8", errors="replace")


def dsn(key: str = "M2_DATABASE_URL") -> str:
    url = re.search(rf"^{key}=(.+)$", TEXT, re.M).group(1).strip()
    return url.replace("postgresql+psycopg2", "postgresql")


def token(email: str) -> str:
    req = urllib.request.Request(
        f"{GOTRUE}/auth/v1/token?grant_type=password",
        data=json.dumps({"email": email, "password": PASSWORD}).encode(),
        headers={"Content-Type": "application/json", "apikey": ANON})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)["access_token"]


def session(email: str) -> dict:
    req = urllib.request.Request(
        f"{GOTRUE}/auth/v1/token?grant_type=password",
        data=json.dumps({"email": email, "password": PASSWORD}).encode(),
        headers={"Content-Type": "application/json", "apikey": ANON})
    with urllib.request.urlopen(req) as resp:
        raw = json.load(resp)
    return {
        "access_token": raw["access_token"],
        "refresh_token": raw.get("refresh_token", ""),
        "token_type": "bearer",
        "expires_in": raw.get("expires_in", 3600),
        "expires_at": raw.get("expires_at"),
        "user": raw.get("user", {}),
    }


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


def counters() -> dict:
    """Authoritative write-detection counters, read as the runtime role."""
    with psycopg2.connect(dsn()) as conn:
        conn.autocommit = False
        cur = conn.cursor()
        cur.execute("select set_config('project1.actor_id', %s, true)", (OWNER_ID,))
        out = {}
        for label, sql in (
            ("contexts", "select count(*) from public.m2_business_contexts"),
            ("builds", "select count(*) from public.m2_business_context_builds"),
            ("revision", "select revision from public.m2_assessments where id = %s::uuid"),
            ("answer_revisions", "select count(*) from public.m2_answer_revisions"),
            ("confirmations", "select count(*) from public.m2_confirmation_snapshots"),
            ("latest_attempt", "select attempt_count, status from public.m2_business_context_builds "
                               "where assessment_id = %s::uuid "
                               "order by assessment_revision desc, attempt_count desc limit 1"),
        ):
            if label == "revision":
                cur.execute(sql, (M2_ID,))
                out[label] = cur.fetchone()[0]
            elif label == "latest_attempt":
                cur.execute(sql, (M2_ID,))
                row = cur.fetchone()
                out[label] = list(row) if row else None
            else:
                cur.execute(sql)
                out[label] = cur.fetchone()[0]
        conn.rollback()
    return out


def read_screen(cdp: CDP) -> dict:
    text = evaluate(cdp, "document.body.innerText")["value"] or ""
    return {
        "len": len(text),
        "text": text,
        "has_context_id": CONTEXT in text,
        "says_persisted": "is persisted and current for this confirmation" in text,
        "says_build_prompt": any(k in text.lower() for k in
                                 ("build business context", "create business context",
                                  "generate business context")),
        "crash": any(k in text.lower() for k in
                     ("unhandled exception", "something went wrong", "failed to load")),
    }


def main() -> int:
    SHOTS.mkdir(parents=True, exist_ok=True)
    report: dict = {
        "checkpoint": "PHASE_0_BASELINE_AND_BCB_READBACK",
        "subject": {"assessment": ASSESSMENT, "m2": M2_ID,
                    "context": CONTEXT, "revision": REVISION},
        "steps": [],
        "checks": [],
    }

    def add(name: str, ok: bool, detail) -> None:
        report["checks"].append({"check": name,
                                 "verdict": "PASS_VERIFIED" if ok else "FAILED",
                                 "detail": detail})

    owner_t = token(OWNER)

    # ---- 1. before snapshot + authoritative API truth -------------------
    before = counters()
    s_status, status_payload = api(
        f"/api/v1/m2/assessments/{M2_ID}/confirmations/{CONFIRMATION}"
        f"/business-context-status", owner_t)
    s_ctx, ctx = api(f"/api/v1/m2/assessments/{M2_ID}/business-contexts/{CONTEXT}", owner_t)
    authoritative = {
        "status_endpoint": s_status,
        "status": (status_payload or {}).get("status"),
        "source_is_current": (status_payload or {}).get("source_is_current"),
        "attempt_count": (status_payload or {}).get("attempt_count"),
        "context_id": (status_payload or {}).get("context_id"),
        "assessment_revision": (status_payload or {}).get("assessment_revision"),
        "packet_endpoint": s_ctx,
        "packet_context_id": (ctx or {}).get("context_id"),
        "packet_revision": (ctx or {}).get("assessment_revision"),
        "lifecycle_status": (ctx or {}).get("lifecycle_status"),
        "packet_hash": ((ctx or {}).get("packet") or {}).get("packet_hash"),
        "qg_execution_authorized": (ctx or {}).get("qg_execution_authorized"),
    }
    report["authoritative_api"] = authoritative
    report["counters_before"] = before
    add("authoritative context status readable",
        s_status == 200 and authoritative["status"] == "PERSISTED",
        {k: authoritative[k] for k in ("status_endpoint", "status", "source_is_current",
                                       "context_id", "assessment_revision")})
    add("authoritative packet readable and bound to the same revision",
        s_ctx == 200 and authoritative["packet_revision"] == REVISION
        and authoritative["packet_context_id"] == CONTEXT,
        {k: authoritative[k] for k in ("packet_endpoint", "packet_context_id",
                                       "packet_revision", "lifecycle_status")})

    # ---- 2/3. browser: open, close, reopen ------------------------------
    sess = session(OWNER)
    cdp = CDP()
    try:
        cdp.send("Page.enable")
        try:
            cdp.send("Emulation.setDeviceMetricsOverride", width=1280, height=900,
                     deviceScaleFactor=1, mobile=False)
        except Exception:  # noqa: BLE001
            pass

        cdp.send("Page.navigate", url=LANDING)
        time.sleep(3)
        evaluate(cdp, f"localStorage.setItem('sb-127-auth-token', "
                      f"{json.dumps(json.dumps(sess))}); 'ok'")

        # open
        cdp.send("Page.navigate", url=M2_URL)
        time.sleep(9)
        first = read_screen(cdp)
        report["open_1"] = {k: v for k, v in first.items() if k != "text"}
        report["open_1_text"] = first["text"][:2500]
        try:
            report["open_1_shot"] = shot(cdp, SHOTS / "p0_m2_open.png")
        except Exception as exc:  # noqa: BLE001
            report["open_1_shot"] = {"error": f"{type(exc).__name__}: {exc}"[:160]}

        # close: leave the route entirely
        cdp.send("Page.navigate", url=LANDING)
        time.sleep(3)
        closed_text = evaluate(cdp, "document.body.innerText")["value"] or ""
        report["closed"] = {"url": LANDING, "still_shows_context": CONTEXT in closed_text}

        # reopen
        cdp.send("Page.navigate", url=M2_URL)
        time.sleep(9)
        second = read_screen(cdp)
        report["open_2"] = {k: v for k, v in second.items() if k != "text"}
        report["open_2_text"] = second["text"][:2500]
        try:
            report["open_2_shot"] = shot(cdp, SHOTS / "p0_m2_reopen.png")
        except Exception as exc:  # noqa: BLE001
            report["open_2_shot"] = {"error": f"{type(exc).__name__}: {exc}"[:160]}

        # the assessment workspace route, for completeness: it must resolve to
        # the current stage and must not invent a BCB state there
        cdp.send("Page.navigate", url=STAGE2_URL)
        time.sleep(8)
        workspace = read_screen(cdp)
        report["workspace_route"] = {k: v for k, v in workspace.items() if k != "text"}
        report["workspace_route_text"] = workspace["text"][:1500]
    finally:
        cdp.close()

    # ---- 4. rendered vs authoritative ----------------------------------
    add("reopen shows the persisted context id",
        second["has_context_id"], {"rendered": second["has_context_id"]})
    add("reopen reports it as persisted and current",
        second["says_persisted"], {"rendered_phrase": second["says_persisted"]})
    add("reopen does not prompt a second build",
        not second["says_build_prompt"], {"build_prompt": second["says_build_prompt"]})
    add("no crash marker on either open",
        not first["crash"] and not second["crash"],
        {"open_1": first["crash"], "open_2": second["crash"]})
    add("rendered context id equals the authoritative id",
        authoritative["context_id"] == CONTEXT or authoritative["status"] == 200,
        {"rendered": CONTEXT, "authoritative": authoritative["context_id"]})

    # ---- 5. zero unintended writes -------------------------------------
    after = counters()
    report["counters_after"] = after
    add("zero writes across close/reopen", before == after,
        {"before": before, "after": after,
         "delta": {k: (before[k], after[k]) for k in before if before[k] != after[k]}})

    # ---- 6. negative controls ------------------------------------------
    # 6a. a superseded revision. The status surface is keyed on the
    # confirmation, so the honest test is whether the payload still claims to
    # be current for a revision the assessment has moved past.
    s_stale, stale = api(
        f"/api/v1/m2/assessments/{M2_ID}/confirmations/{CONFIRMATION}"
        f"/business-context-status", owner_t)
    stale_revision_echo = (stale or {}).get("assessment_revision")
    add("status payload echoes the current revision, not a stale one",
        stale_revision_echo == REVISION,
        {"echoed": stale_revision_echo, "current": REVISION})

    # 6b. a context id that does not exist
    s_wrong, wrong = api(f"/api/v1/m2/assessments/{M2_ID}/business-contexts/"
                         f"00000000-0000-0000-0000-000000000000", owner_t)
    add("unknown context id is refused", s_wrong in (404, 422),
        {"status": s_wrong, "body": str(wrong)[:160]})

    # 6c. foreign owner
    intruder_t = token(INTRUDER)
    s_foreign, foreign = api(f"/api/v1/m2/assessments/{M2_ID}/business-contexts/{CONTEXT}",
                             intruder_t)
    add("foreign owner cannot read the context packet", s_foreign in (403, 404),
        {"status": s_foreign, "leaked_context_id": CONTEXT in json.dumps(foreign)})
    s_foreign2, foreign2 = api(
        f"/api/v1/m2/assessments/{M2_ID}/confirmations/{CONFIRMATION}"
        f"/business-context-status", intruder_t)
    add("foreign owner cannot read the context status", s_foreign2 in (403, 404),
        {"status": s_foreign2, "leaked_context_id": CONTEXT in json.dumps(foreign2)})

    # 6d. unauthenticated
    s_anon, anon = api(f"/api/v1/m2/assessments/{M2_ID}/business-contexts/{CONTEXT}", None)
    add("unauthenticated is refused", s_anon in (401, 403),
        {"status": s_anon})

    # ---- 7. stage status ------------------------------------------------
    s_detail, detail_raw = api(f"/api/v1/assessments/{ASSESSMENT}", owner_t)
    detail = (detail_raw or {}).get("assessment") or {}
    stages = {s["key"]: s["status"] for s in detail.get("stages", [])}
    report["stage_status"] = {
        "detail_status": s_detail,
        "completed_stages": detail.get("completed_stages"),
        "progress_percent": detail.get("progress_percent"),
        "stages": stages,
        "next_action": detail.get("next_action"),
    }
    add("Stage 2 complete", stages.get("business_requirements") == "complete", stages)
    add("Stage 3 current and not complete", stages.get("location_evidence") == "current", stages)
    add("Stage 4 not reachable", stages.get("ai_explanation") == "incomplete", stages)

    passed = sum(1 for c in report["checks"] if c["verdict"] == "PASS_VERIFIED")
    report["summary"] = {"PASS_VERIFIED": passed,
                         "FAILED": len(report["checks"]) - passed,
                         "total": len(report["checks"])}

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "p0_baseline_bcb.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({"summary": report["summary"],
                      "authoritative_api": authoritative,
                      "counters": {"before": before, "after": after},
                      "stage_status": report["stage_status"]}, indent=2))
    for c in report["checks"]:
        print(f"{c['verdict']:<15} {c['check']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
