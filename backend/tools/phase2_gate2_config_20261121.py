"""Gate 2 — disposable configuration and confirmation-validity semantics.

Environment is installed BEFORE any `sitewise` import, because `settings` is a
module-level singleton: an override applied afterwards would not take effect.

No `.env` is modified. No password is printed.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase2_gate2_config_20261121.py
"""
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

TARGET_DB = "project1_workflow_tests"
PORT = 5433
BACKEND = Path(__file__).resolve().parents[1]
ROLE = "p1_m2_runtime"
ROLE_PW = "m2_runtime_dev_only"


def libpq(dsn: str) -> str:
    return dsn.replace("postgresql+psycopg2://", "postgresql://")


def env_database_url():
    for line in (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("DATABASE_URL="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("DATABASE_URL missing")


def install_overrides():
    """Process-scoped only: set before importing sitewise.core.config."""
    app = env_database_url().replace(":5432", f":{PORT}")
    app = app.rsplit("/", 1)[0] + "/" + TARGET_DB
    # restricted principal for the BCB store, same database, same cluster
    host = app.split("://", 1)[1].split("@", 1)[1]
    scheme = app.split("://", 1)[0]
    m2 = f"{scheme}://{ROLE}:{ROLE_PW}@{host}"
    os.environ["DATABASE_URL"] = app
    os.environ["M2_DATABASE_URL"] = m2
    os.environ["PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS"] = "1"
    return app, m2


def main():
    app_url, m2_url = install_overrides()

    from sitewise.core.config import settings
    from sitewise.repositories.m2_context_bindings import confirmation_horizon
    from sitewise.services.business_context_v1 import ContextRefused

    checks = []

    def check(label, fn):
        try:
            checks.append({"check": label, "result": "PASS", "detail": str(fn())})
        except Exception as exc:
            checks.append({"check": label, "result": "FAIL",
                           "detail": f"{type(exc).__name__}: {str(exc)[:150]}"})
        print("  %-4s %-46s %s" % (checks[-1]["result"], label, str(checks[-1]["detail"])[:62]))

    print("=" * 78)
    print("GATE 2 — disposable configuration")
    print("=" * 78)
    print("validity setting:", settings.project1_bcb_confirmation_validity_days, "(days)")

    def settings_applied():
        if str(settings.project1_bcb_confirmation_validity_days) != "1":
            raise AssertionError("validity override not applied to settings")
        db = settings.m2_database_url.get_secret_value()
        if TARGET_DB not in db or f":{PORT}" not in db:
            raise AssertionError("M2_DATABASE_URL does not target the disposable DB")
        if ROLE not in db:
            raise AssertionError("M2_DATABASE_URL does not use the restricted principal")
        return "validity=1, M2_DATABASE_URL→restricted principal on disposable DB"

    def app_connection():
        import psycopg2
        c = psycopg2.connect(libpq(app_url))
        c.autocommit = True
        with c.cursor() as cur:
            cur.execute("select current_database(), inet_server_port(), current_user, session_user")
            db, port, cu, su = cur.fetchone()
        c.close()
        if db != TARGET_DB or port != PORT:
            raise AssertionError(f"{db}@{port}")
        return f"{db}@{port} user={cu}/{su}"

    def m2_connection():
        import psycopg2
        c = psycopg2.connect(libpq(m2_url))
        c.autocommit = True
        with c.cursor() as cur:
            cur.execute("select current_database(), inet_server_port(), current_user, session_user")
            db, port, cu, su = cur.fetchone()
        c.close()
        if db != TARGET_DB or port != PORT or cu != ROLE:
            raise AssertionError(f"{db}@{port} as {cu}")
        return f"{db}@{port} user={cu}/{su}"

    def no_dss_writes():
        import psycopg2
        for label, dsn in (("app", app_url), ("m2", m2_url)):
            c = psycopg2.connect(libpq(dsn))
            c.autocommit = True
            with c.cursor() as cur:
                cur.execute("select current_database(), inet_server_port()")
                db, port = cur.fetchone()
            c.close()
            if (db, port) != (TARGET_DB, PORT):
                raise AssertionError(f"{label} connection points at {db}@{port}")
        return "both write-capable connections verified as disposable"

    def horizon_one_day():
        created = datetime(2026, 11, 21, 12, 0, tzinfo=timezone.utc)
        h = confirmation_horizon({"created_at": created}, timedelta(days=1))
        if h != "2026-11-22T12:00:00+00:00":
            raise AssertionError(h)
        return "created_at + 24h (rolling window, UTC)"

    def missing_basis():
        try:
            confirmation_horizon({"created_at": datetime.now(timezone.utc)}, None)
        except ContextRefused as exc:
            if str(exc) != "VALIDITY_BASIS_UNAUTHORIZED":
                raise
            return "refused: VALIDITY_BASIS_UNAUTHORIZED"
        raise AssertionError("unset validity was accepted")

    def nonpositive_basis():
        for bad in (timedelta(0), timedelta(seconds=-5)):
            try:
                confirmation_horizon({"created_at": datetime.now(timezone.utc)}, bad)
            except ContextRefused as exc:
                if str(exc) != "VALIDITY_BASIS_UNAUTHORIZED":
                    raise
            else:
                raise AssertionError(f"accepted {bad}")
        return "zero and negative refused"

    def expired_horizon():
        created = datetime.now(timezone.utc) - timedelta(days=2)
        h = confirmation_horizon({"created_at": created}, timedelta(days=1))
        if datetime.fromisoformat(h) > datetime.now(timezone.utc):
            raise AssertionError(f"horizon still future: {h}")
        return "horizon in the past for a 2-day-old confirmation"

    check("1. overrides applied before settings init", settings_applied)
    check("2. app connection identity", app_connection)
    check("3. restricted M2 connection identity", m2_connection)
    check("4. no write connection points at Dss", no_dss_writes)
    check("5. validity=1 → 24h rolling horizon", horizon_one_day)
    check("6. missing validity refused", missing_basis)
    check("7. zero/negative validity refused", nonpositive_basis)
    check("8. expired confirmation horizon", expired_horizon)

    passed = sum(1 for c in checks if c["result"] == "PASS")
    evidence = {"gate": 2, "target": f"{TARGET_DB}@{PORT}",
                "config": {"PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS": "1",
                           "DATABASE_URL": f"{TARGET_DB}@{PORT} (app role)",
                           "M2_DATABASE_URL": f"{TARGET_DB}@{PORT} as {ROLE}",
                           "env_file_modified": False},
                "semantics": {"unit": "timedelta(days=1)",
                              "basis": "confirmation.created_at + validity (UTC)",
                              "window": "rolling 24h, not a calendar day",
                              "unset_or_nonpositive": "VALIDITY_BASIS_UNAUTHORIZED"},
                "checks": checks, "passed": passed, "total": len(checks),
                "not_covered": ["resolver end-to-end accept/refuse against a real repo",
                                "cross-owner refusal at resolver level"],
                "verdict": "PASS" if passed == len(checks) else "FAIL"}
    out = BACKEND.parent / "deliverables/phase2/BDJ_GATE2_CONFIG_20261121.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\n  %d/%d checks passed" % (passed, len(checks)))
    print("  evidence:", out)
    print("  VERDICT:", evidence["verdict"])
    return 0 if evidence["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
