"""Resolve property management from existing operational relationships.

No new database column is needed: the business rule lives in
:mod:`sitewise.domain.management` and this module only supplies it with facts
read from the operational database. The research catalogue uses text IDs;
operational assignments use ``fyp.rental_properties.id`` (bigint). Resolve the
relationship via the exact ``listing_id`` key, never names or coordinates.

Unknown or ambiguous mappings are not given a person or a management type.
"""

from __future__ import annotations

from typing import Any, Iterable, Sequence

from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import AuthUnavailableError
from sitewise.core.supabase_admin import SupabaseAdminError, SupabaseAdminService
from sitewise.domain.management import (
    ManagementFacts,
    derive,
    derive_provenance,
    unavailable,
)

_FACTS_SELECT = """
SELECT p.id, p.owner_user_id, p.owner_id, p.listing_id, p.verification_status,
       p.is_published,
       u.full_name AS owner_name, u.account_status AS owner_status,
       a.agent_id
FROM fyp.rental_properties p
LEFT JOIN users u ON u.user_id = p.owner_user_id
LEFT JOIN agent_listing_assignment a ON a.listing_id = p.id
"""


def agent_directory(
    session: Session, agent_ids: Iterable[int]
) -> tuple[dict[int, str], dict[int, str]]:
    """Return ``(display_names, account_statuses)`` for the given agent ids.

    One Supabase call covers every agent on the page. A name is authoritative
    only when the profile is tied to a real auth identity; the status comes
    from the local mirror, which is what the authorization layer enforces. A
    remote failure leaves the name unknown rather than inventing one.
    """
    wanted = {int(a) for a in agent_ids}
    if not wanted:
        return {}, {}
    names: dict[int, str] = {}
    user_ids: dict[int, str] = {}
    try:
        for profile in SupabaseAdminService().list_agent_profiles():
            if not profile.get("user_id") or profile.get("agent_id") is None:
                continue
            agent_id = int(profile["agent_id"])
            if agent_id not in wanted:
                continue
            user_ids[agent_id] = str(profile["user_id"])
            name = str(profile.get("agent_name") or "").strip()
            if name:
                names[agent_id] = name
    except (AuthUnavailableError, SupabaseAdminError):
        # The local assignment remains proven; a remote name is not.
        return {}, {}
    statuses: dict[int, str] = {}
    if user_ids:
        try:
            rows = session.execute(
                text(
                    "SELECT user_id::text AS uid, account_status FROM users "
                    "WHERE user_id::text = ANY(:ids)"
                ),
                {"ids": sorted(user_ids.values())},
            ).mappings().all()
            by_uuid = {str(r["uid"]): str(r["account_status"]) for r in rows}
            statuses = {
                agent_id: by_uuid[uid]
                for agent_id, uid in user_ids.items()
                if uid in by_uuid
            }
        except Exception:  # noqa: BLE001 - status stays unknown, never guessed
            statuses = {}
    return names, statuses


def _derive_row(
    row: Any, names: dict[int, str], statuses: dict[int, str]
) -> dict:
    agent_id = row["agent_id"]
    facts = ManagementFacts(
        property_id=int(row["id"]),
        provenance=derive_provenance(row["listing_id"]),
        owner_user_id=(
            str(row["owner_user_id"]) if row["owner_user_id"] is not None else None
        ),
        owner_display_name=row["owner_name"],
        owner_account_status=row["owner_status"],
        agent_id=int(agent_id) if agent_id is not None else None,
        agent_display_name=names.get(int(agent_id)) if agent_id is not None else None,
        agent_account_status=(
            statuses.get(int(agent_id)) if agent_id is not None else None
        ),
        legacy_owner_id=row["owner_id"],
        verification_status=row["verification_status"],
        is_published=bool(row["is_published"]),
    )
    return derive(facts)


def _assignment_table_missing(session: Session) -> bool:
    # Do not claim "unassigned" if the assignment migration was never applied.
    return (
        session.execute(
            text("SELECT to_regclass('public.agent_listing_assignment')")
        ).scalar()
        is None
    )


def resolve_listings(session: Session, listing_ids: Sequence[int]) -> dict[int, dict]:
    """Management for many operational properties in a bounded number of queries."""
    wanted = [int(i) for i in listing_ids]
    if not wanted:
        return {}
    if _assignment_table_missing(session):
        return {lid: unavailable() for lid in wanted}
    rows = session.execute(
        text(_FACTS_SELECT + " WHERE p.id = ANY(:ids)"),
        {"ids": wanted},
    ).mappings().all()
    names, statuses = agent_directory(
        session, [r["agent_id"] for r in rows if r["agent_id"] is not None]
    )
    resolved = {int(r["id"]): _derive_row(r, names, statuses) for r in rows}
    # A requested id with no operational row is not "unmanaged" — it is absent.
    return {lid: resolved.get(lid, unavailable()) for lid in wanted}


def resolve_management(
    session: Session, *, catalogue_id: str | None = None, listing_id: int | None = None
) -> dict:
    """Read one manager from FK-backed assignments or UUID owner identity.

    The agent relationship takes precedence: an agent may manage an
    owner-submitted listing while the owner keeps ownership. Missing identities
    do not produce made-up names, and the response deliberately excludes email,
    phone and internal identifiers.
    """
    if (catalogue_id is None) == (listing_id is None):
        raise ValueError("Pass exactly one listing identity.")
    if _assignment_table_missing(session):
        return unavailable()
    # The lookup column is chosen from a fixed allow-list; values are bound.
    column = "p.listing_id" if catalogue_id is not None else "p.id"
    lookup = catalogue_id if catalogue_id is not None else listing_id
    rows = session.execute(
        text(_FACTS_SELECT + f" WHERE {column} = :lookup LIMIT 2"),
        {"lookup": lookup},
    ).mappings().all()
    if len(rows) != 1:
        # No reliable operational match, or more than one with the same ID.
        return unavailable()
    names, statuses = agent_directory(
        session, [rows[0]["agent_id"]] if rows[0]["agent_id"] is not None else []
    )
    return _derive_row(rows[0], names, statuses)
