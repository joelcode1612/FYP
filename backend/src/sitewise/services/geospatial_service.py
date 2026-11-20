"""Geospatial read model: competitors, geo features, foot traffic, districts.

Every method returns exactly what the corresponding row-access call returned
before this service existed; the endpoints under ``/api/v1/geospatial`` keep the
same payloads. The 404 decisions stay with the transport layer because they are
transport decisions - this layer only reports whether a record exists.
"""

from __future__ import annotations

from typing import Any

from sitewise.services.ports.geospatial_repository_port import (
    GeospatialRepositoryPort,
)
from sitewise.services.ports.refresh_state_port import RefreshStatePort


class GeospatialService:
    def __init__(self, repo: GeospatialRepositoryPort, refresh: RefreshStatePort):
        self.repo = repo
        self.refresh = refresh

    def competitors(self, property_id: int) -> list[Any]:
        return self.repo.get_competitors_by_property_id(property_id)

    def geo_feature(self, property_id: int) -> Any | None:
        return self.repo.get_geo_feature_by_property_id(property_id)

    def foot_traffic(self, property_id: int) -> Any | None:
        return self.repo.get_foot_traffic_by_property_id(property_id)

    def districts(self, offset: int = 0, limit: int = 100) -> list[Any]:
        return self.repo.get_all_districts(offset, limit)

    def freshness(self, property_id: int) -> dict:
        """Additive freshness/provenance for one property's calculated features.

        Read-only by construction: nothing here triggers a recalculation, and an
        untrustworthy value is reported as ``available=false`` rather than zero.
        """
        return {
            "data": self.refresh.freshness_payload(property_id),
            "provenance": self.refresh.provenance_summary(),
        }
