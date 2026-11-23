"""Bounded synthetic cloud diagnostics for the two supplied demonstration files.

Phase D of the Gate D assignment. This runner exists so that credentials stay
process-scoped and never appear in argv, logs or evidence:

* it reads the provider key from a local env file into ``os.environ`` only;
* it never writes to a ``.env`` file;
* it redacts any secret-shaped token from captured output before persisting it;
* it runs each demonstration at most once per invocation, with no retry.

Subcommands
-----------
``models``
    Read-only catalogue probe (``GET {base}/models``) so a diagnostic can be
    dispatched at a model the provider actually serves. This is *not* a
    completion and does not consume the one-call budget.

``bdj-preview`` / ``bdj-live``
    Drive ``tools/bdj_prompt_validation_cloud_demo_20261121.py``. Preview sends
    nothing; live performs one chat completion.

``qg-preview`` / ``qg-live``
    Drive ``tools/project1_qj_qg_question_options_cloud_demo.py`` with
    ``--objective 2`` (``selection_factors``, the branch that reaches the cloud
    because it is absent from the demo question bank).

Nothing here touches a database, persists a proposal, or activates QG.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import runpy
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
EVIDENCE_DIR = ROOT / "deliverables/phase2"

# The demonstrations import ``sitewise`` directly, so make the source tree
# importable regardless of whether the venv has an editable install.
if str(BACKEND / "src") not in sys.path:
    sys.path.insert(0, str(BACKEND / "src"))

BDJ_DEMO = "tools/bdj_prompt_validation_cloud_demo_20261121.py"
QG_DEMO = "tools/project1_qj_qg_question_options_cloud_demo.py"
#: The objective-proposal diagnostic. Needed because the supplied BDJ demo only
#: exercises the legacy BDJOutput/findings contract and cannot reach
#: PROMPTS["BDJ_OBJECTIVE"] or validate_objective_proposal at all.
OBJ_DEMO = "tools/bdj_objective_proposal_live_20261121.py"

#: Backup env file that still carries the project's own provider key. The
#: active .env has no TOKENHARBOR_API_KEY, so this is read here and injected
#: process-scoped rather than by editing any persistent file.
DEFAULT_ENV_FILE = BACKEND / ".env.bak.path1"

SECRET_PATTERNS = (
    re.compile(r"thk_[A-Za-z0-9_\-]{8,}"),
    re.compile(r"sk-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"(?i)(authorization:\s*bearer\s+)\S+"),
)


def sanitize(text: str, secrets: list[str]) -> str:
    for secret in secrets:
        if secret:
            text = text.replace(secret, "<redacted>")
    for pattern in SECRET_PATTERNS:
        text = pattern.sub("<redacted>", text)
    return text


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def chat_base(endpoint: str) -> str:
    """``…/v1/chat/completions`` -> ``…/v1`` for the catalogue probe."""
    return endpoint.rsplit("/chat/completions", 1)[0] if "/chat/completions" in endpoint else endpoint.rstrip("/")


def probe_models(api_key: str, endpoint: str) -> dict:
    url = chat_base(endpoint) + "/models"
    request = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {api_key}", "Accept": "application/json"},
        method="GET")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            status = response.status
            body = response.read(200_000)
    except urllib.error.HTTPError as exc:
        return {"url": url, "http_status": exc.code, "error": "HTTPError", "ids": []}
    except (urllib.error.URLError, TimeoutError) as exc:
        return {"url": url, "http_status": None, "error": type(exc).__name__, "ids": []}
    ids = []
    try:
        payload = json.loads(body)
        for item in payload.get("data", []):
            if isinstance(item, dict) and isinstance(item.get("id"), str):
                ids.append(item["id"])
    except (ValueError, AttributeError):
        return {"url": url, "http_status": status, "error": "NOT_JSON", "ids": []}
    return {"url": url, "http_status": status, "error": None, "ids": sorted(ids)}


def run_demo(demo: str, argv: list[str], env: dict[str, str], secrets: list[str]) -> dict:
    """Execute a demonstration in-process, capturing sanitised output."""
    import io
    from contextlib import redirect_stderr, redirect_stdout

    out, err = io.StringIO(), io.StringIO()
    previous_argv = sys.argv
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    sys.argv = [str(BACKEND / demo)] + argv
    code = 0
    try:
        with redirect_stdout(out), redirect_stderr(err):
            runpy.run_path(str(BACKEND / demo), run_name="__main__")
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else (0 if exc.code is None else 1)
    except BaseException as exc:  # noqa: BLE001 - the demo must not take us down
        code = 70
        err.write(f"\nUNCAUGHT {type(exc).__name__}: {exc}")
    finally:
        sys.argv = previous_argv
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    return {"argv": argv, "exit_code": code,
            "stdout": sanitize(out.getvalue(), secrets),
            "stderr": sanitize(err.getvalue(), secrets),
            "env_names": sorted(env)}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["models", "bdj-preview", "bdj-live",
                                         "obj-preview", "obj-live",
                                         "qg-preview", "qg-live"])
    parser.add_argument("--env-file", default=str(DEFAULT_ENV_FILE))
    parser.add_argument("--model", default=None,
                        help="Override the model id; normally the id the catalogue probe reported")
    parser.add_argument("--endpoint", default="https://tokenharbor.ai/v1/chat/completions")
    parser.add_argument("--out", default=None)
    args = parser.parse_args(argv)

    env_file = Path(args.env_file)
    file_values = read_env_file(env_file)
    api_key = file_values.get("TOKENHARBOR_API_KEY", "") or os.environ.get("TOKENHARBOR_API_KEY", "")
    model = args.model or os.environ.get("QG_DEMO_LLM_MODEL") or "deepseek-v4.1-flash-1017"
    secrets = [api_key] if api_key else []

    record: dict = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mode": args.mode,
        "credential_source": str(env_file.relative_to(ROOT)) if env_file.is_relative_to(ROOT) else str(env_file),
        "credential_present": bool(api_key),
        "endpoint": args.endpoint,
        "model": model,
        "persistent_env_modified": False,
    }

    if not api_key:
        record["result"] = "BLOCKED"
        record["blocked_reason"] = ("No provider credential found in the supplied env file or "
                                    "the process environment; nothing was dispatched.")
    elif args.mode == "models":
        record["catalogue"] = probe_models(api_key, args.endpoint)
        record["result"] = "OK" if record["catalogue"]["ids"] else "NO_IDS"
    elif args.mode.startswith("bdj"):
        env = {"TOKENHARBOR_ENABLED": "true", "TOKENHARBOR_API_KEY": api_key}
        demo_argv = (["--show-cloud-request"] if args.mode == "bdj-preview"
                     else ["--live", "--model", model])
        record["demo"] = run_demo(BDJ_DEMO, demo_argv, env, secrets)
        record["dispatched"] = args.mode == "bdj-live"
        record["result"] = "EXECUTED" if record["demo"]["exit_code"] == 0 else "HELD_OR_FAILED"
    elif args.mode.startswith("obj"):
        env = {"TOKENHARBOR_ENABLED": "true", "TOKENHARBOR_API_KEY": api_key}
        demo_argv = ([] if args.mode == "obj-preview" else ["--live", "--model", model])
        record["demo"] = run_demo(OBJ_DEMO, demo_argv, env, secrets)
        record["dispatched"] = args.mode == "obj-live"
        record["result"] = "EXECUTED" if record["demo"]["exit_code"] == 0 else "HELD_OR_FAILED"
    else:
        env = {"QG_DEMO_LLM_API_KEY": api_key,
               "QG_DEMO_LLM_MODEL": model,
               "QG_DEMO_CHAT_COMPLETIONS_URL": args.endpoint}
        demo_argv = (["--show-cloud-request", "--objective", "2"] if args.mode == "qg-preview"
                     else ["--live", "--objective", "2"])
        record["demo"] = run_demo(QG_DEMO, demo_argv, env, secrets)
        record["dispatched"] = args.mode == "qg-live"
        record["result"] = "EXECUTED" if record["demo"]["exit_code"] == 0 else "HELD_OR_FAILED"

    out = Path(args.out) if args.out else EVIDENCE_DIR / f"BDJ_CLOUD_DIAGNOSTIC_{args.mode.upper()}_20261122.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(record, indent=2), encoding="utf-8")

    if "demo" in record:
        print(record["demo"]["stdout"])
        if record["demo"]["stderr"]:
            print("--- stderr ---")
            print(record["demo"]["stderr"])
    else:
        print(json.dumps(record.get("catalogue") or record, indent=2))
    print(f"\n[{args.mode}] result={record['result']} evidence -> {out}")
    return 0 if record["result"] in ("OK", "EXECUTED") else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
