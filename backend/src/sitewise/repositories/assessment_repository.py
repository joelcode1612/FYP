import uuid
from typing import Optional

from sqlmodel import Session, select

from sitewise.db.models.assessment import Assessment


class AssessmentRepository:
    """Persistence for web assessments, always scoped to one owner."""

    def __init__(self, session: Session):
        self.session = session

    def create(self, assessment: Assessment) -> Assessment:
        self.session.add(assessment)
        self.session.commit()
        self.session.refresh(assessment)
        return assessment

    def save(self, assessment: Assessment) -> Assessment:
        self.session.add(assessment)
        self.session.commit()
        self.session.refresh(assessment)
        return assessment

    def delete(self, assessment: Assessment) -> None:
        """Legacy callers share the same coordinator; no marketplace-only delete."""
        from sitewise.services.assessment_discard_service import AssessmentDiscardService
        AssessmentDiscardService(self.session.get_bind()).discard(
            assessment.assessment_id, assessment.user_id)

    def get_by_id(self, assessment_id: uuid.UUID) -> Optional[Assessment]:
        return self.session.get(Assessment, assessment_id)

    def get_by_user_and_property(
        self, user_id: uuid.UUID, property_id: str
    ) -> Optional[Assessment]:
        return self.session.exec(
            select(Assessment).where(
                Assessment.user_id == user_id,
                Assessment.property_id == property_id,
            )
        ).first()

    def list_by_user(
        self, user_id: uuid.UUID, limit: int = 50, offset: int = 0
    ) -> list[Assessment]:
        statement = (
            select(Assessment)
            .where(Assessment.user_id == user_id)
            .order_by(Assessment.updated_at.desc(), Assessment.created_at.desc())
            .limit(limit)
            .offset(offset)
        )
        return list(self.session.exec(statement).all())

    def count_by_user(self, user_id: uuid.UUID) -> int:
        from sqlalchemy import func

        return int(
            self.session.exec(
                select(func.count()).select_from(Assessment).where(Assessment.user_id == user_id)
            ).one()
        )

    def most_recent(self, user_id: uuid.UUID) -> Optional[Assessment]:
        return self.session.exec(
            select(Assessment)
            .where(Assessment.user_id == user_id)
            .order_by(Assessment.updated_at.desc(), Assessment.created_at.desc())
            .limit(1)
        ).first()
