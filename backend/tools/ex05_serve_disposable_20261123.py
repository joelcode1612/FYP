"""EX-05 disposable launcher with the explanation chain enabled.

This is the Phase 4 disposable launcher plus the EX-05 seams:

* CQ runtime and EE-01 explanation endpoints are switched on.
* Every database setting -- the main application engine included -- is
  repointed at the disposable cluster *before* ``sitewise.main`` is imported,
  because ``sitewise.db.session`` builds its engine at module import time.
  A standalone launch therefore cannot fall back to a protected database.
* The backend's EE-01 service is patched to use the same disposable PostgreSQL
  engine, because the production ``Dss`` identity is not available in this
  disposable environment.
* The pooled EE-01 connections assume the restricted ``p1_ee01_runtime``
  role. The role exists in this cluster with exactly the attributes
  ``Ee01Service.connection()`` demands (no superuser, no bypassrls) and the
  CQ/EE-01 SELECT grants, but it is NOLOGIN: a session can only assume it via
  SET ROLE. This reproduces the production restricted identity without
  inventing a login for it.
* The explanation store and readback are pointed at the same disposable
  database, so the browser E2E can exercise the full chain without touching
  protected data.

The app itself is unchanged; the only differences are configuration and the
test-only overrides below. The frontend is the real compiled Jaspr bundle.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
sys.path.insert(0, str(BACKEND / "src"))
sys.path.insert(0, str(BACKEND))

TARGET_DB = "project1_workflow_tests"
TARGET_PORT = 5433
EE01_ROLE = "p1_ee01_runtime"


def _password() -> str:
    text = (BACKEND / ".env").read_text(encoding="utf-8", errors="replace")
    match = re.search(r"^DATABASE_URL=(.*)$", text, re.M)
    if not match:
        raise SystemExit("DATABASE_URL not found in backend/.env")
    cred = re.match(r"^[^:]+://[^:]+:([^@]+)@", match.group(1).strip())
    if not cred:
        raise SystemExit("DATABASE_URL has no inline password")
    return cred.group(1)


def _disposable_url() -> str:
    return (
        f"postgresql+psycopg2://postgres:{_password()}"
        f"@127.0.0.1:{TARGET_PORT}/{TARGET_DB}"
    )


def _verify(url: str) -> None:
    from sqlalchemy import create_engine, text

    engine = create_engine(url)
    try:
        with engine.connect() as conn:
            db, port = conn.execute(
                text("SELECT current_database(), inet_server_port()")
            ).one()
    finally:
        engine.dispose()
    if db != TARGET_DB or int(port) != TARGET_PORT:
        raise SystemExit(f"REFUSED: target resolves to {db}@{port}")


def _patch_all_db_settings(url: str) -> None:
    """Point every database setting at the disposable cluster.

    Must run before ``sitewise.main`` is imported: the application engine in
    ``sitewise.db.session`` is created from ``settings.database_url`` at
    module import time, so a patch made after that import would be too late.
    """
    from sitewise.core.config import settings
    from pydantic import SecretStr

    if not isinstance(SecretStr, type):  # pragma: no cover - defensive
        raise SystemExit("pydantic SecretStr unavailable")

    settings.database_url = url
    settings.analytics_database_url = url
    settings.m2_database_url = SecretStr(url)
    settings.m2_expected_database = TARGET_DB
    settings.ee01_database_url = SecretStr(url)
    settings.ee01_expected_database = TARGET_DB
    settings.explanation_store_database_url = SecretStr(url)
    settings.explanation_store_expected_database = TARGET_DB
    settings.explanation_store_expected_port = TARGET_PORT
    settings.project1_runtime_database_url = SecretStr(url)
    settings.project1_audit_database_url = SecretStr(url)
    settings.project1_cp07_uc_database_url = SecretStr(url)

    settings.cq_runtime_enabled = True
    settings.ee01_explanation_enabled = True
    settings.m2_upstream_enabled = True
    settings.project1_workflow_enabled = True
    settings.project1_isolated_database_name = TARGET_DB
    settings.project1_isolated_database_port = TARGET_PORT


def _restricted_ee01_engine(url: str):
    """Engine whose pooled sessions assume the restricted EE-01 runtime role.

    ``Ee01Service.connection()`` requires ``current_user`` to be
    ``p1_ee01_runtime`` with no superuser and no bypassrls. The role is
    NOLOGIN in this cluster, so the session assumes it right after connect;
    ``current_user`` then reports the assumed role for the life of the
    pooled connection. Production code is not modified.
    """
    from sqlalchemy import create_engine, event

    engine = create_engine(url, hide_parameters=True, pool_pre_ping=True)

    @event.listens_for(engine, "connect")
    def _assume_restricted_role(dbapi_connection, _connection_record):
        cursor = dbapi_connection.cursor()
        try:
            cursor.execute(f"SET ROLE {EE01_ROLE}")
        finally:
            cursor.close()

    return engine


def build_app() -> object:
    import jwt  # noqa: F401  (needed by the JWK helper)

    url = _disposable_url()
    _verify(url)
    # Settings first, imports second: the application engine reads
    # settings.database_url at import time.
    _patch_all_db_settings(url)

    from sitewise.core.security import JWKSClient
    from sitewise.core.supabase_admin import get_admin_service
    from sitewise.main import app
    from tests.fakes import FakeSupabaseAdmin

    key_path = BACKEND / "var" / "test-auth" / "es256-test.pem"
    from cryptography.hazmat.primitives import serialization

    private_key = serialization.load_pem_private_key(
        key_path.read_bytes(), password=None
    )
    jwk = jwt.algorithms.ECAlgorithm.to_jwk(private_key.public_key(), as_dict=True)
    jwk.update({"kid": "sitewise-disposable-test-key", "alg": "ES256", "use": "sig"})

    def offline_fetch(self):
        self._keys = {"sitewise-disposable-test-key": dict(jwk)}
        self._fetched_at = time.monotonic()
        return self._keys

    JWKSClient._fetch = offline_fetch

    from sitewise.api.v1 import customer_questionnaire
    from sitewise.services.ee01_service import Ee01Service

    engine = _restricted_ee01_engine(url)

    def disposable_ee01_service():
        return Ee01Service(engine)

    # Route dependency and direct imports both need the patched seam.
    app.dependency_overrides[customer_questionnaire.get_ee01_service] = (
        disposable_ee01_service
    )
    customer_questionnaire.get_ee01_service = disposable_ee01_service

    app.dependency_overrides[get_admin_service] = lambda: FakeSupabaseAdmin()
    return app


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8091)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    app = build_app()
    import uvicorn

    print(
        json.dumps(
            {
                "serving": f"http://{args.host}:{args.port}",
                "database": f"{TARGET_DB}@{TARGET_PORT}",
                "explanation_enabled": True,
                "cq_runtime_enabled": True,
                "ee01_role": EE01_ROLE,
            },
            indent=1,
        ),
        flush=True,
    )
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
