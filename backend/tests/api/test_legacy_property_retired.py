"""Legacy ``public.property`` retirement (migration 0005).

Asserts the post-consolidation contract:
* the obsolete ``RentalProperty`` SQLModel is out of the metadata, so
  ``create_all`` can never resurrect ``public.property``;
* ``FypRentalProperty`` remains mapped to the canonical ``fyp`` schema table;
* the legacy ``/properties`` CRUD endpoints are gone while the canonical
  owner-listing endpoints still work;
* no SQLModel still declares a FK to ``property.property_id``.
"""

from __future__ import annotations

import uuid

from sqlmodel import SQLModel

from sitewise.db.models import FypRentalProperty

from ..conftest import TEST_EMAIL_DOMAIN, make_token


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_rentalproperty_model_is_retired_from_metadata():
    assert "property" not in SQLModel.metadata.tables, (
        "public.property must not be recreated by create_all"
    )
    # The canonical operational model stays mapped to the fyp schema.
    table = FypRentalProperty.__table__
    assert table.name == "rental_properties"
    assert table.schema == "fyp"


def test_no_sqlmodel_declares_the_legacy_property_fk():
    declaring = []
    for table in SQLModel.metadata.tables.values():
        for column in table.columns:
            for fk in column.foreign_keys:
                if str(fk.target_fullname) in ("property.property_id", "property.id"):
                    declaring.append(f"{table.name}.{column.name}")
    assert declaring == []


def test_legacy_property_crud_routes_are_gone(client):
    # The retired legacy catalogue read: no route, so 404 (not 200/422).
    assert client.get("/api/v1/properties/").status_code == 404
    assert client.get("/api/v1/properties/123").status_code == 404


def test_canonical_owner_listing_routes_still_serve(client):
    sub = str(uuid.uuid4())
    token = make_token(
        sub=sub,
        email=f"legacy-retired-{sub[:8]}@{TEST_EMAIL_DOMAIN}",
    )
    assert client.get("/api/v1/auth/me", headers=auth(token)).status_code == 200
    response = client.get(
        "/api/v1/properties/listings/mine", headers=auth(token)
    )
    assert response.status_code == 200
    assert response.json()["data"] == []
