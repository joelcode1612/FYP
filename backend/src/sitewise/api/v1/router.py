from fastapi import APIRouter

from sitewise.api.v1 import (
    auth,
    catalog,
    geospatial,
    properties,
    recommendations,
    reports,
    saved_properties,
    staff,
    statistics,
    suitability,
    users,
    virtual_tours,
)

router = APIRouter()

router.include_router(auth.router, prefix="/auth", tags=["auth"])
# Imported property catalogue (read-only, previously served by FYP/test).
router.include_router(catalog.router, prefix="/catalog", tags=["catalog"])
router.include_router(properties.router, prefix="/properties", tags=["properties"])
router.include_router(users.router, prefix="/users", tags=["users"])
router.include_router(staff.router, prefix="/staff", tags=["staff"])
router.include_router(recommendations.router, prefix="/recommendations", tags=["recommendations"])
router.include_router(suitability.router, prefix="/suitability", tags=["suitability"])
router.include_router(saved_properties.router, prefix="/saved-properties", tags=["saved_properties"])
router.include_router(geospatial.router, prefix="/geospatial", tags=["geospatial"])
router.include_router(virtual_tours.router, prefix="/virtual-tours", tags=["virtual_tours"])
router.include_router(reports.router, prefix="/reports", tags=["reports"])
router.include_router(statistics.router, prefix="/statistics", tags=["statistics"])

# UPSTREAM M2 RESEARCH FEATURE: disabled by default, no QJ/QG activation.
# Requires separately reviewed schema migration and authorized instrument
# version before it may be enabled in a controlled environment.
from sitewise.core.config import settings
if settings.m2_upstream_enabled:
    from sitewise.api.v1 import m2
    router.include_router(m2.router, prefix="/m2", tags=["m2_upstream"])
