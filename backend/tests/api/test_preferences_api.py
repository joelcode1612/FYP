"""Entrepreneur preferences API behaviour.

Covers the guarantees the web preferences page depends on:

* an unsaved account is an empty state, not an error and not invented defaults
* a save is really persisted (re-read through a second request)
* one row per entrepreneur, however many times they save
* a partial save merges over what is stored rather than blanking it
* an invalid save is refused and writes nothing
* preferences are scoped to the authenticated user

The stored payload is asserted against ``validate_requirements`` so a tightening
of the assessment's rules can never leave preferences the workspace refuses to
load.
"""

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.services.assessment_service import validate_requirements

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def identity(client, cleanup_users):
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub,
        email=f"prefs-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Preferences Tester"},
    )
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    register_user_id(cleanup_users, uuid.UUID(sub))
    return {"token": token, "user_id": uuid.UUID(sub)}


@pytest.fixture()
def other_identity(client, cleanup_users):
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub,
        email=f"prefs-other-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Other Tester"},
    )
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    register_user_id(cleanup_users, uuid.UUID(sub))
    return {"token": token, "user_id": uuid.UUID(sub)}


@pytest.fixture(autouse=True)
def cleanup_preferences(cleanup_users):
    """Delete this test's preference rows before its user rows are removed.

    Requesting ``cleanup_users`` pins the teardown order: preferences first,
    then users, so the foreign key is never violated.
    """
    yield
    if not cleanup_users:
        return
    with Session(engine) as session:
        session.execute(
            text("DELETE FROM entrepreneur_preferences WHERE user_id = ANY(:ids)"),
            {"ids": list(cleanup_users)},
        )
        session.commit()


VALID_PREFERENCES = {
    "business_type": "Specialty coffee",
    "property_type": "Shop lot",
    "target_market": "Office workers",
    "seating_model": "Dine-in",
    "min_budget_rm": 2000,
    "max_budget_rm": 9000,
    "min_size_sqft": 500,
    "max_size_sqft": 2200,
    "requirements": ["Halal kitchen"],
    "preferred_areas": ["Petaling Jaya"],
}


def _row_count(user_id):
    with Session(engine) as session:
        return int(
            session.execute(
                text("SELECT count(*) FROM entrepreneur_preferences WHERE user_id = :uid"),
                {"uid": user_id},
            ).scalar_one()
        )


# ------------------------------------------------------------------ auth


def test_preferences_requires_authentication(client):
    assert client.get("/api/v1/preferences/me").status_code == 401
    assert (
        client.patch("/api/v1/preferences/me", json={"preferences": VALID_PREFERENCES}).status_code
        == 401
    )


# ------------------------------------------------------------- empty state


def test_unsaved_preferences_is_an_empty_state_not_an_error(client, identity):
    """No record must not be reported as a zeroed-out set of criteria.

    A null payload with ``saved: false`` lets the form show its own defaults;
    a fabricated ``{min_budget_rm: 0, ...}`` would claim the server holds values
    it has never been given.
    """
    r = client.get("/api/v1/preferences/me", headers=auth(identity["token"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["saved"] is False
    assert body["preferences"] is None
    assert body["updated_at"] is None
    assert _row_count(identity["user_id"]) == 0


# ------------------------------------------------------------ persistence


def test_saving_preferences_persists_them(client, identity):
    saved = client.patch(
        "/api/v1/preferences/me",
        json={"preferences": VALID_PREFERENCES},
        headers=auth(identity["token"]),
    )
    assert saved.status_code == 200, saved.text
    body = saved.json()
    assert body["saved"] is True
    assert body["updated_at"] is not None
    assert body["preferences"]["business_type"] == "Specialty coffee"
    assert body["preferences"]["max_budget_rm"] == 9000

    # A second request re-reads the database rather than an in-memory copy.
    reread = client.get("/api/v1/preferences/me", headers=auth(identity["token"]))
    assert reread.json()["preferences"] == body["preferences"]
    assert _row_count(identity["user_id"]) == 1


def test_repeated_saves_update_one_row(client, identity):
    """Saving twice must not leave a second record behind.

    The table has no unique constraint on ``user_id``, so the repository is what
    keeps one row per entrepreneur; this is the assertion that would catch a
    regression to insert-always.
    """
    for budget in (9000, 12000):
        r = client.patch(
            "/api/v1/preferences/me",
            json={"preferences": {**VALID_PREFERENCES, "max_budget_rm": budget}},
            headers=auth(identity["token"]),
        )
        assert r.status_code == 200, r.text
    assert _row_count(identity["user_id"]) == 1
    stored = client.get("/api/v1/preferences/me", headers=auth(identity["token"])).json()
    assert stored["preferences"]["max_budget_rm"] == 12000


def test_partial_save_merges_over_what_is_stored(client, identity):
    client.patch(
        "/api/v1/preferences/me",
        json={"preferences": VALID_PREFERENCES},
        headers=auth(identity["token"]),
    )
    partial = client.patch(
        "/api/v1/preferences/me",
        json={"preferences": {"target_market": "Students"}},
        headers=auth(identity["token"]),
    )
    assert partial.status_code == 200, partial.text
    stored = partial.json()["preferences"]
    assert stored["target_market"] == "Students"
    # Untouched fields keep their stored values instead of being blanked.
    assert stored["business_type"] == "Specialty coffee"
    assert stored["property_type"] == "Shop lot"
    assert stored["max_budget_rm"] == 9000
    assert stored["preferred_areas"] == ["Petaling Jaya"]


def test_stored_preferences_stay_loadable_by_the_assessment_stage(client, identity):
    """One vocabulary, so the workspace can seed its draft from these values.

    Re-validating what the server stored proves a tightened rule cannot leave
    preferences the business-requirements stage would refuse to read.
    """
    client.patch(
        "/api/v1/preferences/me",
        json={"preferences": VALID_PREFERENCES},
        headers=auth(identity["token"]),
    )
    stored = client.get("/api/v1/preferences/me", headers=auth(identity["token"])).json()
    assert validate_requirements(stored["preferences"]) == stored["preferences"]


# -------------------------------------------------------------- validation


def test_inverted_range_is_refused_and_writes_nothing(client, identity):
    client.patch(
        "/api/v1/preferences/me",
        json={"preferences": VALID_PREFERENCES},
        headers=auth(identity["token"]),
    )
    refused = client.patch(
        "/api/v1/preferences/me",
        json={"preferences": {"min_budget_rm": 20000}},
        headers=auth(identity["token"]),
    )
    assert refused.status_code == 422, refused.text
    assert "cannot exceed" in refused.json()["detail"]["message"]

    # The refusal left the stored criteria exactly as they were.
    stored = client.get("/api/v1/preferences/me", headers=auth(identity["token"])).json()
    assert stored["preferences"]["min_budget_rm"] == 2000
    assert _row_count(identity["user_id"]) == 1


def test_missing_required_fields_are_all_reported_at_once(client, identity):
    r = client.patch(
        "/api/v1/preferences/me",
        json={"preferences": {"target_market": "Office workers"}},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 422, r.text
    message = r.json()["detail"]["message"]
    assert "business_type is required" in message
    assert "property_type is required" in message
    assert "max_budget_rm is required" in message
    assert _row_count(identity["user_id"]) == 0


# --------------------------------------------------------------- ownership


def test_preferences_are_scoped_to_the_authenticated_user(client, identity, other_identity):
    client.patch(
        "/api/v1/preferences/me",
        json={"preferences": VALID_PREFERENCES},
        headers=auth(identity["token"]),
    )
    other = client.get("/api/v1/preferences/me", headers=auth(other_identity["token"]))
    assert other.status_code == 200, other.text
    assert other.json()["saved"] is False
    assert other.json()["preferences"] is None
    assert _row_count(other_identity["user_id"]) == 0
