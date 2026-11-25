"""Database-derived scope for the Owner / Agent (Provider) workspace.

An Owner and an Agent reach the SAME operational records through *different*
relationships, so "which properties may this account manage" can never be
answered from a role name. It is resolved from the database:

* an **owner** (canonical ``owner`` role) reaches the rows whose
  ``fyp.rental_properties.owner_user_id`` is their verified identity;
* an **entrepreneur** reaches the rows it owns under the same predicate. The
  role no longer *means* owner — the two are distinct — but accounts provisioned
  before the role split own properties recorded against their identity, and the
  ownership row is what authorises them, not the role name;
* an **agent** reaches rows through ``fyp.agent_listing_assignment`` — a
  real foreign key to ``fyp.rental_properties.id`` — never through a name and
  never through ownership the agent does not hold;
* an **administrator** is not a provider. It is given the unrestricted scope
  explicitly, because administration is the only reason it reaches this
  surface at all.

Authorization fails closed: a Supabase outage denies agent scope rather than
silently granting it.
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import HTTPException
from sqlalchemy import text
from sqlmodel import Session

from sitewise.domain import rbac

logger = logging.getLogger("sitewise.provider_scope")


def agent_id_for_user(user_id: Any) -> int | None:
    """The account's ``public.agent.agent_id``, or ``None`` when it is not one.

    The profile lookup is the single agent-identity definition shared by the
    listing routes and the provider workspace routes.
    """
    try:
        from sitewise.core.supabase_admin import SupabaseAdminService

        profile = SupabaseAdminService().get_agent_profile(user_id)
    except Exception:  # noqa: BLE001 - authorization must never fail open
        logger.warning("Agent profile lookup failed", exc_info=True)
        return None
    if not profile or profile.get("agent_id") is None:
        return None
    return int(profile["agent_id"])


def is_agent_role(role: str) -> bool:
    return rbac.has_role(role, (rbac.ROLE_AGENT,))


def listing_owner(session: Session, listing_id: int) -> tuple[bool, Any]:
    """``(found, owner_user_id)`` for one operational listing.

    Absence is reported separately from a null owner on purpose: an
    agent-created listing legitimately has ``owner_user_id IS NULL``, and the
    caller has to tell "no such listing" (404) apart from "not yours" (403).
    """
    row = session.execute(
        text("SELECT owner_user_id FROM fyp.rental_properties WHERE id = :pid"),
        {"pid": listing_id},
    ).first()
    if row is None:
        return False, None
    return True, row[0]


def agent_is_assigned(session: Session, *, listing_id: int, agent_id: int) -> bool:
    """True only when an assignment row links this listing to this agent.

    An agent's authority over an existing listing is the assignment, never the
    account role: one agent can never reach another agent's listings.
    """
    row = session.execute(
        text(
            "SELECT 1 FROM fyp.agent_listing_assignment "
            "WHERE listing_id = :lid AND agent_id = :aid"
        ),
        {"lid": listing_id, "aid": agent_id},
    ).first()
    return row is not None


def can_manage_listing(
    session: Session,
    *,
    listing_id: int,
    user_id: Any,
    role: str,
) -> tuple[bool, bool]:
    """``(found, allowed)`` — the owner / assigned-agent / admin rule, once.

    Tour reads, panorama uploads and verification submissions all ask the same
    question of the same two tables, so the predicate lives here rather than in
    each caller. Ownership is the verified identity, administration is explicit,
    and an agent is in only through its assignment row: an agent with no
    assignment manages nothing, and a null owner never matches a caller.
    """
    found, owner = listing_owner(session, listing_id)
    if not found:
        return False, False
    if rbac.can_administer_users(role):
        return True, True
    if owner is not None and str(owner) == str(user_id):
        return True, True
    if is_agent_role(role):
        agent_id = agent_id_for_user(user_id)
        if agent_id is not None and agent_is_assigned(
            session, listing_id=listing_id, agent_id=agent_id
        ):
            return True, True
    return True, False


APPROVED_LOCK_MESSAGE = "This property has been approved and is locked for editing."
MUTABLE_STATUSES = ("draft", "rejected", "changes_requested")


def require_mutable_listing(
    session: Session, *, listing_id: int, role: str
) -> dict[str, Any]:
    """Re-read the property inside the caller's transaction and lock it.

    Approval, publication and pending review are authoritative in the database,
    never in a cached client status or an ``editable`` response field. Only an
    administrator may bypass this lock (for the explicit correction workflow).
    """
    if rbac.can_administer_users(role):
        return {"listing_id": listing_id, "administrator": True}
    row = session.execute(
        text(
            "SELECT verification_status, is_published "
            "FROM fyp.rental_properties WHERE id = :pid FOR UPDATE"
        ),
        {"pid": listing_id},
    ).mappings().first()
    if row is None:
        raise HTTPException(status_code=404, detail="Property not found.")
    status = str(row.get("verification_status") or "").lower()
    published = bool(row.get("is_published"))
    if published or status in ("approved", "verified", "pending", "under_review"):
        detail = (
            APPROVED_LOCK_MESSAGE
            if published or status in ("approved", "verified")
            else "This property is locked while it awaits administrator review."
        )
        raise HTTPException(status_code=409, detail=detail)
    if status not in MUTABLE_STATUSES:
        raise HTTPException(status_code=409, detail=APPROVED_LOCK_MESSAGE)
    return {"listing_id": listing_id, "administrator": False, "status": status}


def managed_property_ids(
    session: Session, *, user_id: Any, role: str
) -> list[int] | None:
    """Operational property ids the account may manage.

    ``None`` means "no restriction". It is returned only for administrators:
    every provider-scoped read passes this list into an ``= ANY(...)`` /
    ``IN`` predicate, so an empty list yields an empty result rather than an
    unfiltered one.
    """
    if rbac.can_administer_users(role):
        return None

    ids: set[int] = set()
    owned = session.execute(
        text("SELECT id FROM fyp.rental_properties WHERE owner_user_id = :uid"),
        {"uid": str(user_id)},
    ).scalars().all()
    ids.update(int(value) for value in owned)

    if is_agent_role(role):
        agent_id = agent_id_for_user(user_id)
        if agent_id is not None:
            assigned = session.execute(
                text(
                    "SELECT listing_id FROM fyp.agent_listing_assignment "
                    "WHERE agent_id = :aid"
                ),
                {"aid": agent_id},
            ).scalars().all()
            ids.update(int(value) for value in assigned)

    return sorted(ids)


def scope_predicate(
    column: str, property_ids: list[int] | None
) -> tuple[str, dict[str, Any]]:
    """``(sql_fragment, params)`` restricting ``column`` to the managed set.

    Administrators (``None``) get a fragment that is always true; an empty
    managed set gets one that is always false. Both cases keep the caller's
    ``WHERE`` clause unconditional, so a mistake here can never widen a query
    to every provider's rows.

    Explicit placeholders are used instead of an array bind: an empty Python
    list sent as ``= ANY(%s)`` cannot be typed by the server.
    """
    if property_ids is None:
        return "TRUE", {}
    if not property_ids:
        return "FALSE", {}
    names = [f"__scope_{index}" for index in range(len(property_ids))]
    placeholders = ", ".join(f":{name}" for name in names)
    params = dict(zip(names, (int(value) for value in property_ids), strict=True))
    return f"{column} IN ({placeholders})", params
