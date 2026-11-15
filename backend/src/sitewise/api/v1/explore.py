"""Entrepreneur Explore + location-analysis endpoints over the ``fyp`` schema.

Auth: every route requires a verified Supabase bearer (``CurrentUser``) —
the same dependency the catalogue uses. Authorization stays server-side; no
route trusts a client-supplied user id.

Gating: reads expose ONLY ``verification_status='approved' AND
is_published`` rows. Pending research imports (955 live) are never visible
here, and nothing in this module writes to the database.

Radius selection (500 m / 1 km) maps to the documented research radii and
the precomputed ``property_geospatial_features`` columns; the live
competitor/demand-generator lookups use the indexed PostGIS geometries.
"""

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlmodel import Session

from sitewise.db.session import get_db
from sitewise.dependencies import CurrentUser
from sitewise.ingestion.state import RefreshState
from sitewise.repositories.fyp_property_repository import FypPropertyRepository
from sitewise.services.property_management_service import resolve_management

router = APIRouter()

DbSession = Depends(get_db)


@router.get("/options")
def explore_options(_user: CurrentUser, session=DbSession) -> dict:
    """Filter facets (states / cities / types / availability) + totals.

    Sourced from the database so a filter option can never silently match
    zero rows.
    """
    return {"data": FypPropertyRepository(session).filter_options()}


@router.get("/properties")
def explore_properties(
    _user: CurrentUser,
    session=DbSession,
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
        return FypPropertyRepository(session).list_published(params)
    except ValueError as exc:
        # Radius whitelist violations surface as 422, matching the
        # competitor/demand-generator endpoints.
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/properties/{property_id}")
def explore_property_detail(
    property_id: int, _user: CurrentUser, session=DbSession
) -> dict:
    """Detail payload: listing + photos + amenities + research linkage.

    404 covers both "does not exist" and "exists but not
    approved/published" — pending research rows are indistinguishable from
    absent ones to entrepreneurs, by design.
    """
    repo = FypPropertyRepository(session)
    prop = repo.get_published(property_id)
    if prop is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "property_not_found",
                "message": "No published property with this id.",
            },
        )
    return {
        "data": {
            **prop,
            "photos": repo.get_photos(property_id),
            "amenities": repo.get_amenities(property_id),
            "listing_sources": repo.get_listing_sources(property_id),
            "management": resolve_management(session, listing_id=property_id),
        }
    }


@router.get("/properties/{property_id}/competitors")
def explore_competitors(
    property_id: int,
    _user: CurrentUser,
    session=DbSession,
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
    repo = FypPropertyRepository(session)
    try:
        result = repo.list_competitors(
            property_id, radius_m=radius_m, limit=limit, source=source
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    coords = repo._coords(property_id)
    if coords is not None:
        result["meta"]["counts"] = repo.competitor_counts_by_source(
            coords[0], coords[1], radius_m=radius_m
        )
    return result


@router.get("/properties/{property_id}/demand-generators")
def explore_demand_generators(
    property_id: int,
    _user: CurrentUser,
    session=DbSession,
    radius_m: int = Query(default=1000),
    limit: int = Query(default=50, ge=1, le=100),
) -> dict:
    """Demand generators (malls, transit, offices…) within radius."""
    try:
        return FypPropertyRepository(session).list_demand_generators(
            property_id, radius_m=radius_m, limit=limit
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/properties/{property_id}/population")
def explore_population(property_id: int, _user: CurrentUser, session=DbSession) -> dict:
    """Population intelligence through the verified research linkage.

    ``available: false`` when the property has no verified subject link —
    the population table is keyed to research subjects, not properties.
    """
    data = FypPropertyRepository(session).get_population(property_id)
    return {"data": data, "meta": {"available": data is not None}}


@router.get("/properties/{property_id}/research-evidence")
def explore_research_evidence(
    property_id: int, _user: CurrentUser, session=DbSession
) -> dict:
    """Verified research linkage + PU feature record for one property.

    Feature/status fields only — the research dataset contains no verified
    success-probability score, and none is synthesised here.
    """
    data = FypPropertyRepository(session).get_research_evidence(property_id)
    return {"data": data, "meta": {"available": data is not None}}


@router.get("/analysis")
def explore_analysis(
    _user: CurrentUser,
    session=DbSession,
    ref: str = Query(max_length=120),
) -> dict:
    """Cross-universe location analysis for one property reference.

    ``ref`` is either a ``fyp.rental_properties`` numeric id or a workbook
    catalogue id (``EP-xxxxx`` / ``MD-xxxxx``). Precomputed geospatial
    features are used when the row has them; otherwise competitor counts at
    500 m / 1 km are computed live from the indexed research geometry.
    Scores are labelled research indexes — never verified probabilities.
    """
    repo = FypPropertyRepository(session)
    resolved = repo.resolve_reference(ref)
    if resolved is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "property_not_found",
                "message": f"No property matches reference '{ref}'.",
            },
        )
    geo = None
    research = None
    population = None
    fyp_id: int | None = None
    if resolved["source_schema"] == "fyp":
        fyp_id = int(resolved["property_id"])
        geo = repo.get_geo_features(fyp_id)
        research = repo.get_research_evidence(fyp_id)
        population = repo.get_population(fyp_id)

    counts: dict = {}
    lat = resolved.get("latitude")
    lon = resolved.get("longitude")
    if lat is not None and lon is not None and not (
        geo and geo.get("competitor_count_500m") is not None
    ):
        counts = repo.competitor_counts(float(lat), float(lon))

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
            # Workbook/catalogue suitability index (research ranking input —
            # NOT a verified success probability).
            "catalog_suitability_score": resolved.get("suitability_score"),
            "geospatial_features": geo,
            "competitor_counts": counts,
            "research_link": research,
            "population": population,
            # Additive freshness/provenance block. Read-only; an unknown
            # state is explicit ("unavailable"), never a zero.
            "freshness": RefreshState(session).freshness_payload(fyp_id),
            "provenance": RefreshState(session).provenance_summary(),
        },
        "meta": {
            "available": bool(
                geo or counts or research or resolved.get("suitability_score")
            ),
        },
    }
