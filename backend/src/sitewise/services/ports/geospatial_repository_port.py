"""Contract the geospatial read model is written against.

The router built ``GeospatialRepository`` (and ``RefreshState``) itself in every
handler, which made the presentation layer the owner of row access. The
collaborators are declared here instead and bound to the live session by the
composition root in :mod:`sitewise.dependencies`; the freshness half of the
contract lives in :mod:`~sitewise.services.ports.refresh_state_port`.

Only the four reads the endpoints expose are declared, so
``GeospatialRepository`` satisfies this implicitly (it is a superset).
"""

from __future__ import annotations

from typing import Any, Protocol


class GeospatialRepositoryPort(Protocol):
    """Row access for competitors, geo features and district demographics."""

    def get_competitors_by_property_id(self, property_id: int) -> list[Any]: ...

    def get_geo_feature_by_property_id(self, property_id: int) -> Any | None: ...

    def get_foot_traffic_by_property_id(self, property_id: int) -> Any | None: ...

    def get_all_districts(self, offset: int = 0, limit: int = 100) -> list[Any]: ...
