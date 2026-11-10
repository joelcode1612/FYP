"""Read-only property report assembly over the ``fyp`` operational schema.

The report joins what the application can actually verify for one
APPROVED + PUBLISHED property: the listing itself, its stored photos and
listing sources, its precomputed geospatial features, and — through the
verified research subject link — the PU feature record and population
intelligence. Every section that has no backing data is reported as
explicitly ``available: false`` with a reason: nothing is fabricated, and
research feature values are never presented as success probabilities.

Pending, unpublished, rejected, or unknown-availability rows are reported
as 404 to consumers (same gating as the Explore endpoints). Catalogue
workbook references (``EP-xxxxx``) are also accepted.
"""

from fastapi import HTTPException
from sqlmodel import Session

from sitewise.repositories.fyp_property_repository import FypPropertyRepository


def _section(data, available: bool, reason: str) -> dict:
    if available:
        return {"available": True, "data": data}
    return {"available": False, "reason": reason}


class ReportService:
    def __init__(self, session: Session):
        self.session = session

    def generate_property_report(self, property_id: int | str) -> dict:
        ref = str(property_id)
        repo = FypPropertyRepository(self.session)

        resolved = repo.resolve_reference(ref)
        if resolved is None:
            raise HTTPException(
                status_code=404,
                detail=f"No published property matches reference '{ref}'.",
            )

        geo = None
        photos: list[dict] = []
        sources: list[dict] = []
        research = None
        population = None
        if resolved["source_schema"] == "fyp":
            fyp_id = int(resolved["property_id"])
            geo = repo.get_geo_features(fyp_id)
            photos = repo.get_photos(fyp_id)
            sources = repo.get_listing_sources(fyp_id)
            research = repo.get_research_evidence(fyp_id)
            population = repo.get_population(fyp_id)

        coords_present = (
            resolved.get("latitude") is not None
            and resolved.get("longitude") is not None
        )
        precomputed_counts = bool(geo and geo.get("competitor_count_500m") is not None)
        live_counts: dict = {}
        if coords_present and not precomputed_counts:
            live_counts = repo.competitor_counts(
                float(resolved["latitude"]), float(resolved["longitude"])
            )

        return {
            "property": {
                "property_id": resolved["property_id"],
                "source_schema": resolved["source_schema"],
                "name": resolved.get("name"),
                "property_type": resolved.get("property_type"),
                "address": resolved.get("address"),
                "city": resolved.get("city"),
                "state": resolved.get("state"),
                "latitude": resolved.get("latitude"),
                "longitude": resolved.get("longitude"),
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
            },
            "listing_media": _section(
                {"photos": photos, "listing_sources": sources},
                bool(photos or sources),
                "No photos or listing sources are stored for this property.",
            ),
            "geospatial_features": _section(
                geo,
                geo is not None,
                "No precomputed geospatial features exist for this property.",
            ),
            "live_competitor_counts": _section(
                live_counts,
                bool(live_counts) and coords_present,
                (
                    "Precomputed geospatial features already cover this "
                    "property; live counts were not recomputed."
                    if precomputed_counts
                    else "Property coordinates are unavailable; live "
                    "competitor counts cannot be computed."
                ),
            ),
            "research_link": _section(
                research,
                research is not None,
                "This property has no verified research subject link (the "
                "verified-link set covers the unlabeled research candidates).",
            ),
            "population_intelligence": _section(
                population,
                population is not None,
                "Population intelligence resolves through the verified "
                "research subject link; none exists for this property.",
            ),
            "meta": {
                # Honest labeling: all research figures here are dataset
                # features/counts, never verified success probabilities.
                "scores_are_research_indexes": True,
            },
        }
