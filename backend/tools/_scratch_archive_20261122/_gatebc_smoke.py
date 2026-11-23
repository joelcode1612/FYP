"""Throwaway smoke probe: auth + disposable wiring for the Gate B/C E2E.

Read-only. Establishes that a real JWT-bearing request reaches the mounted
objective-proposal routes and that every session binds to the disposable
database before any write is attempted.
"""
import os
import sys
import uuid
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
TARGET_DB = "project1_workflow_tests"
PORT = 5433
OWNER = "c70a999a-50c6-4a31-8f7a-b914d0a5c641"
ASSESSMENT = "d82b78ff-dad0-41d8-afa4-0205ad199a20"
CONTEXT = "79151dfe-c411-54d9-b03c-47b19ce44ecb"
REVISION = 11

sys.path.insert(0, str(BACKEND / "src"))


def base_url():
    from sqlalchemy.engine import make_url

    lines = (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines()
    raw = next(l.split("=", 1)[1].strip() for l in lines if l.startswith("DATABASE_URL="))
    url = make_url(raw)
    assert url.host in {"localhost", "127.0.0.1"}
    # verify_workflow_database() requires the literal loopback address, not the
    # 'localhost' alias, on a non-default port.
    return url.set(host="127.0.0.1", port=PORT, database=TARGET_DB)


def dsn(url, role=None, password=None):
    if role:
        url = url.set(username=role, password=password)
    # Keep the configured driver (postgresql+psycopg2): rewriting it to a bare
    # ``postgresql://`` lets SQLAlchemy resolve a different DBAPI that is not
    # installed in this venv.
    return url.render_as_string(hide_password=False)


base = base_url()
os.environ.update({
    "DATABASE_URL": dsn(base, "p1_m2_runtime", "m2_runtime_dev_only"),
    "M2_DATABASE_URL": dsn(base, "p1_m2_runtime", "m2_runtime_dev_only"),
    "M2_EXPECTED_DATABASE": TARGET_DB,
    "PROJECT1_RUNTIME_DATABASE_URL": dsn(base, "p1ai_engine", "p1ai_engine_dev_only"),
    "PROJECT1_ISOLATED_DATABASE_NAME": TARGET_DB,
    "PROJECT1_ISOLATED_DATABASE_PORT": str(PORT),
    "PROJECT1_WORKFLOW_ENABLED": "true",
    "M2_BCB_PERSISTENCE_ENABLED": "true",
    "PROJECT1_BDJ_CONTRACT": "objective",
    "PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS": "1",
    "M2_PROTECTED_IDENTITY_ENABLED": "false",
    "PROJECT1_SYNTHETIC_BDJ_TRIAL_ENABLED": "false",
    "TOKENHARBOR_ENABLED": "false",
})

import jwt  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from sitewise.core.security import JWKSClient  # noqa: E402

KID = "gatebc-es256"
private_key = ec.generate_private_key(ec.SECP256R1())
coords = jwt.algorithms.ECAlgorithm.to_jwk(private_key.public_key(), as_dict=True)
public_jwk = {"kid": KID, "kty": "EC", "alg": "ES256", "use": "sig",
              "crv": "P-256", "x": coords["x"], "y": coords["y"]}


def fake_fetch(self):
    import time
    self._keys = {KID: dict(public_jwk)}
    self._fetched_at = time.monotonic()
    return self._keys


JWKSClient._fetch = fake_fetch

import sitewise.dependencies as deps  # noqa: E402
deps._verifier = None

from sitewise.main import app  # noqa: E402
from sitewise.core.supabase_admin import get_admin_service  # noqa: E402
from tests.fakes import FakeSupabaseAdmin  # noqa: E402

app.dependency_overrides[get_admin_service] = lambda: FakeSupabaseAdmin()


def token(sub=OWNER):
    from datetime import datetime, timedelta, timezone
    now = datetime.now(timezone.utc)
    payload = {"sub": sub, "email": f"gatebc-{str(sub)[:8]}@example.invalid",
               "email_verified": True, "aud": "authenticated",
               "iss": "https://lzdpjwmcjbhtkzkqudyt.supabase.co/auth/v1",
               "role": "authenticated", "iat": int(now.timestamp()),
               "exp": int((now + timedelta(minutes=10)).timestamp()),
               "session_id": str(uuid.uuid4()),
               "app_metadata": {"provider": "email", "providers": ["email"]},
               "user_metadata": {"full_name": "Gate BC E2E"}}
    return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": KID})


client = TestClient(app)
r = client.get(f"/api/v1/project1-workflow/assessments/{ASSESSMENT}/objective-proposals",
               params={"expected_revision": REVISION, "context_id": CONTEXT},
               headers={"Authorization": f"Bearer {token()}"})
print("status:", r.status_code)
print("body:", r.text[:1500])
r2 = client.get(f"/api/v1/project1-workflow/assessments/{ASSESSMENT}/objective-proposals",
                params={"expected_revision": REVISION, "context_id": CONTEXT})
print("no-auth status:", r2.status_code, r2.text[:200])
