"""Staff authorization tests (spec scenarios 15-18 + 25).

Covers: entrepreneur denied staff endpoints, staff sessions without ``aal2``
denied with a structured ``staff_mfa_required`` signal, suspended/pending
staff denied, agents see ONLY their assigned listings (valid empty state
otherwise), and verification scoping by assignment.
"""

import uuid

import pytest

from sitewise.domain import rbac
from tests.conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id
from tests.fakes import FakeSupabaseAdmin


@pytest.fixture()
def fake_admin(monkeypatch):
    fake = FakeSupabaseAdmin()
    import sitewise.api.v1.staff as staff_module

    monkeypatch.setattr(staff_module, "_admin_service", lambda: fake)
    return fake


def auth(token):
    return {"Authorization": f"Bearer {token}"}


def _mirror_user(cleanup_users, *, role: str, status: str = "active") -> tuple[uuid.UUID, str]:
    """Pre-create the local mirror row with a chosen role/status + token."""
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.repositories.user_repository import UserRepository

    email = f"staff-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    with Session(engine) as session:
        UserRepository(session).get_or_create_from_supabase(
            user_id=sub, email=email, email_verified=True
        )
        UserRepository(session).update(sub, {"role": role, "account_status": status})
    token = make_token(sub=str(sub), email=email, aal="aal2", amr=[{"method": "password"}, {"method": "totp"}])
    return sub, token


def test_entrepreneur_cannot_access_staff_endpoints(client, cleanup_users, fake_admin):
    """Scenario 18: entrepreneur denied staff-only endpoints."""
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"ent-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    token = make_token(sub=str(sub), email=email)
    client.get("/api/v1/auth/me", headers=auth(token))  # provision

    r = client.get("/api/v1/staff/me/listings", headers=auth(token))
    assert r.status_code == 403


def test_agent_without_aal2_is_denied_with_structured_signal(client, cleanup_users, fake_admin):
    """Scenario 15: agent session without completed MFA (aal1 / no claim)
    cannot reach protected staff endpoints; the response carries a code the
    frontend branches on for the MFA screens."""
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"aal1-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.repositories.user_repository import UserRepository

    with Session(engine) as session:
        UserRepository(session).get_or_create_from_supabase(
            user_id=sub, email=email, email_verified=True
        )
        UserRepository(session).update(sub, {"role": "agent"})

    for token in (
        make_token(sub=str(sub), email=email),  # no aal claim at all
        make_token(sub=str(sub), email=email, aal="aal1"),  # password only
    ):
        r = client.get("/api/v1/staff/me/listings", headers=auth(token))
        assert r.status_code == 403, token
        assert r.json()["detail"]["code"] == "staff_mfa_required"


def test_agent_with_aal2_gets_valid_empty_state(client, cleanup_users, fake_admin):
    """Scenario 14 (empty): agent without assignments sees an empty state,
    never unrelated listings."""
    _, token = _mirror_user(cleanup_users, role="agent")
    r = client.get("/api/v1/staff/me/listings", headers=auth(token))
    assert r.status_code == 200
    body = r.json()
    assert body["agent"] is None
    assert body["listings"] == []


def test_agent_sees_only_assigned_listings(client, cleanup_users, fake_admin):
    sub, token = _mirror_user(cleanup_users, role="agent")
    profile = fake_admin.create_agent_profile(user_id=sub, agent_name="Assigned Agent")
    mine = fake_admin.seed_listing(101, profile["agent_id"])
    fake_admin.seed_listing(202, None)
    other_agent = fake_admin.create_agent_profile(user_id=uuid.uuid4(), agent_name="Other")
    fake_admin.seed_listing(303, other_agent["agent_id"])

    r = client.get("/api/v1/staff/me/listings", headers=auth(token))
    assert r.status_code == 200
    ids = [row["listing_id"] for row in r.json()["listings"]]
    assert ids == [mine["listing_id"]]


def test_suspended_agent_denied(client, cleanup_users, fake_admin):
    """Scenario 16: suspended agent denied access."""
    _, token = _mirror_user(cleanup_users, role="agent", status="suspended")
    r = client.get("/api/v1/staff/me/listings", headers=auth(token))
    assert r.status_code == 403
    assert "suspended" in str(r.json()["detail"]).lower()


def test_pending_agent_denied(client, cleanup_users, fake_admin):
    _, token = _mirror_user(cleanup_users, role="agent", status="pending")
    r = client.get("/api/v1/staff/me/listings", headers=auth(token))
    assert r.status_code == 403


def test_verification_finding_requires_assigned_listing(client, cleanup_users, fake_admin):
    """An agent cannot reach another agent's listing by changing a request
    parameter; administrators may act on any listing."""
    sub, token = _mirror_user(cleanup_users, role="agent")
    profile = fake_admin.create_agent_profile(user_id=sub, agent_name="Scoped Agent")
    assigned = fake_admin.seed_listing(501, profile["agent_id"])
    unassigned = fake_admin.seed_listing(502, None)

    good = {
        "property_authenticity_status": "verified",
        "commercial_classification_status": "confirmed",
        "verification_reason": "Site visit completed; photos match listing.",
    }
    # Unassigned listing -> 403.
    r = client.post(f"/api/v1/staff/listings/{unassigned['listing_id']}/verifications",
                    headers=auth(token), json=good)
    assert r.status_code == 403

    # Assigned listing -> 201 and recorded against the caller.
    r = client.post(f"/api/v1/staff/listings/{assigned['listing_id']}/verifications",
                    headers=auth(token), json=good)
    assert r.status_code == 201, r.text
    assert r.json()["verified_by_user_id"] == str(sub)

    # Listing history readable by the assigned agent.
    r = client.get(f"/api/v1/staff/listings/{assigned['listing_id']}/verifications",
                   headers=auth(token))
    assert r.status_code == 200
    assert len(r.json()) == 1


def test_admin_can_verify_any_listing(client, cleanup_users, fake_admin):
    _, token = _mirror_user(cleanup_users, role="admin")
    unassigned = fake_admin.seed_listing(601, None)
    r = client.post(
        f"/api/v1/staff/listings/{unassigned['listing_id']}/verifications",
        headers=auth(token),
        json={
            "property_authenticity_status": "verified",
            "commercial_classification_status": "confirmed",
            "verification_reason": "Administrative re-check.",
        },
    )
    assert r.status_code == 201, r.text


def test_nonexistent_agent_cannot_sign_in_to_staff(client, cleanup_users, fake_admin):
    """Scenario 17: an unknown identity has no local staff row - the JWT
    verifies (it is signed correctly in the test) but provisions the default
    entrepreneur role, so staff authorization fails."""
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    token = make_token(sub=str(sub), email=f"ghost-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}", aal="aal2")
    r = client.get("/api/v1/staff/me/listings", headers=auth(token))
    assert r.status_code == 403


def test_legacy_administrator_role_still_authorizes_staff(client, cleanup_users, fake_admin):
    """Legacy 'administrator' rows keep working until the data migration."""
    _, token = _mirror_user(cleanup_users, role=rbac.ROLE_ADMINISTRATOR)
    r = client.get("/api/v1/staff/me/listings", headers=auth(token))
    assert r.status_code == 200
