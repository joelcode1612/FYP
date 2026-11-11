"""Unified property verification workflow (listing + ownership dimensions).

Covers the spec section 10 backend matrix: ownership scoping, RBAC + MFA,
queue search/filter/sort/pagination, per-dimension decisions, publication
eligibility (both-verified rule), audit persistence, invalid lifecycle
transitions, document type/size rejection and private-document access control.

Documents are stored under a pytest tmp dir (settings overridden per test), so
the real storage directory is never touched and no test file can leak.
"""

import io
import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.db.session import engine
from sitewise.repositories.user_repository import UserRepository

from ..conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token):
    return {"Authorization": f"Bearer {token}"}


PDF_BYTES = b"%PDF-1.4\n%test-document\n"


def insert_listing(
    session: Session,
    owner_uuid: str,
    *,
    name: str,
    address: str,
    city: str,
    state: str,
    property_type: str = "Shop",
    complete: bool = True,
) -> int:
    """Insert one owner listing in the canonical table. ``complete=True``
    fills every field final submission validates; ``complete=False`` leaves
    an intentionally sparse draft."""
    row = session.execute(
        text(
            """
            INSERT INTO fyp.rental_properties (
                owner_user_id, name, property_type, address, city, state,
                postcode, latitude, longitude, rental_price, size_sqft,
                availability, verification_status, is_published
            ) VALUES (
                :owner, :name, :ptype, :address, :city, :state,
                :postcode, :lat, :lon, :price, :size, :availability,
                'draft', false
            ) RETURNING id
            """
        ),
        {
            "owner": owner_uuid,
            "name": name,
            "ptype": property_type,
            "address": address,
            "city": city,
            "state": state,
            "postcode": "40460" if complete else None,
            "lat": 3.0722 if complete else None,
            "lon": 101.6065 if complete else None,
            "price": 4500 if complete else None,
            "size": 1680 if complete else None,
            "availability": "Immediate" if complete else None,
        },
    )
    session.commit()
    return int(row.scalar_one())


@pytest.fixture(autouse=True)
def offline_address_validation(monkeypatch):
    """The suite runs without Google: every address submitted through the
    verification workflow is treated as provider-validated, so lifecycle
    tests exercise transitions instead of the network."""
    from sitewise.services import property_verification_service as service_module

    monkeypatch.setattr(
        service_module,
        "validate_address",
        lambda **_kwargs: {
            "status": "validated",
            "formatted_address": "Test formatted address, Selangor",
        },
    )


@pytest.fixture(autouse=True)
def private_storage(monkeypatch, tmp_path):
    monkeypatch.setattr(settings, "verification_storage_dir", str(tmp_path / "docs"))
    return tmp_path / "docs"


@pytest.fixture(autouse=True)
def cleanup_verifications(cleanup_users):
    """Verification rows before their property rows; order pinned by
    requesting ``cleanup_users`` (users are removed after this fixture)."""
    props: list[int] = []
    yield props
    if not props and not cleanup_users:
        return
    with Session(engine) as session:
        for table in (
            "verification_audit",
            "verification_document",
            "property_verification",
            "fyp.property_geospatial_features",
        ):
            if props:
                session.execute(
                    text(f"DELETE FROM {table} WHERE property_id = ANY(:ids)"),
                    {"ids": props},
                )
            else:
                session.execute(text(f"DELETE FROM {table}"))
        if props:
            # Photos cascade on delete; the listing rows themselves are
            # owner-submitted test rows.
            session.execute(
                text("DELETE FROM fyp.rental_properties WHERE id = ANY(:ids)"),
                {"ids": props},
            )
        session.commit()


@pytest.fixture()
def owner(client, cleanup_users, cleanup_verifications):
    """A provisioned entrepreneur plus one owned rental listing (the
    canonical fyp.rental_properties identity the verification workflow is
    bound to)."""
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub,
        email=f"verify-owner-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Verification Owner"},
    )
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    register_user_id(cleanup_users, uuid.UUID(sub))
    with Session(engine) as session:
        property_id = insert_listing(
            session,
            sub,
            name="Corner shoplot, Section 13",
            address="Jalan 13/1, Shah Alam",
            city="Shah Alam",
            state="Selangor",
            property_type="Shop lot",
        )
        cleanup_verifications.append(property_id)
    return {"token": token, "sub": sub, "property_id": property_id}


@pytest.fixture()
def admin(client, cleanup_users):
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"verify-admin-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
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


def upload_ownership_doc(client, owner, filename="deed.pdf"):
    return client.post(
        f"/api/v1/properties/{owner['property_id']}/verification/documents",
        headers=auth(owner["token"]),
        files={"file": (filename, io.BytesIO(PDF_BYTES), "application/pdf")},
        data={"verification_type": "ownership", "document_type": "ownership_deed"},
    )


def upload_listing_doc(client, owner, filename="frontage.jpg"):
    return client.post(
        f"/api/v1/properties/{owner['property_id']}/verification/documents",
        headers=auth(owner["token"]),
        files={"file": (filename, io.BytesIO(PDF_BYTES), "image/jpeg")},
        data={"verification_type": "listing", "document_type": "listing_photo"},
    )


# --------------------------------------------------------------------------
# Submission and ownership scoping
# --------------------------------------------------------------------------


def test_owner_submits_own_property_with_evidence(client, owner):
    """Upload -> submit -> both dimensions pending; eligible stays false."""
    r = upload_ownership_doc(client, owner)
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["verification_type"] == "ownership"
    assert body["file_size"] == len(PDF_BYTES)
    # Submission before evidence is refused.
    r2 = client.post(
        f"/api/v1/properties/{owner['property_id']}/verification/submit",
        headers=auth(owner["token"]),
    )
    assert r2.status_code == 200, r2.text
    verification = r2.json()
    assert verification["listing_status"] == "pending"
    assert verification["ownership_status"] == "pending"
    assert verification["publication_eligible"] is False

    # Re-submitting while pending is a lifecycle error, not a duplicate.
    r3 = client.post(
        f"/api/v1/properties/{owner['property_id']}/verification/submit",
        headers=auth(owner["token"]),
    )
    assert r3.status_code == 409


def test_owner_cannot_touch_another_owners_property(client, owner, cleanup_users):
    foreign_sub = str(uuid.uuid4())
    foreign_token = make_token(
        sub=foreign_sub,
        email=f"verify-foreign-{foreign_sub[:8]}@{TEST_EMAIL_DOMAIN}",
        role_claims={"full_name": "Foreign Owner"},
    )
    assert client.get("/api/v1/auth/me", headers=auth(foreign_token)).status_code == 200
    register_user_id(cleanup_users, uuid.UUID(foreign_sub))
    assert upload_ownership_doc(client, owner).status_code == 201

    # Foreign account cannot submit, cannot upload, cannot read the status.
    assert (
        client.post(
            f"/api/v1/properties/{owner['property_id']}/verification/submit",
            headers=auth(foreign_token),
        ).status_code
        == 403
    )
    assert (
        upload_ownership_doc(
            client, {"token": foreign_token, "property_id": owner["property_id"]}
        ).status_code
        == 403
    )
    assert (
        client.get(
            f"/api/v1/properties/{owner['property_id']}/verification",
            headers=auth(foreign_token),
        ).status_code
        == 403
    )


def test_private_document_access_control(client, owner, cleanup_users):
    r = upload_ownership_doc(client, owner)
    document_id = r.json()["document_id"]

    # Anonymous access is rejected before ownership is even considered.
    anon = client.get(f"/api/v1/properties/verification-documents/{document_id}")
    assert anon.status_code == 401

    foreign_sub = str(uuid.uuid4())
    foreign_token = make_token(
        sub=foreign_sub,
        email=f"verify-doc-{foreign_sub[:8]}@{TEST_EMAIL_DOMAIN}",
    )
    assert client.get("/api/v1/auth/me", headers=auth(foreign_token)).status_code == 200
    register_user_id(cleanup_users, uuid.UUID(foreign_sub))
    stolen = client.get(
        f"/api/v1/properties/verification-documents/{document_id}",
        headers=auth(foreign_token),
    )
    assert stolen.status_code == 403

    # The owner downloads their own evidence.
    mine = client.get(
        f"/api/v1/properties/verification-documents/{document_id}",
        headers=auth(owner["token"]),
    )
    assert mine.status_code == 200
    assert mine.content == PDF_BYTES


def test_document_type_and_size_are_rejected(client, owner):
    bad_type = client.post(
        f"/api/v1/properties/{owner['property_id']}/verification/documents",
        headers=auth(owner["token"]),
        files={"file": ("evil.exe", io.BytesIO(b"MZ..."), "application/x-msdownload")},
        data={"verification_type": "ownership", "document_type": "deed"},
    )
    assert bad_type.status_code == 422

    monkey_max = 1
    previous = settings.verification_max_upload_mb
    try:
        settings.verification_max_upload_mb = monkey_max
        oversized = client.post(
            f"/api/v1/properties/{owner['property_id']}/verification/documents",
            headers=auth(owner["token"]),
            files={
                "file": (
                    "deed.pdf",
                    io.BytesIO(b"x" * (monkey_max * 1024 * 1024 + 1)),
                    "application/pdf",
                )
            },
            data={"verification_type": "ownership", "document_type": "deed"},
        )
        assert oversized.status_code == 413
    finally:
        settings.verification_max_upload_mb = previous


# --------------------------------------------------------------------------
# Administrator authorization
# --------------------------------------------------------------------------


def test_non_admin_cannot_reach_staff_endpoints(client, owner):
    for path, method in (
        ("/api/v1/staff/properties/", "GET"),
        (f"/api/v1/staff/properties/{owner['property_id']}", "GET"),
        (
            f"/api/v1/staff/properties/{owner['property_id']}/verification/approve",
            "POST",
        ),
    ):
        r = client.request(
            method, path, headers=auth(owner["token"]), json={"dimension": "listing"}
        )
        assert r.status_code == 403, f"{method} {path} -> {r.status_code}"


def test_admin_without_mfa_is_rejected(client, cleanup_users, owner):
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"no-mfa-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    with Session(engine) as session:
        repo = UserRepository(session)
        repo.get_or_create_from_supabase(user_id=sub, email=email, email_verified=True)
        repo.update(sub, {"role": "admin", "account_status": "active"})
    aal1_token = make_token(sub=str(sub), email=email, aal="aal1")
    r = client.get("/api/v1/staff/properties/", headers=auth(aal1_token))
    assert r.status_code == 403
    assert r.json()["detail"]["code"] == "staff_mfa_required"


def test_admin_queue_filters_sort_and_paginate(
    client, owner, admin, cleanup_users, cleanup_verifications
):
    """Two submissions, different states and addresses; filters compose."""
    other_sub = str(uuid.uuid4())
    other_token = make_token(
        sub=other_sub,
        email=f"verify-second-{other_sub[:8]}@{TEST_EMAIL_DOMAIN}",
    )
    assert client.get("/api/v1/auth/me", headers=auth(other_token)).status_code == 200
    register_user_id(cleanup_users, uuid.UUID(other_sub))
    with Session(engine) as session:
        prop2_id = insert_listing(
            session,
            other_sub,
            name="Bistro unit, JB",
            address="Jalan Trus, Johor Bahru",
            city="Johor Bahru",
            state="Johor",
            property_type="Retail space",
        )
        cleanup_verifications.append(prop2_id)
    upload_ownership_doc(client, owner)
    client.post(
        f"/api/v1/properties/{owner['property_id']}/verification/submit",
        headers=auth(owner["token"]),
    )
    upload_ownership_doc(client, {"token": other_token, "property_id": prop2_id}, "letter.pdf")
    client.post(
        f"/api/v1/properties/{prop2_id}/verification/submit",
        headers=auth(other_token),
    )
    client.post(
        f"/api/v1/staff/properties/{prop2_id}/verification/approve",
        headers=auth(admin["token"]),
        json={"dimension": "ownership"},
    )

    q = client.get("/api/v1/staff/properties/", headers=auth(admin["token"]))
    assert q.status_code == 200
    body = q.json()
    assert body["total"] == 2
    assert {item["property_id"] for item in body["items"]} == {
        owner["property_id"],
        prop2_id,
    }
    assert set(body["counts"]["listing"]) <= {
        "not_submitted",
        "pending",
        "under_review",
        "verified",
        "rejected",
        "information_requested",
    }

    # Combined filters: ownership verified AND state match. Only prop2 is
    # ownership-verified, and it has no address row -> state filter excludes it.
    filtered = client.get(
        "/api/v1/staff/properties/?ownership_status=verified&state=Selangor",
        headers=auth(admin["token"]),
    )
    assert filtered.json()["total"] == 0

    verified_only = client.get(
        "/api/v1/staff/properties/?ownership_status=verified",
        headers=auth(admin["token"]),
    )
    assert verified_only.json()["total"] == 1
    assert verified_only.json()["items"][0]["property_id"] == prop2_id

    # Search hits the title.
    searched = client.get("/api/v1/staff/properties/?q=Bistro", headers=auth(admin["token"]))
    assert searched.json()["total"] == 1

    # Sorting + pagination.
    page = client.get(
        "/api/v1/staff/properties/?sort=title&order=asc&limit=1&offset=1",
        headers=auth(admin["token"]),
    )
    assert page.json()["total"] == 2
    assert len(page.json()["items"]) == 1


# --------------------------------------------------------------------------
# Decisions, eligibility, audit, lifecycle
# --------------------------------------------------------------------------


def full_submission(client, owner):
    upload_ownership_doc(client, owner)
    upload_listing_doc(client, owner)
    r = client.post(
        f"/api/v1/properties/{owner['property_id']}/verification/submit",
        headers=auth(owner["token"]),
    )
    assert r.status_code == 200
    return r.json()


def test_decisions_are_independent_and_eligibility_requires_both(client, owner, admin):
    full_submission(client, owner)
    pid = owner["property_id"]
    base = f"/api/v1/staff/properties/{pid}/verification"

    listing_ok = client.post(
        f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "listing"}
    )
    assert listing_ok.status_code == 200
    after_listing = listing_ok.json()
    assert after_listing["listing_status"] == "verified"
    # One approval must not leak into the other dimension.
    assert after_listing["ownership_status"] == "pending"
    assert after_listing["publication_eligible"] is False

    ownership_ok = client.post(
        f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "ownership"}
    )
    final = ownership_ok.json()
    assert final["ownership_status"] == "verified"
    assert final["publication_eligible"] is True

    detail = client.get(f"/api/v1/staff/properties/{pid}", headers=auth(admin["token"]))
    assert detail.status_code == 200
    body = detail.json()
    assert body["verification"]["publication_eligible"] is True
    actions = [row["action"] for row in body["history"]]
    # Two document uploads, the owner submission, then the two decisions.
    assert actions.count("evidence_uploaded") == 2
    assert actions[-3:] == ["submitted", "listing_approved", "ownership_approved"]
    decisions = body["history"][-2:]
    assert all(row["admin_user_id"] == admin["sub"] for row in decisions)
    assert all(row["admin_user_id"] is None for row in body["history"][:-2])


def test_reject_and_request_information_require_reason(client, owner, admin):
    full_submission(client, owner)
    pid = owner["property_id"]
    base = f"/api/v1/staff/properties/{pid}/verification"

    empty = client.post(
        f"{base}/reject",
        headers=auth(admin["token"]),
        json={"dimension": "listing", "reason": "   "},
    )
    assert empty.status_code == 409

    rejected = client.post(
        f"{base}/reject",
        headers=auth(admin["token"]),
        json={"dimension": "listing", "reason": "Photos do not match the address."},
    )
    assert rejected.status_code == 200
    assert rejected.json()["listing_status"] == "rejected"
    assert rejected.json()["latest_note"] == "Photos do not match the address."

    info = client.post(
        f"{base}/request-information",
        headers=auth(admin["token"]),
        json={"dimension": "ownership", "note": "Provide the signed tenancy letter."},
    )
    assert info.status_code == 200
    assert info.json()["ownership_status"] == "information_requested"

    # The owner sees the requested corrections and can resubmit.
    status = client.get(f"/api/v1/properties/{pid}/verification", headers=auth(owner["token"]))
    corrections = status.json()["requested_corrections"]
    assert corrections["listing"] == "Photos do not match the address."
    assert corrections["ownership"] == "Provide the signed tenancy letter."

    resubmit = client.post(
        f"/api/v1/properties/{pid}/verification/submit", headers=auth(owner["token"])
    )
    assert resubmit.status_code == 200
    assert resubmit.json()["listing_status"] == "pending"
    assert resubmit.json()["ownership_status"] == "pending"


def test_invalid_lifecycle_transitions_are_refused(client, owner, admin):
    full_submission(client, owner)
    pid = owner["property_id"]
    base = f"/api/v1/staff/properties/{pid}/verification"

    # start-review is only valid from pending.
    assert (
        client.post(
            f"{base}/start-review", headers=auth(admin["token"]), json={"dimension": "listing"}
        ).status_code
        == 200
    )
    again = client.post(
        f"{base}/start-review", headers=auth(admin["token"]), json={"dimension": "listing"}
    )
    assert again.status_code == 409

    # Approving an already-verified dimension is refused.
    client.post(f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "listing"})
    twice = client.post(
        f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "listing"}
    )
    assert twice.status_code == 409

    # No submission -> every decision 404s.
    ghost = client.post(
        "/api/v1/staff/properties/999999/verification/approve",
        headers=auth(admin["token"]),
        json={"dimension": "listing"},
    )
    assert ghost.status_code == 404


def test_concurrent_decisions_serialize_not_overwrite(client, owner, admin):
    """A held row lock blocks a second decision until the first commits; the
    second decision then applies on top of the first (no lost update)."""
    full_submission(client, owner)
    pid = owner["property_id"]

    from threading import Thread

    from sitewise.db.session import engine as engine2

    blocker_session = Session(engine2)
    blocker_session.execute(
        text(
            "SELECT verification_id FROM property_verification WHERE property_id = :pid FOR UPDATE"
        ),
        {"pid": pid},
    ).first()  # holds the row lock

    result = {}

    def decision():
        result["r"] = client.post(
            f"/api/v1/staff/properties/{pid}/verification/approve",
            headers=auth(admin["token"]),
            json={"dimension": "listing"},
        )

    try:
        worker = Thread(target=decision, daemon=True)
        worker.start()
        worker.join(timeout=1.5)
        assert worker.is_alive(), "second decision did not wait for the row lock"
    finally:
        # ALWAYS release the lock: a failure above must never leave the
        # blocker's transaction open, or fixture cleanup deadlocks.
        blocker_session.commit()
    worker.join(timeout=5)
    assert not worker.is_alive()
    assert result["r"].status_code == 200
    assert result["r"].json()["listing_status"] == "verified"

    # The second admin's decision landed on top of the first, and both are
    # individually audited.
    detail = client.get(f"/api/v1/staff/properties/{pid}", headers=auth(admin["token"]))
    actions = [row["action"] for row in detail.json()["history"]]
    assert actions.count("submitted") == 1
    assert actions[-1] == "listing_approved"
    blocker_session.close()


def test_upload_after_full_verification_is_refused(client, owner, admin):
    full_submission(client, owner)
    pid = owner["property_id"]
    base = f"/api/v1/staff/properties/{pid}/verification"
    client.post(f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "listing"})
    client.post(f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "ownership"})
    late = upload_ownership_doc(client, owner, "extra.pdf")
    assert late.status_code == 409


def test_unauthenticated_access_is_rejected(client, owner):
    pid = owner["property_id"]
    assert client.get(f"/api/v1/properties/{pid}/verification").status_code == 401
    assert client.get("/api/v1/staff/properties/").status_code == 401
    assert client.post(f"/api/v1/properties/{pid}/verification/submit").status_code == 401


def test_owner_sees_own_submission_round_trip(client, owner, admin):
    """Spec section 10 integration: submit -> admin decisions -> owner reads."""
    full_submission(client, owner)
    pid = owner["property_id"]
    base = f"/api/v1/staff/properties/{pid}/verification"
    client.post(f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "listing"})
    client.post(f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "ownership"})
    status = client.get(f"/api/v1/properties/{pid}/verification", headers=auth(owner["token"]))
    assert status.status_code == 200
    body = status.json()
    assert body["verification"]["listing_status"] == "verified"
    assert body["verification"]["ownership_status"] == "verified"
    assert body["verification"]["publication_eligible"] is True
    assert len(body["documents"]) == 2


# --------------------------------------------------------------------------
# Listing-information-only workflow (no ownership documents)
# --------------------------------------------------------------------------


def listing_scope_submit(client, owner):
    return client.post(
        f"/api/v1/properties/{owner['property_id']}/verification/submit",
        headers=auth(owner["token"]),
        json={"scope": "listing"},
    )


def test_listing_only_submission_enters_queue_without_ownership_documents(
    client, owner, admin
):
    """A complete listing enters Admin review with scope=listing: the listing
    dimension goes pending, ownership stays not_submitted, publication
    eligibility stays false."""
    r = listing_scope_submit(client, owner)
    assert r.status_code == 200, r.text
    verification = r.json()
    assert verification["listing_status"] == "pending"
    assert verification["ownership_status"] == "not_submitted"
    assert verification["publication_eligible"] is False

    # The submission is visible in the admin queue and its detail carries
    # the listing-only audit trail.
    queue = client.get("/api/v1/staff/properties/", headers=auth(admin["token"]))
    assert queue.status_code == 200
    assert owner["property_id"] in {
        item["property_id"] for item in queue.json()["items"]
    }

    detail = client.get(
        f"/api/v1/staff/properties/{owner['property_id']}",
        headers=auth(admin["token"]),
    )
    assert detail.status_code == 200
    actions = [row["action"] for row in detail.json()["history"]]
    assert actions == ["listing_submitted"]
    assert detail.json()["history"][0]["verification_type"] == "listing"


def test_listing_approval_does_not_verify_ownership_or_publish(client, owner, admin):
    """Approving the listing dimension moves ONLY that dimension; the
    property stays unpublished and ineligible even though the listing is
    verified."""
    assert listing_scope_submit(client, owner).status_code == 200
    pid = owner["property_id"]
    base = f"/api/v1/staff/properties/{pid}/verification"

    started = client.post(
        f"{base}/start-review", headers=auth(admin["token"]), json={"dimension": "listing"}
    )
    assert started.status_code == 200, started.text
    approved = client.post(
        f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "listing"}
    )
    assert approved.status_code == 200, approved.text
    body = approved.json()
    assert body["listing_status"] == "verified"
    assert body["ownership_status"] == "not_submitted"
    assert body["publication_eligible"] is False

    # The listing row mirrors the aggregate, never 'approved': publication
    # stays a separate administrative action.
    with Session(engine) as session:
        row = session.execute(
            text(
                "SELECT verification_status, is_published, rejection_reason "
                "FROM fyp.rental_properties WHERE id = :pid"
            ),
            {"pid": pid},
        ).mappings().one()
    assert row["verification_status"] == "pending"
    assert row["is_published"] is False


def test_ownership_stays_unreviewable_after_listing_only_submission(
    client, owner, admin
):
    """A listing-scope submission never moves ownership: it stays
    not_submitted, which no staff decision can act on — ownership simply
    cannot be verified for a listing-only submission."""
    assert listing_scope_submit(client, owner).status_code == 200
    pid = owner["property_id"]
    base = f"/api/v1/staff/properties/{pid}/verification"
    # start-review from not_submitted is refused...
    assert (
        client.post(
            f"{base}/start-review", headers=auth(admin["token"]), json={"dimension": "ownership"}
        ).status_code
        == 409
    )
    # ...and so is approving it directly.
    refused = client.post(
        f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "ownership"}
    )
    assert refused.status_code == 409


def test_ownership_approval_still_requires_evidence_after_review_starts(
    client, owner, admin
):
    """Even when ownership somehow sits in a decisionable state, 'verified'
    demands an active document on file."""
    full_submission(client, owner)
    pid = owner["property_id"]
    base = f"/api/v1/staff/properties/{pid}/verification"
    # Start + approve listing first; ownership is pending (full scope).
    client.post(f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "listing"})
    # Remove the ownership evidence to simulate an evidence-less record.
    with Session(engine) as session:
        session.execute(
            text(
                "UPDATE verification_document SET status = 'superseded' "
                "WHERE property_id = :pid AND verification_type = 'ownership'"
            ),
            {"pid": pid},
        )
        session.commit()
    refused = client.post(
        f"{base}/approve", headers=auth(admin["token"]), json={"dimension": "ownership"}
    )
    assert refused.status_code == 409
    assert "document" in refused.json()["detail"]


def test_listing_scope_resubmission_after_rejection(client, owner, admin):
    """Reject the listing, then the owner resubmits with scope=listing: the
    listing returns to pending and ownership is never touched."""
    assert listing_scope_submit(client, owner).status_code == 200
    pid = owner["property_id"]
    base = f"/api/v1/staff/properties/{pid}/verification"
    client.post(f"{base}/start-review", headers=auth(admin["token"]), json={"dimension": "listing"})
    rejected = client.post(
        f"{base}/reject",
        headers=auth(admin["token"]),
        json={"dimension": "listing", "reason": "Floor level is inconsistent."},
    )
    assert rejected.status_code == 200

    resubmitted = listing_scope_submit(client, owner)
    assert resubmitted.status_code == 200, resubmitted.text
    assert resubmitted.json()["listing_status"] == "pending"
    assert resubmitted.json()["ownership_status"] == "not_submitted"
    assert resubmitted.json()["latest_note"] is None

    # A listing-scope resubmission while pending is refused.
    again = listing_scope_submit(client, owner)
    assert again.status_code == 409


def test_admin_detail_carries_location_context(client, owner, admin):
    """The staff detail response expands with photos, amenities, geospatial
    features and nearby demand generators — real rows round-trip, and the
    absent blocks arrive as explicit nulls the UI renders as 'Not
    calculated'."""
    assert listing_scope_submit(client, owner).status_code == 200
    pid = owner["property_id"]

    with Session(engine) as session:
        session.execute(
            text(
                "INSERT INTO fyp.property_photos (property_id, url, caption, "
                "is_primary, created_at) VALUES (:pid, :url, :caption, true, now())"
            ),
            {"pid": pid, "url": "https://example.test/photo-1.jpg", "caption": "Frontage"},
        )
        session.execute(
            text(
                "INSERT INTO fyp.property_geospatial_features (property_id, "
                "competitor_count_500m, competitor_count_1km, "
                "demand_generator_count_500m, demand_generator_count_1km, "
                "population_500m, population_1km, nearest_major_road_m, "
                "last_calculated_at) VALUES (:pid, 12, 37, 9, 28, NULL, NULL, "
                "140, now())"
            ),
            {"pid": pid},
        )
        session.commit()

    detail = client.get(
        f"/api/v1/staff/properties/{pid}", headers=auth(admin["token"])
    )
    assert detail.status_code == 200, detail.text
    body = detail.json()

    photos = body["photos"]
    assert len(photos) == 1
    assert photos[0]["url"] == "https://example.test/photo-1.jpg"
    assert photos[0]["is_primary"] is True

    geo = body["geo_features"]
    assert geo is not None
    assert geo["competitor_count_500m"] == 12
    assert geo["competitor_count_1km"] == 37
    assert geo["demand_generator_count_1km"] == 28
    assert geo["population_500m"] is None
    assert geo["last_calculated_at"]

    demand = body["demand_generators"]
    assert isinstance(demand, list)
    for generator in demand:
        assert generator["subject_id"]
        assert generator["distance_m"] is not None
    assert body["amenities"] is None  # no fyp.property_features row for test listings
    assert body["population"] is None  # no verified research link for test listings

    # The expanded property payload carries the fields the Admin overview
    # tab renders.
    prop = body["property"]
    assert prop["postcode"] == "40460"
    assert prop["latitude"] == 3.0722
    assert prop["longitude"] == 101.6065
    assert prop["has_parking"] is False
    assert prop["is_published"] is False
