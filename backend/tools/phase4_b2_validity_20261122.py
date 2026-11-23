"""Phase B2 — confirmation validity, all four cases.

Cases, each against real production code:

  1. current valid confirmation          -> horizon in the future, gate passes
  2. expired confirmation                -> gate refuses before content is read
  3. missing validity configuration      -> VALIDITY_BASIS_UNAUTHORIZED
  4. stale M2 revision                   -> covered live in phase4_b1 (409)

Expiry is exercised by driving the service clock forward, not by ageing a real
confirmation. Rewriting `created_at` on an audit row would manufacture the very
evidence under test.

The validity value in this environment is `PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS=30`,
authorised for synthetic testing only. It is not a product policy.
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg2

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
OUT = REPO / "deliverables" / "phase4" / "b2_validity.json"

sys.path.insert(0, str(BACKEND / "src"))

from sitewise.repositories.m2_context_bindings import confirmation_horizon  # noqa: E402
from sitewise.services.business_context_v1 import (  # noqa: E402
    ContextRefused, BusinessContextBuilderV1,
)

ACTOR = "b9e62014-b7bc-426e-a950-a95b25965639"
CONFIRMATION = "00ea0ece-cdca-48f6-9c4c-53c47cedc329"
VALIDITY_DAYS = 30


def dsn() -> str:
    text = (BACKEND / "var" / "e2e" / "app.env").read_text(encoding="utf-8", errors="replace")
    url = re.search(r"^M2_DATABASE_URL=(.+)$", text, re.M).group(1).strip()
    return url.replace("postgresql+psycopg2", "postgresql")


class FixedClock:
    def __init__(self, moment: datetime) -> None:
        self._moment = moment

    def now(self) -> datetime:
        return self._moment


def main() -> int:
    out: dict = {"checks": [], "validity_days": VALIDITY_DAYS,
                 "note": "30 days is a synthetic test value, not a product policy"}

    def record(name, ok, detail):
        out["checks"].append({"check": name, "pass": bool(ok), "detail": detail})

    # --- the real confirmation row ----------------------------------------
    with psycopg2.connect(dsn()) as conn:
        conn.autocommit = False
        cur = conn.cursor()
        cur.execute("select set_config('project1.actor_id', %s, true)", (ACTOR,))
        cur.execute(
            "select id::text, assessment_id::text, assessment_revision, created_at, actor_user_id::text "
            "from public.m2_confirmation_snapshots where id = %s", (CONFIRMATION,))
        row = cur.fetchone()
        conn.rollback()
    if row is None:
        out["error"] = "confirmation not visible to its owner"
        OUT.write_text(json.dumps(out, indent=2), encoding="utf-8")
        return 1

    confirmation = {"id": row[0], "assessment_id": row[1], "assessment_revision": row[2],
                    "created_at": row[3], "actor_user_id": row[4]}
    out["confirmation"] = {k: (v.isoformat() if isinstance(v, datetime) else v)
                           for k, v in confirmation.items()}

    validity = timedelta(days=VALIDITY_DAYS)

    # --- 1. valid ----------------------------------------------------------
    try:
        horizon = confirmation_horizon(confirmation, validity)
        expired_at = datetime.fromisoformat(horizon)
        now = datetime.now(timezone.utc)
        ok = expired_at > now
    except ContextRefused as exc:
        horizon, ok, expired_at = None, False, None
        out["valid_error"] = exc.code
    record("current confirmation -> horizon in the future",
           ok, {"valid_until": horizon, "now": now.isoformat()})

    # --- 1b. the real gate accepts it (positive control) -------------------
    live = BusinessContextBuilderV1(authorization=None, snapshots=None)
    try:
        live._fresh(horizon, "ACCESS_DENIED")
        gate_ok = True
        gate_detail = {"raised": None}
    except ContextRefused as exc:
        gate_ok = False
        gate_detail = {"raised": exc.code}
    record("freshness gate passes for the current confirmation", gate_ok, gate_detail)

    # --- 2. expired --------------------------------------------------------
    # Drive the real gate with a clock one day past the horizon.
    later = BusinessContextBuilderV1(authorization=None, snapshots=None,
                                     clock=FixedClock(expired_at + timedelta(days=1)))
    try:
        later._fresh(horizon, "ACCESS_DENIED")
        expired_ok, detail = False, {"raised": None}
    except ContextRefused as exc:
        expired_ok, detail = exc.code == "ACCESS_DENIED", {"raised": exc.code}
    record("expired confirmation -> refused with ACCESS_DENIED", expired_ok, detail)

    # --- 2b. expiry is checked before content is opened --------------------
    class RecordingSnapshots:
        opened = False

        def open_read(self, request, decision):
            RecordingSnapshots.opened = True
            raise AssertionError("content opened for an expired confirmation")

    class AllowingAuth:
        def __init__(self, decision):
            self._decision = decision

        def authorize(self, request):
            return self._decision

    # A decision that satisfies every scope check except freshness, so the only
    # thing that can stop it is the expiry rule.
    from uuid import UUID
    request_stub = {
        "viewer_id": UUID(ACTOR), "tenant_id": f"m2-owner:{ACTOR}",
        "assessment_id": UUID(confirmation["assessment_id"]), "purpose": "EXPLANATION",
        "role": "entrepreneur", "confirmation_id": UUID(CONFIRMATION),
        "confirmed_revision": confirmation["assessment_revision"],
        "concept_version": "M2-CONFIRMED-%d" % confirmation["assessment_revision"],
    }
    scope = {k: (str(v) if isinstance(v, UUID) else v) for k, v in request_stub.items()}
    decision = {
        "allowed": True, "scope": scope, "owner_id": ACTOR,
        "decision_id": "b2-expiry-probe", "policy_version": "b2-probe/1",
        "valid_until": horizon,
    }

    class Stub:
        viewer_id = request_stub["viewer_id"]
        tenant_id = request_stub["tenant_id"]
        assessment_id = request_stub["assessment_id"]
        purpose = request_stub["purpose"]
        role = request_stub["role"]
        confirmation_id = request_stub["confirmation_id"]
        confirmed_revision = request_stub["confirmed_revision"]
        concept_version = request_stub["concept_version"]

    guarded = BusinessContextBuilderV1(authorization=AllowingAuth(decision),
                                       snapshots=RecordingSnapshots(),
                                       clock=FixedClock(expired_at + timedelta(days=1)))
    try:
        guarded.get_context(Stub())
        blocked_ok, blocked_detail = False, {"raised": None}
    except ContextRefused as exc:
        blocked_ok = exc.code == "ACCESS_DENIED"
        blocked_detail = {"raised": exc.code}
    except Exception as exc:  # noqa: BLE001 - any other error is a finding
        blocked_ok, blocked_detail = False, {"raised": type(exc).__name__, "message": str(exc)[:200]}
    blocked_detail["content_opened"] = RecordingSnapshots.opened
    record("expiry is enforced before content is opened",
           blocked_ok and not RecordingSnapshots.opened, blocked_detail)

    # --- 3. missing / non-positive configuration ---------------------------
    for label, value in (("absent (None)", None), ("zero", timedelta(0)),
                         ("negative", timedelta(days=-1))):
        try:
            confirmation_horizon(confirmation, value)
            res, detail = False, {"raised": None}
        except ContextRefused as exc:
            res, detail = exc.code == "VALIDITY_BASIS_UNAUTHORIZED", {"raised": exc.code}
        record(f"validity {label} -> VALIDITY_BASIS_UNAUTHORIZED", res, detail)

    # --- 4. stale revision -------------------------------------------------
    # `confirmation_horizon` is revision-agnostic; staleness is refused upstream
    # in the resolver, and was exercised live in phase4_b1 (409). Recorded here
    # so the four-case matrix is complete in one artifact.
    b1 = REPO / "deliverables" / "phase4" / "b1_bcb_construction.json"
    stale_live = None
    if b1.exists():
        for c in json.loads(b1.read_text(encoding="utf-8"))["checks"]:
            if c["check"] == "stale expected_revision -> refused":
                stale_live = c
    record("stale M2 revision -> refused (live, from B1)",
           bool(stale_live and stale_live["pass"]), stale_live)

    out["passed"] = sum(1 for c in out["checks"] if c["pass"])
    out["total"] = len(out["checks"])
    out["verdict"] = "PASS" if out["passed"] == out["total"] else "FAIL"
    OUT.write_text(json.dumps(out, indent=2, default=str), encoding="utf-8")
    print(json.dumps(out, indent=2, default=str))
    return 0 if out["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
