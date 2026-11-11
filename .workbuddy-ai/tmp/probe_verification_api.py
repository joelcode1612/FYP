"""Replicate the failing verification API sequence without pytest."""

from __future__ import annotations

import io
import uuid

from fastapi.testclient import TestClient

from sitewise.core.security import JWKSClient
from sitewise.db.session import engine
from sitewise.main import app
from sqlalchemy import text
from sqlmodel import Session
import sys

sys.path.insert(0, ".")

from tests.conftest import (  # noqa: E402
    TEST_EMAIL_DOMAIN,
    TEST_KID,
    _public_jwk,
    make_token,
)


def _fake_fetch(self: JWKSClient):
    self._keys = {TEST_KID: dict(_public_jwk)}


JWKSClient._fetch = _fake_fetch  # type: ignore[method-assign]

sub = str(uuid.uuid4())
token = make_token(sub=sub, email=f"probe-{sub[:8]}@{TEST_EMAIL_DOMAIN}")
auth = {"Authorization": f"Bearer {token}"}

with TestClient(app) as client:
    r = client.get("/api/v1/auth/me", headers=auth)
    print("auth/me:", r.status_code)

    with Session(engine) as session:
        pid = session.execute(
            text(
                "INSERT INTO fyp.rental_properties (owner_user_id, name, "
                "property_type, address, city, state, latitude, longitude, "
                "rental_price, size_sqft, availability, verification_status, "
                "is_published) VALUES (:owner, 'Probe shoplot', 'Shop', "
                "'Jalan Probe 1', 'Klang', 'Selangor', 3.0, 101.4, 4500, 1200, "
                "'Immediate', 'draft', false) RETURNING id"
            ),
            {"owner": sub},
        ).scalar_one()
        session.commit()
    print("listing:", pid)

    r = client.post(
        f"/api/v1/properties/{pid}/verification/documents",
        headers=auth,
        files={"file": ("deed.pdf", io.BytesIO(b"%PDF-1.4 probe"), "application/pdf")},
        data={"verification_type": "ownership", "document_type": "deed"},
    )
    print("upload doc:", r.status_code, r.text[:300])

    r = client.post(
        f"/api/v1/properties/{pid}/verification/submit", headers=auth
    )
    print("submit:", r.status_code, r.text[:300])

    r = client.get(f"/api/v1/properties/listings/{pid}", headers=auth)
    print("listing after submit:", r.status_code, r.text[:200])

    with Session(engine) as session:
        for table in ("verification_audit", "verification_document",
                      "property_verification"):
            session.execute(text(f"DELETE FROM {table} WHERE property_id = :p"), {"p": pid})
        session.execute(text("DELETE FROM fyp.rental_properties WHERE id = :p"), {"p": pid})
        session.commit()
    print("cleaned up")
