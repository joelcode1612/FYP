"""Property verification APIs — submitter and administrator surfaces.

Submitter routes are mounted under ``/api/v1/properties`` (the owner's own
listing management prefix) and staff routes under ``/api/v1/staff/properties``
(administrator + ``aal2`` enforced server-side by ``require_admin_mfa``).
Documents live in private local storage and stream only through the
authenticated download endpoint — never through public URLs.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import get_db
from sitewise.dependencies import (
    ActiveUser,
    AuthenticatedUser,
    require_admin_mfa,
    require_property_owner,
)
from sitewise.domain import rbac
from sitewise.services import verification_storage as storage
from sitewise.services.agent_inspection_policy import (
    guard_enrichment_before_submit as _guard_enrichment_before_submit,
    require_ready_for_admin,
)
from sitewise.services import provider_scope
from sitewise.services.property_enrichment_service import PropertyEnrichmentService
from sitewise.services.property_verification_service import (
    AdminPropertyReviewService,
    PropertyVerificationService,
    document_payload,
)
from sitewise.services.verification_storage import DocumentRejected

submitter_router = APIRouter()
staff_router = APIRouter()

DbSession = Annotated[Session, Depends(get_db)]
OwnerUser = Annotated[AuthenticatedUser, Depends(require_property_owner)]
AdminUser = Annotated[AuthenticatedUser, Depends(require_admin_mfa)]


class DimensionRequest(BaseModel):
    dimension: Literal["listing", "ownership"]


class SubmitRequest(BaseModel):
    """How much of the property is being submitted for review.

    ``full`` (default) keeps the historical contract: at least one active
    ownership document is required and both dimensions go ``pending``.
    ``listing`` submits the listing information only — no ownership evidence
    required, ``ownership_status`` untouched (stays ``not_submitted`` on a
    first submission). An admin approving a listing-scope submission never
    verifies ownership and never publishes the property.
    """

    scope: Literal["full", "listing", "ownership"] = "full"
    acknowledge_unavailable_population: bool = Field(
        default=False,
        description=(
            "Set only after the owner has been told that population could not "
            "be measured for these coordinates. Population is never estimated, "
            "so the owner has to acknowledge the gap before the listing enters "
            "the review queue."
        ),
    )


class RejectRequest(BaseModel):
    dimension: Literal["listing", "ownership"]
    reason: str = Field(min_length=1, max_length=2000)


class InformationRequest(BaseModel):
    dimension: Literal["listing", "ownership"]
    note: str = Field(min_length=1, max_length=2000)


def _is_admin(user: AuthenticatedUser) -> bool:
    """Administrator acting with the signed AAL2 assurance the staff surface
    requires; an admin token without ``aal2`` is treated as a plain account."""
    return rbac.can_administer_users(user.role) and user.assurance_level == "aal2"


# ---------------------------------------------------------------------------
# Submitter surface (the property's owning account)
# ---------------------------------------------------------------------------


@submitter_router.get("/{property_id}/verification")
def verification_status(
    property_id: int,
    session: DbSession,
    current: OwnerUser,
) -> dict:
    """The submitter's own verification state, evidence and requested
    corrections. A property never submitted returns ``verification: null``."""
    return PropertyVerificationService(session).status_for_property(
        property_id, current.user_id, is_admin=_is_admin(current), role=current.role
    )


@submitter_router.post("/{property_id}/verification/submit")
def submit_for_verification(
    property_id: int,
    session: DbSession,
    current: OwnerUser,
    payload: SubmitRequest | None = None,
) -> dict:
    """Submit (or resubmit) the property for verification. The default
    ``full`` scope requires at least one ownership document; the ``listing``
    scope enters the queue on listing information alone (ownership stays
    ``not_submitted``).

    Google Address Validation is no longer part of the submission flow; the
    listing enters the queue with the address as entered and location truth
    is established by geospatial enrichment plus admin review.

    Submission is always an explicit owner action and never an automatic
    consequence of enrichment finishing. Two guards apply, and only once
    enrichment has actually been attempted for the listing:

    * while a category is still ``running`` the submission is refused (409),
      because the figures the reviewer will see are not settled yet;
    * when population is ``unavailable`` or ``failed`` the owner must
      acknowledge the gap (409 until they do). Population is reported as
      unavailable rather than estimated, so the reviewer needs to know it is
      missing instead of assuming a low number.
    """
    provider_scope.require_mutable_listing(
        session, listing_id=property_id, role=current.role
    )
    role = rbac.canonical_role(current.role)
    scope = payload.scope if payload is not None else "full"
    if role == rbac.ROLE_OWNER and scope == "ownership":
        return PropertyVerificationService(session).submit(
            property_id, current.user_id, scope="ownership", role=current.role
        )
    if role != rbac.ROLE_AGENT or scope == "ownership":
        raise HTTPException(status_code=403, detail="This verification must be submitted by its Owner or assigned Agent.")
    evidence = require_ready_for_admin(session, property_id, current)
    acknowledgement = bool(
        payload.acknowledge_unavailable_population if payload is not None else False
    )
    service = PropertyVerificationService(session)
    # Ownership FIRST: the enrichment probe must never reveal another
    # account's enrichment progress (running categories, population gaps).
    # The record-level check decides access; only a caller entitled to manage
    # this listing ever reaches the guard below.
    listing = service.get_property_owned(
        property_id,
        current.user_id,
        is_admin=_is_admin(current),
        role=current.role,
    )
    from sitewise.services.expanded64_enrichment import VERIFIED_ADDRESS_STATUSES
    from sitewise.services.property_enrichment_service import _valid_coordinates

    # Automatic location resolution BEFORE the address gate. A listing whose
    # owner never confirmed the preview has an address but no coordinates, and
    # used to be refused outright — which made the whole Location Intelligence
    # pipeline unreachable for it. The saved street, city and state are geocoded
    # through the same provider pipeline the preview uses; only a genuine
    # provider failure still refuses the submission, and then with the
    # provider's own reason.
    verdict = listing.get("address_validation_status")
    if verdict not in VERIFIED_ADDRESS_STATUSES or not _valid_coordinates(
        listing.get("latitude"), listing.get("longitude")
    ):
        from sitewise.services.property_location_service import (
            resolve_property_coordinates,
        )

        resolution = resolve_property_coordinates(session, property_id)
        session.commit()
        if not resolution.located:
            raise HTTPException(
                status_code=409,
                detail=resolution.reason
                or "Verify and confirm the property address before submitting the listing for review.",
            )
        listing = service.get_property_owned(
            property_id,
            current.user_id,
            is_admin=_is_admin(current),
            role=current.role,
        )
    _guard_enrichment_before_submit(session, property_id, acknowledgement)
    return service.submit(
        property_id,
        current.user_id,
        scope=scope,
        role=current.role,
        panorama_id=evidence["completed_panorama_id"],
    )


@submitter_router.post("/{property_id}/verification/documents", status_code=201)
async def upload_document(
    property_id: int,
    session: DbSession,
    current: OwnerUser,
    file: UploadFile = File(...),  # noqa: B008 - FastAPI dependency idiom
    verification_type: str = Form(...),
    document_type: str = Form(...),
) -> dict:
    """Upload listing or ownership evidence. The storage key is generated
    server-side; the file never touches a public URL.

    Two boundaries apply, deliberately different in kind:

    * the **general edit lock** (``require_mutable_listing``) still applies —
      a published or awaiting-review listing accepts no new evidence;
    * ownership evidence is the owner's own act, so its authority is the
      ownership row, not the role name. An account provisioned before the
      owner/entrepreneur role split still owns its properties and must be able
      to prove title, while an assigned agent or an administrator never can.

    Uploading evidence is NOT gated on the agent-assignment edit lock that
    freezes listing fields once inspection starts (``properties.py``): the
    owner has to be able to supply ownership proof while the agent inspects.
    """
    provider_scope.require_mutable_listing(
        session, listing_id=property_id, role=current.role
    )
    if verification_type not in ("listing", "ownership"):
        raise HTTPException(
            status_code=422, detail="verification_type must be listing or ownership."
        )
    if verification_type == "ownership":
        found, owner = provider_scope.listing_owner(session, property_id)
        if not found:
            raise HTTPException(status_code=404, detail="Property not found.")
        if owner is None or str(owner) != str(current.user_id):
            raise HTTPException(status_code=403, detail="Only the Property Owner uploads ownership proof.")
    if verification_type == "listing" and rbac.canonical_role(current.role) != rbac.ROLE_AGENT:
        raise HTTPException(status_code=403, detail="Only the Agent uploads inspection evidence.")
    limit = storage.max_bytes()
    data = await file.read(limit + 1)
    if len(data) > limit:
        raise HTTPException(
            status_code=413,
            detail=(
                f"{'Ownership' if verification_type == 'ownership' else 'Inspection'} "
                f"evidence exceeds the {limit // (1024 * 1024)} MB upload limit."
            ),
        )
    try:
        document = PropertyVerificationService(session).add_document(
            property_id,
            current.user_id,
            verification_type,
            document_type,
            file.filename or "",
            file.content_type or "",
            data,
            role=current.role,
        )
    except DocumentRejected as exc:
        raise HTTPException(status_code=413 if exc.oversized else 422, detail=str(exc))
    return document_payload(document)


@submitter_router.get("/verification-documents/{document_id}")
def download_document(
    document_id: uuid.UUID,
    session: DbSession,
    current: ActiveUser,
) -> FileResponse:
    """Stream private evidence to its Owner, the current MFA-verified Agent,
    or an administrator with completed MFA. Everyone else gets 403/404."""
    document = PropertyVerificationService(session).document_for_download(
        document_id, current.user_id, is_admin=_is_admin(current),
        agent_role=current.role if current.assurance_level == "aal2" else None,
    )
    path, _size = storage.open_document(document.storage_key)
    return FileResponse(
        path,
        media_type=document.mime_type,
        filename=document.original_filename,
    )


# ---------------------------------------------------------------------------
# Administrator surface (aal2 enforced by the dependency)
# ---------------------------------------------------------------------------


@staff_router.get("/")
def review_queue(
    session: DbSession,
    admin: AdminUser,
    q: str | None = None,
    listing_status: str | None = None,
    ownership_status: str | None = None,
    lifecycle: str | None = None,
    source: str | None = None,
    scope: str | None = None,
    property_type: str | None = None,
    state: str | None = None,
    city: str | None = None,
    submitted_from: datetime | None = None,
    submitted_to: datetime | None = None,
    sort: str = "submitted_at",
    order: str = "desc",
    offset: int = 0,
    limit: int = 20,
) -> dict:
    """Server-side filtered/sorted/paginated property directory with faceted
    status counts. Filters compose; the catalogue is never loaded wholesale.

    Every property in ``fyp.rental_properties`` is listed — published,
    unpublished, imported, owner- or agent-created, draft, rejected and
    pending — whether or not a verification record exists.
    """
    return AdminPropertyReviewService(session).queue(
        q=(q or "").strip() or None,
        listing_status=listing_status or None,
        ownership_status=ownership_status or None,
        lifecycle=lifecycle or None,
        source=source or None,
        scope=scope or None,
        property_type=property_type or None,
        state=state or None,
        city=city or None,
        submitted_from=submitted_from,
        submitted_to=submitted_to,
        sort=sort,
        order=order,
        offset=offset,
        limit=limit,
    )


@staff_router.get("/{property_id}")
def review_detail(property_id: int, session: DbSession, admin: AdminUser) -> dict:
    """Full verification detail: property, owner identity reference, both
    dimension statuses, document metadata and chronological audit history.

    The stored per-category enrichment state is added alongside it so the
    reviewer can see which figures are measured, which are unavailable and why
    — without recalculating anything. A category that could not be measured is
    reported as unavailable, never as a zero.
    """
    service = AdminPropertyReviewService(session)
    before = service.final_review_state(property_id)
    payload = service.detail(property_id)
    final = service.final_review_state(property_id, check_storage=True)
    if before["token"] != final["token"]:
        final["blockers"].append("Evidence changed during loading. Refresh the review.")
        final["token"] = None
    payload["final_review"] = final
    enrichment = PropertyEnrichmentService(session)
    enrichment.ensure_schema()
    payload["enrichment"] = enrichment.summary(property_id)
    return payload


@staff_router.get("/{property_id}/location-intelligence")
def location_intelligence_status(property_id: int, session: DbSession, admin: AdminUser) -> dict:
    from sitewise.services.expanded64_enrichment import persisted_association
    from sitewise.services.property_location_service import address_is_geocodable
    from sqlalchemy import text

    coordinates = session.execute(text(
        "SELECT latitude, longitude, address_validation_status "
        "FROM fyp.rental_properties WHERE id=:id"
    ), {"id": property_id}).first()
    if coordinates is None:
        raise HTTPException(status_code=404, detail="Property not found.")
    payload = persisted_association(session, property_id, *coordinates[:2])
    # Reported so the reviewer can tell "never queued" from "queued but the
    # address verdict was not server-derived".
    payload["address_validation_status"] = coordinates[2]
    # Whether an analysis can be started AT ALL. A listing with an address but
    # no coordinates is not a dead end: the analysis action geocodes it first.
    # Without this flag the UI had to disable the action on `has_coordinates`
    # alone and a geocodable listing could never be analysed.
    payload["address_resolution"] = address_is_geocodable(session, property_id)
    return payload


@staff_router.post("/{property_id}/location-intelligence/analyze", status_code=202)
def analyze_location_intelligence(
    property_id: int, session: DbSession, admin: AdminUser, full: bool = False,
) -> dict:
    """Queue only the missing, failed or stale measurement categories.

    ``full=true`` is the explicit full recalculation. Nothing is ever
    recalculated merely because the review page was opened.

    A listing that has an address but no coordinates is geocoded first, through
    the same provider pipeline the owner-facing preview uses. That is the only
    way "Run location analysis" can work for a listing whose location was never
    confirmed: the queue refuses to measure an unknown point, so without this
    step the action could never do anything. The resolution outcome is returned
    in ``location`` so the reviewer sees exactly what happened.
    """
    from sitewise.services.expanded64_enrichment import enqueue_outstanding
    from sitewise.services.property_location_service import (
        resolve_property_coordinates,
    )

    try:
        # Coordinates only: what to queue is this endpoint's decision, and
        # letting the resolver queue as well would leave the caller reporting
        # "already queued" for work it had just created itself.
        location = resolve_property_coordinates(
            session, property_id, queue_measurements=False
        )
    except LookupError as exc:
        raise HTTPException(status_code=404, detail="Property not found.") from exc
    try:
        result = enqueue_outstanding(session, property_id, full=full)
    except LookupError as exc:
        raise HTTPException(status_code=404, detail="Property not found.") from exc
    session.commit()
    result["location"] = location.as_dict()
    # The provider's own explanation is the actionable part; surface it as the
    # reason so the caller does not have to read a nested object to learn why
    # nothing was queued.
    if not location.located and location.reason:
        result["reason"] = location.reason
    return result


@staff_router.post("/{property_id}/location-intelligence/recalculate", status_code=202)
@staff_router.post("/{property_id}/location-intelligence/retry/{category}", status_code=202)
def queue_location_intelligence(
    property_id: int, session: DbSession, admin: AdminUser, category: str | None = None,
) -> dict:
    from sitewise.services.expanded64_enrichment import CATEGORIES, enqueue
    from sitewise.services.property_location_service import (
        resolve_property_coordinates,
    )

    if category is not None and category not in CATEGORIES:
        raise HTTPException(status_code=404, detail="Unknown measurement category.")
    try:
        location = resolve_property_coordinates(
            session, property_id, queue_measurements=False
        )
        queued = enqueue(session, property_id, category=category, force=True)
    except LookupError as exc:
        raise HTTPException(status_code=404, detail="Property not found.") from exc
    session.commit()
    return {"queued": queued, "location": location.as_dict()}


class FinalDecisionRequest(BaseModel):
    action: Literal["approve", "reject", "information", "publish", "unpublish"]
    token: str = Field(min_length=1, max_length=100)
    reviewed: set[Literal["property", "ownership", "panorama"]] = Field(default_factory=set)
    component: Literal["property", "ownership", "inspection", "panorama"] | None = None
    reason: str | None = Field(default=None, max_length=2000)


@staff_router.get("/{property_id}/final-review")
def final_review(property_id: int, session: DbSession, admin: AdminUser) -> dict:
    return AdminPropertyReviewService(session).final_review_state(property_id)


@staff_router.post("/{property_id}/final-review")
def final_review_decision(
    property_id: int, payload: FinalDecisionRequest, session: DbSession, admin: AdminUser,
) -> dict:
    if payload.action == "approve" and payload.reviewed != {"property", "ownership", "panorama"}:
        raise HTTPException(422, "Confirm all three evidence reviews.")
    if payload.action in ("reject", "information") and (
        payload.component is None or not (payload.reason or "").strip()
    ):
        raise HTTPException(422, "Choose the affected component and enter a reason.")
    return AdminPropertyReviewService(session).final_decision(
        property_id, admin.user_id, action=payload.action, token=payload.token,
        component=payload.component, reason=payload.reason,
    )


@staff_router.post("/{property_id}/verification/start-review")
def start_review(
    property_id: int,
    payload: DimensionRequest,
    session: DbSession,
    admin: AdminUser,
) -> dict:
    return AdminPropertyReviewService(session).start_review(
        property_id, payload.dimension, admin.user_id
    )


@staff_router.post("/{property_id}/verification/approve")
def approve_dimension(
    property_id: int,
    payload: DimensionRequest,
    session: DbSession,
    admin: AdminUser,
) -> dict:
    raise HTTPException(409, "Use Approve Property to approve the full submission.")


@staff_router.post("/{property_id}/verification/reject")
def reject_dimension(
    property_id: int,
    payload: RejectRequest,
    session: DbSession,
    admin: AdminUser,
) -> dict:
    raise HTTPException(409, "Use the consolidated property correction action.")

@staff_router.post("/{property_id}/verification/request-information")
def request_information(
    property_id: int,
    payload: InformationRequest,
    session: DbSession,
    admin: AdminUser,
) -> dict:
    raise HTTPException(409, "Use the consolidated property correction action.")
