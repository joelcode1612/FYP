"""Round 24 / Gate 7 — capture the synthetic-preview section as an image.

Two earlier attempts failed, both for the same reason: the browser is zoomed out
(`devicePixelRatio` 0.625), so CSS coordinates, device pixels and the capture
surface are three different spaces. `Page.captureScreenshot` clips in one of
them, `getBoundingClientRect` reports another, and the PNG comes back scaled by
1.25. A clip computed from the rect therefore lands somewhere else — the first
attempt was shifted right and mostly blank, the second captured the correct band
but squeezed the content into the left fifth of the frame.

Rather than solve that arithmetic, this forces the ambiguity away.
`Emulation.setDeviceMetricsOverride` takes device pixels and then divides by the
page zoom to get CSS pixels, while `deviceScaleFactor` multiplies back. So for a
frame that is `css_width` CSS pixels wide at exactly one image pixel per CSS
pixel, with page zoom `z`:

    width = css_width * z        height = css_height * z        dsf = 1 / z

The zoom is measured from the live page rather than assumed. Then the section is
scrolled into frame with a top offset that clears the sticky header, and the
*viewport* is captured with no clip at all — so no coordinate space can drift.

Captures as many frames as the section is tall, so nothing is cut off.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sys
import time
from pathlib import Path

CDP_HTTP = 'http://127.0.0.1:9222'

#: The section card, its position, and how tall it is relative to the frame.
_SECTION_RECT = """
(() => {
  const needle = __NEEDLE__;
  const cards = [...document.querySelectorAll('section, div, article')].filter(el => {
    const t = el.innerText || '';
    return t.includes(needle) && el.querySelector('figure.sw-chart, p');
  });
  if (!cards.length) return {found: false};
  const card = cards.sort((a, b) => (a.innerText || '').length - (b.innerText || '').length)[0];
  const r = card.getBoundingClientRect();
  return {
    found: true,
    top: Math.round(r.top),
    left: Math.round(r.left),
    width: Math.round(r.width),
    height: Math.round(r.height),
    viewport_width: window.innerWidth,
    viewport_height: window.innerHeight,
    dpr: window.devicePixelRatio,
    charts: card.querySelectorAll('figure.sw-chart').length,
    lines: (card.innerText || '').split('\\n').filter(Boolean).length,
  };
})()
"""

#: Scroll so the card's top edge lands `target` px below the frame top.
#:
#: The correction is measured, not assumed: `scrollIntoView` leaves the card at
#: some offset of its own (a sticky header's `scroll-margin`, usually), so the
#: second step moves by the difference between where it landed and where the
#: caller wants it. That makes the framing independent of the page's own layout.
_SCROLL_TO_CARD = """
(() => {
  const needle = __NEEDLE__;
  const cards = [...document.querySelectorAll('section, div, article')].filter(el => {
    const t = el.innerText || '';
    return t.includes(needle) && el.querySelector('figure.sw-chart, p');
  });
  if (!cards.length) return {found: false};
  const card = cards.sort((a, b) => (a.innerText || '').length - (b.innerText || '').length)[0];
  card.scrollIntoView({block: 'start', behavior: 'instant'});
  const landed = card.getBoundingClientRect().top;
  window.scrollBy(0, landed - __TARGET__);
  return {found: true, landed: Math.round(landed),
          top_after: Math.round(card.getBoundingClientRect().top)};
})()
"""


def connect(page_hint: str):
    import requests
    import websocket
    targets = requests.get(f'{CDP_HTTP}/json/list', timeout=5).json()
    pages = [t for t in targets
             if t.get('type') == 'page' and t.get('webSocketDebuggerUrl')]
    if not pages:
        raise SystemExit('no page target; is Chrome running with --remote-debugging-port=9222?')
    chosen = next((t for t in pages if page_hint in (t.get('url') or '')), pages[0])
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


def freeze_animation(send) -> None:
    evaluate(send, """
    (() => {
      if (document.getElementById('rt24-freeze')) return true;
      const s = document.createElement('style');
      s.id = 'rt24-freeze';
      s.textContent = '*,*::before,*::after{animation:none!important;'
                    + 'transition:none!important;caret-color:transparent!important}';
      document.head.appendChild(s);
      return true;
    })()
    """)


def settle(send) -> None:
    """Force a layout pass, then wait for the compositor.

    Deliberately *not* `requestAnimationFrame`: a background tab never fires
    rAF, so awaiting it hangs the script forever, and a page that never
    re-composites is also why an earlier capture came back as a stale frame
    from before the scroll. A synchronous layout read plus a wall-clock wait
    does not depend on the tab being visible.
    """
    evaluate(send, 'document.documentElement.offsetHeight')
    time.sleep(0.5)


def capture(send, path: Path) -> dict:
    result = send('Page.captureScreenshot', format='png', fromSurface=True)
    data = base64.b64decode(result['data'])
    path.write_bytes(data)
    return {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()[:16],
            'path': path.name}


def capture_section(send, evaluate, *, needle: str, out_path: Path,
                    css_viewport: tuple[int, int] = (1360, 1000),
                    offset: int = 250, frames: int = 0,
                    keep_override: bool = False) -> dict:
    """Frame `needle`'s card and capture it, one viewport at a time.

    Takes the caller's `send`/`evaluate` so the acceptance harness can capture
    through the connection it already holds — a second WebSocket to the same
    target would fight the first over the emulation override.
    """
    css_width, css_height = css_viewport
    evidence: dict = {'needle': needle}

    # With no override in place, `devicePixelRatio` *is* the page zoom.
    zoom = float(evaluate(send, 'window.devicePixelRatio') or 1.0)
    evidence['page_zoom'] = zoom
    override = {'width': round(css_width * zoom), 'height': round(css_height * zoom),
                'deviceScaleFactor': round(1 / zoom, 6)}
    # The override does not land where the arithmetic says it will: Chrome
    # recomputes the layout viewport from the new metrics, so the zoom in
    # effect afterwards is not the zoom measured beforehand. Converge by
    # measuring — two corrections are enough in practice, and the loop is
    # bounded so a pathological page cannot spin here.
    attempts = []
    state = {'w': css_width, 'h': css_height, 'd': 1.0}
    for _ in range(4):
        send('Emulation.setDeviceMetricsOverride', mobile=False, **override)
        settle(send)
        state = evaluate(send, '({w: innerWidth, h: innerHeight, d: devicePixelRatio})')
        attempts.append({**override, **state})
        if abs(state['w'] - css_width) <= 2 and abs(state['d'] - 1.0) <= 0.02:
            break
        override = {
            'width': max(200, round(override['width'] * css_width / state['w'])),
            'height': max(200, round(override['height'] * css_height / state['h'])),
            'deviceScaleFactor': round(min(8.0, max(0.1,
                                                   override['deviceScaleFactor'] / state['d'])), 6),
        }
    evidence['override_attempts'] = attempts
    evidence['override'] = override
    evidence['measured_after_override'] = state

    freeze_animation(send)
    settle(send)

    evidence['before'] = evaluate(send, _SECTION_RECT.replace('__NEEDLE__', json.dumps(needle)))
    if not evidence['before'] or not evidence['before'].get('found'):
        if not keep_override:
            try:
                send('Emulation.clearDeviceMetricsOverride')
            except Exception:  # noqa: BLE001
                pass
        return evidence

    frame_height = state['h']
    planned = frames or max(1, -(-(evidence['before']['height'] + offset) // frame_height))
    out_path.parent.mkdir(parents=True, exist_ok=True)
    shots = []
    for index in range(min(planned, 8)):
        target = offset - index * frame_height
        scrolled = evaluate(send, _SCROLL_TO_CARD
                            .replace('__NEEDLE__', json.dumps(needle))
                            .replace('__TARGET__', str(target)))
        settle(send)
        path = out_path if index == 0 else out_path.with_name(
            f'{out_path.stem}_{index + 1}.png')
        shot = capture(send, path)
        shot['scroll'] = scrolled
        shot['frame'] = index + 1
        shots.append(shot)
    evidence['frames'] = shots
    evidence['after'] = evaluate(send, _SECTION_RECT.replace('__NEEDLE__', json.dumps(needle)))
    evidence['section_height'] = evidence['before']['height']
    evidence['frame_count'] = len(shots)

    if not keep_override:
        try:
            send('Emulation.clearDeviceMetricsOverride')
        except Exception:  # noqa: BLE001
            pass
    return evidence


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--page', default='8093')
    parser.add_argument('--needle', default='Synthetic chart preview')
    parser.add_argument('--out', required=True, help='first frame path')
    parser.add_argument('--css-viewport', default='1360x1000',
                        help='frame size in CSS pixels (1 image px per CSS px)')
    parser.add_argument('--offset', type=int, default=250,
                        help='px of frame above the card top (clears sticky chrome)')
    parser.add_argument('--frames', type=int, default=0,
                        help='0 = as many as the section is tall')
    parser.add_argument('--keep-override', action='store_true',
                        help='leave the emulated viewport in place')
    args = parser.parse_args()

    css_width, css_height = (int(part) for part in args.css_viewport.lower().split('x'))

    ws, send, target = connect(args.page)
    evidence: dict = {'target_url': target.get('url')}
    try:
        send('Page.enable')
        send('Runtime.enable')
        try:
            send('Page.bringToFront')
        except Exception as exc:  # noqa: BLE001
            evidence['bring_to_front'] = f'{type(exc).__name__}'
        evidence.update(capture_section(
            send, evaluate, needle=args.needle, out_path=Path(args.out),
            css_viewport=(css_width, css_height), offset=args.offset,
            frames=args.frames, keep_override=args.keep_override))
    finally:
        try:
            ws.close()
        except Exception:  # noqa: BLE001
            pass

    print(json.dumps(evidence, indent=2))
    return 0 if evidence.get('frame_count') else 2


if __name__ == '__main__':
    sys.exit(main())
