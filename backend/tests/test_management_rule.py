"""Management derivation: the four-step hierarchy and the live-data invariants.

The rule is pure, so most of this file runs without a database. The final class
reads the operational database read-only and asserts the invariants that must
hold for EVERY property, rather than pinning counts that legitimate assignment
work is allowed to change.
"""

from __future__ import annotations

import pytest
from sqlalchemy import create_engine, text
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.domain.management import (
    LABEL_AGENT,
    LABEL_PLATFORM_DEMO,
    LABEL_PLATFORM_RESEARCH,
    LABEL_UNRESOLVED,
    REASON_AGENT_INACTIVE,
    REASON_AGENT_PROFILE_MISSING,
    REASON_NO_STEWARDSHIP,
    TYPE_AGENT,
    TYPE_OWNER,
    TYPE_PLATFORM,
    TYPE_UNRESOLVED,
    ManagementFacts,
    derive,
    derive_provenance,
    unavailable,
)


def facts(**overrides) -> ManagementFacts:
    base = {"property_id": 1, "provenance": "owner_draft"}
    base.update(overrides)
    return ManagementFacts(**base)


class TestAgentManaged:
    def test_active_assigned_agent_is_the_manager(self):
        result = derive(
            facts(
                provenance="demo_seed",
                agent_id=2,
                agent_display_name="Joel Personal",
                agent_account_status="active",
            )
        )
        assert result["type"] == TYPE_AGENT
        assert result["label"] == LABEL_AGENT
        assert result["manager_name"] == "Joel Personal"
        assert result["name"] == "Joel Personal"  # compatibility alias
        assert result["agent_id"] == 2
        assert result["assignment_status"] == "active"

    def test_agent_takes_precedence_over_owner_but_owner_is_preserved(self):
        result = derive(
            facts(
                provenance="owner_draft",
                owner_user_id="11111111-1111-1111-1111-111111111111",
                owner_display_name="Nur Aisyah",
                owner_account_status="active",
                agent_id=3,
                agent_display_name="Joel",
                agent_account_status="active",
            )
        )
        assert result["type"] == TYPE_AGENT
        assert result["agent_id"] == 3
        # Management does not transfer ownership.
        assert result["owner_user_id"] == "11111111-1111-1111-1111-111111111111"
        assert result["ownership_status"] == "verified"

    def test_assignment_to_suspended_agent_is_unresolved_not_a_manager(self):
        result = derive(
            facts(
                provenance="demo_seed",
                agent_id=2,
                agent_display_name="Joel Personal",
                agent_account_status="suspended",
            )
        )
        assert result["type"] == TYPE_UNRESOLVED
        assert result["manager_name"] is None
        assert result["reason"] == REASON_AGENT_INACTIVE
        assert result["assignment_status"] == "agent_inactive"

    def test_assignment_without_a_verified_profile_is_unresolved(self):
        result = derive(
            facts(
                provenance="demo_seed",
                agent_id=9,
                agent_display_name=None,
                agent_account_status=None,
            )
        )
        assert result["type"] == TYPE_UNRESOLVED
        assert result["reason"] == REASON_AGENT_PROFILE_MISSING


class TestOwnerManaged:
    def test_active_owner_manages_their_own_listing(self):
        result = derive(
            facts(
                owner_user_id="22222222-2222-2222-2222-222222222222",
                owner_display_name="Tan Wei Ming",
                owner_account_status="active",
            )
        )
        assert result["type"] == TYPE_OWNER
        assert result["manager_name"] == "Tan Wei Ming"
        assert result["agent_id"] is None
        assert result["ownership_status"] == "verified"

    def test_active_owner_without_a_name_is_not_given_a_made_up_one(self):
        result = derive(
            facts(
                owner_user_id="33333333-3333-3333-3333-333333333333",
                owner_display_name="   ",
                owner_account_status="active",
            )
        )
        assert result["type"] == TYPE_UNRESOLVED
        assert result["manager_name"] is None
        assert result["reason"] == "owner_display_name_unavailable"


class TestPlatformManaged:
    def test_research_import_is_catalogue_stewardship_not_a_person(self):
        result = derive(facts(provenance="research_import"))
        assert result["type"] == TYPE_PLATFORM
        assert result["label"] == LABEL_PLATFORM_RESEARCH
        assert result["manager_name"] is None
        assert result["steward_role"] == "catalogue_administrator"
        assert result["ownership_status"] == "unclaimed"

    def test_legacy_demo_listing_is_platform_managed_not_owned(self):
        result = derive(facts(provenance="demo_seed", legacy_owner_id=8))
        assert result["type"] == TYPE_PLATFORM
        assert result["label"] == LABEL_PLATFORM_DEMO
        assert result["ownership_status"] == "legacy_unverified"
        # The legacy integer is provenance, never promoted to an owner UUID.
        assert result["owner_user_id"] is None

    def test_suspended_owner_falls_back_to_stewardship(self):
        result = derive(
            facts(
                provenance="research_import",
                owner_user_id="44444444-4444-4444-4444-444444444444",
                owner_display_name="Suspended Owner",
                owner_account_status="suspended",
            )
        )
        assert result["type"] == TYPE_PLATFORM
        assert result["ownership_status"] == "unverified"


class TestUnresolved:
    def test_ownerless_draft_is_a_defect_not_stewardship(self):
        result = derive(facts(provenance="owner_draft"))
        assert result["type"] == TYPE_UNRESOLVED
        assert result["label"] == LABEL_UNRESOLVED
        assert result["reason"] == REASON_NO_STEWARDSHIP

    def test_lookup_failure_is_explicit_and_never_a_manager(self):
        result = unavailable()
        assert result["type"] == "unavailable"
        assert result["status"] == "unavailable"
        assert result["manager_name"] is None
        assert result["reason"] == "management_lookup_failed"


class TestProvenance:
    @pytest.mark.parametrize(
        ("listing_id", "expected"),
        [
            ("MD-00510", "research_import"),
            ("EP-03341", "research_import"),
            ("501493880", "demo_seed"),
            (None, "owner_draft"),
            ("XYZ", "other"),
        ],
    )
    def test_provenance_follows_the_external_reference(self, listing_id, expected):
        assert derive_provenance(listing_id) == expected


@pytest.fixture(scope="module")
def live_session():
    engine = create_engine(settings.database_url)
    with Session(engine) as session:
        session.execute(text("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY"))
        yield session


class TestLiveInvariants:
    """Every operational property must have exactly one defined management state."""

    @pytest.fixture()
    def session(self, live_session):
        return live_session

    def test_every_property_resolves_to_a_valid_type(self, session):
        from sitewise.services.property_management_service import resolve_listings

        ids = [
            int(r[0])
            for r in session.execute(text("SELECT id FROM fyp.rental_properties"))
        ]
        assert ids, "the operational property table must not be empty"
        resolved = resolve_listings(session, ids)
        assert len(resolved) == len(ids)
        valid = {TYPE_AGENT, TYPE_OWNER, TYPE_PLATFORM, TYPE_UNRESOLVED, "unavailable"}
        bad = {pid: m["type"] for pid, m in resolved.items() if m["type"] not in valid}
        assert not bad, f"properties without a defined management state: {bad}"

    def test_research_imports_are_never_given_a_person(self, session):
        from sitewise.services.property_management_service import resolve_listings

        rows = session.execute(
            text(
                "SELECT id FROM fyp.rental_properties "
                "WHERE listing_id ~ '^(MD|EP)-'"
            )
        ).scalars().all()
        resolved = resolve_listings(session, [int(r) for r in rows])
        offenders = {
            pid: m
            for pid, m in resolved.items()
            if m["type"] in (TYPE_AGENT, TYPE_OWNER) or m["manager_name"] is not None
        }
        assert not offenders, f"research imports were given a manager: {offenders}"
        assert all(m["type"] == TYPE_PLATFORM for m in resolved.values())

    def test_owner_drafts_without_an_owner_are_unresolved(self, session):
        from sitewise.services.property_management_service import resolve_listings

        rows = session.execute(
            text(
                "SELECT id FROM fyp.rental_properties "
                "WHERE listing_id IS NULL AND owner_user_id IS NULL"
            )
        ).scalars().all()
        if not rows:
            pytest.skip("no ownerless drafts present")
        resolved = resolve_listings(session, [int(r) for r in rows])
        assert all(m["type"] == TYPE_UNRESOLVED for m in resolved.values())
        assert all(m["reason"] for m in resolved.values())

    def test_no_property_reports_a_manager_without_a_reason_or_identity(self, session):
        from sitewise.services.property_management_service import resolve_listings

        rows = session.execute(text("SELECT id FROM fyp.rental_properties")).scalars().all()
        resolved = resolve_listings(session, [int(r) for r in rows])
        for pid, m in resolved.items():
            if m["type"] in (TYPE_AGENT, TYPE_OWNER):
                assert m["manager_name"], f"property {pid} claims a manager with no name"
            else:
                assert m["reason"], f"property {pid} has no type and no reason"
