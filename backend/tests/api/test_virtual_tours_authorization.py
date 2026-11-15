"""Authorization coverage for virtual-tour read endpoints.

Virtual tours retain a legacy integer property id, so these tests exercise
the explicit ownership resolution against ``fyp.rental_properties`` rather
than relying on a database foreign key that no longer exists.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.models.virtual_tour import VirtualTour
from sitewise.db.session import engine
from sitewise.repositories.user_repository import UserRepository

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _entrepreneur(client, cleanup_users, *, prefix: str) -> dict[str, str]:
    sub = uuid.uuid4()
    token = make_token(
        sub=str(sub),
        email=f"{prefix}-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": prefix},
    )
    # This provisions the local profile from the verified identity and leaves
    # it in the default entrepreneur role.
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    register_user_id(cleanup_users, sub)
    return {"token": token, "sub": str(sub)}


@pytest.fixture()
def owner(client, cleanup_users):
    return _entrepreneur(client, cleanup_users, prefix="tour-owner")


@pytest.fixture()
def owner_listing(client, owner):
    response = client.post(
        "/api/v1/properties/listings/drafts",
        headers=auth(owner["token"]),
        json={"name": "Virtual tour listing"},
    )
    assert response.status_code == 201, response.text
    property_id = response.json()["data"]["id"]
    yield {**owner, "property_id": property_id}

    # The retired legacy FK means the application, rather than PostgreSQL,
    # owns this cleanup order.
    with Session(engine) as session:
        session.execute(
            text("DELETE FROM public.virtual_tour WHERE property_id = :pid"),
            {"pid": property_id},
        )
        session.execute(
            text("DELETE FROM fyp.rental_properties WHERE id = :pid"),
            {"pid": property_id},
        )
        session.commit()


@pytest.fixture()
def tour(owner_listing):
    row = VirtualTour(
        property_id=owner_listing["property_id"],
        url="https://example.test/tours/owner-tour",
        status="completed",
        created_at=datetime.now(UTC),
        updated_at=datetime.now(UTC),
    )
    with Session(engine) as session:
        session.add(row)
        session.commit()
        session.refresh(row)
        return {"tour_id": row.tour_id, "url": row.url}


@pytest.fixture()
def admin(cleanup_users):
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"tour-admin-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    with Session(engine) as session:
        repo = UserRepository(session)
        repo.get_or_create_from_supabase(user_id=sub, email=email, email_verified=True)
        repo.update(sub, {"role": "admin", "account_status": "active"})
    return {
        "token": make_token(
            sub=str(sub),
            email=email,
            aal="aal2",
            amr=[{"method": "password"}, {"method": "totp"}],
        )
    }


def test_tour_read_routes_require_authentication(client, owner_listing, tour):
    assert (
        client.get(f"/api/v1/virtual-tours/property/{owner_listing['property_id']}").status_code
        == 401
    )
    assert client.get(f"/api/v1/virtual-tours/{tour['tour_id']}").status_code == 401


def test_owner_can_read_own_property_tours(client, owner_listing, tour):
    listing = client.get(
        f"/api/v1/virtual-tours/property/{owner_listing['property_id']}",
        headers=auth(owner_listing["token"]),
    )
    assert listing.status_code == 200, listing.text
    assert [row["tour_id"] for row in listing.json()] == [str(tour["tour_id"])]

    detail = client.get(
        f"/api/v1/virtual-tours/{tour['tour_id']}",
        headers=auth(owner_listing["token"]),
    )
    assert detail.status_code == 200, detail.text
    assert detail.json()["url"] == tour["url"]


def test_other_owner_cannot_read_another_owners_tours(
    client, cleanup_users, owner_listing, tour
):
    foreign = _entrepreneur(client, cleanup_users, prefix="tour-foreign")

    listing = client.get(
        f"/api/v1/virtual-tours/property/{owner_listing['property_id']}",
        headers=auth(foreign["token"]),
    )
    assert listing.status_code == 403

    detail = client.get(
        f"/api/v1/virtual-tours/{tour['tour_id']}",
        headers=auth(foreign["token"]),
    )
    assert detail.status_code == 403


def test_admin_can_read_any_listing_tour(client, admin, owner_listing, tour):
    listing = client.get(
        f"/api/v1/virtual-tours/property/{owner_listing['property_id']}",
        headers=auth(admin["token"]),
    )
    assert listing.status_code == 200, listing.text

    detail = client.get(
        f"/api/v1/virtual-tours/{tour['tour_id']}",
        headers=auth(admin["token"]),
    )
    assert detail.status_code == 200, detail.text


def test_unlinked_legacy_property_id_is_not_readable(client, owner_listing):
    missing_property_id = 2_147_000_000
    row = VirtualTour(
        property_id=missing_property_id,
        url="https://example.test/tours/unlinked-tour",
        status="completed",
        created_at=datetime.now(UTC),
        updated_at=datetime.now(UTC),
    )
    with Session(engine) as session:
        session.add(row)
        session.commit()
        session.refresh(row)
        tour_id = row.tour_id

    try:
        listing = client.get(
            f"/api/v1/virtual-tours/property/{missing_property_id}",
            headers=auth(owner_listing["token"]),
        )
        assert listing.status_code == 404

        detail = client.get(
            f"/api/v1/virtual-tours/{tour_id}",
            headers=auth(owner_listing["token"]),
        )
        assert detail.status_code == 404
    finally:
        with Session(engine) as session:
            session.execute(
                text("DELETE FROM public.virtual_tour WHERE tour_id = :tour_id"),
                {"tour_id": tour_id},
            )
            session.commit()


def test_owner_can_create_and_update_own_tour(client, owner_listing):
    created = client.post(
        "/api/v1/virtual-tours/",
        headers=auth(owner_listing["token"]),
        json={
            "property_id": owner_listing["property_id"],
            "url": "https://example.test/tours/created-by-owner",
            "status": "draft",
        },
    )
    assert created.status_code == 201, created.text
    tour_id = created.json()["tour_id"]

    updated = client.patch(
        f"/api/v1/virtual-tours/{tour_id}",
        headers=auth(owner_listing["token"]),
        json={"status": "ready"},
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["status"] == "ready"


def test_virtual_tour_writes_are_owner_scoped_and_cannot_reassign(
    client, cleanup_users, owner_listing, tour
):
    foreign = _entrepreneur(client, cleanup_users, prefix="tour-writer")

    create = client.post(
        "/api/v1/virtual-tours/",
        headers=auth(foreign["token"]),
        json={
            "property_id": owner_listing["property_id"],
            "url": "https://example.test/tours/foreign-write",
            "status": "draft",
        },
    )
    assert create.status_code == 403

    update = client.patch(
        f"/api/v1/virtual-tours/{tour['tour_id']}",
        headers=auth(foreign["token"]),
        json={"status": "ready"},
    )
    assert update.status_code == 403

    delete = client.delete(
        f"/api/v1/virtual-tours/{tour['tour_id']}",
        headers=auth(foreign["token"]),
    )
    assert delete.status_code == 403

    reassign = client.patch(
        f"/api/v1/virtual-tours/{tour['tour_id']}",
        headers=auth(owner_listing["token"]),
        json={"property_id": 9},
    )
    assert reassign.status_code == 422

    still_there = client.get(
        f"/api/v1/virtual-tours/{tour['tour_id']}",
        headers=auth(owner_listing["token"]),
    )
    assert still_there.status_code == 200
