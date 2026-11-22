"""Shared Provider (Owner / Agent) workspace: enquiries, performance, verification.

The Provider workspace is ONE product surface for two account kinds, so these
tests assert the property that makes that safe: **what a caller may see is
decided by the database relationship, never by the role name**.

Coverage
--------
* an agent's inbox contains the enquiries of its assigned listings and nothing
  else; an unrelated agent cannot read or move them (404, not 403 — an
  out-of-scope row is indistinguishable from a missing one);
* an owner sees the enquiries on the listing it owns;
* an enquiry can only be created against a published, approved listing, and the
  message is length-checked;
* status transitions move forward only — ``new`` is not a settable target, a
  reply is mandatory to reach ``replied``, and a closed enquiry is not reopened;
* the performance report is scoped to managed properties, counts publication
  from the stored columns, and reports untracked engagement as untracked
  rather than as zero;
* provider (account) verification starts ``unsubmitted``, a submission always
  becomes ``pending``, a second submission while pending is refused, and only
  an ``aal2`` administrator can decide it — a rejection needs a reason;
* a staff session without its second factor is refused by the server, so the
  mobile MFA screen is load-bearing rather than decorative.

Every row these tests create is removed in teardown: the property row cascades
to its enquiries, and the user rows cascade to their verification record.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.repositories.agent_assignment_repository import (
    AgentAssignmentRepository,
)
from sitewise.repositories.user_repository import UserRepository

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

AGENT_A_ID = 992001
AGENT_B_ID = 992002


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _identity(cleanup_users, *, role: str, aal: str | None = None):
    """Create one account and return ``(user_id, token)``.

    ``aal`` is omitted for an entrepreneur (no second factor is expected) and
    passed explicitly for staff, so the same helper covers the positive and the
    "staff without MFA" negative.
    """
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"pv-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    with Session(engine) as session:
        repo = UserRepository(session)
        # A display name is part of the management contract: without one the
        # backend reports "owner_display_name_unavailable" rather than inventing
        # a name, so the fixtures carry a real one.
        repo.get_or_create_from_supabase(
            user_id=sub,
            email=email,
            full_name=f"PV Test {role.title()}",
            email_verified=True,
        )
        repo.update(sub, {"role": role, "account_status": "active"})
    token = make_token(
        sub=str(sub),
        email=email,
        aal=aal,
        amr=None if aal is None else [{"method": "password"}, {"method": "totp"}],
    )
    return sub, token


@pytest.fixture()
def owner(cleanup_users):
    """An entrepreneur that genuinely owns the listing under test."""
    sub, token = _identity(cleanup_users, role="entrepreneur")
    return {"sub": sub, "token": token}


@pytest.fixture()
def agents(monkeypatch, cleanup_users):
    """Two agents, both with a completed second factor."""
    a_sub, a_token = _identity(cleanup_users, role="agent", aal="aal2")
    b_sub, b_token = _identity(cleanup_users, role="agent", aal="aal2")
    profiles = {
        str(a_sub): {
            "agent_id": AGENT_A_ID,
            "user_id": str(a_sub),
            "agent_name": "Agent A",
        },
        str(b_sub): {
            "agent_id": AGENT_B_ID,
            "user_id": str(b_sub),
            "agent_name": "Agent B",
        },
    }
    from sitewise.core.supabase_admin import SupabaseAdminService

    monkeypatch.setattr(
        SupabaseAdminService,
        "get_agent_profile",
        lambda self, user_id: profiles.get(str(user_id)),
    )
    monkeypatch.setattr(
        SupabaseAdminService, "list_agent_profiles", lambda self: list(profiles.values())
    )
    monkeypatch.setattr(
        SupabaseAdminService, "insert_role_audit", lambda self, **kwargs: {"id": 1}
    )
    return {
        "a": {"sub": a_sub, "token": a_token, "agent_id": AGENT_A_ID},
        "b": {"sub": b_sub, "token": b_token, "agent_id": AGENT_B_ID},
    }


@pytest.fixture()
def admin(cleanup_users):
    sub, token = _identity(cleanup_users, role="admin", aal="aal2")
    return {"sub": sub, "token": token}


@pytest.fixture()
def admin_without_mfa(cleanup_users):
    """An administrator whose session never completed the second factor."""
    sub, token = _identity(cleanup_users, role="admin", aal="aal1")
    return {"sub": sub, "token": token}


@pytest.fixture()
def listing(owner):
    """One published, approved listing owned by :func:`owner`.

    Publication is set from the stored columns the backend actually reads
    (``is_published`` + ``verification_status``), not simulated.
    """
    with Session(engine) as session:
        row = session.execute(
            text(
                """
                INSERT INTO fyp.rental_properties (
                    owner_user_id, name, property_type, address, city, state,
                    postcode, latitude, longitude, rental_price, size_sqft,
                    availability, verification_status, is_published
                ) VALUES (
                    :owner, :name, 'Shop', :address, 'Kuala Lumpur',
                    'Wilayah Persekutuan', '50450', 3.1578, 101.7116, 5200,
                    1450, 'Immediate', 'approved', true
                ) RETURNING id
                """
            ),
            {
                "owner": str(owner["sub"]),
                "name": "PV Test Shopfront",
                "address": "12 Jalan PV Test",
            },
        )
        session.commit()
        listing_id = int(row.scalar_one())
    yield listing_id
    with Session(engine) as session:
        # Enquiries reference the listing ON DELETE CASCADE, so removing the
        # row also removes every enquiry these tests wrote.
        session.execute(
            text("DELETE FROM fyp.rental_properties WHERE id = :id"),
            {"id": listing_id},
        )
        session.commit()


@pytest.fixture()
def draft_listing(owner):
    """An unpublished listing, for the "not available" path."""
    with Session(engine) as session:
        row = session.execute(
            text(
                """
                INSERT INTO fyp.rental_properties (
                    owner_user_id, name, property_type, address, city, state,
                    verification_status, is_published
                ) VALUES (
                    :owner, 'PV Draft Unit', 'Shop', '1 Jalan Draft',
                    'Kuala Lumpur', 'Wilayah Persekutuan', 'draft', false
                ) RETURNING id
                """
            ),
            {"owner": str(owner["sub"])},
        )
        session.commit()
        listing_id = int(row.scalar_one())
    yield listing_id
    with Session(engine) as session:
        session.execute(
            text("DELETE FROM fyp.rental_properties WHERE id = :id"),
            {"id": listing_id},
        )
        session.commit()


def _assign(listing_id: int, agent_id: int) -> None:
    with Session(engine) as session:
        AgentAssignmentRepository(session).assign(listing_id, agent_id)


def _enquire(client, token: str, listing_id: int, message: str) -> int:
    response = client.post(
        f"/api/v1/properties/listings/{listing_id}/enquiries",
        json={"message": message},
        headers=auth(token),
    )
    assert response.status_code == 201, response.text
    return int(response.json()["data"]["id"])


# ---------------------------------------------------------------------------
# Enquiry creation
# ---------------------------------------------------------------------------


def test_enquiry_requires_a_published_approved_listing(client, owner, draft_listing):
    """An unpublished draft is 404 — the same answer as a missing listing."""
    response = client.post(
        f"/api/v1/properties/listings/{draft_listing}/enquiries",
        json={"message": "Is this unit still available to view this week?"},
        headers=auth(owner["token"]),
    )
    assert response.status_code == 404, response.text


def test_enquiry_message_is_length_checked(client, owner, listing):
    response = client.post(
        f"/api/v1/properties/listings/{listing}/enquiries",
        json={"message": "too short"},
        headers=auth(owner["token"]),
    )
    assert response.status_code == 422, response.text


def test_agent_cannot_create_an_enquiry_as_a_provider(client, agents, listing):
    """Enquiries are written by the person asking, not by the provider.

    ``require_entrepreneur`` is the dependency: an agent account is refused, so
    a provider cannot seed its own inbox.
    """
    response = client.post(
        f"/api/v1/properties/listings/{listing}/enquiries",
        json={"message": "Provider writing to its own inbox should be refused."},
        headers=auth(agents["a"]["token"]),
    )
    assert response.status_code == 403, response.text


# ---------------------------------------------------------------------------
# Inbox scoping
# ---------------------------------------------------------------------------


def test_owner_sees_enquiries_on_the_listing_it_owns(client, owner, listing):
    _enquire(client, owner["token"], listing, "Could I view the unit on Saturday?")

    response = client.get("/api/v1/provider/enquiries", headers=auth(owner["token"]))
    assert response.status_code == 200, response.text
    body = response.json()
    assert len(body["data"]) == 1
    assert body["data"][0]["property_id"] == listing
    assert body["meta"]["total"] == 1
    assert body["meta"]["by_status"]["new"] == 1


def test_agent_inbox_is_its_assignment_and_nothing_else(
    client, owner, agents, listing
):
    _enquire(client, owner["token"], listing, "Is parking included with this unit?")

    # Before assignment the agent manages nothing, so it sees nothing.
    unassigned = client.get(
        "/api/v1/provider/enquiries", headers=auth(agents["a"]["token"])
    )
    assert unassigned.status_code == 200, unassigned.text
    assert unassigned.json()["data"] == []

    _assign(listing, AGENT_A_ID)

    assigned = client.get(
        "/api/v1/provider/enquiries", headers=auth(agents["a"]["token"])
    )
    assert assigned.status_code == 200, assigned.text
    assert len(assigned.json()["data"]) == 1

    other = client.get(
        "/api/v1/provider/enquiries", headers=auth(agents["b"]["token"])
    )
    assert other.status_code == 200, other.text
    assert other.json()["data"] == []


def test_enquiry_outside_scope_cannot_be_moved(client, owner, agents, listing):
    enquiry_id = _enquire(
        client, owner["token"], listing, "What is the monthly service charge?"
    )
    _assign(listing, AGENT_A_ID)

    response = client.patch(
        f"/api/v1/provider/enquiries/{enquiry_id}",
        json={"status": "read"},
        headers=auth(agents["b"]["token"]),
    )
    assert response.status_code == 404, response.text


# ---------------------------------------------------------------------------
# Enquiry lifecycle
# ---------------------------------------------------------------------------


def test_enquiry_moves_forward_and_a_reply_is_required(
    client, owner, agents, listing
):
    enquiry_id = _enquire(
        client, owner["token"], listing, "Would the landlord accept a 2-year lease?"
    )
    _assign(listing, AGENT_A_ID)
    headers = auth(agents["a"]["token"])

    read = client.patch(
        f"/api/v1/provider/enquiries/{enquiry_id}",
        json={"status": "read"},
        headers=headers,
    )
    assert read.status_code == 200, read.text
    assert read.json()["data"]["status"] == "read"

    # "replied" without a reply would be a status with nothing behind it.
    no_reply = client.patch(
        f"/api/v1/provider/enquiries/{enquiry_id}",
        json={"status": "replied"},
        headers=headers,
    )
    assert no_reply.status_code == 422, no_reply.text

    replied = client.patch(
        f"/api/v1/provider/enquiries/{enquiry_id}",
        json={"status": "replied", "reply": "Yes, a two-year term is accepted."},
        headers=headers,
    )
    assert replied.status_code == 200, replied.text
    assert replied.json()["data"]["status"] == "replied"
    assert replied.json()["data"]["provider_reply"].startswith("Yes")
    assert replied.json()["data"]["replied_at"] is not None

    closed = client.patch(
        f"/api/v1/provider/enquiries/{enquiry_id}",
        json={"status": "closed"},
        headers=headers,
    )
    assert closed.status_code == 200, closed.text

    # A closed enquiry is kept for the record and is not reopened.
    reopened = client.patch(
        f"/api/v1/provider/enquiries/{enquiry_id}",
        json={"status": "read"},
        headers=headers,
    )
    assert reopened.status_code == 409, reopened.text


def test_new_is_not_a_settable_target(client, owner, agents, listing):
    enquiry_id = _enquire(
        client, owner["token"], listing, "Is the unit air-conditioned throughout?"
    )
    _assign(listing, AGENT_A_ID)

    # ``new`` is the arrival state; the request model refuses it before the
    # service is even reached.
    response = client.patch(
        f"/api/v1/provider/enquiries/{enquiry_id}",
        json={"status": "new"},
        headers=auth(agents["a"]["token"]),
    )
    assert response.status_code == 422, response.text


def test_inbox_filters_by_status(client, owner, agents, listing):
    first = _enquire(client, owner["token"], listing, "Can I visit on a weekday?")
    _enquire(client, owner["token"], listing, "Is there a lift to the first floor?")
    _assign(listing, AGENT_A_ID)
    headers = auth(agents["a"]["token"])

    client.patch(
        f"/api/v1/provider/enquiries/{first}",
        json={"status": "read"},
        headers=headers,
    )

    read = client.get(
        "/api/v1/provider/enquiries", params={"status": "read"}, headers=headers
    )
    assert read.status_code == 200, read.text
    assert [row["id"] for row in read.json()["data"]] == [first]

    unknown = client.get(
        "/api/v1/provider/enquiries", params={"status": "archived"}, headers=headers
    )
    assert unknown.status_code == 422, unknown.text


# ---------------------------------------------------------------------------
# Performance
# ---------------------------------------------------------------------------


def test_performance_counts_managed_listings_and_reports_untracked(
    client, owner, agents, listing
):
    _enquire(client, owner["token"], listing, "How many parking bays come with it?")
    _assign(listing, AGENT_A_ID)

    response = client.get(
        "/api/v1/provider/performance", headers=auth(agents["a"]["token"])
    )
    assert response.status_code == 200, response.text
    report = response.json()["data"]

    assert report["scope"]["is_agent"] is True
    assert report["scope"]["managed_properties"] >= 1
    assert report["listings"]["published"] >= 1
    assert report["listings"]["total"] >= 1
    assert report["enquiries"]["total"] == 1

    # Engagement is NOT tracked. It must say so instead of reporting zeroes.
    engagement = report["engagement"]
    assert engagement["tracked"] is False
    assert engagement["reason"]
    assert engagement["metrics"]
    assert all(metric["reason"] for metric in engagement["metrics"])


def test_performance_is_empty_for_an_unassigned_agent(client, owner, agents, listing):
    _enquire(client, owner["token"], listing, "Is the deposit negotiable at all?")
    _assign(listing, AGENT_A_ID)

    response = client.get(
        "/api/v1/provider/performance", headers=auth(agents["b"]["token"])
    )
    assert response.status_code == 200, response.text
    report = response.json()["data"]
    assert report["scope"]["managed_properties"] == 0
    assert report["listings"]["total"] == 0
    assert report["enquiries"]["total"] == 0
    # Still honest about what is not measured, even with nothing to measure.
    assert report["engagement"]["tracked"] is False


# ---------------------------------------------------------------------------
# Account verification
# ---------------------------------------------------------------------------


def test_verification_starts_unsubmitted(client, owner):
    response = client.get(
        "/api/v1/provider/verification", headers=auth(owner["token"])
    )
    assert response.status_code == 200, response.text
    body = response.json()["data"]
    assert body["status"] == "unsubmitted"
    assert body["provider_role"] == "owner"
    assert [item["key"] for item in body["requirements"]]


def test_agent_verification_is_recorded_as_an_agent(client, agents):
    response = client.get(
        "/api/v1/provider/verification", headers=auth(agents["a"]["token"])
    )
    assert response.status_code == 200, response.text
    assert response.json()["data"]["provider_role"] == "agent"


def test_submission_becomes_pending_and_cannot_be_repeated(client, owner):
    headers = auth(owner["token"])
    submitted = client.post(
        "/api/v1/provider/verification",
        json={
            "business_name": "PV Test Holdings",
            "contact_phone": "+60 3 1234 5678",
            "registration_no": "202601234567",
            "submission_note": "Two shopfronts in Kuala Lumpur.",
        },
        headers=headers,
    )
    assert submitted.status_code == 201, submitted.text
    assert submitted.json()["data"]["status"] == "pending"
    assert submitted.json()["data"]["submitted_at"] is not None

    repeated = client.post(
        "/api/v1/provider/verification",
        json={
            "business_name": "PV Test Holdings",
            "contact_phone": "+60 3 1234 5678",
        },
        headers=headers,
    )
    assert repeated.status_code == 409, repeated.text


def test_submission_validates_the_contact_number(client, owner):
    response = client.post(
        "/api/v1/provider/verification",
        json={"business_name": "PV Test Holdings", "contact_phone": "nope"},
        headers=auth(owner["token"]),
    )
    assert response.status_code == 422, response.text


def test_only_an_aal2_administrator_can_decide(client, owner, admin, agents):
    client.post(
        "/api/v1/provider/verification",
        json={
            "business_name": "PV Decision Test",
            "contact_phone": "+60 3 9999 0000",
        },
        headers=auth(owner["token"]),
    )

    # An agent is not an administrator.
    as_agent = client.get(
        "/api/v1/staff/providers/verification", headers=auth(agents["a"]["token"])
    )
    assert as_agent.status_code == 403, as_agent.text

    # The provider cannot approve itself, and cannot reach the queue at all.
    self_approve = client.post(
        f"/api/v1/staff/providers/{owner['sub']}/verification/decision",
        json={"decision": "approve"},
        headers=auth(owner["token"]),
    )
    assert self_approve.status_code == 403, self_approve.text

    queue = client.get(
        "/api/v1/staff/providers/verification",
        params={"status": "pending"},
        headers=auth(admin["token"]),
    )
    assert queue.status_code == 200, queue.text
    assert any(
        row["user_id"] == str(owner["sub"]) for row in queue.json()["data"]
    )


def test_administrator_without_mfa_is_refused(client, admin_without_mfa):
    response = client.get(
        "/api/v1/staff/providers/verification",
        headers=auth(admin_without_mfa["token"]),
    )
    assert response.status_code == 403, response.text
    detail = response.json()["detail"]
    assert isinstance(detail, dict) and detail.get("code") == "staff_mfa_required"


def test_rejection_needs_a_reason_and_approval_clears_it(client, owner, admin):
    client.post(
        "/api/v1/provider/verification",
        json={
            "business_name": "PV Rejection Test",
            "contact_phone": "+60 3 8888 1111",
        },
        headers=auth(owner["token"]),
    )

    no_note = client.post(
        f"/api/v1/staff/providers/{owner['sub']}/verification/decision",
        json={"decision": "reject"},
        headers=auth(admin["token"]),
    )
    assert no_note.status_code == 422, no_note.text

    rejected = client.post(
        f"/api/v1/staff/providers/{owner['sub']}/verification/decision",
        json={"decision": "reject", "note": "Registration number does not match."},
        headers=auth(admin["token"]),
    )
    assert rejected.status_code == 200, rejected.text
    assert rejected.json()["data"]["status"] == "rejected"
    assert rejected.json()["data"]["decision_note"].startswith("Registration")

    # A rejected provider may correct and resubmit.
    resubmitted = client.post(
        "/api/v1/provider/verification",
        json={
            "business_name": "PV Rejection Test",
            "contact_phone": "+60 3 8888 1111",
            "registration_no": "202609999999",
        },
        headers=auth(owner["token"]),
    )
    assert resubmitted.status_code == 201, resubmitted.text
    assert resubmitted.json()["data"]["status"] == "pending"
    assert resubmitted.json()["data"]["decision_note"] is None

    approved = client.post(
        f"/api/v1/staff/providers/{owner['sub']}/verification/decision",
        json={"decision": "approve", "note": "Documents verified."},
        headers=auth(admin["token"]),
    )
    assert approved.status_code == 200, approved.text
    assert approved.json()["data"]["status"] == "approved"

    # An approved account has nothing left to submit.
    again = client.post(
        "/api/v1/provider/verification",
        json={
            "business_name": "PV Rejection Test",
            "contact_phone": "+60 3 8888 1111",
        },
        headers=auth(owner["token"]),
    )
    assert again.status_code == 409, again.text


# ---------------------------------------------------------------------------
# Creation attribution — owner identity vs agent assignment
# ---------------------------------------------------------------------------


def test_owner_creation_keeps_the_genuine_owner_identity(client, owner):
    """An owner's draft records the owner, and reports itself owner-managed."""
    response = client.post(
        "/api/v1/properties/listings/drafts",
        json={"name": "PV Owner Draft", "property_type": "Shop"},
        headers=auth(owner["token"]),
    )
    assert response.status_code == 201, response.text
    data = response.json()["data"]
    try:
        assert data["owner_user_id"] == str(owner["sub"])
        management = client.get(
            f"/api/v1/properties/listings/{data['id']}",
            headers=auth(owner["token"]),
        ).json()["data"]["management"]
        assert management["type"] == "owner"
        assert management["assignment_status"] == "none"
        assert management["name"]
    finally:
        _delete_listing(int(data["id"]))


def test_agent_creation_assigns_the_agent_and_invents_no_owner(
    client, agents
):
    """An agent's draft has NO owner and IS assigned to the agent.

    This is the rule that keeps the two provider kinds distinct: an agent acts
    on behalf of a provider, so the record must not be stamped with an owner it
    cannot prove — but it must still be reachable by the agent that created it,
    which is what the assignment row does.
    """
    response = client.post(
        "/api/v1/properties/listings/drafts",
        json={"name": "PV Agent Draft", "property_type": "Shop"},
        headers=auth(agents["a"]["token"]),
    )
    assert response.status_code == 201, response.text
    data = response.json()["data"]
    listing_id = int(data["id"])
    try:
        assert data["owner_user_id"] is None
        with Session(engine) as session:
            assigned = session.execute(
                text(
                    "SELECT agent_id FROM fyp.agent_listing_assignment "
                    "WHERE listing_id = :lid"
                ),
                {"lid": listing_id},
            ).scalar()
        assert assigned == AGENT_A_ID

        management = client.get(
            f"/api/v1/properties/listings/{listing_id}",
            headers=auth(agents["a"]["token"]),
        ).json()["data"]["management"]
        assert management["type"] == "agent"
        assert management["name"] == "Agent A"
        assert management["owner_user_id"] is None

        # The assignment is what makes it visible — and only to that agent.
        mine = client.get(
            "/api/v1/staff/me/listings", headers=auth(agents["a"]["token"])
        )
        assert mine.status_code == 200, mine.text
        assert any(
            int(row["listing_id"]) == listing_id for row in mine.json()["listings"]
        )

        other = client.get(
            f"/api/v1/properties/listings/{listing_id}",
            headers=auth(agents["b"]["token"]),
        )
        assert other.status_code == 403, other.text
    finally:
        _delete_listing(listing_id)


def _delete_listing(listing_id: int) -> None:
    """Remove one draft this test created (cascades to its enquiries)."""
    with Session(engine) as session:
        session.execute(
            text("DELETE FROM fyp.agent_listing_assignment WHERE listing_id = :lid"),
            {"lid": listing_id},
        )
        session.execute(
            text("DELETE FROM fyp.rental_properties WHERE id = :id"),
            {"id": listing_id},
        )
        session.commit()


# ---------------------------------------------------------------------------
# Staff MFA is enforced by the server
# ---------------------------------------------------------------------------


def test_agent_without_second_factor_is_refused(client, cleanup_users, listing):
    """The mobile MFA screen is a condition, not a courtesy.

    An agent session at ``aal1`` receives the structured refusal on every
    provider surface, so no screen can grant property management on its own.
    """
    sub, token = _identity(cleanup_users, role="agent", aal="aal1")
    from sitewise.core.supabase_admin import SupabaseAdminService

    original = SupabaseAdminService.get_agent_profile
    SupabaseAdminService.get_agent_profile = lambda self, user_id: {
        "agent_id": AGENT_A_ID,
        "user_id": str(sub),
        "agent_name": "Agent Without MFA",
    }
    try:
        for path in (
            "/api/v1/provider/enquiries",
            "/api/v1/provider/performance",
            "/api/v1/provider/verification",
        ):
            response = client.get(path, headers=auth(token))
            assert response.status_code == 403, (path, response.text)
            detail = response.json()["detail"]
            assert isinstance(detail, dict), (path, detail)
            assert detail.get("code") == "staff_mfa_required", (path, detail)
    finally:
        SupabaseAdminService.get_agent_profile = original
