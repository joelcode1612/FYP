"""Throwaway probe: surface the real exception behind a held BCB retrieve."""
import os
import sys
import traceback
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / "src"))

from sqlalchemy.engine import make_url  # noqa: E402

lines = (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines()
raw = next(l.split("=", 1)[1].strip() for l in lines if l.startswith("DATABASE_URL="))
t = make_url(raw).set(host="127.0.0.1", port=5433, database="project1_workflow_tests")
m2 = t.set(username="p1_m2_runtime", password="m2_runtime_dev_only").render_as_string(hide_password=False)
eng = t.set(username="p1ai_engine", password="p1ai_engine_dev_only").render_as_string(hide_password=False)
os.environ.update({
    "DATABASE_URL": m2, "M2_DATABASE_URL": m2,
    "M2_EXPECTED_DATABASE": "project1_workflow_tests",
    "PROJECT1_RUNTIME_DATABASE_URL": eng,
    "PROJECT1_ISOLATED_DATABASE_NAME": "project1_workflow_tests",
    "PROJECT1_ISOLATED_DATABASE_PORT": "5433",
    "PROJECT1_WORKFLOW_ENABLED": "true", "M2_BCB_PERSISTENCE_ENABLED": "true",
    "PROJECT1_BDJ_CONTRACT": "objective",
    "PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS": "1",
    "M2_PROTECTED_IDENTITY_ENABLED": "false", "TOKENHARBOR_ENABLED": "false",
})

import jwt  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from sitewise.core.security import JWKSClient  # noqa: E402

KID = "probe"
key = ec.generate_private_key(ec.SECP256R1())
coords = jwt.algorithms.ECAlgorithm.to_jwk(key.public_key(), as_dict=True)


def fake_fetch(self):
    import time
    self._keys = {KID: {"kid": KID, "kty": "EC", "alg": "ES256", "use": "sig",
                        "crv": "P-256", "x": coords["x"], "y": coords["y"]}}
    self._fetched_at = time.monotonic()
    return self._keys


JWKSClient._fetch = fake_fetch
import sitewise.dependencies as deps  # noqa: E402
deps._verifier = None

from sitewise.main import app  # noqa: E402
from sitewise.core.supabase_admin import get_admin_service  # noqa: E402
from tests.fakes import FakeSupabaseAdmin  # noqa: E402
from sitewise.services.persisted_business_context_service import (  # noqa: E402
    PersistedBusinessContextService)

app.dependency_overrides[get_admin_service] = lambda: FakeSupabaseAdmin()

original = PersistedBusinessContextService.retrieve


def traced(self, *args, **kwargs):
    try:
        return original(self, *args, **kwargs)
    except Exception:
        print("---- retrieve raised ----")
        traceback.print_exc()
        raise


PersistedBusinessContextService.retrieve = traced

from datetime import datetime, timedelta, timezone  # noqa: E402
import uuid  # noqa: E402

now = datetime.now(timezone.utc)
tok = jwt.encode({
    "sub": "c70a999a-50c6-4a31-8f7a-b914d0a5c641",
    "email": "gatebc-e2e-c70a999a@example.invalid",
    "email_verified": True, "aud": "authenticated",
    "iss": "https://lzdpjwmcjbhtkzkqudyt.supabase.co/auth/v1",
    "role": "authenticated", "iat": int(now.timestamp()),
    "exp": int((now + timedelta(minutes=10)).timestamp()),
    "session_id": str(uuid.uuid4()),
    "app_metadata": {"provider": "email", "providers": ["email"]},
    "user_metadata": {"full_name": "probe"},
}, key, algorithm="ES256", headers={"kid": KID})

client = TestClient(app)
r = client.get(
    "/api/v1/project1-workflow/assessments/d82b78ff-dad0-41d8-afa4-0205ad199a20/objective-proposals",
    params={"expected_revision": 11,
            "context_id": "79151dfe-c411-54d9-b03c-47b19ce44ecb"},
    headers={"Authorization": f"Bearer {tok}"})
print("status:", r.status_code)
print("body:", r.text[:400])
