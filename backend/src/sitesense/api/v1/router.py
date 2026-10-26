from fastapi import APIRouter

from sitesense.api.v1 import (
    geospatial,
    properties,
    recommendations,
    reports,
    saved_properties,
    suitability,
    users,
    virtual_tours,
)

router = APIRouter()

router.include_router(properties.router, prefix="/properties", tags=["properties"])
router.include_router(users.router, prefix="/users", tags=["users"])
router.include_router(recommendations.router, prefix="/recommendations", tags=["recommendations"])
router.include_router(suitability.router, prefix="/suitability", tags=["suitability"])
router.include_router(saved_properties.router, prefix="/saved-properties", tags=["saved_properties"])
router.include_router(geospatial.router, prefix="/geospatial", tags=["geospatial"])
router.include_router(virtual_tours.router, prefix="/virtual-tours", tags=["virtual_tours"])
router.include_router(reports.router, prefix="/reports", tags=["reports"])
