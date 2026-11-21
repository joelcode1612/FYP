"""Read-only, versioned assessment workflow readiness.

The marketplace timestamps retain their original meaning.  A confirmed M2
revision is checked against the existing owner-scoped link and provenance
validator on each read; it is never copied into those timestamps.
"""
from uuid import UUID

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.services.assessment_link_service import AssessmentLinkError

CONTRACT_VERSION = "sitewise-assessment-workflow/2"


def workflow_readiness(assessment, actor_id: UUID, email: str | None, link_service, m2_service) -> dict:
    """Return a point-in-time readiness result; do not mutate either database."""
    result = {
        "contract_version": CONTRACT_VERSION,
        "assessment_id": str(assessment.assessment_id),
        "stage_1": {"complete": assessment.property_selected_at is not None},
        "stage_2": {"complete": False, "reason": "M2_NOT_LINKED"},
        "stage_3": {"enterable": False, "complete": False, "completion": "NOT_IMPLEMENTED"},
        "stage_4": {"enterable": False, "complete": False, "completion": "NOT_IMPLEMENTED"},
        # The assessment is already owner-scoped by the route. Viewing a
        # read-only unavailable/preview state is not a completion or grant.
        "stage_5": {"preview_enterable": True, "complete": False,
                    "completion": "NOT_IMPLEMENTED"},
    }
    try:
        link = link_service.resolve(marketplace_assessment_id=assessment.assessment_id,
                                    user_id=actor_id, verified_email=email,
                                    create_if_missing=False)
    except AssessmentLinkError as exc:
        if exc.code == "ASSESSMENT_NOT_LINKED":
            return result
        raise
    confirmation = m2_service.repo.latest_confirmation(link.m2_assessment_id, actor_id)
    if confirmation is None or not confirmation.get("is_current"):
        result["stage_2"]["reason"] = "CURRENT_CONFIRMATION_REQUIRED"
        return result
    try:
        with m2_service.locked_confirmed_source(
            link.m2_assessment_id, actor_id, confirmation_id=confirmation["id"],
            expected_revision=confirmation["assessment_revision"],
        ) as source:
            result["stage_2"] = {
                "complete": True, "reason": None,
                "m2_assessment_id": str(link.m2_assessment_id),
                "confirmation_id": str(source["confirmation_id"]),
                "assessment_revision": source["assessment_revision"],
                "snapshot_digest": source["snapshot_digest"],
            }
            result["stage_3"]["enterable"] = result["stage_1"]["complete"]
            # Viewing question review does not authorize generation, approval,
            # fielding or completion. Each operation retains its own gates.
            result["stage_4"]["enterable"] = result["stage_3"]["enterable"]
    except (ConflictError, NotFoundError):
        result["stage_2"]["reason"] = "CONFIRMATION_STALE_OR_INVALID"
    return result
