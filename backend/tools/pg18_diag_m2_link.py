"""Reproduce the 503 on the assessment-link read, with the real exception.

The endpoints swallow ``SQLAlchemyError`` into a 503, so the SQL error never
reaches the log. This script drives the same service with the same engines the
application builds, so the underlying error surfaces with a traceback.

Read-only intent: ``create_if_missing=False``, so nothing is created. Any
session opened here is rolled back.
"""

from __future__ import annotations

import os
import sys
import traceback
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ENV_FILE = BACKEND / "var" / "e2e" / "pg18" / "app_pg18.env"

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
    load_env()
    drop_unreachable_proxies()

    from sqlalchemy import text

    from sitewise.db.m2_session import get_m2_engine
    from sitewise.db.session import engine as market
    from sitewise.services.assessment_link_service import AssessmentLinkService

    m2 = get_m2_engine()

    with market.connect() as c:
        db, port = c.execute(text(
            "select current_database(), inet_server_port()"
        )).one()
        print(f"marketplace engine -> {db}@{port}")
        row = c.execute(text(
            "select a.assessment_id, a.user_id, u.email "
            "from public.assessment a join public.users u on u.user_id = a.user_id "
            "order by a.created_at desc limit 1"
        )).first()
        c.rollback()
    if row is None:
        print("no assessment row found")
        return 1
    aid, uid, email = row
    print(f"assessment={aid} user={uid} email={email}")

    with m2.connect() as c:
        db2, port2 = c.execute(text(
            "select current_database(), inet_server_port()"
        )).one()
        print(f"m2 engine        -> {db2}@{port2}")
        c.rollback()

    svc = AssessmentLinkService(marketplace_engine=market, m2_engine=m2)
    try:
        result = svc.resolve(
            marketplace_assessment_id=aid,
            user_id=uid,
            verified_email=email,
            create_if_missing=False,
        )
        print("resolve OK:", result.as_dict())
    except Exception:  # noqa: BLE001 - the traceback IS the output
        print("---- resolve FAILED ----")
        traceback.print_exc()

    # Probe the exact relations the link service and readiness read.
    for rel in (
        "public.m2_assessment_links",
        "public.m2_assessments",
        "public.m2_instrument_versions",
        "public.m2_confirmation_snapshots",
        "public.cp12.operations",
    ):
        try:
            with market.connect() as c:
                c.execute(text(f"select 1 from {rel} limit 1"))
                c.rollback()
            print(f"  OK    {rel} (marketplace role)")
        except Exception as exc:  # noqa: BLE001
            print(f"  FAIL  {rel} (marketplace role): {type(exc).__name__}: {str(exc).splitlines()[0][:120]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
