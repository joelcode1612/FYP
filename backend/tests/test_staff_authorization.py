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


@pytest.fixture()
def real_listings():
    """Two real operational property ids + assignment cleanup.

    Assignments live in ``agent_listing_assignment`` (FK to
    ``fyp.rental_properties.id``); the fake Supabase service only supplies
    agent profiles now, so scope tests must seed the real table.
    """
    from sqlalchemy import text
    from sqlmodel import Session

    from sitewise.db.session import engine

    with Session(engine) as session:
        ids = session.execute(
            text("SELECT id FROM fyp.rental_properties ORDER BY id LIMIT 2")
        ).scalars().all()
    assert len(ids) == 2
    created: list[int] = []
    yield ids, created
    with Session(engine) as session:
        if created:
            session.execute(
                text(
                    "DELETE FROM agent_listing_assignment WHERE listing_id = ANY(:ids)"
                ),
                {"ids": created},
            )
            session.commit()


def _assign(listing_id: int, agent_id: int, created: list[int]) -> None:
    from sqlalchemy import text
    from sqlmodel import Session

    from sitewise.db.session import engine

    with Session(engine) as session:
        session.execute(
            text(
                "INSERT INTO agent_listing_assignment (listing_id, agent_id) "
                "VALUES (:lid, :aid) ON CONFLICT (listing_id) DO UPDATE "
                "SET agent_id = EXCLUDED.agent_id"
            ),
            {"lid": int(listing_id), "aid": int(agent_id)},
        )
        session.commit()
    created.append(int(listing_id))


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


def test_agent_sees_only_assigned_listings(
    client, cleanup_users, fake_admin, real_listings
):
    ids, created = real_listings
    sub, token = _mirror_user(cleanup_users, role="agent")
    profile = fake_admin.create_agent_profile(user_id=sub, agent_name="Assigned Agent")
    other_agent = fake_admin.create_agent_profile(user_id=uuid.uuid4(), agent_name="Other")
    _assign(ids[0], profile["agent_id"], created)
    _assign(ids[1], other_agent["agent_id"], created)

    r = client.get("/api/v1/staff/me/listings", headers=auth(token))
    assert r.status_code == 200
    returned = [row["listing_id"] for row in r.json()["listings"]]
    # Scope: the agent's own assignment is present, the other agent's is not.
    # (Pre-existing rows for other agent ids are outside this test's control.)
    assert ids[0] in returned
    assert ids[1] not in returned


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


def test_verification_finding_requires_assigned_listing(
    client, cleanup_users, fake_admin, real_listings
):
    """An agent cannot reach another agent's listing by changing a request
    parameter; administrators may act on any listing."""
    ids, created = real_listings
    sub, token = _mirror_user(cleanup_users, role="agent")
    profile = fake_admin.create_agent_profile(user_id=sub, agent_name="Scoped Agent")
    other = fake_admin.create_agent_profile(user_id=uuid.uuid4(), agent_name="Other")
    # Another agent owns the first listing; the second has no assignment.
    _assign(ids[0], other["agent_id"], created)

    good = {
        "property_authenticity_status": "verified",
        "commercial_classification_status": "confirmed",
        "verification_reason": "Site visit completed; photos match listing.",
    }
    # Another agent's assignment -> 403.
    r = client.post(f"/api/v1/staff/listings/{ids[0]}/verifications",
                    headers=auth(token), json=good)
    assert r.status_code == 403

    # No assignment at all -> 404 (never a phantom property).
    r = client.post(f"/api/v1/staff/listings/{ids[1]}/verifications",
                    headers=auth(token), json=good)
    assert r.status_code == 404

    # Own assignment -> 201 and recorded against the caller.
    _assign(ids[1], profile["agent_id"], created)
    r = client.post(f"/api/v1/staff/listings/{ids[1]}/verifications",
                    headers=auth(token), json=good)
    assert r.status_code == 201, r.text
    assert r.json()["verified_by_user_id"] == str(sub)

    # Listing history readable by the assigned agent.
    r = client.get(f"/api/v1/staff/listings/{ids[1]}/verifications",
                   headers=auth(token))
    assert r.status_code == 200
    assert len(r.json()) == 1


def test_admin_can_verify_any_listing(
    client, cleanup_users, fake_admin, real_listings
):
    _, token = _mirror_user(cleanup_users, role="admin")
    ids, _created = real_listings
    unassigned = {"listing_id": ids[0]}
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
