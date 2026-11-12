"""Read-only catalogue of the imported research-property workbook.

The 955 normalised rows live in ``sitewise_app.properties`` in the analytics
database (``Final_Location_Analysis``). That table was previously reachable
only through the throwaway Express server in ``FYP/test`` (``/api/catalog/
properties``). This endpoint exposes the SAME dataset through the intended
FastAPI backend so the Jaspr frontend no longer needs the test folder at
runtime.

The row set is the 955 U-class commercial properties of
``SiteWise_PU_Property_Image_Scores_Merged``. The 894 P-class research rows in
``sitewise_analytics.subject_features`` are model input, NOT listings, and are
deliberately absent here. ``suitability_score`` is that workbook's uncalibrated
P-vs-U association index rescaled to 0-100 for ranking; ``source_data`` carries
the raw score plus ``score_type``. Neither is a business-success probability.

It is intentionally read-only and column-allow-listed: nothing here writes to
or alters the analytics/geospatial tables, and no scoring, recommendation or
property-analysis logic is duplicated.
"""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import get_analytics_db
from sitewise.db.session import get_db
from sitewise.dependencies import CurrentUser
from sitewise.repositories.catalog_repository import PROPERTY_COLUMNS, CatalogRepository
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
    total = int(session.execute(text("SELECT count(*) FROM sitewise_app.properties")).scalar_one())
    rows = (
        session.execute(
            text(
                f"SELECT {_SELECT_COLUMNS} FROM sitewise_app.properties "
                "ORDER BY id LIMIT :limit OFFSET :offset"
            ),
            {"limit": limit, "offset": offset},
        )
        .mappings()
        .all()
    )
    return {
        "data": [dict(row) for row in rows],
        "meta": {"total": total, "limit": limit, "offset": offset},
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
        "management": resolve_management(operational_session, catalogue_id=property_id),
    }


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
    * the score is a research association index, never a success probability.

    Computation is expensive (permutation SHAP over 47 features, ~13 s), so the
    service caches per ``(model_version, property_id)`` and the first request
    for a property pays the cost.
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
    return PropertyInsightsService(
        session=session, analytics_session=session
    ).insights(property_id, origin=origin)
