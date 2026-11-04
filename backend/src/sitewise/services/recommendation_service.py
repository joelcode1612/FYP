import uuid
from typing import Optional

from sqlmodel import Session

from sitewise.db.models.recommendation_result import RecommendationResult
from sitewise.repositories.recommendation_repository import RecommendationRepository
from sitewise.domain.ranking import rank


class RecommendationService:
    def __init__(self, session: Session):
        self.repo = RecommendationRepository(session)

    def create_result(self, result: RecommendationResult) -> RecommendationResult:
        return self.repo.create(result)

    def get_by_user(self, user_id: uuid.UUID) -> list[RecommendationResult]:
        return self.repo.get_by_user_id(user_id)

    def list_results(self, offset: int = 0, limit: int = 100) -> list[RecommendationResult]:
        return self.repo.get_all(offset, limit)

    def delete_result(self, result_id: uuid.UUID) -> bool:
        return self.repo.delete(result_id)
