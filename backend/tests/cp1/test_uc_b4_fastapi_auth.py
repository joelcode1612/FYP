"""B4-02: actual FastAPI JWT boundary through the *real* UC decision route.

Unlike dependency_override or a mock verifier, these tests use real JWTs
validated by the configured Supabase verifier. They are BLOCKED until the
UC route, restricted UC connection, isolated stage application DB and token
fixtures have been implemented. They NEVER run against the default Dss DB.

HTTP success tests commit test events to the disposable isolated clone; require
an explicit opt-in and NEVER reuse a real customer's assessment/token.
"""

import os
from uuid import uuid4

import pytest
from sqlalchemy import text
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient

from _uc_b4_support import (
    blocked, require_api_stage, restricted_engine,
    token_from_file, version_fixture,
)


def route_path():
    require_api_stage()
    path = os.environ.get("UC_B4_API_PATH")
    if not path:
        blocked("UC_B4_API_PATH not supplied; implement UC POST decision endpoint first")
    if not path.startswith("/") or "{" in path:
        pytest.fail("UC_B4_API_PATH must be a concrete local API path (no placeholders)")
    from sitewise.main import app
    available = any(
        isinstance(route, APIRoute)
        and route.path == path and "POST" in route.methods
        for route in app.routes
    )
    if not available:
        pytest.fail(f"UC POST decision route {path} is not registered in FastAPI")
    return path


def request_body(version_id, event_id=None, **extras):
    body = {
        "event_id": str(event_id or uuid4()),
        "candidate_version_id": str(version_id),
        "action": "CONFIRMED",
        "receipt": f"CP1-B4-http-{uuid4()}",
    }
    body.update(extras)
    return body


def authorization(token):
    return {"Authorization": f"Bearer {token}"}


def enable_write_tests():
    if os.environ.get("UC_B4_ALLOW_API_WRITES") != "YES_DISPOSABLE_DB_ONLY":
        blocked("set UC_B4_ALLOW_API_WRITES=YES_DISPOSABLE_DB_ONLY; stage HTTP writes persist")


def assert_success(resp):
    assert resp.status_code in (200, 201, 204), (
        f"Expected authorized decision success; received HTTP {resp.status_code}"
    )


def assert_denied(resp):
    assert resp.status_code in (403, 404), (
        f"Expected cross-owner denial; received HTTP {resp.status_code}"
    )


def test_01_uc_decision_route_registered():
    route_path()


def test_02_anonymous_and_invalid_jwt_denied():
    path = route_path()
    from sitewise.main import app
    # No TestClient context manager: avoids invoking lifespan create_all;
    # the isolated stage database must already have the schema installed.
    client = TestClient(app)
    no_token = client.post(path, json=request_body(uuid4()))
    invalid = client.post(path, json=request_body(uuid4()),
                          headers=authorization("deliberately-invalid-test-token"))
    assert no_token.status_code == 401, (
        f"Anonymous request: expected HTTP 401, got {no_token.status_code}"
    )
    assert invalid.status_code == 401, (
        f"Invalid JWT: expected HTTP 401, got {invalid.status_code}"
    )


def test_03_two_real_jwts_and_cross_owner_denial():
    enable_write_tests()
    path = route_path()
    a_actor, a_version = version_fixture("A")
    b_actor, b_version = version_fixture("B")
    assert a_actor != b_actor
    token_a, token_b = token_from_file("A"), token_from_file("B")
    from sitewise.main import app
    client = TestClient(app)

    assert_success(client.post(path, json=request_body(a_version),
                               headers=authorization(token_a)))
    assert_success(client.post(path, json=request_body(b_version),
                               headers=authorization(token_b)))
    assert_denied(client.post(path, json=request_body(b_version),
                              headers=authorization(token_a)))
    assert_denied(client.post(path, json=request_body(a_version),
                              headers=authorization(token_b)))


def test_04_actor_uuid_in_payload_cannot_impersonate_user():
    enable_write_tests()
    path = route_path()
    a_actor, a_version = version_fixture("A")
    b_actor, _ = version_fixture("B")
    token_a = token_from_file("A")
    event_id = uuid4()
    from sitewise.main import app
    response = TestClient(app).post(
        path,
        json=request_body(a_version, event_id=event_id,
                          actor_user_id=str(b_actor)),
        headers=authorization(token_a),
    )
    if response.status_code in (400, 422):
        assert "actor_user_id" in response.text, (
            "Request failed, but not demonstrably because the spoofed actor was rejected"
        )
        return  # Explicitly rejected the untrusted actor field.
    assert_success(response)  # Or accepted while IGNORING untrusted actor_id.
    # This checks the persisted actor, rather than trusting the HTTP body.
    with restricted_engine("admin") as admin:
        with admin.connect() as conn:
            persisted_actor = conn.execute(text(
                "SELECT actor_user_id FROM project1_uc.candidate_events WHERE id=:id"
            ), {"id": event_id}).scalar_one()
    assert persisted_actor == a_actor, (
        "CRITICAL: UC decision used a caller-supplied actor rather than verified JWT"
    )


def test_05_service_role_token_cannot_confirm():
    enable_write_tests()
    path = route_path()
    _, a_version = version_fixture("A")
    if not os.environ.get("UC_B4_TOKEN_SERVICE_FILE"):
        blocked("provide UC_B4_TOKEN_SERVICE_FILE for restricted service identity")
    # Uses same protected-file handling without exposing the token in logs.
    token = token_from_file("SERVICE")
    from sitewise.main import app
    response = TestClient(app).post(
        path, json=request_body(a_version), headers=authorization(token)
    )
    assert response.status_code in (401, 403, 404), (
        f"Service identity can execute human decision: HTTP {response.status_code}"
    )
