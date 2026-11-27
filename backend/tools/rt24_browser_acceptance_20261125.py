"""Round 24 / Gate 7 — browser acceptance for the synthetic chart preview.

Two servers, one backend, one difference: the frontend bundle.

* ``--base http://127.0.0.1:8093`` serves the **production-shaped** build, made
  with no ``--dart-define``. The request path is compiled out of the bundle, so
  the preview can neither be fetched nor rendered.
* ``--base http://127.0.0.1:8094`` serves the **developer-preview** build, made
  with ``SITEWISE_SYNTHETIC_PREVIEW=true`` and ``SITEWISE_BUILD_ENV=development``
  from the same sources. The preview is fetched and rendered, marked
  non-reportable.

The script never prints a token. It reads the access token inside the page (where
the app already holds it), uses it for same-origin requests, and reports only
status codes and body markers.

Writes a JSON evidence file plus screenshots.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent

#: Screenshots go through the section-capture module: a plain viewport capture
#: after `scrollIntoView` returns a stale frame in this browser (see that
#: module's docstring), which would have made the held-card evidence a lie.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from rt24_section_shot import capture_section, freeze_animation  # noqa: E402

CDP_HTTP = 'http://127.0.0.1:9222'
PROPERTY = 'MD-03209'
#: The card's own label. The report is a destination reached from "View report"
#: on the assessment card, not a URL — there is no report route to navigate to,
#: which is why this script clicks rather than deep-links.
PROPERTY_TITLE = 'Prime Commercial Shoplot at Jalan Shahbandar, Batu Pahat'
LIST_PATH = '/entrepreneur/assessments'
M2_ASSESSMENT = 'df15adf3-be2c-4751-86aa-78fda663cf93'
CAMPAIGN = 'de3121ff-8e96-46dc-9330-1cc438b143a5'
#: The other campaign on this cluster, owned by the same person but not by this
#: assessment — the cross-binding negative.
FOREIGN_CAMPAIGN = 'f4902d2c-1588-4fb7-a082-ec9529f5d138'
#: A campaign that does not exist at all.
MISSING_CAMPAIGN = '00000000-0000-4000-8000-000000000000'

REPORT_PATH = f'/entrepreneur/assessments?id={PROPERTY}&stage=assessment_report'

#: Clicks "View report" on the card for this property, then waits for the
#: report document to replace the tab's content.
_OPEN_REPORT = """
(() => {
  const buttons = [...document.querySelectorAll('button.asw-ecard__link')];
  const target = buttons.find(b => (b.getAttribute('aria-label') || '').includes(__TITLE__));
  if (!target) return {clicked: false, available: buttons.length};
  target.click();
  return {clicked: true, available: buttons.length};
})()
"""

MARKERS = {
    'preview_heading': 'Response distribution by question',
    'demo_mode': 'Demo Mode',
    'coverage': 'measured questions charted',
    'revision_selection': 'Revision selection',
    'held_card': 'R03 · Concept intent distribution — held',
    # The full data-origin sentence lives once, in the methodology block. Its
    # presence here is what proves the disclosure survived the banner removal.
    'data_origin_disclosure': 'do not represent independently collected',
    # Human labels, not wire codes: a business report prints the meaning. The
    # wire codes stay in the API payload, which `probe_api` captures separately.
    'not_shown_badge': 'Not shown',
    'missing_stimulus_badge': 'Unavailable',
}


def connect(page_hint: str):
    import requests
    import websocket
    targets = requests.get(f'{CDP_HTTP}/json/list', timeout=5).json()
    pages = [t for t in targets
             if t.get('type') == 'page' and t.get('webSocketDebuggerUrl')]
    if not pages:
        raise SystemExit('no page target; is Chrome running with --remote-debugging-port=9222?')
    chosen = next((t for t in pages if page_hint in (t.get('url') or '')), pages[0])
    # No custom Origin header: websocket-client appends its own, and Chrome
    # rejects a duplicated origin pair with 403.
    ws = websocket.create_connection(chosen['webSocketDebuggerUrl'], timeout=180)
    state = {'id': 0}

    def send(method: str, **params):
        state['id'] += 1
        message_id = state['id']
        ws.send(json.dumps({'id': message_id, 'method': method, 'params': params}))
        while True:
            message = json.loads(ws.recv())
            if message.get('id') == message_id:
                if 'error' in message:
                    raise RuntimeError(f'{method}: {message["error"]}')
                return message.get('result', {})

    return ws, send, chosen


def evaluate(send, expression: str):
    result = send('Runtime.evaluate', expression=expression, returnByValue=True,
                  awaitPromise=True)
    if result.get('exceptionDetails'):
        raise RuntimeError(json.dumps(result['exceptionDetails'])[:400])
    return result.get('result', {}).get('value')


def wait_for_text(send, needle: str, timeout: float = 25.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if needle in (evaluate(send, 'document.body ? document.body.innerText : ""') or ''):
                return True
        except Exception:  # noqa: BLE001
            pass
        time.sleep(0.4)
    return False


def wait_for_js(send, expression: str, timeout: float = 30.0) -> bool:
    """Wait until a JS expression is truthy.

    Readiness must be a condition the page actually reaches. Waiting for the
    word "Assessments" passed on the nav label while the cards were still
    absent, which is how a click landed on nothing.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if evaluate(send, expression):
                return True
        except Exception:  # noqa: BLE001
            pass
        time.sleep(0.4)
    return False


def shot(send, path: Path) -> int:
    """Capture the viewport, tolerating a page that is mid-animation.

    A looping chart animation can hold the compositor long enough that the CDP
    call exceeds the socket timeout. The evidence is not worth failing the whole
    run over, so a failed capture is retried once and then reported as 0 bytes
    with the rest of the evidence intact.
    """
    import base64
    for attempt in (1, 2):
        try:
            result = send('Page.captureScreenshot', format='png')
            data = base64.b64decode(result['data'])
            path.write_bytes(data)
            return len(data)
        except Exception as exc:  # noqa: BLE001
            if attempt == 2:
                print(f'  screenshot unavailable: {type(exc).__name__}', file=sys.stderr)
                return 0
            time.sleep(2)
    return 0


_PROBE_TEMPLATE = """
(async () => {
  const raw = Object.keys(localStorage).find(k => /^sb-.*-auth-token$/.test(k));
  let token = null;
  if (raw) {
    try { token = JSON.parse(localStorage.getItem(raw)).access_token; }
    catch (e) { token = null; }
  }
  const call = async (path, withToken) => {
    const headers = {Accept: 'application/json'};
    if (withToken && token) headers.Authorization = 'Bearer ' + token;
    const r = await fetch(path, {headers, cache: 'no-store'});
    let code = null;
    try { const body = await r.json(); code = (body && body.detail && body.detail.code) || null; }
    catch (e) { code = null; }
    return {status: r.status, code};
  };
  const p = (a, c) => `/api/v1/cq/assessments/${a}/campaigns/${c}/chart-previews`;
  const out = {};
  out.has_token = !!token;
  out.own_campaign = await call(p(ASSESSMENT, CAMPAIGN), true);
  out.foreign_campaign = await call(p(ASSESSMENT, FOREIGN), true);
  out.missing_campaign = await call(p(ASSESSMENT, MISSING), true);
  out.anonymous = await call(p(ASSESSMENT, CAMPAIGN), false);
  out.other_assessment = await call(p(OTHER_ASSESSMENT, CAMPAIGN), true);
  return out;
})()
"""


def probe_api(send) -> dict:
    """Same-origin requests from inside the page, so the session is the real one."""
    script = (_PROBE_TEMPLATE
              # Longest placeholder first: `OTHER_ASSESSMENT` contains
              # `ASSESSMENT`, so replacing the shorter one first would corrupt it.
              .replace('OTHER_ASSESSMENT', json.dumps('53ca2f95-004f-4c83-937c-bfb0ddb6d6a3'))
              .replace('ASSESSMENT', json.dumps(M2_ASSESSMENT))
              .replace('FOREIGN', json.dumps(FOREIGN_CAMPAIGN))
              .replace('MISSING', json.dumps(MISSING_CAMPAIGN))
              .replace('CAMPAIGN', json.dumps(CAMPAIGN)))
    return evaluate(send, script)


_READ_SESSION = """
(() => {
  const key = Object.keys(localStorage).find(k => /^sb-.*-auth-token$/.test(k));
  return key ? JSON.stringify({key, value: localStorage.getItem(key)}) : null;
})()
"""


def read_session_from(base: str) -> str | None:
    """The stored Supabase session, read from a page already signed in on `base`.

    localStorage is origin-scoped, so a second port is a second origin with no
    session. Cookies ignore the port, which is why only this needs copying. The
    value is never printed.
    """
    ws, send, _ = connect(base.replace('http://', ''))
    try:
        return evaluate(send, _READ_SESSION)
    finally:
        ws.close()


def inject_session(send, packed: str) -> bool:
    script = """
    (() => {
      const packed = __PACKED__;
      if (!packed) return false;
      const {key, value} = JSON.parse(packed);
      localStorage.setItem(key, value);
      return localStorage.getItem(key) === value;
    })()
    """.replace('__PACKED__', json.dumps(packed))
    return bool(evaluate(send, script))


#: Structural measurement of the preview section.
#:
#: Text markers were the wrong instrument: "Share of V" is CSS-transformed and
#: appears in the Q01 demonstration too, so a substring count conflates two
#: different things. This reads the DOM instead — the section card that carries
#: the heading, the charts inside it, and the prose it prints for held slots.
_MEASURE_SECTION = """
(() => {
  const figures = [...document.querySelectorAll('figure.sw-chart')];
  const cards = [...document.querySelectorAll('section, div')].filter(el => {
    const t = el.innerText || '';
    return t.includes('Response distribution by question') && el.querySelector('figure.sw-chart, p');
  });
  // The innermost card is the section itself, not a page wrapper.
  const card = cards.sort((a, b) => (a.innerText || '').length - (b.innerText || '').length)[0] || null;
  const inCard = card ? [...card.querySelectorAll('figure.sw-chart')] : [];
  return {
    total_charts: figures.length,
    synthetic_charts: figures.filter(f => f.classList.contains('sw-chart--synthetic')).length,
    section_found: !!card,
    section_charts: inCard.length,
    section_text: card ? (card.innerText || '').slice(0, 20000) : '',
    section_lines: card ? (card.innerText || '').split('\\n').filter(Boolean).length : 0,
  };
})()
"""


def step(message: str) -> None:
    print(f'  .. {message}', file=sys.stderr, flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='http://127.0.0.1:8094')
    parser.add_argument('--out', default=None)
    parser.add_argument('--label', default=None)
    parser.add_argument('--skip-screenshot', action='store_true')
    parser.add_argument('--copy-session-from', default=None,
                        help='base URL of an origin already signed in')
    args = parser.parse_args()

    label = args.label or ('preview' if '8094' in args.base else 'production')
    out_dir = Path(args.out) if args.out else ROOT / 'artifacts' / 'rt24_gate7' / label
    out_dir.mkdir(parents=True, exist_ok=True)

    ws, send, target = connect(args.base.replace('http://', ''))
    evidence: dict = {
        'base': args.base,
        'label': label,
        'cdp_target_url_before': target.get('url'),
        'report_path': REPORT_PATH,
    }
    try:
        send('Network.enable')
        send('Network.setCacheDisabled', cacheDisabled=True)
        send('Page.enable')
        if args.copy_session_from:
            # Land on the target origin first: localStorage is only writable
            # from a document on that origin.
            send('Page.navigate', url=f'{args.base}/login')
            wait_for_text(send, 'Sign in', timeout=30)
            packed = read_session_from(args.copy_session_from)
            evidence['session_copied'] = inject_session(send, packed) if packed else False
        step('navigating to the list')
        send('Page.navigate', url=f'{args.base}{LIST_PATH}')
        evidence['list_loaded'] = wait_for_text(send, 'Assessments', timeout=40)
        step('waiting for assessment cards')
        evidence['cards_ready'] = wait_for_js(
            send, "document.querySelectorAll('button.asw-ecard__link').length > 0")
        step('opening the report')
        evidence['open_report'] = evaluate(
            send, _OPEN_REPORT.replace('__TITLE__', json.dumps(PROPERTY_TITLE)))
        step('waiting for the report document')
        evidence['report_loaded'] = wait_for_text(send, 'Assessment report', timeout=40)
        # Give the report's own async reads (business description, explanation,
        # chart preview) time to settle before reading the document text.
        time.sleep(8)
        body = evaluate(send, 'document.body ? document.body.innerText : ""') or ''
        evidence['markers'] = {name: (needle in body) for name, needle in MARKERS.items()}
        step('measuring the preview section')
        evidence['section'] = evaluate(send, _MEASURE_SECTION)
        evidence['chart_count'] = evidence['section']['total_charts'] if evidence['section'] else 0
        evidence['text_length'] = len(body)
        if args.skip_screenshot:
            evidence['screenshot_bytes'] = None
            evidence['r03'] = None
            evidence['section_frames'] = None
        else:
            # Freeze animation first: a looping chart animation keeps the
            # compositor busy and `Page.captureScreenshot` then blocks until the
            # socket times out, which reads as "the harness hung".
            freeze_animation(send)
            time.sleep(0.5)
            # The cover, at whatever the window's own zoom is — this one is a
            # sanity frame, not the evidence for the section.
            step('capturing the report cover')
            evidence['screenshot_bytes'] = shot(send, out_dir / 'report.png')
            # The held card must be captured with the same instrument as the
            # preview section, or the comparison means nothing: a viewport
            # capture after `scrollIntoView` came back as a stale frame from
            # before the scroll, so "0 charts above" would have been an artefact
            # of where the camera was, not of what the card contains.
            step('capturing the held R03 card')
            evidence['r03'] = capture_section(
                send, evaluate, needle='Concept intent distribution',
                out_path=out_dir / 'held_r03.png', offset=250, frames=1)
            step('capturing the preview section')
            evidence['section_frames'] = capture_section(
                send, evaluate, needle='Response distribution by question',
                out_path=out_dir / 'preview_section.png', offset=250)
        evidence['api'] = probe_api(send)
    finally:
        try:
            ws.close()
        except Exception:  # noqa: BLE001
            pass

    (out_dir / 'evidence.json').write_text(
        json.dumps(evidence, indent=2), encoding='utf-8')
    print(json.dumps(evidence, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
