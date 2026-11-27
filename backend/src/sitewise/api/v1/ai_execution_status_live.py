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
* the domain table for each purpose — whether a governed write landed, *and
  whether it can be attributed to this attempt*;
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
* No ``DISPATCHED`` milestone. See ``runs.MILESTONES`` — nothing durable records
  dispatch, so the contract does not claim it (CP-PROG-03).

Owner scoping
-------------
The ledger is read under the restricted execution principal and filtered by
``owner_user_id``; the domain counts are read through the M2 principal, whose
policies are anchored on the acting owner. A foreign assessment yields an empty
reading, not another owner's run.

Identity (CP-PROG-01)
---------------------
Every purpose is read with ``current_revision`` so an attempt made before the
owner re-confirmed M2 is reported as ``stale`` instead of as the current
execution. Domain counts are attempt-bound where the schema allows it: QG
candidates carry ``run_id``/``attempt_no``, BDJ proposals do not, so BDJ
persistence is reported as *unattributable* and can never complete the
``PERSISTED`` milestone for a new attempt.
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

#: Contract identity. Bumped when a consumer-visible field changes meaning.
#: ``/2`` adds attempt-bound persistence, the revision guard, per-milestone
#: status and the reported timing policy. Additive only: every ``/1`` field is
#: still present with its original meaning.
CONTRACT = 'sitewise-ai-execution-status/2'

#: The two purposes the owner asked to see. ``EXPLANATION`` runs exist in the
#: ledger but belong to the Stage 4 report surface, not to this card.
PURPOSES = (
    ('BDJ', 'BDJ'),
    ('QG', 'QG'),
)

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

#: Baseline attribution capability, per purpose.
#:
#: QG candidates carry ``run_id`` and ``attempt_no``, so a QG figure can always
#: be narrowed to an attempt. BDJ objective proposals carry neither *until*
#: migration 20261126_01 adds them — ``evaluation_id`` is a fresh ``uuid4()`` per
#: evaluation and joins to no ledger row (measured: 0 of 20 rows join
#: ``project1_ai.runs.id``). The constant therefore records the pre-migration
#: baseline; the route upgrades BDJ at request time when the columns exist
#: (``_has_bdj_identity``). Keeping the baseline here means the limitation is
#: visible in one place and cannot be quietly "fixed" by counting harder.
ATTRIBUTABLE = {'BDJ': False, 'QG': True}


def _current_revision(engine, assessment_id) -> int | None:
    """The M2 revision the owner is looking at, or ``None`` if unreadable.

    ``None`` disables the staleness qualifier rather than guessing a revision:
    an unreadable revision must not silently make every execution look current,
    and it must not make every execution look stale either.
    """
    try:
        with engine.connect() as conn:
            value = conn.execute(text(
                'SELECT revision FROM public.m2_assessments WHERE id = :a'),
                {'a': str(assessment_id)}).scalar()
            return None if value is None else int(value)
    except Exception:  # noqa: BLE001 - an unreadable revision is "not checked"
        return None


#: Whether the proposals table carries the attempt identity yet (proposed
#: migration 20261126_01). Cached: the answer cannot change while the process
#: runs except by applying that migration, which restarts the app anyway.
_BDJ_IDENTITY: bool | None = None


def _has_bdj_identity(conn) -> bool:
    """Whether a BDJ proposal row can carry its attempt identity.

    A probe that cannot run (no ``information_schema``) answers False: an
    unattributable reading is the conservative answer, and it is already what the
    projection reports when the migration is absent.
    """
    global _BDJ_IDENTITY
    if _BDJ_IDENTITY is None:
        try:
            _BDJ_IDENTITY = conn.execute(text(
                "SELECT 1 FROM information_schema.columns"
                " WHERE table_schema='public'"
                "   AND table_name='m2_bdj_objective_proposals'"
                "   AND column_name='run_id'")).first() is not None
        except Exception:  # noqa: BLE001 - unknown schema is "cannot bind"
            return False
    return _BDJ_IDENTITY


def _domain_counts(engine, actor_id, assessment_id, *, qg_run_id, qg_attempt_no,
                   bdj_run_id=None, bdj_attempt_no=None) -> dict:
    """How many governed rows each purpose has written for this assessment.

    Read through the M2 principal so the owner policies apply. A failure here is
    reported as "unknown", never as zero: zero would read as "nothing was
    persisted", which is a much stronger claim than "the count could not be
    read".

    The QG figure is returned twice: assessment-wide, and narrowed to the exact
    attempt when that attempt is known. Only the narrow figure may complete the
    ``PERSISTED`` milestone.
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
            candidates, pending, run_bound = conn.execute(text("""
                SELECT count(*),
                       count(*) FILTER (
                           WHERE candidate_state NOT IN ('VALIDATED', 'ABSTAINED')),
                       count(*) FILTER (WHERE run_id IS NOT NULL)
                  FROM public.m2_qg_candidates
                 WHERE assessment_id = :a
            """), {'a': str(assessment_id)}).one()

            # Attempt-bound QG counts. Absent a run id there is nothing to bind
            # to, and the caller is told so rather than shown the wide figure.
            qg_bound = {'persisted': 0, 'pending_validation': 0, 'bound': False}
            if qg_run_id is not None and qg_attempt_no is not None:
                bound_persisted, bound_pending = conn.execute(text("""
                    SELECT count(*),
                           count(*) FILTER (
                               WHERE candidate_state NOT IN ('VALIDATED', 'ABSTAINED'))
                      FROM public.m2_qg_candidates
                     WHERE assessment_id = :a
                       AND run_id = :run
                       AND attempt_no = :n
                """), {'a': str(assessment_id), 'run': str(qg_run_id),
                       'n': int(qg_attempt_no)}).one()
                qg_bound = {'persisted': int(bound_persisted),
                            'pending_validation': int(bound_pending),
                            'bound': True}

            # The same narrowing for BDJ, available only once the identity
            # columns exist. Before that the answer stays "not attributable",
            # which is what stops six historical proposals from completing a
            # brand-new attempt (CP-PROG-01 / CP-FINAL-02).
            bdj_bound = {'persisted': 0, 'pending_validation': 0, 'bound': False}
            if (bdj_run_id is not None and bdj_attempt_no is not None
                    and _has_bdj_identity(conn)):
                bdj_persisted = conn.execute(text("""
                    SELECT count(*)
                      FROM public.m2_bdj_objective_proposals
                     WHERE assessment_id = :a
                       AND run_id = :run
                       AND attempt_no = :n
                """), {'a': str(assessment_id), 'run': str(bdj_run_id),
                       'n': int(bdj_attempt_no)}).scalar_one()
                bdj_bound = {'persisted': int(bdj_persisted),
                             'pending_validation': 0, 'bound': True}
    except WorkflowHeld:
        raise
    except Exception:  # noqa: BLE001 - a count failure must not read as zero
        return {'readable': False,
                'BDJ': {'persisted': 0, 'pending_validation': 0,
                        'approved': 0, 'admitted': 0,
                        'bound': {'persisted': 0, 'pending_validation': 0,
                                  'bound': False}},
                'QG': {'persisted': 0, 'pending_validation': 0,
                       'run_bound': 0, 'bound': {'persisted': 0,
                                                 'pending_validation': 0,
                                                 'bound': False}}}
    return {
        'readable': True,
        'BDJ': {'persisted': int(proposals),
                'pending_validation': 0,
                'approved': int(approved),
                'admitted': int(admitted),
                'bound': bdj_bound},
        'QG': {'persisted': int(candidates), 'pending_validation': int(pending),
               'run_bound': int(run_bound), 'bound': qg_bound},
    }


@router.get('/assessments/{assessment_id}/ai-execution-status')
def read_execution_status(assessment_id: UUID, user: Owner, response: Response,
                          ledger_engine: AuthorizedLedgerEngine,
                          m2_engine: AuthorizedProposalStorageEngine,
                          revision: int | None = None,
                          objective_id: str | None = None):
    """Per-purpose execution state, derived from the persisted ledger.

    ``revision`` is optional and defaults to the assessment's current M2
    revision. Supplying it explicitly lets a caller ask "was this execution made
    against revision N?" rather than "is it current?".

    ``objective_id`` scopes the QG reading to one approved additional research
    objective. Without it the QG rail is a stage-wide reading, which is correct
    for a single objective and misleading for two: it shows the newest attempt
    whichever objective produced it (CP-FINAL-04).
    """
    response.headers['Cache-Control'] = 'no-store'
    actor = user.user_id

    # Resolve the revision *before* the ledger is read.
    #
    # This used to happen after the loop below, which made the staleness
    # qualifier dead in production: `execution_status` received
    # `current_revision=None`, `is_stale` treats "unknown revision" as "not
    # checked" (correctly — an unreadable revision must not mark everything
    # stale), and every execution was therefore reported `stale: false`. The
    # response then printed the resolved revision beside that `false`, so a
    # superseded execution looked like a current one that had passed the check
    # (CP-PROG-01 / CP-P04). The client sends no `revision`, so this was the
    # default path, not an edge case.
    if revision is None:
        revision = _current_revision(m2_engine, assessment_id)

    # Ledger first: the QG domain counts have to be narrowed to the attempt the
    # ledger names, so the identity is needed before the counts are read.
    statuses: dict[str, dict] = {}
    for purpose, stage in PURPOSES:
        try:
            statuses[purpose] = runs.execution_status(
                ledger_engine, actor, assessment_id, stage=stage,
                # Revision binds BDJ; QG records the sentinel 0 on purpose, so
                # comparing it with a real revision would call every QG
                # execution stale. QG currency is a fingerprint comparison.
                revision_bound=(stage != 'QG'),
                current_revision=revision,
                objective_id=(objective_id if purpose == 'QG' else None))
        except WorkflowHeld as exc:
            # A ledger that cannot be read is not a stage that never ran.
            statuses[purpose] = {
                'stage': stage, 'state': 'UNKNOWN_OUTCOME',
                'reason': str(exc), 'run_id': None, 'attempt_no': None,
                'attempts_reserved': 0, 'reserved_at': None,
                'receipt_outcome': None, 'receipt_at': None,
                'assessment_revision': None, 'stale': False,
                'revision_bound': (stage != 'QG'),
                'currency_basis': ('ASSESSMENT_REVISION' if stage != 'QG'
                                   else 'SOURCE_FINGERPRINT'),
                'objective_id': objective_id if purpose == 'QG' else None,
                'identity_basis': 'UNAVAILABLE',
                'milestones': runs.milestones('UNKNOWN_OUTCOME'),
                'ledger_readable': False,
            }

    qg = statuses['QG']
    bdj = statuses['BDJ']
    domain = _domain_counts(m2_engine, actor, assessment_id,
                            qg_run_id=qg.get('run_id'),
                            qg_attempt_no=qg.get('attempt_no'),
                            bdj_run_id=bdj.get('run_id'),
                            bdj_attempt_no=bdj.get('attempt_no'))
    # Capability, not this reading's outcome: "can BDJ persistence be bound to an
    # attempt at all in this schema?" The per-purpose flag below says whether
    # *this* figure is bound, which is a different question.
    try:
        with m2_engine.connect() as _conn:
            bdj_capable = _has_bdj_identity(_conn)
    except Exception:  # noqa: BLE001 - unknown capability is reported as absent
        bdj_capable = False

    purposes = []
    for purpose, stage in PURPOSES:
        status = statuses[purpose]
        counts = domain[purpose]
        attributable = bool(ATTRIBUTABLE[purpose])
        if purpose == 'QG':
            bound = counts.get('bound') or {}
            persisted = int(bound.get('persisted', 0))
            pending = int(bound.get('pending_validation', 0))
            # A QG count is attempt-bound only when the ledger named the attempt
            # *and* the rows carry that binding. Otherwise it is a true figure
            # about the assessment that cannot complete this attempt.
            attributable = bool(bound.get('bound'))
        else:
            bound = counts.get('bound') or {}
            persisted = int(bound.get('persisted', 0))
            pending = 0
            attributable = bool(bound.get('bound'))
        refined = runs.refine_with_domain(
            status, persisted=persisted, pending_validation=pending,
            attributable=attributable)
        purposes.append({
            'purpose': purpose,
            **refined,
            # Say what the number above was counted from. Without this, a
            # "Persisted" rail and a "NO_CURRENT_RESULT" status line read as a
            # contradiction when they are two true facts about two stores.
            'domain_store': DOMAIN_STORES[purpose],
            # The wide figure is reported beside the narrow one so the interface
            # can say "6 stored, none attributable to this attempt" instead of
            # silently dropping history.
            'domain_assessment_wide': {
                'persisted': counts.get('persisted', 0),
                'pending_validation': counts.get('pending_validation', 0),
                'run_bound': counts.get('run_bound', 0),
            },
        })

    return {
        'contract': CONTRACT,
        'assessment_id': str(assessment_id),
        'current_revision': revision,
        # Echoed so a client polling two objectives can discard a response that
        # belongs to the other one (CP-FINAL-04).
        'objective_id': objective_id,
        'objective_scoped': objective_id is not None,
        'ledger': ('project1_ai.runs, project1_ai.attempts, '
                   'project1_ai.attempt_receipts'),
        # The rail is refined by the attempt-bound count named in each purpose;
        # the current-result line reads ``result_store`` instead. They are
        # different tables for BDJ (DD-124).
        'result_store': BDJ_RESULT_STORE,
        'states': list(runs.EXECUTION_STATES),
        # Four, not five. ``DISPATCHED`` is absent because nothing durable
        # records it; listed explicitly so a client cannot mistake the omission
        # for an oversight and draw a fifth tick.
        'milestones': list(runs.MILESTONES),
        'unprovable_milestones': ['DISPATCHED'],
        'timing': {
            'provider_timeout_seconds': runs.provider_timeout_seconds(),
            'grace_seconds': int(runs.in_flight_grace().total_seconds()),
        },
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
            # Whether *this* figure is bound to the attempt, and separately
            # whether this schema can bind one at all. Before the identity
            # migration both are false and the rail stops at Returned; after it,
            # a bound figure can complete Persisted and an unbound one still
            # cannot.
            'persistence_attributable': bool(
                (domain['BDJ'].get('bound') or {}).get('bound')),
            'attribution_capability': ('EXACT' if bdj_capable
                                       else 'UNAVAILABLE'),
        },
        'scientific_approval': False,
        'fielding_authorized': False,
    }
