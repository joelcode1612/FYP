from sqlmodel import Session

from sitewise.core.exceptions import NotFoundError
from sitewise.domain.suitability_engine import assess_premises
from sitewise.repositories.fyp_property_repository import FypPropertyRepository


class SuitabilityService:
    def __init__(self, session: Session):
        self.session = session
        self.properties = FypPropertyRepository(session)

    def assess(self, property_id: int, user_preferences: dict | None = None) -> dict:
        """Assess one property, honestly reporting when scoring is unavailable.

        Raises ``NotFoundError`` when the property itself does not exist, so
        a missing property (404) is distinguishable from an unavailable model
        (200 with ``available: false``). Existence is checked against the
        canonical operational table ``fyp.rental_properties`` — the legacy
        ``public.property`` table was retired by migration 0005.
        """
        if self.properties.owner_listing(property_id) is None:
            raise NotFoundError("Property not found")
        assessment = assess_premises(property_id, user_preferences)
        return {
            "property_id": assessment.property_id,
            "available": assessment.available,
            "score": assessment.score,
            "reason": assessment.reason,
            "components": assessment.components,
            "prerequisites": list(assessment.prerequisites),
        }
