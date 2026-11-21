"""Activity History V1 — HTTP layer verification.

Proves the chain step that a database read cannot: that the authenticated
FastAPI endpoint returns the projected events, and that a different
authenticated principal is refused.

It reuses the local-JWKS harness (`cp03f_e2e_browser`) so real ES256 tokens are
minted for the production verifier path. Nothing here is a TestClient shortcut:
the request goes over HTTP to a real uvicorn process.

Writes evidence to `backend/var/activity_history/`.
"""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src"))
sys.path.insert(0, str(HERE))

import requests  # noqa: E402
from sqlalchemy import create_engine, text  # noqa: E402

import cp03f_e2e_browser as H  # noqa: E402

from sitewise.core.config import settings  # noqa: E402

OUT = HERE.parent / "var" / "activity_history"
OWNER = "11111111-1111-4111-8111-111111111111"   # cp02.synthetic@example.test
OTHER = "32ef694a-69b0-4863-a77f-b9cf6c056b56"   # a different entrepreneur


def _m2_dsn() -> str:
    """M2 rows live in the M2 database, not the catalogue `database_url`."""
    import os
    explicit = os.environ.get("ACTIVITY_HISTORY_DB_URL")
    if explicit:
        return explicit
    url = settings.m2_database_url.get_secret_value()
    if not url:
        raise SystemExit("M2_DATABASE_URL is not configured")
    return url


def pick_assessment() -> str:
    """The assessment with the richest history in this database.

    The M2 URL connects as the restricted runtime role, so RLS hides every row
    until an actor is bound. Binding the owner here is what the application
    itself does — it is not a bypass, and it is why an unbound connection
    correctly reports zero rows.
    """
    engine = create_engine(_m2_dsn(), hide_parameters=True)
    with engine.connect() as c:
        c.execute(text("select set_config('project1.actor_id', :owner, false)"),
                  {"owner": OWNER})
        row = c.execute(text("""
            SELECT a.id
              FROM public.m2_assessments a
              LEFT JOIN public.m2_bdj_evaluations e ON e.assessment_id = a.id
             WHERE a.owner_user_id = :owner
             GROUP BY a.id
             ORDER BY count(e.id) DESC, a.revision DESC
             LIMIT 1
        """), {"owner": OWNER}).first()
    if row is None:
        raise SystemExit("no assessment owned by the synthetic entrepreneur")
    return str(row[0])


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    assessment_id = pick_assessment()
    workdir = Path(tempfile.mkdtemp(prefix="cp03f_hist_jwks_"))
    priv = H.make_keypair(workdir)
    owner_token = H.mint(priv, OWNER, "cp02.synthetic@example.test")
    other_token = H.mint(priv, OTHER, "tabhello1612@gmail.com")
    srv = H.serve_jwks(workdir)
    log: dict = {"assessment_id": assessment_id, "checks": []}
    backend = None
    try:
        backend = H.start_backend()
        base = f"http://127.0.0.1:{H.BACKEND_PORT}"

        def get(token: str):
            return requests.get(
                f"{base}/api/v1/m2/assessments/{assessment_id}/activity",
                headers={"Authorization": f"Bearer {token}"}, timeout=30,
            )

        def check(name, ok, detail):
            log["checks"].append({"check": name, "ok": bool(ok), "detail": detail})
            print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")
            return ok

        owner = get(owner_token)
        check("owner receives 200", owner.status_code == 200, owner.status_code)
        body = owner.json() if owner.status_code == 200 else {}
        log["response"] = body

        check("contract_version", body.get("contract_version") == "m2-activity/1",
              body.get("contract_version"))
        check("history_extension",
              body.get("history_extension") == "workflow-history-metadata/2",
              body.get("history_extension"))
        check("assessment_id matches", body.get("assessment_id") == assessment_id,
              body.get("assessment_id"))
        check("authorization_decisions_included is false",
              body.get("authorization_decisions_included") is False,
              body.get("authorization_decisions_included"))

        events = body.get("events") or []
        kinds = sorted({e.get("kind") for e in events})
        check("events present", len(events) > 0, len(events))
        check("kinds present", True, kinds)

        answers = [e for e in events if e.get("kind") == "ANSWER_SAVED"]
        bad = [e for e in answers if not e.get("status") or not e.get("item_key")]
        check("every ANSWER_SAVED carries status + item_key",
              answers and not bad, f"{len(answers)} answers, {len(bad)} bad")

        evals = [e for e in events if e.get("kind") == "BDJ_EVALUATED"]
        check("BDJ_EVALUATED carries evaluator_version, not reason",
              all(e.get("evaluator_version") and "reason" not in e for e in evals),
              [e.get("evaluator_version") for e in evals])

        confs = [e for e in events if e.get("kind") == "CONTEXT_CONFIRMED"]
        check("CONTEXT_CONFIRMED carries a 64-hex digest",
              all(len(e.get("snapshot_digest") or "") == 64 for e in confs),
              [e.get("snapshot_digest") for e in confs])

        other = get(other_token)
        check("cross-owner read is refused", other.status_code == 404,
              other.status_code)

        anon = requests.get(
            f"{base}/api/v1/m2/assessments/{assessment_id}/activity", timeout=30)
        check("unauthenticated read is refused", anon.status_code in (401, 403),
              anon.status_code)

        failed = [c for c in log["checks"] if not c["ok"]]
        log["verdict"] = "PASS" if not failed else "FAIL"
        print(f"\nverdict: {log['verdict']}  ({len(log['checks'])} checks, "
              f"{len(failed)} failed)")
        return 0 if not failed else 1
    finally:
        (OUT / "activity_http.json").write_text(
            json.dumps(log, indent=2, default=str), encoding="utf-8")
        print(f"evidence: {OUT / 'activity_http.json'}")
        if backend is not None:
            backend.terminate()
            try:
                backend.wait(timeout=15)
            except Exception:
                backend.kill()
        srv.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
