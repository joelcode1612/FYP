"""Bind the governed live QG runner to the fixed-option candidate adapter.

Why this module exists
----------------------
The adapter is the only writer of ``m2_qg_candidates`` and the only thing Stage 4
reads. The live runner is the only component allowed to put a packet on the
provider transport. Between them there was nothing: the adapter took an injected
``generate`` callable, and every caller passed a simulator. That is why no
candidate has ever carried a provider receipt.

This module is that seam and nothing more. It does not choose an assessment, an
objective, a measurement or an authorization — all four arrive from the adapter's
already-verified gates. It builds the QG input from the ``ConfirmedFacts`` the
adapter assembled, dispatches through the authorised runner, and returns the
output **with the receipt that describes how it was made**.

What it refuses to do
---------------------
* It will not invent a receipt. If the runner recorded no execution, it raises
  ``QG_LIVE_EXECUTION_RECEIPT_MISSING`` rather than returning a simulated one.
* It will not relabel a prompt. The version and hash in the receipt come from the
  registry entry the runner actually dispatched.
* It will not claim a provider it did not use: ``model_provider`` is read from the
  runner's provider class, not written as a literal.
"""
from __future__ import annotations

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.disclosure import QG_SCHEMA_VERSION
from sitewise.project1.qg_candidate_adapter import (
    LIVE_PROVIDER, ExecutionReceipt, GenerationResult,
)
from sitewise.project1.qg_fixed_options import (
    FIXED_OPTION_CONTRACT, FixedOptionCandidate,
)
from sitewise.project1.prompts import PROMPTS
from sitewise.project1 import research_coverage

#: The registered prompt for fixed-option customer-question generation. Its
#: contract is the one ``validate_fixed_candidate`` accepts.
PROMPT_KEY = 'QG_FIXED_OPTION'


def provider_name(runner) -> str:
    """The provider identity actually in use, read rather than asserted."""
    provider = getattr(runner, 'provider', None)
    if provider is None:
        raise WorkflowHeld('QG_LIVE_PROVIDER_UNAVAILABLE')
    return type(provider).__name__.lower()


def build_qg_input(facts, *, policy_version: str) -> dict:
    """The packet the live runner puts on the transport.

    ``source_fingerprint`` is the facts digest, not the BCB packet hash. The
    runner compares it against the authorized fingerprint before provisioning, so
    the authorization must bind this value — see ``N04C_QG_PROMPT_AND_AUTHORIZATION.md``.

    ``research_coverage`` is the Section A coverage the assessment already has.
    It sits beside ``source_fingerprint`` rather than inside
    ``confirmed_facts``: the facts digest is what the authorization binds, and
    coverage is material for the model's duplication judgement, not a confirmed
    business fact.
    """
    return {
        'contract_version': FIXED_OPTION_CONTRACT,
        'schema_version': QG_SCHEMA_VERSION,
        'source_fingerprint': facts.fingerprint,
        'confirmed_facts': facts.model_dump(mode='json'),
        'policy_version': policy_version,
        research_coverage.COVERAGE_FIELD: research_coverage.for_question_arm(),
    }


def receipt_from_execution(execution: dict | None, *, prompt) -> ExecutionReceipt:
    """Turn the runner's execution record into the adapter's receipt.

    Every field is copied. Nothing is defaulted into a plausible-looking value:
    a missing run id or attempt number stays missing so the adapter's
    ``_require_receipt`` can refuse it with its own code.
    """
    if not execution:
        raise WorkflowHeld('QG_LIVE_EXECUTION_RECEIPT_MISSING')
    return ExecutionReceipt(
        execution_mode='LIVE',
        model_provider=LIVE_PROVIDER,
        model_requested=str(execution.get('model_requested') or ''),
        model_returned=execution.get('model_returned'),
        run_id=execution.get('run_id'),
        attempt_no=execution.get('attempt_no'),
        prompt_version=str(execution.get('prompt_version') or prompt.version),
        prompt_sha256=str(execution.get('prompt_sha256') or prompt.fingerprint),
    )


def live_fixed_option_generator(runner, *, policy_version: str,
                                prompt_key: str = PROMPT_KEY,
                                attempt_slot: int = 1):
    """Build the ``generate`` callable the adapter expects.

    The returned callable raises rather than degrading. A provider failure is the
    provider's answer; substituting a simulated success would make the candidate
    table lie.
    """
    prompts = getattr(runner, 'prompts', None) or PROMPTS
    if prompt_key not in prompts:
        raise WorkflowHeld('PROVIDER_PROMPT_NOT_REGISTERED')
    prompt = prompts[prompt_key]

    def generate(payload: dict) -> GenerationResult:
        facts = payload['facts']
        qg_input = build_qg_input(facts, policy_version=policy_version)
        # The slot is passed ONLY when one is actually asked for, so the ordinary
        # call shape stays exactly what it was and every existing runner double
        # keeps working. A retry is a deliberate act, not a default (DD-054).
        slot = {'attempt_slot': attempt_slot} if attempt_slot != 1 else {}
        raw = runner('QG', qg_input, FixedOptionCandidate, prompt_key=prompt_key,
                     **slot)
        receipt = receipt_from_execution(runner.last_execution, prompt=prompt)
        return GenerationResult(output=raw, receipt=receipt)

    return generate


__all__ = ['PROMPT_KEY', 'build_qg_input', 'live_fixed_option_generator',
           'provider_name', 'receipt_from_execution']
