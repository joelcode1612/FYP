"""Database-backed M2 draft use cases; no hardcoded questionnaire seeding."""
from uuid import UUID

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.domain.m2_rules import validate_m2_answer
from sitewise.services.ports.m2_repository_port import M2RepositoryPort


class M2Service:
    def __init__(self, repository: M2RepositoryPort):
        self.repo = repository

    def read_instrument(self, instrument_id: UUID) -> dict:
        instrument = self.repo.get_instrument(instrument_id)
        if instrument is None or instrument["approval_state"] != "AUTHORIZED":
            raise NotFoundError("Authorized instrument version not found.")
        return {"instrument": instrument, "items": self.repo.list_items(instrument_id)}

    def create_assessment(self, instrument_id: UUID, actor_id: UUID) -> dict:
        instrument = self.repo.get_instrument(instrument_id)
        if instrument is None or instrument["approval_state"] != "AUTHORIZED":
            raise ConflictError("No authorized M2 instrument version is available.")
        try:
            result = self.repo.create_assessment(instrument_id, actor_id)
            self.repo.commit()
            return result
        except Exception:
            self.repo.rollback()
            raise

    def read_assessment(self, assessment_id: UUID, actor_id: UUID) -> dict:
        assessment = self.repo.get_assessment(assessment_id, actor_id)
        if assessment is None:
            raise NotFoundError("Assessment not found.")
        items = self.repo.list_items(assessment["instrument_id"])
        answers = self.repo.get_latest_answers(assessment_id, assessment["revision"])
        return {"assessment": assessment, "items": items, "answers": answers,
                "current_review_completed": self.repo.get_review(assessment_id, assessment["revision"]) is not None,
                "current_confirmation_valid": assessment["confirmed_revision"] == assessment["revision"]}

    def update_answer(self, assessment_id: UUID, actor_id: UUID, *, expected_revision: int,
                      item_key: str, state: str, value: object) -> dict:
        # Owner-scoped row lock prevents an edit racing a confirmation or
        # clarification decision in PostgreSQL. The CAS remains authoritative.
        try:
            assessment = self.repo.get_assessment_for_update(assessment_id, actor_id)
            if assessment is None:
                raise NotFoundError("Assessment not found.")
            if assessment["revision"] != expected_revision:
                raise ConflictError("Assessment revision is stale; reload before saving.")
            item = self.repo.get_item(assessment["instrument_id"], item_key)
            if item is None:
                raise NotFoundError("Item not found for this instrument version.")
            validate_m2_answer(item, state, value)
            if not self.repo.bump_revision(assessment_id, expected_revision):
                raise ConflictError("Assessment revision is stale; reload before saving.")
            answer = self.repo.save_answer(assessment_id, item["id"], expected_revision + 1, state, value)
            self.repo.commit()
            return {"assessment_revision": expected_revision + 1, "answer": answer,
                    "current_review_required": True,
                    "previous_confirmation_is_historical": assessment["confirmed_revision"] is not None}
        except Exception:
            self.repo.rollback()
            raise
