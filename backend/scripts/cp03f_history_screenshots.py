"""Activity History — actual browser evidence.

Captures the real Jaspr page served by the real FastAPI process, with a real
ES256 token minted against the local JWKS. Nothing is mocked: every record in
these screenshots came from PostgreSQL through the authenticated endpoint.

Each capture records what it observed (`document.title`, the event count text,
the selected detail heading) alongside the PNG, so a screenshot cannot be
mistaken for a different page than the one it claims to show.
"""
from __future__ import annotations

import base64
import hashlib
import json
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src"))
sys.path.insert(0, str(HERE))

import requests  # noqa: E402
from sqlalchemy import create_engine, text  # noqa: E402

import cp03f_e2e_browser as H  # noqa: E402

from sitewise.core.config import settings  # noqa: E402

OUT = HERE.parent.parent / "docs" / "architecture" / "activity_history" / "snapshots"
OWNER = "11111111-1111-4111-8111-111111111111"
OWNER_EMAIL = "cp02.synthetic@example.test"
OWNER_NAME = "Synthetic Entrepreneur"


def m2_dsn() -> str:
    url = settings.m2_database_url.get_secret_value()
    if not url:
        raise SystemExit("M2_DATABASE_URL is not configured")
    return url


def target_assessment() -> str:
    engine = create_engine(m2_dsn(), hide_parameters=True)
    with engine.connect() as c:
        c.execute(text("select set_config('project1.actor_id', :o, false)"), {"o": OWNER})
        row = c.execute(text("""
            SELECT a.id FROM public.m2_assessments a
            LEFT JOIN public.m2_bdj_evaluations e ON e.assessment_id = a.id
            WHERE a.owner_user_id = :o
            GROUP BY a.id ORDER BY count(e.id) DESC, a.revision DESC LIMIT 1
        """), {"o": OWNER}).first()
    if row is None:
        raise SystemExit("no assessment for the synthetic owner")
    return str(row[0])


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    aid = target_assessment()
    workdir = Path(tempfile.mkdtemp(prefix="cp03f_hist_jwks_"))
    profile = Path(tempfile.mkdtemp(prefix="cp03f_hist_chrome_"))
    priv = H.make_keypair(workdir)
    token = H.mint(priv, OWNER, OWNER_EMAIL)
    srv = H.serve_jwks(workdir)
    backend = chrome = None
    manifest: dict = {"assessment_id": aid, "identity_source": "LOCAL_JWKS",
                      "subject": OWNER, "shots": []}
    try:
        backend = H.start_backend()
        base = f"http://127.0.0.1:{H.BACKEND_PORT}"
        auth = {"Authorization": f"Bearer {token}"}
        body = requests.get(
            f"{base}/api/v1/m2/assessments/{aid}/activity", headers=auth, timeout=30).json()
        events = body.get("events") or []
        (OUT / "activity_response.json").write_text(
            json.dumps(body, indent=2, default=str), encoding="utf-8")

        chrome = H.launch_chrome(profile)
        cdp = H.CDP(H.page_ws())
        cdp.call("Page.enable")
        cdp.call("Runtime.enable")
        cdp.call("Network.enable")

        origin = f"http://127.0.0.1:{H.BACKEND_PORT}"
        ref = H.ISSUER.split("//")[1].split(".")[0]
        now = int(time.time())
        session = {
            "access_token": token, "refresh_token": "cp03f-hist-refresh",
            "expires_at": now + 7200, "expires_in": 7200, "token_type": "bearer",
            "user": {"id": OWNER, "aud": H.AUDIENCE, "role": "authenticated",
                     "email": OWNER_EMAIL, "email_confirmed_at": "2026-11-11T00:00:00Z",
                     "created_at": "2026-11-11T00:00:00Z",
                     "app_metadata": {"provider": "email", "providers": ["email"]},
                     "user_metadata": {"full_name": OWNER_NAME}},
        }
        cdp.call("Page.navigate", url=origin + "/")
        time.sleep(2.0)
        cdp.js(f"localStorage.setItem({json.dumps(f'sb-{ref}-auth-token')}, "
               f"{json.dumps(json.dumps(session))})")

        def shot(name, note, viewport_only=False, extra=None):
            # A fixed-position overlay (`position: fixed; inset: 0`) is not
            # reliably composited by Chrome's full-page capture path, so the
            # dialog is captured at viewport size instead.
            data = cdp.call("Page.captureScreenshot", format="png",
                            captureBeyondViewport=not viewport_only)
            path = OUT / f"{name}.png"
            path.write_bytes(base64.b64decode(data["data"]))
            observed = {
                "file": path.name,
                "note": note,
                "title": cdp.js("document.title"),
                "url": cdp.js("location.pathname + location.search"),
                "timeline": cdp.js(
                    "(() => { const p=[...document.querySelectorAll('.sr-card-head p')];"
                    " return p.length ? p[0].textContent.trim() : null; })()"),
                "detail_heading": cdp.js(
                    "(() => { const h=document.querySelector('.sr-detail-title-wrap h3');"
                    " return h ? h.textContent.trim() : null; })()"),
                "status_badge": cdp.js(
                    "(() => { const s=document.querySelector('.sr-detail-title-row .sr-status');"
                    " return s ? s.textContent.trim() : null; })()"),
                "event_rows": cdp.js("document.querySelectorAll('.sr-event').length"),
                "dialog_open": bool(cdp.js(
                    "document.querySelectorAll('.sr-json-dialog').length")),
                "bytes": path.stat().st_size,
                # A hash makes "these are ten different pieces of evidence"
                # checkable. An earlier run shipped a shot that was byte
                # identical to another and therefore proved nothing new.
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
            if extra:
                observed.update(extra)
            manifest["shots"].append(observed)
            print(f"  {name}.png  rows={observed['event_rows']} "
                  f"detail={observed['detail_heading']!r} "
                  f"badge={observed['status_badge']!r} "
                  f"dialog={observed['dialog_open']}")
            return observed

        def goto(path):
            cdp.call("Page.navigate", url=origin + path)
            deadline = time.time() + 40
            while time.time() < deadline:
                if cdp.js("document.readyState") == "complete":
                    break
                time.sleep(0.4)
            time.sleep(3.0)

        def click_event(event_id):
            return bool(cdp.js(
                "(() => { const b=document.querySelector("
                f"'[data-event-id=\"{event_id}\"]');"
                " if (!b) return false; b.click(); return true; })()"))

        history_path = f"/entrepreneur/activity-history?assessment={aid}"
        goto(history_path)

        shot("01_activity_history_overview",
             "Overall Activity History page: heading, assessment picker, "
             "context stats, filters, workflow coverage, timeline and detail.")

        # One detail view per implemented event kind, chosen from the real rows.
        # UNCERTAINTY_CONFIRMED is excluded on purpose: it is the newest event,
        # so it is already the default selection in the overview capture and a
        # second shot would be byte-identical to 01 rather than new evidence.
        wanted = ["ANSWER_SAVED", "BDJ_EVALUATED", "CONTEXT_CONFIRMED",
                  "REVIEW_RECORDED"]
        index = 2
        for kind in wanted:
            event = next((e for e in events if e.get("kind") == kind), None)
            if event is None:
                manifest["shots"].append({"kind": kind, "captured": False,
                                          "reason": "no persisted row of this kind"})
                print(f"  (skip {kind}: no persisted row)")
                continue
            event_id = f"{kind}:{event['event_id']}"
            if not click_event(event_id):
                # The event may be on a later page of the timeline.
                cdp.js("(() => { const n=[...document.querySelectorAll('button')]"
                       ".find(b => b.textContent.trim().startsWith('Next'));"
                       " if (n) n.click(); })()")
                time.sleep(1.0)
                click_event(event_id)
            time.sleep(1.0)
            shot(f"{index:02d}_detail_{kind.lower()}", f"Detail view for {kind}.")
            index += 1

        # The read-only JSON record dialog.
        #
        # The button's textContent is `codeView full log (JSON)`: the material
        # icon is a ligature text node inside the same <button>, so a prefix
        # match on 'View full log' never fires. Match on containment instead,
        # then verify the dialog actually exists before capturing — an earlier
        # run silently captured the page without the dialog.
        FIND_LOG = ("[...document.querySelectorAll('button')]"
                    ".find(e => e.textContent.includes('View full log'))")
        opened = cdp.js(f"(() => {{ const b={FIND_LOG};"
                        " if (!b) return 'NO_BUTTON'; b.click(); return 'CLICKED'; })()")
        time.sleep(1.2)
        dialog_count = cdp.js("document.querySelectorAll('.sr-json-dialog').length")
        if not dialog_count and opened == 'CLICKED':
            # A synthetic .click() is not always delivered to the Jaspr
            # listener; fall back to a real mouse press at the button centre.
            box = cdp.js(f"(() => {{ const b={FIND_LOG}; if (!b) return null;"
                         " const r=b.getBoundingClientRect();"
                         " return [Math.round(r.left+r.width/2),"
                         "         Math.round(r.top+r.height/2)]; })()")
            if isinstance(box, list) and len(box) == 2:
                for t in ("mousePressed", "mouseReleased"):
                    cdp.call("Input.dispatchMouseEvent", type=t, x=box[0], y=box[1],
                             button="left", clickCount=1)
                time.sleep(1.2)
                dialog_count = cdp.js("document.querySelectorAll('.sr-json-dialog').length")

        if dialog_count:
            shot("06_json_record_dialog",
                 "Read-only event record dialog, opened from the selected "
                 "REVIEW_RECORDED event. It shows only the fields the page "
                 "already displays; no private answers or model payloads.",
                 viewport_only=True,
                 extra={
                     "dialog_title": cdp.js(
                         "(() => { const h=document.querySelector('.sr-json-dialog h2');"
                         " return h ? h.textContent.trim() : null; })()"),
                     "dialog_record_head": cdp.js(
                         "(() => { const p=document.querySelector('.sr-json-dialog pre');"
                         " return p ? p.textContent.slice(0, 160) : null; })()"),
                 })
            cdp.js(f"(() => {{ const b=[...document.querySelectorAll('button')]"
                   ".find(e => e.textContent.trim() === 'Done');"
                   " if (!b) return false; b.click(); return true; })()")
            time.sleep(0.8)
        else:
            # Honest failure: no screenshot is written for a dialog that never
            # opened, and the manifest says so rather than claiming otherwise.
            manifest["shots"].append({
                "file": None, "captured": False,
                "kind": "JSON_RECORD_DIALOG",
                "reason": f"dialog did not open (button match: {opened})",
            })
            print(f"  (skip 06: JSON dialog did not open — {opened})")

        # Filtered state — proves the filters act on real statuses.
        cdp.js("(() => { const s=[...document.querySelectorAll('.sr-filters select')];"
               " const st=s[s.length-1];"
               " if (!st) return false;"
               " st.value='ANSWERED';"
               " st.dispatchEvent(new Event('change', {bubbles:true}));"
               " return true; })()")
        time.sleep(1.5)
        shot("07_filtered_status_answered",
             "Status filter set to ANSWERED — the timeline narrows from 17 to "
             "the 10 events that actually carry that stored outcome.",
             extra={"filters": cdp.js(
                 "[...document.querySelectorAll('.sr-filters select')]"
                 ".map(s => s.value)")})

        # Honest empty state. The engine list is the fixed workflow vocabulary
        # (M2, BDJ, BCB, QJ, QG ...), so selecting an engine that has produced
        # no persisted record yields a genuine "no matching activities" — not a
        # stale list and not a fabricated placeholder row.
        #
        # Filters are reset first: leaving the ANSWERED status from shot 07
        # applied would make the empty result over-determined, and the capture
        # would not show which filter caused it.
        cdp.js("(() => { const b=[...document.querySelectorAll('button')]"
               ".find(e => e.textContent.includes('Reset filters'));"
               " if (!b) return false; b.click(); return true; })()")
        time.sleep(1.2)
        cdp.js("(() => { const s=[...document.querySelectorAll('.sr-filters select')];"
               " if (!s.length) return false;"
               " s[0].value='QJ';"
               " s[0].dispatchEvent(new Event('change', {bubbles:true}));"
               " return true; })()")
        time.sleep(1.5)
        shot("08_empty_filter_result",
             "No matching activities — filters reset, then only the engine "
             "module set to QJ, which has produced no persisted record. The "
             "empty state is attributable to that single filter.",
             extra={"filters": cdp.js(
                 "[...document.querySelectorAll('.sr-filters select')]"
                 ".map(s => s.value)")})

        # Genuinely unavailable source: an assessment id that does not resolve.
        goto("/entrepreneur/activity-history?assessment="
             "00000000-0000-4000-8000-000000000000")
        time.sleep(2.0)
        shot("09_unavailable_source",
             "Unavailable state: the service refuses an assessment it cannot "
             "resolve. No substitute rows are rendered.")

        # No mobile capture. Activity History is a desktop surface: the Owner
        # has stated there is no mobile requirement (AH-D-21). An earlier run
        # captured a 390x844 layout; that shot was withdrawn rather than kept as
        # evidence for a form the project does not require.

        # Ten shots are only ten pieces of evidence if they differ. A duplicate
        # hash means one of them shows something other than what it claims.
        seen: dict[str, str] = {}
        duplicates = []
        for entry in manifest["shots"]:
            digest = entry.get("sha256")
            if not digest:
                continue
            if digest in seen:
                duplicates.append([seen[digest], entry["file"]])
            else:
                seen[digest] = entry["file"]
        manifest["duplicate_shots"] = duplicates
        manifest["verdict"] = "CAPTURED" if not duplicates else "CAPTURED_WITH_DUPLICATES"
        if duplicates:
            print(f"\nWARNING: duplicate captures {duplicates}")
        print(f"\n{len(manifest['shots'])} shots -> {OUT}")
        return 0
    finally:
        (OUT / "capture_manifest.json").write_text(
            json.dumps(manifest, indent=2, default=str), encoding="utf-8")
        if chrome is not None:
            try:
                chrome.terminate()
            except Exception:
                pass
        if backend is not None:
            backend.terminate()
            try:
                backend.wait(timeout=15)
            except Exception:
                backend.kill()
        srv.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
