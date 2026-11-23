"""Drive the debuggable Chrome over the DevTools Protocol.

The virtual-desktop route is not used here: the app under test is a Flutter web
build that renders into a canvas, so DOM automation is not available, and the
interactive agent cannot be pointed at the user's own Chrome. CDP gives direct
control of a real browser plus deterministic, file-backed evidence.

Actions are executed in the order given on the command line, so a single
invocation can express a whole step of the journey.

Examples::

    python tools/cdp_20261122.py --shot out/01.png
    python tools/cdp_20261122.py --url http://127.0.0.1:8091 --wait 6000 --shot out/02.png
    python tools/cdp_20261122.py --click 1130,120 --wait 800 --shot out/03.png
    python tools/cdp_20261122.py --text 'a@b.c' --key Tab --text 'pw' --key Enter
    python tools/cdp_20261122.py --eval 'document.title'
"""
from __future__ import annotations

import argparse
import base64
import json
import sys
import time
from pathlib import Path

import requests
import websocket

CDP_HTTP = 'http://127.0.0.1:9222'


def _page_target() -> dict:
    targets = requests.get(f'{CDP_HTTP}/json/list', timeout=5).json()
    pages = [t for t in targets if t.get('type') == 'page' and t.get('webSocketDebuggerUrl')]
    if not pages:
        raise SystemExit('no page target; is Chrome running with --remote-debugging-port=9222?')
    for target in pages:
        if '127.0.0.1:8091' in (target.get('url') or ''):
            return target
    return pages[0]


class CDP:
    def __init__(self) -> None:
        self.target = _page_target()
        self.ws = websocket.create_connection(
            self.target['webSocketDebuggerUrl'], timeout=30,
            header=['Origin: http://127.0.0.1:9222'],
        )
        self._id = 0

    def send(self, method: str, **params):
        self._id += 1
        message_id = self._id
        self.ws.send(json.dumps({'id': message_id, 'method': method, 'params': params}))
        while True:
            raw = self.ws.recv()
            message = json.loads(raw)
            if message.get('id') == message_id:
                if 'error' in message:
                    raise RuntimeError(f'{method}: {message["error"]}')
                return message.get('result', {})

    def close(self) -> None:
        try:
            self.ws.close()
        except Exception:  # noqa: BLE001
            pass


def shot(cdp: CDP, path: Path, full: bool = False) -> dict:
    path.parent.mkdir(parents=True, exist_ok=True)
    result = cdp.send('Page.captureScreenshot', format='png', captureBeyondViewport=full)
    path.write_bytes(base64.b64decode(result['data']))
    return {'screenshot': str(path), 'bytes': path.stat().st_size}


def click(cdp: CDP, x: float, y: float) -> dict:
    for kind in ('mousePressed', 'mouseReleased'):
        cdp.send('Input.dispatchMouseEvent', type=kind, x=x, y=y,
                 button='left', clickCount=1, buttons=1 if kind == 'mousePressed' else 0)
        time.sleep(0.05)
    return {'clicked': [x, y]}


def type_text(cdp: CDP, text: str) -> dict:
    cdp.send('Input.insertText', text=text)
    return {'typed_length': len(text)}


def press(cdp: CDP, key: str) -> dict:
    mapping = {
        'Enter': (13, 'Enter', '\r'),
        'Tab': (9, 'Tab', '\t'),
        'Escape': (27, 'Escape', ''),
        'Backspace': (8, 'Backspace', ''),
    }
    code, name, text = mapping.get(key, (0, key, ''))
    base = {'key': name, 'code': name, 'windowsVirtualKeyCode': code, 'nativeVirtualKeyCode': code}
    cdp.send('Input.dispatchKeyEvent', type='keyDown', **base, **( {'text': text} if text else {}))
    cdp.send('Input.dispatchKeyEvent', type='keyUp', **base)
    return {'key': key}


def evaluate(cdp: CDP, expression: str) -> dict:
    result = cdp.send('Runtime.evaluate', expression=expression, returnByValue=True,
                      awaitPromise=True)
    return {'value': result.get('result', {}).get('value')}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--url')
    parser.add_argument('--wait', type=int, default=0)
    parser.add_argument('--shot')
    parser.add_argument('--shot-full', action='store_true')
    parser.add_argument('--click')
    parser.add_argument('--text')
    parser.add_argument('--key')
    parser.add_argument('--eval')
    parser.add_argument('--reload', action='store_true')
    parser.add_argument('--title', action='store_true')
    args = parser.parse_args()

    cdp = CDP()
    out: list[dict] = [{'target': cdp.target.get('url')}]
    try:
        if args.url:
            cdp.send('Page.enable')
            cdp.send('Page.navigate', url=args.url)
            out.append({'navigated': args.url})
        if args.reload:
            cdp.send('Page.reload', ignoreCache=False)
            out.append({'reloaded': True})
        if args.wait:
            time.sleep(args.wait / 1000)
            out.append({'waited_ms': args.wait})
        if args.click:
            x, y = (float(v) for v in args.click.split(','))
            out.append(click(cdp, x, y))
        if args.text:
            out.append(type_text(cdp, args.text))
        if args.key:
            out.append(press(cdp, args.key))
        if args.eval:
            out.append(evaluate(cdp, args.eval))
        if args.title:
            out.append(evaluate(cdp, 'document.title'))
        if args.shot:
            time.sleep(0.4)
            out.append(shot(cdp, Path(args.shot), full=args.shot_full))
    finally:
        cdp.close()

    print(json.dumps(out, indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
