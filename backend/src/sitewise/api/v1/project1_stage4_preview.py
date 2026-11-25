"""Read-only Stage 4 preview surface for the governed Q01-Q13 questionnaire.

Scope
-----
This route answers one question: *what does the fixed core questionnaire look
like once the owner's own M2 declarations are substituted into its governed
wording?* It is a **preview**. It writes nothing, calls no model, and grants no
authority.

What it deliberately does not do
--------------------------------
* It does not touch ``QuestionBank``. BD-01 reuse and BD-02 no-equivalent are
  claims about approval; none of Q01-Q13 carries an approval, so no such claim
  may be made from here. ``PreviewQuestionCatalogue.lookup`` raises if anything
  tries.
* It does not decide respondent routing. Template population and respondent
  lifecycle are separate (R1): a question rendered here is not thereby shown to
  any respondent, and an unresolved slot is not a respondent-facing absence.
* It does not expose Approve/Reject. The fixed 13 are not individually
  reviewable here, because the decision that matters for them is a scientific
  approval recorded elsewhere, not an owner toggle.

Scoping
-------
The assessment, revision and confirmation are all re-checked against the
caller's own rows inside an owner-bound session, so a caller cannot preview
another account's wording or a superseded revision. The response carries
``no_authority()`` plus explicit ``fielding_authorized=False``.
"""
from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy import text

from sitewise.cq_successor.preview_catalogue import (
    PreviewCatalogueError, PreviewQuestionCatalogue, build_slot_values)
from sitewise.db.m2_session import m2_session_for
from sitewise.dependencies import AuthenticatedUser, require_entrepreneur
from sitewise.services import questionnaire_composition as composition
from sitewise.project1.contracts import no_authority

router = APIRouter()

Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]


def _refused(code: str, status: int = 409) -> HTTPException:
    return HTTPException(status_code=status, detail={'code': code})


@router.get('/assessments/{assessment_id}/stage4/preview-questionnaire')
def preview_questionnaire(
        assessment_id: UUID,
        expected_revision: Annotated[int, Query(ge=0)],
        confirmation_id: UUID,
        user: Owner,
        response: Response) -> dict:
    """Populate the governed Q01-Q13 wording from this owner's declarations.

    Read-only. Returns all 13 questions regardless of population status, because
    hiding an unpopulated question would misreport the governed questionnaire as
    shorter than it is (R5).
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

        # RLS already filters to the caller; this is the second, explicit check
        # so a policy change cannot silently widen the read.
        if row is None or str(row['owner_user_id']) != str(user.user_id):
            raise _refused('PREVIEW_ASSESSMENT_NOT_FOUND', 404)
        if row['revision'] != expected_revision:
            raise _refused('PREVIEW_REVISION_STALE')
        if row['confirmed_revision'] != expected_revision:
            raise _refused('PREVIEW_CONFIRMATION_REQUIRED')

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
            raise _refused('PREVIEW_CONFIRMATION_NOT_FOUND', 404)
        if confirmation['assessment_revision'] != expected_revision:
            raise _refused('PREVIEW_CONFIRMATION_STALE')

        # DD-093 Option A: the build receipt names the authoritative context.
        # Selecting the newest packet by ``created_at`` let a stray rebuild
        # outrank the context the workflow actually produced.
        context = composition.resolve_current_context(
            session, assessment_id=assessment_id,
            confirmation_id=confirmation_id, revision=expected_revision)

        answers = session.execute(
            text("""
                SELECT DISTINCT ON (iv.item_key)
                       iv.item_key, ar.answer_state, ar.value_json
                  FROM public.m2_answer_revisions ar
                  JOIN public.m2_item_versions iv ON iv.id = ar.item_version_id
                 WHERE ar.assessment_id = :assessment_id
                   AND ar.assessment_revision <= :revision
                   AND iv.item_key IN ('M2V2-01', 'M2V2-14')
                 ORDER BY iv.item_key, ar.assessment_revision DESC
            """),
            {'assessment_id': str(assessment_id), 'revision': expected_revision},
        ).mappings().all()

    by_item = {r['item_key']: r for r in answers}

    study_area = None
    area_row = by_item.get('M2V2-01')
    if area_row is not None and area_row['answer_state'] == 'ANSWERED':
        study_area = area_row['value_json']

    priced_offer = None
    offer_row = by_item.get('M2V2-14')
    if offer_row is not None and offer_row['answer_state'] == 'ANSWERED':
        priced_offer = offer_row['value_json']

    concept_version = None
    if context is not None:
        packet = context['packet_json'] or {}
        concept = packet.get('concept') if isinstance(packet, dict) else None
        if isinstance(concept, dict):
            concept_version = concept.get('version')
        concept_version = concept_version or context['concept_version']

    values = build_slot_values(
        study_area=study_area,
        concept_version=concept_version,
        priced_offer=priced_offer,
    )

    try:
        catalogue = PreviewQuestionCatalogue.load()
        populated = catalogue.populate(values)
    except PreviewCatalogueError as exc:
        raise _refused(str(exc), 503) from None

    payload = populated.as_payload()
    payload.update({
        'assessment_id': str(assessment_id),
        'confirmation_id': str(confirmation_id),
        'assessment_revision': expected_revision,
        'context_id': str(context['context_id']) if context is not None else None,
        'context_packet_hash': (
            context['packet_hash'] if context is not None else None
        ),
        'context_available': context is not None,
        'slot_values': values,
        'slot_sources': {
            'named_area': 'M2V2-01 study_area',
            'concept_card_version': 'BCB concept.version',
            'exact_rm_price': 'M2V2-14 amount_myr',
            'product_spec': 'M2V2-14 product_ref + size_quantity + charges',
            'defined_item': 'M2V2-14 product_ref',
        },
        # Section A has no per-question review control by design.
        'section': 'A_FIXED_CORE',
        **no_authority(),
    })
    return payload
