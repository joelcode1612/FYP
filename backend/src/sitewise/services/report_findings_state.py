"""Section 03's source of truth: does a business finding exist for this assessment?

Why this module exists
----------------------
Section 03 used to assert ``evidence_status: PRESENT`` unconditionally and print
*"Business-finding decisions are recorded for this assessment and withheld"* —
while the readback state it carried was ``null``. Nothing had been read. A reader
was told that withheld findings existed when the report did not know whether any
finding existed at all, and the two errors point in opposite directions: one
overstates what the business has been told, the other hides that an evaluation
may simply never have run.

Five states are therefore kept apart, because they call for five different
sentences:

``NO_FINDINGS_RECORDED``
    No evaluation row and no source material. There is nothing to withhold.
``EVALUATION_NOT_EXECUTED``
    Source material exists but no evaluation has run. An absence of result, not
    a result of zero.
``ZERO_FINDINGS_VALID``
    An evaluation ran and produced no finding. A real, reportable zero.
``FINDINGS_ACCEPTED_WITHHELD``
    Findings exist and at least one was approved for research; the report is not
    authorized to release them.
``FINDINGS_WITHHELD``
    Findings exist and none has been approved; the report is not authorized.

``FINDINGS_STATE_UNESTABLISHED`` is the composer's default when this loader
could not run at all. It is never upgraded to "present".

What it reads, and what it does not
-----------------------------------
Only identity and counts: whether an ``m2_bdj_evaluations`` row exists at the
confirmed revision, how many ``m2_bdj_findings`` rows exist, and how many are
``APPROVED``. It never reads ``explanation``, ``not_proven`` or ``next_action``,
so it cannot leak finding text into a report that is not authorized to show it.
"""
from __future__ import annotations

from typing import Any

from sqlalchemy import text

#: The M2 tables are RLS-scoped on ``project1.actor_id``; binding it here keeps
#: the predicate transaction-local and off any pooled connection.
_BIND = text("SELECT set_config('project1.actor_id', :actor, true)")

_REVISION_SQL = text(
    'SELECT revision, confirmed_revision FROM public.m2_assessments WHERE id = :id'
)

_EVALUATION_SQL = text(
    'SELECT id, evaluator_version, assessment_revision, created_at '
    '  FROM public.m2_bdj_evaluations '
    ' WHERE assessment_id = :assessment AND assessment_revision = :revision '
    ' ORDER BY created_at DESC LIMIT 1'
)

_FINDING_COUNT_SQL = text(
    'SELECT count(*) AS total, '
    "       count(*) FILTER (WHERE review_state = 'APPROVED') AS approved "
    '  FROM public.m2_bdj_findings '
    ' WHERE assessment_id = :assessment AND assessment_revision = :revision'
)


def _unavailable(reason: str, detail: str) -> dict:
    return {'state': 'FINDINGS_STATE_UNESTABLISHED',
            'reason_code': reason, 'detail': detail,
            'evaluation_id': None, 'run_id': None, 'attempt_id': None,
            'finding_count': None, 'accepted_count': None,
            'readback_state': None, 'source_fingerprint': None}


def load_findings_state(
    session: Any, *, actor_id: Any, m2_assessment_id: str | None,
    has_measurement: bool = False,
) -> dict:
    """Establish whether findings exist for one M2 assessment, at its revision.

    ``session`` must be an M2-bound session. ``has_measurement`` says whether the
    questionnaire association resolved a frozen snapshot: it is what separates
    "the evaluation never ran on data that exists" from "there is no data and no
    evaluation". Both are absences, and they are different absences.

    Every failure degrades to ``FINDINGS_STATE_UNESTABLISHED``: a report must not
    claim a finding exists because a query failed, and must not claim one does
    not.
    """
    if not m2_assessment_id:
        return {'state': 'NO_FINDINGS_RECORDED',
                'reason_code': 'NO_M2_LINK',
                'detail': 'This assessment has no confirmed M2 research record, '
                          'so no finding evaluation can exist for it.',
                'evaluation_id': None, 'run_id': None, 'attempt_id': None,
                'finding_count': None, 'accepted_count': None,
                'readback_state': None, 'source_fingerprint': None}

    try:
        session.execute(_BIND, {'actor': str(actor_id)})
        assessment = session.execute(
            _REVISION_SQL, {'id': str(m2_assessment_id)}).mappings().first()
        if assessment is None:
            session.rollback()
            return _unavailable(
                'M2_ASSESSMENT_NOT_READABLE',
                'The M2 assessment this report is bound to could not be read, so '
                'the report does not know whether findings exist.')

        revision = assessment['confirmed_revision']
        evaluation = session.execute(
            _EVALUATION_SQL,
            {'assessment': str(m2_assessment_id), 'revision': revision},
        ).mappings().first()
        counts = session.execute(
            _FINDING_COUNT_SQL,
            {'assessment': str(m2_assessment_id), 'revision': revision},
        ).mappings().first() or {'total': 0, 'approved': 0}
        session.rollback()
    except Exception as exc:  # noqa: BLE001 - a report never fails on this read
        try:
            session.rollback()
        except Exception:  # noqa: BLE001 - the original failure is the useful one
            pass
        return _unavailable(
            'FINDINGS_STORE_UNAVAILABLE',
            'The finding store could not be read while this report was composed, '
            f'so nothing is claimed about findings. ({type(exc).__name__})')

    total = int(counts['total'] or 0)
    approved = int(counts['approved'] or 0)

    if evaluation is None:
        if has_measurement:
            state, reason = 'EVALUATION_NOT_EXECUTED', 'EVALUATION_NOT_EXECUTED'
        else:
            state, reason = 'NO_FINDINGS_RECORDED', 'NO_FINDINGS_RECORDED'
    elif total == 0:
        state, reason = 'ZERO_FINDINGS_VALID', 'ZERO_FINDINGS_VALID'
    elif approved > 0:
        state, reason = 'FINDINGS_ACCEPTED_WITHHELD', 'FINDINGS_ACCEPTED_WITHHELD'
    else:
        state, reason = 'FINDINGS_WITHHELD', 'FINDINGS_WITHHELD'

    evaluation_row = dict(evaluation) if evaluation is not None else {}

    return {
        'state': state,
        'reason_code': reason,
        'detail': None,
        'evaluation_id': (str(evaluation_row['id']) if evaluation_row.get('id')
                          else None),
        'evaluator_version': evaluation_row.get('evaluator_version'),
        'run_id': None,
        'attempt_id': None,
        'assessment_revision': revision,
        'finding_count': total,
        'accepted_count': approved,
        'readback_state': reason,
        'source_fingerprint': None,
    }
