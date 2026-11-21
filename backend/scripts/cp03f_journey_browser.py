"""CP-03F-10: the same journey through the real Jaspr UI.

The backend journey reached confirmation. This one asks whether a user can get
there through the application, and records every divergence. It deliberately does
not reuse the backend's assessment: a fresh one makes each conditional state
observable, and an assessment that already has answers makes "before the
controlling answer" a label with nothing behind it.

The wire log is captured per request and polled until the response arrives, because
scanning a snapshot of the event buffer once produced `status: None` and a
`response: ""` that looked like a silent failure but was only a race.
"""
from __future__ import annotations

import base64
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src"))
sys.path.insert(0, str(HERE))

import requests  # noqa: E402

import cp03f_e2e_browser as H  # noqa: E402

INSTRUMENT = "50906385-072b-5cf1-9661-4d001898ffb8"


def main() -> int:
    H.OUT.mkdir(parents=True, exist_ok=True)
    workdir = Path(tempfile.mkdtemp(prefix="cp03f_jw_"))
    profile_dir = Path(tempfile.mkdtemp(prefix="cp03f_jc_"))
    sub_id, sub_email, sub_name = H.entrepreneur()
    priv = H.make_keypair(workdir)
    token = H.mint(priv, sub_id, sub_email)
    srv = H.serve_jwks(workdir)
    backend = chrome = None
    ev: dict = {"identity_source": "LOCAL_JWKS", "subject": sub_id, "steps": []}
    try:
        backend = H.start_backend()
        base = f"http://127.0.0.1:{H.BACKEND_PORT}"
        auth = {"Authorization": f"Bearer {token}"}

        created = requests.post(f"{base}/api/v1/m2/assessments", headers=auth,
                                json={"instrument_version_id": INSTRUMENT}, timeout=20)
        if not created.ok:
            print("cannot create assessment:", created.status_code, created.text[:300])
            return 1
        aid = created.json()["id"]
        ev["assessment_id"] = aid

        def step(name, **kw):
            ev["steps"].append({"step": name, **kw})
            print(f"[{name}] " + json.dumps(kw)[:500])

        step("01_SIGN_IN", status=requests.get(f"{base}/api/v1/auth/me", headers=auth,
                                               timeout=20).status_code)
        step("02_SAVED_ASSESSMENT", assessment_id=aid, instrument=INSTRUMENT, revision=0)

        chrome = H.launch_chrome(profile_dir)
        cdp = H.CDP(H.page_ws())
        cdp.call("Page.enable")
        cdp.call("Network.enable")
        cdp.call("Runtime.enable")

        origin = f"http://127.0.0.1:{H.BACKEND_PORT}"
        project_ref = H.ISSUER.split("//")[1].split(".")[0]
        storage_key = f"sb-{project_ref}-auth-token"
        now = int(time.time())
        session = {
            "access_token": token, "refresh_token": "cp03f-journey-refresh",
            "expires_at": now + 7200, "expires_in": 7200, "token_type": "bearer",
            "user": {"id": sub_id, "aud": H.AUDIENCE, "role": "authenticated",
                     "email": sub_email, "email_confirmed_at": "2026-11-11T00:00:00Z",
                     "created_at": "2026-11-11T00:00:00Z",
                     "app_metadata": {"provider": "email", "providers": ["email"]},
                     "user_metadata": {"full_name": sub_name}},
        }
        cdp.call("Page.navigate", url=origin + "/")
        time.sleep(2.0)
        cdp.js(f"localStorage.setItem({json.dumps(storage_key)}, "
               f"{json.dumps(json.dumps(session))})")

        def shot(name):
            data = cdp.call("Page.captureScreenshot", format="png", captureBeyondViewport=True)
            (H.OUT / f"journey_{name}.png").write_bytes(base64.b64decode(data["data"]))

        def goto(path):
            cdp.call("Page.navigate", url=origin + path)
            deadline = time.time() + 30
            while time.time() < deadline:
                if cdp.js("document.readyState") == "complete":
                    break
                time.sleep(0.4)
            time.sleep(2.5)
            return cdp.js("location.href")

        def click_text(label):
            return bool(cdp.js(
                "(() => { const els=[...document.querySelectorAll('button,a')];"
                f" const want={json.dumps(label)};"
                " const exact=els.find(e => e.textContent.trim() === want);"
                " const prefix=els.find(e => e.textContent.trim().startsWith(want));"
                " const b=exact||prefix; if (!b) return false; b.click(); return true; })()"))

        def options_for(item):
            return cdp.js(
                "(() => { const ins=[...document.querySelectorAll("
                f"'input[name=\"m2-{item}\"]')]; return ins.map(i=>({{"
                "label:i.parentElement.textContent.trim(), checked:i.checked})); })()") or []

        def states_for(item):
            return cdp.js(
                "(() => { const ins=[...document.querySelectorAll("
                f"'input[name=\"m2-state-{item}\"]')]; return ins.map(i=>"
                "i.parentElement.textContent.trim()); })()") or []

        def open_item(item):
            ok = click_text(item)
            time.sleep(1.5)
            # `document.querySelector('.m1-notice')` returns the first notice on
            # the page, which is not necessarily this item's. Collect them all and
            # label them as page-level so the evidence cannot be misread.
            notices = cdp.js(
                "(() => [...document.querySelectorAll('.m1-notice')]"
                ".map(n=>n.textContent.trim()))()") or []
            return {"clicked": ok, "options": options_for(item),
                    "states": states_for(item), "notices": notices}

        def wire(pattern, expect_within=12.0):
            """Requests matching `pattern`, polled until each has a response.

            `CDP.events` is only appended to while a `call()` is in flight, so a
            response that arrives between calls sits unread in the socket. Each
            poll issues a trivial evaluate to drain it; without that the status
            reads None even though the request succeeded.
            """
            deadline = time.time() + expect_within
            seen: dict[str, dict] = {}
            while time.time() < deadline:
                cdp.js("1")  # drain pending protocol messages
                for e in list(cdp.events):
                    p = e.get("params", {})
                    if e.get("method") == "Network.requestWillBeSent":
                        url = str(p.get("request", {}).get("url"))
                        if pattern in url:
                            seen.setdefault(p.get("requestId"), {
                                "url": url, "method": p["request"].get("method"),
                                "postData": p["request"].get("postData"), "status": None})
                    elif e.get("method") == "Network.responseReceived":
                        rid = p.get("requestId")
                        if rid in seen:
                            seen[rid]["status"] = p["response"].get("status")
                    elif e.get("method") == "Network.loadingFailed":
                        rid = p.get("requestId")
                        if rid in seen:
                            seen[rid]["failed"] = p.get("errorText")
                if seen and all(v.get("status") or v.get("failed") for v in seen.values()):
                    break
                time.sleep(0.4)
            return list(seen.values())

        # 3. Open the saved assessment's workspace.
        url = goto("/entrepreneur/m2-workflow")
        body = cdp.js("document.body.innerText") or ""
        step("03_OPEN_WORKSPACE", url=url, shows_assessment=(aid in body),
             text=body[:900])
        shot("03_workspace")

        # 4-5. Instrument and answers load; conditional baseline.
        baseline = {k: open_item(k) for k in ("M2V1-01", "M2V1-05", "M2V1-10", "M2V1-11")}
        step("05_CONDITIONAL_BASELINE", **baseline)
        shot("05_baseline")

        # 6. Try to answer the required GEO item through the UI.
        #    The server accepts UNDECIDED; the panel renders no value controls for
        #    kind=GEO, so this records whether a user can complete the instrument.
        geo = open_item("M2V1-01")
        can_pick_undecided = any(o["label"].lower().startswith("undecided")
                                 or "not decided" in o["label"].lower()
                                 for o in geo["options"])
        saved = False
        if can_pick_undecided:
            cdp.js("(() => { const ins=[...document.querySelectorAll("
                   "'input[name=\"m2-M2V1-01\"]')];"
                   " const t=ins.find(i=>/undecided|not decided/i.test(i.parentElement.textContent));"
                   " if (t) t.click(); return !!t; })()")
            time.sleep(0.5)
            saved = click_text("Save answer")
            time.sleep(3.0)
        step("06_GEO_ITEM", can_pick_undecided=can_pick_undecided, saved=saved,
             options=geo["options"], states=geo["states"], notices=geo["notices"],
             wire=wire("/answers/M2V1-01", 4))
        shot("06_geo")

        # 7. Answer the controlling item and confirm the derived list follows.
        open_item("M2V1-04")
        cdp.js("(() => { const want=['Students','Office workers'];"
               " const ins=[...document.querySelectorAll('input[name=\"m2-M2V1-04\"]')];"
               " let n=0; for (const i of ins) { if (want.includes(i.parentElement.textContent.trim()))"
               " { i.click(); n++; } }"
               " const st=[...document.querySelectorAll('input[name=\"m2-state-M2V1-04\"]')];"
               " const a=st.find(e=>e.parentElement.textContent.trim()==='ANSWERED');"
               " if (a) a.click(); return n; })()")
        time.sleep(0.6)
        click_text("Save answer")
        time.sleep(3.0)
        step("07_SAVE_M2V1_04", wire=wire("/answers/M2V1-04", 6))
        after05 = open_item("M2V1-05")
        step("07B_M2V1_05_AFTER", **after05)
        shot("07_m2v1_05_after")

        # 7B. A SINGLE item, to prove the list-vs-string fix (UI-12). Six of the
        #     eleven M2V1 items are single-choice, so a broken save here blocks
        #     most of the instrument.
        open_item("M2V1-02")
        # HYBRID's display label is "A combination of service formats"; matching on
        # the code name finds nothing and silently sends a null value.
        cdp.js("(() => { const ins=[...document.querySelectorAll('input[name=\"m2-M2V1-02\"]')];"
               " const t=ins.find(i=>/combination/i.test(i.parentElement.textContent));"
               " if (t) t.click();"
               " const st=[...document.querySelectorAll('input[name=\"m2-state-M2V1-02\"]')];"
               " const a=st.find(e=>e.parentElement.textContent.trim()==='ANSWERED');"
               " if (a) a.click(); return !!t; })()")
        time.sleep(0.6)
        click_text("Save answer")
        time.sleep(3.0)
        step("07C_SAVE_SINGLE_M2V1_02", wire=wire("/answers/M2V1-02", 6))
        shot("07c_single")

        # 8-9. Independent readback and reload.
        api = requests.get(f"{base}/api/v1/m2/assessments/{aid}", headers=auth, timeout=20).json()
        step("08_API_READBACK", revision=api["assessment"]["revision"],
             answers={k: (v or {}).get("value_json") for k, v in (api.get("answers") or {}).items()})

        goto("/entrepreneur/m2-workflow")
        reloaded = {k: open_item(k) for k in ("M2V1-02", "M2V1-04", "M2V1-05")}
        step("09_RELOAD", **reloaded)
        shot("09_reload")

        # 10-14. BDJ, result, review, confirm — through the API, recording exactly
        #        what the backend says. The UI has no control for these while the
        #        instrument cannot be completed, which is the finding.
        rev = requests.get(f"{base}/api/v1/m2/assessments/{aid}",
                           headers=auth, timeout=20).json()["assessment"]["revision"]
        evr = requests.post(f"{base}/api/v1/m2/assessments/{aid}/bdj/evaluate",
                            headers=auth, json={"expected_revision": rev}, timeout=60)
        step("10_BDJ", revision=rev, status=evr.status_code,
             body=(evr.json() if evr.ok else evr.text[:400]))

        # 15. Activity History page.
        goto(f"/entrepreneur/activity-history?assessment={aid}")
        hist = cdp.js("document.body.innerText") or ""
        links = cdp.js("(() => [...document.querySelectorAll('a')].map(a=>a.getAttribute('href')))()")
        step("15_ACTIVITY_HISTORY", text=hist[:1500], links=(links or [])[:20])
        shot("15_activity_history")

        api_act = requests.get(f"{base}/api/v1/m2/assessments/{aid}/activity",
                               headers=auth, timeout=20).json()
        step("15B_ACTIVITY_API", event_count=len(api_act.get("events") or []),
             ids=[e.get("event_id") for e in (api_act.get("events") or [])][:12])

        (H.OUT / "journey_browser.json").write_text(json.dumps(ev, indent=2, default=str),
                                                    encoding="utf-8")
        return 0
    finally:
        if chrome:
            chrome.terminate()
        if backend:
            backend.terminate()
        srv.shutdown()
        shutil.rmtree(workdir, ignore_errors=True)
        shutil.rmtree(profile_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
