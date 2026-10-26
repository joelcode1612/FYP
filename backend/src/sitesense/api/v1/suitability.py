from fastapi import APIRouter, Depends
from sqlmodel import Session

from sitesense.db.session import get_db
from sitesense.services.suitability_service import SuitabilityService

router = APIRouter()


@router.post("/")
def assess_suitability(payload: dict, session: Session = Depends(get_db)):
    property_id = payload.get("property_id")
    return SuitabilityService(session).assess(property_id, payload.get("preferences"))
