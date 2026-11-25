"""Read-only catalogue of the imported research-property workbook.

The 955 normalised rows are canonical property data in
``fyp.rental_properties`` (research attributes in the ``catalogue_*``
columns), exposed through the ``fyp.catalogue_properties`` view that
preserves the original response contract. The dataset was previously
reachable only through the throwaway Express server in ``FYP/test``
(``/api/catalog/properties``). This endpoint exposes the SAME dataset
through the intended FastAPI backend so the Jaspr frontend no longer needs
the test folder at runtime.

The row set is the 955 U-class commercial properties of
``SiteWise_PU_Property_Image_Scores_Merged``. The 894 P-class research rows in
``fyp.property_inference_features`` are model input, NOT listings, and are
deliberately absent here. ``suitability_score`` is the expanded64 association
index on a 0-100 scale, or null when inference is unavailable.

It is intentionally read-only and column-allow-listed: nothing here writes to
or alters the analytics/geospatial tables. Display scores reuse the same
expanded inference as Recommendations.
"""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import get_analytics_db
from sitewise.db.session import get_db
from sitewise.dependencies import CurrentUser
from sitewise.ingestion.sources.gtfs_importer import is_transit_stale
from sitewise.ml.pu_expanded import expanded_display_scores
from sitewise.repositories.catalog_repository import PROPERTY_COLUMNS, CatalogRepository
from sitewise.repositories.fyp_property_repository import FypPropertyRepository
from sitewise.services.catalog_listing_details_service import CatalogListingDetailsService
from sitewise.services.business_concept_service import BusinessConceptService
from sitewise.services.nearby_places_service import NearbyPlacesService
from sitewise.services.property_insights_service import PropertyInsightsService
from sitewise.services.property_management_service import resolve_management

router = APIRouter()

# Exact column order consumed by lib/data/api_property_repository.dart.
_SELECT_COLUMNS = ", ".join(PROPERTY_COLUMNS)

AnalyticsSession = Annotated[Session, Depends(get_analytics_db)]


@router.get("/properties")
def list_catalog_properties(
    session: AnalyticsSession,
    _user: CurrentUser,
    limit: int = Query(default=200, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> dict:
    """Paginated, authenticated read of the imported property catalogue.

    Mirrors the old ``/api/catalog/properties`` response shape
    (``{data: [...], meta: {total, limit, offset}}``) so the shared Dart
    repository keeps working unchanged. The bearer token is verified by the
    same ``CurrentUser`` dependency used by every other protected endpoint.
    """
    total = int(session.execute(text("SELECT count(*) FROM fyp.catalogue_properties")).scalar_one())
    rows = (
        session.execute(
            text(
                f"SELECT {_SELECT_COLUMNS} FROM fyp.catalogue_properties "
                "ORDER BY id LIMIT :limit OFFSET :offset"
            ),
            {"limit": limit, "offset": offset},
        )
        .mappings()
        .all()
    )
    scores = expanded_display_scores(session, [str(row["id"]) for row in rows])
    return {
        "data": [{**row, "suitability_score": scores.get(str(row["id"]))} for row in rows],
        "meta": {"total": total, "limit": limit, "offset": offset},
    }


@router.get("/properties/count")
def catalogue_count(session: AnalyticsSession, _user: CurrentUser) -> dict:
    total = session.execute(text("SELECT count(*) FROM fyp.catalogue_properties")).scalar_one()
    return {"meta": {"total": int(total)}}


@router.get("/properties/by-ids")
def catalogue_by_ids(
    session: AnalyticsSession, _user: CurrentUser,
    ids: Annotated[list[str], Query(min_length=1, max_length=200)],
) -> dict:
    rows = CatalogRepository(session).get_properties(list(dict.fromkeys(ids)))
    scores = expanded_display_scores(session, list(rows))
    return {
        "data": [{**row, "suitability_score": scores.get(ref)} for ref, row in rows.items()]
    }


@router.get("/property-types")
def list_catalog_property_types(session: AnalyticsSession, _user: CurrentUser) -> dict:
    """The distinct ``property_type`` values the eligibility filter can match.

    Read from the catalogue rather than hardcoded in the frontend, so the
    business-requirements form can never offer an option that silently filters
    every listing out.
    """
    types = CatalogRepository(session).get_property_types()
    return {"data": types, "meta": {"total": len(types)}}


@router.get("/properties/{property_id}")
def get_catalog_property(
    property_id: str,
    session: AnalyticsSession,
    _user: CurrentUser,
    operational_session: Session = Depends(get_db),
) -> dict:
    """One catalogue listing by its text id (e.g. ``EP-01051``).

    The workspace needs a single-record read that distinguishes "this id does
    not exist" (404) from "the list happened to be paginated past it".

    ``photos`` is the full ``fyp.property_photos`` set for this catalogue row,
    resolved through the verified subject link (primary first). The single
    ``image_url`` column stays in the payload as the documented fallback for
    properties with no photo records; the two are never merged into one list.
    """
    prop = CatalogRepository(session).get_property(property_id)
    if prop is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "property_not_found",
                "message": f"No property with id '{property_id}' exists in the catalogue.",
            },
        )
    return {
        **prop,
        "suitability_score": expanded_display_scores(session, [property_id]).get(property_id),
        # Additive commercial-listing details, sourced from the recorded
        # research subject features and — only for a verified, approved AND
        # published match — the operational listing row. Unknown fields stay
        # null; nothing is inferred or defaulted.
        "listing_details": CatalogListingDetailsService(
            analytics_session=session,
            operational_session=operational_session,
        ).get_details(property_id),
        "management": resolve_management(operational_session, catalogue_id=property_id),
        # All photographs of THIS property only. The catalogue id is resolved
        # to the numeric fyp.property_photos.property_id inside the repository;
        # an empty list is a real "no photo records" state, not an error.
        "photos": FypPropertyRepository(operational_session).get_catalogue_photos(property_id),
    }


@router.get("/properties/{property_id}/nearby-places")
def get_catalog_nearby_places(
    property_id: str,
    session: AnalyticsSession,
    _user: CurrentUser,
    radius_m: int = Query(default=1000, ge=100, le=3000),
) -> dict:
    """Individual verified locations around one listing, for the map's markers.

    The insights endpoint reports how many competitors, nearby places, transit
    stops and parking facilities fall inside each radius; this endpoint
    returns the locations those totals describe, each with a stable id, its
    category and subtype, its coordinate, its source, its operating status
    where the source records one, the straight-line distance from the
    catalogue's own coordinate and the date the record was observed. Five
    categories are served from their real tables: the research catalogue's
    other properties, F&B outlets, demand-generating POIs, GTFS stops (with
    each stop's distinct routes and its published scheduled departures —
    never live arrivals) and parking facilities. A missing listing is 404; a
    listing without usable coordinates is 200 with honest zero counts, never
    fabricated places.

    Every category carries an explicit ``state`` — ``mapped``,
    ``measured_zero``, ``source_unavailable`` or ``data_stale`` (accessibility
    only, when every official GTFS feed on this host is past the freshness
    SLA; markers still come back) — so a failed source is never converted
    into a zero, and one source failing never removes the others.
    The response's ``distance_method`` names the straight-line spherical
    computation shared with the score.

    The radius-based aggregate statistics stay owned by the insights payload —
    nothing here changes them. Recorded totals and mapped locations can
    legitimately differ (deduplication, operating-status gates, coordinate
    validation), and the map shows both rather than forcing one onto the other.
    Large catchments are capped per category at the nearest 800 locations and
    say so via ``truncated``.
    """
    row = CatalogRepository(session).get_property(property_id)
    if row is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "property_not_found",
                "message": f"No property with id '{property_id}' exists in the catalogue.",
            },
        )
    # The same coordinate the insights score describes: markers and score must
    # never disagree about where the property is.
    lat, lon = row.get("latitude"), row.get("longitude")
    origin = {"lat": float(lat), "lon": float(lon)} if lat is not None and lon is not None else None
    # Feed freshness is decided by the importer's status file (missing or
    # unreadable -> False/unknown), so a corrupt status never fakes staleness.
    result = NearbyPlacesService(session).nearby(
        origin["lat"] if origin else None,
        origin["lon"] if origin else None,
        radius_m,
        exclude_property_id=property_id,
        transit_stale=is_transit_stale(),
    )
    return {"property_id": property_id, "origin": origin, **result}


@router.get("/properties/{property_id}/evidence")
def get_catalog_evidence(
    property_id: str,
    session: AnalyticsSession,
    _user: CurrentUser,
) -> dict:
    """Analysed location evidence for one listing.

    A missing listing is 404. A listing that exists but has no analysis row is
    200 with ``available: false`` and a reason, so the workspace can show an
    honest "evidence unavailable" stage instead of an error or a fake zero.
    """
    repo = CatalogRepository(session)
    if repo.get_property(property_id) is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "property_not_found",
                "message": f"No property with id '{property_id}' exists in the catalogue.",
            },
        )
    return repo.get_evidence(property_id)


@router.get("/properties/{property_id}/insights")
def get_catalog_insights(
    property_id: str,
    session: AnalyticsSession,
    _user: CurrentUser,
    operational_session: Session = Depends(get_db),
    business_type: str | None = Query(
        default=None,
        max_length=120,
        description=(
            "The entrepreneur's stated F&B business type, kept for "
            "backward compatibility. It is recorded with the response and "
            "never changes the general PU association score or its SHAP "
            "explanation."
        ),
    ),
) -> dict:
    """Location score plus genuine SHAP factors for one listing.

    This is the read model behind the Property Detail page's "Location Fit" and
    "Why this score?" sections. It answers with the *deployed* model's own
    output and its permutation-SHAP decomposition over the property's resolved
    47-feature vector.

    Contract:

    * a missing listing is 404;
    * everything else is 200 — an unscoreable property returns
      ``score.available: false`` with a stable ``reason.code`` rather than an
      error, so the page can show an honest empty state;
    * score and explanation availability are independent: a valid stored or
      live PU score remains visible when features/background/SHAP do not permit
      an explanation;
    * ``explanation.factors`` always carries plain-English labels; the raw
      feature key is present only as ``technical`` for audit;
    * ``business_type`` is recorded as the entrepreneur's stated selection; it
      selects no model output;
    * the score is a research association index, never a success probability.

    Computation is expensive (permutation SHAP over 47 or 64 features), so the
    service caches per ``(model version, artifact checksum, resolved feature
    vector, stated business type)`` and the first request for a property pays
    the cost.
    """
    row = CatalogRepository(session).get_property(property_id)
    if row is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "property_not_found",
                "message": f"No property with id '{property_id}' exists in the catalogue.",
            },
        )
    # Echo the catalogue's own coordinate so the map and the score describe the
    # same point; the page must not re-derive a location for itself.
    origin = None
    lat, lon = row.get("latitude"), row.get("longitude")
    if lat is not None and lon is not None:
        origin = {"lat": float(lat), "lon": float(lon)}
    # The operational session enables the persistent validated-explanation
    # cache: a precomputed explanation is served immediately, and a miss never
    # blocks this request on SHAP (it returns the real PU score with a
    # truthful pending state and schedules the background computation).
    return PropertyInsightsService(
        session=session,
        analytics_session=session,
        cache_session=operational_session,
    ).insights(property_id, origin=origin, business_type=business_type)

@router.get("/properties/{property_id}/business-concepts")
def get_property_business_concepts(
    property_id: str,
    session: AnalyticsSession,
    _user: CurrentUser,
    operational_session: Session = Depends(get_db),
    monthly_budget_myr: float | None = Query(default=None, gt=0, le=1_000_000),
) -> dict:
    """Experimental five-concept assessment; no writes and no success claims.

    Reuses expanded64 general PU context and the existing four-class research
    model WITHOUT folding either score into the concept compatibility index.
    A numeric rental ID is accepted only when a verified catalogue link exists.
    """
    try:
        return BusinessConceptService(session, operational_session).assess(
            property_id, monthly_budget_myr=monthly_budget_myr
        )
    except LookupError as exc:
        raise HTTPException(status_code=404, detail={
            "code": "property_not_found_or_unlinked", "message": str(exc)
        }) from exc
