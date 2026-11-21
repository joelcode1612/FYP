"""One-shot bounded TokenHarbor provider diagnostic.

Purpose: after the exposed key is rotated, prove the *real* provider adapter works:
credential accepted, returned model identity == expected, structured output validated,
single no-retry call within the timeout budget. This does NOT exercise the ledger or a
disclosure adapter (neither has an honest production implementation yet) and makes NO
claim beyond the provider adapter boundary.

Safety:
- Refuses to run while the stored key still matches the previously exposed key.
- Never prints the key value; prints only a SHA-256 prefix.
- Exactly one provider call, no retry, no redirect (delegated to TokenHarbor.complete).
- Requires an explicit acknowledgement flag.

Usage:
    python scripts/tokenharbor_diagnostic.py --i-understand-this-makes-one-live-call
"""
import argparse
import hashlib
import sys
import time
from pathlib import Path
from typing import Literal

# Import the real adapter; do not reimplement its checks here.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from pydantic import BaseModel, ConfigDict  # noqa: E402

from sitewise.core.config import settings  # noqa: E402
from sitewise.project1.contracts import WorkflowHeld  # noqa: E402
from sitewise.project1.provider import MODEL, TokenHarbor  # noqa: E402

# SHA-256 prefix of the key that was exposed in an earlier session. Any key whose
# prefix equals this must be treated as compromised and refused.
EXPOSED_KEY_SHA256_12 = "9e9644b42e51"


class DiagnosticOutput(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)
    status: Literal["OK"]


def key_prefix(secret: str) -> str:
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()[:12]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--i-understand-this-makes-one-live-call",
        action="store_true",
        help="Required acknowledgement that this makes a single live external call.",
    )
    args = parser.parse_args()
    if not args.i_understand_this_makes_one_live_call:
        print("REFUSED: pass --i-understand-this-makes-one-live-call to proceed.")
        return 2

    raw = settings.tokenharbor_api_key.get_secret_value()
    if not raw:
        print("BLOCKED: PROVIDER_NOT_CONFIGURED (no key in settings).")
        return 3

    prefix = key_prefix(raw)
    print(f"key_sha256_12={prefix}")
    if prefix == EXPOSED_KEY_SHA256_12:
        print("BLOCKED: KEY_NOT_ROTATED — stored key still matches the exposed key. "
              "Rotate it in the TokenHarbor dashboard and update backend/.env first.")
        return 4

    # Operator diagnostic: explicitly enable the provider for this single call
    # without changing the persisted tokenharbor_enabled flag.
    provider = TokenHarbor(
        settings.tokenharbor_api_key,
        enabled=True,
        structured_mode=settings.tokenharbor_structured_mode,
        timeout=max(1, min(settings.tokenharbor_timeout_seconds, 60)),
    )
    messages = [{
        "role": "user",
        "content": 'Reply with exactly this JSON object and nothing else: {"status": "OK"}',
    }]

    started = time.monotonic()
    try:
        result = provider.complete(messages, DiagnosticOutput)
    except WorkflowHeld as exc:
        elapsed = time.monotonic() - started
        print(f"result=FAIL code={exc} elapsed_s={elapsed:.3f}")
        print("note=provider adapter returned a governed hold; no retry was attempted.")
        return 5
    elapsed = time.monotonic() - started
    print(f"result=PASS elapsed_s={elapsed:.3f}")
    print(f"expected_model={MODEL}")
    print("model_identity=VALIDATED (adapter raises PROVIDER_MODEL_MISMATCH on any other model)")
    print(f"validated_output={result}")
    print("receipt=PROVIDER_ADAPTER_ONLY (no ledger/disclosure claim)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
