"""AI execution status: what the ledger actually recorded, for BDJ and QG.

Why this route exists
---------------------
The existing "AI Execution Status" card told the owner the truth and nothing
else: that the read response it was built from carried no execution status, so
none was claimed. That is honest but useless — the ledger *does* know, it just
had no owner-scoped read.

This route is that read. It composes three facts that are already persisted:

* ``project1_ai.runs`` / ``attempts`` / ``attempt_receipts`` — whether an attempt
  was reserved, and what the provider recorded;
* the domain table for each purpose — whether a governed write landed;
* nothing else.

What it deliberately does not do
--------------------------------
* No percentage. The ledger records discrete states, not fractions, so
  ``progress_percent`` is present and ``null`` rather than an invented number.
* No second ledger and no progress table. If the ledger has no row, the answer is
  ``BLOCKED`` — "no attempt has been reserved" — not an estimate.
* It does not dispatch anything. Reading this never invokes a model, which is
  what makes it safe to poll.
* It grants no authority: ``scientific_approval`` and ``fielding_authorized``
  are false because a progress reading is not a permission.

Owner scoping
-------------
The ledger is read under the restricted execution principal and filtered by
``owner_user_id``; the domain counts are read through the M2 principal, whose
policies are anchored on the acting owner. A foreign assessment yields an empty
reading, not another owner's run.
"""
from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Response
from sqlalchemy import text

from sitewise.dependencies import AuthenticatedUser, require_entrepreneur
from sitewise.project1 import runs
from sitewise.project1.contracts import WorkflowHeld
from sitewise.api.v1.project1_objective_proposals import (
    AuthorizedLedgerEngine, AuthorizedProposalStorageEngine,
)

router = APIRouter()

Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]

#: The two purposes the owner asked to see. ``EXPLANATION`` runs exist in the
#: ledger but belong to the Stage 4 report surface, not to this card.
PURPOSES = (
    ('BDJ', 'BDJ'),
    ('QG', 'QG'),
)


def _domain_counts(engine, actor_id, assessment_id) -> dict:
    """How many governed rows each purpose has written for this assessment.

    Read through the M2 principal so the owner policies apply. A failure here is
    reported as "unknown", never as zero: zero would read as "nothing was
    persisted", which is a much stronger claim than "the count could not be
    read".
    """
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    from sitewise.services.business_context_v1 import ContextRefused

    try:
        with engine.connect() as conn:
            try:
                bind_restricted_principal(conn, actor_id)
            except ContextRefused as exc:
                raise WorkflowHeld(exc.code) from None
            proposals, approved = conn.execute(text("""
                SELECT count(*),
                       count(*) FILTER (WHERE review_state = 'APPROVED')
                  FROM public.m2_bdj_objective_proposals
                 WHERE assessment_id = :a
            """), {'a': str(assessment_id)}).one()
            # Admission is a *different* fact from the owner's approval, and it
            # is recorded in its own table: an approved objective can still be
            # refused as research-unsuitable (BUSINESS_DECISION_REQUIRED). Both
            # numbers are reported so the interface cannot present one as the
            # other (DD-061).
            admitted = conn.execute(text("""
                SELECT count(*) FROM public.m2_bdj_objective_admissions
                 WHERE assessment_id = :a AND decision = 'WORTH_RESEARCHING'
            """), {'a': str(assessment_id)}).scalar_one()
            candidates, pending = conn.execute(text("""
                SELECT count(*),
                       count(*) FILTER (
                           WHERE candidate_state NOT IN ('VALIDATED', 'ABSTAINED'))
                  FROM public.m2_qg_candidates
                 WHERE assessment_id = :a
            """), {'a': str(assessment_id)}).one()
    except WorkflowHeld:
        raise
    except Exception:  # noqa: BLE001 - a count failure must not read as zero
        return {'readable': False,
                'BDJ': {'persisted': 0, 'pending_validation': 0,
                        'approved': 0, 'admitted': 0},
                'QG': {'persisted': 0, 'pending_validation': 0}}
    return {
        'readable': True,
        'BDJ': {'persisted': int(proposals),
                'pending_validation': 0,
                'approved': int(approved),
                'admitted': int(admitted)},
        'QG': {'persisted': int(candidates), 'pending_validation': int(pending)},
    }


#: Which table each purpose's "persisted" figure is counted from, and which
#: table holds its *result*. They are different tables for BDJ because objective
#: proposal generation and the BDJ source evaluation are different pipelines
#: (DD-124): the card used to print a green "Persisted" rail above
#: "NO_CURRENT_RESULT" without saying that the rail counts proposals and the
#: status line reads results. Naming both removes the apparent contradiction
#: without inserting a row into either.
DOMAIN_STORES = {
    'BDJ': 'public.m2_bdj_objective_proposals',
    'QG': 'public.m2_qg_candidates',
}

#: The store the BDJ "current result" line reads. Empty is a real answer here:
#: it means the source evaluation has not been run, not that it was lost.
BDJ_RESULT_STORE = 'project1_ai.bdj_results'


@router.get('/assessments/{assessment_id}/ai-execution-status')
def read_execution_status(assessment_id: UUID, user: Owner, response: Response,
                          ledger_engine: AuthorizedLedgerEngine,
                          m2_engine: AuthorizedProposalStorageEngine):
    """Per-purpose execution state, derived from the persisted ledger."""
    response.headers['Cache-Control'] = 'no-store'
    actor = user.user_id

    domain = _domain_counts(m2_engine, actor, assessment_id)

    purposes = []
    for purpose, stage in PURPOSES:
        try:
            status = runs.execution_status(
                ledger_engine, actor, assessment_id, stage=stage)
        except WorkflowHeld as exc:
            # A ledger that cannot be read is not a stage that never ran.
            purposes.append({
                'purpose': purpose, 'stage': stage, 'state': 'UNKNOWN_OUTCOME',
                'reason': str(exc), 'run_id': None, 'attempt_no': None,
                'attempts_reserved': 0, 'reserved_at': None,
                'receipt_outcome': None, 'receipt_at': None,
                'assessment_revision': None, 'domain': None,
            })
            continue
        counts = domain[purpose]
        purposes.append({
            'purpose': purpose,
            **runs.refine_with_domain(
                status,
                persisted=counts['persisted'],
                pending_validation=counts['pending_validation']),
            # Say what the number above was counted from. Without this, a
            # "Persisted" rail and a "NO_CURRENT_RESULT" status line read as a
            # contradiction when they are two true facts about two stores.
            'domain_store': DOMAIN_STORES[purpose],
        })

    return {
        'assessment_id': str(assessment_id),
        'ledger': ('project1_ai.runs, project1_ai.attempts, '
                   'project1_ai.attempt_receipts'),
        # The rail is refined by the domain count named in each purpose; the
        # current-result line reads ``result_store`` instead. They are different
        # tables for BDJ (DD-124).
        'result_store': BDJ_RESULT_STORE,
        'states': list(runs.EXECUTION_STATES),
        'purposes': purposes,
        # Present and null on purpose: an omitted key would look like an
        # oversight, and a number here would be invented.
        'progress_percent': None,
        'progress_note': ('No percentage is reported. The ledger records '
                          'discrete states, not fractional progress.'),
        'domain_readable': domain['readable'],
        # The owner's approval and the scientific admission are reported side by
        # side because they are different acts with different outcomes. Stage 3
        # previously counted a legacy list that never held a proposal, so it
        # printed "0 / 0 approved" beside a card saying "Approved by you"
        # (DD-061).
        'bdj_objectives': {
            'proposed': domain['BDJ']['persisted'],
            'approved': domain['BDJ']['approved'],
            'admitted': domain['BDJ']['admitted'],
            'readable': domain['readable'],
        },
        'scientific_approval': False,
        'fielding_authorized': False,
    }
