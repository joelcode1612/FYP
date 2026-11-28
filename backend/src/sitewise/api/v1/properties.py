

import logging
from datetime import date
from decimal import Decimal, ROUND_HALF_UP
from typing import Literal
from uuid import NAMESPACE_URL, UUID, uuid5

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel, Field, ValidationInfo, field_validator
from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ForbiddenError
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, require_property_owner
from sitewise.domain import rbac
from sitewise.repositories.agent_assignment_repository import (
    AgentAssignmentRepository,
)
from sitewise.repositories.fyp_property_repository import FypPropertyRepository
from sitewise.services.address_preview_service import (
    canonical_address_hash,
    preview_address,
    verify_confirmation_token,
)
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
from sitewise.services import provider_scope

router = APIRouter()

logger = logging.getLogger("sitewise.properties")

#: The only commercial property types the Add Property form may submit.
#: Mirrors `shared_logic/lib/src/domain/data/add_property_rules.dart`; the
#: backend is authoritative, so a client cannot widen the list.
COMMERCIAL_PROPERTY_TYPES = (
    "Shoplot",
    "Retail Space",
)

#: Legacy spellings still present in existing rows / older clients. They are
#: normalised instead of rejected so an edit of an old listing keeps working.
_LEGACY_PROPERTY_TYPES = {
    "shop": "Shoplot",
    "shop lot": "Shoplot",
    "shophouse": "Shoplot",
    "shoplot / shophouse": "Shoplot",
    "ground floor retail": "Shoplot",
    "corner retail unit": "Shoplot",
    "shopping mall unit": "Retail Space",
    "commercial kiosk": "Retail Space",
    "standalone commercial": "Retail Space",
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
    # Coordinates are deliberately server-owned; draft forms cannot replace
    # the geocoded location when changing rental/property information.
    rental_price: float = Field(gt=0, le=10_000_000)
    size_sqft: float = Field(gt=0, le=10_000_000)
    property_type: str = Field(default="Shoplot", max_length=60)
    description: str | None = Field(default=None, max_length=4000)
    availability: str | None = Field(default=None, max_length=60)
    floor_level: float | None = Field(default=None, ge=-1, le=10000)
    floor_description: str | None = Field(default=None, max_length=40)
    frontage_ft: float | None = Field(default=None, ge=0, le=10_000)
    furnishing: str | None = Field(default=None, max_length=40)
    tenure: str | None = Field(default=None, max_length=20)
    unit_position: str | None = Field(default=None, max_length=40)
    has_parking: bool | None = None
    lease_duration_months: int | None = Field(default=None, ge=1, le=360)
    lease_duration_negotiable: bool | None = None
    available_from: date | None = None
    rental_deposit_myr: float | None = Field(default=None, ge=0, le=10_000_000)
    title_type: str | None = Field(default=None, max_length=30)

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

    @field_validator("availability")
    @classmethod
    def _valid_availability(cls, value: str | None) -> str | None:
        return _choice(value, {"Ready to move in", "Available from a specific date", "By arrangement"}, "availability")

    @field_validator("floor_description")
    @classmethod
    def _valid_floor_description(cls, value: str | None) -> str | None:
        return _choice(value, {"Basement", "Ground floor", "First floor", "Second floor", "Third floor or above", "Multiple floors"}, "floor level")

    @field_validator("furnishing")
    @classmethod
    def _valid_furnishing(cls, value: str | None) -> str | None:
        return _choice(value, {"Bare unit", "Partially fitted", "Fully fitted", "Existing F&B fit-out", "Not sure"}, "furnishing condition")

    @field_validator("tenure")
    @classmethod
    def _valid_tenure(cls, value: str | None) -> str | None:
        return _choice(value, {"Freehold", "Leasehold", "Not sure"}, "land tenure")

    @field_validator("unit_position")
    @classmethod
    def _valid_unit_position(cls, value: str | None) -> str | None:
        return _choice(value, {"Intermediate unit", "Corner unit", "End lot", "Standalone unit", "Not sure"}, "unit position")

    @field_validator("title_type")
    @classmethod
    def _valid_title_type(cls, value: str | None) -> str | None:
        return _choice(value, {"Individual title", "Strata title", "Master title", "Not sure"}, "property title type")


def _run_enrichment(repo: FypPropertyRepository, property_row: dict) -> dict:
    """Compute + persist initial features for one newly created property.

    Goes through FeatureRefreshService so the attempt is recorded as a
    pending/current/failed freshness state that Admin and Entrepreneur clients
    can display and retry. The property row is committed BEFORE this call, so
    a failure here never invalidates the saved listing; no external data
    download is triggered (local PostGIS only).

    Population is resolved through the REAL provider chain (pre-computed row,
    WorldPop 2025 PostGIS raster, LandScan, configured GeoTIFF) instead of
    being carried forward from an earlier row: the category lifecycle records
    what actually happened, and the response reports it. ``status`` is ``ok``
    only when every attempted category settled honestly (measured or explicitly
    unavailable); any ``failed`` category yields ``partial`` with the reasons.
    """
    from sitewise.ingestion.state import RefreshState
    from sitewise.services.feature_refresh_service import FeatureRefreshService
    from sitewise.services.property_enrichment_service import (
        CATEGORIES,
        CALCULATION_VERSION,
        CATEGORY_PHASE,
        PHASE_POSTGIS,
        PropertyEnrichmentService,
    )

    property_id = int(property_row["id"])
    try:
        result = FeatureRefreshService(repo.session).recalculate_new_property(
            property_id
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
        enrichment = PropertyEnrichmentService(repo.session)
        attempted = [
            c for c in CATEGORIES if CATEGORY_PHASE[c] == PHASE_POSTGIS
        ] + ["population"]
        try:
            enrichment.run(property_id, phase="postgis")
            # Population is measured, never borrowed: the provider chain
            # either produces a real measurement for these coordinates or
            # settles the category as explicitly unavailable.
            enrichment.run(property_id, categories=["population"])
        except Exception as exc:  # noqa: BLE001 - additive bookkeeping only
            logger.warning(
                "enrichment.category_state_failed property=%s error=%s",
                property_row.get("id"), exc,
            )
        # Honest freshness: when the population chain measured a real value
        # for these coordinates the whole set is current; otherwise the
        # category row (and the summary the UI polls) carries the truth.
        try:
            population_state = enrichment.summary(property_id)["categories"][
                "population"
            ]["status"]
            if population_state == "current":
                RefreshState(repo.session).set_freshness(
                    property_id,
                    status="current",
                    version=CALCULATION_VERSION,
                    success=True,
                )
        except Exception:  # noqa: BLE001 - never fail creation on bookkeeping
            population_state = "unknown"
        states = enrichment.states(property_id)
        failed = [
            (name, states[name].get("last_error"))
            for name in attempted
            if states[name]["status"] == "failed"
        ]
        freshness = RefreshState(repo.session).freshness_payload(property_id)
        payload: dict = {
            "status": "partial" if failed else "ok",
            # Preserve the original response contract: the stored feature row
            # (competitor/demand/accessibility counts) is returned exactly as
            # before, with the freshness state added alongside it.
            "features": repo.get_geo_features(property_id) or {},
            "freshness": freshness.get("status", "unknown"),
            "population_status": population_state,
            "categories": {name: states[name]["status"] for name in attempted},
        }
        if failed:
            payload["detail"] = "; ".join(
                f"{name}: {str(error)[:120]}" for name, error in failed
            )[:300]
        return payload
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
    _owner_write_only(current)
    raise HTTPException(status_code=410, detail="Use /properties/listings/drafts, then request an Agent. Direct publication submission is retired.")
    body = payload.model_dump()

    repo = FypPropertyRepository(session)
    agent_id = _provider_agent_id(session, current)
    row = repo.create_owner_listing(
        owner_user_id=None if agent_id is not None else current.user_id,
        payload=body,
    )
    if agent_id is not None:
        AgentAssignmentRepository(session).assign(
            int(row["id"]), agent_id, assigned_by=None
        )
        row = repo.owner_listing(int(row["id"])) or row
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

    Each row also carries its display photos, exactly as the single-listing read
    does. Without them the workspace cannot thumbnail a listing, and a draft
    that already has photographs still reads as needing them.
    """
    repo = FypPropertyRepository(session)
    rows = repo.owner_listings(current.user_id)
    ids = [int(row["id"]) for row in rows]
    management = resolve_listings(session, ids)
    photos = repo.listing_photos_by_ids(ids)
    locked_ids = set()
    if ids:
        locked_ids = set(session.execute(text("""
            SELECT listing_id FROM fyp.agent_listing_assignment
             WHERE listing_id = ANY(CAST(:ids AS integer[]))
               AND workflow_status IN ('requested', 'accepted', 'needs_correction')
        """), {"ids": ids}).scalars().all())
    return {
        "data": [
            {
                **row,
                "management": management.get(int(row["id"])),
                "photos": photos.get(int(row["id"]), []),
                "owner_edit_locked": int(row["id"]) in locked_ids,
            }
            for row in rows
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


def _owner_write_only(current: AuthenticatedUser) -> None:
    """Only a property owner registers or modifies original listing facts."""
    if rbac.canonical_role(current.role) != rbac.ROLE_OWNER:
        raise ForbiddenError("Only a Property Owner may register or edit property details.")


# SITEWISE_PRESERVE_AGENT_EVIDENCE_V1
# Compare the effective write, not the mere presence of a field in a payload.
# Decimal-normalise numeric properties so 22.0 and Decimal('22.00') agree.
def _owner_field_changed(existing: object, new: object, column: str) -> bool:
    from decimal import Decimal, InvalidOperation

    if column in ('rental_price', 'size_sqft', 'floor_level', 'frontage_ft',
                  'latitude', 'longitude', 'has_parking', 'is_fnb_suitable'):
        def number(value: object):
            if value is None or value == '':
                return None
            if isinstance(value, bool):
                return int(value)
            try:
                return Decimal(str(value))
            except (InvalidOperation, TypeError, ValueError):
                return str(value)
        return number(existing) != number(new)
    if column == 'lease_duration_negotiable':
        return existing is not new
    return str(existing if existing is not None else '').strip() != str(new if new is not None else '').strip()


def _choice(value: str | None, allowed: set[str], label: str) -> str | None:
    if value is None or not value.strip():
        return None
    normalized = value.strip()
    if normalized not in allowed:
        raise ValueError(f"Choose a valid {label} option.")
    return normalized


class OwnerDraftRequest(BaseModel):
    """Partial Add-Property payload. Drafts may omit everything except a
    name (draft creation); updates may omit any field. Final submission
    re-validates completeness server-side."""

    draft_request_id: UUID | None = None
    name: str | None = Field(default=None, min_length=1, max_length=160)
    property_type: str | None = Field(default=None, max_length=60)
    description: str | None = Field(default=None, max_length=4000)
    address: str | None = Field(default=None, max_length=300)
    city: str | None = Field(default=None, max_length=80)
    state: str | None = Field(default=None, max_length=80)
    postcode: str | None = Field(default=None, pattern=r"^\d{5}$")
    # Coordinates are server-generated and are not writable through drafts.
    rental_price: Decimal | None = Field(default=None, gt=0, le=10_000_000)
    size_sqft: Decimal | None = Field(default=None, gt=0, le=10_000_000)
    availability: str | None = Field(default=None, max_length=60)
    floor_level: Decimal | None = Field(default=None, ge=-1, le=Decimal("9999.9"))
    floor_description: str | None = Field(default=None, max_length=40)
    frontage_ft: Decimal | None = Field(default=None, ge=0, le=10_000)
    furnishing: str | None = Field(default=None, max_length=40)
    tenure: str | None = Field(default=None, max_length=20)
    unit_position: str | None = Field(default=None, max_length=40)
    has_parking: bool | None = None
    lease_duration_months: int | None = Field(default=None, ge=1, le=360)
    lease_duration_negotiable: bool | None = None
    available_from: date | None = None
    rental_deposit_myr: Decimal | None = Field(default=None, ge=0, le=10_000_000)
    title_type: str | None = Field(default=None, max_length=30)
    # Signed evidence from POST /address-preview: the server-obtained verdict
    # for the EXACT address, confirmed by the user on the map. Coordinates are
    # derived from the token (server-controlled), never from client lat/lng.
    address_confirmation_token: str | None = Field(default=None, max_length=4096)

    @field_validator("*", mode="before")
    @classmethod
    def _valid_database_text(cls, value):
        if isinstance(value, str) and "\x00" in value:
            raise ValueError("Remove null characters.")
        return value

    @field_validator("name")
    @classmethod
    def _draft_name(cls, value: str | None) -> str:
        if value is None or not value.strip():
            raise ValueError("Enter a property title.")
        return value.strip()

    @field_validator("property_type")
    @classmethod
    def _commercial_type(cls, value: str | None) -> str:
        return normalize_property_type(value)

    @field_validator("rental_price", "size_sqft", "floor_level", "frontage_ft", "rental_deposit_myr")
    @classmethod
    def _normalize_numeric(cls, value: Decimal | None, info: ValidationInfo) -> Decimal | None:
        if value is None:
            return None
        precision = Decimal("0.1") if info.field_name == "floor_level" else Decimal("0.01")
        rounded = value.quantize(precision, rounding=ROUND_HALF_UP)
        if info.field_name in ("rental_price", "size_sqft") and rounded == 0:
            raise ValueError("Enter a value of at least 0.01 after rounding.")
        return rounded

    @field_validator("availability")
    @classmethod
    def _valid_availability(cls, value: str | None) -> str | None:
        return _choice(value, {"Ready to move in", "Available from a specific date", "By arrangement"}, "availability")

    @field_validator("floor_description")
    @classmethod
    def _valid_floor_description(cls, value: str | None) -> str | None:
        return _choice(value, {"Basement", "Ground floor", "First floor", "Second floor", "Third floor or above", "Multiple floors"}, "floor level")

    @field_validator("furnishing")
    @classmethod
    def _valid_furnishing(cls, value: str | None) -> str | None:
        return _choice(value, {"Bare unit", "Partially fitted", "Fully fitted", "Existing F&B fit-out", "Not sure"}, "furnishing condition")

    @field_validator("tenure")
    @classmethod
    def _valid_tenure(cls, value: str | None) -> str | None:
        return _choice(value, {"Freehold", "Leasehold", "Not sure"}, "land tenure")

    @field_validator("unit_position")
    @classmethod
    def _valid_unit_position(cls, value: str | None) -> str | None:
        return _choice(value, {"Intermediate unit", "Corner unit", "End lot", "Standalone unit", "Not sure"}, "unit position")

    @field_validator("title_type")
    @classmethod
    def _valid_title_type(cls, value: str | None) -> str | None:
        return _choice(value, {"Individual title", "Strata title", "Master title", "Not sure"}, "property title type")


def _draft_field_error(field: str, message: str) -> None:
    raise HTTPException(status_code=422, detail=[
        {"loc": ["body", field], "msg": message, "type": "value_error"},
    ])


def _validate_draft_values(fields: dict, existing: dict | None = None) -> None:
    current = existing or {}
    if {"lease_duration_months", "lease_duration_negotiable"} & fields.keys():
        months = fields.get("lease_duration_months", current.get("lease_duration_months"))
        negotiable = fields.get("lease_duration_negotiable", current.get("lease_duration_negotiable"))
        if months is not None and negotiable is True:
            _draft_field_error("lease_duration_months", "Choose a fixed or negotiable rental period, or clear the fixed months.")

    if {"rental_price", "size_sqft"} & fields.keys():
        price = fields.get("rental_price", current.get("rental_price"))
        size = fields.get("size_sqft", current.get("size_sqft"))
        if price is not None and size is not None and price > 0 and size > 0:
            psf = (price / size).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            field = "size_sqft" if "size_sqft" in fields else "rental_price"
            if psf == 0:
                _draft_field_error(field, "Rent and area produce a price per square foot that rounds to zero.")
            if psf > Decimal("999999.99"):
                _draft_field_error(field, "Rent and area produce a price per square foot above 999,999.99.")


def _agent_id_for(session: Session, user_id) -> int | None:
    """The caller's ``public.agent.agent_id``, or ``None`` when they are not one.

    Delegates to the shared provider-scope helper so the staff endpoints, the
    listing routes and the Owner / Agent workspace all resolve agent identity
    through exactly one definition. Authorization fails closed: a Supabase
    outage denies agent scope rather than silently granting it.
    """
    return provider_scope.agent_id_for_user(user_id)


def _agent_manages_listing(
    session: Session, property_id: int, current: AuthenticatedUser
) -> bool:
    """True only when an assignment row links this listing to this agent.

    An agent's authority over an existing property is the assignment, never the
    account role: an agent with no assignment manages nothing, and one agent
    can never reach another agent's listings.
    """
    if not rbac.has_role(current.role, (rbac.ROLE_AGENT,)):
        return False
    agent_id = _agent_id_for(session, current.user_id)
    if agent_id is None:
        return False
    return provider_scope.agent_is_assigned(
        session, listing_id=property_id, agent_id=agent_id
    )


def _provider_agent_id(session: Session, current: AuthenticatedUser) -> int | None:
    """The agent id a NEW record should be assigned to, or ``None`` for owners.

    Raises 403 when the account carries the agent role but has no agent
    profile: such an account must not create a record nobody can manage.
    """
    if not rbac.has_role(current.role, (rbac.ROLE_AGENT,)):
        return None
    agent_id = _agent_id_for(session, current.user_id)
    if agent_id is None:
        raise ForbiddenError(
            "This agent account has no agent profile, so it cannot create "
            "property listings."
        )
    return agent_id


def _owned_listing_or_error(
    repo: FypPropertyRepository, property_id: int, current: AuthenticatedUser,
    *, for_update: bool = False,
) -> dict:
    listing = repo.owner_listing(property_id, for_update=for_update)
    if listing is None:
        raise HTTPException(status_code=404, detail="Property not found.")
    if rbac.can_administer_users(current.role):
        return listing
    owner = listing.get("owner_user_id")
    if owner is not None and str(owner) == str(current.user_id):
        return listing
    # Owner / Agent workspace: an assigned agent maintains the record on the
    # owner's behalf, so the assignment — not ownership — is what authorizes it.
    if _agent_manages_listing(repo.session, property_id, current):
        return listing
    raise ForbiddenError(
        "You can only manage property listings you own or are assigned to."
    )


def _require_listing_edit_permission(
    session: Session, property_id: int, listing: dict,
    current: AuthenticatedUser,
) -> int | None:
    """Enforce the edit window for Owners and the currently assigned Agent.

    Agents may maintain listing facts only after accepting the assignment and
    until submission. Owners are locked while an accepted/correction inspection
    is active so the Agent and Owner cannot overwrite each other's work.
    """
    agent_id = _provider_agent_id(session, current)
    assignment = session.execute(text("""
        SELECT agent_id, workflow_status FROM fyp.agent_listing_assignment
         WHERE listing_id=:pid FOR UPDATE
    """), {"pid": property_id}).mappings().one_or_none()
    if agent_id is not None:
        if (assignment is None or assignment["agent_id"] != agent_id
                or assignment["workflow_status"] not in ("accepted", "needs_correction")):
            raise ForbiddenError(
                "Only the currently assigned Agent may edit during an accepted inspection."
            )
    elif (
        assignment is not None
        and assignment["workflow_status"] in ("requested", "accepted", "needs_correction")
        and not rbac.can_administer_users(current.role)
    ):
        raise HTTPException(
            status_code=409,
            detail="The assigned Agent is inspecting this property. Its details are temporarily locked for the Owner.",
        )

    if listing.get("is_published") or listing.get("verification_status") not in (
        "draft", "rejected", "information_requested"
    ):
        raise HTTPException(status_code=409, detail="The property is locked for review or publication.")
    from sitewise.db.models.property_verification import can_resubmit
    from sitewise.services.property_verification_service import verification_row
    verification = verification_row(session, property_id)
    listing_review_in_progress = verification is not None and (
        verification.listing_status in ("pending", "under_review", "verified")
    )
    ownership_review_in_progress = verification is not None and (
        verification.ownership_status in ("pending", "under_review", "verified")
    )
    if agent_id is None and not rbac.can_administer_users(current.role) and (
        listing_review_in_progress or ownership_review_in_progress
    ):
        raise HTTPException(
            status_code=409,
            detail="This property is with the Administrator for review and cannot be edited.",
        )
    if agent_id is not None and listing_review_in_progress and (
        assignment is None or assignment["workflow_status"] != "needs_correction"
    ):
        raise HTTPException(
            status_code=409,
            detail="This property is with the Administrator for review and cannot be edited.",
        )
    if verification is not None and not can_resubmit(
        verification.listing_status, verification.ownership_status
    ):
        raise HTTPException(
            status_code=409,
            detail="This property is awaiting or has passed review; its details can no longer be edited.",
        )
    return agent_id


def _owner_edit_locked_by_agent(session: Session, property_id: int) -> bool:
    status = session.execute(text("""
        SELECT workflow_status FROM fyp.agent_listing_assignment
         WHERE listing_id=:pid
    """), {"pid": property_id}).scalar_one_or_none()
    return status in ("requested", "accepted", "needs_correction")


def _queue_expanded64(session: Session, property_id: int) -> None:
    """Queue the informational location measurements for one listing.

    Valid latitude/longitude is the only precondition. The address verdict is
    NOT a gate: it describes how confidently the location was matched, and is
    reported alongside the measurements (``address_validation_status``), but a
    listing whose match was never confirmed still has a real coordinate and
    therefore still has real surroundings worth measuring. Requiring a
    server-confirmed verdict here left every catalogue listing unmeasured,
    which blocked Location Intelligence entirely.

    Model eligibility is a separate concern: ``enqueue`` writes every
    measurement it can, and only the inputs allowlisted for the active model
    variant enter the scoring vector. So queueing here never widens what the
    recommendation model consumes.
    """
    # A migration/source failure must not break the ownership draft workflow.
    try:
        from sitewise.services.expanded64_enrichment import enqueue

        with session.begin_nested():
            queued = enqueue(session, property_id)
        if not queued:
            logger.info(
                "Location intelligence not queued for listing %s: no valid "
                "coordinates, or the categories are already current.",
                property_id,
            )
    except Exception as exc:
        logger.warning("Expanded64 enqueue failed for listing %s (%s)", property_id, type(exc).__name__)


def _resolve_location_after_save(
    session: Session,
    repo: FypPropertyRepository,
    property_id: int,
    row: dict,
) -> dict:
    """Obtain coordinates from the saved address when none are stored yet.

    Runs AFTER the caller's commit and in its own transaction. Geocoding is an
    outbound HTTP call with a bounded retry, and holding the property row lock
    across it would block every other writer for the duration of a provider
    timeout. The caller keeps its committed draft either way.

    This is the automatic half of the location workflow: a client that did not
    send an address-confirmation token still ends up with a measured listing,
    because the saved street, city and state are geocoded through the same
    provider pipeline the preview uses. Nothing is inferred when the provider
    cannot place the address — the draft simply stays unlocated and the reason
    is logged.
    """
    if row.get("latitude") is not None and row.get("longitude") is not None:
        return row
    try:
        from sitewise.services.property_location_service import (
            resolve_property_coordinates,
        )

        resolution = resolve_property_coordinates(session, property_id)
        session.commit()
    except Exception as exc:  # noqa: BLE001 - the saved draft must still return
        session.rollback()
        logger.warning(
            "Automatic location resolution failed for listing %s (%s)",
            property_id, type(exc).__name__,
        )
        return row
    if not resolution.located:
        logger.info(
            "Listing %s saved without coordinates: %s (%s)",
            property_id, resolution.status, resolution.reason,
        )
        return row
    return repo.owner_listing(property_id) or row


def _apply_address_confirmation(
    session: Session,
    repo: FypPropertyRepository,
    property_id: int,
    token_value: str | None,
    listing: dict,
) -> dict:
    """Apply signed preview evidence to a saved draft. Server-controlled.

    The token was issued by the read-only preview after the server itself
    called the provider, so the coordinates written here are SERVER-derived
    (draft requests accept no client lat/lng at all). Evidence is bound to
    the canonical address: if the stored address differs from the confirmed
    one, the evidence is rejected as outdated and the draft still saves
    unverified — Save Draft never depends on the maps service.
    """
    if not token_value:
        return {"applied": False, "reason": "not_provided"}
    evidence = verify_confirmation_token(token_value)
    if evidence is None:
        return {"applied": False, "reason": "invalid_or_expired"}
    stored_hash = canonical_address_hash(
        listing.get("address"),
        listing.get("city"),
        listing.get("state"),
        listing.get("postcode"),
    )
    if stored_hash != evidence["ah"]:
        return {"applied": False, "reason": "address_changed"}
    # Precise premise-level verdicts count as validated; approximate or
    # ambiguous results stay partially_validated — user confirmation is NOT
    # ownership proof or administrator verification.
    status = "validated" if evidence["mc"] == "precise" else "partially_validated"
    repo.set_address_validation(
        property_id,
        status=status,
        formatted_address=evidence["fa"],
        latitude=evidence["la"],
        longitude=evidence["lo"],
    )
    logger.info(
        "Address confirmation applied to listing %s (match=%s provider=%s)",
        property_id, evidence["mc"], evidence.get("pv"),
    )
    return {
        "applied": True,
        "status": status,
        "match_class": evidence["mc"],
        "provider": evidence.get("pv"),
    }


@router.post("/listings/drafts", status_code=201)
def create_owner_draft(
    payload: OwnerDraftRequest,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Persist a NEW draft. The owner identity comes from the verified token;
    the database assigns the persistent id; the draft stays unpublished and
    outside the admin queue."""
    if not rbac.has_role(current.role, (rbac.ROLE_OWNER, rbac.ROLE_AGENT)):
        raise ForbiddenError("Only a Property Owner or assigned Agent account may create a draft.")
    if payload.name is None:
        _draft_field_error("name", "Enter a property title.")
    fields = payload.model_dump(
        exclude_unset=True, exclude={"draft_request_id", "address_confirmation_token"}
    )
    repo = FypPropertyRepository(session)
    # An agent creates the record ON BEHALF OF a provider, so the row is not
    # given an owner it cannot prove. It is scoped to the agent through an
    # assignment row instead, which is what the workspace and the admin queue
    # both read. Owners keep the existing owner_user_id behaviour.
    agent_id = _provider_agent_id(session, current)
    try:
        request_key = None
        existing_id = None
        if payload.draft_request_id is not None:
            request_key = str(uuid5(
                NAMESPACE_URL, f"sitewise/draft/{current.user_id}/{payload.draft_request_id}"
            ))
            # Keep duplicate retries for this account and request in the same
            # transaction order without locking unrelated draft submissions.
            session.execute(text("""
                SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))
            """), {"key": request_key})
            existing_id = session.execute(text("""
                SELECT id FROM fyp.rental_properties WHERE draft_request_key = :key
            """), {"key": request_key}).scalar_one_or_none()
        if existing_id is not None:
            row = _owned_listing_or_error(repo, int(existing_id), current)
        else:
            _validate_draft_values(fields)
            row = repo.create_owner_draft(
                owner_user_id=None if agent_id is not None else current.user_id,
                payload=fields,
                commit=False,
            )
            if request_key is not None:
                session.execute(text("""
                    UPDATE fyp.rental_properties SET draft_request_key = :key WHERE id = :id
                """), {"key": request_key, "id": row["id"]})
            if agent_id is not None:
                AgentAssignmentRepository(session).assign(
                    int(row["id"]), agent_id, assigned_by=None, commit=False
                )
                row = repo.owner_listing(int(row["id"])) or row
        # Location evidence lands BEFORE the enrichment queue reads the row,
        # so a confirmed location immediately drives new measurements.
        confirmation = _apply_address_confirmation(
            session, repo, int(row["id"]), payload.address_confirmation_token, row
        )
        _queue_expanded64(session, int(row["id"]))
        session.commit()
    except Exception:
        session.rollback()
        raise
    # Location last: the draft is already durable, so a provider outage cannot
    # lose it, and a successful geocode returns the listing WITH coordinates.
    row = _resolve_location_after_save(session, repo, int(row["id"]), row)
    return {
        "data": row,
        "meta": {
            "replayed": existing_id is not None,
            "verification_status": row["verification_status"],
            "is_published": row["is_published"],
            "address_confirmation": confirmation,
            "note": "Draft saved. Submit for verification when complete.",
        },
    }


@router.get("/listings/drafts/{request_id}")
def recover_owner_draft(
    request_id: UUID,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    request_key = str(uuid5(NAMESPACE_URL, f"sitewise/draft/{current.user_id}/{request_id}"))
    # Wait for an in-flight create using the same transaction-scoped key.
    session.execute(text("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))"), {"key": request_key})
    property_id = session.execute(text("""
        SELECT id FROM fyp.rental_properties WHERE draft_request_key = :key
    """), {"key": request_key}).scalar_one_or_none()
    if property_id is None:
        raise HTTPException(status_code=404, detail="No saved draft for this request.")
    return get_own_listing(property_id, session, current)


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
            "owner_edit_locked": _owner_edit_locked_by_agent(session, property_id),
        }
    }


@router.patch("/listings/{property_id}")
def update_own_listing(
    property_id: int,
    payload: OwnerDraftRequest,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Update a property draft through its Owner or accepted Agent scope.

    Assigned Agent writes are limited to the accepted inspection/correction
    window and listing facts; Owners are locked while an Agent inspection is
    active. Review and publication state remain immutable here.
    """
    repo = FypPropertyRepository(session)
    listing = _owned_listing_or_error(repo, property_id, current, for_update=True)
    if listing is None:
        raise HTTPException(status_code=404, detail="Property not found.")
    agent_id = _require_listing_edit_permission(session, property_id, listing, current)
    fields = payload.model_dump(
        exclude_unset=True, exclude={"draft_request_id", "address_confirmation_token"}
    )
    _validate_draft_values(fields, listing)
    changed = [
        key for key, value in fields.items()
        if key in FypPropertyRepository._OWNER_WRITABLE
        and _owner_field_changed(listing.get(key), value, key)
    ]
    row = repo.update_owner_listing(property_id, fields, commit=False)
    if row is None:
        raise HTTPException(status_code=404, detail="Property not found.")
    # Fresh evidence must be applied AFTER the update: an edited address first
    # invalidates the previous confirmation inside update_owner_listing, then
    # a valid token re-establishes it for the NEW address in the same
    # transaction. Without a token the draft simply saves unverified.
    confirmation = _apply_address_confirmation(
        session, repo, property_id, payload.address_confirmation_token, row
    )
    location_changed = (
        any(key in changed for key in ("address", "city", "state", "postcode"))
        or row.get("latitude") != listing.get("latitude")
        or row.get("longitude") != listing.get("longitude")
    )
    audit_fields = list(changed)
    if agent_id is not None and confirmation.get("applied"):
        audit_fields.append("verified_coordinates")
    _queue_expanded64(session, property_id)
    if agent_id is not None and audit_fields:
        session.execute(text("""
            INSERT INTO fyp.verification_audit
                (audit_id, property_id, verification_id, verification_type,
                 previous_status, new_status, action, reason, created_at)
            VALUES (gen_random_uuid(), :pid, NULL, NULL, NULL, NULL,
                    'agent_updated_property_details', :reason, now())
        """), {
            "pid": property_id,
            "reason": f"Agent {current.user_id} updated property details: "
                      + ", ".join(sorted(audit_fields)),
        })
    if agent_id is not None and (location_changed or set(changed).intersection({
        "property_type", "address", "city", "state", "postcode",
        "latitude", "longitude", "size_sqft", "floor_level",
        "floor_description", "frontage_ft", "furnishing", "unit_position",
        "has_parking",
    })):
        # Re-check on-site facts after a material listing correction. If the
        # confirmed location moved, leave the old panorama record intact but
        # detach it from this inspection so it cannot satisfy a new submission.
        session.execute(text("""
            UPDATE fyp.agent_listing_assignment
               SET inspection_data=COALESCE(inspection_data, '{}'::jsonb) ||
                     '{"floor_area_verified":false,"condition_verified":false,
                       "parking_verified":false,"accessibility_verified":false}'::jsonb,
                   inspection_updated_at=NULL,
                   panorama_id=CASE WHEN :location_changed THEN NULL ELSE panorama_id END,
                   panorama_tour_id=CASE WHEN :location_changed THEN NULL ELSE panorama_tour_id END,
                   panorama_job_id=CASE WHEN :location_changed THEN NULL ELSE panorama_job_id END,
                   panorama_uploaded_at=CASE WHEN :location_changed THEN NULL ELSE panorama_uploaded_at END,
                   updated_at=now()
             WHERE listing_id=:pid AND agent_id=:aid
        """), {
            "pid": property_id,
            "aid": agent_id,
            "location_changed": location_changed,
        })
    session.commit()
    # An edited address invalidates the previous location, so the same
    # automatic resolution applies here: the new address is geocoded before the
    # owner has to think about coordinates at all.
    row = _resolve_location_after_save(session, repo, property_id, row)
    return {"data": row, "meta": {"address_confirmation": confirmation}}


# ---------------------------------------------------------------------------
# Property photos (display media — public bucket, permanent URLs)
# ---------------------------------------------------------------------------


@router.put("/listings/{property_id}/reference-image")
async def replace_reference_image(
    property_id: int,
    file: UploadFile = File(...),
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Store a small, validated exterior reference photo on the property row."""
    import cv2
    import numpy as np

    repo = FypPropertyRepository(session)
    listing = _owned_listing_or_error(repo, property_id, current, for_update=True)
    _require_listing_edit_permission(session, property_id, listing, current)
    raw = await file.read(8 * 1024 * 1024 + 1)
    if not raw or len(raw) > 8 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="Choose an image smaller than 8 MB before compression.")
    decoded = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
    if decoded is None:
        raise HTTPException(status_code=422, detail="The selected file is not a supported image.")
    name = (file.filename or "").lower()
    detected = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_UNCHANGED)
    mime = "image/png" if name.endswith(".png") and detected is not None else "image/jpeg"
    height, width = decoded.shape[:2]
    scale = min(1.0, 1600 / max(width, height))
    if scale < 1.0:
        decoded = cv2.resize(decoded, (round(width * scale), round(height * scale)), interpolation=cv2.INTER_AREA)
    quality = 88
    while True:
        ok, encoded = cv2.imencode(".jpg", decoded, [cv2.IMWRITE_JPEG_QUALITY, quality])
        if not ok:
            raise HTTPException(status_code=422, detail="The image could not be processed.")
        data = encoded.tobytes()
        if len(data) <= 2 * 1024 * 1024:
            break
        if quality > 55:
            quality -= 8
        elif max(decoded.shape[:2]) > 640:
            decoded = cv2.resize(decoded, (round(decoded.shape[1] * .8), round(decoded.shape[0] * .8)), interpolation=cv2.INTER_AREA)
        else:
            raise HTTPException(status_code=413, detail="The compressed reference image exceeds 2 MB.")
    mime = "image/jpeg"
    session.execute(text("""
        UPDATE fyp.rental_properties
           SET reference_image=:image, reference_image_mime_type=:mime, updated_at=now()
         WHERE id=:pid
    """), {"image": data, "mime": mime, "pid": property_id})
    session.commit()
    return {"data": {"property_id": property_id, "mime_type": mime, "size_bytes": len(data)}}


@router.get("/listings/{property_id}/reference-image")
def get_reference_image(
    property_id: int,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Return the reference image only to an Owner, assigned Agent, or Admin."""
    repo = FypPropertyRepository(session)
    _owned_listing_or_error(repo, property_id, current)
    row = session.execute(text("""
        SELECT reference_image, reference_image_mime_type
          FROM fyp.rental_properties WHERE id=:pid
    """), {"pid": property_id}).first()
    if row is None or not row[0]:
        raise HTTPException(status_code=404, detail="No reference image is available.")
    mime = row[1] if row[1] in ("image/jpeg", "image/png", "image/webp") else "image/jpeg"
    return Response(content=bytes(row[0]), media_type=mime, headers={"Cache-Control": "private, no-store"})


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
    from sitewise.services import photo_storage
    from sitewise.services.photo_storage import (
        PhotoRejected,
        PhotoStorageUnavailable,
    )
    repo = FypPropertyRepository(session)
    listing = _owned_listing_or_error(repo, property_id, current)
    if not rbac.has_role(current.role, (rbac.ROLE_AGENT,)):
        _owner_write_only(current)
    agent_id = _require_listing_edit_permission(session, property_id, listing, current)
    data = await file.read()
    try:
        ext = photo_storage.validate_photo(
            file.filename or "", file.content_type or "", len(data)
        )
        url = photo_storage.save_photo(
            data, ext, file.content_type or "", identity=str(property_id)
        )
    except PhotoRejected as exc:
        raise HTTPException(
            status_code=413 if exc.oversized else 422, detail=str(exc)
        ) from exc
    except PhotoStorageUnavailable as exc:
        # 503 with the exact reason; the draft is untouched.
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    existing = repo.listing_photo_by_url(property_id, url)
    if existing is not None:
        # A retry of the same bytes: the stable object and its row already
        # exist. Return the row rather than adding a duplicate gallery entry.
        return {"data": existing}
    try:
        photo = repo.add_listing_photo(
            property_id, url, (caption or "").strip()[:200], is_primary, commit=False
        )
    except Exception:
        logger.exception(
            "Property photo database insert failed (property_id=%s)", property_id
        )
        try:
            session.rollback()
        finally:
            photo_storage.delete_photo(url)
        raise
    if agent_id is not None:
        session.execute(text("""
            INSERT INTO fyp.verification_audit
                (audit_id, property_id, verification_id, verification_type,
                 previous_status, new_status, action, reason, created_at)
            VALUES (gen_random_uuid(), :pid, NULL, NULL, NULL, NULL,
                    'agent_updated_property_photos', :reason, now())
        """), {"pid": property_id,
               "reason": f"Agent {current.user_id} added a property photograph."})
    # If commit itself fails, its outcome may be unknown. Keep the object
    # rather than risk deleting a photo referenced by a committed row.
    session.commit()
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
    listing = _owned_listing_or_error(repo, property_id, current)
    _owner_write_only(current)
    _require_listing_edit_permission(session, property_id, listing, current)
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
    listing = _owned_listing_or_error(repo, property_id, current)
    if not rbac.has_role(current.role, (rbac.ROLE_AGENT,)):
        _owner_write_only(current)
    agent_id = _require_listing_edit_permission(session, property_id, listing, current)
    if not repo.set_primary_listing_photo(property_id, photo_id, commit=False):
        raise HTTPException(status_code=404, detail="Photo not found.")
    if agent_id is not None:
        session.execute(text("""
            INSERT INTO fyp.verification_audit
                (audit_id, property_id, verification_id, verification_type,
                 previous_status, new_status, action, reason, created_at)
            VALUES (gen_random_uuid(), :pid, NULL, NULL, NULL, NULL,
                    'agent_updated_property_photos', :reason, now())
        """), {"pid": property_id,
               "reason": f"Agent {current.user_id} changed the primary property photograph."})
    session.commit()
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
    if owner_uuid is not None and str(owner_uuid) == str(current.user_id):
        return
    if _agent_manages_listing(session, property_id, current):
        return
    raise ForbiddenError(
        "You can only enrich property listings you own or are assigned to."
    )


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
    * ``phase="population"`` (Phase 2) runs the raster work on its own — the
      population chain and the WorldPop age-band extraction. These are the
      only categories that can legitimately be unavailable, and calling this
      never recomputes Phase 1.
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
    # Schema is provisioned by Alembic (0015/0016), not by a read request.
    # Calling ensure_schema() here issued DDL from a GET and failed under
    # read-only production grants.
    service = PropertyEnrichmentService(session)
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
    if category == "operational25":
        # Same durable queue, separate model: re-queue only this property and
        # reuse its existing row on retry (no duplicate records).
        from sitewise.services.operational25_enrichment import CATEGORY, enqueue, persisted

        listing = session.execute(
            text("SELECT latitude, longitude FROM fyp.rental_properties WHERE id=:id"),
            {"id": property_id},
        ).mappings().first()
        if listing is None:
            raise HTTPException(status_code=404, detail="Property not found.")
        enqueue(session, property_id, force=True)
        session.commit()
        return {
            "data": persisted(session, property_id, listing.latitude, listing.longitude),
            "meta": {"property_id": property_id, "category": CATEGORY, "status": "queued"},
        }
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

@router.post("/listings/{property_id}/validate-address")
def validate_saved_property_address(
    property_id: int,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
) -> dict:
    """Validate the saved address and persist a server-obtained verdict."""
    _owner_write_only(current)
    repository = FypPropertyRepository(session)
    listing = _owned_listing_or_error(repository, property_id, current)
    if listing["is_published"] or listing["verification_status"] not in ("draft", "rejected"):
        raise HTTPException(status_code=409, detail="The property is locked for address edits.")
    keys = ("address", "city", "state", "postcode", "latitude", "longitude")
    if any(not listing.get(key) for key in keys[:4]):
        raise HTTPException(status_code=422, detail="Save the street, city, state and postcode first.")
    result = validate_property_address(
        AddressValidationRequest(
            address_lines=[listing["address"]],
            city=listing["city"],
            state=listing["state"],
            postcode=listing["postcode"],
        ),
        current,
    )["data"]
    latest = _owned_listing_or_error(repository, property_id, current, for_update=True)
    if (
        latest["is_published"]
        or latest["verification_status"] not in ("draft", "rejected")
        or any(_owner_field_changed(listing.get(key), latest.get(key), key) for key in keys)
    ):
        raise HTTPException(status_code=409, detail="The saved property changed. Retry address verification.")
    if session.execute(text("""
        SELECT listing_id FROM fyp.agent_listing_assignment
        WHERE listing_id = :id AND workflow_status IN ('accepted', 'needs_correction', 'submitted')
        FOR UPDATE
    """), {"id": property_id}).first() is not None:
        raise HTTPException(status_code=409, detail="Use the inspection correction workflow while an inspection is active.")
    repository.set_address_validation(
        property_id,
        status=result["status"],
        formatted_address=result["formatted_address"],
        latitude=result["latitude"],
        longitude=result["longitude"],
    )
    _queue_expanded64(session, property_id)
    session.commit()
    return {"data": repository.owner_listing(property_id), "address_validation": result}


class AddressPreviewRequest(BaseModel):
    """The typed address exactly as the Add Property form expresses it.

    Only the fields the existing forms store are accepted (street address,
    city, state, 5-digit postcode) so the confirmation evidence hash always
    matches the saved draft address. Matching is restricted to Malaysia.
    """

    address: str = Field(min_length=3, max_length=300)
    city: str = Field(min_length=1, max_length=80)
    state: str = Field(min_length=1, max_length=80)
    postcode: str = Field(pattern=r"^\d{5}$")
    refresh: bool = False

    @field_validator("address", "city", "state")
    @classmethod
    def _strip(cls, value: str) -> str:
        if "\x00" in value:
            raise ValueError("Remove null characters.")
        return value.strip()


@router.post("/address-preview")
def preview_property_address(
    payload: AddressPreviewRequest,
    current: AuthenticatedUser = Depends(require_property_owner),
) -> dict:
    """Authenticated, READ-ONLY address preview for the Add Property wizards.

    Resolves the typed address through the existing provider chain (Google
    Address Validation first, then the Malaysian fallback geocoder),
    classifies the match against the typed components, and returns an
    HMAC-signed confirmation token bound to the canonical address. Nothing is
    persisted: no temporary property row, no verdict write. Save Draft stays
    fully usable when this endpoint reports the service unavailable.
    """
    if not rbac.has_role(current.role, (rbac.ROLE_OWNER, rbac.ROLE_AGENT)):
        raise ForbiddenError(
            "Only a Property Owner or assigned Agent account may preview an address."
        )
    result = preview_address(
        address_line1=payload.address,
        city=payload.city,
        state=payload.state,
        postcode=payload.postcode,
        force_refresh=payload.refresh,
    )
    return {
        "data": result,
        "meta": {
            "region": "MY",
            "confirmation_note": (
                "Confirming only records that the displayed location was "
                "accepted for THIS address; it is not ownership proof or "
                "administrator verification."
            ),
            # Licensing/attribution surface for client display.
            "attribution": {
                "google_address_validation": (
                    "Matched by Google Address Validation; Google-derived "
                    "content is used transiently for this preview."
                ),
                "openstreetmap_nominatim": (
                    "Geocoding (c) OpenStreetMap contributors (ODbL)."
                ),
            },
        },
    }
