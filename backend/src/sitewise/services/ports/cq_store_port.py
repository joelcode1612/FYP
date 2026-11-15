"""CQ persistence/authority boundaries; approval cannot arrive from client JSON."""
from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class CqGrant:
    scope: str
    receipt: str
    production_fielding_authorized: bool = False


class CqAuthorityPort(Protocol):
    def authorize(self, unit, release, actor_id, operation) -> CqGrant: ...


class CqStorePort(Protocol):
    def open(self): ...
