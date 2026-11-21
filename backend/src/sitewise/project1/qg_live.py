"""Server-side QG live dispatch, bound to an explicit synthetic authorization.

This is the only component allowed to put a contract-2.0 confirmed-facts packet
on the provider transport. It does not invent authority:

* the authorization is an on-disk artifact containing the Owner-authorized
  confirmed-facts fingerprint and operator receipt;
* a packet whose fingerprint differs is refused before any run is provisioned,
  any global budget slot is consumed, or any socket is opened;
* the governed stage stays ``QG`` and the prompt stays ``QG_PROPOSAL`` — no
  relabelling as BDJ, and no QJ stage anywhere on this path;
* the global 50-attempt reservation is consumed once, immediately before the
  ledger reservation and the provider call.

The artifact is deliberately not a code constant: adding a new fingerprint must
be a visible, auditable act rather than an edit to production logic.
"""
from __future__ import annotations

import json
from pathlib import Path
from uuid import UUID

from sitewise.core.config import settings
from sitewise.project1 import budget
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.disclosure import (
    QG_PURPOSE, QG_SCHEMA_VERSION, SyntheticQgAuthorization,
    SyntheticQgDisclosure,
)
from sitewise.project1.ledger import PostgresAttemptLedger
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.provider import ModelRunner, TokenHarbor
from sitewise.project1.runs import attempt_count, ensure_qg_run

BACKEND = Path(__file__).resolve().parents[3]
AUTHORIZATION_PATH = BACKEND / 'var' / 'qg_synthetic_authorization.json'


def load_authorization(path: Path | str | None = None) -> dict:
    """Read the pre-authorized synthetic facts binding, or fail closed."""
    target = Path(path) if path is not None else AUTHORIZATION_PATH
    if not target.is_file():
        raise WorkflowHeld('QG_LIVE_AUTHORIZATION_MISSING')
    try:
        payload = json.loads(target.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        raise WorkflowHeld('QG_LIVE_AUTHORIZATION_INVALID') from None
    required = ('source_fingerprint', 'operator_receipt', 'assessment_id',
                'actor_id', 'max_attempts', 'purpose')
    if any(key not in payload for key in required):
        raise WorkflowHeld('QG_LIVE_AUTHORIZATION_INVALID')
    if payload['purpose'] != QG_PURPOSE:
        raise WorkflowHeld('QG_LIVE_AUTHORIZATION_INVALID')
    if payload['max_attempts'] not in (1, 3):
        raise WorkflowHeld('QG_LIVE_AUTHORIZATION_INVALID')
    return payload


class QgLiveRunner:
    """The configured runner behind ``get_qg_runner()``.

    ``__call__`` has the same signature as ``ModelRunner`` so the existing
    ``ResearchWorkflow`` / ``DirectQgService`` composition is unchanged.
    """

    # The runner owns the global reservation. Callers must not reserve again.
    owns_global_reservation = True
    supports_prompt_key = True

    def __init__(self, *, engine, authorization: dict | None = None,
                 provider=None, prompts=None, budget_path=None,
                 authorization_path=None):
        self.engine = engine
        # Loading is deferred to dispatch: a missing artifact must fail the
        # request with a named hold, not break app startup or dependency wiring.
        self.authorization = authorization
        self._authorization_path = authorization_path
        self.prompts = prompts if prompts is not None else PROMPTS
        self._provider = provider
        self.budget_path = budget_path
        self.last_run_id: UUID | None = None
        self.last_budget_status: dict | None = None
        self.last_execution: dict | None = None

    @property
    def provider(self):
        if self._provider is None:
            self._provider = TokenHarbor(settings.tokenharbor_api_key,
                enabled=settings.tokenharbor_enabled,
                structured_mode=settings.tokenharbor_structured_mode,
                timeout=max(1, min(settings.tokenharbor_timeout_seconds, 60)),
                identity_exception=settings.tokenharbor_model_identity_exception)
        return self._provider

    @property
    def last_identity(self):
        return getattr(self.provider, 'last_identity', None)

    def __call__(self, stage, packet, output_type, *, prompt_key=None):
        self.last_execution = None
        if self.engine is None:
            raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE')
        if self.authorization is None:
            self.authorization = load_authorization(self._authorization_path)
        auth = self.authorization
        if stage != 'QG':
            raise WorkflowHeld('DISCLOSURE_STAGE_NOT_AUTHORIZED')
        if prompt_key not in (None, 'QG_PROPOSAL'):
            raise WorkflowHeld('PROVIDER_PROMPT_NOT_AUTHORIZED')
        if packet.get('schema_version') != QG_SCHEMA_VERSION:
            raise WorkflowHeld('DISCLOSURE_SOURCE_CLASS_INVALID')
        if packet.get('source_fingerprint') != auth['source_fingerprint']:
            raise WorkflowHeld('DISCLOSURE_SOURCE_MISMATCH')

        actor = UUID(str(auth['actor_id']))
        assessment = UUID(str(auth['assessment_id']))
        source = auth['source_fingerprint']
        run_id = ensure_qg_run(self.engine, actor, assessment, source,
                               str(auth.get('evaluation_id', '')))
        self.last_run_id = run_id

        # A refused re-dispatch must not consume a global slot. The ledger is
        # the second line of defence and still refuses the duplicate reservation.
        if attempt_count(self.engine, actor, run_id) >= int(auth['max_attempts']):
            raise WorkflowHeld('MODEL_ATTEMPT_BUDGET_EXHAUSTED')

        # Consumer before transport: an exhausted global ceiling stops here.
        budget.reserve(self.budget_path, 'CP-08 synthetic QG research evaluation')
        self.last_budget_status = budget.status(self.budget_path)

        disclosure = SyntheticQgDisclosure(SyntheticQgAuthorization(
            run_id=str(run_id), source_fingerprint=source,
            operator_receipt=auth['operator_receipt'],
            max_attempts=int(auth['max_attempts'])))
        ledger = PostgresAttemptLedger(self.engine, actor, run_id)
        runner = ModelRunner(self.provider, ledger, self.prompts,
                             disclosure=disclosure)
        try:
            return runner('QG', packet, output_type, prompt_key='QG_PROPOSAL')
        finally:
            receipt=runner.last_execution
            if receipt is not None:
                self.last_execution={**receipt,'run_id':str(run_id),'source_fingerprint':source}


def configured_qg_runner(engine, *, authorization_path=None) -> QgLiveRunner:
    """Server composition only; web callers cannot choose provider or facts."""
    return QgLiveRunner(engine=engine, authorization_path=authorization_path)


__all__ = ['AUTHORIZATION_PATH', 'QgLiveRunner', 'configured_qg_runner',
           'load_authorization']
