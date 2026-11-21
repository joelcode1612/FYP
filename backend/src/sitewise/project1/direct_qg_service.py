"""Production composition for the V2.0 active path: BCB -> QG.

Contract version ``P1-WORKFLOW-2.0-DIRECT-QG``. This supersedes the V1.0
composition in ``qj_qg_service`` for the active path, and differs from it in
exactly three ways, each of which is a contract change rather than a refactor:

1. **No QJ stage.** Nothing here dispatches a QJ call, and no gate reads
   ``qj_execution_authorized``. That flag asked whether QJ could run; a path that
   does not run QJ must not inherit it as a precondition.
2. **No bank.** The workflow is composed with ``bank=None``. V1.0 required a
   ``QuestionBank`` and refused to draft without a verified no-equivalent
   receipt; V2.0 removes that gate by contract, so a bank is not merely
   optional here — it is absent, and the result says ``NOT_CONSULTED_DIRECT_QG``
   rather than ``not_checked`` so a reader cannot mistake the absence for a skip.
3. **The measurement is supplied, not produced.** See
   ``research.DIRECT_QG_MEASUREMENT_SOURCES``. This module does not build,
   infer or complete a measurement, and it refuses one it cannot bind.

The composition still fails closed. Every gate has a stable code, and the
result carries ``no_authority()``: a candidate for entrepreneur review, never an
approved, accepted or fielded question.
"""
from __future__ import annotations

from sitewise.project1.contracts import WorkflowHeld, no_authority
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.qg_contract import CONTRACT_VERSION
from sitewise.project1.qg_iteration import MAX_ATTEMPTS, run_with_retries
from sitewise.project1.qj_qg_service import PacketBuilder
from sitewise.project1.research import ResearchWorkflow

#: Identifies the orchestration contract, not a data schema. A caller that
#: expects the V1.0 stage list gets a refusal rather than a differently-shaped
#: result.
WORKFLOW_CONTRACT_VERSION = 'P1-WORKFLOW-2.0-DIRECT-QG'

#: Stages this contract can dispatch. Exactly one, by design.
ACTIVE_STAGES = ('QG',)


class DirectQgService:
    """One governed BCB -> QG evaluation over a persisted context."""

    def __init__(self, *, contexts, authority, runner, enabled: bool = False,
                 contract_version: str = WORKFLOW_CONTRACT_VERSION,
                 fixed_policy_resolver=None):
        self.contexts = contexts
        self.authority = authority
        self.runner = runner
        self.enabled = enabled
        self.contract_version = contract_version
        # Server composition only. This is never read from an HTTP payload.
        # No production resolver is registered until source authority is adopted.
        self.fixed_policy_resolver = fixed_policy_resolver

    def gates(self) -> dict:
        """Report the prerequisites without executing anything."""
        return {
            'contract_version': self.contract_version,
            'active_stages': list(ACTIVE_STAGES),
            'service_enabled': bool(self.enabled),
            'context_service': self.contexts is not None,
            'measurement_authority': getattr(self.authority,
                                             'measurement_policy_version', None),
            'version_resolution': callable(getattr(self.authority,
                                                   'resolve_version', None)),
            # Reported as False rather than omitted: the absence of a bank is a
            # contract term in 2.0, and a missing key would read as an oversight.
            'bank_required': False,
            'runner': self.runner is not None,
            'fielding_authorized': False,
            'publication_authorized': False,
            'scientific_acceptance': False,
        }

    def _check_common(self) -> None:
        if self.contract_version != WORKFLOW_CONTRACT_VERSION:
            raise WorkflowHeld('DIRECT_QG_CONTRACT_VERSION_MISMATCH')
        if not self.enabled:
            raise WorkflowHeld('DIRECT_QG_NOT_ENABLED')
        if self.contexts is None:
            raise WorkflowHeld('DIRECT_QG_CONTEXT_SERVICE_MISSING')
        if getattr(self.authority, 'measurement_policy_version', None) is None:
            raise WorkflowHeld('DIRECT_QG_AUTHORITY_UNVERIFIED')
        if self.runner is None:
            raise WorkflowHeld('DIRECT_QG_RUNNER_MISSING')

    def _check(self, frozen_measurement) -> None:
        self._check_common()
        if frozen_measurement is None:
            # The named gap, surfaced at composition as well as at the workflow:
            # no component in this tree produces a Measurement once QJ is gone.
            raise WorkflowHeld('DIRECT_QG_MEASUREMENT_NOT_SUPPLIED')

    def evaluate(self, *, assessment_id, context_id, actor, frozen_measurement,
                 measurement_source, measurement_source_ref=None, objective=None) -> dict:
        self._check(frozen_measurement)
        response = self.contexts.retrieve(assessment_id, context_id, actor)
        packet = response['packet']
        # Validate a retrieved context even when this legacy drafting path is
        # held, so stale or tampered sources retain their specific refusal.
        from sitewise.project1.research import checked_context
        checked_context(PacketBuilder(packet), None)
        from sitewise.project1.qg_fixed_options import require_verified_respondent_path
        require_verified_respondent_path()
        workflow = ResearchWorkflow(PacketBuilder(packet), self.authority,
                                    None, self.runner)
        result = workflow.execute_direct_qg(
            None, frozen_measurement=frozen_measurement,
            measurement_source=measurement_source,
            measurement_source_ref=measurement_source_ref,
            objective=objective)
        result['composition'] = {
            'contract_version': self.contract_version,
            'active_stages': list(ACTIVE_STAGES),
            'source': 'persisted-business-context/1',
            'context_id': str(context_id),
            'bank_required': False,
            'qj_executed': False,
            # The persisted context still reports its QJ authorization. It is
            # recorded, not consulted: the field is history, not a gate.
            'qj_execution_authorized_observed':
                response.get('qj_execution_authorized'),
            'qg_execution_authorized': False,
        }
        result.update(no_authority())
        return result


    def prepare_candidate(self, *, assessment_id, context_id, actor, objective=None,
                          bdj_findings=(), attempt_limit: int = MAX_ATTEMPTS,
                          reserve=None) -> dict:
        """Contract 2.0: generate a candidate from confirmed facts.

        No measurement is required, because none exists to supply. The retry
        cycle is bounded, each attempt reserves budget *before* dispatch, and the
        outcome is one of ``VALIDATED_OUTPUT``, ``VALID_ABSTENTION``,
        ``BLOCKED_INPUT`` or ``MODEL_FAILURE``.

        An abstention is returned to the caller rather than retried: it is the
        model reporting missing facts, which is a result for the entrepreneur.
        """
        self._check_common()
        if not callable(self.fixed_policy_resolver):
            from sitewise.project1.qg_fixed_options import require_verified_respondent_path
            require_verified_respondent_path()
        response = self.contexts.retrieve(assessment_id, context_id, actor)
        packet = response['packet']
        policy = self.fixed_policy_resolver(assessment_id, context_id, actor, objective, packet)
        confirmation = packet.get('confirmation') or {}
        packet_assessment = packet.get('assessment_id') or (packet.get('identity') or {}).get('assessment_id')
        if (not isinstance(policy, dict) or not objective or
            str(packet_assessment) != str(assessment_id) or
            str(policy.get('assessment_id')) != str(assessment_id) or
            str(policy.get('owner_id')) != str(getattr(actor, 'user_id', None)) or
            policy.get('objective_approved') is not True or
            not isinstance(policy.get('authority_reference'), str) or
            not policy['authority_reference'].strip() or
            str(policy.get('context_id')) != str(context_id) or
            policy.get('context_hash') != packet.get('packet_hash') or
            str(policy.get('objective_id')) != str(objective.get('objective_id')) or
            policy.get('assessment_revision') != confirmation.get('revision')):
            raise WorkflowHeld('QG_FIXED_POLICY_SOURCE_MISMATCH')
        workflow = ResearchWorkflow(PacketBuilder(packet), self.authority, None,
                                    self.runner)

        def generate(feedback, _attempt):
            return workflow.execute_fixed_option_candidate(
                None, objective=objective, policy=policy, revision_feedback=feedback)

        from copy import deepcopy
        previous_execution=deepcopy(getattr(self.runner,'last_execution',None))
        run = run_with_retries(
            generate, attempt_limit=attempt_limit,
            prompt_version=PROMPTS['QG_FIXED_OPTION'].version, reserve=reserve)

        result = {'status': run['status'], 'code': run['code'],
                  'attempts': run['attempts'],
                  'attempt_limit': attempt_limit}
        if run['result'] is not None:
            result.update(run['result'])
        execution=getattr(self.runner,'last_execution',None)
        if execution is not None and execution!=previous_execution and run['attempts']:
            result['provider_execution']=execution
        result['composition'] = {
            'contract_version': self.contract_version,
            'qg_contract_version': result.get('contract_version', 'P1-QG-FIXED-OPTION-1.0'),
            'active_stages': list(ACTIVE_STAGES),
            'source': 'persisted-business-context/1',
            'context_id': str(context_id),
            'bank_required': False,
            'qj_executed': False,
            'qj_execution_authorized_observed':
                response.get('qj_execution_authorized'),
            'qg_execution_authorized': False,
        }
        result.update(no_authority())
        return result


def build_service(*, contexts, authority, runner, enabled: bool) -> DirectQgService:
    """Server composition only; a caller cannot choose a provider or credential."""
    return DirectQgService(contexts=contexts, authority=authority, runner=runner,
                           enabled=enabled)


__all__ = ['ACTIVE_STAGES', 'DirectQgService', 'WORKFLOW_CONTRACT_VERSION',
           'build_service']
