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
* an **agent** reaches rows through ``public.agent_listing_assignment`` — a
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
                    "SELECT listing_id FROM agent_listing_assignment "
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
