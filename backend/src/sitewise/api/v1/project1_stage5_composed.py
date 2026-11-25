"""Stage 5 composed-questionnaire retrieval.

What this route answers
-----------------------
*What is the actual questionnaire for this assessment, right now?* It returns the
13 governed core questions plus every additional question that is both approved
and eligible, with the real option sets, the objective bindings, the owner's own
intended option as entrepreneur-only metadata, and an explicit statement of what
is still unresolved and why nothing is publishable.

What it deliberately does not do
--------------------------------
* **No second approval mechanism.** Stage 5 displays what Stage 4 decided. An
  additional question enters this document only because it already carries an
  ``APPROVE_FOR_REVIEW`` decision, a ``VALIDATED`` candidate state and passing
  structural/semantic/provenance checks. This route has no approve or reject
  verb, and the fixed core has no per-question control anywhere.
* **No authority.** ``fielding_authorized``, ``publication_authorized`` and
  ``scientifically_accepted`` are false on the document and on every item.
  Publication and customer fielding stay disabled.
* **No respondent leakage.** Owner-intended options are marked
  ``ENTREPRENEUR_ONLY_METADATA``. They are never a respondent answer, never
  preselected in a customer questionnaire, and never read by an EE-01
  measurement. Customer-facing questionnaire routes do not read the review table
  this route reads.

Why it is not a duplicate of the existing preview endpoints
-----------------------------------------------------------
Two ``questionnaire-preview`` endpoints already exist and both are Stage 5
surfaces, but neither can answer this question:

* ``GET /assessments/{id}/questionnaire-preview`` is a hard-coded HOLD;
* ``GET /m2/assessments/{id}/questionnaire-preview`` returns
  ``NO_ADMITTED_OBJECTIVE`` before it returns any item, and never includes the
  fixed core.

Neither composes the governed core with approved additional questions, so this
route is additive. It reuses the same composition service as the Stage 4 preview,
which is what keeps the two stages from describing different questionnaires.
"""
from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy import text

from sitewise.api.v1.m2_route import M2SourceRoute
from sitewise.cq_successor.preview_catalogue import (
    PreviewCatalogueError,
    PreviewQuestionCatalogue,
    build_slot_values,
)
from sitewise.db.m2_session import m2_session_for
from sitewise.dependencies import AuthenticatedUser, require_entrepreneur
from sitewise.project1.contracts import no_authority
from sitewise.project1.qg_candidate_read import list_candidates_in_session
from sitewise.services import questionnaire_composition as composition

router = APIRouter(route_class=M2SourceRoute)

Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]

#: The admission decision the schema actually permits. There is no ``ADMITTED``
#: value in ``m2_bdj_objective_admissions``; the CHECK constraint allows only
#: ``WORTH_RESEARCHING``, so counting ``ADMITTED`` would always return zero and
#: silently misreport why Section B is empty.
ADMITTED_DECISION = 'WORTH_RESEARCHING'

#: Count the objectives that are actually authorised, from **either** authority.
#:
#: Before contract 2.1 this counted manual admissions only, so an objective the
#: owner had approved in Stage 3 produced ``admitted_objective_count = 0`` and
#: Section B stayed empty with ``NO_ADMITTED_OBJECTIVE`` — the composition was
#: reporting the absence of a step the directive removes. The two sources are
#: counted as distinct identities rather than merged, because mapping a proposal
#: to a registry objective is a policy decision made in Python; merging them in
#: SQL would claim a correspondence this query cannot establish. Only "is
#: anything authorised" and "how many authorities exist" are asserted here.
_AUTHORISED_SQL = """
    SELECT count(*) AS n FROM (
        SELECT 'admission:' || objective_id AS identity
          FROM public.m2_bdj_objective_admissions
         WHERE assessment_id = :assessment_id
           AND confirmation_id = :confirmation_id
           AND confirmation_revision = :revision
           AND decision = :decision
           AND objective_id IS NOT NULL
        UNION
        SELECT 'proposal:' || d.proposal_id::text AS identity
          FROM public.m2_bdj_objective_decisions d
          JOIN public.m2_bdj_objective_proposals p
            ON p.proposal_id = d.proposal_id
         WHERE p.assessment_id = :assessment_id
           AND d.confirmation_id = :confirmation_id
           AND p.confirmation_revision = :revision
           AND d.decision = 'APPROVED'
    ) authorised
"""


def _refused(code: str, status: int = 409) -> HTTPException:
    return HTTPException(status_code=status, detail={'code': code})


@router.get('/assessments/{assessment_id}/stage5/composed-questionnaire')
def composed_questionnaire(
        assessment_id: UUID,
        expected_revision: Annotated[int, Query(ge=0)],
        confirmation_id: UUID,
        user: Owner,
        response: Response) -> dict:
    """The composed questionnaire for one assessment at one revision.

    Read-only: writes nothing, calls no model, grants no authority.
    """
    response.headers['Cache-Control'] = 'no-store'

    with m2_session_for(user.user_id) as session:
        row = session.execute(
            text("""
                SELECT id, owner_user_id, revision, confirmed_revision
                  FROM public.m2_assessments
                 WHERE id = :assessment_id
            """),
            {'assessment_id': str(assessment_id)},
        ).mappings().first()

        # RLS already filters to the caller; this is the explicit second check so
        # a policy change cannot silently widen the read.
        if row is None or str(row['owner_user_id']) != str(user.user_id):
            raise _refused('COMPOSITION_ASSESSMENT_NOT_FOUND', 404)
        if row['revision'] != expected_revision:
            raise _refused('COMPOSITION_REVISION_STALE')
        if row['confirmed_revision'] != expected_revision:
            raise _refused('COMPOSITION_CONFIRMATION_REQUIRED')

        confirmation = session.execute(
            text("""
                SELECT id, assessment_revision
                  FROM public.m2_confirmation_snapshots
                 WHERE id = :confirmation_id
                   AND assessment_id = :assessment_id
            """),
            {'confirmation_id': str(confirmation_id),
             'assessment_id': str(assessment_id)},
        ).mappings().first()
        if confirmation is None:
            raise _refused('COMPOSITION_CONFIRMATION_NOT_FOUND', 404)
        if confirmation['assessment_revision'] != expected_revision:
            raise _refused('COMPOSITION_CONFIRMATION_STALE')

        declarations = composition.load_declarations(
            session,
            assessment_id=assessment_id,
            revision=expected_revision,
            confirmation_id=confirmation_id,
        )
        context = declarations['context']

        admitted = session.execute(
            text(_AUTHORISED_SQL),
            {'assessment_id': str(assessment_id),
             'confirmation_id': str(confirmation_id),
             'revision': expected_revision,
             'decision': ADMITTED_DECISION},
        ).mappings().first()
        admitted_count = int(admitted['n']) if admitted else 0

        # Read candidates in the same session and transaction that just verified
        # the revision, so a header from one revision cannot be combined with
        # candidate rows from another.
        readback = list_candidates_in_session(
            session, actor_id=user.user_id, assessment_id=assessment_id,
        )

    values = build_slot_values(
        study_area=declarations['study_area'],
        concept_version=declarations['concept_version'],
        priced_offer=declarations['priced_offer'],
    )

    try:
        populated = PreviewQuestionCatalogue.load().populate(values)
    except PreviewCatalogueError as exc:
        raise _refused(str(exc), 503) from None

    composed = composition.compose(
        populated=populated,
        candidates=readback['candidates'],
        assessment_id=str(assessment_id),
        confirmation_id=str(confirmation_id),
        revision=expected_revision,
        declarations={
            'slot_values': values,
            'context_available': context is not None,
            'context_id': str(context['context_id']) if context is not None else None,
            'context_packet_hash': context['packet_hash'] if context is not None else None,
        },
        admitted_objective_count=admitted_count,
    )

    # Composition validity and publication authority are different questions.
    # A composition can now reach zero blocking requirements, which previously
    # left ``ready: False`` with an empty ``blockers`` list and no stated reason
    # -- a verdict that could not be audited. ``reasons`` names the authority
    # that is still missing, so an empty ``blockers`` list is never read as
    # "publishable".
    composition_blockers = [
        requirement['code']
        for requirement in composed['unresolved_requirements']
        if requirement.get('blocking')
    ]
    counts = composed['counts']
    readiness_reasons = []
    if composition_blockers:
        readiness_reasons.append('COMPOSITION_BLOCKERS_UNRESOLVED')
    if counts['approved_fixed_core'] < counts['fixed_core']:
        readiness_reasons.append('FIXED_CORE_NOT_APPROVED')
    readiness_reasons.append('RELEASE_AUTHORIZATION_ABSENT')

    composed.update({
        'admitted_objective_count': admitted_count,
        # Publication is a separate decision from composition validity. This
        # states the blockers rather than implying readiness.
        'publication_readiness': {
            'ready': False,
            'blockers': composition_blockers,
            'reasons': readiness_reasons,
            'approved_fixed_core': counts['approved_fixed_core'],
            'fixed_core': counts['fixed_core'],
            'detail': (
                'Composition and publication are different decisions. Nothing in '
                'this document is scientifically accepted or authorised for '
                'fielding, so it cannot be published.'
            ),
        },
        **no_authority(),
    })
    return composed
