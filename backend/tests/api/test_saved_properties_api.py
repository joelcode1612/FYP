"""Saved-properties API behaviour.

Covers the guarantees the web shortlist depends on:

* saving requires authentication and is scoped to the token's account
* a save is really persisted (re-read through a second request)
* saving the same property twice keeps one row (no duplicates)
* a ref that is not in the catalogue is refused and writes nothing
* removal deletes the row; removing an absent ref is a 404
* refs that no longer resolve against the catalogue are reported as
  ``unresolved`` rather than silently dropped (delisted properties)
* one account cannot read another account's list

The catalogue rows come from the real imported dataset, so a catalogue id is
read from the database rather than invented here.
"""

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def identity(client, cleanup_users):
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub,
        email=f"saved-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Saved Tester"},
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
        email=f"saved-other-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Other Tester"},
    )
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    register_user_id(cleanup_users, uuid.UUID(sub))
    return {"token": token, "user_id": uuid.UUID(sub)}


@pytest.fixture(autouse=True)
def cleanup_favourites(cleanup_users):
    """Delete this test's favourite rows before its user rows are removed."""
    yield
    if not cleanup_users:
        return
    with Session(engine) as session:
        session.execute(
            text("DELETE FROM favorite_property WHERE user_id = ANY(:ids)"),
            {"ids": list(cleanup_users)},
        )
        session.commit()


@pytest.fixture()
def catalogue_ref():
    """A real catalogue id — the endpoint must accept what the app displays."""
    with Session(engine) as session:
        row = session.execute(
            text("SELECT id FROM sitewise_app.properties ORDER BY id LIMIT 1")
        ).scalar()
    assert row
    return row


def test_saved_requires_authentication(client):
    assert client.get("/api/v1/saved-properties/me").status_code == 401
    r = client.post(
        "/api/v1/saved-properties/",
        json={"property_ref": "EP-01051"},
    )
    assert r.status_code == 401


def test_saving_a_catalogue_property_persists_it(client, identity, catalogue_ref):
    r = client.post(
        "/api/v1/saved-properties/",
        json={"property_ref": catalogue_ref},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 201, r.text
    assert r.json()["property_ref"] == catalogue_ref

    listing = client.get("/api/v1/saved-properties/me", headers=auth(identity["token"]))
    assert listing.status_code == 200
    body = listing.json()
    assert [row["property_ref"] for row in body["saved"]] == [catalogue_ref]
    assert body["unresolved"] == []


def test_saving_twice_keeps_one_row(client, identity, catalogue_ref):
    headers = auth(identity["token"])
    first = client.post(
        "/api/v1/saved-properties/", json={"property_ref": catalogue_ref}, headers=headers
    )
    second = client.post(
        "/api/v1/saved-properties/", json={"property_ref": catalogue_ref}, headers=headers
    )
    assert first.status_code == 201
    assert second.status_code == 200
    assert first.json()["favorite_id"] == second.json()["favorite_id"]

    listing = client.get("/api/v1/saved-properties/me", headers=headers)
    assert len(listing.json()["saved"]) == 1


def test_unknown_property_ref_is_refused_and_writes_nothing(client, identity):
    r = client.post(
        "/api/v1/saved-properties/",
        json={"property_ref": "NO-SUCH-CATALOGUE-ID"},
        headers=auth(identity["token"]),
    )
    assert r.status_code == 404
    listing = client.get("/api/v1/saved-properties/me", headers=auth(identity["token"]))
    assert listing.json()["saved"] == []


def test_removing_a_saved_property_deletes_it(client, identity, catalogue_ref):
    headers = auth(identity["token"])
    assert (
        client.post(
            "/api/v1/saved-properties/",
            json={"property_ref": catalogue_ref},
            headers=headers,
        ).status_code
        == 201
    )
    assert (
        client.delete(f"/api/v1/saved-properties/me/{catalogue_ref}", headers=headers).status_code
        == 204
    )
    listing = client.get("/api/v1/saved-properties/me", headers=headers)
    assert listing.json()["saved"] == []
    assert (
        client.delete(f"/api/v1/saved-properties/me/{catalogue_ref}", headers=headers).status_code
        == 404
    )


def test_delisted_refs_are_reported_as_unresolved(client, identity, cleanup_favourites):
    """A row whose ref left the catalogue is reported, not hidden or pruned."""
    with Session(engine) as session:
        session.execute(
            text(
                "INSERT INTO favorite_property (favorite_id, user_id, property_id, created_at)"
                " VALUES (:fid, :uid, 'GONE-DELISTED-1', now())"
            ),
            {"fid": uuid.uuid4(), "uid": identity["user_id"]},
        )
        session.commit()

    listing = client.get("/api/v1/saved-properties/me", headers=auth(identity["token"]))
    body = listing.json()
    assert body["unresolved"] == ["GONE-DELISTED-1"]
    assert [row["property_ref"] for row in body["saved"]] == ["GONE-DELISTED-1"]


def test_saved_lists_are_scoped_to_the_authenticated_user(
    client, identity, other_identity, catalogue_ref
):
    assert (
        client.post(
            "/api/v1/saved-properties/",
            json={"property_ref": catalogue_ref},
            headers=auth(identity["token"]),
        ).status_code
        == 201
    )
    other = client.get("/api/v1/saved-properties/me", headers=auth(other_identity["token"]))
    assert other.json()["saved"] == []
    cross = client.get(
        f"/api/v1/saved-properties/user/{identity['user_id']}",
        headers=auth(other_identity["token"]),
    )
    assert cross.status_code == 403


def test_admin_can_read_another_accounts_list(client, cleanup_users, catalogue_ref):
    """Administrators may read any list; ordinary users may not (403 above)."""
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"saved-admin-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.repositories.user_repository import UserRepository

    with Session(engine) as session:
        repo = UserRepository(session)
        repo.get_or_create_from_supabase(user_id=sub, email=email, email_verified=True)
        repo.update(sub, {"role": "admin", "account_status": "active"})
    admin_token = make_token(
        sub=str(sub), email=email, aal="aal2", amr=[{"method": "password"}, {"method": "totp"}]
    )

    owner_sub = str(uuid.uuid4())
    owner_token = make_token(
        sub=owner_sub,
        email=f"saved-owner-{owner_sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Owner Tester"},
    )
    assert client.get("/api/v1/auth/me", headers=auth(owner_token)).status_code == 200
    register_user_id(cleanup_users, uuid.UUID(owner_sub))
    assert (
        client.post(
            "/api/v1/saved-properties/",
            json={"property_ref": catalogue_ref},
            headers=auth(owner_token),
        ).status_code
        == 201
    )

    r = client.get(f"/api/v1/saved-properties/user/{owner_sub}", headers=auth(admin_token))
    assert r.status_code == 200
    assert [row["property_id"] for row in r.json()] == [catalogue_ref]
