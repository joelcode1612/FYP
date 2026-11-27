"""Server-side QG live dispatch, bound to an explicit synthetic authorization.

This is the only component allowed to put a contract-2.0 confirmed-facts packet
on the provider transport. It does not invent authority:

* the authorization is an on-disk artifact containing the Owner-authorized
  confirmed-facts fingerprint and operator receipt;
* a packet whose fingerprint differs is refused before any run is provisioned,
  any global budget slot is consumed, or any socket is opened;
* the governed stage stays ``QG`` — no relabelling as BDJ, and no QJ stage
  anywhere on this path. The dispatched prompt is the one the caller names, and
  only registered keys are admissible;
* the global 50-attempt reservation is consumed once, immediately before the
  ledger reservation and the provider call.

Two prompt keys are authorised. ``QG_PROPOSAL`` produces the methodological
envelope (routing, denominator, measurement description). ``QG_FIXED_OPTION``
produces the fixed-option block that ``validate_fixed_candidate`` requires.
The owner authorised the second key on 2026-11-23 after its source, disclosure
and respondent conditions were evidenced; see
``var/e2e/N04C_QG_PROMPT_AND_AUTHORIZATION.md`` §2.1. Neither key relaxes a
validation rule.

The artifact is deliberately not a code constant: adding a new fingerprint must
be a visible, auditable act rather than an edit to production logic.
"""
from __future__ import annotations

import json
from pathlib import Path
from uuid import UUID

from sitewise.core.config import provider_timeout_seconds, settings
from sitewise.project1 import budget
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.disclosure import (
    QG_PURPOSE, QG_SCHEMA_VERSION, SyntheticQgAuthorization,
    SyntheticQgDisclosure,
)
from sitewise.project1.ledger import PostgresAttemptLedger
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.provider import ModelRunner, TokenHarbor
from sitewise.project1.runs import (
    QG_POLICY_PROMPT_KEYS, attempt_count, ensure_qg_run)

BACKEND = Path(__file__).resolve().parents[3]
AUTHORIZATION_PATH = BACKEND / 'var' / 'qg_synthetic_authorization.json'

#: Registered prompt keys this runner may dispatch. Anything else is refused
#: before a run is provisioned, so an unregistered prompt cannot spend an
#: attempt. Membership here is an authorization, not a convenience. The set is
#: shared with ``qg_policy_fingerprint`` so a run cannot record a policy for a
#: prompt this runner would refuse to dispatch.
AUTHORIZED_PROMPT_KEYS = QG_POLICY_PROMPT_KEYS

#: The key used when a caller names none.
#:
#: This was ``QG_PROPOSAL`` when the proposal prompt was the only authorised
#: key, and the default then preserved the behaviour of a composition that named
#: no key. It is now the fixed-option prompt, because the default must name the
#: pathway that actually executes:
#:
#: * every persisted live candidate carries ``QG-FIXED-OPTION-4-CAND`` and every
#:   run provisioned for QG is fingerprinted with the fixed-option policy;
#: * no run has ever been provisioned with the ``QG_PROPOSAL`` policy, so no
#:   stored identity depends on this default;
#: * the only consumer of a QG answer on this runner is
#:   ``validate_fixed_candidate``, and a proposal-shaped answer cannot satisfy
#:   it — it is refused with ``QG_FIXED_OPTION_SCHEMA_INVALID`` *after* the
#:   attempt is reserved and the dispatch is billed.
#:
#: A default that can only produce a paid refusal is not a conservative default.
#: ``QG_PROPOSAL`` remains in ``AUTHORIZED_PROMPT_KEYS`` so the held legacy
#: evaluation service can be re-enabled by a separately authorised act, but a
#: caller that wants it must now name it.
DEFAULT_PROMPT_KEY = 'QG_FIXED_OPTION'


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
                 authorization_path=None, authorization_verifier=None):
        self.engine = engine
        # Loading is deferred to dispatch: a missing artifact must fail the
        # request with a named hold, not break app startup or dependency wiring.
        self.authorization = authorization
        self._authorization_path = authorization_path
        #: Called at dispatch to re-derive the authority from what is *stored*.
        #:
        #: ``authorization`` alone is not enough for the HTTP path: a dict built
        #: by the caller makes the purpose check below self-referential. When a
        #: verifier is supplied it is the only source of ``auth``, so a caller
        #: cannot assert a purpose, an attempt budget or a prompt identity the
        #: persisted record does not carry.
        self.authorization_verifier = authorization_verifier
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
                timeout=provider_timeout_seconds(),
                identity_exception=settings.tokenharbor_model_identity_exception)
        return self._provider

    @property
    def last_identity(self):
        return getattr(self.provider, 'last_identity', None)

    def __call__(self, stage, packet, output_type, *, prompt_key=None,
                 attempt_slot=1):
        """Dispatch one governed attempt.

        ``attempt_slot`` mirrors ``ModelRunner.__call__`` so the two runners are
        interchangeable. It is *not* how a recovery is distinguished: a recovery
        is issued as a new authorization, and the authorization id is part of the
        run's work identity, so a recovery lands in its own run with slot 1 free
        (DD-054). The parameter exists for a same-run retry, which this path
        never produces, and is forwarded so the ledger stays the single place
        that decides what a slot means.
        """
        self.last_execution = None
        if self.engine is None:
            raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE')
        if self.authorization_verifier is not None:
            # Re-read at dispatch, not at construction: an authorization can be
            # consumed or expire between the route resolving it and the socket
            # opening, and a cached dict would not notice.
            self.authorization = self.authorization_verifier()
        elif self.authorization is None:
            self.authorization = load_authorization(self._authorization_path)
        auth = self.authorization
        if stage != 'QG':
            raise WorkflowHeld('DISCLOSURE_STAGE_NOT_AUTHORIZED')
        # The purpose is now read from the persisted authorization row (via the
        # verifier) rather than from a dict this process assembled, so a BDJ
        # grant cannot be presented as QG authority.
        if auth.get('purpose') != QG_PURPOSE:
            raise WorkflowHeld('QG_LIVE_PURPOSE_NOT_AUTHORIZED')
        key = prompt_key or DEFAULT_PROMPT_KEY
        if key not in AUTHORIZED_PROMPT_KEYS:
            # Refused before the run is provisioned: an unregistered prompt must
            # never consume an attempt or open a socket.
            raise WorkflowHeld('PROVIDER_PROMPT_NOT_AUTHORIZED')
        if key not in self.prompts:
            raise WorkflowHeld('PROVIDER_PROMPT_NOT_REGISTERED')
        # When the artifact names the prompt it authorises, that binding is
        # enforced here — still before the run is provisioned, so a mismatched
        # prompt cannot spend an attempt.
        prompt = self.prompts[key]
        bound_version = auth.get('prompt_version')
        bound_sha = auth.get('prompt_sha256')
        if bound_version and bound_version != prompt.version:
            raise WorkflowHeld('QG_LIVE_PROMPT_VERSION_MISMATCH')
        if bound_sha and bound_sha != prompt.fingerprint:
            raise WorkflowHeld('QG_LIVE_PROMPT_HASH_MISMATCH')
        if packet.get('schema_version') != QG_SCHEMA_VERSION:
            raise WorkflowHeld('DISCLOSURE_SOURCE_CLASS_INVALID')
        if packet.get('source_fingerprint') != auth['source_fingerprint']:
            raise WorkflowHeld('DISCLOSURE_SOURCE_MISMATCH')

        actor = UUID(str(auth['actor_id']))
        assessment = UUID(str(auth['assessment_id']))
        source = auth['source_fingerprint']
        run_id = ensure_qg_run(self.engine, actor, assessment, source,
                               str(auth.get('evaluation_id', '')), prompt_key=key,
                               # Recorded at reservation time where the schema
                               # holds it, so two approved objectives never share
                               # one run (CP-FINAL-04).
                               objective_id=auth.get('objective_id'))
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
            return runner('QG', packet, output_type, prompt_key=key,
                          attempt_slot=attempt_slot)
        finally:
            receipt=runner.last_execution
            if receipt is not None:
                # The dispatched prompt identity travels with the receipt so a
                # downstream writer can prove the prompt that ran is the prompt
                # the authorization bound. Without this a caller could authorise
                # one version and dispatch another.
                prompt = self.prompts[key]
                self.last_execution = {
                    **receipt,
                    'run_id': str(run_id),
                    'source_fingerprint': source,
                    'prompt_key': key,
                    'prompt_version': prompt.version,
                    'prompt_sha256': prompt.fingerprint,
                }


def configured_qg_runner(engine, *, authorization_path=None) -> QgLiveRunner:
    """Server composition only; web callers cannot choose provider or facts."""
    return QgLiveRunner(engine=engine, authorization_path=authorization_path)


__all__ = ['AUTHORIZATION_PATH', 'AUTHORIZED_PROMPT_KEYS', 'DEFAULT_PROMPT_KEY',
           'QgLiveRunner', 'configured_qg_runner', 'load_authorization']
