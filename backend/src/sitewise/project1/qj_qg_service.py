"""Production composition for the QJ -> bank -> QG workflow (directive §5.4).

Before this module, ``ResearchWorkflow`` had **no production caller at all**: it was
reachable only from test harnesses. That is why every ``authority`` and ``bank`` in
the tree was a double, and why a no-op ``validate_measurement`` could sit in the
survey path unnoticed.

This module connects the existing services — it does not create a parallel system:

* context comes from ``PersistedBusinessContextService``, the same persisted BCB
  builder the BDJ path uses, so QJ sees the same packet and the same integrity
  checks rather than a second construction path;
* authority is the real versioned ``MeasurementAuthority``;
* bank is a ``QuestionBank`` (BD-01), not a double;
* the runner is built by the existing ``configured_runner`` factory, so provider,
  ledger and disclosure controls are unchanged;
* the result carries ``no_authority()`` and never sets a fielding right.

Every gate fails closed with a stable code. In particular the persisted context
itself reports ``qj_execution_authorized: False``; until an Owner authorization
changes that, this service composes successfully and then refuses to execute. That
refusal is the correct production behaviour, not a defect to be worked around.
"""
from __future__ import annotations

from sitewise.project1.contracts import WorkflowHeld, no_authority
from sitewise.project1.measurement_policy import MeasurementAuthority
from sitewise.project1.research import ResearchWorkflow


class PacketBuilder:
    """Adapts an already-verified persisted packet to the workflow's builder port."""

    def __init__(self, packet: dict):
        self.packet = packet

    def get_context(self, _request=None) -> dict:
        return self.packet


class QjQgService:
    """One governed QJ -> bank -> QG evaluation over a persisted BCB context."""

    def __init__(self, *, contexts, authority: MeasurementAuthority, bank,
                 runner, enabled: bool = False):
        self.contexts = contexts
        self.authority = authority
        self.bank = bank
        # A bound runner, not a factory: the factory's ledger and disclosure belong
        # to one attempt and are resolved by the caller before composition.
        self.runner = runner
        self.enabled = enabled

    def gates(self) -> dict:
        """Report the prerequisites without executing anything."""
        return {
            'service_enabled': bool(self.enabled),
            'context_service': self.contexts is not None,
            'measurement_authority': getattr(self.authority, 'measurement_policy_version', None),
            'bank': type(self.bank).__name__ if self.bank is not None else None,
            'runner': self.runner is not None,
            'fielding_authorized': False,
            'publication_authorized': False,
            'scientific_acceptance': False,
        }

    def evaluate(self, *, assessment_id, context_id, actor) -> dict:
        if not self.enabled:
            raise WorkflowHeld('QJQG_NOT_ENABLED')
        if self.contexts is None:
            raise WorkflowHeld('QJQG_CONTEXT_SERVICE_MISSING')
        if getattr(self.authority, 'measurement_policy_version', None) is None:
            raise WorkflowHeld('QJQG_AUTHORITY_UNVERIFIED')
        if self.bank is None:
            raise WorkflowHeld('QJQG_BANK_MISSING')
        if self.runner is None:
            raise WorkflowHeld('QJQG_RUNNER_MISSING')

        response = self.contexts.retrieve(assessment_id, context_id, actor)
        # The persisted context is the authority on whether QJ may run against it.
        # It reports False today; a caller cannot override that by passing a flag.
        if response.get('qj_execution_authorized') is not True:
            raise WorkflowHeld('QJQG_CONTEXT_DOES_NOT_AUTHORIZE_QJ')
        packet = response['packet']

        workflow = ResearchWorkflow(PacketBuilder(packet), self.authority, self.bank,
                                    self.runner)
        result = workflow.execute(None)
        result['composition'] = {'source': 'persisted-business-context/1',
                                 'context_id': str(context_id),
                                 'qj_execution_authorized': False,
                                 'qg_execution_authorized': False}
        result.update(no_authority())
        return result


def build_service(*, contexts, authority, bank, runner, enabled: bool) -> QjQgService:
    """Server composition only; a web caller cannot choose a provider or credential."""
    return QjQgService(contexts=contexts, authority=authority, bank=bank,
                       runner=runner, enabled=enabled)


def runner_for(ledger, disclosure, prompts):
    """Bind the existing runner factory to one attempt's ledger and disclosure."""
    from sitewise.project1.provider import configured_runner
    return configured_runner(ledger, disclosure, prompts)


def unavailable(*_args, **_kwargs):
    """A builder that refuses: used where composition is reported but not wired."""
    raise WorkflowHeld('QJQG_NOT_COMPOSED')


__all__ = ['PacketBuilder', 'QjQgService', 'build_service', 'runner_for', 'unavailable']
