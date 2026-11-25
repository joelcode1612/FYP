"""Read-only, versioned assessment workflow readiness.

The marketplace timestamps retain their original meaning.  A confirmed M2
revision is checked against the existing owner-scoped link and provenance
validator on each read; it is never copied into those timestamps.

Completion is evaluated by :mod:`sitewise.services.assessment_progress` -- the
same predicate the marketplace record uses for ``completed_stages`` and
``progress_percent``. That is deliberate: this module used to carry its own
hardcoded ``completion: NOT_IMPLEMENTED`` for stages 3-5 while the record
counted legacy timestamps, so the stepper and the dashboard could report
different journeys. There is now one evaluation and two renderings of it.

Stages 3-5 stay non-complete until their own evidence exists. A governance hold
is reported as ``BLOCKED`` with its reason, never as success.
"""
from uuid import UUID

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.services import assessment_progress
from sitewise.services.assessment_link_service import AssessmentLinkError

CONTRACT_VERSION = "sitewise-assessment-workflow/3"

#: Stage 5's completion rule is not ours to invent. It is reported so the owner
#: can approve or reject it; nothing in this module applies it.
STAGE_5_PROPOSED_RULE = assessment_progress.STAGE_5_PROPOSED_RULE


def _stage_view(stage: dict, *, extra: dict | None = None) -> dict:
    view = {
        "complete": stage["complete"],
        "state": stage["state"],
        "reason": stage["reason"],
        "completed_at": stage["completed_at"],
    }
    if extra:
        view.update(extra)
    return view


def workflow_readiness(assessment, actor_id: UUID, email: str | None, link_service, m2_service) -> dict:
    """Return a point-in-time readiness result; do not mutate either database."""
    evidence = assessment_progress.empty_evidence(
        getattr(assessment, "property_selected_at", None),
        getattr(assessment, "requirements_saved_at", None))

    try:
        link = link_service.resolve(marketplace_assessment_id=assessment.assessment_id,
                                    user_id=actor_id, verified_email=email,
                                    create_if_missing=False)
    except AssessmentLinkError as exc:
        if exc.code != "ASSESSMENT_NOT_LINKED":
            raise
        return _payload(assessment, evidence, link=None, source=None)

    evidence["linked"] = True
    confirmation = m2_service.repo.latest_confirmation(link.m2_assessment_id, actor_id)
    if confirmation is None or not confirmation.get("is_current"):
        evidence["declaration_reason"] = assessment_progress.REASON_CURRENT_CONFIRMATION_REQUIRED
        return _payload(assessment, evidence, link=link, source=None)

    source = None
    try:
        with m2_service.locked_confirmed_source(
            link.m2_assessment_id, actor_id, confirmation_id=confirmation["id"],
            expected_revision=confirmation["assessment_revision"],
        ) as confirmed:
            source = {
                "confirmation_id": str(confirmed["confirmation_id"]),
                "assessment_revision": confirmed["assessment_revision"],
                "snapshot_digest": confirmed["snapshot_digest"],
            }
    except (ConflictError, NotFoundError):
        evidence["declaration_reason"] = "CONFIRMATION_STALE_OR_INVALID"
        return _payload(assessment, evidence, link=link, source=None)

    evidence["declaration"] = source
    evidence["declaration_reason"] = None
    _read_objectives(evidence, assessment, actor_id, m2_service)
    return _payload(assessment, evidence, link=link, source=source)


def _read_objectives(evidence: dict, assessment, actor_id: UUID, m2_service) -> None:
    """Load stage 3-5 evidence from the owner-scoped M2 session.

    The objectives, candidate and preview rows all live behind
    ``project1.actor_id`` RLS, so they are read through the same session the M2
    routes use. A caller that cannot supply one (a unit-test double) is treated
    as "no objectives yet" rather than as a storage failure -- but a session that
    exists and fails is a storage failure and is reported as one.
    """
    session = getattr(getattr(m2_service, "repo", None), "session", None)
    if session is None:
        evidence["preview"] = assessment_progress.preview_status(evidence)
        return
    loaded = assessment_progress.load_evidence(
        session, actor_id, [assessment.assessment_id],
        property_selected_at={str(assessment.assessment_id): evidence["property_selected_at"]},
        requirements_saved_at={str(assessment.assessment_id):
                               evidence.get("requirements_saved_at")},
    ).get(str(assessment.assessment_id))
    if loaded is None:
        return
    for key in ("store_readable", "instrument_version", "objectives", "candidates",
                "preview", "stage3", "m2_assessment_id"):
        evidence[key] = loaded[key]


def _payload(assessment, evidence: dict, *, link, source) -> dict:
    progress = assessment_progress.evaluate(evidence)
    stages = {stage["key"]: stage for stage in progress["stages"]}

    stage_1 = _stage_view(stages["select_property"])
    stage_2 = _stage_view(stages["business_requirements"])
    if source is not None:
        stage_2.update({
            "m2_assessment_id": str(link.m2_assessment_id),
            "confirmation_id": source["confirmation_id"],
            "assessment_revision": source["assessment_revision"],
            "snapshot_digest": source["snapshot_digest"],
        })

    # Enterability is navigation only. It says "the panel may open", never
    # "the work is done"; each operation keeps its own server-side gate.
    enterable = stage_1["complete"] and stage_2["complete"]
    stage_3 = _stage_view(stages["location_evidence"], extra={"enterable": enterable})
    stage_4 = _stage_view(stages["ai_explanation"], extra={"enterable": enterable})
    stage_5 = _stage_view(stages["assessment_report"],
                          extra={"preview_enterable": True})

    blocked = [
        {"stage": stage["key"], "reason": stage["reason"]}
        for stage in progress["stages"]
        if stage["state"] in (assessment_progress.BLOCKED,
                              assessment_progress.NOT_AVAILABLE)
    ]
    # Everything still outstanding, blocked or merely not done yet. This is what
    # the "N remaining" count is made of, so a reader can see which checkpoints
    # they are rather than only how many.
    outstanding = [
        {"stage": stage["key"], "number": stage["number"], "state": stage["state"],
         "reason": stage["reason"]}
        for stage in progress["stages"]
        if not stage["complete"]
    ]

    return {
        "contract_version": CONTRACT_VERSION,
        "assessment_id": str(assessment.assessment_id),
        "stage_1": stage_1,
        "stage_2": stage_2,
        "stage_3": stage_3,
        "stage_4": stage_4,
        "stage_5": stage_5,
        # The one number every surface renders. Present so a client never has to
        # sum the stage flags itself (which is how the stepper used to cap at 2).
        "progress": {
            "completed_stages": progress["completed_stages"],
            "remaining_stages": progress["remaining_stages"],
            "total_stages": progress["total_stages"],
            "progress_percent": progress["progress_percent"],
            "current_stage": progress["current_stage"],
            "current_stage_key": progress["current_stage_key"],
        },
        "blocked": blocked,
        "outstanding": outstanding,
        # Stage 3's rule is adopted and enforced by the evaluator; stage 4's rule
        # is now adopted and enforced too (it had an implementation but no
        # written rule until 2026-11-24). Stage 5's is still a proposal, because
        # no adopted questionnaire-preview contract exists. Keeping them in
        # separate keys stops an unapplied rule from reading as an applied one.
        "applied_completion_rules": {
            "stage_3": assessment_progress.STAGE_3_RULE,
            "stage_4": assessment_progress.STAGE_4_RULE,
        },
        "proposed_completion_rules": {
            "stage_5": STAGE_5_PROPOSED_RULE,
        },
    }
