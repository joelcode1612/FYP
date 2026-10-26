import uuid

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from sitesense.db.session import get_db
from sitesense.db.models.recommendation_result import RecommendationResult
from sitesense.services.recommendation_service import RecommendationService

router = APIRouter()


@router.get("/")
def list_recommendations(offset: int = 0, limit: int = 100, session: Session = Depends(get_db)):
    return RecommendationService(session).list_results(offset, limit)


@router.get("/user/{user_id}")
def get_recommendations_by_user(user_id: uuid.UUID, session: Session = Depends(get_db)):
    return RecommendationService(session).get_by_user(user_id)


@router.post("/", status_code=201)
def create_recommendation(result: RecommendationResult, session: Session = Depends(get_db)):
    return RecommendationService(session).create_result(result)


@router.delete("/{result_id}", status_code=204)
def delete_recommendation(result_id: uuid.UUID, session: Session = Depends(get_db)):
    ok = RecommendationService(session).delete_result(result_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Recommendation not found")
    return None
