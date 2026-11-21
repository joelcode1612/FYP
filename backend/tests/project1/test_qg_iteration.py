"""CP-02: bounded iterative prompting.

The properties that matter, in the order they matter:

1. A retry carries the *exact* validation failure, not a restatement of the task.
2. The cycle stops on success, on a justified abstention, on an unrecoverable
   failure, and on budget exhaustion — and each of those is a distinct outcome.
3. Budget is reserved per attempt, so a three-attempt operation costs three slots.

A test that only proved "it retries" would pass for a loop that retried the same
broken prompt three times. Every retry test here also asserts what the model was
told on the retry.
"""
from __future__ import annotations

import copy
from types import SimpleNamespace

import pytest

from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.direct_qg_service import WORKFLOW_CONTRACT_VERSION, build_service
from sitewise.project1.measurement_policy import lab_authority
from sitewise.project1.qg_contract import CONTRACT_VERSION
from sitewise.project1.qg_iteration import (
    MAX_ATTEMPTS, RECOVERABLE, UNRECOVERABLE, is_recoverable, run_with_retries,
)

UNCERTAINTY_ID = 'a1b2c3d4-0000-4000-8000-000000000000'
CONFIRMATION_ID = 'b2c3d4e5-0000-4000-8000-000000000000'
TEXT = ('Would eligible customers find RM13 acceptable for a 12 oz takeaway '
        'iced latte?')


def packet():
    value = {
        'schema_version': 'business-context-package/1.1',
        'assessment_id': 'SYN-ASSESS-1',
        'confirmation': {'status': 'CURRENT_CONFIRMED', 'id': CONFIRMATION_ID,
                         'revision': 1},
        'confirmed_uncertainty': {
            'id': UNCERTAINTY_ID, 'confirmation_id': CONFIRMATION_ID,
            'actor_user_id': 'c3d4e5f6-0000-4000-8000-000000000000',
            'exact_text': TEXT},
        'geography': None,
        'permissions': {'qj_execution': False},
        'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04',
                        'value': 'takeaway only'}],
        'supporting_sources': [],
    }
    value['packet_hash'] = digest(value)
    return value


def draft(**overrides):
    value = {
        'decision': 'DRAFT',
        'question': 'Would you find a 12 oz takeaway iced latte at RM13 acceptable?',
        'justification': 'One neutral question about the confirmed offer.',
        'construct_interpretation': 'Stated acceptability of the confirmed offer.',
        'response_options': ['Acceptable', 'Not acceptable', "Don't know"],
        'response_codes': ['ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW'],
        'routing': {'ACCEPTABLE': 'END', 'NOT_ACCEPTABLE': 'END', 'DONT_KNOW': 'END'},
        'reference_period': 'At the moment the respondent views the offer.',
        'measurement_description': 'Share describing the offer as acceptable.',
        'denominator_specification': ('ACCEPTABLE and NOT_ACCEPTABLE respondents; '
                                      'DONT_KNOW reported separately.'),
        'limitations': 'Stated acceptability only. Not a purchase estimate.',
        'unresolved_assumptions': [],
        'missing_business_facts': [],
        'used_confirmed_facts': ['RM13', '12'],
    }
    value.update(overrides)
    return value


def abstention():
    return {'decision': 'ABSTAIN_NEEDS_REVIEW', 'question': '',
            'justification': 'No price is confirmed.',
            'missing_business_facts': ['PRICE'], 'used_confirmed_facts': []}


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------
def test_a_validation_defect_is_recoverable():
    assert is_recoverable('QG_UNSOURCED_AMOUNT')
    assert 'QG_UNSOURCED_AMOUNT' in RECOVERABLE


@pytest.mark.parametrize('code', sorted(UNRECOVERABLE))
def test_a_governance_refusal_is_not_recoverable(code):
    """Rewording a question cannot create a confirmation or a budget slot."""
    assert not is_recoverable(code)


def test_an_unlisted_code_defaults_to_unrecoverable():
    """The safe default: three calls to rediscover the same refusal is a leak."""
    assert not is_recoverable('SOMETHING_NEW')


# ---------------------------------------------------------------------------
# Cycle behaviour
# ---------------------------------------------------------------------------
def test_success_ends_the_cycle_immediately():
    calls = []

    def generate(feedback, attempt):
        calls.append((feedback, attempt))
        return {'qg': {'decision': 'DRAFT'}}

    run = run_with_retries(generate, prompt_version='QG-PROPOSE-6-CAND')
    assert run['status'] == 'VALIDATED_OUTPUT'
    assert len(run['attempts']) == 1 and calls[0][0] is None


def test_an_abstention_is_returned_not_retried():
    calls = []

    def generate(feedback, attempt):
        calls.append(attempt)
        return {'qg': {'decision': 'ABSTAIN_NEEDS_REVIEW',
                       'missing_business_facts': ['PRICE']}}

    run = run_with_retries(generate, prompt_version='QG-PROPOSE-6-CAND')
    assert run['status'] == 'VALID_ABSTENTION'
    assert calls == [1], 'an abstention must not be resubmitted to the model'


def test_a_recoverable_failure_retries_with_the_exact_code_and_instruction():
    seen = []

    def generate(feedback, attempt):
        seen.append((attempt, feedback))
        if attempt == 1:
            raise WorkflowHeld('QG_UNSOURCED_AMOUNT')
        return {'qg': {'decision': 'DRAFT'}}

    run = run_with_retries(generate, prompt_version='QG-PROPOSE-6-CAND')
    assert run['status'] == 'VALIDATED_OUTPUT'
    assert len(run['attempts']) == 2
    second = seen[1][1]
    assert second['code'] == 'QG_UNSOURCED_AMOUNT'
    assert second['instruction'] == RECOVERABLE['QG_UNSOURCED_AMOUNT']
    assert 'confirmed_facts' in second['instruction']


def test_three_recoverable_failures_exhaust_the_cycle():
    def generate(feedback, attempt):
        raise WorkflowHeld('QG_UNSOURCED_NUMBER')

    run = run_with_retries(generate, attempt_limit=3,
                           prompt_version='QG-PROPOSE-6-CAND')
    assert run['status'] == 'MODEL_FAILURE'
    assert run['code'] == 'QG_RETRY_EXHAUSTED'
    assert len(run['attempts']) == 3
    assert [a['outcome'] for a in run['attempts']] == ['MODEL_FAILURE'] * 3


def test_an_unrecoverable_failure_stops_on_the_first_attempt():
    calls = []

    def generate(feedback, attempt):
        calls.append(attempt)
        raise WorkflowHeld('BCB_CONFIRMATION_REQUIRED')

    run = run_with_retries(generate, prompt_version='QG-PROPOSE-6-CAND')
    assert run['status'] == 'BLOCKED_INPUT'
    assert run['code'] == 'BCB_CONFIRMATION_REQUIRED'
    assert calls == [1]


def test_budget_exhaustion_stops_before_the_model_is_called():
    called = []

    def generate(feedback, attempt):
        called.append(attempt)
        return {'qg': {'decision': 'DRAFT'}}

    def reserve(attempt):
        raise WorkflowHeld('MODEL_ATTEMPT_BUDGET_EXHAUSTED')

    run = run_with_retries(generate, reserve=reserve)
    assert run['status'] == 'BLOCKED_INPUT'
    assert run['attempts'][0]['outcome'] == 'NOT_EXECUTED'
    assert called == []


def test_budget_is_reserved_once_per_attempt():
    reserved = []

    def generate(feedback, attempt):
        if attempt < 3:
            raise WorkflowHeld('QG_ROUTING_DRIFT')
        return {'qg': {'decision': 'DRAFT'}}

    run = run_with_retries(generate, reserve=lambda n: reserved.append(n),
                           prompt_version='QG-PROPOSE-6-CAND')
    assert run['status'] == 'VALIDATED_OUTPUT'
    assert reserved == [1, 2, 3], 'a three-attempt operation must cost three slots'


def test_attempt_ledger_links_each_revision_to_the_failure_that_caused_it():
    def generate(feedback, attempt):
        if attempt == 1:
            raise WorkflowHeld('QG_LIMITATIONS_INCOMPLETE')
        return {'qg': {'decision': 'DRAFT'}}

    run = run_with_retries(generate, prompt_version='QG-PROPOSE-6-CAND')
    first, second = run['attempts']
    assert first['input_revision'] == 'initial'
    assert first['prompt_revision'] == 'QG-PROPOSE-6-CAND'
    assert first['code'] == 'QG_LIMITATIONS_INCOMPLETE'
    assert second['input_revision'] == 'feedback.1'
    assert second['prompt_revision'] == 'QG-PROPOSE-6-CAND+feedback.1'
    assert second['feedback_code'] == 'QG_LIMITATIONS_INCOMPLETE'


def test_a_malformed_answer_is_recorded_as_a_model_failure_without_retry():
    def generate(feedback, attempt):
        raise ValueError('schema mismatch')

    run = run_with_retries(generate)
    assert run['status'] == 'MODEL_FAILURE'
    assert run['code'] == 'ValueError'
    assert len(run['attempts']) == 1


def test_an_invalid_attempt_limit_is_refused():
    with pytest.raises(WorkflowHeld, match='QG_ATTEMPT_LIMIT_INVALID'):
        run_with_retries(lambda *a: None, attempt_limit=0)


def test_the_default_limit_is_three():
    assert MAX_ATTEMPTS == 3


# ---------------------------------------------------------------------------
# Through the production service
# ---------------------------------------------------------------------------
class Contexts:
    def __init__(self, value=None):
        self.value = packet() if value is None else value
        self.calls = 0

    def retrieve(self, assessment_id, context_id, actor):
        self.calls += 1
        return {'packet': copy.deepcopy(self.value),
                'qj_execution_authorized': False}


def service(runner):
    return build_service(contexts=Contexts(), authority=lab_authority(),
                         runner=runner, enabled=True)


def call(svc, **overrides):
    kwargs = dict(assessment_id='A', context_id='C',
                  actor=SimpleNamespace(user_id='U'))
    kwargs.update(overrides)
    return svc.prepare_candidate(**kwargs)


def test_prepare_candidate_generates_from_facts_without_a_measurement():
    svc = service(lambda stage, payload, output_type: draft())
    result = call(svc)
    assert result['status'] == 'VALIDATED_OUTPUT'
    assert result['qg']['decision'] == 'DRAFT'
    assert result['qj'] is None
    assert result['contract_version'] == CONTRACT_VERSION
    assert result['composition']['qg_contract_version'] == CONTRACT_VERSION
    assert result['composition']['contract_version'] == WORKFLOW_CONTRACT_VERSION


def test_prepare_candidate_retries_a_recoverable_failure_end_to_end():
    calls = []

    def runner(stage, payload, output_type):
        calls.append(payload)
        if len(calls) == 1:
            return draft(question='Would you find a 12 oz latte at RM12 acceptable?')
        return draft()

    result = call(service(runner))
    assert result['status'] == 'VALIDATED_OUTPUT'
    assert len(result['attempts']) == 2
    assert result['attempts'][0]['code'] == 'QG_UNSOURCED_AMOUNT'
    assert calls[1]['previous_attempt']['code'] == 'QG_UNSOURCED_AMOUNT'


def test_prepare_candidate_returns_an_abstention_without_retrying():
    def runner(stage, payload, output_type):
        return abstention()

    result = call(service(runner))
    assert result['status'] == 'VALID_ABSTENTION'
    assert result['qg']['missing_business_facts'] == ['PRICE']
    assert len(result['attempts']) == 1
    assert result['fielding_authorized'] is False


def test_prepare_candidate_reports_blocked_input_for_a_stale_context():
    contexts = Contexts()
    contexts.value = packet()
    contexts.value['confirmation']['status'] = 'SUPERSEDED'
    contexts.value['packet_hash'] = digest(
        {k: v for k, v in contexts.value.items() if k != 'packet_hash'})
    svc = build_service(contexts=contexts, authority=lab_authority(),
                        runner=lambda *a: draft(), enabled=True)
    result = call(svc)
    assert result['status'] == 'BLOCKED_INPUT'
    assert result['code'] == 'BCB_CONFIRMATION_REQUIRED'


def test_prepare_candidate_respects_an_exhausted_budget():
    svc = service(lambda *a: draft())

    def reserve(attempt):
        raise WorkflowHeld('MODEL_ATTEMPT_BUDGET_EXHAUSTED')

    result = call(svc, reserve=reserve)
    assert result['status'] == 'BLOCKED_INPUT'
    assert result['code'] == 'MODEL_ATTEMPT_BUDGET_EXHAUSTED'


# ---------------------------------------------------------------------------
# Prompt selection is separate from the governed ledger stage
# ---------------------------------------------------------------------------
def test_a_runner_without_the_capability_still_gets_the_three_argument_call():
    """The adapter must not break every existing double and third-party runner."""
    from sitewise.project1.research import _call_runner

    class Plain:
        def __call__(self, stage, payload, output_type):
            return (stage, None)

    assert _call_runner(Plain(), 'QG', {}, None, prompt_key='QG_PROPOSAL') == ('QG', None)


def test_a_capable_runner_receives_the_prompt_key():
    from sitewise.project1.research import _call_runner

    class Capable:
        supports_prompt_key = True

        def __call__(self, stage, payload, output_type, *, prompt_key=None):
            return (stage, prompt_key)

    assert _call_runner(Capable(), 'QG', {}, None,
                        prompt_key='QG_PROPOSAL') == ('QG', 'QG_PROPOSAL')


def test_the_ledger_stage_stays_qg_while_the_real_prompt_version_is_recorded():
    """The attempts table only accepts BDJ/QJ/QG; the prompt is a version, not a stage.

    Recording the actual prompt version is what keeps the audit trail honest: a
    reader can tell which template ran without the schema needing a new stage.
    """
    from sitewise.project1.prompts import PROMPTS
    from sitewise.project1.provider import ModelRunner
    from sitewise.project1.qg_contract import QGCandidate

    reserved = []

    class Ledger:
        def reserve(self, stage, version, prompt_hash, request_hash):
            reserved.append((stage, version))
            return 1

        def finish(self, *a):
            pass

    class Provider:
        mode = 'json_schema'

        def complete(self, messages, output_type):
            return {'decision': 'ABSTAIN_NEEDS_REVIEW', 'question': '',
                    'justification': 'No confirmed price.', 'missing_business_facts': ['PRICE']}

    runner = ModelRunner(Provider(), Ledger(), PROMPTS,
                         disclosure=SimpleNamespace(require_current=lambda *a: None))
    runner('QG', {'confirmed_facts': {}}, QGCandidate, prompt_key='QG_PROPOSAL')
    assert reserved == [('QG', 'QG-PROPOSE-6-CAND')]
    assert PROMPTS['QG_PROPOSAL'].version == 'QG-PROPOSE-6-CAND'
