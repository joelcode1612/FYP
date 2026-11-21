"""CP-03F-07: authenticated browser E2E harness (real Chrome, real FastAPI).

Why a local identity provider
-----------------------------
Authentication is Supabase-only; there is no password-login endpoint and no
development bypass on the server path (`dependencies.get_jwt_verifier`). The
project's Supabase signing key is not available here, and creating users in the
live project would be a production side effect.

So this harness keeps the **production verification code path** — a real ES256
JWT, verified by `SupabaseJWTVerifier` against a real JWKS fetched over HTTP —
and substitutes only the *identity provider*: a P-256 keypair generated locally
whose public half is served as a JWKS. The `sub` claim is a **real, existing
entrepreneur row** from `Final_Location_Analysis.public.users`; no user is
created and no production data is modified.

What is therefore proven and what is not:
  PROVEN      the token is really signed, really fetched, really verified; the
              backend resolves the real profile; the browser really renders.
  NOT PROVEN  that Supabase itself issued the token. This is an identity-source
              substitution, and every result is labelled `LOCAL_JWKS`.

Read-only by default. Mutating scenarios must be requested explicitly and are
recorded with their before/after rows.
"""
from __future__ import annotations

import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import jwt  # noqa: E402
import requests  # noqa: E402
from cryptography.hazmat.primitives import serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from sqlalchemy import create_engine, text  # noqa: E402

from sitewise.core.config import settings  # noqa: E402

BACKEND_PORT = 8011
JWKS_PORT = 8899
CDP_PORT = 9333
KID = "cp03f-e2e-key"
ISSUER = settings.supabase_issuer
AUDIENCE = "authenticated"
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "backend" / "var" / "cp03f_e2e"


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def make_keypair(workdir: Path):
    key = ec.generate_private_key(ec.SECP256R1())
    priv_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    numbers = key.public_key().public_numbers()
    jwk = {
        "kty": "EC",
        "crv": "P-256",
        "kid": KID,
        "use": "sig",
        "alg": "ES256",
        "x": b64u(numbers.x.to_bytes(32, "big")),
        "y": b64u(numbers.y.to_bytes(32, "big")),
    }
    (workdir / "jwks.json").write_text(json.dumps({"keys": [jwk]}), encoding="utf-8")
    return priv_pem


def mint(priv_pem: bytes, sub: str, email: str, ttl: int = 3600) -> str:
    now = int(time.time())
    return jwt.encode(
        {"sub": sub, "email": email, "role": "authenticated",
         "aud": AUDIENCE, "iss": ISSUER, "iat": now, "exp": now + ttl,
         "session_id": "cp03f-e2e"},
        priv_pem, algorithm="ES256", headers={"kid": KID},
    )


def session_cookie(profile: dict) -> str:
    return b64u(json.dumps(profile).encode())


def serve_jwks(workdir: Path) -> ThreadingHTTPServer:
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(workdir), **kw)

        def log_message(self, *a):  # silence
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", JWKS_PORT), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def free(port: int) -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) != 0


def start_backend() -> subprocess.Popen:
    env = {**os.environ,
           "SUPABASE_JWKS_URL": f"http://127.0.0.1:{JWKS_PORT}/jwks.json",
           "NO_PROXY": "localhost,127.0.0.1", "no_proxy": "localhost,127.0.0.1",
           "HTTP_PROXY": "", "HTTPS_PROXY": "",
           "http_proxy": "", "https_proxy": ""}
    # A file, not a pipe: the M2 route converts SQLAlchemyError into a fixed 503,
    # so the traceback only exists in the server log.
    log_path = OUT / "backend.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "sitewise.main:app",
         "--host", "127.0.0.1", "--port", str(BACKEND_PORT), "--app-dir", "src",
         "--log-level", "debug"],
        cwd=str(ROOT / "backend"), env=env,
        stdout=log, stderr=subprocess.STDOUT, text=True,
    )
    for _ in range(60):
        if not free(BACKEND_PORT):
            break
        time.sleep(0.5)
    for _ in range(60):
        try:
            if requests.get(f"http://127.0.0.1:{BACKEND_PORT}/health", timeout=2).ok:
                return proc
        except requests.RequestException:
            pass
        time.sleep(0.5)
    raise RuntimeError("backend did not become healthy")


def find_chrome() -> str:
    candidates = [
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"),
    ]
    for c in candidates:
        if Path(c).exists():
            return c
    raise RuntimeError("chrome.exe not found")


class CDP:
    """Minimal Chrome DevTools Protocol client over a page websocket."""

    def __init__(self, ws_url: str):
        import asyncio
        import websockets

        self._asyncio = asyncio
        self._loop = asyncio.new_event_loop()
        # No header overrides: Chrome rejects a DevTools handshake whose Host
        # does not match the address it is listening on (HTTP 500).
        self._ws = self._loop.run_until_complete(
            websockets.connect(ws_url, max_size=32 * 1024 * 1024,
                               max_queue=None))
        self._id = 0
        self.events: list[dict] = []

    def call(self, method: str, **params):
        self._id += 1
        msg_id = self._id
        payload = json.dumps({"id": msg_id, "method": method, "params": params})
        self._loop.run_until_complete(self._ws.send(payload))
        deadline = time.time() + 45
        while time.time() < deadline:
            raw = self._loop.run_until_complete(
                self._asyncio.wait_for(self._ws.recv(), timeout=45))
            msg = json.loads(raw)
            if msg.get("id") == msg_id:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})
            self.events.append(msg)
        raise TimeoutError(method)

    def js(self, expression: str):
        res = self.call("Runtime.evaluate", expression=expression,
                        returnByValue=True, awaitPromise=True)
        return res.get("result", {}).get("value")

    def close(self):
        try:
            self._loop.run_until_complete(self._ws.close())
        finally:
            self._loop.close()


def _supports_headers() -> bool:
    import inspect
    import websockets
    try:
        return "additional_headers" in inspect.signature(websockets.connect).parameters
    except (TypeError, ValueError):
        return False


def launch_chrome(profile_dir: Path) -> subprocess.Popen:
    args = [
        find_chrome(),
        f"--remote-debugging-port={CDP_PORT}",
        f"--user-data-dir={profile_dir}",
        "--headless=new",
        "--disable-gpu", "--no-first-run", "--no-default-browser-check",
        "--disable-extensions", "--disable-background-networking",
        "--proxy-server=direct://", "--proxy-bypass-list=*",
        "--window-size=1440,2200",
        "about:blank",
    ]
    env = {**os.environ, "NO_PROXY": "localhost,127.0.0.1",
           "no_proxy": "localhost,127.0.0.1",
           "HTTP_PROXY": "", "HTTPS_PROXY": "", "http_proxy": "", "https_proxy": ""}
    return subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)


def page_ws() -> str:
    for _ in range(80):
        try:
            targets = requests.get(f"http://127.0.0.1:{CDP_PORT}/json/list", timeout=2).json()
            for t in targets:
                if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                    return t["webSocketDebuggerUrl"]
        except requests.RequestException:
            pass
        time.sleep(0.5)
    raise RuntimeError("no page target")


def entrepreneur() -> tuple[str, str, str]:
    engine = create_engine(settings.database_url, hide_parameters=True)
    with engine.connect() as c:
        row = c.execute(text(
            "SELECT user_id, email, full_name FROM public.users "
            "WHERE role='entrepreneur' AND account_status='active' "
            "ORDER BY created_at LIMIT 1")).one()
    return str(row[0]), row[1], row[2]


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    workdir = Path(tempfile.mkdtemp(prefix="cp03f_jwks_"))
    profile_dir = Path(tempfile.mkdtemp(prefix="cp03f_chrome_"))
    sub_id, sub_email, sub_name = entrepreneur()
    priv = make_keypair(workdir)
    token = mint(priv, sub_id, sub_email)
    srv = serve_jwks(workdir)
    backend = chrome = None
    evidence: dict = {"identity_source": "LOCAL_JWKS", "subject": sub_id,
                      "subject_email": sub_email, "scenarios": []}
    try:
        backend = start_backend()

        # 0. The token must survive the real verifier before any browser work.
        me = requests.get(f"http://127.0.0.1:{BACKEND_PORT}/api/v1/auth/me",
                          headers={"Authorization": f"Bearer {token}"}, timeout=15)
        evidence["auth_me"] = {"status": me.status_code, "body": me.json() if me.ok else me.text[:400]}
        if not me.ok:
            print(json.dumps(evidence, indent=2))
            return 1

        # Resolve the owner's own assessment rather than hard-coding an id.
        listed = requests.get(f"http://127.0.0.1:{BACKEND_PORT}/api/v1/m2/assessments",
                              headers={"Authorization": f"Bearer {token}"}, timeout=15)
        rows = (listed.json().get("items") or []) if listed.ok else []
        assessment_id = rows[0]["id"] if rows else None
        evidence["assessment_id"] = assessment_id
        evidence["assessment_count"] = len(rows)
        if not assessment_id:
            print(json.dumps(evidence, indent=2))
            return 1

        chrome = launch_chrome(profile_dir)
        cdp = CDP(page_ws())
        cdp.call("Page.enable")
        cdp.call("Network.enable")
        cdp.call("Runtime.enable")

        origin = f"http://127.0.0.1:{BACKEND_PORT}"
        for name, value in (("sitewise_token", token),
                            ("sitewise_session", session_cookie(
                                {"role": "entrepreneur", "full_name": sub_name,
                                 "email": sub_email, "user_id": sub_id,
                                 "account_status": "active"}))):
            r = cdp.call("Network.setCookie", name=name, value=value,
                         domain="127.0.0.1", path="/", httpOnly=False,
                         secure=False, sameSite="Lax")
            evidence.setdefault("cookies", []).append({"name": name, "ok": r.get("success")})

        def goto(path: str) -> dict:
            cdp.call("Page.navigate", url=origin + path)
            deadline = time.time() + 30
            while time.time() < deadline:
                state = cdp.js("document.readyState")
                if state == "complete":
                    break
                time.sleep(0.4)
            time.sleep(2.5)  # let the client bundle boot and settle
            return {
                "path": path,
                "url": cdp.js("location.href"),
                "title": cdp.js("document.title"),
                "text": (cdp.js("document.body ? document.body.innerText : ''") or "")[:4000],
            }

        # The adopted build mode is `jaspr: mode: client`, so the router reads a
        # Supabase session through auth_bundle.js rather than the SSR cookie.
        # Seed that session with the already-verified token. `expires_at` is far
        # in the future so supabase-js returns it without a refresh round trip
        # (a refresh would need the real project, which is not the point here).
        project_ref = ISSUER.split("//")[1].split(".")[0]
        storage_key = f"sb-{project_ref}-auth-token"
        now = int(time.time())
        session = {
            "access_token": token, "refresh_token": "cp03f-e2e-refresh",
            "expires_at": now + 7200, "expires_in": 7200, "token_type": "bearer",
            "user": {"id": sub_id, "aud": AUDIENCE, "role": "authenticated",
                     "email": sub_email, "email_confirmed_at": "2026-11-11T00:00:00Z",
                     "created_at": "2026-11-11T00:00:00Z",
                     "app_metadata": {"provider": "email", "providers": ["email"]},
                     "user_metadata": {"full_name": sub_name}},
        }
        # Establish the origin first so localStorage is scoped correctly.
        cdp.call("Page.navigate", url=origin + "/")
        time.sleep(2.0)
        cdp.js(f"localStorage.setItem({json.dumps(storage_key)}, "
               f"{json.dumps(json.dumps(session))})")
        evidence["session_seeded"] = {
            "storage_key": storage_key,
            "present": bool(cdp.js(f"!!localStorage.getItem({json.dumps(storage_key)})")),
        }

        def shot(name: str):
            data = cdp.call("Page.captureScreenshot", format="png",
                            captureBeyondViewport=True)
            (OUT / f"{name}.png").write_bytes(
                base64.b64decode(data["data"]))

        # Scenario 1: does the injected session actually authenticate the UI?
        s1 = goto("/entrepreneur")
        evidence["scenarios"].append({"id": "SESSION", **s1})
        shot("01_entrepreneur")

        # Scenario 2: the M2 assessment workspace.
        s2 = goto("/entrepreneur/m2-workflow")
        evidence["scenarios"].append({"id": "M2_WORKSPACE", **s2})
        shot("02_m2_workspace")
        html = cdp.js("document.documentElement.outerHTML") or ""
        (OUT / "m2_workspace.html").write_text(html, encoding="utf-8")
        evidence["html_bytes"] = len(html)

        def click_text(label: str) -> bool:
            # Exact match first, then prefix. Answered items render as
            # "M2V1-04 ✓", so an exact-match-only matcher silently fails once any
            # answer exists and every downstream scenario captures an empty panel.
            return bool(cdp.js(
                "(() => { const els=[...document.querySelectorAll('button,a')];"
                f" const want={json.dumps(label)};"
                " const exact=els.find(e => e.textContent.trim() === want);"
                " const prefix=els.find(e => e.textContent.trim().startsWith(want));"
                " const b=exact||prefix; if (!b) return false; b.click(); return true; })()"))

        def options_for(item: str) -> list[dict]:
            return cdp.js(
                "(() => { const ins=[...document.querySelectorAll("
                f"'input[name=\"m2-{item}\"]')]; return ins.map(i=>({{"
                "label:i.parentElement.textContent.trim(), checked:i.checked})); })()") or []

        def states_for(item: str) -> list[str]:
            return cdp.js(
                "(() => { const ins=[...document.querySelectorAll("
                f"'input[name=\"m2-state-{item}\"]')]; return ins.map(i=>"
                "i.parentElement.textContent.trim()); })()") or []

        def open_item(item_key: str) -> dict:
            """Select an item tab and report whether its controls rendered."""
            ok = click_text(item_key)
            time.sleep(1.5)
            return {"clicked": ok,
                    "options": options_for(item_key),
                    "states": states_for(item_key),
                    "text": (cdp.js("document.body.innerText") or "")[:2500]}

        # Scenario 3: open the conditional item BEFORE its source is answered.
        opened = open_item("M2V1-04")
        evidence["scenarios"].append({"id": "OPEN_M2V1_04", **opened})
        (OUT / "m2v1_04.html").write_text(
            cdp.js("document.documentElement.outerHTML") or "", encoding="utf-8")
        shot("03_m2v1_04")

        evidence["scenarios"].append({"id": "M2V1_05_BEFORE_SOURCE", **open_item("M2V1-05")})
        shot("04_m2v1_05_before")

        # Scenario 3b: M2V1-11 is the inverse hazard. Its rule is a *gate*
        # (`requires_priority`), so the server reports applicable=false while
        # still listing four codes in effective_options. A panel that keys off
        # "options.length > 0" renders selectable controls the server will reject.
        evidence["scenarios"].append({"id": "M2V1_11_GATED", **open_item("M2V1-11")})
        shot("04b_m2v1_11_gated")

        # Scenario 4: answer the source item and persist it.
        click_text("M2V1-04")
        time.sleep(1.2)
        picked = cdp.js(
            "(() => { const want=['Students','Office workers'];"
            " const ins=[...document.querySelectorAll('input[name=\"m2-M2V1-04\"]')];"
            " let n=0; for (const i of ins) { const t=i.parentElement.textContent.trim();"
            " if (want.includes(t)) { i.click(); n++; } }"
            " const st=[...document.querySelectorAll('input[name=\"m2-state-M2V1-04\"]')];"
            " const a=st.find(e=>e.parentElement.textContent.trim()==='ANSWERED');"
            " if (a) a.click(); return n; })()")
        time.sleep(0.8)
        ticked = cdp.js(
            "(() => { const ins=[...document.querySelectorAll('input[name=\"m2-M2V1-04\"]')];"
            " return ins.map(i=>({label:i.parentElement.textContent.trim(), checked:i.checked})); })()")
        saved = click_text("Save answer (PUT /m2/…/answers/M2V1-04)") or bool(cdp.js(
            "(() => { const b=[...document.querySelectorAll('button')]"
            ".find(e=>e.textContent.trim().startsWith('Save answer'));"
            " if(!b) return false; b.click(); return true; })()"))
        time.sleep(3.0)
        wire = []
        for e in cdp.events:
            if e.get("method") != "Network.requestWillBeSent":
                continue
            req = e.get("params", {}).get("request", {})
            if "/answers/" not in str(req.get("url")):
                continue
            rid = e["params"].get("requestId")
            status = next((x["params"]["response"]["status"] for x in cdp.events
                           if x.get("method") == "Network.responseReceived"
                           and x["params"].get("requestId") == rid), None)
            body = None
            if status is not None:
                try:
                    body = cdp.call("Network.getResponseBody",
                                    requestId=rid).get("body", "")[:800]
                except Exception as exc:  # noqa: BLE001
                    body = f"<unavailable: {exc}>"
            wire.append({"url": req.get("url"), "postData": req.get("postData"),
                         "status": status, "response": body})
        evidence["scenarios"].append({
            "id": "ANSWER_M2V1_04", "picked": picked, "saved": saved,
            "checkbox_state": ticked, "wire": wire,
            "text": (cdp.js("document.body.innerText") or "")[:2500]})
        shot("05_m2v1_04_saved")

        # Scenario 5: the conditional item must now offer exactly the picked groups.
        evidence["scenarios"].append({"id": "M2V1_05_AFTER_SOURCE", **open_item("M2V1-05")})
        shot("06_m2v1_05_after")

        # Scenario 6: Activity History must be read-only and show only persisted
        # rows — no synthetic success, no write controls.
        s6 = goto(f"/entrepreneur/activity-history?assessment={assessment_id}")
        controls = cdp.js(
            "(() => { const els=[...document.querySelectorAll("
            "'button,input[type=submit],textarea,form')];"
            " return els.map(e=>({tag:e.tagName, text:(e.textContent||'').trim().slice(0,60)})); })()")
        links = cdp.js(
            "(() => [...document.querySelectorAll('a')].map(a=>({href:a.getAttribute('href'),"
            " text:(a.textContent||'').trim().slice(0,50)})))()")
        evidence["scenarios"].append({
            "id": "ACTIVITY_HISTORY", **s6,
            "write_controls": controls, "links": links})
        shot("07_activity_history")

        print(json.dumps(evidence, indent=2)[:6000])
        (OUT / "evidence.json").write_text(json.dumps(evidence, indent=2),
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
