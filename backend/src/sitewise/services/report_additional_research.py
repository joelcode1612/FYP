"""Section B inputs for the report: admitted objectives and their questions.

Why this module exists
----------------------
The report's Section 06 ("Additional questions") could only list question
*strings* typed by the entrepreneur during question review. Everything the
report needed in order to say whether an additional question had been admitted,
reviewed or measured lived in ``m2_bdj_objective_proposals``,
``m2_bdj_objective_admissions``, ``m2_qg_candidates`` and
``m2_qg_candidate_reviews`` — and nothing read them for reporting.

What it reads, and what it refuses to infer
-------------------------------------------
It reads the owner's own question-design records and reuses
``services.questionnaire_composition.build_additional_item`` so the report
describes an item exactly as the composer does. That is the point: two
descriptions of one candidate would drift.

It does not read a respondent answer, and it does not claim a measurement.
Section B has no defined EE-01 measurement contract yet, so ``measurement_state``
is ``UNMEASURED`` for every item and the measurement *attributes* the report
cannot obtain (level, analysis method, denominator) are left as ``None`` rather
than filled with a plausible default.

Every failure degrades to a named state. A report must not fail because the
M2 store is unreachable, and "could not read" must stay distinguishable from
"read it and Section B is empty".
"""
from __future__ import annotations

from typing import Any, Mapping

from sqlalchemy import text

#: Reported for every Section B item until the upstream measurement contract
#: defines one. Not a zero, not a failure: an unestablished attribute.
UNMEASURED = 'UNMEASURED'

_OBJECTIVES_SQL = text(
    # ``m2_bdj_objective_proposals`` carries no ``objective_id``: the objective
    # identity is minted by the admission row, so it is read from there and
    # stays NULL for a proposal that was never admitted. Selecting a
    # ``p.objective_id`` would fail the whole read on a correct schema.
    "SELECT p.proposal_id, p.research_objective, p.problem, "
    "       p.review_state, p.confirmation_revision, p.source_fingerprint, "
    "       a.admission_id, a.decision AS admission_decision, a.objective_id "
    "         AS admitted_objective_id "
    "  FROM m2_bdj_objective_proposals p "
    "  LEFT JOIN m2_bdj_objective_admissions a "
    "         ON a.proposal_id = p.proposal_id "
    " WHERE p.assessment_id = :assessment "
    " ORDER BY p.created_at ASC"
)


def _objective(row: Mapping) -> dict:
    return {
        'proposal_id': str(row['proposal_id']) if row.get('proposal_id') else None,
        # The objective identity exists only on an admission. A proposal that
        # was never admitted has none, and inventing one would let the report
        # describe an unauthorised objective as if it were authorized.
        'objective_id': row.get('admitted_objective_id'),
        'research_objective': row.get('research_objective'),
        'problem': row.get('problem'),
        'review_state': row.get('review_state'),
        'confirmation_revision': row.get('confirmation_revision'),
        'source_fingerprint': row.get('source_fingerprint'),
        'admission_id': (str(row['admission_id'])
                         if row.get('admission_id') else None),
        'admission_decision': row.get('admission_decision'),
        'admitted': bool(row.get('admission_id')),
    }


def _item(candidate: Mapping, order: int) -> dict:
    """One candidate as the report may describe it.

    ``build_additional_item`` is reused verbatim for the question identity, the
    options and the owner's intended answer. The report adds only the states it
    is responsible for: whether the item was reviewed, and whether a measurement
    exists (it does not).
    """
    from sitewise.services.questionnaire_composition import build_additional_item

    base = build_additional_item(candidate, order=order)
    # An abstained candidate has no wording at all. Rendering its empty stem
    # would print a blank heading that reads as "a question with no text", so
    # the absence is named instead of left blank.
    stem = (base.get('stem') or '').strip()
    if not stem:
        stem = ('No wording recorded — the generator abstained on this '
                'candidate, so there is no question to field.')
    return {
        'candidate_id': base['item_id'],
        'objective_id': base.get('objective_id'),
        'objective_admission_id': base.get('objective_admission_id'),
        'stem': stem,
        'response_format': base.get('response_format'),
        'options': list(base.get('options') or []),
        'owner_intended_options': list(base.get('owner_intended_options') or []),
        'owner_intended_option_scope': base.get('owner_intended_option_scope'),
        'review_decision': base.get('review_decision'),
        'review_recorded_at': base.get('review_recorded_at'),
        'structural_status': base.get('structural_status'),
        'semantic_status': base.get('semantic_status'),
        'measurement_id': base.get('measurement_id'),
        'measurement_version': base.get('measurement_version'),
        # -- the attributes the report cannot obtain yet ----------------------
        # Emitted as None so a consumer sees the same shape and cannot read a
        # missing key as "not applicable". Inventing a level or a denominator
        # here would be a measurement-layer decision taken in the report.
        'measurement_level': None,
        'analysis_method': None,
        'denominator': None,
        'measurement_state': UNMEASURED,
        'fielding_authorized': False,
        'publication_authorized': False,
    }


def load_additional_research(
    session: Any, *, actor_id: Any, m2_assessment_id: str | None,
) -> dict:
    """Read the Section B inputs for one M2 assessment.

    ``session`` must be an M2-bound session (the tables are RLS-scoped on
    ``project1.actor_id``). The actor is bound transaction-locally here so the
    predicate cannot leak onto a pooled connection.
    """
    if not m2_assessment_id:
        return {
            'status': 'UNAVAILABLE',
            'reason_code': 'NO_M2_LINK',
            'detail': 'This assessment has no confirmed M2 research record, so '
                      'no additional research objective can exist for it.',
            'objectives': [], 'items': [],
        }

    try:
        session.execute(
            text("SELECT set_config('project1.actor_id', :actor, true)"),
            {'actor': str(actor_id)},
        )
        rows = session.execute(
            _OBJECTIVES_SQL, {'assessment': str(m2_assessment_id)}).mappings().all()
        objectives = [_objective(dict(row)) for row in rows]

        from sitewise.project1.qg_candidate_read import list_candidates_in_session

        candidates = list_candidates_in_session(
            session, actor_id=actor_id, assessment_id=m2_assessment_id,
        )['candidates']
        items = [_item(candidate, index)
                 for index, candidate in enumerate(candidates, start=1)]
        session.rollback()
    except Exception as exc:  # noqa: BLE001 - a report never fails on this read
        try:
            session.rollback()
        except Exception:  # noqa: BLE001 - the original failure is the useful one
            pass
        return {
            'status': 'UNAVAILABLE',
            'reason_code': 'ADDITIONAL_RESEARCH_UNAVAILABLE',
            'detail': ('The additional-research store could not be read while '
                       'this report was composed, so nothing is claimed about '
                       f'Section B. ({type(exc).__name__})'),
            'objectives': [], 'items': [],
        }

    return {
        'status': 'AVAILABLE',
        'reason_code': None,
        'detail': None,
        'objectives': objectives,
        'items': items,
    }
