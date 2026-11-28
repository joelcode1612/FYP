"""Row-access contract for the Explore read model.

Only the methods the Explore endpoints actually use are declared, and with the
adapter's own parameter defaults, so ``FypPropertyRepository`` satisfies it
implicitly (it is a superset) while the service stays testable with an
in-memory fake. ``property_coords`` is the public form of the repository's
private coordinate lookup — the route layer used to call ``repo._coords(...)``
straight from a handler.
"""

from __future__ import annotations

from typing import Any, Protocol


class ExploreRepositoryPort(Protocol):
    def filter_options(self) -> dict: ...

    def list_published(self, params: dict[str, Any]) -> dict: ...

    def get_published(self, property_id: int) -> dict | None: ...

    def get_photos(self, property_id: int) -> list[dict]: ...

    def get_amenities(self, property_id: int) -> dict | None: ...

    def get_listing_sources(self, property_id: int) -> list[dict]: ...

    def list_competitors(
        self,
        property_id: int,
        radius_m: int = 500,
        limit: int = 50,
        source: str = "osm",
    ) -> dict: ...

    def property_coords(self, property_id: int) -> tuple[float, float] | None: ...

    def competitor_counts_by_source(
        self, lat: float, lon: float, radius_m: int = 500
    ) -> dict: ...

    def list_demand_generators(
        self, property_id: int, radius_m: int = 1000, limit: int = 50
    ) -> dict: ...

    def get_population(self, property_id: int) -> dict | None: ...

    def get_research_evidence(self, property_id: int) -> dict | None: ...

    def resolve_reference(
        self, ref: str, *, include_unpublished: bool = False
    ) -> dict | None: ...

    def get_geo_features(self, property_id: int) -> dict | None: ...

    def competitor_counts(self, lat: float, lon: float) -> dict: ...
