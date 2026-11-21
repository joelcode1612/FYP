"""HTTP-facing composition for the V2.0 BCB -> QG candidate path (CP-04).

Why this module exists
----------------------
``DirectQgService`` and the retry cycle were complete and tested, but nothing in
the HTTP layer called them: the QG candidate engine had no route, so an
entrepreneur could never receive a candidate. This service is the missing
caller. It does not re-implement the engine, the contract or the repository; it
binds them in the order the contracts require and refuses when they disagree.

The ordering constraint that matters
------------------------------------
A candidate version may only be superseded after its parent has a terminal
``REQUEST_REVISION`` decision: the database enforces it (``supersedes`` is
UNIQUE and ``m2_repository.persist_candidate`` checks the parent's decision),
and ``record_owner_review`` refuses a candidate that already has a child. So a
revision is always: review the parent -> record ``REQUEST_REVISION`` -> generate
the child with ``supersedes=parent``. ``revise`` therefore refuses to generate
unless that decision is already persisted; it never writes the decision itself.

Integrity cross-checks
----------------------
The persisted research objective and the persisted business context are two
records of one event. If they disagree, the candidate would be authored against
a different confirmation, objective or revision than the one the caller
believes it is reviewing. None of those is silently repaired: each returns a
stable conflict code and nothing is generated, reserved or persisted.

An abstention is a result
-------------------------
``VALID_ABSTENTION`` means the model reported which confirmed facts are missing.
There is no question to persist, so nothing is persisted, and the caller gets
the missing-fact codes. It is a 200 at the HTTP layer, not an error.
"""
from __future__ import annotations

import json
from uuid import UUID

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.project1 import budget
from sitewise.project1.budget import BudgetExhausted
from sitewise.project1.contracts import WorkflowHeld, no_authority
from sitewise.project1.direct_qg_service import DirectQgService
from sitewise.services.ports.business_context_store_port import ContextActor

#: Objective origin for a candidate the entrepreneur asked for. The objective
#: text is the confirmed uncertainty text, never the request body.
ENTREPRENEUR = 'ENTREPRENEUR'

#: The only statuses that are a successful answer to the caller.
ANSWER_STATUSES = frozenset({'VALIDATED_OUTPUT', 'VALID_ABSTENTION'})

#: Integrity failures between the persisted objective and the persisted context.
CONTEXT_CONFLICT_CODES = frozenset({
    'QG_CONTEXT_ASSESSMENT_MISMATCH',
    'QG_CONTEXT_CONFIRMATION_MISMATCH',
    'QG_CONTEXT_OBJECTIVE_MISMATCH',
    'QG_CONTEXT_REVISION_STALE',
})


class QgCandidateService:
    """Prepare, read and revise persisted QG candidates for one owner."""

    def __init__(self, *, contexts, confirmation, authority, runner,
                 enabled: bool = False, fixed_policy_resolver=None):
        self.contexts = contexts
        self.confirmation = confirmation
        self.authority = authority
        # A bound runner, not a factory: provider, ledger and disclosure are
        # resolved by the server composition, never by the request body.
        self.runner = runner
        self.enabled = enabled
        self.fixed_policy_resolver = fixed_policy_resolver

    # -- prepare ---------------------------------------------------------
    def prepare(self, objective_id, actor_id, expected_revision, context_id, *,
                actor_role: str = 'entrepreneur', supersedes=None) -> dict:
        """Generate one candidate for the current objective revision.

        ``supersedes`` is only ever set by ``revise``, and only after the
        parent's ``REQUEST_REVISION`` decision is confirmed to exist.
        """
        # A candidate this path persists is assessment-bound: it is keyed by a
        # confirmed objective. ``facts_from_packet`` can represent "no objective"
        # as objective_id=None, but that representation is for offline/synthetic
        # regression only. Refuse it here, before any model call or write, with
        # its own code rather than the generic stale-revision conflict.
        if objective_id is None:
            raise ConflictError('QG_OBJECTIVE_NOT_PERSISTED')
        context = self._context(objective_id, actor_id, expected_revision)
        source = context['source']
        assessment_id = source['assessment_id']
        actor = ContextActor(user_id=actor_id, role=actor_role)

        response = self.contexts.retrieve(UUID(str(assessment_id)),
                                          UUID(str(context_id)), actor)
        packet = response['packet']
        conflict = self._integrity(packet, context, expected_revision)
        if conflict is not None:
            return self._refusal(conflict)

        service = DirectQgService(contexts=self.contexts, authority=self.authority,
                                  runner=self.runner, enabled=self.enabled,
                                  fixed_policy_resolver=self.fixed_policy_resolver)
        result = service.prepare_candidate(
            assessment_id=UUID(str(assessment_id)),
            context_id=UUID(str(context_id)),
            actor=actor,
            objective={'objective_id': str(objective_id), 'origin': ENTREPRENEUR,
                       'text': context['objective']},
            reserve=self._reserve(objective_id))

        if result['status'] == 'VALIDATED_OUTPUT':
            # The engine echoes the id that facts_from_packet() bound into its
            # QG input. A real candidate is persisted under the resolved
            # objective, so a null echo (no objective supplied) or a different
            # objective must fail closed: never persist a version whose QG
            # input carried no objective id or one that disagrees with the
            # objective resolved from the assessment.
            engine_objective = result.get('objective_id')
            if (engine_objective is None
                    or str(engine_objective) != str(context['objective_id'])):
                raise ConflictError('QG_OBJECTIVE_NOT_PERSISTED')
            candidate = result['qg']
            evidence = {
                'question': candidate['question'],
                'options': [{'code': code, 'label': label, 'eligible': True}
                            for code, label in zip(candidate['response_codes'],
                                                   candidate['response_options'])],
                'source_receipt': result['source_fingerprint'],
                'source_version': result['admission']['uncertainty_version'],
            }
            version = self.confirmation.persist_candidate(
                objective_id, actor_id, expected_revision, context, result,
                evidence, supersedes=supersedes)
            if supersedes is not None and str(version) == str(supersedes):
                # A version id is a digest of the receipt, so a revision that
                # reproduces the parent byte for byte IS the parent. The insert
                # was a no-op; reporting it as a new version would tell the
                # reviewer a revision happened when nothing changed.
                raise ConflictError('QG_CANDIDATE_REVISION_UNCHANGED')
            return self._project(result, version=version)

        if result['status'] == 'VALID_ABSTENTION':
            # Nothing to persist: an abstention has no question, and storing one
            # would create a version a reviewer could be assigned to.
            missing = (result.get('qg') or {}).get('missing_business_facts') or []
            return self._project(result, version=None, missing=missing)

        return self._project(result, version=None)

    # -- read ------------------------------------------------------------
    def read(self, version, actor_id) -> dict:
        row = self.confirmation.repo.candidate_version(version, actor_id)
        if row is None:
            raise NotFoundError('Candidate version not found.')
        return self._candidate(row)

    # -- history ---------------------------------------------------------
    def history(self, objective_id, actor_id, expected_revision) -> dict:
        """Every version for the objective, oldest generation first.

        Status is derived from the persisted decision only. ``PENDING`` means no
        review row exists yet; no other value is invented here.
        """
        context = self._context(objective_id, actor_id, expected_revision)
        rows = self.confirmation.repo.candidate_history(
            objective_id, actor_id, expected_revision)
        versions = [self._history_entry(row) for row in rows]
        return {
            'objective_id': str(objective_id),
            'objective': context['objective'],
            'versions': versions,
            'version_count': len(versions),
            **no_authority(),
        }

    # -- revise ----------------------------------------------------------
    def revise(self, version, actor_id, expected_revision, context_id, *,
               actor_role: str = 'entrepreneur') -> dict:
        """Generate the child of a candidate whose parent asked for a revision.

        The parent's terminal decision is checked here rather than left to the
        repository so the caller receives a conflict, not a persistence error.
        """
        parent = self.confirmation.repo.candidate_version(version, actor_id)
        if parent is None:
            raise NotFoundError('Candidate version not found.')
        if parent['decision'] != 'REQUEST_REVISION':
            raise ConflictError('QG_CANDIDATE_REVISION_NOT_REQUESTED')
        return self.prepare(parent['objective_id'], actor_id, expected_revision,
                            context_id, actor_role=actor_role, supersedes=version)

    # -- internals -------------------------------------------------------
    def _context(self, objective_id, actor_id, expected_revision) -> dict:
        """The persisted objective, with ownership and staleness enforced.

        ``qj_context`` raises NotFoundError both for an objective that does not
        exist and for one whose revision is no longer current. The caller cannot
        distinguish those, and a stale revision is a conflict with current
        state, so it is reported as one.
        """
        try:
            return self.confirmation.qj_context(objective_id, actor_id,
                                                expected_revision)
        except NotFoundError as exc:
            raise ConflictError('QG_CONTEXT_REVISION_STALE') from exc

    @staticmethod
    def _integrity(packet: dict, context: dict, expected_revision: int):
        """Return a conflict code when the two persisted records disagree."""
        source = context.get('source') or {}
        confirmation = packet.get('confirmation') or {}
        uncertainty = packet.get('confirmed_uncertainty') or {}
        # Matching text alone is not identity: two assessments or objectives
        # can legitimately use exactly the same wording.  Resolve every edge
        # from the server-held records, never from a model-provided claim.
        assessment_id = packet.get('assessment_id') or (packet.get('identity') or {}).get('assessment_id')
        if not assessment_id or str(assessment_id) != str(source.get('assessment_id')):
            return 'QG_CONTEXT_ASSESSMENT_MISMATCH'
        if not uncertainty.get('id') or str(uncertainty['id']) != str(context.get('objective_id')):
            return 'QG_CONTEXT_OBJECTIVE_MISMATCH'
        if str(confirmation.get('id')) != str(source.get('confirmation_id')):
            return 'QG_CONTEXT_CONFIRMATION_MISMATCH'
        if str(uncertainty.get('confirmation_id')) != str(confirmation.get('id')):
            return 'QG_CONTEXT_CONFIRMATION_MISMATCH'
        if uncertainty.get('exact_text') != context.get('objective'):
            return 'QG_CONTEXT_OBJECTIVE_MISMATCH'
        if confirmation.get('revision') != expected_revision:
            return 'QG_CONTEXT_REVISION_STALE'
        return None

    @staticmethod
    def _reserve(objective_id):
        """One authorised budget slot per attempt, reserved before dispatch."""
        def reserve(attempt):
            try:
                budget.reserve(scenario=f'qg-candidate:{objective_id}:attempt-{attempt}')
            except BudgetExhausted as exc:
                raise WorkflowHeld('MODEL_ATTEMPT_BUDGET_EXHAUSTED') from exc
        return reserve

    @staticmethod
    def _project(result: dict, *, version, missing=()) -> dict:
        """The HTTP body for one engine result.

        ``confirmed_facts`` is deliberately not returned: it restates the
        entrepreneur's confirmed source text, which the caller already holds and
        which no client needs in order to review a proposal.
        """
        projection = {
            'status': result['status'],
            'code': result.get('code'),
            'version': version,
            'candidate': result.get('qg'),
            'field_authority': result.get('field_authority'),
            'admission': result.get('admission'),
            'attempts': result.get('attempts') or [],
            'composition': result.get('composition'),
            'missing_business_facts': list(missing),
            'candidate_authority': 'ENTREPRENEUR_REVIEW_ONLY',
            **no_authority(),
        }
        if result.get('provider_execution') is not None:
            projection['provider_execution']=result['provider_execution']
        return projection

    @classmethod
    def _refusal(cls, code: str) -> dict:
        return cls._project({'status': 'BLOCKED_INPUT', 'code': code}, version=None)

    @staticmethod
    def _receipt(row: dict) -> dict:
        try:
            return json.loads(row['source_receipt'])
        except (KeyError, TypeError, ValueError):
            return {}

    @classmethod
    def _candidate(cls, row: dict) -> dict:
        evaluation = (cls._receipt(row).get('evaluation') or {})
        projection = {
            'version': str(row['id']),
            'objective_id': str(row['objective_id']),
            'objective': row.get('exact_text'),
            'question': row['question'],
            'options': row['options'],
            'supersedes': (str(row['supersedes']) if row.get('supersedes') else None),
            'status': row.get('decision') or 'PENDING',
            'decision': row.get('decision'),
            'rationale': row.get('rationale'),
            'reviewer_id': (str(row['reviewer_id']) if row.get('reviewer_id') else None),
            'recorded_at': row.get('recorded_at'),
            'field_authority': evaluation.get('field_authority'),
            'admission': evaluation.get('admission'),
            'candidate_authority': 'ENTREPRENEUR_REVIEW_ONLY',
            **no_authority(),
        }
        # Only the new versioned contract can provide these fields. Historical
        # V1/V2 rows retain their existing interpretation and response shape.
        if evaluation.get('contract_version') == 'P1-QG-FIXED-OPTION-1.0':
            qg = evaluation.get('qg') or {}
            projection['contract_version'] = evaluation['contract_version']
            projection['fixed_measurement'] = qg.get('fixed_measurement')
            projection['source_fingerprint'] = evaluation.get('source_fingerprint')
        if evaluation.get('provider_execution') is not None:
            projection['provider_execution']=evaluation['provider_execution']
        return projection

    @classmethod
    def _history_entry(cls, row: dict) -> dict:
        projection = {
            'version': str(row['id']),
            'depth': row['depth'],
            'question': row['question'],
            'options': row['options'],
            'supersedes': (str(row['supersedes']) if row.get('supersedes') else None),
            'status': row.get('decision') or 'PENDING',
            'decision': row.get('decision'),
            'rationale': row.get('rationale'),
            'reviewer_id': (str(row['reviewer_id']) if row.get('reviewer_id') else None),
            'recorded_at': row.get('recorded_at'),
        }
        execution=(cls._receipt(row).get('evaluation') or {}).get('provider_execution')
        if execution is not None:
            projection['provider_execution']=execution
        return projection


__all__ = ['ANSWER_STATUSES', 'CONTEXT_CONFLICT_CODES', 'ENTREPRENEUR',
           'QgCandidateService']
