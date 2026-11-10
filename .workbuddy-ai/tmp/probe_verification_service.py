"""Direct service-level probe of the rebound verification flow (no pytest)."""

from __future__ import annotations

import uuid

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.services.property_verification_service import (
    PropertyVerificationService,
    rental_listing,
)

sub = uuid.uuid4()

with Session(engine) as session:
    pid = session.execute(
        text(
            "INSERT INTO fyp.rental_properties (owner_user_id, name, property_type, "
            "address, city, state, latitude, longitude, rental_price, size_sqft, "
            "availability, verification_status, is_published) VALUES "
            "(:owner, 'Probe shoplot', 'Shop', 'Jalan Probe 1', 'Klang', 'Selangor', "
            "3.0, 101.4, 4500, 1200, 'Immediate', 'draft', false) RETURNING id"
        ),
        {"owner": str(sub)},
    ).scalar_one()
    session.commit()
    print("created listing", pid)

    svc = PropertyVerificationService(session)
    try:
        owned = svc.get_property_owned(pid, sub)
        print("ownership check OK:", owned["name"])
    except Exception as exc:  # noqa: BLE001
        print("ownership check FAILED:", type(exc).__name__, exc)

    try:
        doc = svc.add_document(
            pid, sub, "ownership", "deed", "deed.pdf", "application/pdf",
            b"%PDF-1.4 probe",
        )
        print("document added:", doc.document_id)
    except Exception as exc:  # noqa: BLE001
        print("add_document FAILED:", type(exc).__name__, exc)

    try:
        result = svc.submit(pid, sub)
        print("submit OK:", result["listing_status"], result["ownership_status"])
        listing = rental_listing(session, pid)
        print("listing status now:", listing["verification_status"])
    except Exception as exc:  # noqa: BLE001
        print("submit FAILED:", type(exc).__name__, exc)

    # cleanup
    session.execute(text("DELETE FROM verification_audit WHERE property_id = :p"), {"p": pid})
    session.execute(text("DELETE FROM verification_document WHERE property_id = :p"), {"p": pid})
    session.execute(text("DELETE FROM property_verification WHERE property_id = :p"), {"p": pid})
    session.execute(text("DELETE FROM fyp.rental_properties WHERE id = :p"), {"p": pid})
    session.commit()
    print("cleaned up")
