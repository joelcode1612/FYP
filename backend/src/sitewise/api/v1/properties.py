

import logging
from typing import Literal

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ForbiddenError
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, require_property_owner
from sitewise.domain import rbac
from sitewise.repositories.fyp_property_repository import FypPropertyRepository
from sitewise.services.address_validation_service import (
    AddressValidationRejected,
    AddressValidationUnavailable,
    validate_address,
)
from sitewise.services.property_enrichment_service import PropertyEnrichmentService
from sitewise.services.property_management_service import (
    resolve_listings,
    resolve_management,
)

router = APIRouter()

logger = logging.getLogger("sitewise.properties")

#: The only commercial property types the Add Property form may submit.
#: Mirrors `shared_logic/lib/src/domain/data/add_property_rules.dart`; the
#: backend is authoritative, so a client cannot widen the list.
COMMERCIAL_PROPERTY_TYPES = (
    "Shoplot",
    "Retail Space",
    "Ground Floor Shop",
    "Corner Shoplot",
    "Retail Unit",
    "Kiosk",
    "Commercial F&B Premise",
)

#: Legacy spellings still present in existing rows / older clients. They are
#: normalised instead of rejected so an edit of an old listing keeps working.
_LEGACY_PROPERTY_TYPES = {
    "shop": "Shoplot",
    "shop lot": "Shoplot",
    "shophouse": "Shoplot",
    "shoplot / shophouse": "Shoplot",
    "ground floor retail": "Ground Floor Shop",
    "corner retail unit": "Corner Shoplot",
    "shopping mall unit": "Retail Unit",
    "commercial kiosk": "Kiosk",
    "standalone commercial": "Retail Unit",
}


def normalize_property_type(value: str | None) -> str:
    """Return an allowed commercial type or raise ``ValueError``."""
    raw = (value or "").strip()
    if not raw:
        raise ValueError("Select a commercial property type.")
    for allowed in COMMERCIAL_PROPERTY_TYPES:
        if allowed.lower() == raw.lower():
            return allowed
    mapped = _LEGACY_PROPERTY_TYPES.get(raw.lower())
    if mapped:
        return mapped
    raise ValueError(
        "property_type must be one of: " + ", ".join(COMMERCIAL_PROPERTY_TYPES)
    )


# ---------------------------------------------------------------------------
# Owner-submitted listings (fyp.rental_properties) — the ONLY operational
# property-write workflow.
#
# The legacy CRUD endpoints that wrote ``public.property`` were retired with
# migration 0005: the legacy table was empty, unused by any live client, and
# its removal leaves ``fyp.rental_properties`` as the single canonical
# operational property source (read by Explore, drafts, verification, admin
# review and photos). No duplicate write path remains.
# ---------------------------------------------------------------------------


class OwnerListingRequest(BaseModel):
    """Validated payload for one owner submission.

    Only fields the Add Property wizard actually collects are accepted.
    Verification/publication flags are NOT part of the contract — they are
    decided administratively, never by the submitter.
    """

    name: str = Field(min_length=4, max_length=160)
    address: str = Field(min_length=5, max_length=300)
    city: str = Field(min_length=2, max_length=80)
    state: str = Field(min_length=2, max_length=80)
    postcode: str = Field(pattern=r"^\d{5}$")
    # Coordinates are optional: the wizard no longer geocodes, and the
    # backend's enrichment/admin review resolves the location afterwards.
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    rental_price: float = Field(gt=0, le=10_000_000)
    size_sqft: float = Field(gt=0, le=10_000_000)
    property_type: str = Field(default="Shoplot", max_length=60)
    description: str | None = Field(default=None, max_length=4000)
    availability: str | None = Field(default=None, max_length=60)
    floor_level: str | None = Field(default=None, max_length=60)
    frontage_ft: float | None = Field(default=None, ge=0, le=10_000)
    has_parking: bool = False
    is_fnb_suitable: bool = False

    @field_validator("name", "address", "city", "state")
    @classmethod
    def _trim_required(cls, value: str) -> str:
        trimmed = value.strip()
        if not trimmed:
            raise ValueError("This field is required.")
        return trimmed

    @field_validator("property_type")
    @classmethod
    def _commercial_type(cls, value: str) -> str:
        return normalize_property_type(value)


def _run_enrichment(repo: FypPropertyRepository, property_row: dict) -> dict:
    """Compute + persist initial features for one newly created property.

    Goes through FeatureRefreshService so the attempt is recorded as a
    pending/current/failed freshness state that Admin and Entrepreneur clients
    can display and retry. The property row is committed BEFORE this call, so
    a failure here never invalidates the saved listing; no external data
    download is triggered (local PostGIS only).
    """
    from sitewise.services.feature_refresh_service import FeatureRefreshService

    try:
        result = FeatureRefreshService(repo.session).recalculate_new_property(
            int(property_row["id"])
        )
        if result["successful_computations"] != 1:
            return {
                "status": "failed",
                "reason": "feature_calculation_unavailable",
                "detail": "; ".join(result["errors"])[:300],
                "freshness": "pending_or_failed",
            }
        # Record the per-category lifecycle for the SAME values. The wide
        # feature row above stays the measurement contract; this keeps the
        # admin review panel from reporting "not started" for a listing whose
        # features were in fact calculated. Same source tables and predicates,
        # so the numbers agree; a failure here must not fail the creation.
        try:
            PropertyEnrichmentService(repo.session).run(
                int(property_row["id"]), phase="postgis"
            )
        except Exception as exc:  # noqa: BLE001 - additive bookkeeping only
            logger.warning(
                "enrichment.category_state_failed property=%s error=%s",
                property_row.get("id"), exc,
            )
        return {
            "status": "ok",
            # Preserve the original response contract: the stored feature row
            # (competitor/demand/accessibility counts) is returned exactly as
            # before, with the freshness state added alongside it.
            "features": repo.get_geo_features(int(property_row["id"])) or {},
            "freshness": "current",
        }
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

    Google Address Validation is no longer part of the create path: the
    listing is stored with the owner's address as entered and its location is
    resolved afterwards by the geospatial enrichment and admin review. The
    standalone ``/validate-address`` endpoint remains available for callers
    that want an explicit check.
    """
    body = payload.model_dump()

    repo = FypPropertyRepository(session)
    row = repo.create_owner_listing(owner_user_id=current.user_id, payload=body)
    enrichment = _run_enrichment(repo, row)
    return {
        "data": row,
        "enrichment": enrichment,
        "meta": {
            "verification_status": row["verification_status"],
            "is_published": row["is_published"],
            "address_validation": {
                "status": row.get("address_validation_status"),
                "granularity": None,
                "formatted_address": row.get("address_formatted"),
                "note": "Address validation is not performed at submission; "
                "location is resolved by enrichment and admin review.",
            },
            "note": "Listings stay pending and unpublished until an administrator verifies them.",
        },
    }


@router.get("/listings/mine")
def list_own_listings(
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """The authenticated owner's submissions, drafts included (newest first).

    Each row carries the derived management state so the owner can see when an
    agent has been assigned to manage it. Ownership stays on the row; the agent
    adds responsibility, it does not take the listing away.
    """
    rows = FypPropertyRepository(session).owner_listings(current.user_id)
    management = resolve_listings(session, [int(r["id"]) for r in rows])
    return {
        "data": [
            {**row, "management": management.get(int(row["id"]))} for row in rows
        ]
    }


# ---------------------------------------------------------------------------
# Owner draft lifecycle (Add Property wizard)
#
# Drafts persist in fyp.rental_properties with verification_status='draft'
# and is_published=false: invisible to Explore, absent from the admin queue,
# resumable across sessions. Submission goes through the EXISTING property
# verification workflow (property_verification.py), which after migration
# 0004 is bound to this same table.
# ---------------------------------------------------------------------------


class OwnerDraftRequest(BaseModel):
    """Partial Add-Property payload. Drafts may omit everything except a
    name (draft creation); updates may omit any field. Final submission
    re-validates completeness server-side."""

    name: str | None = Field(default=None, min_length=1, max_length=160)
    property_type: str | None = Field(default=None, max_length=60)
    description: str | None = Field(default=None, max_length=4000)
    address: str | None = Field(default=None, max_length=300)
    city: str | None = Field(default=None, max_length=80)
    state: str | None = Field(default=None, max_length=80)
    postcode: str | None = Field(default=None, pattern=r"^\d{5}$")
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    rental_price: float | None = Field(default=None, gt=0, le=10_000_000)
    size_sqft: float | None = Field(default=None, gt=0, le=10_000_000)
    availability: str | None = Field(default=None, max_length=60)
    floor_level: str | None = Field(default=None, max_length=60)
    frontage_ft: float | None = Field(default=None, ge=0, le=10_000)
    has_parking: bool = False
    is_fnb_suitable: bool = False


def _owned_listing_or_error(
    repo: FypPropertyRepository, property_id: int, current: AuthenticatedUser
) -> dict:
    listing = repo.owner_listing(property_id)
    if listing is None:
        raise HTTPException(status_code=404, detail="Property not found.")
    owner = listing.get("owner_user_id")
    is_admin = rbac.can_administer_users(current.role)
    if not is_admin and (owner is None or str(owner) != str(current.user_id)):
        raise ForbiddenError("You can only manage your own property listings.")
    return listing


@router.post("/listings/drafts", status_code=201)
def create_owner_draft(
    payload: OwnerDraftRequest,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Persist a NEW draft. The owner identity comes from the verified token;
    the database assigns the persistent id; the draft stays unpublished and
    outside the admin queue."""
    if not (payload.name or "").strip():
        raise HTTPException(
            status_code=422, detail="A draft property needs at least a name."
        )
    repo = FypPropertyRepository(session)
    row = repo.create_owner_draft(
        owner_user_id=current.user_id, payload=payload.model_dump()
    )
    return {
        "data": row,
        "meta": {
            "verification_status": row["verification_status"],
            "is_published": row["is_published"],
            "note": "Draft saved. Submit for verification when complete.",
        },
    }


@router.get("/listings/{property_id}")
def get_own_listing(
    property_id: int,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """One owned listing (any status) with its photos — the resume-a-draft
    read. Another owner's draft is 403, never leaked."""
    repo = FypPropertyRepository(session)
    listing = _owned_listing_or_error(repo, property_id, current)
    return {
        "data": {
            **listing,
            "photos": repo.listing_photos(property_id),
            "management": resolve_management(session, listing_id=property_id),
        }
    }


@router.patch("/listings/{property_id}")
def update_own_listing(
    property_id: int,
    payload: OwnerDraftRequest,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Update an owned draft. Editing is blocked once a submission is
    awaiting review (pending/under_review/verified) so submitted evidence
    cannot be invalidated; draft, rejected and corrections-requested states
    remain editable, and a repeat save updates the SAME row."""
    from sitewise.db.models.property_verification import can_resubmit
    from sitewise.services.property_verification_service import verification_row

    repo = FypPropertyRepository(session)
    _owned_listing_or_error(repo, property_id, current)
    verification = verification_row(session, property_id)
    editable = verification is None or can_resubmit(
        verification.listing_status, verification.ownership_status
    )
    if not editable:
        raise HTTPException(
            status_code=409,
            detail="This property is awaiting or has passed review; "
            "its details can no longer be edited.",
        )
    fields = payload.model_dump(exclude_unset=True)
    if fields.get("name") is None:
        # A null name must not null out the NOT NULL column: keep the
        # existing draft name.
        fields.pop("name", None)
    row = repo.update_owner_listing(property_id, fields)
    if row is None:
        raise HTTPException(status_code=404, detail="Property not found.")
    return {"data": row}


# ---------------------------------------------------------------------------
# Property photos (display media — public bucket, permanent URLs)
# ---------------------------------------------------------------------------


@router.post("/listings/{property_id}/photos", status_code=201)
async def upload_listing_photo(
    property_id: int,
    file: UploadFile = File(...),  # noqa: B008 - FastAPI dependency idiom
    caption: str = Form(default=""),  # noqa: B008
    is_primary: bool = Form(default=False),  # noqa: B008
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Upload one property photo (JPG/PNG/WebP, <= 8 MB) to public storage
    and persist its permanent URL on the listing. The bytes are uploaded
    BEFORE the row insert, so a failed upload never leaves a dangling row
    and the draft stays intact."""
    from sitewise.db.models.property_verification import can_resubmit
    from sitewise.services import photo_storage
    from sitewise.services.photo_storage import (
        PhotoRejected,
        PhotoStorageUnavailable,
    )
    from sitewise.services.property_verification_service import verification_row

    repo = FypPropertyRepository(session)
    _owned_listing_or_error(repo, property_id, current)
    verification = verification_row(session, property_id)
    editable = verification is None or can_resubmit(
        verification.listing_status, verification.ownership_status
    )
    if not editable:
        raise HTTPException(
            status_code=409,
            detail="This property is awaiting or has passed review; "
            "photos can no longer be changed.",
        )
    data = await file.read()
    try:
        ext = photo_storage.validate_photo(
            file.filename or "", file.content_type or "", len(data)
        )
        url = photo_storage.save_photo(data, ext, file.content_type or "")
    except PhotoRejected as exc:
        raise HTTPException(
            status_code=413 if exc.oversized else 422, detail=str(exc)
        ) from exc
    except PhotoStorageUnavailable as exc:
        # 503 with the exact reason; the draft is untouched.
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    photo = repo.add_listing_photo(
        property_id, url, (caption or "").strip()[:200], is_primary
    )
    return {"data": photo}


@router.get("/listings/{property_id}/photos")
def list_listing_photos(
    property_id: int,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    repo = FypPropertyRepository(session)
    _owned_listing_or_error(repo, property_id, current)
    return {"data": repo.listing_photos(property_id)}


@router.delete("/listings/{property_id}/photos/{photo_id}", status_code=200)
def delete_listing_photo(
    property_id: int,
    photo_id: int,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    from sitewise.services import photo_storage

    repo = FypPropertyRepository(session)
    _owned_listing_or_error(repo, property_id, current)
    deleted = repo.delete_listing_photo(property_id, photo_id)
    if deleted is None:
        raise HTTPException(status_code=404, detail="Photo not found.")
    photo_storage.delete_photo(deleted["url"])
    return {"data": {"deleted": photo_id}}


@router.post("/listings/{property_id}/photos/{photo_id}/primary")
def set_primary_listing_photo(
    property_id: int,
    photo_id: int,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    repo = FypPropertyRepository(session)
    _owned_listing_or_error(repo, property_id, current)
    if not repo.set_primary_listing_photo(property_id, photo_id):
        raise HTTPException(status_code=404, detail="Photo not found.")
    return {"data": repo.listing_photos(property_id)}


class EnrichRequest(BaseModel):
    """Which enrichment phase to run.

    ``postgis`` and ``population`` are the two phases the Add Property flow
    starts separately. ``all`` is the default so an existing client that sends
    no body keeps its old behaviour.
    """

    phase: Literal["postgis", "population", "all"] = "all"
    force: bool = False
    categories: list[str] | None = Field(
        default=None,
        description=(
            "Optional explicit subset. Unknown names are ignored so a client "
            "cannot ask for a category that does not exist."
        ),
    )


def _require_owned_listing(
    session: Session, property_id: int, current: AuthenticatedUser
) -> None:
    """404 when the listing is missing, 403 when it belongs to someone else.

    The owner identity always comes from the verified token; an administrator
    may act on any listing.
    """
    row = session.execute(
        text("SELECT owner_user_id FROM fyp.rental_properties WHERE id = :pid"),
        {"pid": property_id},
    ).first()
    if row is None:
        raise HTTPException(status_code=404, detail="Property not found.")
    owner_uuid = row[0]
    if rbac.can_administer_users(current.role):
        return
    if owner_uuid is None or str(owner_uuid) != str(current.user_id):
        raise ForbiddenError("You can only enrich your own property listings.")


@router.post("/listings/{property_id}/enrich")
def enrich_listing(
    property_id: int,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
    payload: EnrichRequest | None = None,
):
    """Run one enrichment phase for an owned listing.

    The two phases are independent on purpose:

    * ``phase="postgis"`` (Phase 1) computes F&B competitors, demand
      generators, roads/transportation and parking. Fast, and safe to call
      while the owner is still filling the form.
    * ``phase="population"`` (Phase 2) runs the raster population chain on its
      own. It is the only category that can legitimately be unavailable, and
      calling it never recomputes Phase 1.
    * ``phase="all"`` (default, backward compatible with callers that send no
      body) runs both.

    Idempotent: a category already ``current`` for the same coordinates is not
    recalculated unless ``force`` is set. A request that arrives while another
    request owns a category leaves that category alone instead of starting a
    duplicate computation.
    """
    _require_owned_listing(session, property_id, current)
    phase = payload.phase if payload is not None else "all"
    force = bool(payload.force) if payload is not None else False
    categories = payload.categories if payload is not None else None

    service = PropertyEnrichmentService(session)
    try:
        summary = service.run(
            property_id, phase=phase, categories=categories, force=force
        )
    except LookupError:
        raise HTTPException(
            status_code=404, detail="Property not found or has no coordinates."
        )
    # Preserve the original response contract: the stored feature row (with its
    # flat competitor/demand/accessibility columns) is still the payload, and
    # the per-category lifecycle is added alongside it. A client written against
    # the old shape keeps working; a client that needs the new states reads
    # `categories`.
    stored = FypPropertyRepository(session).get_geo_features(property_id) or {}
    return {
        "data": {**stored, **summary},
        "meta": {"property_id": property_id, "status": "ok"},
    }


@router.get("/listings/{property_id}/enrichment")
def enrichment_state(
    property_id: int,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Stored per-category enrichment state.

    Reads what is stored and never recalculates: the Add Property progress
    panel, the admin review and the property-detail page all poll this and
    must not trigger work by looking.
    """
    _require_owned_listing(session, property_id, current)
    service = PropertyEnrichmentService(session)
    service.ensure_schema()
    return {"data": service.summary(property_id), "meta": {"property_id": property_id}}


@router.post("/listings/{property_id}/enrichment/{category}/retry")
def retry_enrichment_category(
    property_id: int,
    category: str,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Retry exactly one category.

    Scoped to a single category so a failed population raster never forces the
    four PostGIS categories to be recomputed.
    """
    _require_owned_listing(session, property_id, current)
    service = PropertyEnrichmentService(session)
    try:
        summary = service.retry(property_id, category)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    except LookupError:
        raise HTTPException(
            status_code=404, detail="Property not found or has no coordinates."
        )
    return {"data": summary, "meta": {"property_id": property_id, "status": "ok"}}


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
