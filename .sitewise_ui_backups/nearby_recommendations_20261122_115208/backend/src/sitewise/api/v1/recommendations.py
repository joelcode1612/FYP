import uuid
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field, model_validator
from sqlmodel import Session

from sitewise.db.analytics_session import get_analytics_db
from sitewise.db.models.recommendation_result import RecommendationResult
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, CurrentUser, get_active_user, require_admin_mfa
from sitewise.domain import rbac
from sitewise.services.property_insights_service import (
    PANORAMA_UNAVAILABLE,
    panoramas_by_catalogue_ids,
    photo_urls_by_catalogue_ids,
)
from sitewise.services.recommendation_search_service import (
    SORT_BEST_MATCH,
    RecommendationSearchService,
    SearchCriteria,
)
from sitewise.services.recommendation_service import RecommendationService
from sitewise.services.recommendation_management_service import (
    ManagementLookupError, RecommendationManagementService, unavailable_management,
)

router = APIRouter()

#: The accepted orderings. Declared as a Literal so an unsupported value is a
#: 422 from Pydantic rather than a silently unsorted list.
SortKey = Literal[
    "best_match",
    "rent_asc",
    "rent_desc",
    "size_desc",
    "size_asc",
    "pu_desc",
]


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
    # City / District is the address prefix; the research catalogue's own
    # city column is empty. Advanced fields are applied only when a verified
    # measurement exists — NULL never matches a selection.
    city: str | None = Field(default=None, max_length=120)
    location_latitude: float | None = Field(default=None, ge=-90, le=90, allow_inf_nan=False)
    location_longitude: float | None = Field(default=None, ge=-180, le=180, allow_inf_nan=False)
    nearby_radius_km: float | None = Field(default=None, ge=0.5, le=100, allow_inf_nan=False)
    floor_level: str | None = Field(default=None, max_length=80)
    transit_max_m: float | None = Field(default=None, ge=0, le=100_000)
    nearby_parking_min: float | None = Field(default=None, ge=0, le=10_000)
    fnb_competition_max: float | None = Field(default=None, ge=0, le=100_000)
    demand_generator: str | None = Field(default=None, max_length=40)
    population_min_1000m: float | None = Field(default=None, ge=0, le=10_000_000)
    population_max_1000m: float | None = Field(default=None, ge=0, le=10_000_000)
    layout_preferences: list[str] = Field(default_factory=list, max_length=12)
    query: str | None = Field(default=None, max_length=120)
    managed_only: bool = False
    page_size: int = Field(default=20, ge=1, le=60)
    cursor: str | None = Field(default=None, max_length=512)
    sort: SortKey = Field(
        default=SORT_BEST_MATCH,
        description=(
            "Ordering of the eligible set. Never changes which properties "
            "qualify — only their sequence."
        ),
    )

    @model_validator(mode="after")
    def _check_ranges(self) -> "RecommendationSearchRequest":
        if any(value is not None for value in (
            self.location_latitude, self.location_longitude, self.nearby_radius_km
        )) and not all(value is not None for value in (
            self.location_latitude, self.location_longitude, self.nearby_radius_km
        )):
            raise ValueError("Location latitude, longitude, and radius must be provided together.")
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
        if (
            self.population_min_1000m is not None
            and self.population_max_1000m is not None
            and self.population_min_1000m > self.population_max_1000m
        ):
            raise ValueError("Minimum population cannot exceed the maximum.")
        return self


@router.post("/search")
def search_recommendations(
    body: RecommendationSearchRequest,
    _user: CurrentUser,
    session: Session = Depends(get_analytics_db),
    operational_db: Session = Depends(get_db),
) -> dict:
    """Rank catalogue properties against the caller's requirements.

    Read-only. Filtering, requirement evaluation, ordering and pagination all
    happen server-side over the complete eligible set, so page 2 is always
    consistent with page 1 and neither client ever sorts the catalogue.

    ``model.available`` is ``false`` in this build: the trained artifact is not
    integrated, so ``recommendation.score`` is null and the ordering is the
    documented requirement-fit ordering. No score is fabricated.

    Each page is batch-enriched with display media: ``photos`` (URL list, the
    verified catalogue-photo chain) and ``panorama`` (the same honest
    ``ready``/``processing``/``unavailable`` payload as the insights endpoint).
    Both resolve in ONE query per page — never per card — and media failures
    degrade to empty media instead of failing the search.
    """
    management = RecommendationManagementService(operational_db)
    try:
        assigned_ids = management.assigned_catalogue_ids() if body.managed_only else ()
    except ManagementLookupError as exc:
        raise HTTPException(
            status_code=503,
            detail="Property assignments cannot be verified right now. Please retry.",
        ) from exc
    criteria = SearchCriteria(
        business_type=body.business_type,
        preferred_state=body.preferred_state,
        preferred_area=body.preferred_area,
        min_rental_rm=body.min_rental_rm,
        max_rental_rm=body.max_rental_rm,
        min_size_sqft=body.min_size_sqft,
        max_size_sqft=body.max_size_sqft,
        property_type=body.property_type,
        city=body.city,
        location_latitude=body.location_latitude,
        location_longitude=body.location_longitude,
        nearby_radius_km=body.nearby_radius_km,
        floor_level=body.floor_level,
        transit_max_m=body.transit_max_m,
        nearby_parking_min=body.nearby_parking_min,
        fnb_competition_max=body.fnb_competition_max,
        demand_generator=body.demand_generator,
        population_min_1000m=body.population_min_1000m,
        population_max_1000m=body.population_max_1000m,
        layout_preferences=tuple(body.layout_preferences),
        query=body.query,
        page_size=body.page_size,
        cursor=body.cursor,
        sort=body.sort,
        managed_only=body.managed_only,
        management_ids=assigned_ids,
    )
    try:
        response = RecommendationSearchService(session).search(criteria)
        ids = [row['property_id'] for row in response['data']]
        try:
            managers = management.resolve(ids)
        except ManagementLookupError:
            managers = {pid: unavailable_management() for pid in ids}
        try:
            photo_urls = photo_urls_by_catalogue_ids(operational_db, ids)
        except Exception:  # noqa: BLE001 - media must never fail the search
            photo_urls = {}
        panoramas = panoramas_by_catalogue_ids(operational_db, ids)
        for row in response['data']:
            row['management'] = managers.get(
                row['property_id'], unavailable_management()
            )
            row['photos'] = photo_urls.get(row['property_id'], [])
            row['panorama'] = panoramas.get(
                row['property_id']
            ) or dict(PANORAMA_UNAVAILABLE)
        return response
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
    operational_db: Session = Depends(get_db),
    business_type: str | None = Query(default=None, max_length=120),
    preferred_state: str | None = Query(default=None, max_length=120),
    preferred_area: str | None = Query(default=None, max_length=120),
    min_rental_rm: float | None = Query(default=None, ge=0, le=10_000_000),
    max_rental_rm: float | None = Query(default=None, ge=0, le=10_000_000),
    min_size_sqft: float | None = Query(default=None, ge=0, le=1_000_000),
    max_size_sqft: float | None = Query(default=None, ge=0, le=1_000_000),
    property_type: str | None = Query(default=None, max_length=120),
    city: str | None = Query(default=None, max_length=120),
    location_latitude: float | None = Query(default=None, ge=-90, le=90, allow_inf_nan=False),
    location_longitude: float | None = Query(default=None, ge=-180, le=180, allow_inf_nan=False),
    nearby_radius_km: float | None = Query(default=None, ge=0.5, le=100, allow_inf_nan=False),
    floor_level: str | None = Query(default=None, max_length=80),
    transit_max_m: float | None = Query(default=None, ge=0, le=100_000),
    nearby_parking_min: float | None = Query(default=None, ge=0, le=10_000),
    fnb_competition_max: float | None = Query(default=None, ge=0, le=100_000),
    demand_generator: str | None = Query(default=None, max_length=40),
    population_min_1000m: float | None = Query(default=None, ge=0, le=10_000_000),
    population_max_1000m: float | None = Query(default=None, ge=0, le=10_000_000),
    layout_preferences: list[str] = Query(default=[]),
    query: str | None = Query(default=None, max_length=120),
    managed_only: bool = False,
) -> dict:
    """Filter vocabulary and ranges, counted over the listings the current
    selections still leave eligible.

    The same criteria the search accepts, so the options a dropdown offers are
    computed from the same PU-gated population the search would rank. Each
    facet is counted with all OTHER hard filters applied and only its own
    constraint released — see
    :meth:`RecommendationSearchService.facets`.

    ``business_type`` and the target-market requirements are accepted and
    echoed by the response, but they are not eligibility filters: the first
    only re-sequences the set, the second cannot be verified from the
    catalogue. A caller that treated either as a filter would be told so by
    ``data.fields``.
    """
    if (
        min_rental_rm is not None
        and max_rental_rm is not None
        and min_rental_rm > max_rental_rm
    ):
        raise HTTPException(
            status_code=422,
            detail={"code": "invalid_range",
                    "message": "Minimum rental cannot exceed the maximum rental."},
        )
    if (
        min_size_sqft is not None
        and max_size_sqft is not None
        and min_size_sqft > max_size_sqft
    ):
        raise HTTPException(
            status_code=422,
            detail={"code": "invalid_range",
                    "message": "Minimum floor area cannot exceed the maximum."},
        )
    if (
        population_min_1000m is not None
        and population_max_1000m is not None
        and population_min_1000m > population_max_1000m
    ):
        raise HTTPException(
            status_code=422,
            detail={"code": "invalid_range",
                    "message": "Minimum population cannot exceed the maximum."},
        )
    if any(value is not None for value in (
        location_latitude, location_longitude, nearby_radius_km
    )) and not all(value is not None for value in (
        location_latitude, location_longitude, nearby_radius_km
    )):
        raise HTTPException(status_code=422, detail="Location and radius must be provided together.")
    management = RecommendationManagementService(operational_db)
    try:
        assigned_ids = management.assigned_catalogue_ids() if managed_only else ()
    except ManagementLookupError as exc:
        raise HTTPException(
            status_code=503,
            detail="Property assignments cannot be verified right now. Please retry.",
        ) from exc
    criteria = SearchCriteria(
        business_type=business_type,
        preferred_state=preferred_state,
        preferred_area=preferred_area,
        min_rental_rm=min_rental_rm,
        max_rental_rm=max_rental_rm,
        min_size_sqft=min_size_sqft,
        max_size_sqft=max_size_sqft,
        property_type=property_type,
        city=city,
        location_latitude=location_latitude,
        location_longitude=location_longitude,
        nearby_radius_km=nearby_radius_km,
        floor_level=floor_level,
        transit_max_m=transit_max_m,
        nearby_parking_min=nearby_parking_min,
        fnb_competition_max=fnb_competition_max,
        demand_generator=demand_generator,
        population_min_1000m=population_min_1000m,
        population_max_1000m=population_max_1000m,
        layout_preferences=tuple(layout_preferences),
        query=query,
        managed_only=managed_only,
        management_ids=assigned_ids,
    )
    return {"data": RecommendationSearchService(session).facets(criteria)}



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


@router.delete("/{result_id}", status_code=204, response_model=None)
def delete_recommendation(
    result_id: uuid.UUID,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(get_active_user),
):
    existing = RecommendationService(session).get_result(result_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Recommendation not found")
    if existing.user_id != current.user_id and not rbac.can_read_any_user_data(current.role):
        raise HTTPException(
            status_code=403, detail="You can only delete your own recommendation results."
        )
    RecommendationService(session).delete_result(result_id)
    return None
