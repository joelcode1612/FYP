"""Authenticated batch comparison of two or three shortlisted properties."""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator
from sqlmodel import Session

from sitewise.db.analytics_session import get_analytics_db
from sitewise.db.session import get_db
from sitewise.dependencies import CurrentUser
from sitewise.services.property_compare_service import PropertyCompareService

router = APIRouter()

AnalyticsSession = Annotated[Session, Depends(get_analytics_db)]
OperationalSession = Annotated[Session, Depends(get_db)]


class PropertyCompareRequest(BaseModel):
    """Catalogue ids selected from Recommendations (max three, no duplicates)."""

    property_ids: list[str] = Field(min_length=2, max_length=3)

    @field_validator("property_ids")
    @classmethod
    def _normalise(cls, values: list[str]) -> list[str]:
        cleaned = [value.strip() for value in values if value and value.strip()]
        if len(cleaned) != len(set(cleaned)):
            raise ValueError("A property cannot be compared with itself.")
        return cleaned


@router.post("")
def compare_properties(
    body: PropertyCompareRequest,
    _user: CurrentUser,
    analytics: AnalyticsSession,
    operational: OperationalSession,
) -> dict:
    """Return structured differences, not a second recommendation ranking.

    Targeted queries only: the three selected rows, their existing geospatial
    measurements, verified listing attributes and panorama status. Missing
    measurements are reported explicitly and never become zeros.
    """
    try:
        result = PropertyCompareService(analytics, operational).compare(
            body.property_ids
        )
    except ValueError as exc:
        raise HTTPException(
            status_code=422,
            detail={"code": "invalid_comparison", "message": str(exc)},
        ) from exc
    return {"data": result}
