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

    scope: Literal["full", "listing"] = "full"


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
        property_id, current.user_id, is_admin=_is_admin(current)
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
    """
    return PropertyVerificationService(session).submit(
        property_id,
        current.user_id,
        scope=payload.scope if payload is not None else "full",
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
    server-side; the file never touches a public URL."""
    if verification_type not in ("listing", "ownership"):
        raise HTTPException(
            status_code=422, detail="verification_type must be listing or ownership."
        )
    data = await file.read()
    try:
        document = PropertyVerificationService(session).add_document(
            property_id,
            current.user_id,
            verification_type,
            document_type,
            file.filename or "",
            file.content_type or "",
            data,
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
    """Stream a private document. Access: the submitting owner, or an
    administrator with completed MFA. Everyone else gets 403/404."""
    document = PropertyVerificationService(session).document_for_download(
        document_id, current.user_id, is_admin=_is_admin(current)
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
    """Server-side filtered/sorted/paginated submission queue with faceted
    status counts. Filters compose; the catalogue is never loaded wholesale."""
    return AdminPropertyReviewService(session).queue(
        q=(q or "").strip() or None,
        listing_status=listing_status or None,
        ownership_status=ownership_status or None,
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
    dimension statuses, document metadata and chronological audit history."""
    return AdminPropertyReviewService(session).detail(property_id)


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
    """Approve ONE dimension. Never touches the other dimension's status;
    publication eligibility is recomputed server-side after the commit."""
    return AdminPropertyReviewService(session).approve(
        property_id, payload.dimension, admin.user_id
    )


@staff_router.post("/{property_id}/verification/reject")
def reject_dimension(
    property_id: int,
    payload: RejectRequest,
    session: DbSession,
    admin: AdminUser,
) -> dict:
    return AdminPropertyReviewService(session).reject(
        property_id, payload.dimension, admin.user_id, payload.reason
    )


@staff_router.post("/{property_id}/verification/request-information")
def request_information(
    property_id: int,
    payload: InformationRequest,
    session: DbSession,
    admin: AdminUser,
) -> dict:
    return AdminPropertyReviewService(session).request_information(
        property_id, payload.dimension, admin.user_id, payload.note
    )
