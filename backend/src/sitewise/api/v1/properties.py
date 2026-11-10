from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ForbiddenError
from sitewise.db.models.rental_property import RentalProperty
from sitewise.db.session import get_db
from sitewise.dependencies import ActiveUser, AuthenticatedUser, require_property_owner
from sitewise.domain import rbac
from sitewise.repositories.fyp_property_repository import FypPropertyRepository
from sitewise.services.address_validation_service import (
    AddressValidationRejected,
    AddressValidationUnavailable,
    validate_address,
)
from sitewise.services.property_service import PropertyService

router = APIRouter()


def _assert_can_mutate(prop: RentalProperty, current: AuthenticatedUser) -> None:
    """Ownership rule: a listing may be mutated by its owner or an administrator.

    Agents manage listings only through separately authorized flows, never by
    writing arbitrary property rows (see domain/rbac.py).
    """
    if prop.user_id is None:
        # Legacy row without an owning identity: only administrators may touch it.
        if not rbac.can_administer_users(current.role):
            raise ForbiddenError("This listing has no owner assigned; it is admin-managed.")
        return
    if prop.user_id != current.user_id and not rbac.can_administer_users(current.role):
        raise ForbiddenError("You can only manage your own property listings.")


@router.get("/")
def list_properties(offset: int = 0, limit: int = 100, session: Session = Depends(get_db)):
    """Public catalogue read (browse is unauthenticated by design)."""
    return PropertyService(session).list_properties(offset, limit)


@router.get("/mine")
def list_own_properties(
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """The authenticated owner's own listings."""
    from sqlmodel import select

    rows = session.exec(
        select(RentalProperty).where(RentalProperty.user_id == current.user_id)
    ).all()
    return rows


@router.get("/{property_id}")
def get_property(property_id: int, session: Session = Depends(get_db)):
    prop = PropertyService(session).get_property(property_id)
    if not prop:
        raise HTTPException(status_code=404, detail="Property not found")
    return prop


@router.post("/", status_code=201)
def create_property(
    prop: RentalProperty,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Create a listing. Ownership is stamped from the verified identity."""
    prop.user_id = current.user_id
    return PropertyService(session).create_property(prop)


@router.patch("/{property_id}")
def update_property(
    property_id: int,
    data: dict,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    prop = PropertyService(session).get_property(property_id)
    if not prop:
        raise HTTPException(status_code=404, detail="Property not found")
    _assert_can_mutate(prop, current)
    # Ownership is identity-controlled; a client cannot transfer a listing.
    data.pop("user_id", None)
    result = PropertyService(session).update_property(property_id, data)
    if not result:
        raise HTTPException(status_code=404, detail="Property not found")
    return result


@router.delete("/{property_id}", status_code=204)
def delete_property(
    property_id: int,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    prop = PropertyService(session).get_property(property_id)
    if not prop:
        raise HTTPException(status_code=404, detail="Property not found")
    _assert_can_mutate(prop, current)
    PropertyService(session).delete_property(property_id)
    return None


# ---------------------------------------------------------------------------
# Owner-submitted listings (fyp.rental_properties)
#
# The legacy ``POST /`` above writes ``public.property`` (no coordinates, not
# read by Explore). Owner submissions therefore use these endpoints, which
# write the table the rest of the product reads and always start as
# ``pending`` + unpublished.
# ---------------------------------------------------------------------------


class OwnerListingRequest(BaseModel):
    """Validated payload for one owner submission.

    Only fields the Add Property wizard actually collects are accepted.
    Verification/publication flags are NOT part of the contract — they are
    decided administratively, never by the submitter.
    """

    name: str = Field(min_length=2, max_length=160)
    address: str = Field(min_length=3, max_length=300)
    city: str = Field(min_length=2, max_length=80)
    state: str = Field(min_length=2, max_length=80)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    rental_price: float = Field(gt=0, le=10_000_000)
    size_sqft: float = Field(gt=0, le=10_000_000)
    property_type: str = Field(default="Shop", max_length=60)
    description: str | None = Field(default=None, max_length=4000)
    availability: str | None = Field(default=None, max_length=60)
    floor_level: str | None = Field(default=None, max_length=60)
    frontage_ft: float | None = Field(default=None, ge=0, le=10_000)
    has_parking: bool = False
    is_fnb_suitable: bool = False


def _run_enrichment(repo: FypPropertyRepository, property_row: dict) -> dict:
    """Compute + persist features for one property.

    A failure here must never invalidate the saved listing: the caller keeps
    the row and receives ``status: failed`` with the reason class.
    """
    try:
        snapshot = repo.enrichment_snapshot(
            float(property_row["latitude"]), float(property_row["longitude"])
        )
        stored = repo.upsert_geospatial_features(int(property_row["id"]), snapshot)
        return {"status": "ok", "features": stored}
    except Exception as exc:  # noqa: BLE001 - reported, never swallowed silently
        return {"status": "failed", "reason": type(exc).__name__, "detail": str(exc)[:300]}


@router.post("/listings", status_code=201)
def create_owner_listing(
    payload: OwnerListingRequest,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Create a real owner listing, then enrich it from the geospatial data.

    The listing is committed first (``pending``, unpublished). Enrichment is a
    separate best-effort step whose outcome is reported, so a spatial failure
    never loses the submission.
    """
    repo = FypPropertyRepository(session)
    row = repo.create_owner_listing(owner_user_id=current.user_id, payload=payload.model_dump())
    enrichment = _run_enrichment(repo, row)
    return {
        "data": row,
        "enrichment": enrichment,
        "meta": {
            "verification_status": row["verification_status"],
            "is_published": row["is_published"],
            "note": "Listings stay pending and unpublished until an administrator verifies them.",
        },
    }


@router.get("/listings/mine")
def list_own_listings(
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """The authenticated owner's submissions (newest first)."""
    return {"data": FypPropertyRepository(session).owner_listings(current.user_id)}


@router.post("/listings/{property_id}/enrich")
def enrich_listing(
    property_id: int,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Recompute features for an owned listing (idempotent).

    Only the owner or an administrator may enrich; the row is never modified
    beyond the feature table, and repeated calls produce the same single row.
    """
    repo = FypPropertyRepository(session)
    coords = repo._coords(property_id)
    owner = session.execute(
        text("SELECT owner_user_id FROM fyp.rental_properties WHERE id = :pid"),
        {"pid": property_id},
    ).first()
    if coords is None or owner is None:
        raise HTTPException(status_code=404, detail="Property not found or has no coordinates.")
    owner_uuid = owner[0]
    is_admin = rbac.can_administer_users(current.role)
    if not is_admin and (owner_uuid is None or str(owner_uuid) != str(current.user_id)):
        raise ForbiddenError("You can only enrich your own property listings.")
    snapshot = repo.enrichment_snapshot(coords[0], coords[1])
    stored = repo.upsert_geospatial_features(property_id, snapshot)
    return {"data": stored, "meta": {"property_id": property_id, "status": "ok"}}


# ---------------------------------------------------------------------------
# Address validation (Google Address Validation API, server-side only)
#
# Deliberately separate from verification: a validated address proves the
# ADDRESS exists, never ownership, availability or administrative approval.
# The key lives on this server; no client ever receives it.
# ---------------------------------------------------------------------------


class AddressValidationRequest(BaseModel):
    address_lines: list[str] = Field(min_length=1, max_length=3)
    city: str | None = Field(default=None, max_length=80)
    state: str | None = Field(default=None, max_length=80)
    postcode: str | None = Field(default=None, max_length=10)
    region_code: str = Field(default="MY", min_length=2, max_length=2)


@router.post("/validate-address")
def validate_property_address(
    payload: AddressValidationRequest,
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Validate an address before submission.

    ``200`` returns the provider verdict; ``503`` means the provider is not
    configured/enabled (a precise reason is included); ``422`` means the
    payload itself was rejected. Address validity is reported separately from
    property verification status.
    """
    lines = [line.strip() for line in payload.address_lines if line.strip()]
    if not lines or not any(lines):
        raise HTTPException(status_code=422, detail="At least one address line is required.")
    try:
        result = validate_address(
            address_lines=lines,
            region_code=payload.region_code.upper(),
            locality=payload.city,
            postal_code=payload.postcode,
            administrative_area=payload.state,
        )
    except AddressValidationRejected as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except AddressValidationUnavailable as exc:
        raise HTTPException(
            status_code=503,
            detail={"code": "address_validation_unavailable", "message": str(exc)},
        ) from exc
    return {
        "data": result,
        "meta": {
            "verification_status_unchanged": True,
            "note": "Address validation does not verify ownership or approve the listing.",
        },
    }
