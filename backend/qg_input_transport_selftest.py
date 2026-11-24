"""OFFLINE self-test of Project1 TokenHarbor provider's outbound request.

Run from the backend folder:
    python qg_input_transport_selftest.py
or:
    python path/to/qg_input_transport_selftest.py

Requires existing backend environment with httpx, pydantic and sitewise installed.
Makes ZERO network requests. Never loads the real TokenHarbour API key.
This verifies TokenHarbor.complete(), NOT the full assessment -> QG workflow.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import httpx
from pydantic import BaseModel, SecretStr

# Find backend/src when this script is placed in backend/ or backend/tools/.
for root in [Path.cwd(), Path(__file__).resolve().parent, Path(__file__).resolve().parent.parent]:
    source = root / "src"
    if (source / "sitewise" / "project1" / "provider.py").is_file():
        sys.path.insert(0, str(source))
        break

from sitewise.project1.provider import MODEL, TokenHarbor  # noqa: E402
from sitewise.project1.contracts import WorkflowHeld  # noqa: E402


class ProbeReply(BaseModel):
    question: str
    options: list[str]


def main() -> None:
    # Deliberately synthetic — never read backend/.env or connect to TokenHarbour.
    fake_key = "OFFLINE_TEST_KEY_DO_NOT_USE"
    marker = "OFFLINE_QG_INPUT_SENTINEL_20261123"
    messages = [
        {"role": "system", "content": "Offline fixed-option question-generation transport check."},
        {"role": "user", "content": "Generate a sample café question. " + marker},
    ]
    captured: list[dict] = []

    def fake_provider(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST", "Wrong HTTP method"
        assert str(request.url) == "https://tokenharbor.ai/v1/chat/completions", "Wrong endpoint"
        assert request.headers.get("Authorization") == "Bearer " + fake_key, "Bearer key missing/wrong"
        assert request.headers.get("Content-Type", "").startswith("application/json"), "Wrong media type"
        payload = json.loads(request.content.decode("utf-8"))
        assert payload["model"] == MODEL, "Wrong model"
        assert payload["messages"] == messages, "Input messages omitted or changed"
        assert marker in payload["messages"][1]["content"], "Input sentinel missing"
        assert payload["response_format"]["type"] == "json_schema", "Structured mode missing"
        assert payload["response_format"]["json_schema"]["strict"] is True
        assert payload["stream"] is False
        captured.append({
            "method": request.method,
            "model": payload["model"],
            "message_count": len(payload["messages"]),
            "roles": [m["role"] for m in payload["messages"]],
            "sentinel_present": True,
            "bearer_header_present": True,
            "structured_mode": payload["response_format"]["type"],
            "request_bytes": len(request.content),
            "request_sha256": hashlib.sha256(request.content).hexdigest(),
        })
        response = {
            "model": MODEL,
            "choices": [{
                "finish_reason": "stop",
                "message": {"role": "assistant", "content": json.dumps({
                    "question": "Would you consider visiting this hypothetical café?",
                    "options": ["Yes", "No"],
                })},
            }],
            "usage": {"prompt_tokens": 40, "completion_tokens": 20, "total_tokens": 60},
        }
        return httpx.Response(200, json=response)

    provider = TokenHarbor(
        SecretStr(fake_key),
        enabled=True,
        structured_mode="json_schema",
        timeout=10,
        transport=httpx.MockTransport(fake_provider),
    )
    output = provider.complete(messages, ProbeReply)
    assert output["options"] == ["Yes", "No"]
    assert len(captured) == 1, "Expected exactly one intercepted request"
    assert provider.last_execution["schema_validation"] == "VALID"
    assert provider.last_execution["identity_verified"] is True
    print("PASS — offline provider request was intercepted, with no network call")
    print(json.dumps(captured[0], indent=2))
    print("NOTE: This confirms TokenHarbor.complete() attaches these synthetic messages and a bearer header.")
    print("It does NOT prove the actual Assessment/BCB/QG route supplied the expected real input.")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, WorkflowHeld, Exception) as exc:
        # Exception messages from this offline test are synthetic; no real secrets are loaded.
        print("FAIL — offline provider request check:", type(exc).__name__, str(exc))
        raise SystemExit(1)
