from fastapi import APIRouter, HTTPException

from sitewise.dependencies import CurrentUser, GeospatialServiceImpl

router = APIRouter()


@router.get("/property/{property_id}/freshness")
def get_feature_freshness(
    property_id: int,
    _user: CurrentUser,
    service: GeospatialServiceImpl,
):
    """Additive freshness/provenance for one property's calculated features.

    ``status`` is one of current / stale / pending / failed / unavailable.
    ``available=false`` means no trustworthy value exists — it is never
    reported as zero. Read-only: this endpoint never triggers a calculation.
    """
    return service.freshness(property_id)


@router.get("/property/{property_id}/competitors")
def get_competitors(property_id: int, service: GeospatialServiceImpl):
    return service.competitors(property_id)


@router.get("/property/{property_id}/geo-feature")
def get_geo_feature(property_id: int, service: GeospatialServiceImpl):
    feature = service.geo_feature(property_id)
    if not feature:
        raise HTTPException(status_code=404, detail="Geo feature not found")
    return feature


@router.get("/property/{property_id}/foot-traffic")
def get_foot_traffic(property_id: int, service: GeospatialServiceImpl):
    traffic = service.foot_traffic(property_id)
    if not traffic:
        raise HTTPException(status_code=404, detail="Foot traffic not found")
    return traffic


@router.get("/districts")
def list_districts(
    service: GeospatialServiceImpl,
    offset: int = 0,
    limit: int = 100,
):
    return service.districts(offset, limit)
