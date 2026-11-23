"""Serve the app for M2 V2 synthetic verification, reusing the proven E2E seams.

Delegates app composition to ``phase4_serve_disposable_20261122.build_app``,
which is the already-reviewed offline-auth configuration (local JWKS key plus
``FakeSupabaseAdmin``), and adds exactly one thing: an explicitly declared
synthetic instrument scope.

The scope is gated structurally. It is enabled only when all of the following
hold, and the process exits otherwise:

* ``--synthetic-scope`` is passed with a non-empty name
* ``DATABASE_URL`` resolves to an isolated ``project1_*`` database on a
  non-5432 port
* the derived target is declared to ``configured_target()`` so the authorization
  gate can verify it independently

The stored ``approval_state`` of any instrument is never modified.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / "src"))
sys.path.insert(0, str(BACKEND))


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--port", type=int, default=8091)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--env-file", default=str(BACKEND / "var" / "e2e" / "app.env"))
    p.add_argument("--synthetic-scope", default="",
                   help="Enable the synthetic instrument scope under this name.")
    args = p.parse_args()

    from dotenv import load_dotenv
    load_dotenv(args.env_file, override=True)

    from sqlalchemy.engine import make_url
    raw = os.environ.get("DATABASE_URL", "")
    url = make_url(raw) if raw else None
    if (url is None or not url.database
            or url.database in {"Dss", "Final_Location_Analysis", "postgres"}
            or url.port in (None, 5432)
            or not url.database.startswith("project1_")):
        raise SystemExit("Refusing: runtime binding is not a disposable project1_* target.")

    if args.synthetic_scope:
        os.environ["M2_SYNTHETIC_INSTRUMENT_SCOPE"] = args.synthetic_scope
        os.environ["PROJECT1_ISOLATED_DATABASE_NAME"] = url.database
        os.environ["PROJECT1_ISOLATED_DATABASE_PORT"] = str(url.port)
        os.environ["M2_EXPECTED_DATABASE"] = url.database
        print(f"synthetic scope '{args.synthetic_scope}' declared on "
              f"{url.database}@{url.port}", flush=True)

    from tools.phase4_serve_disposable_20261122 import build_app
    app = build_app()

    import uvicorn
    uvicorn.run(app, host=args.host, port=args.port,
                log_level=os.environ.get("LOG_LEVEL", "warning").lower())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
