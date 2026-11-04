import uuid
from typing import Optional

from sqlmodel import Session, select

from sitewise.db.models.recommendation_result import RecommendationResult


class RecommendationRepository:
    def __init__(self, session: Session):
        self.session = session

    def create(self, result: RecommendationResult) -> RecommendationResult:
        self.session.add(result)
        self.session.commit()
        self.session.refresh(result)
        return result

    def get_by_id(self, result_id: uuid.UUID) -> Optional[RecommendationResult]:
        return self.session.get(RecommendationResult, result_id)

    def get_by_user_id(self, user_id: uuid.UUID) -> list[RecommendationResult]:
        statement = select(RecommendationResult).where(RecommendationResult.user_id == user_id)
        return list(self.session.exec(statement).all())

    def get_all(self, offset: int = 0, limit: int = 100) -> list[RecommendationResult]:
        statement = select(RecommendationResult).offset(offset).limit(limit)
        return list(self.session.exec(statement).all())

    def update(self, result_id: uuid.UUID, data: dict) -> Optional[RecommendationResult]:
        result = self.get_by_id(result_id)
        if not result:
            return None
        for key, value in data.items():
            setattr(result, key, value)
        self.session.add(result)
        self.session.commit()
        self.session.refresh(result)
        return result

    def delete(self, result_id: uuid.UUID) -> bool:
        result = self.get_by_id(result_id)
        if not result:
            return False
        self.session.delete(result)
        self.session.commit()
        return True
