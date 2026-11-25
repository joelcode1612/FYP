"""Entrepreneur Explore + location-analysis endpoints over the ``fyp`` schema.

Auth: every route requires a verified Supabase bearer (``CurrentUser``) —
the same dependency the catalogue uses. Authorization stays server-side; no
route trusts a client-supplied user id.

Transport only: each handler maps query parameters onto an
:class:`~sitewise.services.explore_service.ExploreService` call and turns the
service's own signals into status codes (``None`` → 404, ``ValueError`` → 422).
The row access, the payload shapes and the read-only guarantees live in that
service.

Gating: reads expose ONLY ``verification_status='approved' AND
is_published`` rows. Pending research imports (955 live) are never visible
here, and nothing in this module writes to the database.

Radius selection (500 m / 1 km) maps to the documented research radii and
the precomputed ``property_geospatial_features`` columns; the live
competitor/demand-generator lookups use the indexed PostGIS geometries.
"""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlmodel import Session

from sitewise.db.analytics_session import get_analytics_db
from sitewise.dependencies import CurrentUser, ExploreServiceImpl
from sitewise.ml.pu_expanded import expanded_display_scores

router = APIRouter()


@router.get("/options")
def explore_options(_user: CurrentUser, service: ExploreServiceImpl) -> dict:
    """Filter facets (states / cities / types / availability) + totals.

    Sourced from the database so a filter option can never silently match
    zero rows.
    """
    return service.options()


@router.get("/properties")
def explore_properties(
    _user: CurrentUser,
    service: ExploreServiceImpl,
    q: str | None = Query(default=None, max_length=120),
    state: str | None = Query(default=None, max_length=255),
    city: str | None = Query(default=None, max_length=120),
    property_type: str | None = Query(default=None, max_length=255),
    availability: str | None = Query(default=None, max_length=255),
    min_price: float | None = Query(default=None, ge=0),
    max_price: float | None = Query(default=None, ge=0),
    min_size: float | None = Query(default=None, ge=0),
    max_size: float | None = Query(default=None, ge=0),
    fnb_suitable: bool = False,
    sort: str = "newest",
    limit: int = Query(default=24, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    min_nearby_properties: int | None = Query(
        default=None,
        ge=1,
        le=500,
        description=(
            "Optional spatial filter: keep only listings with at least this "
            "many OTHER approved+published listings within nearby_radius_m. "
            "Omit to keep the unfiltered behaviour (backward compatible)."
        ),
    ),
    nearby_radius_m: int = Query(
        default=500,
        description="Geodesic radius in metres for the nearby-property "
        "count; must be one of (250, 500, 1000).",
    ),
) -> dict:
    """Map markers + listing cards: approved, published listings only.

    One query with lateral joins (no N+1). Competitor/population values are
    the precomputed research counts — ``null`` means "not calculated for
    this property", never 0. Map-marker consumers read ``latitude``/
    ``longitude`` (null coordinates are skipped client-side).

    When ``min_nearby_properties`` is supplied, each row additionally carries
    ``nearby_property_count`` — the real number of OTHER eligible listings
    within the radius, computed with PostGIS geodesic distance (never the
    F&B ``competitor_count_*`` research aggregates). Listings without usable
    coordinates cannot satisfy the spatial filter and are excluded.
    """
    params = {
        "q": q,
        "state": state,
        "city": city,
        "property_type": property_type,
        "availability": availability,
        "min_price": min_price,
        "max_price": max_price,
        "min_size": min_size,
        "max_size": max_size,
        "fnb_suitable": fnb_suitable,
        "sort": sort,
        "limit": limit,
        "offset": offset,
        "min_nearby_properties": min_nearby_properties,
        "nearby_radius_m": nearby_radius_m,
    }
    try:
        return service.list_published(params)
    except ValueError as exc:
        # Radius whitelist violations surface as 422, matching the
        # competitor/demand-generator endpoints.
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/properties/{property_id}")
def explore_property_detail(
    property_id: int, _user: CurrentUser, service: ExploreServiceImpl
) -> dict:
    """Detail payload: listing + photos + amenities + research linkage.

    404 covers both "does not exist" and "exists but not
    approved/published" — pending research rows are indistinguishable from
    absent ones to entrepreneurs, by design.
    """
    detail = service.detail(property_id)
    if detail is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "property_not_found",
                "message": "No published property with this id.",
            },
        )
    return detail


@router.get("/properties/{property_id}/competitors")
def explore_competitors(
    property_id: int,
    _user: CurrentUser,
    service: ExploreServiceImpl,
    radius_m: int = Query(default=500),
    limit: int = Query(default=50, ge=1, le=100),
    source: str = Query(
        default="osm",
        description="Competitor source: osm (default), overture, or merged.",
    ),
) -> dict:
    """Actual competitor outlets (name, category, distance) within radius.

    ``source=osm`` keeps the original behaviour (OpenStreetMap only).
    ``overture`` reads ``fnb_a.overture_places``; ``merged`` combines both and
    removes Overture rows already MATCHed to an OSM outlet, so a business is
    never listed twice. ``meta.counts`` reports the raw per-provider numbers
    next to the deduplicated merged count.
    """
    try:
        return service.competitors(
            property_id, radius_m=radius_m, limit=limit, source=source
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/properties/{property_id}/demand-generators")
def explore_demand_generators(
    property_id: int,
    _user: CurrentUser,
    service: ExploreServiceImpl,
    radius_m: int = Query(default=1000),
    limit: int = Query(default=50, ge=1, le=100),
) -> dict:
    """Demand generators (malls, transit, offices…) within radius."""
    try:
        return service.demand_generators(property_id, radius_m=radius_m, limit=limit)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/properties/{property_id}/population")
def explore_population(
    property_id: int, _user: CurrentUser, service: ExploreServiceImpl
) -> dict:
    """Population intelligence through the verified research linkage.

    ``available: false`` when the property has no verified subject link —
    the population table is keyed to research subjects, not properties.
    """
    return service.population(property_id)


@router.get("/properties/{property_id}/research-evidence")
def explore_research_evidence(
    property_id: int, _user: CurrentUser, service: ExploreServiceImpl
) -> dict:
    """Verified research linkage + PU feature record for one property.

    Feature/status fields only — the research dataset contains no verified
    success-probability score, and none is synthesised here.
    """
    return service.research_evidence(property_id)


@router.get("/analysis")
def explore_analysis(
    _user: CurrentUser,
    service: ExploreServiceImpl,
    analytics: Annotated[Session, Depends(get_analytics_db)],
    ref: str = Query(max_length=120),
) -> dict:
    """Cross-universe location analysis for one property reference.

    ``ref`` is either a ``fyp.rental_properties`` numeric id or a workbook
    catalogue id (``EP-xxxxx`` / ``MD-xxxxx``). Precomputed geospatial
    features are used when the row has them; otherwise competitor counts at
    500 m / 1 km are computed live from the indexed research geometry.
    Scores are labelled research indexes — never verified probabilities.

    ``location_measurements`` carries the measured surroundings from the
    existing Expanded64 enrichment pipeline. It is read-only and independent of
    the model: a measurement that was calculated is reported even when its
    definition is not approved as a model input, and an unavailable
    measurement never prevents the rest of the analysis from rendering.
    """
    from sitewise.services.expanded64_enrichment import informational_measurements

    def measurements(property_id: int, latitude: float, longitude: float) -> dict:
        return informational_measurements(analytics, property_id, latitude, longitude)

    result = service.analysis(
        ref,
        catalogue_score=lambda property_id: expanded_display_scores(
            analytics, [property_id]
        ).get(property_id),
        measurements=measurements,
    )
    if result is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "property_not_found",
                "message": f"No property matches reference '{ref}'.",
            },
        )
    return result
