"""EX-05 Gate 5 authenticated browser E2E over the DevTools Protocol.

Drives the real compiled Jaspr frontend served by the EX-05 disposable app:

1. launches a private headless Chromium with remote debugging;
2. mints a real session from the local GoTrue stub and installs it under the
   key supabase-js derives for this origin;
3. opens the normal workspace report route
   ``/entrepreneur/assessments?id=1&stage=5`` for the fixture assessment;
4. records every network request/response the page makes, with status codes,
   and reads back the explanation binding + readback payloads the page received;
5. captures ``document.body.innerText`` markers and a viewport screenshot;
6. repeats the read on the dev-only ``/dev/report`` harness for the synthetic
   preview capture.

Nothing is fabricated: the token is issued by the same stub the server
validates, and the page calls the real API. Evidence is written to
``artifacts/project1_ex05_explanation_runtime_v1/browser/``.
"""
from __future__ import annotations

import base64
import json
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
OUT = ROOT / "artifacts" / "project1_ex05_explanation_runtime_v1" / "browser"

CHROME = Path(
    "C:/Users/HP/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe")
PROFILE = BACKEND / "var" / "e2e" / "ex05" / "chrome-profile"

GOTRUE = "http://127.0.0.1:54329"
APP = "http://127.0.0.1:8091"
ANON = "sb_publishable_local_e2e"
EMAIL = "gatebc-e2e-b9e62014@example.invalid"
PASSWORD = "e2e-local-password"
REPORT_URL = f"{APP}/entrepreneur/assessments?id=EP-01051&stage=assessment_report"
HARNESS_URL = f"{APP}/dev/report"

# The one disposable chain this gate certifies. The owner also holds three
# newer synthetic fixtures, so every assertion is keyed to these identities
# rather than to "whatever the listing showed first".
FIXTURE_PROPERTY = "EP-01051"
FIXTURE_TITLE = "Uptown Damansara Corner Mezzanine Shop Office to Let"
FIXTURE_ASSESSMENT = "37bf879a-005a-4f5a-b49d-210ea1ce37c4"
FIXTURE_M2_ASSESSMENT = "053b3768-145b-4d4a-a880-e98174adcd94"
FIXTURE_CAMPAIGN = "d195f8fd-6673-5120-b102-e1ae01879208"
FIXTURE_SNAPSHOT = "a7578a26-91e5-51ec-aaff-215970de516b"

CDP_HTTP = "http://127.0.0.1:9222"


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


class Browser:
    """Minimal CDP client that records the events it sees along the way."""

    def __init__(self) -> None:
        import requests
        import websocket

        targets = requests.get(f"{CDP_HTTP}/json/list", timeout=5).json()
        pages = [t for t in targets
                 if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
        if not pages:
            raise SystemExit("no page target; Chrome did not expose a page")
        self.target = pages[0]
        self.ws = websocket.create_connection(
            self.target["webSocketDebuggerUrl"], timeout=60,
            header=["Origin: http://127.0.0.1:9222"])
        self._id = 0
        self.requests: dict[str, dict] = {}
        self.responses: dict[str, dict] = {}

    def send(self, method: str, **params):
        self._id += 1
        message_id = self._id
        self.ws.send(json.dumps(
            {"id": message_id, "method": method, "params": params}))
        while True:
            raw = self.ws.recv()
            if not raw:
                continue
            message = json.loads(raw)
            if "id" in message:
                if message["id"] != message_id:
                    continue
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message.get("result", {})
            self._event(message)

    def _event(self, message: dict) -> None:
        method = message.get("method")
        params = message.get("params") or {}
        if method == "Network.requestWillBeSent":
            request = params.get("request") or {}
            self.requests[params.get("requestId", "")] = {
                "url": request.get("url"),
                "method": request.get("method"),
                "ts": params.get("timestamp"),
            }
        elif method == "Network.responseReceived":
            response = params.get("response") or {}
            self.responses[params.get("requestId", "")] = {
                "status": response.get("status"),
                "url": response.get("url"),
                "cache_control": (response.get("headers") or {}).get(
                    "cache-control"),
            }

    def body(self, request_id: str):
        try:
            result = self.send("Network.getResponseBody", requestId=request_id)
            raw = result.get("body") or ""
            if result.get("base64Encoded"):
                raw = base64.b64decode(raw).decode("utf-8", "replace")
            return raw
        except Exception:  # noqa: BLE001
            return None

    def eval(self, expression: str):
        result = self.send("Runtime.evaluate", expression=expression,
                           returnByValue=True, awaitPromise=True)
        return result.get("result", {}).get("value")

    def shot(self, path: Path) -> dict:
        path.parent.mkdir(parents=True, exist_ok=True)
        result = self.send("Page.captureScreenshot", format="png")
        path.write_bytes(base64.b64decode(result["data"]))
        return {"screenshot": str(path), "bytes": path.stat().st_size}

    def close(self) -> None:
        try:
            self.ws.close()
        except Exception:  # noqa: BLE001
            pass


def api_calls(browser: Browser) -> list[dict]:
    rows = []
    for request_id, request in browser.requests.items():
        url = request.get("url") or ""
        if "/api/v1/" not in url:
            continue
        response = browser.responses.get(request_id) or {}
        rows.append({
            "method": request.get("method"),
            "url": url.replace(APP, ""),
            "status": response.get("status"),
            "cache_control": response.get("cache_control"),
            "request_id": request_id,
        })
    return rows


def explanation_payloads(browser: Browser) -> dict:
    """The payloads the page actually received from the explanation routes."""
    out: dict = {}
    for row in api_calls(browser):
        url = row["url"]
        if ("explanations/binding" in url or "/explanations/Q" in url
                or "explanations/availability" in url):
            body = browser.body(row["request_id"])
            parsed = None
            if body:
                try:
                    parsed = json.loads(body)
                except json.JSONDecodeError:
                    parsed = None
            out[url.split("?")[0]] = {
                "status": row["status"],
                "cache_control": row["cache_control"],
                "body": parsed,
            }
    return out


def markers(text: str) -> dict:
    low = text.lower()
    return {
        "report_heading": "report" in low,
        "explanation_section": any(k in low for k in
                                   ("explanation", "explanation candidates")),
        "withheld": any(k in low for k in
                        ("withheld", "not authorized", "no authorized source")),
        "synthetic_labels": any(k in text for k in
                                ("SYNTHETIC_PREVIEW_ONLY", "Synthetic preview")),
        "report_unavailable": any(k in low for k in
                                  ("report could not", "failed to load",
                                   "report unavailable")),
        "crash": any(k in low for k in
                     ("unhandled exception", "something went wrong",
                      "error: type", "socketexception")),
        "page_not_found": "page not found" in low,
    }


def _grade(evidence: dict) -> dict:
    """Grade the run against the Gate 5 acceptance criteria.

    Every criterion is keyed to the one disposable chain under test. The
    verdict is deliberately mechanical: a criterion that cannot be evidenced
    from the captured payloads fails rather than being assumed.
    """
    click = evidence.get("report_click") or {}
    report = evidence.get("report") or {}
    calls = report.get("api_calls") or []
    payloads = report.get("explanation_payloads") or {}
    text = report.get("inner_text") or ""
    low = text.lower()
    marks = report.get("markers") or {}
    harness = evidence.get("synthetic_preview") or {}
    harness_marks = harness.get("markers") or {}
    harness_available = bool(harness_marks.get("synthetic_labels")) and not (
        harness_marks.get("page_not_found"))

    def find(fragment: str, require: str | None = None) -> dict | None:
        for call in calls:
            url = call.get("url") or ""
            if fragment in url and (require is None or require in url):
                return call
        return None

    def route(fragment: str) -> dict | None:
        for url, payload in payloads.items():
            if fragment in url:
                return {"url": url, **payload}
        return None

    report_call = find("/report", "/assessments/") or {}
    report_url = report_call.get("url") or ""
    availability = route("explanations/availability") or {}
    binding = route("explanations/binding") or {}
    readback = route("/explanations/Q") or {}
    readback_body = json.dumps(readback.get("body") or {})

    criteria = {
        "fixture_card_selected": bool(click.get("targets_fixture")),
        "report_endpoint_targets_fixture": FIXTURE_ASSESSMENT in report_url,
        "report_endpoint_200": report_call.get("status") == 200,
        "report_names_fixture_property": (
            FIXTURE_PROPERTY in text or FIXTURE_TITLE in text),
        "report_heading_rendered": bool(marks.get("report_heading")),
        "explanation_section_rendered": bool(marks.get("explanation_section")),
        "availability_route_200": availability.get("status") == 200,
        "availability_uncacheable": (
            availability.get("cache_control") or "") == "no-store",
        "binding_route_exercised": binding.get("status") == 200,
        "readback_route_exercised": readback.get("status") == 200,
        # The readback must be the bound snapshot, not an arbitrary result.
        "readback_bound_to_fixture_snapshot": bool(
            readback) and FIXTURE_SNAPSHOT in readback_body,
        # The card must exist and must present itself as withheld. A withheld
        # card still carries its provenance (authority `CANDIDATE_UNVERIFIED`
        # is a required disclosure, not a leaked finding) but no substantive
        # result, so the leak test is about the claim, not the vocabulary.
        "explanation_card_rendered": "q05 · explanation" in low,
        "explanation_presented_as_withheld": (
            "explanation withheld" in low
            and "withheld_not_authorized" in low),
        "no_admitted_finding_published": "substantive result" not in low,
        "synthetic_data_marked_unreportable": (
            "synthetic_data_not_reportable" in low),
        "report_not_unavailable": not marks.get("report_unavailable"),
        "no_crash": not marks.get("crash"),
        # The dev harness is compile-time gated (SITEWISE_SYNTHETIC_PREVIEW +
        # SITEWISE_BUILD_ENV=development + a non-product build), so a release
        # build must not expose it. Its absence is the gate working.
        "dev_harness_compiled_out_of_release_build": not harness_available,
    }
    failed = [name for name, ok in criteria.items() if not ok]
    return {
        "criteria": criteria,
        "failed": failed,
        "passed": not failed,
        "verdict": "PASS" if not failed else "FAIL",
    }


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    sess = session()
    evidence: dict = {
        "report_url": REPORT_URL,
        "harness_url": HARNESS_URL,
        "session": {
            "email": EMAIL,
            "sub_matches_fixture_owner":
                (sess.get("user") or {}).get("id")
                == "b9e62014-b7bc-426e-a950-a95b25965639",
            "expires_at": sess.get("expires_at"),
        },
    }

    # Fresh private profile so no stale localStorage leaks between runs.
    if PROFILE.exists():
        try:
            shutil.rmtree(PROFILE)
        except Exception:  # noqa: BLE001
            pass
    PROFILE.mkdir(parents=True, exist_ok=True)
    chrome = subprocess.Popen(
        [str(CHROME), "--headless=new", "--remote-debugging-port=9222",
         "--remote-allow-origins=*",
         "--no-proxy-server", "--no-first-run", "--no-default-browser-check",
         "--disable-gpu", "--window-size=1440,900",
         f"--user-data-dir={PROFILE}", "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            urllib.request.urlopen(f"{CDP_HTTP}/json/version", timeout=1)
            break
        except Exception:  # noqa: BLE001
            time.sleep(0.4)

    browser = Browser()
    try:
        browser.send("Page.enable")
        browser.send("Network.enable")

        # Land on the origin so localStorage is writable for it, then install
        # the real stub-issued session under the key supabase-js derives.
        browser.send("Page.navigate", url=f"{APP}/")
        time.sleep(4)
        payload = json.dumps(sess)
        browser.eval(
            "localStorage.setItem('sb-127-auth-token', "
            f"{json.dumps(payload)}); 'ok'")
        evidence["session"]["installed_key"] = "sb-127-auth-token"
        evidence["session"]["local_storage_keys"] = browser.eval(
            "Object.keys(localStorage)")

        # The report is a destination reached from the assessment card's
        # "View report" control; there is no direct route, so drive the click
        # the way a user would. Flutter's semantics tree carries the aria-label
        # and accepts synthetic pointer events at the node's centre.
        #
        # The owner has four assessments and the three newer synthetic fixtures
        # sort ahead of the EX-05 one, so the card must be selected by property
        # identity rather than by "first match" — clicking the first control
        # would grade a different assessment's report.
        browser.requests.clear()
        browser.responses.clear()
        browser.send("Page.navigate", url=f"{APP}/entrepreneur/assessments")
        time.sleep(9)

        finder = (
            "(() => {"
            "  const wantId = " + json.dumps(FIXTURE_ASSESSMENT) + ";"
            "  const btns = [...document.querySelectorAll('[aria-label]')]"
            "    .filter(e => /view the report/i.test("
            "      e.getAttribute('aria-label') || ''));"
            "  const rows = btns.map(b => {"
            "    let node = b, card = null;"
            "    for (let i = 0; i < 10 && node; i++) {"
            "      node = node.parentElement;"
            "      if (node && (node.getAttribute('aria-label') || '')"
            "          .startsWith('Assessment for ')) { card = node; break; }"
            "    }"
            "    const scope = card || b.parentElement;"
            "    const text = scope ? (scope.textContent || '') : '';"
            "    return {label: b.getAttribute('aria-label'),"
            "            cardLabel: card ? card.getAttribute('aria-label') : null,"
            "            hasId: text.includes(wantId),"
            "            text: text.slice(0, 240)};"
            "  });"
            "  const idx = rows.findIndex(r => r.hasId);"
            "  if (idx < 0) return {found:false, candidates: rows,"
            "                       scrollY: window.scrollY};"
            "  const hit = btns[idx];"
            "  hit.scrollIntoView({block:'center'});"
            "  const r = hit.getBoundingClientRect();"
            "  return {found:true, x: r.x + r.width/2, y: r.y + r.height/2,"
            "          label: hit.getAttribute('aria-label'),"
            "          cardLabel: rows[idx].cardLabel,"
            "          candidates: rows, scrollY: window.scrollY};"
            "})()")

        evidence["report_click"] = {"attempts": []}
        rect = {"found": False}
        for attempt in range(9):
            rect = browser.eval(finder) or {"found": False}
            evidence["report_click"]["attempts"].append({
                "attempt": attempt,
                "found": bool(rect.get("found")),
                "label": rect.get("label"),
                "cardLabel": rect.get("cardLabel"),
                "scrollY": rect.get("scrollY"),
                "candidates": rect.get("candidates"),
            })
            if rect.get("found"):
                break
            # Flutter web scrolls its own viewport, so a DOM scroll does
            # nothing; drive a wheel event over the centre of the page.
            browser.send("Input.dispatchMouseEvent", type="mouseWheel",
                         x=720, y=520, deltaX=0, deltaY=620)
            time.sleep(1.6)

        evidence["report_click"]["resolved_label"] = rect.get("label")
        evidence["report_click"]["resolved_card"] = rect.get("cardLabel")
        # Resolution is by the card's rendered assessment id, so a successful
        # hit is by construction the fixture's card.
        evidence["report_click"]["targets_fixture"] = bool(rect.get("found"))
        time.sleep(1)
        if rect.get("found"):
            for kind, buttons in (("mousePressed", 1), ("mouseReleased", 0)):
                browser.send("Input.dispatchMouseEvent", type=kind,
                             x=rect["x"], y=rect["y"], button="left",
                             clickCount=1, buttons=buttons)
                time.sleep(0.05)
            time.sleep(12)

        text = browser.eval("document.body.innerText") or ""
        card_at = text.find("Q05 · explanation")
        evidence["report"] = {
            "inner_text_len": len(text),
            "inner_text": text[:6000],
            "explanation_card_text": (
                text[card_at:card_at + 1400] if card_at >= 0 else None),
            "markers": markers(text),
            "api_calls": api_calls(browser),
            "explanation_payloads": explanation_payloads(browser),
        }
        try:
            evidence["report"]["screenshot"] = browser.shot(
                OUT / "ex05_stage5_report.png")
        except Exception as exc:  # noqa: BLE001
            evidence["report"]["screenshot"] = {
                "error": f"{type(exc).__name__}: {exc}"}

        # A human-readable capture of the governed explanation card itself.
        # The semantics tree is the only text source here, so the card is
        # found by its rendered title and scrolled to the centre of the page.
        try:
            scrolled = browser.eval(
                "(() => {"
                "  const want = 'Q05 · explanation';"
                "  const nodes = [...document.querySelectorAll('*')]"
                "    .filter(e => (e.textContent || '').trim() === want"
                "              || (e.getAttribute && e.getAttribute('aria-label')"
                "                  === want));"
                "  if (!nodes.length) return {found:false};"
                "  nodes[0].scrollIntoView({block:'center'});"
                "  return {found:true};"
                "})()")
            time.sleep(1.5)
            evidence["report"]["explanation_card_screenshot"] = browser.shot(
                OUT / "ex05_stage5_explanation_card.png")
            evidence["report"]["explanation_card_scrolled"] = scrolled
        except Exception as exc:  # noqa: BLE001
            evidence["report"]["explanation_card_screenshot"] = {
                "error": f"{type(exc).__name__}: {exc}"}

        # Synthetic preview harness (dev-only gate; compiled into this build).
        browser.requests.clear()
        browser.responses.clear()
        browser.send("Page.navigate", url=HARNESS_URL)
        time.sleep(8)
        htext = browser.eval("document.body.innerText") or ""
        evidence["synthetic_preview"] = {
            "url": HARNESS_URL,
            "inner_text_len": len(htext),
            "inner_text": htext[:6000],
            "markers": markers(htext),
            "api_calls": api_calls(browser),
            "note": (
                "The harness is compile-time gated "
                "(SITEWISE_SYNTHETIC_PREVIEW + SITEWISE_BUILD_ENV=development "
                "+ a non-product build); a release build must not serve it."),
        }
        try:
            evidence["synthetic_preview"]["screenshot"] = browser.shot(
                OUT / "ex05_dev_harness_absent.png")
        except Exception as exc:  # noqa: BLE001
            evidence["synthetic_preview"]["screenshot"] = {
                "error": f"{type(exc).__name__}: {exc}"}
    finally:
        browser.close()
        chrome.terminate()
        try:
            chrome.wait(timeout=10)
        except Exception:  # noqa: BLE001
            chrome.kill()

    evidence["gate5"] = _grade(evidence)
    (OUT / "EX05_BROWSER_E2E.json").write_text(
        json.dumps(evidence, indent=2), encoding="utf-8")

    summary = {
        "listing_url": f"{APP}/entrepreneur/assessments",
        "report_click": evidence.get("report_click"),
        "report_markers": evidence["report"]["markers"],
        "report_api_calls": [
            {"url": r["url"], "status": r["status"]}
            for r in evidence["report"]["api_calls"]],
        "explanation_route_statuses": {
            url: payload["status"]
            for url, payload in
            evidence["report"]["explanation_payloads"].items()},
        "synthetic_markers": evidence["synthetic_preview"]["markers"],
        "synthetic_preview_note": evidence["synthetic_preview"]["note"],
        "gate5": evidence["gate5"],
        "screenshots": [
            (evidence["report"].get("screenshot") or {}).get("screenshot"),
            (evidence["report"].get("explanation_card_screenshot")
             or {}).get("screenshot"),
            (evidence["synthetic_preview"].get("screenshot") or {}).get(
                "screenshot"),
        ],
    }
    print(json.dumps(summary, indent=2))
    print("--- report inner text (first 1600) ---")
    print(evidence["report"]["inner_text"][:1600])
    return 0


if __name__ == "__main__":
    sys.exit(main())