from fastapi import APIRouter

from sitewise.api.v1 import (
    assessments,
    agent_only_flow,
    auth,
    capture_360,
    public_panorama_publication,
    catalog,
    compare,
    explore,
    geospatial,
    ml_predictions,
    personalised_recommendations,
    preferences,
    properties,
    project1_read,
    property_verification,
    provider,
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
from sitewise.api.v1 import customer_questionnaire
router.include_router(customer_questionnaire.router,prefix='/cq',tags=['customer_questionnaire'])
from sitewise.api.v1 import synthetic_inspection
router.include_router(synthetic_inspection.router,prefix='/cq',tags=['synthetic_developer_inspection'])
from sitewise.api.v1 import synthetic_execution
router.include_router(synthetic_execution.router,prefix='/cq',tags=['synthetic_developer_execution'])
# Candidate EE-01 explanations: always mounted so the hold is visible; the
# request-time gate returns 503 until the feature is deliberately activated.
from sitewise.api.v1 import ee01_explanation
router.include_router(ee01_explanation.router, prefix='/cq', tags=['ee01_explanation'])

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
# Owner / Agent (Provider) workspace: the shared inbox, performance report and
# account verification. One route set serves both provider roles — what differs
# is the ownership / assignment relationship resolved server-side, not the API.
router.include_router(provider.router, prefix="/provider", tags=["provider"])
router.include_router(agent_only_flow.router, prefix="/provider-flow", tags=["agent_only_verification"])
# Enquiry creation is the ENQUIRER's action, so it rides the listing prefix the
# rest of the property surface uses.
router.include_router(
    provider.enquirer_router, prefix="/properties", tags=["provider"]
)
router.include_router(
    provider.staff_router,
    prefix="/staff/providers",
    tags=["provider_verification"],
)
router.include_router(staff.router, prefix="/staff", tags=["staff"])
# Agent listing management (assigned-listing edits, change requests,
# listing photos). Separate module so staff.py is never modified; the
# assignment enforcement helper is IMPORTED from staff.py, so there is
# exactly one authorization definition for staff listing access.
router.include_router(staff_listings.router, prefix="/staff", tags=["staff_listings"])
router.include_router(recommendations.router, prefix="/recommendations", tags=["recommendations"])
# Direct shortlist comparison — separate from ranking, never a second scorer.
router.include_router(compare.router, prefix="/compare", tags=["compare"])
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
# RP-13: the confirmed business description the report's section 02 reads.
# Additive and read-only; mounted beside the assessment router so the report
# always gets an explicit state (including "the M2 stage is not enabled") rather
# than a 404 it would have to guess about.
from sitewise.api.v1 import report_business_description
router.include_router(report_business_description.router, prefix="/assessments",
                      tags=["report_business_description"])
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
# Backend-authoritative 360° capture: authorized sessions, frame manifests and
# panorama processing jobs. The stitching worker claims the jobs these routes
# enqueue; storage transport is the signed-upload gateway.
router.include_router(capture_360.router, prefix="/360", tags=["capture_360"])
# Public-schema AR capture tour publication and shared read endpoint.
router.include_router(
    public_panorama_publication.router, prefix="/360/published",
    tags=["public_panorama_publication"],
)
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
    # Questionnaire Preview and the composed questionnaire are the fixed-path
    # release surface. They were implemented but never registered, so the client
    # (``stage4_preview_api.dart`` / ``stage5_composed_api.dart``, both on
    # ``/api/v1/project1-workflow``) received 404 for a route that exists. The
    # fixed Q01-Q13 path must be reachable without any optional AI execution, so
    # these are mounted beside the workflow router they belong to.
    from sitewise.api.v1 import project1_stage4_preview
    from sitewise.api.v1 import project1_stage5_composed
    # Governed BDJ objective proposals. Same defect class as the two routers
    # above: the module, its persistence adapter and its complete Dart client
    # (``bdj_objective_proposal_api.dart``, base ``/api/v1/project1-workflow/
    # assessments``) all existed, but the router was never registered, so every
    # objective request answered 404. Without it the Stage 3 objective panel
    # cannot execute, review, approve or reject anything -- and an approved
    # objective is the only route by which an additional question can become
    # eligible for Section B.
    from sitewise.api.v1 import project1_objective_proposals
    router.include_router(project1_workflow.router, prefix="/project1-workflow",
                          tags=["project1_candidate_review"])
    router.include_router(project1_stage4_preview.router, prefix="/project1-workflow",
                          tags=["project1_stage4_preview"])
    router.include_router(project1_stage5_composed.router, prefix="/project1-workflow",
                          tags=["project1_stage5_composed"])
    router.include_router(project1_objective_proposals.router,
                          prefix="/project1-workflow",
                          tags=["project1_objective_proposals"])

if settings.project1_cp07_enabled:
    from sitewise.api.v1 import project1_cp07
    router.include_router(project1_cp07.router, prefix="/project1", tags=["project1_cp07_stage"])

if settings.m2_upstream_enabled:
    from sitewise.api.v1 import m2
    from sitewise.api.v1 import m2_business_context
    # QG candidate generation rides the same opt-in gate: it reads the same M2
    # records and persists versions into the same review tables, so a separate
    # flag would only create a state in which half the surface is mounted.
    from sitewise.api.v1 import qg_candidate
    # Stage 4 readback for a persisted Direct-QG candidate. Mounted on the same
    # opt-in gate because it reads the same M2 records the candidate writer
    # produced; a separate flag would allow a state in which a candidate exists
    # but cannot be reviewed.
    from sitewise.api.v1 import qg_candidate_read
    # Authenticated Direct-QG generation. Same gate as the two above: it writes
    # the candidates the Stage 4 readback reads, so mounting it separately would
    # allow a reviewer surface with nothing that can produce a candidate.
    from sitewise.api.v1 import qg_candidate_live
    # The authorization the generation route requires. Mounted on the same gate
    # as the route that spends it: an authorization surface without the ability
    # to generate would be a permission nobody can use, and the generation
    # route without this is the dead end DD-040 recorded.
    from sitewise.api.v1 import qg_authorization_live
    from sitewise.api.v1 import ai_execution_status_live
    router.include_router(m2.router, prefix="/m2", tags=["m2_upstream"])
    router.include_router(m2_business_context.router, prefix="/m2", tags=["m2_business_context"])
    router.include_router(qg_candidate.router, prefix="/m2", tags=["m2_qg_candidate"])
    # Order is load-bearing. ``qg_candidate_live`` declares the literal
    # ``/qg-candidates/recovery``, and ``qg_candidate_read`` declares
    # ``/qg-candidates/{candidate_id}``. FastAPI matches in include order, so
    # mounting the parameterised router first made ``recovery`` parse as a UUID
    # and the endpoint answered 422 instead of reporting recovery state. The
    # literal router must therefore be included first; its other paths
    # (``/qg-candidates``, ``/qg-candidates/generate``) do not collide with any
    # ``{candidate_id}`` shape, so nothing is shadowed in return.
    router.include_router(qg_candidate_live.router, prefix="/m2",
                          tags=["m2_qg_candidate_live"])
    router.include_router(qg_candidate_read.router, prefix="/m2",
                          tags=["m2_qg_candidate_read"])
    router.include_router(qg_authorization_live.router, prefix="/m2",
                          tags=["m2_qg_authorization_live"])
    # Real execution progress for the existing AI Execution Status card, read
    # from the ledger that already records it. Mounted beside the QG routes for
    # the same reason they are grouped: the card reports on the same attempts.
    router.include_router(ai_execution_status_live.router, prefix="/m2",
                          tags=["m2_ai_execution_status"])

# Additive OPTIONAL selected research PU model (Layer-1 alternate). Mounted
# BESIDE the default /ml routes — nothing existing is replaced. Same
# authentication dependency, same read-only analytics connection.
router.include_router(
    selected_pu_routes.router, prefix="/ml/selected", tags=["ml_selected"]
)
