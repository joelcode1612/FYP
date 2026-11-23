"""Entrepreneur Explore use-cases over the ``fyp`` schema (read-only).

The route module used to build ``FypPropertyRepository`` and ``RefreshState`` in
each handler and to assemble the location-analysis payload inline. Both moved
here; every returned dictionary keeps the exact shape the endpoints already
send, including the ``available`` flags that distinguish "not calculated" from
zero.

Gating is unchanged and lives in the repository queries this service calls:
only ``verification_status='approved' AND is_published`` rows are visible, and
nothing in this module writes.

``management`` is injected rather than imported so this layer never holds a
session; the composition root binds it to
:func:`sitewise.services.property_management_service.resolve_management`.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from sitewise.services.ports.explore_repository_port import ExploreRepositoryPort
from sitewise.services.ports.refresh_state_port import RefreshStatePort


class ExploreService:
    def __init__(
        self,
        repo: ExploreRepositoryPort,
        refresh: RefreshStatePort,
        management: Callable[[int], Any],
    ):
        self.repo = repo
        self.refresh = refresh
        self.management = management

    def options(self) -> dict:
        """Filter facets (states / cities / types / availability) + totals."""
        return {"data": self.repo.filter_options()}

    def list_published(self, params: dict) -> dict:
        """Map markers + listing cards. ``ValueError`` = rejected radius."""
        return self.repo.list_published(params)

    def detail(self, property_id: int) -> dict | None:
        """Detail payload, or ``None`` when the listing is not publicly visible."""
        prop = self.repo.get_published(property_id)
        if prop is None:
            return None
        return {
            "data": {
                **prop,
                "photos": self.repo.get_photos(property_id),
                "amenities": self.repo.get_amenities(property_id),
                "listing_sources": self.repo.get_listing_sources(property_id),
                "management": self.management(property_id),
            }
        }

    def competitors(
        self, property_id: int, *, radius_m: int, limit: int, source: str
    ) -> dict:
        result = self.repo.list_competitors(
            property_id, radius_m=radius_m, limit=limit, source=source
        )
        coords = self.repo.property_coords(property_id)
        if coords is not None:
            result["meta"]["counts"] = self.repo.competitor_counts_by_source(
                coords[0], coords[1], radius_m=radius_m
            )
        return result

    def demand_generators(self, property_id: int, *, radius_m: int, limit: int) -> dict:
        return self.repo.list_demand_generators(
            property_id, radius_m=radius_m, limit=limit
        )

    def population(self, property_id: int) -> dict:
        """``available: false`` when there is no verified research linkage."""
        data = self.repo.get_population(property_id)
        return {"data": data, "meta": {"available": data is not None}}

    def research_evidence(self, property_id: int) -> dict:
        data = self.repo.get_research_evidence(property_id)
        return {"data": data, "meta": {"available": data is not None}}

    def analysis(
        self, ref: str, *, catalogue_score: Callable[[str], float | None] | None = None
    ) -> dict | None:
        """Cross-universe location analysis for one property reference.

        ``ref`` is either a ``fyp.rental_properties`` numeric id or a workbook
        catalogue id (``EP-xxxxx`` / ``MD-xxxxx``). Precomputed geospatial
        features are used when the row has them; otherwise competitor counts at
        500 m / 1 km are computed live from the indexed research geometry.
        ``None`` means nothing matches the reference.
        """
        resolved = self.repo.resolve_reference(ref)
        if resolved is None:
            return None
        geo = None
        research = None
        population = None
        pu_score = None
        fyp_id: int | None = None
        if resolved["source_schema"] == "fyp":
            fyp_id = int(resolved["property_id"])
            geo = self.repo.get_geo_features(fyp_id)
            research = self.repo.get_research_evidence(fyp_id)
            population = self.repo.get_population(fyp_id)
        elif catalogue_score is not None:
            pu_score = catalogue_score(str(resolved["property_id"]))

        counts: dict = {}
        lat = resolved.get("latitude")
        lon = resolved.get("longitude")
        if lat is not None and lon is not None and not (
            geo and geo.get("competitor_count_500m") is not None
        ):
            counts = self.repo.competitor_counts(float(lat), float(lon))

        return {
            "data": {
                "property_ref": ref,
                "source_schema": resolved["source_schema"],
                "name": resolved.get("name"),
                "property_type": resolved.get("property_type"),
                "address": resolved.get("address"),
                "city": resolved.get("city"),
                "state": resolved.get("state"),
                "latitude": lat,
                "longitude": lon,
                "rental_price": (
                    float(resolved["rental_price"])
                    if resolved.get("rental_price") is not None
                    else None
                ),
                "size_sqft": (
                    float(resolved["size_sqft"])
                    if resolved.get("size_sqft") is not None
                    else None
                ),
                "catalog_suitability_score": pu_score,
                "geospatial_features": geo,
                "competitor_counts": counts,
                "research_link": research,
                "population": population,
                # Additive freshness/provenance block. Read-only; an unknown
                # state is explicit ("unavailable"), never a zero.
                "freshness": self.refresh.freshness_payload(fyp_id),
                "provenance": self.refresh.provenance_summary(),
            },
            "meta": {
                "available": bool(
                    geo or counts or research or pu_score is not None
                ),
            },
        }
