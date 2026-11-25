from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from sqlalchemy import create_engine, text
from sqlmodel import Session

from sitewise.services import agent_inspection_policy as policy
from sitewise.services.property_verification_service import (
    REQUIRED_FOR_SUBMISSION,
    listing_completeness_errors,
)


def test_capture_before_checklist_can_be_submitted(monkeypatch):
    agent = SimpleNamespace(user_id="agent-a")
    checklist = dict.fromkeys(policy.REQUIRED_INSPECTION, False)
    assignment = {"inspection_data": checklist, "inspection_updated_at": None}
    monkeypatch.setattr(policy, "agent_assignment", lambda *args, **kwargs: assignment)
    monkeypatch.setattr(policy, "require_submitted_ownership_proof", lambda *args: None)

    with Session(create_engine("sqlite://")) as session:
        session.connection().connection.driver_connection.create_function(
            "btrim", 1, str.strip
        )
        session.execute(text("ATTACH DATABASE ':memory:' AS fyp"))
        for statement in (
            "CREATE TABLE fyp.panoramas (panorama_id, session_id, property_id, created_at, storage_path, verification_status)",
            "CREATE TABLE fyp.capture_sessions (id, property_id, owner_id, status)",
            "CREATE TABLE fyp.agent_listing_assignment (listing_id, workflow_status, inspection_updated_at, inspection_data)",
            "INSERT INTO fyp.agent_listing_assignment VALUES (42, 'accepted', NULL, '{}')",
            "INSERT INTO fyp.capture_sessions VALUES ('session-a', '42', 'agent-a', 'completed')",
            "INSERT INTO fyp.panoramas VALUES ('tour-a', 'session-a', '42', '2026-11-22', 'tour.jpg', 'pending')",
        ):
            session.execute(text(statement))

        assert policy.completed_agent_panorama(session, 42, agent) == "tour-a"
        with pytest.raises(HTTPException, match="Save the four"):
            policy.require_ready_for_admin(session, 42, agent)

        checklist.update(dict.fromkeys(policy.REQUIRED_INSPECTION, True))
        assignment["inspection_updated_at"] = "2026-11-23"
        session.execute(text("""
            UPDATE fyp.agent_listing_assignment
            SET inspection_updated_at = '2026-11-23'
        """))
        assert policy.require_ready_for_admin(session, 42, agent)[
            "completed_panorama_id"
        ] == "tour-a"
        assert policy.completed_agent_panorama(
            session, 42, SimpleNamespace(user_id="agent-b")
        ) is None


def test_missing_availability_does_not_block_agent_inspection():
    listing = dict.fromkeys(REQUIRED_FOR_SUBMISSION, 1)
    listing["availability"] = None
    assert listing_completeness_errors(listing) == ["availability"]
    assert listing_completeness_errors(listing, require_availability=False) == []

    listing["address"] = ""
    assert listing_completeness_errors(listing, require_availability=False) == [
        "address"
    ]
