"""Bounded iterative prompting for QG.

The problem this solves
-----------------------
A model that fails a deterministic check once will usually fail it again if it is
asked the same question in the same way. Re-sending an identical prompt is not a
retry, it is a loop that spends budget. So a retry here always carries the *exact*
validation failure back to the model, and the check that rejected it runs again
unchanged.

What may and may not be retried
-------------------------------
Only failures that a better-formed answer could fix. A missing entrepreneur
confirmation, a stale BCB version, an unsupported objective, an invalid provider
permission, an exhausted budget or an unknown provider outcome are **not**
recoverable by rewording a question, so they stop immediately. Retrying them
would spend a call to learn what the code already knows.

Two outcomes end the cycle on the first attempt, and that is deliberate:

* **A validated candidate** — there is nothing to improve.
* **A justified abstention** — the model is telling us the facts are missing.
  That is an answer for the entrepreneur, not a failure to iterate on. Re-sending
  it would either produce the same abstention or pressure the model into
  inventing the missing fact, which is the exact failure this contract exists to
  prevent.

Every attempt is recorded, including the ones that failed, with the prompt
version, the input revision, the validation code and the feedback that was
returned to the model.
"""
from __future__ import annotations

from sitewise.project1.contracts import WorkflowHeld

#: Default ceiling per candidate-generation operation (directive V3.0, CP-02).
MAX_ATTEMPTS = 3

#: Failures a reformulated answer can fix. Each maps to the instruction returned
#: to the model, so the retry targets the defect rather than restating the task.
RECOVERABLE = {
    'QG_UNSOURCED_NUMBER':
        'Your question contained a number that is not in confirmed_facts. Use only '
        'numbers that appear there, or abstain naming the missing fact.',
    'QG_UNSOURCED_AMOUNT':
        'Your question contained a currency amount that is not in confirmed_facts. '
        'Use only amounts that appear there, or abstain naming the missing fact.',
    'QG_UNSOURCED_OFFER_COMPONENT':
        'Your question changed a product, size or service component. Restate the '
        'confirmed one exactly, or abstain.',
    'QG_RESPONSE_CODING_DRIFT':
        'response_codes and response_options must be the same length, distinct, and '
        'each code must be uppercase A-Z, 0-9 or underscore.',
    'QG_RESPONSE_LABEL_DRIFT':
        'Every response option must be a non-empty label.',
    'QG_ROUTING_DRIFT':
        'routing must have exactly one entry per response code, and no others.',
    'QG_DENOMINATOR_NOT_PROPOSED':
        'Propose a denominator_specification built from your declared response codes.',
    'QG_DENOMINATOR_DRIFT':
        'Your denominator_specification did not name any of your response codes. '
        'Build it from the declared codes.',
    'QG_LIMITATIONS_INCOMPLETE':
        'State limitations of at least 20 characters: what this question does not '
        'establish.',
    'QG_DRAFT_WITHOUT_QUESTION':
        'A DRAFT decision requires a non-empty question. If you cannot ask one, '
        'abstain instead.',
    'QG_CONFIRMED_FACTS_NOT_CITED':
        'List in used_confirmed_facts the confirmed source references, numbers or '
        'amounts your question relies on.',
    'QG_CITED_FACT_NOT_CONFIRMED':
        'used_confirmed_facts may only contain values that appear in confirmed_facts.',
    'QG_ABSTENTION_WITHOUT_MISSING_FACTS':
        'An abstention must list the missing items in missing_business_facts.',
    'QG_ABSTENTION_CODE_UNRECOGNISED':
        'missing_business_facts must use only the declared codes.',
    'QG_ABSTENTION_CONTAINS_QUESTION':
        'An abstention must leave question empty.',
    'QG_DRAFT_DECLARES_MISSING_FACTS':
        'You cannot draft while declaring a mandatory fact missing. Either draft '
        'without it or abstain.',
    'PROHIBITED_OPTIMUM_PRICE':
        'Remove the price-optimisation claim. This question cannot establish an '
        'optimum price.',
    'PROHIBITED_PURCHASE_PREDICTION':
        'Remove the purchase prediction. This question cannot establish purchase.',
    'PROHIBITED_FORECAST':
        'Remove the forecast claim. This question cannot forecast.',
    'PROHIBITED_WTP_CLAIM':
        'Remove the willingness-to-pay claim. This question cannot establish it.',
    'PROHIBITED_VIABILITY_CLAIM':
        'Remove the viability or profitability claim. This question cannot '
        'establish either.',
    'PROHIBITED_DEMAND_CLAIM':
        'Remove the demand or market-share claim. This question cannot establish '
        'either.',
}

#: Failures no rewording can fix. Named explicitly so the refusal reason is
#: stable and auditable rather than "unknown error, stopped".
UNRECOVERABLE = frozenset({
    'BCB_CONFIRMATION_REQUIRED', 'UNCERTAINTY_NOT_CONFIRMED',
    'BCB_PACKET_FINGERPRINT_INVALID', 'BCB_RESTRICTED_ITEM_MEMBERSHIP',
    'F01_CONFIRMATION_NOT_CURRENT', 'F01_UNCERTAINTY_IDENTITY_INCOMPLETE',
    'F01_UNCERTAINTY_CONFIRMATION_MISMATCH', 'F01_UNCERTAINTY_TEXT_MISSING',
    'F01_CONTEXT_CHANGED_SINCE_ADMISSION', 'F02_GEO_NOT_EXCLUDED',
    'QG_CONFIRMED_FACTS_INCOMPLETE', 'QG_CONFIRMED_UNCERTAINTY_TEXT_MISSING',
    'QG_MEASUREMENT_AUTHORITY_UNVERIFIED', 'QG_MEASUREMENT_SOURCE_UNRECOGNIZED',
    'MODEL_ATTEMPT_BUDGET_EXHAUSTED', 'MODEL_STAGE_ALREADY_RESERVED',
    'PROVIDER_CREDENTIALS_REJECTED', 'PROVIDER_BUDGET_INVALID',
    'E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN', 'DISCLOSURE_REQUIRED',
    'RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED', 'PROVIDER_RATE_LIMITED',
    'PROVIDER_TEMPORARILY_UNAVAILABLE', 'PROVIDER_PRICING_ABOVE_CEILING',
})


def is_recoverable(code: str) -> bool:
    """Only a defect in the *answer* is recoverable.

    An unlisted code is treated as unrecoverable. Defaulting the other way would
    turn a governance refusal into three model calls before the same refusal,
    which is a budget leak dressed as persistence.
    """
    return code in RECOVERABLE


def _classify(code: str) -> str:
    if code in UNRECOVERABLE:
        return 'BLOCKED_INPUT'
    return 'MODEL_FAILURE'


def run_with_retries(generate, *, attempt_limit: int = MAX_ATTEMPTS,
                     prompt_version: str = '', reserve=None):
    """Run ``generate`` until it yields a result, or until it must stop.

    ``generate(feedback, attempt)`` must return the workflow result dict or raise
    ``WorkflowHeld``. ``feedback`` is ``None`` on the first attempt and the
    previous failure on every retry.

    ``reserve`` is called once per attempt, *before* the model is invoked, and
    must raise ``WorkflowHeld`` when the budget is exhausted. Reserving per
    attempt rather than per operation is what makes the ceiling real: an
    operation that retries three times costs three slots.

    Returns a dict with ``status`` in
    ``VALIDATED_OUTPUT | VALID_ABSTENTION | BLOCKED_INPUT | MODEL_FAILURE``,
    the attempt ledger, and either ``result`` or ``code``.
    """
    if attempt_limit < 1:
        raise WorkflowHeld('QG_ATTEMPT_LIMIT_INVALID')

    attempts: list[dict] = []
    feedback = None

    for attempt in range(1, attempt_limit + 1):
        revision = ('initial' if attempt == 1 else f'feedback.{attempt - 1}')
        entry = {'attempt': attempt, 'prompt_version': prompt_version,
                 'input_revision': revision,
                 'prompt_revision': (prompt_version if attempt == 1
                                     else f'{prompt_version}+{revision}'),
                 'feedback_code': (feedback or {}).get('code')}

        if reserve is not None:
            try:
                reserve(attempt)
            except WorkflowHeld as exc:
                entry.update(outcome='NOT_EXECUTED', code=str(exc))
                attempts.append(entry)
                return {'status': 'BLOCKED_INPUT', 'code': str(exc),
                        'attempts': attempts, 'result': None}

        try:
            result = generate(feedback, attempt)
        except WorkflowHeld as exc:
            code = str(exc)
            entry.update(outcome=_classify(code), code=code)
            attempts.append(entry)
            if not is_recoverable(code):
                return {'status': _classify(code), 'code': code,
                        'attempts': attempts, 'result': None}
            feedback = {'attempt': attempt, 'code': code,
                        'instruction': RECOVERABLE[code]}
            continue
        except Exception as exc:  # noqa: BLE001 - schema errors are model failures
            # A ValidationError or transport shape problem is the model's answer
            # being malformed, not a governance decision. Recorded, not retried:
            # without a WorkflowHeld code there is no targeted feedback to give.
            code = type(exc).__name__
            entry.update(outcome='MODEL_FAILURE', code=code)
            attempts.append(entry)
            return {'status': 'MODEL_FAILURE', 'code': code,
                    'attempts': attempts, 'result': None}

        decision = (result.get('qg') or {}).get('decision')
        if decision == 'ABSTAIN_NEEDS_REVIEW':
            entry.update(outcome='VALID_ABSTENTION', code=None)
            attempts.append(entry)
            return {'status': 'VALID_ABSTENTION', 'code': None,
                    'attempts': attempts, 'result': result}
        entry.update(outcome='VALIDATED_OUTPUT', code=None)
        attempts.append(entry)
        return {'status': 'VALIDATED_OUTPUT', 'code': None,
                'attempts': attempts, 'result': result}

    return {'status': 'MODEL_FAILURE', 'code': 'QG_RETRY_EXHAUSTED',
            'attempts': attempts, 'result': None}


__all__ = ['MAX_ATTEMPTS', 'RECOVERABLE', 'UNRECOVERABLE', 'is_recoverable',
           'run_with_retries']
