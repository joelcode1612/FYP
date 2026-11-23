"""Shared test fixtures.

Strategy
--------
* Supabase is NOT contacted: a real ES256 keypair is generated with
  ``cryptography`` and the JWKS client's ``_fetch`` is monkeypatched to serve
  the public key. This exercises the full verification path (signature,
  alg allow-list, iss, aud, exp, kid handling) without network access.
* The application database is a DISPOSABLE local Postgres on port 5433
  (``project1_workflow_tests`` or ``project1_disposable_app``). The
  ``require_disposable_database`` fixture refuses to start the suite against
  anything else, because these tests write rows and previously ran against the
  protected ``Final_Location_Analysis`` database by accident.
* Tests that write rows clean up after themselves via the ``cleanup_users``
  fixture; subprocess outputs are redirected to a temporary directory via
  ``SITEWISE_ML_EVAL_DIR`` so tracked reference artifacts are never rewritten.
"""

from __future__ import annotations

import os
import uuid
import warnings
from datetime import datetime, timedelta, timezone

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from sitewise.core.security import JWKSClient
from sitewise.main import app


TEST_KID = "test-es256-key"
TEST_ISSUER = "https://lzdpjwmcjbhtkzkqudyt.supabase.co/auth/v1"
TEST_AUDIENCE = "authenticated"
TEST_EMAIL_DOMAIN = "jwks-test.example"

#: Port of the disposable Postgres cluster. The protected clusters listen on
#: 5432 (``Final_Location_Analysis`` and ``Dss``) and must never receive test
#: writes.
DISPOSABLE_PORT = 5433
DISPOSABLE_DATABASES = frozenset({"project1_workflow_tests", "project1_disposable_app"})
NEVER_TEST_DATABASES = frozenset(
    {"Final_Location_Analysis", "Dss", "dss", "sitesense", "postgres"}
)
ISOLATION_OVERRIDE_ENV = "SITEWISE_TEST_ISOLATION"

_private_key = ec.generate_private_key(ec.SECP256R1())
_pub_coords = jwt.algorithms.ECAlgorithm.to_jwk(_private_key.public_key(), as_dict=True)
_public_jwk = {
    "kid": TEST_KID,
    "kty": "EC",
    "alg": "ES256",
    "use": "sig",
    "crv": "P-256",
    "x": _pub_coords["x"],
    "y": _pub_coords["y"],
}


@pytest.fixture(autouse=True)
def fake_jwks(monkeypatch):
    """Serve the generated public key instead of contacting Supabase."""

    def _fake_fetch(self: JWKSClient):
        self._keys = {TEST_KID: dict(_public_jwk)}
        self._fetched_at = __import__("time").monotonic()
        return self._keys

    monkeypatch.setattr(JWKSClient, "_fetch", _fake_fetch)
    # Reset the cached verifier so every test builds it fresh.
    import sitewise.dependencies as deps

    monkeypatch.setattr(deps, "_verifier", None)
    yield


@pytest.fixture(autouse=True)
def fake_supabase_admin_identity():
    """Keep request-time identity reconciliation hermetic.

    Production uses the real Supabase service and treats the ``public.users``
    row as authoritative. Tests use an in-memory fake; ``strict_identity`` is
    false so token-only fixtures can still provision local profiles exactly
    as before. Individual tests may override this dependency.
    """
    from sitewise.core.supabase_admin import get_admin_service
    from tests.fakes import FakeSupabaseAdmin

    fake = FakeSupabaseAdmin()
    previous = app.dependency_overrides.get(get_admin_service)
    app.dependency_overrides[get_admin_service] = lambda: fake
    yield fake
    if previous is None:
        app.dependency_overrides.pop(get_admin_service, None)
    else:
        app.dependency_overrides[get_admin_service] = previous


@pytest.fixture(scope="session", autouse=True)
def require_disposable_database(tmp_path_factory):
    """Refuse to run this suite against a protected database.

    The suite writes rows (users, preference snapshots, recommendation batches)
    and shells out to ``scripts/ml/train_personalised_recommender.py``, which
    overwrites a report file. Both must be confined to a disposable database and
    a temporary directory.

    The database identity is asked of the SERVER (``current_database()`` and
    ``inet_server_port()``), not parsed out of ``DATABASE_URL``, so a pooled or
    redirected connection cannot satisfy the check by accident.

    Escape hatch: ``SITEWISE_TEST_ISOLATION=off`` downgrades the failure to a
    warning. It exists only for a developer who consciously wants a read-only
    smoke run; it is never used by CI or by the recorded evidence.
    """
    from sqlalchemy import text

    from sitewise.db.session import engine

    override = os.environ.get(ISOLATION_OVERRIDE_ENV, "").strip().lower()
    with engine.connect() as conn:
        db, port = conn.execute(
            text("SELECT current_database(), inet_server_port()")
        ).one()
    identity = f"{db}@{port}"

    problems = []
    if db in NEVER_TEST_DATABASES:
        problems.append(f"{db!r} is a protected database")
    if db not in DISPOSABLE_DATABASES:
        problems.append(f"{db!r} is not a recognised disposable database")
    if int(port) != DISPOSABLE_PORT:
        problems.append(f"port {port} is not the disposable cluster port {DISPOSABLE_PORT}")

    if problems:
        message = (
            "TEST ISOLATION REFUSED: "
            + "; ".join(problems)
            + f" (connected to {identity}). Point DATABASE_URL at one of "
            + ", ".join(sorted(DISPOSABLE_DATABASES))
            + f" on 127.0.0.1:{DISPOSABLE_PORT}, or set "
            + f"{ISOLATION_OVERRIDE_ENV}=off to acknowledge the risk explicitly."
        )
        if override == "off":
            warnings.warn(message + " -- OVERRIDDEN, data will be written here.", stacklevel=1)
        else:
            # 97 is outside pytest's own 0-5 range so "isolation refused" can
            # never be mistaken for "internal error" in CI.
            pytest.exit(message, returncode=97)

    # Keep the trainer's report out of the tracked reference directory.
    os.environ.setdefault(
        "SITEWISE_ML_EVAL_DIR", str(tmp_path_factory.mktemp("ml_reference_eval"))
    )
    return identity


@pytest.fixture(scope="session", autouse=True)
def _shap_process_warm():
    """Tests exercise a BOOTED server: in production the lifespan warm-up
    thread completes the one-off SHAP compilation seconds after start, after
    which explanation paths compute synchronously on a cache miss. Mark the
    test process warm up-front so that contract stays deterministic here (the
    cold-process "pending" behaviour has its own focused tests)."""
    from sitewise.ml import shap_explainer

    shap_explainer.mark_warm()
    yield


@pytest.fixture()
def client():
    with TestClient(app) as test_client:
        yield test_client


def make_token(
    *,
    sub: str | None = None,
    email: str = "user@jwks-test.example",
    role_claims: dict | None = None,
    algorithm: str = "ES256",
    issuer: str = TEST_ISSUER,
    audience: str | list[str] | None = TEST_AUDIENCE,
    expires_in: int = 600,
    issued_at: datetime | None = None,
    not_before: datetime | None = None,
    omit: tuple[str, ...] = (),
    key=None,
    headers: dict | None = None,
    aal: str | None = None,
    amr: list | None = None,
) -> str:
    """Craft a token exactly like Supabase would (or unlike it, for negatives).

    ``aal`` mirrors Supabase's authentication-assurance claim (``aal1`` =
    password only, ``aal2`` = password + verified MFA factor). Omitted for
    entrepreneur flows; staff flows pass it explicitly.
    """
    now = issued_at or datetime.now(timezone.utc)
    payload = {
        "sub": sub or str(uuid.uuid4()),
        "email": email,
        "email_verified": True,
        "phone": "",
        "aud": audience,
        "iss": issuer,
        "role": "authenticated",
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(seconds=expires_in)).timestamp()),
        "session_id": str(uuid.uuid4()),
        "app_metadata": {"provider": "email", "providers": ["email"]},
        "user_metadata": role_claims or {"full_name": "Test User"},
    }
    if aal:
        payload["aal"] = aal
    if amr is not None:
        payload["amr"] = amr
    for field in omit:
        payload.pop(field, None)
    if not_before:
        payload["nbf"] = int(not_before.timestamp())
    signing_key = key or _private_key
    token_headers = {"kid": TEST_KID}
    if headers:
        token_headers.update(headers)
    return jwt.encode(payload, signing_key, algorithm=algorithm, headers=token_headers)


@pytest.fixture()
def cleanup_users(client):
    """Delete every test-created user row after the test finishes."""
    created: list[uuid.UUID] = []
    yield created

    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.repositories.user_repository import UserRepository

    with Session(engine) as session:
        repo = UserRepository(session)
        for user_id in created:
            repo.delete(user_id)


def register_user_id(tracker: list, user_id: uuid.UUID) -> uuid.UUID:
    tracker.append(user_id)
    return user_id
