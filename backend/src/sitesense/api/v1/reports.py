from fastapi import APIRouter, Depends
from sqlmodel import Session

from sitesense.db.session import get_db
from sitesense.services.report_service import ReportService

router = APIRouter()


@router.get("/property/{property_id}")
def property_report(property_id: int, session: Session = Depends(get_db)):
    return ReportService(session).generate_property_report(property_id)
