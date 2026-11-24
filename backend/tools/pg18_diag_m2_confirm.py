"""Reproduce the 503 on M2 confirm, with the real exception.

Purpose
    Surface the SQL error behind ``M2_SOURCE_UNAVAILABLE`` when
    ``POST /api/v1/m2/assessments/{id}/review`` is called.

Reason
    The endpoint converts any ``SQLAlchemyError`` into a bare 503 and logs
    nothing, so the refusing grant, policy or trigger is invisible from both the
    browser and the server log. Driving the same service in-process is the only
    way to see it.

Constraint
    ``--apply`` is required to write. Without it the call is refused before it
    touches the database, because ``confirm`` inserts an event row and
    this tool must not silently mutate an assessment as a side effect of a
    diagnostic run.
"""

from __future__ import annotations

import argparse
import os
import sys
import traceback
from pathlib import Path
from uuid import UUID

BACKEND = Path(__file__).resolve().parents[1]
ENV_FILE = BACKEND / "var" / "e2e" / "pg18" / "app_pg18.env"
EXPECTED_DATABASE = "project1_pg18_migrated_tests"
EXPECTED_PORT = 5544
FORBIDDEN_DATABASES = {"Dss", "Final_Location_Analysis"}

sys.path.insert(0, str(BACKEND / "src"))
sys.path.insert(0, str(BACKEND))
sys.path.insert(0, str(BACKEND / "tools"))

from dead_proxy_guard import drop_unreachable_proxies  # noqa: E402


def load_env() -> None:
    for raw in ENV_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        if k.replace("_", "").isalnum():
            os.environ[k] = v.strip().strip('"').strip("'")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assessment", required=True)
    parser.add_argument("--revision", type=int, required=True)
    parser.add_argument("--user", help="M2 owner uuid. Required: m2_assessments is "
                                       "row-scoped, so an unscoped read finds nothing.")
    parser.add_argument("--marketplace",
                        help="Marketplace assessment uuid. The link check compares this "
                             "against the stored link, so passing the M2 id here is refused.")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    assessment_id = UUID(args.assessment)

    load_env()
    drop_unreachable_proxies()

    from sqlalchemy import text

    from sitewise.db.m2_session import get_m2_engine
    from sitewise.db.session import engine as market

    with market.connect() as c:
        db, port = c.execute(text("select current_database(), inet_server_port()")).one()
        c.rollback()
    if db in FORBIDDEN_DATABASES or db != EXPECTED_DATABASE or port != EXPECTED_PORT:
        print(f"REFUSED: {db}@{port} is not {EXPECTED_DATABASE}@{EXPECTED_PORT}")
        return 2

    if not args.user:
        print("REFUSED: --user is required (m2_assessments is row-scoped by policy)")
        return 2
    user_id = UUID(args.user)
    print(f"assessment={assessment_id} user={user_id} revision={args.revision}")
    if not args.apply:
        print("read-only: pass --apply to actually record the review")
        return 0

    from sitewise.db.m2_session import m2_session_for
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sitewise.services.confirmation_service import ConfirmationService

    # Same wiring the route uses: an owner-scoped session, so the RLS policies
    # see the actor exactly as they do behind the API.
    with m2_session_for(user_id) as session:
        service = ConfirmationService(repository=SqlModelM2Repository(session))
        try:
            result = service.confirm(assessment_id, user_id,
                                           expected_revision=args.revision,
                                           acknowledged_issue_ids=[],
                                           marketplace_assessment_id=(UUID(args.marketplace) if args.marketplace else None),
                                           ai_processing=None)
            print("confirm OK:", result)
        except Exception:  # noqa: BLE001 - the traceback IS the output
            print("---- confirm FAILED ----")
            traceback.print_exc()
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
