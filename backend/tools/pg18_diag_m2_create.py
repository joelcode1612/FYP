"""Reproduce the 503 on assessment-link **creation**, with the real exception.

Purpose
    Surface the underlying SQL error behind ``M2_SOURCE_UNAVAILABLE`` when
    ``POST /api/v1/m2/assessments/by-marketplace/{id}/link`` is called.

Reason
    Both link endpoints convert any ``SQLAlchemyError`` into a bare 503, so the
    traceback never reaches the server log. The only way to know which grant,
    policy or trigger refused the write is to drive the same service with the
    same engines the application builds.

Constraint
    This tool writes: it is the creation path, so a success is the outcome being
    tested. It therefore refuses any target that is not the declared isolated
    PG18 database on 5544, and it never names a different assessment than the
    one given on the command line.
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
    args = parser.parse_args()
    assessment_id = UUID(args.assessment)

    load_env()
    drop_unreachable_proxies()

    from sqlalchemy import text

    from sitewise.db.m2_session import get_m2_engine
    from sitewise.db.session import engine as market
    from sitewise.services.assessment_link_service import AssessmentLinkService

    with market.connect() as c:
        db, port = c.execute(text("select current_database(), inet_server_port()")).one()
        c.rollback()
    if db in FORBIDDEN_DATABASES or db != EXPECTED_DATABASE or port != EXPECTED_PORT:
        print(f"REFUSED: {db}@{port} is not {EXPECTED_DATABASE}@{EXPECTED_PORT}")
        return 2
    print(f"marketplace engine -> {db}@{port}")

    with market.connect() as c:
        row = c.execute(text(
            "select a.assessment_id, a.user_id, u.email "
            "from public.assessment a join public.users u on u.user_id = a.user_id "
            "where a.assessment_id = :id"
        ), {"id": str(assessment_id)}).first()
        c.rollback()
    if row is None:
        print("no such assessment row")
        return 1
    aid, uid, email = row
    print(f"assessment={aid} user={uid} email={email}")

    m2 = get_m2_engine()
    svc = AssessmentLinkService(marketplace_engine=market, m2_engine=m2)
    try:
        result = svc.resolve(
            marketplace_assessment_id=aid, user_id=uid, verified_email=email,
            create_if_missing=True)
        print("resolve OK:", result.as_dict())
    except Exception:  # noqa: BLE001 - the traceback IS the output
        print("---- resolve FAILED ----")
        traceback.print_exc()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
