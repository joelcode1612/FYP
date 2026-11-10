"""Staff administration API tests (spec scenarios 5, 19-24).

All Supabase admin operations run against :class:`FakeSupabaseAdmin` - no
network, no real invites - while the full FastAPI dependency chain (JWT
verification, active check, staff role, ``aal2``) is exercised for real.
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


def _admin_token(client, cleanup_users) -> tuple[uuid.UUID, str]:
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"admin-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    token = make_token(sub=str(sub), email=email, aal="aal2",
                       amr=[{"method": "password"}, {"method": "totp"}])
    client.get("/api/v1/auth/me", headers=auth(token))  # provision + mirror
    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.repositories.user_repository import UserRepository

    with Session(engine) as session:
        UserRepository(session).update(sub, {"role": "admin"})
    return sub, token


def _track_agent(cleanup_users, body: dict) -> None:
    """Register a created agent's mirror row for post-test cleanup."""
    register_user_id(cleanup_users, uuid.UUID(body["agent_user_id"]))


CREATE_BODY = {
    "full_name": "Nurul Aiman",
    "email": "new.agent@staff.example",
    "phone_number": "+60125550123",
    "company_name": "IQI Realty",
}


def test_create_agent_requires_admin(client, cleanup_users, fake_admin):
    """Scenario 25: a non-admin (default provisioned entrepreneur) cannot
    reach administrator endpoints."""
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"civilian-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}"
    token = make_token(sub=str(sub), email=email)
    client.get("/api/v1/auth/me", headers=auth(token))  # provision entrepreneur

    r = client.post("/api/v1/staff/agents", headers=auth(token), json=CREATE_BODY)
    assert r.status_code == 403


def test_create_agent_requires_aal2(client, cleanup_users, fake_admin):
    """Scenario 15 analogue for admin endpoints: password-only admin session
    (no aal2) is rejected even with the admin role."""
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"noaal-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}"
    token = make_token(sub=str(sub), email=email)  # no aal claim
    client.get("/api/v1/auth/me", headers=auth(token))
    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.repositories.user_repository import UserRepository

    with Session(engine) as session:
        UserRepository(session).update(sub, {"role": "admin"})

    r = client.post("/api/v1/staff/agents", headers=auth(token), json=CREATE_BODY)
    assert r.status_code == 403
    assert r.json()["detail"]["code"] == "staff_mfa_required"


def test_admin_creates_agent_and_supabase_invites(client, cleanup_users, fake_admin):
    """Scenarios 5-6: administrator creates the agent; the backend uses the
    native Supabase invite (password-setup email), records the invitation and
    the audit row, and provisions agent/pending."""
    admin_sub, admin_token = _admin_token(client, cleanup_users)

    r = client.post("/api/v1/staff/agents", headers=auth(admin_token), json=CREATE_BODY)
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["invited"] is True
    assert body["role"] == "agent"
    assert body["account_status"] == "pending"
    _track_agent(cleanup_users, body)

    # The invite (and only the invite) went through the native Supabase flow.
    assert fake_admin.invite_calls == ["new.agent@staff.example"]

    # Authoritative identity row: role decided server-side, never by client.
    auth_user_id = body["agent_user_id"]
    assert fake_admin.identity[auth_user_id]["role"] == "agent"
    assert fake_admin.identity[auth_user_id]["account_status"] == "pending"

    # Onboarding tracking + audit.
    assert len(fake_admin.invitations) == 1
    assert fake_admin.invitations[0]["invited_email"] == "new.agent@staff.example"
    assert fake_admin.invitations[0]["invited_by_user_id"] == str(admin_sub)
    assert any(a["action"] == "staff.invited" for a in fake_admin.audit)

    # Local enforcement mirror is agent/pending too.
    r2 = client.get("/api/v1/users/me/status",
                    headers=auth(make_token(sub=auth_user_id, email="new.agent@staff.example")))
    assert r2.status_code == 403  # pending staff are not "active" users yet


def test_duplicate_agent_email_requires_explicit_opt_in(client, cleanup_users, fake_admin):
    """Matching emails never upgrade roles automatically."""
    admin_sub, admin_token = _admin_token(client, cleanup_users)
    existing_uid = str(uuid.uuid4())
    fake_admin.auth_users["known@staff.example"] = {"id": existing_uid, "email": "known@staff.example"}

    r = client.post("/api/v1/staff/agents", headers=auth(admin_token),
                    json={**CREATE_BODY, "email": "known@staff.example"})
    assert r.status_code == 409

    r2 = client.post("/api/v1/staff/agents", headers=auth(admin_token),
                     json={**CREATE_BODY, "email": "known@staff.example", "allow_existing": True})
    assert r2.status_code == 201, r2.text
    _track_agent(cleanup_users, r2.json())
    assert r2.json()["invited"] is False
    assert fake_admin.invite_calls == []  # no re-invite for existing identity
    assert not fake_admin.invitations  # no onboarding invitation either
    assert any(a["action"] == "staff.role_granted" for a in fake_admin.audit)


def test_agent_status_lifecycle_is_audited(client, cleanup_users, fake_admin):
    """Scenarios 23-24: activate / suspend / reactivate recorded in audit."""
    admin_sub, admin_token = _admin_token(client, cleanup_users)
    created = client.post("/api/v1/staff/agents", headers=auth(admin_token), json=CREATE_BODY)
    agent_uid = uuid.UUID(created.json()["agent_user_id"])
    _track_agent(cleanup_users, created.json())

    # pending -> active (activation)
    r = client.patch(f"/api/v1/staff/agents/{agent_uid}/status",
                     headers=auth(admin_token), json={"account_status": "active"})
    assert r.status_code == 200, r.text
    assert r.json()["account_status"] == "active"

    # active -> suspended
    r = client.patch(f"/api/v1/staff/agents/{agent_uid}/status",
                     headers=auth(admin_token), json={"account_status": "suspended"})
    assert r.status_code == 200

    # suspended -> active (reactivation)
    r = client.patch(f"/api/v1/staff/agents/{agent_uid}/status",
                     headers=auth(admin_token), json={"account_status": "active"})
    assert r.status_code == 200

    actions = [a["action"] for a in fake_admin.audit]
    assert actions.count("staff.activated") == 1
    assert actions.count("staff.suspended") == 1
    assert actions.count("staff.reactivated") == 1
    for audit_row in fake_admin.audit:
        if audit_row["action"].startswith("staff."):
            assert audit_row["performed_by_user_id"] == str(admin_sub)

    # Suspended agents are denied immediately (mirror is authoritative).
    client.patch(f"/api/v1/staff/agents/{agent_uid}/status",
                 headers=auth(admin_token), json={"account_status": "suspended"})
    agent_token = make_token(sub=str(agent_uid), email="new.agent@staff.example",
                             aal="aal2", amr=[{"method": "password"}, {"method": "totp"}])
    r = client.get("/api/v1/staff/me/listings", headers=auth(agent_token))
    assert r.status_code == 403


def test_invalid_status_value_rejected(client, cleanup_users, fake_admin):
    _, admin_token = _admin_token(client, cleanup_users)
    other = uuid.uuid4()
    r = client.patch(f"/api/v1/staff/agents/{other}/status",
                     headers=auth(admin_token), json={"account_status": "banned"})
    assert r.status_code == 422


def test_status_change_target_must_be_staff(client, cleanup_users, fake_admin):
    _, admin_token = _admin_token(client, cleanup_users)
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"civilian-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}"
    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.repositories.user_repository import UserRepository

    with Session(engine) as session:
        UserRepository(session).get_or_create_from_supabase(
            user_id=sub, email=email, email_verified=True)  # entrepreneur

    r = client.patch(f"/api/v1/staff/agents/{sub}/status",
                     headers=auth(admin_token), json={"account_status": "active"})
    assert r.status_code == 422


def test_mfa_recovery_removes_verified_totp_factors_and_audits(client, cleanup_users, fake_admin):
    """Administrator-supervised lost-device recovery via the documented
    Supabase admin method; every removal is audited with the reason."""
    _, admin_token = _admin_token(client, cleanup_users)
    agent_uid = str(uuid.uuid4())
    fake_admin.factors[agent_uid] = [
        {"id": "fact-1", "status": "verified", "factor_type": "totp"},
        {"id": "fact-2", "status": "unverified", "factor_type": "totp"},
    ]

    r = client.post(f"/api/v1/staff/agents/{agent_uid}/mfa-recovery",
                    headers=auth(admin_token), json={"reason": "Lost device"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["removed_factors"] == ["fact-1"]  # unverified factors untouched
    assert body["re_enrollment_required"] is True
    assert fake_admin.removed_factors == [(agent_uid, "fact-1")]
    recovery = [a for a in fake_admin.audit if a["action"] == "staff.mfa_factor_reset"]
    assert recovery and recovery[0]["details"]["reason"] == "Lost device"


def test_admin_assigns_listing_and_records_audit(client, cleanup_users, fake_admin):
    """Scenario 22: administrator assigns a listing to an agent."""
    _, admin_token = _admin_token(client, cleanup_users)
    created = client.post("/api/v1/staff/agents", headers=auth(admin_token), json=CREATE_BODY)
    agent_uid = created.json()["agent_user_id"]
    _track_agent(cleanup_users, created.json())
    listing = fake_admin.seed_listing(701, None)

    r = client.post(f"/api/v1/staff/listings/701/assign",
                    headers=auth(admin_token), json={"agent_user_id": agent_uid})
    assert r.status_code == 200, r.text
    assert r.json()["agent_id"] == fake_admin.listings[701]["agent_id"]
    assert listing["agent_id"] is None  # pre-assignment copy unchanged
    assert any(a["action"] == "listing.assigned" and a["affected_user_id"] == agent_uid
               for a in fake_admin.audit)

    # Assigning to an unknown agent profile -> 404.
    r2 = client.post(f"/api/v1/staff/listings/701/assign",
                     headers=auth(admin_token), json={"agent_user_id": str(uuid.uuid4())})
    assert r2.status_code == 404


def test_audit_and_invitations_listing(client, cleanup_users, fake_admin):
    _, admin_token = _admin_token(client, cleanup_users)
    created = client.post("/api/v1/staff/agents", headers=auth(admin_token), json=CREATE_BODY)
    _track_agent(cleanup_users, created.json())
    r = client.get("/api/v1/staff/audit", headers=auth(admin_token))
    assert r.status_code == 200
    assert len(r.json()) >= 1
    r2 = client.get("/api/v1/staff/invitations", headers=auth(admin_token))
    assert r2.status_code == 200
    assert len(r2.json()) == 1


def test_role_change_via_users_endpoint_is_audited(client, cleanup_users, fake_admin, monkeypatch):
    """PATCH /users/{id} role changes record audit and sync the identity row."""
    import sitewise.api.v1.users as users_module

    monkeypatch.setattr(users_module, "get_admin_service", lambda: fake_admin)
    admin_sub, admin_token = _admin_token(client, cleanup_users)
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"promotee-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}"
    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.repositories.user_repository import UserRepository

    with Session(engine) as session:
        UserRepository(session).get_or_create_from_supabase(
            user_id=sub, email=email, email_verified=True)

    r = client.patch(f"/api/v1/users/{sub}", headers=auth(admin_token),
                     json={"role": "agent"})
    assert r.status_code == 200, r.text
    assert r.json()["role"] == "agent"
    # Identity row synced to the canonical agent role.
    assert fake_admin.identity[str(sub)]["role"] == "agent"
    assert any(a["action"] == "role.changed" and a["new_role"] == "agent"
               and a["previous_role"] == "entrepreneur" for a in fake_admin.audit)

    # Legacy alias 'administrator' is canonicalised on write.
    r2 = client.patch(f"/api/v1/users/{sub}", headers=auth(admin_token),
                      json={"role": "administrator"})
    assert r2.status_code == 200
    assert r2.json()["role"] == "admin"


# ---------------------------------------------------------------------------
# Regression: role_change_audit live-column mapping + audit-failure semantics
#
# The LIVE role_change_audit table exposes user_id_affected /
# affected_email_snapshot / changed_by_user_id / entity_type / entity_id /
# action / action_status / old_role / new_role / old_account_status /
# new_account_status / details (non-nullable jsonb). Writing the historical
# field names fails with PostgREST PGRST204 — the confirmed root cause of
# both "cannot invite an agent" and "Suspend produces an error".
# ---------------------------------------------------------------------------


def test_audit_payload_targets_live_role_change_audit_columns():
    """insert_role_audit must write the LIVE column names and always carry a
    details object (non-nullable jsonb)."""
    from sitewise.core.supabase_admin import SupabaseAdminService

    payload = SupabaseAdminService._audit_payload(
        affected_user_id=uuid.UUID("00000000-0000-0000-0000-000000000001"),
        affected_email="agent@staff.example",
        performed_by_user_id=uuid.UUID("00000000-0000-0000-0000-000000000002"),
        performed_by_email="admin@staff.example",
        action="staff.suspended",
        previous_status="active",
        new_status="suspended",
        details={"reason": "probe"},
    )
    assert payload["user_id_affected"] == "00000000-0000-0000-0000-000000000001"
    assert payload["changed_by_user_id"] == "00000000-0000-0000-0000-000000000002"
    assert payload["affected_email_snapshot"] == "agent@staff.example"
    assert payload["entity_id"] == "00000000-0000-0000-0000-000000000001"
    assert payload["old_account_status"] == "active"
    assert payload["new_account_status"] == "suspended"
    assert payload["entity_type"] == "user"
    assert payload["action"] == "staff.suspended"
    assert payload["action_status"] == "success"
    assert payload["details"]["performed_by_email"] == "admin@staff.example"
    assert payload["details"]["reason"] == "probe"
    # Historical (nonexistent) column names must never be sent.
    for legacy in (
        "affected_user_id",
        "affected_email",
        "performed_by_user_id",
        "performed_by_email",
        "previous_role",
        "previous_status",
        "new_status",
        "new_role" if False else "previous_status",
    ):
        assert legacy not in payload


def test_audit_payload_for_company_registration_omits_user_entity_id():
    """entity_id is uuid-typed; a company registration has no affected user,
    so the company id stays inside details instead of breaking the FK."""
    from sitewise.core.supabase_admin import SupabaseAdminService

    payload = SupabaseAdminService._audit_payload(
        affected_user_id=None,
        affected_email=None,
        performed_by_user_id=uuid.UUID("00000000-0000-0000-0000-000000000002"),
        performed_by_email="admin@staff.example",
        action="company.registered",
        entity_type="company",
        details={"company_id": 3},
    )
    assert "entity_id" not in payload
    assert "user_id_affected" not in payload
    assert payload["entity_type"] == "company"
    assert payload["details"]["company_id"] == 3


def test_audit_read_maps_live_row_to_wire_contract():
    """GET /staff/audit normalizes live rows to the shape the Jaspr activity
    table reads (affected_email / performed_by_email / created_at ...)."""
    from sitewise.core.supabase_admin import SupabaseAdminService

    wire = SupabaseAdminService._audit_wire({
        "audit_id": 1,
        "user_id_affected": "00000000-0000-0000-0000-000000000001",
        "affected_email_snapshot": "agent@staff.example",
        "changed_by_user_id": "00000000-0000-0000-0000-000000000002",
        "entity_type": "user",
        "entity_id": "00000000-0000-0000-0000-000000000001",
        "action": "staff.suspended",
        "action_status": "success",
        "old_account_status": "active",
        "new_account_status": "suspended",
        "details": {"performed_by_email": "admin@staff.example"},
        "changed_at": "2026-11-10T00:00:00+00:00",
    })
    assert wire["affected_email"] == "agent@staff.example"
    assert wire["affected_user_id"] == "00000000-0000-0000-0000-000000000001"
    assert wire["performed_by_email"] == "admin@staff.example"
    assert wire["created_at"] == "2026-11-10T00:00:00+00:00"
    assert wire["previous_status"] == "active"
    assert wire["new_status"] == "suspended"
    assert wire["action"] == "staff.suspended"


def test_invite_succeeds_when_audit_write_fails(client, cleanup_users, fake_admin, monkeypatch):
    """Partial-failure contract: the Supabase invite, the identity rows and
    the mirror are all committed BEFORE the audit write. An audit failure must
    not turn a sent invitation into a 502 — the response says so truthfully."""
    from sitewise.core.supabase_admin import SupabaseAdminError

    admin_sub, admin_token = _admin_token(client, cleanup_users)
    fake_admin.companies["AuditCo"] = 1

    def broken(**kwargs):
        raise SupabaseAdminError("Audit write failed: simulated live failure")

    monkeypatch.setattr(fake_admin, "insert_role_audit", broken)
    body = {
        **CREATE_BODY,
        "email": f"audit-fail-{uuid.uuid4().hex[:8]}@staff.example",
        "company_id": 1,
    }
    r = client.post("/api/v1/staff/agents", headers=auth(admin_token), json=body)
    assert r.status_code == 201, r.text
    assert r.json()["invited"] is True
    assert r.json()["audit_recorded"] is False
    assert r.json()["company"]["company_id"] == 1
    _track_agent(cleanup_users, r.json())
    # The invitation itself was still recorded (it precedes the audit write).
    assert any(i["invited_email"] == body["email"] for i in fake_admin.invitations)


def test_suspend_succeeds_when_audit_write_fails(client, cleanup_users, fake_admin, monkeypatch):
    """Suspension commits identity + mirror before the audit write; an audit
    failure must report the change as applied (audit_recorded=false), not as
    an error that invites a retry against an already-suspended account."""
    from sitewise.core.supabase_admin import SupabaseAdminError

    admin_sub, admin_token = _admin_token(client, cleanup_users)
    r = client.post("/api/v1/staff/agents", headers=auth(admin_token), json=CREATE_BODY)
    assert r.status_code == 201, r.text
    agent_user_id = r.json()["agent_user_id"]
    _track_agent(cleanup_users, r.json())

    def broken(**kwargs):
        raise SupabaseAdminError("Audit write failed: simulated live failure")

    monkeypatch.setattr(fake_admin, "insert_role_audit", broken)
    r2 = client.patch(
        f"/api/v1/staff/agents/{agent_user_id}/status",
        headers=auth(admin_token),
        json={"account_status": "suspended"},
    )
    assert r2.status_code == 200, r2.text
    assert r2.json()["audit_recorded"] is False
    assert r2.json()["account_status"] == "suspended"
    # Both real writes committed: authoritative identity row + mirror.
    assert fake_admin.identity[agent_user_id]["account_status"] == "suspended"
    mirror = client.get(
        "/api/v1/auth/me", headers=auth(make_token(
            sub=agent_user_id, email=CREATE_BODY["email"]))
    )
    # /auth/me deliberately stays reachable (status visibility), so the real
    # enforcement probe is a PROTECTED staff endpoint: a suspended agent must
    # be rejected by get_active_user even with a full aal2 staff token.
    suspended_token = make_token(
        sub=agent_user_id, email=CREATE_BODY["email"], aal="aal2",
        amr=[{"method": "password"}, {"method": "totp"}])
    blocked = client.get("/api/v1/staff/me/listings", headers=auth(suspended_token))
    assert blocked.status_code == 403
    assert "suspended" in str(blocked.json()["detail"]).lower()


def test_suspend_with_invalid_agent_id_is_rejected(client, cleanup_users, fake_admin):
    """A malformed uuid fails validation with a meaningful 422, not a crash."""
    admin_sub, admin_token = _admin_token(client, cleanup_users)
    r = client.patch(
        "/api/v1/staff/agents/not-a-uuid/status",
        headers=auth(admin_token),
        json={"account_status": "suspended"},
    )
    assert r.status_code == 422


def test_suspend_unknown_agent_returns_meaningful_404(client, cleanup_users, fake_admin):
    admin_sub, admin_token = _admin_token(client, cleanup_users)
    r = client.patch(
        f"/api/v1/staff/agents/{uuid.uuid4()}/status",
        headers=auth(admin_token),
        json={"account_status": "suspended"},
    )
    assert r.status_code == 404
    assert "User not found" in r.json()["detail"]
