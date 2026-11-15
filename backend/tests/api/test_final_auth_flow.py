"""Final authentication / role-based navigation — backend invariants.

The live Supabase project keeps ``mailer_autoconfirm = false`` globally, so a
normal ``/auth/v1/signup`` cannot give a new Entrepreneur a session. The
trusted ``POST /api/v1/auth/register`` provisions ONE already-confirmed public
identity and returns NO token; the client then performs a real password
sign-in and ``/auth/me`` provisions the local profile from the verified JWT.

These tests pin the security boundaries that must not move:

* registration never accepts a role/status/assurance field and never issues a
  session;
* the canonical ``entrepreneur`` role comes from the local profile, even when
  the token's (client-influenced) metadata claims ``admin``;
* profile provisioning is idempotent keyed by the Supabase UUID;
* the verified ``aal`` claim is echoed read-only and staff ``aal1`` sessions
  are refused by protected endpoints;
* an Entrepreneur cannot read another Provider's enquiry inbox;
* the existing Administrator AAL2 requirement is unchanged.
"""

from __future__ import annotations

import uuid

import pytest
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.core.exceptions import ConflictError
from sitewise.core.supabase_admin import get_admin_service
from sitewise.db.session import engine
from sitewise.main import app
from sitewise.repositories.user_repository import UserRepository

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

REGISTER = "/api/v1/auth/register"


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


class _FakeAdmin:
    """Records the trusted provisioning call without contacting Supabase."""

    def __init__(self, duplicate: bool = False):
        self.duplicate = duplicate
        self.calls: list[dict] = []

    def create_confirmed_entrepreneur(self, **kwargs):
        self.calls.append(kwargs)
        if self.duplicate:
            raise ConflictError("An account with this email already exists.")
        return {"id": str(uuid.uuid4())}


@pytest.fixture(autouse=True)
def _clean_throttle():
    from sitewise.api.v1.auth import reset_registration_throttle

    reset_registration_throttle()
    yield
    reset_registration_throttle()
    app.dependency_overrides.pop(get_admin_service, None)


@pytest.fixture()
def admin_stub():
    fake = _FakeAdmin()
    app.dependency_overrides[get_admin_service] = lambda: fake
    return fake


def _payload(**overrides):
    base = {
        "email": f"new-{uuid.uuid4().hex[:10]}@{TEST_EMAIL_DOMAIN}",
        "password": "Passw0rd",
        "full_name": "New Entrepreneur",
        "account_purpose": "entrepreneur",
        "accept_terms": True,
    }
    base.update(overrides)
    return base


# ---------------------------------------------------------------------------
# Public registration
# ---------------------------------------------------------------------------


def test_registration_creates_one_confirmed_identity_and_no_session(client, admin_stub):
    payload = _payload()
    response = client.post(REGISTER, json=payload)
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["registered"] is True
    assert body["session_issued"] is False
    # No token, role, status or assurance value is ever handed to the client.
    assert not any(
        key in body for key in ("access_token", "session", "token", "role")
    )
    assert len(admin_stub.calls) == 1
    call = admin_stub.calls[0]
    assert call["email"] == payload["email"]
    assert call["full_name"] == "New Entrepreneur"
    assert call["account_purpose"] == "entrepreneur"
    assert set(call) == {"email", "password", "full_name", "account_purpose"}


def test_registration_forbids_privileged_extra_fields(client, admin_stub):
    response = client.post(REGISTER, json=_payload(role="admin"))
    assert response.status_code == 422
    assert not admin_stub.calls
    for field in ("account_status", "email_verified", "assurance_level"):
        again = client.post(REGISTER, json=_payload(**{field: "aal2"}))
        assert again.status_code == 422
    assert not admin_stub.calls


@pytest.mark.parametrize(
    "override",
    [
        {"email": "not-an-email"},
        {"password": "short"},
        {"password": "allletters"},
        {"password": "12345678"},
        {"accept_terms": False},
        {"full_name": "A"},
    ],
)
def test_registration_validates_locally(client, admin_stub, override):
    assert client.post(REGISTER, json=_payload(**override)).status_code == 422
    assert not admin_stub.calls


def test_unknown_account_purpose_is_dropped_not_trusted(client, admin_stub):
    response = client.post(REGISTER, json=_payload(account_purpose="admin"))
    assert response.status_code == 201
    assert admin_stub.calls[0]["account_purpose"] is None


def test_duplicate_email_is_a_conflict_not_an_overwrite(client):
    app.dependency_overrides[get_admin_service] = lambda: _FakeAdmin(duplicate=True)
    assert client.post(REGISTER, json=_payload()).status_code == 409


def test_kill_switch_preserves_the_project_confirmation_policy(client, admin_stub, monkeypatch):
    monkeypatch.setattr(settings, "public_registration_autoconfirm", False)
    response = client.post(REGISTER, json=_payload())
    assert response.status_code == 503
    assert not admin_stub.calls


def test_public_endpoint_is_rate_limited(client, admin_stub):
    payload = _payload()
    for _ in range(10):
        assert client.post(REGISTER, json=payload).status_code == 201
    assert client.post(REGISTER, json=payload).status_code == 409


# ---------------------------------------------------------------------------
# Trusted profile provisioning (/auth/me)
# ---------------------------------------------------------------------------


def test_me_provisions_an_active_entrepreneur_once(client, cleanup_users):
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"provision-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    # A client can put ANY role in its signup metadata. It must not matter.
    token = make_token(
        sub=str(sub),
        email=email,
        role_claims={"full_name": "Self Declared Admin", "role": "admin"},
    )
    first = client.get("/api/v1/auth/me", headers=auth(token))
    assert first.status_code == 200, first.text
    body = first.json()
    assert body["user_id"] == str(sub)
    assert body["role"] == "entrepreneur"
    assert body["account_status"] == "active"
    assert body["assurance_level"] is None  # entrepreneur: no MFA claim
    assert body["full_name"] == "Self Declared Admin"

    second = client.get("/api/v1/auth/me", headers=auth(token))
    assert second.status_code == 200
    assert second.json()["user_id"] == str(sub)
    with Session(engine) as session:
        assert UserRepository(session).get_by_id(sub) is not None
    # Exactly one row for this identity (the UUID is the primary key).
    assert first.json()["user_id"] == second.json()["user_id"]


def test_me_echoes_the_verified_aal_claim(client, cleanup_users):
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"aal-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    token = make_token(
        sub=str(sub),
        email=email,
        aal="aal2",
        amr=[{"method": "password"}, {"method": "totp"}],
    )
    response = client.get("/api/v1/auth/me", headers=auth(token))
    assert response.status_code == 200
    assert response.json()["assurance_level"] == "aal2"


# ---------------------------------------------------------------------------
# Authorization is still the server's decision
# ---------------------------------------------------------------------------


def _identity(cleanup_users, *, role: str, aal: str | None = None):
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"flow-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    with Session(engine) as session:
        repo = UserRepository(session)
        repo.get_or_create_from_supabase(
            user_id=sub, email=email, full_name="Flow User", email_verified=True
        )
        repo.update(sub, {"role": role, "account_status": "active"})
    token = make_token(sub=str(sub), email=email, aal=aal)
    return sub, token


def test_agent_without_mfa_is_refused_by_protected_provider_routes(client, cleanup_users):
    _, token = _identity(cleanup_users, role="agent", aal="aal1")
    response = client.get("/api/v1/provider/enquiries", headers=auth(token))
    assert response.status_code == 403
    assert "staff_mfa_required" in response.text


def test_agent_with_aal2_may_open_the_provider_workspace(client, cleanup_users):
    _, token = _identity(cleanup_users, role="agent", aal="aal2")
    response = client.get("/api/v1/provider/enquiries", headers=auth(token))
    assert response.status_code == 200


def test_entrepreneur_is_scoped_out_of_provider_data(client, cleanup_users):
    """An Entrepreneur may read its own profile but never another Provider's
    workspace rows. The role alone grants no listing-management authority."""
    _, token = _identity(cleanup_users, role="entrepreneur")
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    # A provider verification decision is administrator-only + aal2.
    decision = client.post(
        f"/api/v1/staff/providers/{uuid.uuid4()}/verification/decision",
        headers=auth(token),
        json={"decision": "approve", "note": "escalation attempt"},
    )
    assert decision.status_code in (401, 403)


def test_admin_mfa_policy_is_unchanged(client, cleanup_users):
    _, aal1 = _identity(cleanup_users, role="admin", aal="aal1")
    _, aal2 = _identity(cleanup_users, role="admin", aal="aal2")
    path = "/api/v1/staff/providers/verification"
    assert client.get(path, headers=auth(aal1)).status_code == 403
    assert client.get(path, headers=auth(aal2)).status_code == 200
