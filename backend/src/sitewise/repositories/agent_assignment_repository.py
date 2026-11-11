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

#: Columns exposed for the assigned-listings screen. Kept aligned with
#: ``AgentAssignment.fromJson`` (shared_logic) and the admin queue.
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
    p.property_type,
    p.rental_price,
    p.size_sqft,
    p.floor_level,
    p.availability,
    p.is_published,
    p.verification_status,
    p.owner_user_id,
    (p.id IS NOT NULL) AS property_exists
FROM agent_listing_assignment a
LEFT JOIN fyp.rental_properties p ON p.id = a.listing_id
"""


def _as_dict(row: Any) -> dict[str, Any]:
    data = dict(row)
    for key in ("created_at", "updated_at"):
        value = data.get(key)
        if value is not None and hasattr(value, "isoformat"):
            data[key] = value.isoformat()
    for key in ("rental_price", "size_sqft"):
        value = data.get(key)
        if value is not None:
            data[key] = float(value)
    data["property_exists"] = bool(data.get("property_exists"))
    return data


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

    def assign(
        self,
        listing_id: int,
        agent_id: int,
        *,
        assigned_by: uuid.UUID | None = None,
    ) -> dict[str, Any]:
        """Create/reassign one listing. Raises ValueError when the operational
        property does not exist - the FK would reject it anyway, but an
        explicit error is what the API needs to return 404."""
        exists = self.session.execute(
            text("SELECT 1 FROM fyp.rental_properties WHERE id = :lid"),
            {"lid": int(listing_id)},
        ).scalar()
        if not exists:
            raise ValueError("No operational property with this id.")
        now = datetime.now(UTC)
        self.session.execute(
            text(
                """
                INSERT INTO agent_listing_assignment
                    (listing_id, agent_id, assigned_by_user_id, created_at, updated_at)
                VALUES (:lid, :aid, :by, :now, :now)
                ON CONFLICT (listing_id) DO UPDATE
                    SET agent_id = EXCLUDED.agent_id,
                        assigned_by_user_id = EXCLUDED.assigned_by_user_id,
                        updated_at = EXCLUDED.updated_at
                """
            ),
            {
                "lid": int(listing_id),
                "aid": int(agent_id),
                "by": str(assigned_by) if assigned_by else None,
                "now": now,
            },
        )
        self.session.commit()
        row = self.get(listing_id)
        assert row is not None  # just written
        return row

    def unassign(self, listing_id: int) -> bool:
        result = self.session.execute(
            text("DELETE FROM agent_listing_assignment WHERE listing_id = :lid"),
            {"lid": int(listing_id)},
        )
        self.session.commit()
        return bool(result.rowcount)

    def agent_id_for(self, listing_id: int) -> int | None:
        value = self.session.execute(
            text(
                "SELECT agent_id FROM agent_listing_assignment "
                "WHERE listing_id = :lid"
            ),
            {"lid": int(listing_id)},
        ).scalar()
        return int(value) if value is not None else None
