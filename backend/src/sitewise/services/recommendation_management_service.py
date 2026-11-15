"""Batch resolution of commercial-property management for ranked listings.

Catalogue ids (``MD-``/``EP-`` text) and operational property ids (bigint) are
different namespaces. They are joined only through
``rental_properties.listing_id`` or a VERIFIED ``property_subject_links``
relationship, and an ambiguous many-to-one mapping is refused rather than
guessed.

The business rule itself lives in :mod:`sitewise.domain.management`; this
module exists to answer it for a page of results in a bounded number of
queries. Assignments are read from the existing
``agent_listing_assignment`` table. Agent names come from trusted Supabase
``public.agent`` profiles; owner names from the local identity mirror via
``owner_user_id``, never the legacy ``owner_id``.
"""

from collections import defaultdict
import logging
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.domain.management import (
    TYPE_AGENT,
    TYPE_OWNER,
    ManagementFacts,
    derive,
    derive_provenance,
    unavailable,
)

logger = logging.getLogger("sitewise.recommendation_management")


class ManagementLookupError(Exception):
    """An authoritative assignment lookup could not be completed."""


def unavailable_management() -> dict[str, Any]:
    return unavailable()


def unassigned_management() -> dict[str, Any]:
    """No operational property is mapped to this catalogue record."""
    return {
        "type": "unresolved",
        "status": "unresolved",
        "label": "Manager Not Assigned",
        "name": None,
        "manager_name": None,
        "agent_id": None,
        "owner_user_id": None,
        "assignment_status": "none",
        "ownership_status": "unknown",
        "steward_role": None,
        "reason": "no_operational_property_mapping",
        "provenance": None,
    }


# Both relationship sources are considered. The UNION deduplicates a record
# mapped through both its canonical string id and a verified research link.
# Only approved, published operational listings can expose manager identities.
_MAPPINGS_SQL = """
WITH candidate AS (
  SELECT p.id AS property_id, p.listing_id::text AS catalogue_id
  FROM fyp.rental_properties p
  WHERE p.listing_id IS NOT NULL
    AND p.is_published IS TRUE AND p.verification_status = 'approved'
    AND (:all_rows OR p.listing_id = ANY(:ids))
  UNION
  SELECT p.id AS property_id, l.sitewise_property_id::text AS catalogue_id
  FROM fyp.property_subject_links l
  JOIN fyp.rental_properties p ON p.id = l.property_id
  WHERE l.match_verified IS TRUE AND l.sitewise_property_id IS NOT NULL
    AND p.is_published IS TRUE AND p.verification_status = 'approved'
    AND (:all_rows OR l.sitewise_property_id = ANY(:ids))
)
SELECT c.catalogue_id, c.property_id, p.owner_user_id, p.owner_id, p.listing_id,
       p.verification_status, p.is_published, a.agent_id,
       u.full_name AS owner_name, u.account_status AS owner_status
FROM candidate c
JOIN fyp.rental_properties p ON p.id = c.property_id
LEFT JOIN agent_listing_assignment a ON a.listing_id = p.id
LEFT JOIN users u ON u.user_id = p.owner_user_id
"""


class RecommendationManagementService:
    def __init__(self, db: Session):
        self.db = db

    def _mappings(self, ids: list[str] | None = None) -> dict[str, list[dict[str, Any]]]:
        """Map catalogue ids to UNIQUE operational identities.

        A missing table, mismatched database or SQL outage is an error, never
        silently interpreted as 'no assigned properties'.
        """
        if ids is not None and not ids:
            return {}
        try:
            rows = self.db.execute(
                text(_MAPPINGS_SQL),
                {"all_rows": ids is None, "ids": ids or []},
            ).mappings().all()
        except Exception as exc:
            self.db.rollback()  # avoid leaving a PostgreSQL transaction aborted
            logger.exception("Could not resolve operational property managers")
            raise ManagementLookupError("Property manager information is unavailable") from exc
        groups: dict[str, dict[int, dict[str, Any]]] = defaultdict(dict)
        for row in rows:
            canonical = str(row["catalogue_id"] or "").strip()
            if not canonical:
                continue
            groups[canonical][int(row["property_id"])] = dict(row)
        return {pid: list(records.values()) for pid, records in groups.items()}

    def assigned_catalogue_ids(self) -> tuple[str, ...]:
        """Filter scope from the actual assignment relationships, before rank.

        "Managed" means a responsible *person* — an agent or an active owner.
        Platform stewardship is a catalogue function, not a manager, so it does
        not make a listing agent-managed.
        """
        groups = self._mappings()
        agent_ids = {
            int(matches[0]["agent_id"])
            for matches in groups.values()
            if len(matches) == 1 and matches[0].get("agent_id") is not None
        }
        agent_names, agent_statuses = self._agent_directory(agent_ids)
        managed: list[str] = []
        for pid, matches in groups.items():
            if len(matches) != 1:
                continue
            result = self._derive_one(matches[0], agent_names, agent_statuses)
            if result["type"] in (TYPE_AGENT, TYPE_OWNER):
                managed.append(pid)
        return tuple(sorted(managed))

    def _agent_directory(self, agent_ids: set[int]) -> tuple[dict[int, str], dict[int, str]]:
        """Delegate to the single agent-directory reader.

        Keeping one implementation means the ranked-list path and the
        property-detail path can never disagree about a manager's name or
        whether the agent's account is still active.
        """
        from sitewise.services.property_management_service import agent_directory

        return agent_directory(self.db, agent_ids)

    def _derive_one(
        self,
        record: dict[str, Any],
        agent_names: dict[int, str],
        agent_statuses: dict[int, str],
    ) -> dict[str, Any]:
        agent_id = record.get("agent_id")
        facts = ManagementFacts(
            property_id=int(record["property_id"]),
            provenance=derive_provenance(record.get("listing_id")),
            owner_user_id=(
                str(record["owner_user_id"])
                if record.get("owner_user_id") is not None
                else None
            ),
            owner_display_name=record.get("owner_name"),
            owner_account_status=record.get("owner_status"),
            agent_id=int(agent_id) if agent_id is not None else None,
            agent_display_name=agent_names.get(int(agent_id)) if agent_id is not None else None,
            agent_account_status=(
                agent_statuses.get(int(agent_id)) if agent_id is not None else None
            ),
            legacy_owner_id=record.get("owner_id"),
            verification_status=record.get("verification_status"),
            is_published=bool(record.get("is_published")),
        )
        return derive(facts)

    def resolve(self, ids: list[str]) -> dict[str, dict[str, Any]]:
        groups = self._mappings(ids)
        agent_ids = {
            int(matches[0]["agent_id"])
            for matches in groups.values()
            if len(matches) == 1 and matches[0].get("agent_id") is not None
        }
        agent_names, agent_statuses = self._agent_directory(agent_ids)

        resolved: dict[str, dict[str, Any]] = {}
        for pid in ids:
            matches = groups.get(pid, [])
            if not matches:
                resolved[pid] = unassigned_management()
            elif len(matches) != 1:
                # Never choose the first of multiple operational properties.
                resolved[pid] = unavailable_management()
            else:
                resolved[pid] = self._derive_one(
                    matches[0], agent_names, agent_statuses
                )
        return resolved
