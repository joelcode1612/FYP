"""Administrator property deletion — the ONE dependency-safe delete path.

Covers the deletion workflow required for a single canonical property master
(``fyp.rental_properties``):

* only an administrator with completed MFA may delete; owners and agents get
  403 — deletion authority is never derived from ownership or assignment;
* an unknown canonical id is 404;
* a research-linked master row (``catalogue_id`` set, i.e. one of the 955
  verified research properties) is refused with 409 and PRESERVED;
* a clean operational draft is deleted through the canonical id, and the
  row is gone afterwards.

Every test creates its own scratch rows and removes them in teardown; the
research row is only ever read.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def cleanup_listings(cleanup_users):
    props: list[int] = []
    yield props
    with Session(engine) as session:
        if props:
            for table in (
                "verification_audit",
                "verification_document",
                "property_verification",
            ):
                session.execute(
                    text(f"DELETE FROM {table} WHERE property_id = ANY(:ids)"),
                    {"ids": props},
                )
            for table in ("listing_change_audit", "listing_change_request"):
                session.execute(
                    text(f"DELETE FROM {table} WHERE listing_id = ANY(:ids)"),
                    {"ids": props},
                )
            session.execute(
                text("DELETE FROM fyp.rental_properties WHERE id = ANY(:ids)"),
                {"ids": props},
            )
        session.commit()


def _identity(cleanup_users, *, role: str, aal: str | None = None):
    """A provisioned local identity + a token (``aal2`` for staff surfaces)."""
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"del-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    from sitewise.repositories.user_repository import UserRepository

    with Session(engine) as session:
        repo = UserRepository(session)
        repo.get_or_create_from_supabase(user_id=sub, email=email, email_verified=True)
        repo.update(sub, {"role": role, "account_status": "active"})
    kwargs = {"sub": str(sub), "email": email}
    if aal:
        kwargs["aal"] = aal
        kwargs["amr"] = [{"method": "password"}, {"method": "totp"}]
    return sub, make_token(**kwargs)


@pytest.fixture()
def owner(cleanup_users):
    _, token = _identity(cleanup_users, role="owner")
    return token


@pytest.fixture()
def admin(cleanup_users):
    _, token = _identity(cleanup_users, role="admin", aal="aal2")
    return token


def _create_draft(client, owner_token: str) -> int:
    r = client.post(
        "/api/v1/properties/listings/drafts",
        headers=auth(owner_token),
        json={"name": "Deletion-test draft property"},
    )
    assert r.status_code == 201, r.text
    return int(r.json()["data"]["id"])


def _research_row_id() -> int:
    with Session(engine) as session:
        row = session.execute(
            text(
                "SELECT id FROM fyp.rental_properties "
                "WHERE catalogue_id IS NOT NULL ORDER BY id LIMIT 1"
            )
        ).scalar_one()
        return int(row)


def test_delete_requires_staff_authority(client, owner, cleanup_listings):
    pid = _create_draft(client, owner)
    cleanup_listings.append(pid)
    r = client.delete(f"/api/v1/staff/listings/{pid}", headers=auth(owner))
    assert r.status_code == 403
    # The row survives a non-admin deletion attempt.
    with Session(engine) as session:
        assert (
            session.execute(
                text("SELECT count(*) FROM fyp.rental_properties WHERE id = :pid"),
                {"pid": pid},
            ).scalar_one()
            == 1
        )


def test_delete_requires_admin_mfa(client, cleanup_users, cleanup_listings):
    _, token = _identity(cleanup_users, role="admin")  # no aal2
    r = client.delete("/api/v1/staff/listings/1", headers=auth(token))
    assert r.status_code == 403
    assert r.json()["detail"]["code"] == "staff_mfa_required"


def test_delete_unknown_listing_is_404(client, admin):
    r = client.delete("/api/v1/staff/listings/999999999", headers=auth(admin))
    assert r.status_code == 404


def test_research_property_is_protected(client, admin):
    pid = _research_row_id()
    r = client.delete(f"/api/v1/staff/listings/{pid}", headers=auth(admin))
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "research_property_protected"
    with Session(engine) as session:
        assert (
            session.execute(
                text("SELECT count(*) FROM fyp.rental_properties WHERE id = :pid"),
                {"pid": pid},
            ).scalar_one()
            == 1
        )


def test_admin_deletes_clean_operational_draft(client, owner, admin, cleanup_listings):
    pid = _create_draft(client, owner)
    cleanup_listings.append(pid)
    r = client.delete(f"/api/v1/staff/listings/{pid}", headers=auth(admin))
    assert r.status_code == 200, r.text
    body = r.json()["data"]
    assert body["deleted"] == pid
    assert body["name"] == "Deletion-test draft property"
    with Session(engine) as session:
        assert (
            session.execute(
                text("SELECT count(*) FROM fyp.rental_properties WHERE id = :pid"),
                {"pid": pid},
            ).scalar_one()
            == 0
        )
