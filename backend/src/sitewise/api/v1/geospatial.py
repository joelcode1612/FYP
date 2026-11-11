from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from sitewise.db.session import get_db
from sitewise.dependencies import CurrentUser
from sitewise.ingestion.state import RefreshState
from sitewise.repositories.geospatial_repository import GeospatialRepository

router = APIRouter()


@router.get("/property/{property_id}/freshness")
def get_feature_freshness(
    property_id: int,
    _user: CurrentUser,
    session: Session = Depends(get_db),
):
    """Additive freshness/provenance for one property's calculated features.

    ``status`` is one of current / stale / pending / failed / unavailable.
    ``available=false`` means no trustworthy value exists — it is never
    reported as zero. Read-only: this endpoint never triggers a calculation.
    """
    state = RefreshState(session)
    return {
        "data": state.freshness_payload(property_id),
        "provenance": state.provenance_summary(),
    }


@router.get("/property/{property_id}/competitors")
def get_competitors(property_id: int, session: Session = Depends(get_db)):
    return GeospatialRepository(session).get_competitors_by_property_id(property_id)


@router.get("/property/{property_id}/geo-feature")
def get_geo_feature(property_id: int, session: Session = Depends(get_db)):
    feature = GeospatialRepository(session).get_geo_feature_by_property_id(property_id)
    if not feature:
        raise HTTPException(status_code=404, detail="Geo feature not found")
    return feature


@router.get("/property/{property_id}/foot-traffic")
def get_foot_traffic(property_id: int, session: Session = Depends(get_db)):
    traffic = GeospatialRepository(session).get_foot_traffic_by_property_id(property_id)
    if not traffic:
        raise HTTPException(status_code=404, detail="Foot traffic not found")
    return traffic


@router.get("/districts")
def list_districts(offset: int = 0, limit: int = 100, session: Session = Depends(get_db)):
    return GeospatialRepository(session).get_all_districts(offset, limit)
