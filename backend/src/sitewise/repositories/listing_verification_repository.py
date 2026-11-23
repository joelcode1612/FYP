"""Agent listing-verification findings backed by the canonical local table.

The Supabase ``public.listing_verification`` table that ``staff.py`` was
originally written against was never provisioned in the live project (it is
absent from the REST inventory both before and after schema migration 03), so
every call to the retired adapter methods failed at runtime. This repository
is the canonical replacement: findings persist to
``fyp.property_listing_verification`` — the retained local table whose
``property_id`` is a FOREIGN KEY to ``fyp.rental_properties(id)`` (ON DELETE
CASCADE) and whose ``reviewer_user_id`` references ``public.users(user_id)``.

Table shape (reviewed, not altered):

* PRIMARY KEY (property_id) — one verification state per listing, so a new
  finding replaces the previous one (upsert) instead of accumulating rows.
* ``verification_method`` is TEXT and carries the two finding statuses as a
  JSON object. This is lossless (both statuses round-trip exactly) and
  requires NO schema change to store a payload the table predates.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

_EXISTS_SQL = "SELECT 1 FROM fyp.rental_properties WHERE id = :lid"
_SELECT_SQL = """
SELECT property_id, reviewer_user_id, verification_method,
       evidence_reference, review_notes, reviewed_at, updated_at
FROM fyp.property_listing_verification
WHERE property_id = :lid
"""
_UPSERT_SQL = """
INSERT INTO fyp.property_listing_verification
    (property_id, reviewer_user_id, verification_method, evidence_reference,
     review_notes, reviewed_at, updated_at)
VALUES (:lid, :reviewer, :method, :evidence, :notes, :now, :now)
ON CONFLICT (property_id) DO UPDATE
    SET reviewer_user_id = EXCLUDED.reviewer_user_id,
        verification_method = EXCLUDED.verification_method,
        evidence_reference = EXCLUDED.evidence_reference,
        review_notes = EXCLUDED.review_notes,
        reviewed_at = EXCLUDED.reviewed_at,
        updated_at = EXCLUDED.updated_at
"""

#: Response contract of ``POST/GET /staff/listings/{id}/verifications``.
#: Field names match the retired adapter's payload exactly.
_CONTRACT_KEYS = (
    "property_authenticity_status",
    "commercial_classification_status",
)


def _statuses_from_method(raw: str | None) -> dict[str, str | None]:
    statuses: dict[str, str | None] = {key: None for key in _CONTRACT_KEYS}
    if not raw:
        return statuses
    try:
        decoded = json.loads(raw)
    except ValueError:
        return statuses
    if isinstance(decoded, dict):
        for key in _CONTRACT_KEYS:
            value = decoded.get(key)
            statuses[key] = str(value) if value is not None else None
    return statuses


def _iso(value: Any) -> str | None:
    return value.isoformat() if value is not None and hasattr(value, "isoformat") else None


class ListingVerificationRepository:
    def __init__(self, session: Session):
        self.session = session

    def _as_contract(self, row: Any) -> dict[str, Any]:
        data = dict(row)
        statuses = _statuses_from_method(data.get("verification_method"))
        return {
            "listing_id": int(data["property_id"]),
            "verified_by_user_id": (
                str(data["reviewer_user_id"]) if data.get("reviewer_user_id") else None
            ),
            "property_authenticity_status": statuses["property_authenticity_status"],
            "commercial_classification_status": statuses["commercial_classification_status"],
            "verification_reason": data.get("review_notes"),
            "evidence_url": data.get("evidence_reference"),
            "reviewed_at": _iso(data.get("reviewed_at")),
            "updated_at": _iso(data.get("updated_at")),
        }

    def record_finding(
        self,
        *,
        listing_id: int,
        verified_by_user_id: Any,
        property_authenticity_status: str,
        commercial_classification_status: str,
        verification_reason: str,
        evidence_url: str | None = None,
    ) -> dict[str, Any]:
        """Upsert the verification state for one listing.

        Raises ValueError when the operational property does not exist — the
        FK would reject it anyway, but an explicit error is what the API
        needs to return 404 (same contract as AgentAssignmentRepository.assign).
        """
        exists = self.session.execute(text(_EXISTS_SQL), {"lid": int(listing_id)}).scalar()
        if not exists:
            raise ValueError("No operational property with this id.")
        # reviewed_at / updated_at are TIMESTAMP WITHOUT TIME ZONE; store naive UTC.
        now = datetime.now(UTC).replace(tzinfo=None)
        self.session.execute(
            text(_UPSERT_SQL),
            {
                "lid": int(listing_id),
                "reviewer": str(verified_by_user_id),
                "method": json.dumps({
                    "property_authenticity_status": property_authenticity_status,
                    "commercial_classification_status": commercial_classification_status,
                }),
                "evidence": evidence_url,
                "notes": verification_reason,
                "now": now,
            },
        )
        self.session.commit()
        row = self.session.execute(text(_SELECT_SQL), {"lid": int(listing_id)}).mappings().first()
        assert row is not None  # just written
        return self._as_contract(row)

    def list_for_listing(self, listing_id: int) -> list[dict[str, Any]]:
        row = self.session.execute(text(_SELECT_SQL), {"lid": int(listing_id)}).mappings().first()
        return [self._as_contract(row)] if row is not None else []
