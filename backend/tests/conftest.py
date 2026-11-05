"""Shared test fixtures.

Strategy
--------
* Supabase is NOT contacted: a real ES256 keypair is generated with
  ``cryptography`` and the JWKS client's ``_fetch`` is monkeypatched to serve
  the public key. This exercises the full verification path (signature,
  alg allow-list, iss, aud, exp, kid handling) without network access.
* The application database is the real local ``sitesense`` Postgres (it is a
  development database); every test that writes rows cleans up after itself
  via the ``cleanup_users`` fixture.
"""

from __future__ import annotations

import uuid
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
