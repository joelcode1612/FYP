"""Phase D — drive the real Stage 3 screen and capture what it renders.

The app is a Jaspr/Flutter canvas build, so DOM text is not available; the
reliable read is `document.body.innerText` on the semantics tree, plus a
viewport screenshot. Both are compared against the API payload in the report.

A real session is minted from the local GoTrue stub and written to localStorage
under the key supabase-js derives for this origin (`sb-127-auth-token`). Nothing
is fabricated: the token is issued by the same stub the server validates.
"""
from __future__ import annotations

import json
import sys
import time
import urllib.request
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
sys.path.insert(0, str(BACKEND / "tools"))

from cdp_20261122 import CDP, evaluate, shot  # noqa: E402

OUT = REPO / "deliverables" / "phase4"
SHOTS = OUT / "shots"
GOTRUE = "http://127.0.0.1:54329"
ANON = "sb_publishable_local_e2e"
EMAIL = "gatebc-e2e-b9e62014@example.invalid"
PASSWORD = "e2e-local-password"
URL = "http://127.0.0.1:8091/entrepreneur/assessments?id=EP-01051&stage=3"


def session() -> dict:
    req = urllib.request.Request(
        f"{GOTRUE}/auth/v1/token?grant_type=password",
        data=json.dumps({"email": EMAIL, "password": PASSWORD}).encode(),
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


def main() -> int:
    SHOTS.mkdir(parents=True, exist_ok=True)
    sess = session()
    result: dict = {"url": URL, "steps": []}

    cdp = CDP()
    try:
        # 1. land on the origin so localStorage is writable for it
        cdp.send("Page.enable")
        cdp.send("Page.navigate", url="http://127.0.0.1:8091/")
        time.sleep(4)

        # 2. install the session under the key supabase-js uses for this origin
        payload = json.dumps(sess)
        evaluate(cdp, f"localStorage.setItem('sb-127-auth-token', {json.dumps(payload)}); 'ok'")
        result["steps"].append({"installed_session": True,
                                "key": "sb-127-auth-token",
                                "expires_at": sess.get("expires_at")})

        # 3. open Stage 3
        cdp.send("Page.navigate", url=URL)
        time.sleep(9)

        # 4. what does the screen actually say?
        text = evaluate(cdp, "document.body.innerText")["value"] or ""
        result["inner_text"] = text[:4000]
        result["inner_text_len"] = len(text)
        result["markers"] = {
            "research_workspace": any(k in text.lower() for k in
                                      ("research workspace", "research objective", "no research")),
            "business_context": any(k in text.lower() for k in
                                    ("business context", "context package", "context built")),
            "bdj": any(k in text.lower() for k in ("bdj", "declaration", "review")),
            "stage3": any(k in text.lower() for k in ("location evidence", "stage 3", "research")),
            "crash_marker": any(k in text.lower() for k in
                                ("unhandled exception", "something went wrong",
                                 "failed to load", "error: type")),
        }

        # 5. viewport screenshot. The canvas render can outlast the CDP socket
        # timeout on this build, so a capture failure is recorded as a tooling
        # gap and must never discard the text evidence gathered above.
        try:
            result["screenshot"] = shot(cdp, SHOTS / "d1_stage3_research.png")
        except Exception as exc:  # noqa: BLE001
            result["screenshot"] = {"error": f"{type(exc).__name__}: {exc}"[:200]}
            result["screenshot_note"] = (
                "captureScreenshot timed out; the innerText read above is the "
                "authoritative evidence for this run")
    finally:
        cdp.close()

    (OUT / "d1_stage3_browser.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "inner_text"}, indent=2))
    print("--- inner text (first 1500) ---")
    print(result["inner_text"][:1500])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
