"""Bring up the disposable stack for the EX-05 authenticated browser E2E.

Same layered-disposability contract as ``phase4_launch_browser_e2e_20261122.py``
(the Phase 4 browser E2E this follows), with the app server swapped for the
EX-05 launcher so the CQ runtime and the EE-01 explanation chain are enabled:

1. the local GoTrue stub (``phase4_gotrue_stub_20261122.py``) on 127.0.0.1:54329;
2. a private copy of the compiled Jaspr frontend whose ``auth-config.json``
   points at that stub instead of the live Supabase project;
3. the real FastAPI application (``ex05_serve_disposable_20261123.py``) on
   127.0.0.1:8091, serving that frontend on the same origin, with the JWKS
   bytes supplied by the stub's public key, the admin service replaced by the
   in-memory fake, every database engine pointed at
   ``project1_workflow_tests@5433`` and the EE-01 connections assuming the
   restricted ``p1_ee01_runtime`` role.

Guards inherited from the Phase 4 launcher:

* ``SUPABASE_URL`` must be a loopback address — a production URL is refused;
* ``SITEWISE_ALLOW_LOCAL_AUTH`` must be exactly ``disposable-e2e``;
* the frontend copy is written under ``backend/var/e2e`` so no tracked or
  build artifact is modified.

Nothing here contacts the live Supabase project or any protected database.
The browser performs a real password sign-in against the stub and receives a
real ES256 token, which the backend verifies through its normal code path.

Usage::

    python tools/ex05_launch_browser_e2e_20261123.py --print-env
    python tools/ex05_launch_browser_e2e_20261123.py            # runs until Ctrl-C
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
FRONTEND_BUILD = ROOT / "fyp_jaspr_web" / "build" / "jaspr"
E2E_DIR = BACKEND / "var" / "e2e" / "ex05"

TARGET_DB = "project1_workflow_tests"
TARGET_PORT = 5433
GOTRUE_PORT = 54329
APP_PORT = 8091
LOCAL_FLAG = ("SITEWISE_ALLOW_LOCAL_AUTH", "disposable-e2e")


def _db_password() -> str:
    text = (BACKEND / ".env").read_text(encoding="utf-8", errors="replace")
    match = re.search(r"^DATABASE_URL=(.*)$", text, re.M)
    if not match:
        raise SystemExit("DATABASE_URL not found in backend/.env")
    cred = re.match(r"^[^:]+://[^:]+:([^@]+)@", match.group(1).strip())
    if not cred:
        raise SystemExit("DATABASE_URL has no inline password")
    return cred.group(1)


def _env() -> dict:
    password = _db_password()
    url = f"postgresql+psycopg2://postgres:{password}@127.0.0.1:{TARGET_PORT}/{TARGET_DB}"
    issuer = f"http://127.0.0.1:{GOTRUE_PORT}"

    env = dict(os.environ)
    env.update({
        # every database handle points at the disposable workflow database
        "DATABASE_URL": url,
        "M2_DATABASE_URL": url,
        "PROJECT1_RUNTIME_DATABASE_URL": url,
        "ANALYTICS_DATABASE_URL": url,
        # identity provider: the local stub, on both sides
        "SUPABASE_URL": issuer,
        "SUPABASE_JWKS_URL": f"{issuer}/auth/v1/.well-known/jwks.json",
        "SUPABASE_JWT_AUDIENCES": "authenticated",
        "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_local_e2e",
        "SUPABASE_ADMIN_TIMEOUT_SECONDS": "5",
        # workflow routing
        "PROJECT1_WORKFLOW_ENABLED": "true",
        "M2_UPSTREAM_ENABLED": "true",
        "PROJECT1_BDJ_CONTRACT": "findings",
        "PROJECT1_ISOLATED_DATABASE_NAME": TARGET_DB,
        "PROJECT1_ISOLATED_DATABASE_PORT": str(TARGET_PORT),
        "M2_EXPECTED_DATABASE": TARGET_DB,
        # the private frontend copy
        "SITEWISE_FRONTEND_DIST": str(E2E_DIR / "frontend"),
        "LOG_LEVEL": "WARNING",
    })
    env[LOCAL_FLAG[0]] = LOCAL_FLAG[1]
    return env


def _guard(env: dict) -> dict:
    """Refuse to start unless every layer is provably disposable."""
    if env.get(LOCAL_FLAG[0]) != LOCAL_FLAG[1]:
        raise SystemExit(f"REFUSED: {LOCAL_FLAG[0]} must be {LOCAL_FLAG[1]}")

    supabase = urlparse(env["SUPABASE_URL"])
    if supabase.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise SystemExit(
            f"REFUSED: SUPABASE_URL must be loopback, got {supabase.hostname!r}. "
            "The local key override must never be usable against a real identity provider."
        )

    from sqlalchemy import create_engine, text

    seen = {}
    for name in ("DATABASE_URL", "M2_DATABASE_URL", "PROJECT1_RUNTIME_DATABASE_URL"):
        engine = create_engine(env[name])
        try:
            with engine.connect() as conn:
                db, port = conn.execute(
                    text("SELECT current_database(), inet_server_port()")
                ).one()
        finally:
            engine.dispose()
        if db != TARGET_DB or int(port) != TARGET_PORT:
            raise SystemExit(f"REFUSED: {name} resolves to {db}@{port}")
        seen[name] = f"{db}@{port}"
    return seen


def _prepare_frontend() -> Path:
    if not (FRONTEND_BUILD / "index.html").is_file():
        raise SystemExit(f"frontend build not found: {FRONTEND_BUILD}")
    target = E2E_DIR / "frontend"
    # Copy over the top; never rmtree. A recursive delete of ~160 files trips
    # bulk-delete guards, and an additive copy is enough because the build only
    # gains files between runs.
    target.mkdir(parents=True, exist_ok=True)
    shutil.copytree(FRONTEND_BUILD, target, dirs_exist_ok=True)

    config_path = target / "auth-config.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    config["supabaseUrl"] = f"http://127.0.0.1:{GOTRUE_PORT}"
    config["supabasePublishableKey"] = "sb_publishable_local_e2e"
    config["_note"] = (
        "DISPOSABLE EX-05 E2E COPY. Points at the local GoTrue stub on "
        f"127.0.0.1:{GOTRUE_PORT}. Never deployed; generated under backend/var/e2e/ex05."
    )
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    return target


def _wait_port(port: int, timeout: float = 30.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        with socket.socket() as sock:
            sock.settimeout(0.5)
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.2)
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--print-env", action="store_true")
    parser.add_argument(
        "--identity", default="gatebc-e2e-b9e62014@example.invalid",
        help="Email the stub signs in by default. The EX-05 fixture chain "
             "(campaign/snapshot/explanation result) is owned by this identity.",
    )
    args = parser.parse_args()

    env = _env()
    identity = _guard(env)
    frontend = _prepare_frontend()

    report = {
        "identity": identity,
        "issuer": env["SUPABASE_URL"] + "/auth/v1",
        "gotrue": f"http://127.0.0.1:{GOTRUE_PORT}",
        "app": f"http://127.0.0.1:{APP_PORT}",
        "frontend_dist": str(frontend),
        "app_server": "ex05_serve_disposable_20261123.py",
        "ee01_role": "p1_ee01_runtime",
        "users": [
            "gatebc-e2e-b9e62014@example.invalid",
            "gatebc-e2e-c70a999a@example.invalid",
        ],
        "password": "e2e-local-password",
    }

    if args.print_env:
        print(json.dumps(report, indent=2))
        return 0

    if _wait_port(GOTRUE_PORT, 0.5):
        raise SystemExit(f"port {GOTRUE_PORT} already in use")
    if _wait_port(APP_PORT, 0.5):
        raise SystemExit(f"port {APP_PORT} already in use")

    E2E_DIR.mkdir(parents=True, exist_ok=True)
    gotrue_log = (E2E_DIR / "gotrue.out").open("w", encoding="utf-8")
    app_log = (E2E_DIR / "app.out").open("w", encoding="utf-8")

    stub_cmd = [
        sys.executable, str(BACKEND / "tools" / "phase4_gotrue_stub_20261122.py"),
        "--port", str(GOTRUE_PORT),
    ]
    if args.identity:
        stub_cmd += ["--default-identity", args.identity]
    stub = subprocess.Popen(
        stub_cmd,
        cwd=str(BACKEND), env=env, stdout=gotrue_log, stderr=subprocess.STDOUT,
    )
    if not _wait_port(GOTRUE_PORT):
        stub.terminate()
        raise SystemExit("GoTrue stub did not start; see backend/var/e2e/ex05/gotrue.out")

    app = subprocess.Popen(
        [sys.executable, str(BACKEND / "tools" / "ex05_serve_disposable_20261123.py"),
         "--port", str(APP_PORT)],
        cwd=str(BACKEND), env=env, stdout=app_log, stderr=subprocess.STDOUT,
    )
    if not _wait_port(APP_PORT, 60):
        app.terminate()
        stub.terminate()
        raise SystemExit("application did not start; see backend/var/e2e/ex05/app.out")

    report["started"] = True
    print(json.dumps(report, indent=2), flush=True)
    try:
        while stub.poll() is None and app.poll() is None:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        for proc in (app, stub):
            if proc.poll() is None:
                proc.terminate()
        gotrue_log.close()
        app_log.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
