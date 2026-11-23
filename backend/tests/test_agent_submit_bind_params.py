"""Regression tests for the Agent submission 500 caused by SQLAlchemy text().

A JSON literal such as ``'{"floor_area_verified":true}'`` contains ``:true``,
which ``sqlalchemy.text()`` parses as a bind parameter before the statement
ever reaches PostgreSQL. The real routes now bind the JSON object instead.
These tests execute the real functions with a recording session and assert
that every bind in every emitted statement is supplied.
"""
from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import Mock
from uuid import uuid4

from sitewise.api.v1 import agent_only_flow
from sitewise.services import property_verification_service as pvs
from sitewise.services.agent_inspection_policy import REQUIRED_INSPECTION


def _assert_all_binds_supplied(statement, params: dict) -> None:
    missing = sorted(set(statement.compile().params) - set(params))
    assert not missing, f"unbound SQL parameters: {missing}"


def test_agent_submission_binds_required_inspection_json(monkeypatch):
    captured: list[tuple[object, dict]] = []
    session = Mock()

    def execute(statement, params=None):
        captured.append((statement, params or {}))
        return SimpleNamespace(scalar=lambda: uuid4())

    session.execute.side_effect = execute

    listing = {
        "name": "Example shoplot",
        "property_type": "Shoplot",
        "address": "12 Jalan Contoh",
        "city": "Cheras",
        "state": "Selangor",
        "postcode": "43200",
        "rental_price": 2500,
        "size_sqft": 1200,
    }
    verification = SimpleNamespace(
        verification_id=uuid4(),
        listing_status="not_submitted",
        ownership_status="not_submitted",
        submitted_by=None,
        latest_note=None,
        publication_eligible=False,
        updated_at=None,
        version=1,
    )
    monkeypatch.setattr(
        pvs.PropertyVerificationService,
        "get_property_owned",
        lambda self, *args, **kwargs: listing,
    )
    monkeypatch.setattr(pvs, "verification_row", lambda *args: verification)
    monkeypatch.setattr(
        pvs, "verification_payload", lambda v: {"verification_id": str(v.verification_id)}
    )
    monkeypatch.setattr(
        pvs.FypPropertyRepository,
        "set_listing_verification_status",
        lambda self, *args, **kwargs: None,
    )

    panorama_id = str(uuid4())
    result = pvs.PropertyVerificationService(session).submit(
        11906,
        uuid4(),
        scope="listing",
        role="agent",
        panorama_id=panorama_id,
    )

    assert result["verification_id"] == str(verification.verification_id)
    assignment_update = next(
        (s, p) for s, p in captured if "agent_listing_assignment" in str(s)
    )
    statement, params = assignment_update
    _assert_all_binds_supplied(statement, params)
    assert "CAST(:required_checks AS jsonb)" in str(statement)
    assert json.loads(params["required_checks"]) == {
        key: True for key in REQUIRED_INSPECTION
    }
    assert params["panorama_id"] == panorama_id


def test_agent_details_completion_binds_check_reset_json(monkeypatch):
    captured: list[tuple[object, dict]] = []
    session = Mock()

    def execute(statement, params=None):
        captured.append((statement, params or {}))
        return SimpleNamespace(
            first=lambda: object(),
            scalar_one_or_none=lambda: "accepted",
            scalar=lambda: 1,
        )

    session.execute.side_effect = execute
    listing = {
        "name": "Example shoplot",
        "property_type": "Shoplot",
        "address": "12 Jalan Contoh",
        "city": "Cheras",
        "state": "Selangor",
        "postcode": None,
        "rental_price": 2500,
        "size_sqft": 1200,
    }
    monkeypatch.setattr(
        agent_only_flow,
        "agent_assignment",
        lambda *args, **kwargs: {"agent_id": 7, "workflow_status": "accepted"},
    )
    monkeypatch.setattr(agent_only_flow, "rental_listing", lambda *args: listing)
    monkeypatch.setattr(agent_only_flow, "_agent_missing_detail_view", lambda *args: {})

    agent_only_flow.complete_agent_missing_details(
        11906,
        agent_only_flow.AgentMissingDetails(postcode="43200"),
        session,
        SimpleNamespace(user_id=uuid4(), role="agent"),
    )

    reset_update = next(
        (s, p) for s, p in captured if "inspection_updated_at" in str(s)
    )
    statement, params = reset_update
    _assert_all_binds_supplied(statement, params)
    assert "CAST(:reset_checks AS jsonb)" in str(statement)
    assert json.loads(params["reset_checks"]) == {
        key: False for key in REQUIRED_INSPECTION
    }
