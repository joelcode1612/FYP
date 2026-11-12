from fastapi import APIRouter

from sitewise.api.v1 import (
    assessments,
    auth,
    catalog,
    explore,
    geospatial,
    ml_predictions,
    personalised_recommendations,
    preferences,
    properties,
    project1_read,
    property_verification,
    recommendations,
    reports,
    saved_properties,
    selected_pu_routes,
    staff,
    staff_listings,
    statistics,
    suitability,
    users,
    virtual_tours,
)

router = APIRouter()

# Availability has no activation flag: it only explains the verified holds.
# This does not mount either standalone CQ factory or the staged write APIs.
router.include_router(project1_read.router, prefix="/project1-read", tags=["project1_readiness"])

router.include_router(auth.router, prefix="/auth", tags=["auth"])
# Imported property catalogue (read-only, previously served by FYP/test).
router.include_router(catalog.router, prefix="/catalog", tags=["catalog"])
router.include_router(properties.router, prefix="/properties", tags=["properties"])
# Unified property verification: submitter routes ride the /properties prefix;
# the administrator queue/decisions mount under /staff/properties with the
# established administrator + aal2 requirement.
router.include_router(
    property_verification.submitter_router, prefix="/properties", tags=["property_verification"]
)
router.include_router(
    property_verification.staff_router, prefix="/staff/properties", tags=["property_verification"]
)
router.include_router(users.router, prefix="/users", tags=["users"])
router.include_router(staff.router, prefix="/staff", tags=["staff"])
# Agent listing management (assigned-listing edits, change requests,
# listing photos). Separate module so staff.py is never modified; the
# assignment enforcement helper is IMPORTED from staff.py, so there is
# exactly one authorization definition for staff listing access.
router.include_router(staff_listings.router, prefix="/staff", tags=["staff_listings"])
router.include_router(recommendations.router, prefix="/recommendations", tags=["recommendations"])
# Layer 2/3 personalised pipeline. Separate router so the existing
# recommendations module (and its in-progress /search, /facets work) is never
# modified. Registered AFTER it: existing static paths keep priority.
router.include_router(
    personalised_recommendations.router,
    prefix="/recommendations",
    tags=["recommendations_personalised"],
)
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
# Entrepreneur Explore: approved+published fyp.rental_properties with
# filters/map markers/competitors/population/research evidence. All reads
# are authenticated and gated; nothing here mutates the research schemas.
router.include_router(explore.router, prefix="/explore", tags=["explore"])
# PU model coverage/prediction reporting (implemented; was never registered).
router.include_router(ml_predictions.router, prefix="/ml", tags=["ml_predictions"])

# UPSTREAM M2 RESEARCH FEATURE: disabled by default, no QJ/QG activation.
# Requires separately reviewed schema migration and authorized instrument
# version before it may be enabled in a controlled environment.
from sitewise.core.config import settings
if settings.project1_workflow_enabled:
    from sitewise.api.v1 import project1_workflow
    router.include_router(project1_workflow.router, prefix="/project1-workflow",
                          tags=["project1_candidate_review"])

if settings.project1_cp07_enabled:
    from sitewise.api.v1 import project1_cp07
    router.include_router(project1_cp07.router, prefix="/project1", tags=["project1_cp07_stage"])

if settings.m2_upstream_enabled:
    from sitewise.api.v1 import m2
    router.include_router(m2.router, prefix="/m2", tags=["m2_upstream"])

# Additive OPTIONAL selected research PU model (Layer-1 alternate). Mounted
# BESIDE the default /ml routes — nothing existing is replaced. Same
# authentication dependency, same read-only analytics connection.
router.include_router(
    selected_pu_routes.router, prefix="/ml/selected", tags=["ml_selected"]
)
