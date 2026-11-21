"""Persistence extension around the unchanged sandbox BCB contract.

No production tenant/concept/GEO/purpose authority is invented by this port.
"""
from dataclasses import dataclass
from typing import ContextManager, Protocol
from uuid import UUID

from sitewise.services.ports.business_context_v1_port import ContextRequest
from sitewise.services.ports.m2_repository_port import M2RepositoryPort


@dataclass(frozen=True)
class ContextSelection:
    assessment_id: UUID
    confirmation_id: UUID
    revision: int


@dataclass(frozen=True)
class ContextActor:
    user_id: UUID
    role: str


@dataclass(frozen=True)
class GovernedContextInputs:
    request: ContextRequest
    decision: dict
    bindings: dict


class ContextStoreUnavailable(RuntimeError):
    """Safe infrastructure failure, without connection or source details."""
    def __init__(self, code, *, retryable=False):
        self.retryable = retryable
        super().__init__(code)


class ContextBindingUnavailable(ValueError):
    def __init__(self, code='BCB_BINDING_AUTHORITY_UNVERIFIED'):
        self.code = code
        super().__init__(code)


class ContextUnit(Protocol):
    m2: M2RepositoryPort
    def resolve_inputs(self, selection: ContextSelection, actor: ContextActor) -> GovernedContextInputs: ...
    def read_build(self, confirmation_id: UUID, owner_id: UUID) -> dict | None: ...
    def read_context(self, context_id: UUID, owner_id: UUID) -> dict | None: ...
    def put_context(self, row: dict) -> tuple[dict, bool]: ...
    def record_build(self, confirmation_id: UUID, owner_id: UUID, status: str,
                     code: str | None, context_id: UUID | None = None) -> None: ...
    def commit(self) -> None: ...
    def rollback(self) -> None: ...


class ContextStorePort(Protocol):
    def open(self) -> ContextManager[ContextUnit]:
        """A dedicated PostgreSQL repeatable-read transaction; rollback on exit."""
        ...
