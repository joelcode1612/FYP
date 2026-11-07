"""Read-only catalogue of the imported F&B property workbook.

The 2,126 normalised rows live in ``sitewise_app.properties`` in the analytics
database (``Final_Location_Analysis``). That table was previously reachable
only through the throwaway Express server in ``FYP/test`` (``/api/catalog/
properties``). This endpoint exposes the SAME dataset through the intended
FastAPI backend so the Jaspr frontend no longer needs the test folder at
runtime.

It is intentionally read-only and column-allow-listed: nothing here writes to
or alters the analytics/geospatial tables, and no scoring, recommendation or
property-analysis logic is duplicated.
"""

from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import get_analytics_db
from sitewise.dependencies import CurrentUser

router = APIRouter()

# Exact column order consumed by lib/data/api_property_repository.dart.
_COLUMNS = (
    "id",
    "title",
    "address",
    "city",
    "state",
    "postcode",
    "rental_rm",
    "size_sqft",
    "latitude",
    "longitude",
    "property_type",
    "image_url",
    "source_url",
    "suitability_score",
    "dataset_validation",
)
_SELECT_COLUMNS = ", ".join(_COLUMNS)

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
    total = int(
        session.execute(
            text("SELECT count(*) FROM sitewise_app.properties")
        ).scalar_one()
    )
    rows = session.execute(
        text(
            f"SELECT {_SELECT_COLUMNS} FROM sitewise_app.properties "
            "ORDER BY id LIMIT :limit OFFSET :offset"
        ),
        {"limit": limit, "offset": offset},
    ).mappings().all()
    return {
        "data": [dict(row) for row in rows],
        "meta": {"total": total, "limit": limit, "offset": offset},
    }
