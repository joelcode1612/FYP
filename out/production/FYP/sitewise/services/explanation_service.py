from sqlmodel import Session

from sitewise.db.models.ai_explanation import AiExplanation


class ExplanationService:
    def __init__(self, session: Session):
        self.session = session

    def create(self, explanation: AiExplanation) -> AiExplanation:
        self.session.add(explanation)
        self.session.commit()
        self.session.refresh(explanation)
        return explanation
