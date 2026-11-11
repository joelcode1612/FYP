"""Owner draft lifecycle over fyp.rental_properties (Add Property workflow).

Covers: minimal draft persistence, resume, duplicate-free updates, the
incomplete-draft submission guard, the evidence guard, admin decisions
mirroring onto the listing row, rejection visibility + resubmission,
ownership scoping, and photo upload/primary/delete against a stubbed
storage layer (no network).
"""

import io
import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id

PNG_BYTES = b"\x89PNG\r\n\x1a\n" + b"0" * 64
PDF_BYTES = b"%PDF-1.4\n%deed\n"


def auth(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture(autouse=True)
def offline_address_validation(monkeypatch):
    """The submission path calls Google Address Validation; the suite runs
    offline with a provider-validated result so lifecycle tests exercise the
    real transitions instead of the network (same pattern as
    ``test_property_verification_api.py``)."""
    from sitewise.services import property_verification_service as service_module

    monkeypatch.setattr(
        service_module,
        "validate_address",
        lambda **_kwargs: {
            "status": "validated",
            "formatted_address": "Test formatted address, Selangor",
        },
    )


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
            session.execute(
                text("DELETE FROM fyp.rental_properties WHERE id = ANY(:ids)"),
                {"ids": props},
            )
        session.commit()


@pytest.fixture()
def owner(client, cleanup_users):
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub,
        email=f"draft-owner-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Draft Owner"},
    )
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    register_user_id(cleanup_users, uuid.UUID(sub))
    return {"token": token, "sub": sub}


@pytest.fixture()
def admin(client, cleanup_users):
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"draft-admin-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    from sitewise.repositories.user_repository import UserRepository

    with Session(engine) as session:
        repo = UserRepository(session)
        repo.get_or_create_from_supabase(user_id=sub, email=email, email_verified=True)
        repo.update(sub, {"role": "admin", "account_status": "active"})
    token = make_token(
        sub=str(sub),
        email=email,
        aal="aal2",
        amr=[{"method": "password"}, {"method": "totp"}],
    )
    return {"token": token, "sub": str(sub)}


def create_draft(client, owner, **overrides):
    payload = {"name": "My SS15 shoplot"}
    payload.update(overrides)
    return client.post(
        "/api/v1/properties/listings/drafts",
        headers=auth(owner["token"]),
        json=payload,
    )


def complete_payload():
    return {
        "name": "Complete corner lot",
        "property_type": "Shoplot",
        "address": "Jalan SS15/4, Subang Jaya",
        "city": "Subang Jaya",
        "state": "Selangor",
        # The address-validation policy made postcode a required submission
        # field; SS15 Subang Jaya is 47500.
        "postcode": "47500",
        "latitude": 3.0722,
        "longitude": 101.6065,
        "rental_price": 7800,
        "size_sqft": 1680,
        "availability": "Immediate",
    }


def upload_ownership_doc(client, owner):
    return client.post(
        f"/api/v1/properties/{owner['property_id']}/verification/documents",
        headers=auth(owner["token"]),
        files={"file": ("deed.pdf", io.BytesIO(PDF_BYTES), "application/pdf")},
        data={"verification_type": "ownership", "document_type": "ownership_deed"},
    )


def test_draft_create_round_trip_and_no_duplicates(client, owner, cleanup_listings):
    r = create_draft(client, owner)
    assert r.status_code == 201, r.text
    row = r.json()["data"]
    pid = row["id"]
    cleanup_listings.append(pid)
    assert row["verification_status"] == "draft"
    assert row["is_published"] is False
    assert row["owner_user_id"] == owner["sub"]
    assert row["rental_price"] is None  # minimally validated draft
    # Supabase UUID ownership must never be assigned to the legacy BIGINT FK.
    with Session(engine) as session:
        persisted = session.execute(
            text("SELECT owner_id, owner_user_id FROM fyp.rental_properties WHERE id = :pid"),
            {"pid": pid},
        ).one()
    assert persisted.owner_id is None
    assert str(persisted.owner_user_id) == owner["sub"]

    # Resume: GET returns the same row plus its (empty) photo list.
    g = client.get(f"/api/v1/properties/listings/{pid}", headers=auth(owner["token"]))
    assert g.status_code == 200
    assert g.json()["data"]["name"] == "My SS15 shoplot"
    assert g.json()["data"]["photos"] == []

    # Update the SAME row — a second save must never create a duplicate.
    u = client.patch(
        f"/api/v1/properties/listings/{pid}",
        headers=auth(owner["token"]),
        json=complete_payload(),
    )
    assert u.status_code == 200, u.text
    updated = u.json()["data"]
    assert updated["id"] == pid
    assert updated["rental_price"] == 7800
    assert updated["psf"] == round(7800 / 1680, 2)
    with Session(engine) as session:
        count = session.execute(
            text(
                "SELECT count(*) FROM fyp.rental_properties "
                "WHERE owner_user_id = :owner"
            ),
            {"owner": owner["sub"]},
        ).scalar_one()
    assert count == 1

    # My Properties includes the draft.
    mine = client.get("/api/v1/properties/listings/mine", headers=auth(owner["token"]))
    assert mine.status_code == 200
    assert any(item["id"] == pid for item in mine.json()["data"])


def test_incomplete_draft_cannot_be_submitted(client, owner, cleanup_listings):
    r = create_draft(client, owner)
    pid = r.json()["data"]["id"]
    cleanup_listings.append(pid)
    assert upload_ownership_doc(client, {"token": owner["token"], "property_id": pid}).status_code == 201
    s = client.post(
        f"/api/v1/properties/{pid}/verification/submit",
        headers=auth(owner["token"]),
    )
    assert s.status_code == 409
    detail = s.json()["detail"]
    assert "Complete these fields" in detail
    for missing in ("address", "latitude", "rental price", "availability"):
        assert missing in detail
    # The draft is untouched and still a draft.
    g = client.get(f"/api/v1/properties/listings/{pid}", headers=auth(owner["token"]))
    assert g.json()["data"]["verification_status"] == "draft"


def test_complete_draft_without_evidence_cannot_be_submitted(client, owner, cleanup_listings):
    r = create_draft(client, owner, **complete_payload())
    pid = r.json()["data"]["id"]
    cleanup_listings.append(pid)
    s = client.post(
        f"/api/v1/properties/{pid}/verification/submit",
        headers=auth(owner["token"]),
    )
    assert s.status_code == 409
    assert "ownership or authorisation document" in s.json()["detail"]


def test_full_lifecycle_mirrors_onto_listing(
    client, owner, admin, cleanup_listings
):
    r = create_draft(client, owner, **complete_payload())
    pid = r.json()["data"]["id"]
    cleanup_listings.append(pid)
    assert upload_ownership_doc(client, {"token": owner["token"], "property_id": pid}).status_code == 201
    s = client.post(
        f"/api/v1/properties/{pid}/verification/submit",
        headers=auth(owner["token"]),
    )
    assert s.status_code == 200, s.text
    assert s.json()["listing_status"] == "pending"

    # Editing is now blocked (pending review).
    e = client.patch(
        f"/api/v1/properties/listings/{pid}",
        headers=auth(owner["token"]),
        json={"rental_price": 1},
    )
    assert e.status_code == 409

    g = client.get(f"/api/v1/properties/listings/{pid}", headers=auth(owner["token"]))
    assert g.json()["data"]["verification_status"] == "pending"
    assert g.json()["data"]["is_published"] is False

    base = f"/api/v1/staff/properties/{pid}/verification"
    a1 = client.post(
        f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "listing"}
    )
    assert a1.status_code == 200
    a2 = client.post(
        f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "ownership"}
    )
    assert a2.status_code == 200
    assert a2.json()["publication_eligible"] is True

    # Approval mirrors 'approved' but publication stays an admin action.
    g = client.get(f"/api/v1/properties/listings/{pid}", headers=auth(owner["token"]))
    assert g.json()["data"]["verification_status"] == "approved"
    assert g.json()["data"]["is_published"] is False


def test_rejection_reason_visible_and_resubmission_allowed(
    client, owner, admin, cleanup_listings
):
    r = create_draft(client, owner, **complete_payload())
    pid = r.json()["data"]["id"]
    cleanup_listings.append(pid)
    upload_ownership_doc(client, {"token": owner["token"], "property_id": pid})
    client.post(
        f"/api/v1/properties/{pid}/verification/submit", headers=auth(owner["token"])
    )
    reason = "Photos do not match the stated address."
    rej = client.post(
        f"/api/v1/staff/properties/{pid}/verification/reject",
        headers=auth(admin["token"]),
        json={"dimension": "listing", "reason": reason},
    )
    assert rej.status_code == 200

    # The submitter sees the reason via the verification view AND the
    # listing row, and editing reopens.
    status = client.get(
        f"/api/v1/properties/{pid}/verification", headers=auth(owner["token"])
    )
    assert status.json()["requested_corrections"]["listing"] == reason
    g = client.get(f"/api/v1/properties/listings/{pid}", headers=auth(owner["token"]))
    assert g.json()["data"]["verification_status"] == "rejected"
    assert g.json()["data"]["rejection_reason"] == reason

    fix = client.patch(
        f"/api/v1/properties/listings/{pid}",
        headers=auth(owner["token"]),
        json={"description": "Address photos corrected"},
    )
    assert fix.status_code == 200

    resubmit = client.post(
        f"/api/v1/properties/{pid}/verification/submit", headers=auth(owner["token"])
    )
    assert resubmit.status_code == 200
    assert resubmit.json()["listing_status"] == "pending"


def test_owner_cannot_read_or_edit_another_owners_draft(
    client, owner, cleanup_users, cleanup_listings
):
    r = create_draft(client, owner)
    pid = r.json()["data"]["id"]
    cleanup_listings.append(pid)

    foreign_sub = str(uuid.uuid4())
    foreign_token = make_token(
        sub=foreign_sub,
        email=f"draft-foreign-{foreign_sub[:8]}@{TEST_EMAIL_DOMAIN}",
    )
    assert client.get("/api/v1/auth/me", headers=auth(foreign_token)).status_code == 200
    register_user_id(cleanup_users, uuid.UUID(foreign_sub))

    foreign = {"token": foreign_token}
    assert (
        client.get(
            f"/api/v1/properties/listings/{pid}", headers=auth(foreign_token)
        ).status_code
        == 403
    )
    assert (
        client.patch(
            f"/api/v1/properties/listings/{pid}",
            headers=auth(foreign_token),
            json={"name": "hijacked"},
        ).status_code
        == 403
    )
    assert (
        client.post(
            f"/api/v1/properties/{pid}/verification/submit", headers=auth(foreign_token)
        ).status_code
        == 403
    )


@pytest.fixture()
def fake_photo_storage(monkeypatch):
    """Stub the public storage layer; URLs are in-process fakes."""
    from sitewise.services import photo_storage

    saved: list[str] = []

    def fake_save(data: bytes, ext: str, content_type: str) -> str:
        url = f"https://stub.supabase.co/storage/v1/object/public/property-photos/listings/fake-{len(saved)}{ext}"
        saved.append(url)
        return url

    monkeypatch.setattr(photo_storage, "save_photo", fake_save)
    monkeypatch.setattr(
        photo_storage, "delete_photo", lambda url: saved.remove(url) if url in saved else None
    )
    return saved


def test_photo_upload_primary_and_delete(
    client, owner, cleanup_listings, fake_photo_storage
):
    r = create_draft(client, owner)
    pid = r.json()["data"]["id"]
    cleanup_listings.append(pid)
    headers = auth(owner["token"])

    first = client.post(
        f"/api/v1/properties/listings/{pid}/photos",
        headers=headers,
        files={"file": ("front.png", io.BytesIO(PNG_BYTES), "image/png")},
        data={"caption": "Frontage"},
    )
    assert first.status_code == 201, first.text
    photo1 = first.json()["data"]
    assert photo1["is_primary"] is True  # first photo auto-primary
    assert "property-photos" in photo1["url"]
    assert photo1["url"] not in ("", "/dev/null")

    second = client.post(
        f"/api/v1/properties/listings/{pid}/photos",
        headers=headers,
        files={"file": ("interior.png", io.BytesIO(PNG_BYTES), "image/png")},
        data={"caption": "Interior"},
    )
    assert second.json()["data"]["is_primary"] is False

    # Reject a non-image type.
    bad = client.post(
        f"/api/v1/properties/listings/{pid}/photos",
        headers=headers,
        files={"file": ("evil.exe", io.BytesIO(b"MZ"), "application/x-msdownload")},
        data={"caption": ""},
    )
    assert bad.status_code == 422

    # Primary selection is owner-controlled.
    promote = client.post(
        f"/api/v1/properties/listings/{pid}/photos/{second.json()['data']['id']}/primary",
        headers=headers,
    )
    assert promote.status_code == 200
    photos = promote.json()["data"]
    assert {p["id"] for p in photos if p["is_primary"]} == {
        second.json()["data"]["id"]
    }

    # Deleting the primary promotes the oldest remaining photo.
    d = client.delete(
        f"/api/v1/properties/listings/{pid}/photos/{second.json()['data']['id']}",
        headers=headers,
    )
    assert d.status_code == 200
    photos = client.get(
        f"/api/v1/properties/listings/{pid}/photos", headers=headers
    ).json()["data"]
    assert len(photos) == 1 and photos[0]["is_primary"] is True
    assert len(fake_photo_storage) == 1


def test_photo_rejections(client, owner, cleanup_listings, fake_photo_storage):
    from sitewise.services import photo_storage

    r = create_draft(client, owner)
    pid = r.json()["data"]["id"]
    cleanup_listings.append(pid)
    headers = auth(owner["token"])

    previous = photo_storage.DEFAULT_MAX_BYTES
    try:
        photo_storage.DEFAULT_MAX_BYTES = 1
        oversized = client.post(
            f"/api/v1/properties/listings/{pid}/photos",
            headers=headers,
            files={"file": ("big.png", io.BytesIO(b"x" * 2048), "image/png")},
            data={"caption": ""},
        )
        assert oversized.status_code == 413
    finally:
        photo_storage.DEFAULT_MAX_BYTES = previous


def test_photo_storage_unavailable_preserves_draft(
    client, owner, cleanup_listings
):
    from sitewise.services import photo_storage
    from sitewise.services.photo_storage import PhotoStorageUnavailable

    def broken_save(data, ext, content_type):
        raise PhotoStorageUnavailable("Storage unreachable.")

    monkeypatch_storage = broken_save
    r = create_draft(client, owner)
    pid = r.json()["data"]["id"]
    cleanup_listings.append(pid)

    import unittest.mock as mock

    with mock.patch.object(photo_storage, "save_photo", monkeypatch_storage):
        up = client.post(
            f"/api/v1/properties/listings/{pid}/photos",
            headers=auth(owner["token"]),
            files={"file": ("front.png", io.BytesIO(PNG_BYTES), "image/png")},
            data={"caption": ""},
        )
    assert up.status_code == 503
    assert "Storage unreachable." in up.json()["detail"]
    # Draft preserved, no dangling photo row.
    photos = client.get(
        f"/api/v1/properties/listings/{pid}/photos", headers=auth(owner["token"])
    ).json()["data"]
    assert photos == []
