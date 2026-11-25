"""Agent→listing assignments backed by the REAL property foreign key.

Identity contract
-----------------
``agent_listing_assignment.listing_id`` is a FOREIGN KEY to
``fyp.rental_properties(id)``. An assignment therefore cannot exist for a
property that is not in the operational table, and deleting the property
removes the assignment (ON DELETE CASCADE). This replaces the earlier
assumption that a Supabase ``public.listing`` row with the same numeric id
was the same property - that table does not exist in the live project.

Agent identity stays in Supabase (``agent.agent_id``); only the assignment
lives here. Reads always join the operational row so callers get the display
fields the Agent UI needs, and a missing operational row is reported as
"orphaned", never silently rendered as a property.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.models.property_verification import can_resubmit
from sitewise.services.property_verification_service import listing_completeness_errors

#: The verification dimension states that still carry an unanswered staff
#: request, mirroring
#: ``PropertyVerificationService._requested_corrections``.
_NOTE_BEARING = ("rejected", "information_requested")
#: States where a submitted listing is held for, or has passed, review.
_AWAITING_REVIEW = ("pending", "under_review")

#: Columns exposed for the assigned-listings screen. Kept aligned with
#: ``AgentAssignment.fromJson`` (shared_logic) and the admin queue.
#: ``image_url`` is the listing's primary photograph: the workspace thumbnails
#: every assigned row, and without it a card cannot show the property it names.
#: The lateral join is additive display data — a listing with no usable photo
#: simply reports ``None``.
#:
#: The verification joins are the authoritative record behind the Agent task
#: screen: the listing's own ``verification_status`` says how far the property
#: got, ``property_verification`` says what each review dimension currently is
#: (and when it was submitted), and the newest note-bearing listing-dimension
#: audit row is the administrator's actual feedback. Every one of these is a
#: READ of an existing record - no task is stored a second time here, so a
#: decision made by an administrator is reflected the moment this query runs.
_LIST_SELECT = """
SELECT
    a.listing_id,
    a.agent_id,
    a.assigned_by_user_id,
    a.created_at,
    a.updated_at,
    p.name,
    p.address,
    p.city,
    p.state,
    p.postcode,
    p.property_type,
    p.rental_price,
    p.size_sqft,
    p.latitude,
    p.longitude,
    p.floor_level,
    p.floor_description,
    p.frontage_ft,
    p.furnishing,
    p.tenure,
    p.unit_position,
    CASE WHEN p.parking_owner_declared IS TRUE THEN p.has_parking
         WHEN p.parking_owner_declared IS FALSE THEN NULL
         WHEN p.has_parking = 1 THEN 1 ELSE NULL END AS has_parking,
    p.lease_duration_months,
    p.lease_duration_negotiable,
    p.available_from,
    p.rental_deposit_myr,
    p.title_type,
    p.landlord_fnb_permission,
    p.availability,
    p.is_published,
    p.verification_status,
    p.rejection_reason,
    p.owner_user_id,
    photo.url AS image_url,
    pv.listing_status AS verification_listing_status,
    pv.ownership_status AS verification_ownership_status,
    pv.latest_note AS verification_latest_note,
    pv.created_at AS verification_submitted_at,
    correction.action AS correction_action,
    correction.reason AS correction_reason,
    correction.created_at AS correction_at,
    (p.id IS NOT NULL) AS property_exists
FROM fyp.agent_listing_assignment a
LEFT JOIN fyp.rental_properties p ON p.id = a.listing_id
LEFT JOIN LATERAL (
    SELECT url FROM fyp.property_photos ph
    WHERE ph.property_id = p.id
      AND ph.url IS NOT NULL AND btrim(ph.url) <> ''
    ORDER BY ph.is_primary DESC NULLS LAST, ph.id ASC
    LIMIT 1
) photo ON TRUE
LEFT JOIN fyp.property_verification pv ON pv.property_id = p.id
LEFT JOIN LATERAL (
    SELECT va.action, va.reason, va.created_at
    FROM fyp.verification_audit va
    WHERE va.property_id = p.id
      AND va.action IN ('listing_rejected', 'listing_information_requested')
      AND btrim(coalesce(va.reason, '')) <> ''
    ORDER BY va.created_at DESC
    LIMIT 1
) correction ON TRUE
"""


def _task_projection(data: dict[str, Any]) -> dict[str, Any]:
    """Derive the task state from the records this row actually joins.

    Nothing is invented: an absent verification row or audit row is read as
    "not reported", which the Agent UI renders as no date and no feedback text
    rather than a placeholder. ``editable`` is the backend's own lock policy
    (``can_resubmit`` for the verification dimensions, plus the listing's
    operational status), so a screen never offers an edit the API would refuse
    with 409.
    """
    stage = (data.get("verification_status") or "").strip()
    listing_status = data.get("verification_listing_status")
    ownership_status = data.get("verification_ownership_status")

    data["missing_required_fields"] = (
        listing_completeness_errors(data, require_availability=False)
        if data.get("property_exists") else []
    )
    note_bearing = listing_status in _NOTE_BEARING
    # Administrator feedback travels with the state that asked for it: the
    # audit reason when the listing dimension is still rejected or awaiting
    # information, then the verification row's note, then the operational
    # column a decision was written to. Surfacing any of them once the
    # dimension has moved on would nag about a request already answered.
    feedback = (
        data.get("correction_reason") if note_bearing else None
    ) or (data.get("verification_latest_note") if note_bearing else None) or (
        data.get("rejection_reason") if stage == "rejected" else None
    )
    data["correction_reason"] = feedback or None
    if not note_bearing:
        # The joined audit row belongs to an earlier, already-resolved pass.
        data["correction_action"] = None
        data["correction_at"] = None

    if not data["property_exists"]:
        data["task_state"] = None
        data["editable"] = False
        return data

    if note_bearing or stage == "rejected":
        state = "corrections"
    elif stage == "pending" or listing_status in _AWAITING_REVIEW:
        state = "awaiting_review"
    elif stage == "approved" or listing_status == "verified":
        state = "approved"
    else:
        state = "draft"
    data["task_state"] = state
    data["editable"] = state in ("draft", "corrections") and (
        listing_status is None
        or ownership_status is None
        or can_resubmit(listing_status, ownership_status)
    )
    return data


def _as_dict(row: Any) -> dict[str, Any]:
    data = dict(row)
    for key in ("created_at", "updated_at", "correction_at", "verification_submitted_at", "available_from"):
        value = data.get(key)
        if value is not None and hasattr(value, "isoformat"):
            data[key] = value.isoformat()
    for key in ("rental_price", "size_sqft", "latitude", "longitude"):
        value = data.get(key)
        if value is not None:
            data[key] = float(value)
    data["property_exists"] = bool(data.get("property_exists"))
    return _task_projection(data)


class AgentAssignmentRepository:
    def __init__(self, session: Session):
        self.session = session

    def list_for_agent(self, agent_id: int) -> list[dict[str, Any]]:
        rows = self.session.execute(
            text(_LIST_SELECT + " WHERE a.agent_id = :aid ORDER BY a.listing_id"),
            {"aid": int(agent_id)},
        ).mappings().all()
        return [_as_dict(row) for row in rows]

    def get(self, listing_id: int) -> dict[str, Any] | None:
        row = self.session.execute(
            text(_LIST_SELECT + " WHERE a.listing_id = :lid"),
            {"lid": int(listing_id)},
        ).mappings().first()
        return _as_dict(row) if row is not None else None

    def list_all(self, *, agent_id: int | None = None) -> list[dict[str, Any]]:
        """Administrator overview; optional agent filter."""
        sql = _LIST_SELECT
        params: dict[str, Any] = {}
        if agent_id is not None:
            sql += " WHERE a.agent_id = :aid"
            params["aid"] = int(agent_id)
        sql += " ORDER BY a.listing_id"
        rows = self.session.execute(text(sql), params).mappings().all()
        return [_as_dict(row) for row in rows]

    def _lock_assignment_change(self, listing_id: int) -> bool:
        from sitewise.core.exceptions import ConflictError

        row = self.session.execute(text("""
            SELECT verification_status FROM fyp.rental_properties WHERE id=:id FOR UPDATE
        """), {"id": listing_id}).first()
        if row is None:
            return False
        state = self.session.execute(text("""
            SELECT workflow_status FROM fyp.agent_listing_assignment
            WHERE listing_id=:id FOR UPDATE
        """), {"id": listing_id}).scalar()
        if row[0] == "approved" or state in ("accepted", "needs_correction", "submitted"):
            raise ConflictError("Inspection evidence is protected. Use the correction workflow.")
        return True

    def assign(
        self,
        listing_id: int,
        agent_id: int,
        *,
        assigned_by: uuid.UUID | None = None,
        commit: bool = True,
    ) -> dict[str, Any]:
        """Create/reassign one listing. Raises ValueError when the operational
        property does not exist - the FK would reject it anyway, but an
        explicit error is what the API needs to return 404."""
        if not self._lock_assignment_change(listing_id):
            raise ValueError("Property not found.")
        now = datetime.now(UTC)
        self.session.execute(
            text(
                """
                INSERT INTO fyp.agent_listing_assignment
                    (listing_id, agent_id, assigned_by_user_id, created_at, updated_at, workflow_status, requested_at)
                VALUES (:lid, :aid, :by, :now, :now, 'requested', :now)
                ON CONFLICT (listing_id) DO UPDATE
                    SET agent_id = EXCLUDED.agent_id,
                        assigned_by_user_id = EXCLUDED.assigned_by_user_id,
                        updated_at = EXCLUDED.updated_at,
                        workflow_status = 'requested',
                        requested_at = now(), responded_at = NULL,
                        inspection_data = '{}'::jsonb, inspection_updated_at = NULL,
                        panorama_id = NULL, panorama_tour_id = NULL, panorama_uploaded_at = NULL,
                        submitted_at = NULL, decline_reason = NULL
                """
            ),
            {
                "lid": int(listing_id),
                "aid": int(agent_id),
                "by": str(assigned_by) if assigned_by else None,
                "now": now,
            },
        )
        row = self.get(listing_id)
        assert row is not None  # just written
        if commit:
            self.session.commit()
        return row

    def unassign(self, listing_id: int) -> bool:
        if not self._lock_assignment_change(listing_id):
            return False
        result = self.session.execute(
            text("DELETE FROM fyp.agent_listing_assignment WHERE listing_id = :lid"),
            {"lid": int(listing_id)},
        )
        self.session.commit()
        return bool(result.rowcount)

    def agent_id_for(self, listing_id: int) -> int | None:
        value = self.session.execute(
            text(
                "SELECT agent_id FROM fyp.agent_listing_assignment "
                "WHERE listing_id = :lid"
            ),
            {"lid": int(listing_id)},
        ).scalar()
        return int(value) if value is not None else None
