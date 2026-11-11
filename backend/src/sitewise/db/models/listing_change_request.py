"""Agent listing change requests (additive, 2026-11-11).

One per agent edit cycle on an ASSIGNED listing: the agent saves proposed
field changes as a ``draft`` request, submits it for administrator review
(``pending``), and an administrator resolves it (``approved`` /
``rejected`` / ``changes_requested``). The operational row in
``fyp.rental_properties`` is NEVER written by an agent; ``approved`` changes
are applied by the administrator decision endpoint under server policy.

This table is deliberately separate from the entrepreneur submission
workflow (``property_verification``): that one gates initial publication of
a property, this one governs later edits by the assigned agent. The
Supabase-side ``listing_verification`` finding records (staff.py) are also
untouched — they remain the site-visit finding mechanism.

Rows are append-mostly: decisions update the request's status columns, the
history lives in :class:`ListingChangeAudit` and is never rewritten.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

from sqlalchemy import CheckConstraint, Column, JSON
from sqlmodel import Field, SQLModel

#: Lifecycle of one agent change request.
CHANGE_REQUEST_STATUSES = (
    "draft",
    "pending",
    "approved",
    "rejected",
    "changes_requested",
)

#: Fields an agent may propose. The registered address (address / city /
#: state / postcode) and every ownership or publication column are NOT
#: agent-editable — location and ownership changes require the separate
#: verified workflow, and publication is administrator-controlled.
AGENT_PROPOSABLE_FIELDS = (
    "name",
    "rental_price",
    "size_sqft",
    "property_type",
    "floor_level",
    "availability",
    "description",
    "has_parking",
    "is_fnb_suitable",
)


class ListingChangeRequest(SQLModel, table=True):
    __tablename__ = "listing_change_request"
    __table_args__ = (
        CheckConstraint(
            "status IN ('draft','pending','approved','rejected',"
            "'changes_requested')",
            name="ck_listing_change_request_status",
        ),
    )

    change_request_id: uuid.UUID = Field(
        default_factory=uuid.uuid4, primary_key=True
    )
    # The OPERATIONAL listing id (fyp.rental_properties.id) — the same numeric
    # id the Supabase assignment row carries in listing.listing_id. There is
    # no conversion between id systems anywhere in this workflow.
    listing_id: int = Field(
        foreign_key="fyp.rental_properties.id", nullable=False, index=True
    )
    proposed_by: uuid.UUID = Field(
        foreign_key="users.user_id", nullable=False, index=True
    )
    # {field: {"from": <current value>, "to": <proposed value>}} — captured
    # server-side from the live row at save time, never trusted from the
    # client's "from" values.
    changes: dict = Field(
        default_factory=dict, sa_column=Column(JSON, nullable=False)
    )
    status: str = Field(default="draft", max_length=24, nullable=False, index=True)
    # Required (>= 12 chars) when the request is submitted for review.
    reason: str | None = Field(default=None, max_length=2000)
    reviewed_by: uuid.UUID | None = Field(default=None, foreign_key="users.user_id")
    review_note: str | None = Field(default=None, max_length=2000)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC), nullable=False
    )
    updated_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC), nullable=False
    )


class ListingChangeAudit(SQLModel, table=True):
    """Append-only history for one change request (the Activity tab source).

    One row per real event: draft saved, review requested, administrator
    decision, agent note. Nothing here is overwritten; the request row holds
    only the CURRENT state.
    """

    __tablename__ = "listing_change_audit"

    audit_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    # NULL for listing-level events (agent notes) that belong to no single
    # request; set for every request-scoped event.
    change_request_id: uuid.UUID | None = Field(
        default=None,
        foreign_key="listing_change_request.change_request_id",
        index=True,
    )
    listing_id: int = Field(
        foreign_key="fyp.rental_properties.id", nullable=False, index=True
    )
    # draft_saved | review_requested | approved | rejected |
    # changes_requested | note_added
    action: str = Field(max_length=40, nullable=False)
    actor_user_id: uuid.UUID = Field(
        foreign_key="users.user_id", nullable=False, index=True
    )
    note: str | None = Field(default=None, max_length=2000)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC), nullable=False, index=True
    )
