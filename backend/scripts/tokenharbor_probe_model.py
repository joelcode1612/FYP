"""One-shot raw probe to reveal the ACTUAL model identity TokenHarbor returns.

The governed adapter (provider.TokenHarbor.complete) raises PROVIDER_MODEL_MISMATCH
without exposing the returned model. This probe makes ONE raw call with the SAME
safety constraints (no retry, no redirect, timeout budget, size cap) purely to read
envelope['model'] and finish_reason so the mismatch can be diagnosed honestly.

Never prints the key. Read-only observation; no ledger/disclosure claim.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402

from sitewise.core.config import settings  # noqa: E402
from sitewise.project1.provider import ENDPOINT, MAX_RESPONSE_BYTES, MODEL  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--i-understand-this-makes-one-live-call", action="store_true")
    args = parser.parse_args()
    if not args.i_understand_this_makes_one_live_call:
        print("REFUSED: pass --i-understand-this-makes-one-live-call")
        return 2

    raw = settings.tokenharbor_api_key.get_secret_value()
    if not raw:
        print("BLOCKED: no key")
        return 3
    print("key_sha256_12=" + hashlib.sha256(raw.encode()).hexdigest()[:12])

    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": 'Reply with JSON {"status":"OK"} only.'}],
        "temperature": 0,
        "max_tokens": 200,
        "stream": False,
    }
    budget = 30.0
    try:
        with httpx.Client(timeout=httpx.Timeout(budget, connect=min(5, budget)),
                          follow_redirects=False) as client:
            with client.stream("POST", ENDPOINT, headers={
                    "Authorization": "Bearer " + raw,
                    "Cache-Control": "no-store",
                    "Content-Type": "application/json"}, json=payload) as response:
                status = response.status_code
                body = bytearray()
                for chunk in response.iter_bytes():
                    body.extend(chunk)
                    if len(body) > MAX_RESPONSE_BYTES:
                        print("BLOCKED: response too large")
                        return 6
    except httpx.TransportError as exc:
        print(f"result=TRANSPORT_ERROR type={type(exc).__name__}")
        return 7

    print(f"http_status={status}")
    if status != 200:
        snippet = bytes(body[:400]).decode("utf-8", "replace")
        print(f"body_snippet={snippet}")
        return 0

    try:
        env = json.loads(bytes(body).decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        print(f"result=UNPARSEABLE error={type(exc).__name__}")
        return 8

    print(f"returned_model={env.get('model')!r}")
    print(f"expected_model={MODEL!r}")
    choices = env.get("choices") or []
    if choices:
        print(f"finish_reason={choices[0].get('finish_reason')!r}")
        content = (choices[0].get("message") or {}).get("content")
        print(f"content={content!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
