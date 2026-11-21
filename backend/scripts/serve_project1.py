"""PROJECT1 launcher with an explicit, verified database target.

Replaces the implicit-override behaviour of
``artifacts/cp10_m2_e2e/20261118T030912Z/logs/serve_cp10.py``, which silently retargeted
``M2_DATABASE_URL`` to a clone *and* lowered ``M2_EXPECTED_DATABASE`` to match. That made a
clone run indistinguishable from an authoritative run in every log line and every API
response, which is exactly the failure mode this script removes.

Targets
-------
    --target dss              authoritative Dss; expected database stays "Dss"
    --target clone --clone-name project1_workflow_tests
                              disposable clone; expected database is the clone name AND
                              the process is marked NON-AUTHORITATIVE in logs and /health

The marketplace ``DATABASE_URL`` is never modified. It stays on Final_Location_Analysis
because the catalogue, property and location-scoring tables live there and are absent from
Dss (CP-10 database authority review, §DSS_VS_FINAL_LOCATION_ANALYSIS).

Startup identity is verified against the live server, not against the configured string.
If the connection lands in a database other than the declared target, the process exits
before serving a single request.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ENV = BACKEND / ".env"


def _env_value(name: str) -> str:
    if not ENV.exists():
        return ""
    match = re.search(r"^" + re.escape(name) + r"=(.*)$", ENV.read_text(encoding="utf-8"), re.M)
    return match.group(1).strip().strip('"') if match else ""


def _with_database(url: str, database: str) -> str:
    return re.sub(r"/[^/?]+(\?.*)?$", "/" + database, url, count=1)


def configure(target: str, clone_name: str | None) -> dict[str, str]:
    """Return the environment overrides for a target. Pure; no os.environ mutation."""
    m2_url = _env_value("M2_DATABASE_URL")
    runtime_url = _env_value("PROJECT1_RUNTIME_DATABASE_URL")
    audit_url = _env_value("PROJECT1_AUDIT_DATABASE_URL")

    if target == "dss":
        if not m2_url:
            raise SystemExit("M2_DATABASE_URL is not configured; refusing to start on Dss.")
        return {
            "M2_DATABASE_URL": m2_url,
            "M2_EXPECTED_DATABASE": "Dss",
            "PROJECT1_DB_TARGET": "dss",
            "PROJECT1_DB_AUTHORITATIVE": "1",
        }

    if not clone_name:
        raise SystemExit("--clone-name is required with --target clone.")
    if clone_name == "Dss":
        raise SystemExit("A clone may not be named 'Dss'.")
    if not m2_url:
        raise SystemExit("M2_DATABASE_URL is not configured; cannot derive a clone target.")

    return {
        "M2_DATABASE_URL": _with_database(m2_url, clone_name),
        # Explicit, not lowered by accident: the operator named this clone.
        "M2_EXPECTED_DATABASE": clone_name,
        "PROJECT1_DB_TARGET": f"clone:{clone_name}",
        "PROJECT1_DB_AUTHORITATIVE": "0",
    }


def verify_startup(overrides: dict[str, str]) -> None:
    """Connect through the real application settings and prove where we landed."""
    # Settings are read from backend/.env, which pydantic resolves relative to the
    # working directory. Without this chdir the process would silently load the
    # built-in defaults (m2_upstream_enabled=False, database_url=Dss) and mount a
    # different router set than the one configured.
    os.chdir(BACKEND)
    sys.path.insert(0, str(BACKEND / "src"))
    for key, value in overrides.items():
        os.environ[key] = value

    from sitewise.core.db_identity import banner, describe, verify_or_raise
    from sitewise.db.m2_session import get_m2_engine

    engine = get_m2_engine()
    identity = verify_or_raise(engine, overrides["M2_EXPECTED_DATABASE"])
    print(banner(identity), flush=True)
    if not identity.authoritative:
        print(
            "[db-target] WARNING: this process writes PROJECT1 records to a disposable clone. "
            "Nothing it does is evidence about Dss.",
            flush=True,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=("dss", "clone"), required=True)
    parser.add_argument("--clone-name", default=None)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--verify-only", action="store_true",
                        help="verify identity and exit without serving")
    args = parser.parse_args()

    overrides = configure(args.target, args.clone_name)
    verify_startup(overrides)
    if args.verify_only:
        return

    os.environ["PYTHONPATH"] = str(BACKEND / "src")
    os.environ.setdefault("PYTHONUTF8", "1")
    os.environ["NO_PROXY"] = "localhost,127.0.0.1,::1"
    os.environ["no_proxy"] = "localhost,127.0.0.1,::1"
    os.chdir(BACKEND)

    import uvicorn

    uvicorn.run("sitewise.main:app", host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
