from sqlmodel import Session

from sitesense.domain.suitability_engine import SuitabilityEngine


class SuitabilityService:
    def __init__(self, session: Session):
        self.session = session
        self.engine = SuitabilityEngine()

    def assess(self, property_id: int, user_preferences: dict | None = None) -> dict:
        return self.engine.score(property_id, user_preferences or {})
