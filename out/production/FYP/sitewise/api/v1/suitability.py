from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from sitewise.core.exceptions import SiteWiseError
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, get_active_user
from sitewise.services.suitability_service import SuitabilityService

router = APIRouter()


@router.post("/")
def assess_suitability(
    payload: dict,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(get_active_user),
) -> dict:
    """Assess one property for the authenticated caller.

    Returns ``{"available": false, "score": null, ...}`` while no validated
    scoring specification or trained model artifact exists - a missing model
    is reported, never fabricated as a zero score.
    """
    property_id = payload.get("property_id")
    if not isinstance(property_id, int):
        raise HTTPException(status_code=422, detail="property_id must be an integer.")
    try:
        return SuitabilityService(session).assess(property_id, payload.get("preferences"))
    except SiteWiseError as exc:
        raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc
