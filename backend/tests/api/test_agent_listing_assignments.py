"""P0 verification: agent assignments, change requests and admin decisions.

Covers the workflow that was previously impossible to exercise because the
assignment table did not exist:

* assignments are FK-backed by ``fyp.rental_properties.id`` (no phantom rows);
* an agent sees only their own assigned listings; another agent gets 403;
* a missing assignment/property is an explicit 404;
* saving a proposal writes a DRAFT and never touches the operational row;
* submitting makes it pending; duplicates are refused;
* the administrator queue lists pending requests with current vs proposed;
* approving applies the whitelisted fields; rejecting changes nothing;
* a stale proposal is refused with 409 instead of overwriting newer data;
* the decision endpoint accepts and persists a review note (regression for
  the missing ``note`` field that made every decision fail).

Every test uses a real property row and restores it in teardown. No test
leaves assignments, change requests or modified listings behind.
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

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

AGENT_A_ID = 991001
AGENT_B_ID = 991002


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _staff_identity(cleanup_users, *, role: str) -> tuple[uuid.UUID, str]:
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"pm-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    from sitewise.repositories.user_repository import UserRepository

    with Session(engine) as session:
        repo = UserRepository(session)
        repo.get_or_create_from_supabase(user_id=sub, email=email, email_verified=True)
        repo.update(sub, {"role": role, "account_status": "active"})
    token = make_token(
        sub=str(sub), email=email, aal="aal2", amr=[{"method": "password"}, {"method": "totp"}]
    )
    return sub, token


@pytest.fixture()
def agents(monkeypatch, cleanup_users):
    """Two agent identities with distinct Supabase agent ids (mocked lookup)."""
    a_sub, a_token = _staff_identity(cleanup_users, role="agent")
    b_sub, b_token = _staff_identity(cleanup_users, role="agent")
    profiles = {
        str(a_sub): {"agent_id": AGENT_A_ID, "user_id": str(a_sub), "agent_name": "Agent A"},
        str(b_sub): {"agent_id": AGENT_B_ID, "user_id": str(b_sub), "agent_name": "Agent B"},
    }
    from sitewise.core.supabase_admin import SupabaseAdminService

    monkeypatch.setattr(
        SupabaseAdminService, "get_agent_profile", lambda self, user_id: profiles.get(str(user_id))
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
        "profiles": profiles,
    }


@pytest.fixture()
def admin_token(cleanup_users):
    _sub, token = _staff_identity(cleanup_users, role="admin")
    return token


@pytest.fixture()
def listing_id():
    """A real operational property, restored after the test."""
    with Session(engine) as session:
        row = session.execute(
            text(
                "SELECT id, name, rental_price, size_sqft, description, "
                "property_type, availability, floor_level "
                "FROM fyp.rental_properties ORDER BY id LIMIT 1"
            )
        ).mappings().first()
    assert row is not None
    snapshot = dict(row)
    yield int(row["id"])
    with Session(engine) as session:
        session.execute(
            text(
                "UPDATE fyp.rental_properties SET name=:name, rental_price=:rental_price, "
                "size_sqft=:size_sqft, description=:description, "
                "property_type=:property_type, availability=:availability, "
                "floor_level=:floor_level WHERE id=:id"
            ),
            snapshot,
        )
        session.execute(
            text("DELETE FROM listing_change_audit WHERE listing_id = :lid"),
            {"lid": snapshot["id"]},
        )
        session.execute(
            text("DELETE FROM listing_change_request WHERE listing_id = :lid"),
            {"lid": snapshot["id"]},
        )
        session.execute(
            text("DELETE FROM agent_listing_assignment WHERE listing_id = :lid"),
            {"lid": snapshot["id"]},
        )
        session.commit()


def _assign(listing_id: int, agent_id: int) -> None:
    with Session(engine) as session:
        AgentAssignmentRepository(session).assign(listing_id, agent_id)


def _property_row(listing_id: int) -> dict:
    with Session(engine) as session:
        return dict(
            session.execute(
                text("SELECT * FROM fyp.rental_properties WHERE id = :id"),
                {"id": listing_id},
            ).mappings().one()
        )


def _request_id(client, token: str, listing_id: int) -> str:
    response = client.get(
        f"/api/v1/staff/listings/{listing_id}/change-requests",
        headers=auth(token),
    )
    assert response.status_code == 200, response.text
    requests = response.json()["requests"]
    assert requests
    return requests[0]["change_request_id"]


# ---------------------------------------------------------------------------
# Assignments and scope
# ---------------------------------------------------------------------------


def test_agent_sees_only_own_assignment(client, agents, listing_id):
    _assign(listing_id, AGENT_A_ID)
    own = client.get("/api/v1/staff/me/listings", headers=auth(agents["a"]["token"]))
    assert own.status_code == 200, own.text
    ids = [row["listing_id"] for row in own.json()["listings"]]
    assert ids == [listing_id]

    other = client.get("/api/v1/staff/me/listings", headers=auth(agents["b"]["token"]))
    assert other.status_code == 200
    assert other.json()["listings"] == []


def test_other_agent_is_forbidden(client, agents, listing_id):
    _assign(listing_id, AGENT_A_ID)
    response = client.get(
        f"/api/v1/staff/listings/{listing_id}", headers=auth(agents["b"]["token"])
    )
    assert response.status_code == 403


def test_missing_assignment_is_404(client, agents, listing_id):
    response = client.get(
        f"/api/v1/staff/listings/{listing_id}", headers=auth(agents["a"]["token"])
    )
    assert response.status_code == 404


def test_assigned_agent_loads_real_property(client, agents, listing_id):
    _assign(listing_id, AGENT_A_ID)
    response = client.get(
        f"/api/v1/staff/listings/{listing_id}", headers=auth(agents["a"]["token"])
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["property"]["id"] == listing_id
    assert body["property"]["name"] == _property_row(listing_id)["name"]
    assert body["listing"]["agent_id"] == AGENT_A_ID


def test_admin_can_read_assigned_listing(client, agents, admin_token, listing_id):
    _assign(listing_id, AGENT_A_ID)
    response = client.get(
        f"/api/v1/staff/listings/{listing_id}", headers=auth(admin_token)
    )
    assert response.status_code == 200, response.text


def test_assign_endpoint_is_fk_backed(client, agents, admin_token, listing_id):
    response = client.post(
        f"/api/v1/staff/listings/{listing_id}/assign",
        json={"agent_user_id": str(agents["a"]["sub"])},
        headers=auth(admin_token),
    )
    assert response.status_code == 200, response.text
    assert response.json()["agent_id"] == AGENT_A_ID

    missing = client.post(
        "/api/v1/staff/listings/99999999/assign",
        json={"agent_user_id": str(agents["a"]["sub"])},
        headers=auth(admin_token),
    )
    assert missing.status_code == 404


# ---------------------------------------------------------------------------
# Draft → pending → decision
# ---------------------------------------------------------------------------


def _proposal(client, token, listing_id, **fields):
    return client.patch(
        f"/api/v1/staff/listings/{listing_id}/proposal",
        json=fields,
        headers=auth(token),
    )


def test_draft_never_touches_operational_row(client, agents, listing_id):
    _assign(listing_id, AGENT_A_ID)
    before = _property_row(listing_id)
    new_rent = float(before["rental_price"] or 1000) + 137
    response = _proposal(
        client, agents["a"]["token"], listing_id,
        rental_price=new_rent, description="Agent-proposed description",
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["updated"] is True
    assert body["change_request"]["status"] == "draft"
    assert body["change_request"]["changes"]["rental_price"]["from"] == before["rental_price"]
    assert _property_row(listing_id)["rental_price"] == before["rental_price"]


def test_submit_then_approve_applies_and_records_note(
    client, agents, admin_token, listing_id
):
    _assign(listing_id, AGENT_A_ID)
    before = _property_row(listing_id)
    new_rent = float(before["rental_price"] or 1000) + 211
    _proposal(client, agents["a"]["token"], listing_id, rental_price=new_rent)

    submitted = client.post(
        f"/api/v1/staff/listings/{listing_id}/review-request",
        json={"reason": "Updated rental per owner instruction."},
        headers=auth(agents["a"]["token"]),
    )
    assert submitted.status_code == 200, submitted.text
    assert submitted.json()["change_request"]["status"] == "pending"
    request_id = submitted.json()["change_request"]["change_request_id"]

    decided = client.post(
        f"/api/v1/staff/listings/{listing_id}/change-requests/{request_id}/decision",
        json={"decision": "approve", "note": "Approved after verification."},
        headers=auth(admin_token),
    )
    assert decided.status_code == 200, decided.text
    body = decided.json()
    assert body["change_request"]["status"] == "approved"
    assert body["change_request"]["review_note"] == "Approved after verification."
    assert "rental_price" in body["applied_fields"]
    assert float(_property_row(listing_id)["rental_price"]) == pytest.approx(new_rent)


def test_reject_leaves_operational_row_unchanged(client, agents, admin_token, listing_id):
    _assign(listing_id, AGENT_A_ID)
    before = _property_row(listing_id)
    _proposal(
        client, agents["a"]["token"], listing_id,
        description="Reject me " + uuid.uuid4().hex[:6],
    )
    submitted = client.post(
        f"/api/v1/staff/listings/{listing_id}/review-request",
        json={"reason": "Please review this description."},
        headers=auth(agents["a"]["token"]),
    )
    request_id = submitted.json()["change_request"]["change_request_id"]
    decided = client.post(
        f"/api/v1/staff/listings/{listing_id}/change-requests/{request_id}/decision",
        json={"decision": "reject", "note": "Not accurate."},
        headers=auth(admin_token),
    )
    assert decided.status_code == 200, decided.text
    assert decided.json()["change_request"]["status"] == "rejected"
    assert _property_row(listing_id)["description"] == before["description"]


def test_stale_proposal_is_refused_with_409(client, agents, admin_token, listing_id):
    _assign(listing_id, AGENT_A_ID)
    before = _property_row(listing_id)
    new_rent = float(before["rental_price"] or 1000) + 300
    _proposal(client, agents["a"]["token"], listing_id, rental_price=new_rent)
    submitted = client.post(
        f"/api/v1/staff/listings/{listing_id}/review-request",
        json={"reason": "Rent adjustment proposal."},
        headers=auth(agents["a"]["token"]),
    )
    request_id = submitted.json()["change_request"]["change_request_id"]

    # Another authorized workflow changes the rental after the proposal.
    with Session(engine) as session:
        session.execute(
            text("UPDATE fyp.rental_properties SET rental_price = :p WHERE id = :id"),
            {"p": new_rent + 500, "id": listing_id},
        )
        session.commit()

    decided = client.post(
        f"/api/v1/staff/listings/{listing_id}/change-requests/{request_id}/decision",
        json={"decision": "approve"},
        headers=auth(admin_token),
    )
    assert decided.status_code == 409, decided.text
    detail = decided.json()["detail"]
    assert detail["code"] == "stale_change_request"
    assert "rental_price" in detail["fields"]
    # The newer value survives; the stale proposal did not overwrite it.
    assert float(_property_row(listing_id)["rental_price"]) == pytest.approx(new_rent + 500)


def test_duplicate_pending_is_refused(client, agents, listing_id):
    _assign(listing_id, AGENT_A_ID)
    _proposal(
        client, agents["a"]["token"], listing_id,
        description="First proposal " + uuid.uuid4().hex[:6],
    )
    first = client.post(
        f"/api/v1/staff/listings/{listing_id}/review-request",
        json={"reason": "First review request."},
        headers=auth(agents["a"]["token"]),
    )
    assert first.status_code == 200, first.text
    second = client.post(
        f"/api/v1/staff/listings/{listing_id}/review-request",
        json={"reason": "Second review request."},
        headers=auth(agents["a"]["token"]),
    )
    assert second.status_code == 409


def test_admin_queue_shows_current_and_proposed(client, agents, admin_token, listing_id):
    _assign(listing_id, AGENT_A_ID)
    before = _property_row(listing_id)
    new_rent = float(before["rental_price"] or 1000) + 77
    _proposal(client, agents["a"]["token"], listing_id, rental_price=new_rent)
    client.post(
        f"/api/v1/staff/listings/{listing_id}/review-request",
        json={"reason": "Queue visibility check."},
        headers=auth(agents["a"]["token"]),
    )
    queue = client.get(
        "/api/v1/staff/change-requests?status=pending", headers=auth(admin_token)
    )
    assert queue.status_code == 200, queue.text
    rows = [r for r in queue.json()["requests"] if r["listing_id"] == listing_id]
    assert len(rows) == 1
    row = rows[0]
    assert row["property"]["property_exists"] is True
    assert float(row["current"]["rental_price"]) == float(before["rental_price"])
    assert float(row["changes"]["rental_price"]["to"]) == pytest.approx(new_rent)
    assert row["agent"]["agent_id"] == AGENT_A_ID


def test_queue_requires_admin_mfa(client, agents):
    response = client.get(
        "/api/v1/staff/change-requests", headers=auth(agents["a"]["token"])
    )
    assert response.status_code == 403


# ---------------------------------------------------------------------------
# Photos: agent-scoped permissions
# ---------------------------------------------------------------------------


def test_agent_can_upload_photo_for_assigned_listing(
    client, agents, listing_id, monkeypatch
):
    from sitewise.services import photo_storage

    monkeypatch.setattr(
        photo_storage,
        "save_photo",
        lambda data, ext, content_type: "https://example.test/agent-photo.jpg",
    )
    _assign(listing_id, AGENT_A_ID)
    response = client.post(
        f"/api/v1/staff/listings/{listing_id}/photos",
        headers=auth(agents["a"]["token"]),
        files={"file": ("photo.png", b"\x89PNG\r\n\x1a\n" + b"0" * 64, "image/png")},
        data={"caption": "Agent photo", "is_primary": "true"},
    )
    assert response.status_code == 201, response.text
    photo = response.json()["data"]
    assert photo["url"] == "https://example.test/agent-photo.jpg"
    with Session(engine) as session:
        count = session.execute(
            text(
                "SELECT count(*) FROM fyp.property_photos WHERE property_id = :id"
            ),
            {"id": listing_id},
        ).scalar_one()
    assert count >= 1
    with Session(engine) as session:
        session.execute(
            text(
                "DELETE FROM fyp.property_photos WHERE property_id = :id "
                "AND url = 'https://example.test/agent-photo.jpg'"
            ),
            {"id": listing_id},
        )
        session.commit()


def test_other_agent_cannot_upload_photo(client, agents, listing_id, monkeypatch):
    from sitewise.services import photo_storage

    monkeypatch.setattr(
        photo_storage,
        "save_photo",
        lambda data, ext, content_type: "https://example.test/never.jpg",
    )
    _assign(listing_id, AGENT_A_ID)
    response = client.post(
        f"/api/v1/staff/listings/{listing_id}/photos",
        headers=auth(agents["b"]["token"]),
        files={"file": ("photo.png", b"\x89PNG\r\n\x1a\n" + b"0" * 64, "image/png")},
    )
    assert response.status_code == 403


def test_reject_without_reason_is_refused(client, agents, admin_token, listing_id):
    """Rejecting (or asking for changes) must carry a reason: the agent needs
    an actionable explanation, and the decision is not recorded without one."""
    _assign(listing_id, AGENT_A_ID)
    _proposal(
        client, agents["a"]["token"], listing_id,
        description="Needs a reason " + uuid.uuid4().hex[:6],
    )
    submitted = client.post(
        f"/api/v1/staff/listings/{listing_id}/review-request",
        json={"reason": "Please review this description."},
        headers=auth(agents["a"]["token"]),
    )
    request_id = submitted.json()["change_request"]["change_request_id"]

    refused = client.post(
        f"/api/v1/staff/listings/{listing_id}/change-requests/{request_id}/decision",
        json={"decision": "reject"},
        headers=auth(admin_token),
    )
    assert refused.status_code == 422, refused.text
    assert "reason is required" in refused.json()["detail"].lower()

    # The request is still pending — a refused decision never consumes it.
    history = client.get(
        f"/api/v1/staff/listings/{listing_id}/change-requests",
        headers=auth(agents["a"]["token"]),
    ).json()["requests"]
    assert history[0]["status"] == "pending"


def test_proposer_cannot_decide_own_request(
    client, agents, admin_token, listing_id
):
    """An administrator who authored the proposal cannot approve it: the
    review must be independent of the author."""
    _assign(listing_id, AGENT_A_ID)
    # The admin authors the proposal (administrators may act on any listing).
    _proposal(
        client, admin_token, listing_id,
        description="Admin-authored " + uuid.uuid4().hex[:6],
    )
    submitted = client.post(
        f"/api/v1/staff/listings/{listing_id}/review-request",
        json={"reason": "Self-authored proposal for the guard test."},
        headers=auth(admin_token),
    )
    assert submitted.status_code == 200, submitted.text
    request_id = submitted.json()["change_request"]["change_request_id"]

    refused = client.post(
        f"/api/v1/staff/listings/{listing_id}/change-requests/{request_id}/decision",
        json={"decision": "approve", "note": "Trying to self-approve."},
        headers=auth(admin_token),
    )
    assert refused.status_code == 403, refused.text
    assert "cannot approve or reject" in refused.json()["detail"].lower()
