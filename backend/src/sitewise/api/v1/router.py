from fastapi import APIRouter

from sitewise.api.v1 import (
    assessments,
    auth,
    catalog,
    geospatial,
    preferences,
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
# Web Location Assessment Workspace (decision-support). Mobile data collection
# keeps its own session store and does not use these routes.
router.include_router(assessments.router, prefix="/assessments", tags=["assessments"])
# Entrepreneur recommendation preferences. Shares the assessment's
# business-requirements vocabulary and validation, so the workspace's stage 2
# and the preferences page store the same shape rather than two systems.
router.include_router(preferences.router, prefix="/preferences", tags=["preferences"])
router.include_router(suitability.router, prefix="/suitability", tags=["suitability"])
router.include_router(
    saved_properties.router, prefix="/saved-properties", tags=["saved_properties"]
)
router.include_router(geospatial.router, prefix="/geospatial", tags=["geospatial"])
router.include_router(virtual_tours.router, prefix="/virtual-tours", tags=["virtual_tours"])
router.include_router(reports.router, prefix="/reports", tags=["reports"])
router.include_router(statistics.router, prefix="/statistics", tags=["statistics"])
