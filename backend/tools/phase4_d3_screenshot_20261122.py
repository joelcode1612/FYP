"""Robust Stage 3 screenshot capture.

The first attempts failed because `Page.captureScreenshot` on this canvas build
exceeds the driver's 30 s websocket timeout. Three mitigations, in order:

  1. a longer socket timeout for the capture call only;
  2. a fixed, modest viewport, because capture cost scales with surface area and
     the default window is large;
  3. retry with a smaller surface if the first attempt still times out.

A capture that fails is reported as a failure — never replaced by a placeholder.
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

from cdp_20261122 import CDP, evaluate  # noqa: E402

OUT = REPO / "deliverables" / "phase4"
SHOTS = OUT / "shots"
GOTRUE = "http://127.0.0.1:54329"
ANON = "sb_publishable_local_e2e"
EMAIL = "gatebc-e2e-b9e62014@example.invalid"
PASSWORD = "e2e-local-password"


def session() -> dict:
    req = urllib.request.Request(
        f"{GOTRUE}/auth/v1/token?grant_type=password",
        data=json.dumps({"email": EMAIL, "password": PASSWORD}).encode(),
        headers={"Content-Type": "application/json", "apikey": ANON})
    with urllib.request.urlopen(req) as resp:
        raw = json.load(resp)
    return {"access_token": raw["access_token"],
            "refresh_token": raw.get("refresh_token", ""),
            "token_type": "bearer", "expires_in": raw.get("expires_in", 3600),
            "expires_at": raw.get("expires_at"), "user": raw.get("user", {})}


def capture(cdp: CDP, path: Path, width: int, height: int, timeout: int) -> dict:
    cdp.send("Emulation.setDeviceMetricsOverride", width=width, height=height,
             deviceScaleFactor=1, mobile=False)
    time.sleep(2.5)
    cdp.ws.settimeout(timeout)
    try:
        result = cdp.send("Page.captureScreenshot", format="png",
                          captureBeyondViewport=False, fromSurface=True)
        import base64
        path.write_bytes(base64.b64decode(result["data"]))
        return {"path": str(path), "bytes": path.stat().st_size,
                "viewport": f"{width}x{height}"}
    finally:
        cdp.ws.settimeout(30)


def main() -> int:
    url = sys.argv[1] if len(sys.argv) > 1 else \
        "http://127.0.0.1:8091/entrepreneur/assessments?id=EP-01051&stage=3"
    name = sys.argv[2] if len(sys.argv) > 2 else "d3_stage3_research.png"
    SHOTS.mkdir(parents=True, exist_ok=True)
    target = SHOTS / name
    report: dict = {"url": url, "attempts": []}

    cdp = CDP()
    try:
        cdp.send("Page.enable")
        cdp.send("Page.navigate", url="http://127.0.0.1:8091/")
        time.sleep(3)
        evaluate(cdp, f"localStorage.setItem('sb-127-auth-token', "
                      f"{json.dumps(json.dumps(session()))}); 'ok'")
        cdp.send("Page.navigate", url=url)
        time.sleep(9)

        text = evaluate(cdp, "document.body.innerText")["value"] or ""
        report["inner_text_len"] = len(text)
        report["progress_line"] = next(
            (ln.strip() for ln in text.splitlines() if "/ 5" in ln), None)

        for width, height, timeout in ((1280, 900, 120), (1024, 768, 120), (800, 600, 90)):
            try:
                report["attempts"].append(
                    {"viewport": f"{width}x{height}", **capture(cdp, target, width, height, timeout)})
                report["captured"] = True
                break
            except Exception as exc:  # noqa: BLE001
                report["attempts"].append({"viewport": f"{width}x{height}",
                                           "error": f"{type(exc).__name__}: {exc}"[:160]})
        report.setdefault("captured", False)
    finally:
        cdp.close()

    (OUT / (name.replace(".png", ".json"))).write_text(
        json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["captured"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
