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

    Assembles the property's stored listing data, precomputed geospatial
    features, live competitor counts and (via the verified research link)
    PU feature and population records. Sections without backing data report
    ``available: false`` with a reason instead of fabricated content.
    Accepts both ``fyp.rental_properties`` ids and workbook catalogue ids.
    """
    try:
        return ReportService(session).generate_property_report(property_id)
    except SiteWiseError as exc:
        raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc
