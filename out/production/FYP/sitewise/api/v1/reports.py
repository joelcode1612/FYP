from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from sitewise.core.exceptions import SiteWiseError
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, get_active_user
from sitewise.services.report_service import ReportService

router = APIRouter()


@router.get("/property/{property_id}")
def property_report(property_id: int, session: Session = Depends(get_db), current: AuthenticatedUser = Depends(get_active_user)):
    """Generate a property report for the authenticated caller.

    Reports depend on the analysis modules (suitability/ML), which currently
    report themselves unavailable; the service surfaces that state instead of
    fabricating content.
    """
    try:
        return ReportService(session).generate_property_report(property_id)
    except SiteWiseError as exc:
        raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc
