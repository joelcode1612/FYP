"""Agent listing-management endpoints (assigned listings only).

Mounted under ``/api/v1/staff`` beside :mod:`sitewise.api.v1.staff`, which it
deliberately does NOT modify. Authorization reuses that module's single
enforcement point (``_require_listing_access``): the Supabase assignment row
must carry this agent's ``agent_id``, or the caller is an administrator with
completed MFA. A different agent always receives 403 — never a filtered view
of someone else's listing.

What an agent can do here
-------------------------
* ``GET  /listings/{listing_id}`` — the assignment record joined with the
  OPERATIONAL property row (``fyp.rental_properties``; the SAME numeric id —
  no conversion between id systems), its photos and the open change request.
* ``PATCH /listings/{listing_id}/proposal`` — save proposed field changes
  as a DRAFT change request. The operational row is never written here.
* ``POST /listings/{listing_id}/review-request`` — submit the draft for
  administrator review (duplicate pending requests are refused with 409).
* ``GET  /listings/{listing_id}/change-requests`` — full request + audit
  history (the Activity and Admin Review tabs).
* ``POST /listings/{listing_id}/notes`` — an internal note, persisted as an
  audit event before the response is sent.
* ``POST /listings/{listing_id}/photos`` (+ delete / set-primary) — the
  owner photo endpoints are NOT reachable for agents (ownership check),
  so these reuse the same storage and repository with the assignment check.
* ``POST /listings/{listing_id}/change-requests/{request_id}/decision`` —
  ADMINISTRATOR only. ``approve`` applies the proposed changes to the
  operational row under server policy; an agent can never reach it.

Initial Entrepreneur submissions are NOT affected: they enter the existing
``property_verification`` workflow automatically on
``POST /properties/{id}/verification/submit`` and never need this module.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from pydantic import BaseModel, Field
from sqlmodel import Session, text

from sitewise.api.v1.staff import _require_listing_access
from sitewise.core.supabase_admin import SupabaseAdminService
from sitewise.db.models.listing_change_request import (
    AGENT_PROPOSABLE_FIELDS,
    ListingChangeAudit,
    ListingChangeRequest,
)
from sitewise.db.session import get_db
from sitewise.dependencies import (
    AuthenticatedUser,
    require_agent_mfa,
    require_admin_mfa,
)
from sitewise.repositories.fyp_property_repository import FypPropertyRepository
from sitewise.services import photo_storage
from sitewise.services.photo_storage import (
    PhotoRejected,
    PhotoStorageUnavailable,
)

router = APIRouter()

DbSession = Session  # annotated per-route for readability


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _admin_service() -> SupabaseAdminService:
    return SupabaseAdminService()


# ---------------------------------------------------------------------------
# Request models
# ---------------------------------------------------------------------------


class AgentListingUpdate(BaseModel):
    """Proposed listing fields. Absent keys are not proposed.

    Validation mirrors the owner wizard's server-side rules: title length,
    positive rental / area, the backend's commercial type vocabulary. The
    registered address and every ownership/publication column are
    deliberately absent — location and publication changes are not
    agent-editable under any payload.
    """

    name: str | None = Field(default=None, min_length=4, max_length=160)
    rental_price: float | None = Field(default=None, gt=0, le=10_000_000)
    size_sqft: float | None = Field(default=None, gt=0, le=10_000_000)
    property_type: str | None = Field(default=None, max_length=60)
    floor_level: str | None = Field(default=None, max_length=60)
    availability: str | None = Field(default=None, max_length=60)
    description: str | None = Field(default=None, max_length=4000)
    has_parking: bool | None = None
    is_fnb_suitable: bool | None = None


class ReviewRequestPayload(BaseModel):
    reason: str = Field(min_length=12, max_length=2000)


class ChangeDecisionPayload(BaseModel):
    decision: str

    def validated(self) -> str:
        if self.decision not in ("approve", "reject", "changes_requested"):
            raise HTTPException(
                status_code=422,
                detail="decision must be approve, reject or changes_requested.",
            )
        return self.decision


class AgentNotePayload(BaseModel):
    note: str = Field(min_length=1, max_length=2000)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _request_dict(row: ListingChangeRequest) -> dict:
    return {
        "change_request_id": str(row.change_request_id),
        "listing_id": row.listing_id,
        "proposed_by": str(row.proposed_by),
        "changes": row.changes or {},
        "status": row.status,
        "reason": row.reason,
        "reviewed_by": str(row.reviewed_by) if row.reviewed_by else None,
        "review_note": row.review_note,
        "created_at": row.created_at.isoformat(),
        "updated_at": row.updated_at.isoformat(),
    }


def _audit_dict(row: ListingChangeAudit) -> dict:
    return {
        "audit_id": str(row.audit_id),
        "change_request_id": str(row.change_request_id)
        if row.change_request_id
        else None,
        "listing_id": row.listing_id,
        "action": row.action,
        "actor_user_id": str(row.actor_user_id),
        "note": row.note,
        "created_at": row.created_at.isoformat(),
    }


def _open_request(
    session: Session, listing_id: int, proposer: uuid.UUID | None
) -> ListingChangeRequest | None:
    """The newest draft/pending request for the listing.

    A DRAFT is only visible to the agent who wrote it; a PENDING request is
    visible to every authorized caller of the listing (the administrator
    needs it too).
    """
    rows = session.execute(
        text(
            "SELECT * FROM listing_change_request "
            "WHERE listing_id = :lid AND status IN ('draft','pending') "
            "ORDER BY created_at DESC LIMIT 1"
        ),
        {"lid": listing_id},
    ).mappings().first()
    if rows is None:
        return None
    request = session.get(ListingChangeRequest, rows["change_request_id"])
    if request is None:
        return None
    if request.status == "draft" and proposer is not None:
        if request.proposed_by != proposer:
            return None
    return request


def _record_audit(
    session: Session,
    *,
    listing_id: int,
    action: str,
    actor: uuid.UUID,
    change_request_id: uuid.UUID | None = None,
    note: str | None = None,
) -> None:
    """Append one audit row IN the caller's transaction. A lost audit write
    fails the request rather than reporting an unaudited change — the
    activity tab must never show an event that did not persist."""
    session.add(
        ListingChangeAudit(
            listing_id=listing_id,
            change_request_id=change_request_id,
            action=action,
            actor_user_id=actor,
            note=(note or None),
        )
    )


def _operational_property(session: Session, listing_id: int) -> dict | None:
    return FypPropertyRepository(session).owner_listing(listing_id)


def _owner_reference(session: Session, property_row: dict | None) -> dict | None:
    """The submitting owner's identity reference — the same surface the
    administrator review detail exposes. ``None`` when the row predates
    owner submission (imported research rows carry no owner)."""
    if not property_row:
        return None
    owner_id = property_row.get("owner_user_id")
    if not owner_id:
        return None
    row = session.execute(
        text("SELECT user_id, full_name, email FROM users WHERE user_id = :uid"),
        {"uid": str(owner_id)},
    ).mappings().first()
    if row is None:
        return None
    return {
        "user_id": str(row["user_id"]),
        "full_name": row["full_name"] or "",
        "email": row["email"] or "",
    }


def _normalize_proposed_type(value: str | None) -> str | None:
    """Reuse the owner workflow's commercial-type vocabulary so an approved
    agent proposal can never introduce a type the rest of the system does
    not know."""
    if value is None:
        return None
    from sitewise.api.v1.properties import normalize_property_type

    return normalize_property_type(value)


def _build_changes(
    payload: AgentListingUpdate, current: dict
) -> dict[str, dict]:
    """Server-side diff: every proposed field carries the LIVE current value
    as ``from`` — the client's idea of the current value is never trusted."""
    changes: dict[str, dict] = {}
    for field in AGENT_PROPOSABLE_FIELDS:
        value = getattr(payload, field, None)
        if value is None:
            continue
        if field == "property_type":
            value = _normalize_proposed_type(value)
        if field in ("name", "availability", "description", "floor_level"):
            value = str(value).strip()
            if not value:
                continue
        live = current.get(field)
        if isinstance(live, bool) or isinstance(value, bool):
            live = bool(live)
            value = bool(value)
        elif isinstance(live, (int, float)) and isinstance(value, (int, float)):
            live = float(live)
            value = float(value)
        else:
            live = "" if live is None else str(live)
            value = str(value)
        if live == value:
            continue
        changes[field] = {"from": live, "to": value}
    return changes


# ---------------------------------------------------------------------------
# Reads
# ---------------------------------------------------------------------------


@router.get("/listings/{listing_id}")
def listing_detail(
    listing_id: int,
    user: AuthenticatedUser = Depends(require_agent_mfa),
    session: Session = Depends(get_db),
) -> dict:
    """One assigned listing: the Supabase assignment row plus the operational
    property row (same numeric id), photos and the open change request."""
    service = _admin_service()
    _require_listing_access(service, user, listing_id)
    assignment = service.get_listing(listing_id)
    repo = FypPropertyRepository(session)
    property_row = _operational_property(session, listing_id)
    photos = repo.listing_photos(listing_id)
    open_request = _open_request(session, listing_id, user.user_id)
    return {
        "listing": assignment or {},
        "property": property_row,
        "owner": _owner_reference(session, property_row),
        "photos": photos,
        "change_request": _request_dict(open_request)
        if open_request is not None
        else None,
    }


@router.get("/listings/{listing_id}/change-requests")
def change_request_history(
    listing_id: int,
    user: AuthenticatedUser = Depends(require_agent_mfa),
    session: Session = Depends(get_db),
) -> dict:
    """Every change request and audit event recorded for this listing —
    preserved history, newest first."""
    service = _admin_service()
    _require_listing_access(service, user, listing_id)
    requests = session.execute(
        text(
            "SELECT change_request_id FROM listing_change_request "
            "WHERE listing_id = :lid ORDER BY created_at DESC LIMIT 100"
        ),
        {"lid": listing_id},
    ).mappings().all()
    audit_ids = session.execute(
        text(
            "SELECT audit_id FROM listing_change_audit "
            "WHERE listing_id = :lid ORDER BY created_at DESC LIMIT 200"
        ),
        {"lid": listing_id},
    ).scalars().all()
    return {
        "requests": [
            _request_dict(row)
            for row in (
                session.get(ListingChangeRequest, r["change_request_id"])
                for r in requests
            )
            if row is not None
        ],
        "audit": [
            _audit_dict(row)
            for row in (
                session.get(ListingChangeAudit, audit_id)
                for audit_id in audit_ids
            )
            if row is not None
        ],
    }


# ---------------------------------------------------------------------------
# Draft proposal (agent)
# ---------------------------------------------------------------------------


@router.patch("/listings/{listing_id}/proposal")
def save_proposal(
    listing_id: int,
    payload: AgentListingUpdate,
    user: AuthenticatedUser = Depends(require_agent_mfa),
    session: Session = Depends(get_db),
) -> dict:
    """Save (or replace) the agent's DRAFT change request.

    The diff is computed against the LIVE operational row server-side. An
    empty diff returns the existing open request with ``updated: false``
    instead of writing a no-op record. While a request is PENDING the
    listing is locked for this agent (409) — the administrator must decide
    first.
    """
    service = _admin_service()
    _require_listing_access(service, user, listing_id)
    current = _operational_property(session, listing_id)
    if current is None:
        raise HTTPException(
            status_code=404,
            detail=(
                "No operational property record matches this assignment; "
                "nothing can be proposed."
            ),
        )
    existing = _open_request(session, listing_id, user.user_id)
    if existing is not None and existing.status == "pending":
        raise HTTPException(
            status_code=409,
            detail=(
                "A change request for this listing is already awaiting "
                "administrator review."
            ),
        )
    changes = _build_changes(payload, current)
    now = _utcnow()
    if existing is not None and existing.status == "draft":
        if not changes:
            return {
                "updated": False,
                "change_request": _request_dict(existing),
                "note": "No differences from the current listing values.",
            }
        existing.changes = changes
        existing.updated_at = now
        session.add(existing)
        session.flush()
        _record_audit(
            session,
            listing_id=listing_id,
            action="draft_saved",
            actor=user.user_id,
            change_request_id=existing.change_request_id,
        )
        session.commit()
        session.refresh(existing)
        return {"updated": True, "change_request": _request_dict(existing)}

    if not changes:
        return {
            "updated": False,
            "change_request": None,
            "note": "No differences from the current listing values.",
        }
    request = ListingChangeRequest(
        listing_id=listing_id,
        proposed_by=user.user_id,
        changes=changes,
        status="draft",
    )
    session.add(request)
    session.flush()
    _record_audit(
        session,
        listing_id=listing_id,
        action="draft_saved",
        actor=user.user_id,
        change_request_id=request.change_request_id,
    )
    session.commit()
    session.refresh(request)
    return {"updated": True, "change_request": _request_dict(request)}


@router.post("/listings/{listing_id}/review-request")
def request_admin_review(
    listing_id: int,
    payload: ReviewRequestPayload,
    user: AuthenticatedUser = Depends(require_agent_mfa),
    session: Session = Depends(get_db),
) -> dict:
    """Submit the agent's own DRAFT for administrator review.

    The response is only returned after the transaction commits — a local
    event without persistence is never reported as submitted.
    """
    service = _admin_service()
    _require_listing_access(service, user, listing_id)
    pending = session.execute(
        text(
            "SELECT change_request_id FROM listing_change_request "
            "WHERE listing_id = :lid AND status = 'pending' LIMIT 1"
        ),
        {"lid": listing_id},
    ).scalar_one_or_none()
    if pending is not None:
        raise HTTPException(
            status_code=409,
            detail=(
                "This listing already has a change request awaiting "
                "administrator review."
            ),
        )
    draft = _open_request(session, listing_id, user.user_id)
    if draft is None or draft.status != "draft":
        raise HTTPException(
            status_code=409,
            detail=(
                "Save the proposed changes first; there is no draft to "
                "submit for review."
            ),
        )
    if not draft.changes:
        raise HTTPException(
            status_code=422,
            detail=(
                "The draft contains no field differences; nothing to "
                "review."
            ),
        )
    draft.status = "pending"
    draft.reason = payload.reason.strip()
    draft.updated_at = _utcnow()
    session.add(draft)
    session.flush()
    _record_audit(
        session,
        listing_id=listing_id,
        action="review_requested",
        actor=user.user_id,
        change_request_id=draft.change_request_id,
        note=draft.reason,
    )
    session.commit()
    session.refresh(draft)
    return {"change_request": _request_dict(draft)}


@router.post("/listings/{listing_id}/notes", status_code=201)
def add_note(
    listing_id: int,
    payload: AgentNotePayload,
    user: AuthenticatedUser = Depends(require_agent_mfa),
    session: Session = Depends(get_db),
) -> dict:
    """Persist an internal note as an audit event (append-only history)."""
    service = _admin_service()
    _require_listing_access(service, user, listing_id)
    _record_audit(
        session,
        listing_id=listing_id,
        action="note_added",
        actor=user.user_id,
        note=payload.note.strip(),
    )
    session.commit()
    return {"recorded": True}


# ---------------------------------------------------------------------------
# Administrator decision
# ---------------------------------------------------------------------------


def _apply_approved_changes(
    repo: FypPropertyRepository, listing_id: int, changes: dict
) -> dict:
    """Apply approved field changes under server policy.

    Only the agent-proposable whitelist is applied, re-deriving each value
    from the recorded proposal (never from the client's payload), and the
    psf recompute runs inside ``update_owner_listing`` exactly as on the
    owner path.
    """
    fields: dict = {}
    for field in AGENT_PROPOSABLE_FIELDS:
        if field not in changes:
            continue
        value = changes[field].get("to")
        if field == "property_type":
            value = _normalize_proposed_type(str(value))
        fields[field] = value
    if not fields:
        raise HTTPException(
            status_code=422, detail="The approved request carries no applicable field."
        )
    updated = repo.update_owner_listing(listing_id, fields)
    if updated is None:
        raise HTTPException(status_code=404, detail="Operational listing not found.")
    return updated


@router.post(
    "/listings/{listing_id}/change-requests/{request_id}/decision"
)
def decide_change_request(
    listing_id: int,
    request_id: uuid.UUID,
    payload: ChangeDecisionPayload,
    admin: AuthenticatedUser = Depends(require_admin_mfa),
    session: Session = Depends(get_db),
) -> dict:
    """Administrator decision on one change request.

    ``approve`` makes the proposed values effective on the operational row
    (the ONLY path from proposal to listing data); ``reject`` and
    ``changes_requested`` only record the decision. Publication flags are
    never touched by this endpoint — publication stays under the existing
    administrator policy.
    """
    decision = payload.validated()
    service = _admin_service()
    _require_listing_access(service, admin, listing_id)
    request = session.get(ListingChangeRequest, request_id)
    if request is None or request.listing_id != listing_id:
        raise HTTPException(status_code=404, detail="Change request not found.")
    if request.status != "pending":
        raise HTTPException(
            status_code=409,
            detail=f"This request was already decided (current state: {request.status}).",
        )
    applied: dict | None = None
    if decision == "approve":
        applied = _apply_approved_changes(
            FypPropertyRepository(session), listing_id, request.changes or {}
        )
    request.status = decision
    request.reviewed_by = admin.user_id
    request.review_note = (payload.note or "").strip() or None
    request.updated_at = _utcnow()
    session.add(request)
    session.flush()
    _record_audit(
        session,
        listing_id=listing_id,
        action=decision,
        actor=admin.user_id,
        change_request_id=request.change_request_id,
        note=request.review_note,
    )
    session.commit()
    session.refresh(request)
    return {
        "change_request": _request_dict(request),
        "applied_fields": sorted((applied or {}).keys())
        if applied is not None
        else [],
    }


# ---------------------------------------------------------------------------
# Listing photos (agent-scoped reuse of the owner photo mechanism)
# ---------------------------------------------------------------------------


def _photo_targets(
    listing_id: int, user: AuthenticatedUser, session: Session
) -> FypPropertyRepository:
    service = _admin_service()
    _require_listing_access(service, user, listing_id)
    if _operational_property(session, listing_id) is None:
        raise HTTPException(
            status_code=404,
            detail="No operational property record matches this assignment.",
        )
    return FypPropertyRepository(session)


@router.post("/listings/{listing_id}/photos", status_code=201)
async def upload_listing_photo(
    listing_id: int,
    file: UploadFile = File(...),  # noqa: B008 - FastAPI dependency idiom
    caption: str = Form(default=""),  # noqa: B008
    is_primary: bool = Form(default=False),  # noqa: B008
    session: Session = Depends(get_db),
    user: AuthenticatedUser = Depends(require_agent_mfa),
) -> dict:
    """Upload one photo (JPG/PNG/WebP, <= 8 MB) for an ASSIGNED listing.

    The same storage + repository as the owner flow; bytes are uploaded
    before the row insert, so a failed upload never leaves a dangling row.
    """
    repo = _photo_targets(listing_id, user, session)
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
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    photo = repo.add_listing_photo(
        listing_id, url, (caption or "").strip()[:200], is_primary
    )
    return {"data": photo}


@router.delete("/listings/{listing_id}/photos/{photo_id}", status_code=200)
def delete_listing_photo(
    listing_id: int,
    photo_id: int,
    session: Session = Depends(get_db),
    user: AuthenticatedUser = Depends(require_agent_mfa),
) -> dict:
    repo = _photo_targets(listing_id, user, session)
    deleted = repo.delete_listing_photo(listing_id, photo_id)
    if deleted is None:
        raise HTTPException(status_code=404, detail="Photo not found.")
    photo_storage.delete_photo(deleted["url"])
    return {"data": {"deleted": photo_id}}


@router.post("/listings/{listing_id}/photos/{photo_id}/primary")
def set_primary_listing_photo(
    listing_id: int,
    photo_id: int,
    session: Session = Depends(get_db),
    user: AuthenticatedUser = Depends(require_agent_mfa),
) -> dict:
    repo = _photo_targets(listing_id, user, session)
    if not repo.set_primary_listing_photo(listing_id, photo_id):
        raise HTTPException(status_code=404, detail="Photo not found.")
    return {"data": repo.listing_photos(listing_id)}

