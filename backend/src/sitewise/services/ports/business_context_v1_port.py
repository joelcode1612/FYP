"""Read contracts only. No persistence models, SQL, provider or route registration."""
from dataclasses import dataclass
from datetime import datetime
from typing import ContextManager, Protocol
from uuid import UUID

from sitewise.services.ports.m2_repository_port import M2RepositoryPort


@dataclass(frozen=True)
class ContextRequest:
    # Construct on the server from verified identity; never bind identity from JSON.
    viewer_id: UUID
    tenant_id: str
    role: str
    assessment_id: UUID
    purpose: str
    confirmation_id: UUID
    confirmed_revision: int
    concept_version: str


class AuthorizationPort(Protocol):
    def authorize(self, request: ContextRequest) -> dict:
        """Return a trusted, versioned, explicitly scoped access decision, or deny.

        Must verify active authenticated account, authoritative role, tenant,
        ownership and purpose. Do not query M2/customer answer content here.
        """
        ...


@dataclass(frozen=True)
class ContextReadView:
    m2: M2RepositoryPort
    bindings: dict


class SnapshotPort(Protocol):
    def open_read(self, request: ContextRequest, decision: dict) -> ContextManager[ContextReadView]:
        """All M2 reads + bindings must share one immutable consistent snapshot.

        Production adapter is intentionally NOT supplied: needs authoritative
        tenant/concept/GEO/source owners. Use a dedicated read-only consistent
        transaction and no autoflush. No write, commit or raw customer port.
        Reject unsupported consistency rather than combining separate live reads.
        """
        ...


class ClockPort(Protocol):
    def now(self) -> datetime: ...
