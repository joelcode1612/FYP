import uuid

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session, select

from sitewise.db.models.recommendation_result import RecommendationResult
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, get_active_user, require_admin
from sitewise.domain import rbac
from sitewise.services.recommendation_service import RecommendationService

router = APIRouter()


@router.get("/")
def list_recommendations(
    offset: int = 0,
    limit: int = 100,
    session: Session = Depends(get_db),
    _: AuthenticatedUser = Depends(require_admin),
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
