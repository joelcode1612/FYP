import uuid

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, model_validator
from sqlmodel import Session, select

from sitewise.db.analytics_session import get_analytics_db
from sitewise.db.models.recommendation_result import RecommendationResult
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, CurrentUser, get_active_user, require_admin_mfa
from sitewise.domain import rbac
from sitewise.services.recommendation_search_service import (
    RecommendationSearchService,
    SearchCriteria,
)
from sitewise.services.recommendation_service import RecommendationService

router = APIRouter()


class RecommendationSearchRequest(BaseModel):
    """Entrepreneur requirements for one recommendation search.

    Mirrors ``BusinessPreferences`` plus the layout preferences the workspace
    collects. Every field is optional: a request with no criteria is a plain
    browse of the catalogue, which is what an entrepreneur without saved
    preferences must still get.
    """

    business_type: str | None = Field(default=None, max_length=120)
    preferred_state: str | None = Field(default=None, max_length=120)
    preferred_area: str | None = Field(default=None, max_length=120)
    min_rental_rm: float | None = Field(default=None, ge=0, le=10_000_000)
    max_rental_rm: float | None = Field(default=None, ge=0, le=10_000_000)
    min_size_sqft: float | None = Field(default=None, ge=0, le=1_000_000)
    max_size_sqft: float | None = Field(default=None, ge=0, le=1_000_000)
    property_type: str | None = Field(default=None, max_length=120)
    layout_preferences: list[str] = Field(default_factory=list, max_length=12)
    query: str | None = Field(default=None, max_length=120)
    page_size: int = Field(default=20, ge=1, le=60)
    cursor: str | None = Field(default=None, max_length=512)

    @model_validator(mode="after")
    def _check_ranges(self) -> "RecommendationSearchRequest":
        if (
            self.min_rental_rm is not None
            and self.max_rental_rm is not None
            and self.min_rental_rm > self.max_rental_rm
        ):
            raise ValueError("Minimum rental cannot exceed the maximum rental.")
        if (
            self.min_size_sqft is not None
            and self.max_size_sqft is not None
            and self.min_size_sqft > self.max_size_sqft
        ):
            raise ValueError("Minimum floor area cannot exceed the maximum.")
        return self


@router.post("/search")
def search_recommendations(
    body: RecommendationSearchRequest,
    _user: CurrentUser,
    session: Session = Depends(get_analytics_db),
) -> dict:
    """Rank catalogue properties against the caller's requirements.

    Read-only. Filtering, requirement evaluation, ordering and pagination all
    happen server-side over the complete eligible set, so page 2 is always
    consistent with page 1 and neither client ever sorts the catalogue.

    ``model.available`` is ``false`` in this build: the trained artifact is not
    integrated, so ``recommendation.score`` is null and the ordering is the
    documented requirement-fit ordering. No score is fabricated.
    """
    criteria = SearchCriteria(
        business_type=body.business_type,
        preferred_state=body.preferred_state,
        preferred_area=body.preferred_area,
        min_rental_rm=body.min_rental_rm,
        max_rental_rm=body.max_rental_rm,
        min_size_sqft=body.min_size_sqft,
        max_size_sqft=body.max_size_sqft,
        property_type=body.property_type,
        layout_preferences=tuple(body.layout_preferences),
        query=body.query,
        page_size=body.page_size,
        cursor=body.cursor,
    )
    try:
        return RecommendationSearchService(session).search(criteria)
    except ValueError as exc:
        # Cursor from another search / malformed cursor: the client must
        # restart from page 1 rather than page through the wrong ranking.
        raise HTTPException(
            status_code=422,
            detail={"code": "invalid_cursor", "message": str(exc)},
        ) from exc


@router.get("/facets")
def recommendation_facets(
    _user: CurrentUser,
    session: Session = Depends(get_analytics_db),
) -> dict:
    """Filter vocabulary and numeric ranges read from the catalogue itself."""
    return {"data": RecommendationSearchService(session).facets()}



@router.get("/")
def list_recommendations(
    offset: int = 0,
    limit: int = 100,
    session: Session = Depends(get_db),
    _: AuthenticatedUser = Depends(require_admin_mfa),
):
    """Administrative overview of all stored recommendation results."""
    return RecommendationService(session).list_results(offset, limit)


@router.get("/me")
def list_own_recommendations(
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(get_active_user),
):
    """The authenticated user's own recommendation history."""
    return RecommendationService(session).get_by_user(current.user_id)


@router.get("/user/{user_id}")
def get_recommendations_by_user(
    user_id: uuid.UUID,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(get_active_user),
):
    """Ownership-scoped read: own history, or any history for administrators."""
    if user_id != current.user_id and not rbac.can_read_any_user_data(current.role):
        raise HTTPException(
            status_code=403, detail="You can only view your own recommendation history."
        )
    return RecommendationService(session).get_by_user(user_id)


@router.post("/", status_code=201)
def create_recommendation(
    result: RecommendationResult,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(get_active_user),
):
    """Store a recommendation result owned by the authenticated identity."""
    result.user_id = current.user_id
    return RecommendationService(session).create_result(result)


@router.delete("/{result_id}", status_code=204)
def delete_recommendation(
    result_id: uuid.UUID,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(get_active_user),
):
    existing = session.exec(
        select(RecommendationResult).where(
            RecommendationResult.result_id == result_id
        )
    ).first()
    if existing is None:
        raise HTTPException(status_code=404, detail="Recommendation not found")
    if existing.user_id != current.user_id and not rbac.can_read_any_user_data(current.role):
        raise HTTPException(
            status_code=403, detail="You can only delete your own recommendation results."
        )
    RecommendationService(session).delete_result(result_id)
    return None
