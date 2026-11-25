from types import SimpleNamespace
from unittest.mock import Mock
from uuid import uuid4

import pytest
from fastapi import HTTPException

from sitewise.api.v1 import agent_only_flow, properties
from sitewise.services import agent_inspection_policy


@pytest.fixture
def listing():
    return {
        "name": "Example shoplot",
        "property_type": "Shoplot",
        "address": "12 Jalan Contoh",
        "city": "Cheras",
        "state": "Selangor",
        "postcode": "43200",
        "rental_price": 2500,
        "size_sqft": 1200,
        "verification_status": "draft",
        "is_published": False,
    }


def test_published_listing_cannot_create_agent_request(monkeypatch, listing):
    listing["is_published"] = True
    monkeypatch.setattr(agent_only_flow, "_owner_property", lambda *args: listing)
    profile_lookup = Mock()
    monkeypatch.setattr(agent_only_flow, "_agent_profile", profile_lookup)
    session = Mock()

    with pytest.raises(HTTPException) as exc:
        agent_only_flow.request_agent(
            10, agent_only_flow.AgentRequest(agent_user_id=uuid4()), session,
            SimpleNamespace(user_id=uuid4()),
        )

    assert exc.value.status_code == 409
    assert "published" in exc.value.detail
    profile_lookup.assert_not_called()
    session.execute.assert_not_called()
    session.commit.assert_not_called()


def test_complete_listing_can_request_agent_with_optional_fields_absent(monkeypatch, listing):
    monkeypatch.setattr(agent_only_flow, "_owner_property", lambda *args, **kwargs: listing)
    monkeypatch.setattr(agent_only_flow, "_agent_profile", lambda *args: {
        "agent_id": 12, "display_name": "Agent",
    })
    monkeypatch.setattr(agent_only_flow, "require_submitted_ownership_proof", Mock())
    session = Mock()
    session.execute.return_value.scalar.return_value = None
    session.execute.return_value.mappings.return_value.first.return_value = None

    result = agent_only_flow.request_agent(
        10, agent_only_flow.AgentRequest(agent_user_id=uuid4()), session,
        SimpleNamespace(user_id=uuid4()),
    )

    assert result["data"]["assignment_status"] == "requested"
    session.commit.assert_called_once_with()


def test_owner_cannot_clear_required_details_during_active_request(monkeypatch, listing):
    monkeypatch.setattr(properties, "_owned_listing_or_error", lambda *args, **kwargs: listing)
    monkeypatch.setattr(
        "sitewise.services.property_verification_service.verification_row", lambda *args: None,
    )
    session = Mock()
    session.execute.return_value.scalar.return_value = True
    owner = SimpleNamespace(user_id=uuid4(), role="owner")

    with pytest.raises(HTTPException) as exc:
        properties.update_own_listing(10, properties.OwnerDraftRequest(postcode=None), session, owner)

    assert exc.value.status_code == 409
    assert "postcode" in exc.value.detail
    session.execute.assert_called_once()
    session.commit.assert_not_called()


@pytest.mark.parametrize("all_confirmed", [True, False])
def test_inspection_gate_requires_confirmations_and_allows_blank_notes(monkeypatch, all_confirmed, listing):
    checklist = agent_only_flow.InspectionInput(
        floor_area_verified=True,
        condition_verified=True,
        parking_verified=True,
        accessibility_verified=all_confirmed,
    ).model_dump()
    assert checklist["observed_floor_area_sqft"] is None
    assert checklist["condition_notes"] == checklist["parking_notes"] == checklist["accessibility_notes"] == ""
    assignment = {
        "inspection_data": checklist, "inspection_updated_at": "saved",
        "workflow_status": "accepted",
    }
    for module in (agent_inspection_policy, agent_only_flow):
        monkeypatch.setattr(module, "agent_assignment", lambda *args, **kwargs: assignment)
    monkeypatch.setattr(agent_only_flow, "rental_listing", lambda *args: listing)
    panorama_id = str(uuid4())
    monkeypatch.setattr(
        agent_inspection_policy, "completed_agent_panorama", lambda *args: panorama_id,
    )
    monkeypatch.setattr(agent_only_flow, "completed_agent_panorama", lambda *args: panorama_id)
    monkeypatch.setattr(
        "sitewise.api.v1.agent_only_flow.guard_enrichment_before_submit", Mock(),
    )
    submit = Mock(return_value={})
    monkeypatch.setattr(agent_only_flow.PropertyVerificationService, "submit", submit)
    session = Mock()
    monkeypatch.setattr(agent_inspection_policy, "ownership_proof_state", lambda *a: (True, 1))
    monkeypatch.setattr(agent_inspection_policy, "ownership_submission_status", lambda *a: "pending")
    session.execute.return_value.scalars.return_value.all.return_value = []
    session.execute.return_value.all.return_value = []
    agent = SimpleNamespace(user_id=uuid4(), role="agent")

    if all_confirmed:
        result = agent_only_flow.submit_verified_property(10, session, agent)
        assert result["stage"] == "pending_admin_review"
        submit.assert_called_once_with(
            10, agent.user_id, scope="listing", role="agent", panorama_id=panorama_id,
        )
    else:
        with pytest.raises(HTTPException) as error:
            agent_only_flow.submit_verified_property(10, session, agent)
        assert error.value.status_code == 409
        assert any("access / entrance" in item for item in error.value.detail["blockers"])
        submit.assert_not_called()
