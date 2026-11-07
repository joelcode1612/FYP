from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from sitewise.db.analytics_session import get_analytics_db
from sitewise.services.statistics_service import StatisticsService

router = APIRouter()


@router.get("/districts")
def list_districts(session: Session = Depends(get_analytics_db)):
    return StatisticsService(session).list_districts()


@router.get("/districts/{state}/{district}")
def district_statistics(
    state: str,
    district: str,
    session: Session = Depends(get_analytics_db),
):
    result = StatisticsService(session).get_district_statistics(state, district)
    if not result:
        raise HTTPException(status_code=404, detail="District statistics not found")
    return result
