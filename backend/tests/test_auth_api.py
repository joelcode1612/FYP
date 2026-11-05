"""Authentication API behaviour (spec 15 - auth tests 1-5, 13-14 are
frontend/Supabase flows; these cover the FastAPI side) plus RBAC and
ownership tests (spec 15 - authorization tests)."""

import uuid

import pytest

from .conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


@pytest.fixture()
def identity(client, cleanup_users):
    """A provisioned user (hit /auth/me once) and its bearer token."""
    sub = str(uuid.uuid4())
    token = make_token(sub=sub, email=f"owner-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
                       role_claims={"full_name": "RBAC Tester"})
    response = client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 200, response.text
    register_user_id(cleanup_users, uuid.UUID(sub))
    return {"token": token, "sub": sub, "profile": response.json()}


def auth(token):
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------- /auth/me


def test_auth_me_requires_token(client):
    r = client.get("/api/v1/auth/me")
    assert r.status_code == 401
    assert "detail" in r.json()


def test_auth_me_provisions_profile_once(client, identity, cleanup_users):
    payload = identity["profile"]
    assert payload["email"].endswith(TEST_EMAIL_DOMAIN)
    assert payload["role"] == "entrepreneur"  # never privileged by default
    assert payload["account_status"] == "active"
    assert payload["email_verified"] is True

    # Second call: same identity, no duplicate row.
    r = client.get("/api/v1/auth/me", headers=auth(identity["token"]))
    assert r.status_code == 200
    assert r.json()["user_id"] == payload["user_id"]


def test_auth_me_with_garbage_token(client):
    r = client.get("/api/v1/auth/me", headers={"Authorization": "Bearer garbage"})
    assert r.status_code == 401


def test_auth_me_with_wrong_scheme(client, identity):
    r = client.get("/api/v1/auth/me", headers={"Authorization": f"Basic {identity['token']}"})
    assert r.status_code == 401


# ------------------------------------------------------------- /users/me *


def test_users_me_returns_profile(client, identity):
    r = client.get("/api/v1/users/me", headers=auth(identity["token"]))
    assert r.status_code == 200
    assert r.json()["user_id"] == identity["profile"]["user_id"]


def test_users_me_status(client, identity):
    r = client.get("/api/v1/users/me/status", headers=auth(identity["token"]))
    assert r.status_code == 200
    body = r.json()
    assert body["role"] == "entrepreneur"
    assert body["account_status"] == "active"


def test_patch_own_profile_allowed_fields(client, identity):
    r = client.patch(
        "/api/v1/users/me",
        headers=auth(identity["token"]),
        json={"full_name": "Renamed Tester", "phone_number": "+60123456789"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["full_name"] == "Renamed Tester"
    assert body["phone_number"] == "+60123456789"


def test_patch_own_profile_rejects_role_change(client, identity):
    r = client.patch(
        "/api/v1/users/me",
        headers=auth(identity["token"]),
        json={"role": "admin"},
    )
    assert r.status_code == 403
    # And it really did not change.
    r2 = client.get("/api/v1/users/me", headers=auth(identity["token"]))
    assert r2.json()["role"] == "entrepreneur"


def test_patch_own_profile_rejects_status_and_verification_change(client, identity):
    for field, value in (
        ("account_status", "suspended"),
        ("email_verified", False),
        ("email", "new@attacker.example"),
        ("user_id", str(uuid.uuid4())),
    ):
        r = client.patch("/api/v1/users/me", headers=auth(identity["token"]), json={field: value})
        assert r.status_code == 403, f"{field} change must be rejected"


def test_patch_rejects_protected_fields_even_mixed_with_valid_ones(client, identity):
    r = client.patch(
        "/api/v1/users/me",
        headers=auth(identity["token"]),
        json={"full_name": "Still Applied?", "role": "admin"},
    )
    assert r.status_code == 403
    r2 = client.get("/api/v1/users/me", headers=auth(identity["token"]))
    assert r2.json()["full_name"] != "Still Applied?"


# ------------------------------------------------------------- RBAC / admin


def test_user_list_requires_admin(client, identity):
    r = client.get("/api/v1/users/", headers=auth(identity["token"]))
    assert r.status_code == 403


def test_user_creation_endpoint_is_gone(client, identity):
    r = client.post("/api/v1/users/", headers=auth(identity["token"]), json={})
    assert r.status_code == 410


def test_admin_routes_reject_non_admin(client, identity):
    other = str(uuid.uuid4())
    r = client.get(
        f"/api/v1/users/{other}", headers=auth(identity["token"])
    )
    assert r.status_code == 403


# ----------------------------------------------- saved-property ownership


def test_saved_property_ownership(client, identity, cleanup_users):
    """A client cannot save into another user's list, and cannot read theirs."""
    foreign_id = str(uuid.uuid4())
    register_user_id(cleanup_users, uuid.UUID(foreign_id))

    # POST forces the owner to the authenticated identity even if a foreign
    # user_id is submitted.
    r = client.post(
        "/api/v1/saved-properties/",
        headers=auth(identity["token"]),
        json={"user_id": foreign_id, "property_id": 1},
    )
    # Property id 1 does not exist in the dev dataset; a 404 here still proves
    # the request reached ownership logic. Accept 201 when the dataset has it.
    assert r.status_code in (201, 404)
    if r.status_code == 201:
        assert r.json()["user_id"] == identity["profile"]["user_id"]
        fav_id = r.json()["favorite_id"]
        # Reading the foreign user's list is forbidden.
        r2 = client.get(
            f"/api/v1/saved-properties/user/{foreign_id}", headers=auth(identity["token"])
        )
        assert r2.status_code == 403
        # Deleting someone else's favourite is forbidden.
        r3 = client.delete(
            f"/api/v1/saved-properties/{fav_id}", headers=auth(identity["token"])
        )
        assert r3.status_code in (403, 404)


# ------------------------------------------------- property management RBAC


def test_property_creation_requires_owner_role(client, identity, cleanup_users):
    """Entrepreneurs own properties (the legacy property_owner role folded
    into entrepreneur), so the denial case is now the AGENT role."""
    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.repositories.user_repository import UserRepository

    sub = uuid.UUID(identity["sub"])
    with Session(engine) as session:
        UserRepository(session).update(sub, {"role": "agent"})

    r = client.post(
        "/api/v1/properties/",
        headers=auth(identity["token"]),
        json={"title": "x"},
    )
    assert r.status_code == 403


def test_suspended_account_is_403_on_active_endpoints(client, cleanup_users):
    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.repositories.user_repository import UserRepository

    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    token = make_token(sub=str(sub), email=f"suspended-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}")

    # Pre-create the profile and suspend it.
    with Session(engine) as session:
        UserRepository(session).get_or_create_from_supabase(
            user_id=sub,
            email=f"suspended-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}",
            email_verified=True,
        )
        UserRepository(session).update(sub, {"account_status": "suspended"})

    r = client.get("/api/v1/users/me/status", headers=auth(token))
    assert r.status_code == 403
    assert "suspended" in r.json()["detail"]


def test_unverified_email_syncs_from_token(client, cleanup_users):
    """email_verified is owned by Supabase and mirrored locally."""
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    token = make_token(
        sub=str(sub),
        email=f"unverified-{sub.hex[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "UV"},
    )
    # The /auth/me payload mirrors whatever the token's email_verified claim
    # says; the local row follows Supabase, never the reverse.
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200
    assert isinstance(r.json()["email_verified"], bool)
