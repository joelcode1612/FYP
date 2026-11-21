"""The V2.0 production composition: BCB -> QG, with no QJ stage and no bank.

What these tests are for
------------------------
``ResearchWorkflow`` had no production caller before V1.0, which is why every
authority and bank in the tree was a double. V1.0 added ``QjQgService``; V2.0
retires QJ and, with it, the bank gate. The claim "the bank gate is gone" is only
true if the composed object cannot reach a bank at all — so the central test here
composes the service and asserts the workflow was built with ``bank=None`` and
still produced a candidate.

The second claim is narrower and easier to get wrong: removing QJ must not mean
removing the context gate. A service that drafts against an unconfirmed or
tampered packet would be a regression dressed as a simplification.
"""
from __future__ import annotations

import copy
import importlib.util
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest

from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.direct_qg_service import (
    ACTIVE_STAGES, WORKFLOW_CONTRACT_VERSION, DirectQgService, build_service,
)
from sitewise.project1.measurement_policy import LAB_PRICE_RM13_POLICY, lab_authority
from sitewise.project1.question_bank import STATUS as BANK_STATUS

UNCERTAINTY_ID = 'a1b2c3d4-0000-4000-8000-000000000000'
CONFIRMATION_ID = 'b2c3d4e5-0000-4000-8000-000000000000'
EXACT_TEXT = ('Would eligible customers find RM13 acceptable for a 12 oz takeaway '
              'iced latte?')
SYNTHETIC_SOURCE = 'CANONICAL_SYNTHETIC_FIXTURE'
SYNTHETIC_REF = 'tests/m2_bcb/lab_measurement_v0_1.py::canonical_spec'


def _baseline():
    path = (Path(__file__).resolve().parents[1] / 'm2_bcb'
            / 'lab_measurement_v0_1.py')
    spec = importlib.util.spec_from_file_location('lab_measurement_v0_1_service', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def frozen_measurement():
    return _baseline().canonical_spec().to_contract([UNCERTAINTY_ID], UNCERTAINTY_ID)


def packet(*, status='CURRENT_CONFIRMED'):
    value = {
        'schema_version': 'business-context-package/1.1',
        'confirmation': {'status': status, 'id': CONFIRMATION_ID, 'revision': 1},
        'confirmed_uncertainty': {
            'id': UNCERTAINTY_ID, 'confirmation_id': CONFIRMATION_ID,
            'actor_user_id': 'c3d4e5f6-0000-4000-8000-000000000000',
            'exact_text': EXACT_TEXT},
        'geography': None,
        'permissions': {'qj_execution': False},
        'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04'}],
        'supporting_sources': [],
    }
    value['packet_hash'] = digest(value)
    return value


def question(measurement):
    return (f'{measurement.stimulus} Asked of {measurement.population} '
            f'Timing: {measurement.timeframe} Would you describe this offer as acceptable?')


class Contexts:
    """Stands in for PersistedBusinessContextService.retrieve."""

    def __init__(self, value=None, *, qj_authorized=False):
        self.value = packet() if value is None else value
        self.qj_authorized = qj_authorized
        self.calls = []

    def retrieve(self, assessment_id, context_id, actor):
        self.calls.append((assessment_id, context_id, actor))
        return {'packet': copy.deepcopy(self.value),
                'qj_execution_authorized': self.qj_authorized}


def service(*, contexts=None, runner=None, enabled=True, authority=None,
            contract_version=WORKFLOW_CONTRACT_VERSION):
    measurement = frozen_measurement()
    calls = []

    def default_runner(stage, payload, output_type):
        calls.append(stage)
        return {'decision': 'DRAFT', 'question': question(measurement),
                'measurement': measurement.model_dump(),
                'justification': 'Synthetic composed candidate only.'}

    def recording(stage, payload, output_type):
        calls.append(stage)
        return runner(stage, payload, output_type)

    svc = build_service(
        contexts=contexts if contexts is not None else Contexts(),
        authority=authority or lab_authority(LAB_PRICE_RM13_POLICY),
        runner=recording if runner else default_runner,
        enabled=enabled)
    svc.contract_version = contract_version
    return svc, calls, measurement


def evaluate(svc, measurement, **overrides):
    kwargs = dict(assessment_id=uuid4(), context_id=uuid4(),
                  actor=SimpleNamespace(user_id=uuid4()),
                  frozen_measurement=measurement,
                  measurement_source=SYNTHETIC_SOURCE,
                  measurement_source_ref=SYNTHETIC_REF)
    kwargs.update(overrides)
    return svc.evaluate(**kwargs)


# ---------------------------------------------------------------------------
# The active path runs, and runs without a bank
# ---------------------------------------------------------------------------
def test_composed_service_drafts_without_a_bank_and_without_qj():
    """The bank gate is removed structurally: the workflow is built with None."""
    svc, calls, measurement = service()
    result = evaluate(svc, measurement)
    assert calls == ['QG']
    assert result['qg']['decision'] == 'DRAFT'
    assert result['qj'] is None
    assert result['bank'] == 'NOT_CONSULTED_DIRECT_QG'
    assert result['composition']['bank_required'] is False
    assert result['composition']['qj_executed'] is False


def test_the_contract_version_is_recorded_on_the_result():
    svc, _, measurement = service()
    result = evaluate(svc, measurement)
    assert result['composition']['contract_version'] == 'P1-WORKFLOW-2.0-DIRECT-QG'
    assert result['composition']['active_stages'] == ['QG']
    assert ACTIVE_STAGES == ('QG',)


def test_a_wrong_contract_version_is_refused_before_anything_runs():
    svc, calls, measurement = service(contract_version='P1-WORKFLOW-1.0-QJQG')
    with pytest.raises(WorkflowHeld, match='DIRECT_QG_CONTRACT_VERSION_MISMATCH'):
        evaluate(svc, measurement)
    assert calls == []


def test_the_composed_result_still_grants_no_authority():
    svc, _, measurement = service()
    result = evaluate(svc, measurement)
    assert result['candidate_authority'] == 'ENTREPRENEUR_REVIEW_ONLY'
    for flag in ('scientific_acceptance', 'owner_authorization',
                 'publication_authorized', 'fielding_authorized',
                 'report_release_authorized'):
        assert result[flag] is False
    assert result['composition']['qg_execution_authorized'] is False


# ---------------------------------------------------------------------------
# QJ authorization is observed, never consulted
# ---------------------------------------------------------------------------
def test_a_context_that_does_not_authorize_qj_still_runs_the_active_path():
    """The V1.0 service refused here. That refusal is what V2.0 removes.

    The persisted context reports ``qj_execution_authorized: False`` today. Under
    V1.0 that blocked the only production composition. A path that never runs QJ
    must not be blocked by a QJ permission, or the retired stage is still a gate.
    """
    contexts = Contexts(qj_authorized=False)
    svc, calls, measurement = service(contexts=contexts)
    result = evaluate(svc, measurement)
    assert calls == ['QG'] and result['qg']['decision'] == 'DRAFT'
    assert result['composition']['qj_execution_authorized_observed'] is False


def test_a_context_that_does_authorize_qj_gains_nothing_from_it():
    contexts = Contexts(qj_authorized=True)
    svc, _, measurement = service(contexts=contexts)
    result = evaluate(svc, measurement)
    assert result['composition']['qj_execution_authorized_observed'] is True
    assert result['fielding_authorized'] is False
    assert result['candidate_authority'] == 'ENTREPRENEUR_REVIEW_ONLY'


# ---------------------------------------------------------------------------
# Composition gates fail closed
# ---------------------------------------------------------------------------
@pytest.mark.parametrize('kwargs,code', [
    (dict(enabled=False), 'DIRECT_QG_NOT_ENABLED'),
])
def test_service_gates_refuse(kwargs, code):
    svc, calls, measurement = service(**kwargs)
    with pytest.raises(WorkflowHeld, match=code):
        evaluate(svc, measurement)
    assert calls == []


def test_missing_context_service_is_refused():
    svc = DirectQgService(contexts=None, authority=lab_authority(LAB_PRICE_RM13_POLICY),
                          runner=lambda *a: None, enabled=True)
    with pytest.raises(WorkflowHeld, match='DIRECT_QG_CONTEXT_SERVICE_MISSING'):
        evaluate(svc, frozen_measurement())


def test_unverified_authority_is_refused():
    class NoPolicy:
        pass

    svc, calls, measurement = service(authority=NoPolicy())
    with pytest.raises(WorkflowHeld, match='DIRECT_QG_AUTHORITY_UNVERIFIED'):
        evaluate(svc, measurement)
    assert calls == []


def test_missing_runner_is_refused():
    svc = DirectQgService(contexts=Contexts(),
                          authority=lab_authority(LAB_PRICE_RM13_POLICY),
                          runner=None, enabled=True)
    with pytest.raises(WorkflowHeld, match='DIRECT_QG_RUNNER_MISSING'):
        evaluate(svc, frozen_measurement())


def test_no_supplied_measurement_is_refused_at_composition():
    """The unresolved dependency, surfaced where composition happens.

    Nothing in this tree produces a Measurement once QJ is gone, so a caller that
    supplies none gets a refusal naming the gap rather than a fabricated spec.
    """
    svc, calls, _ = service()
    with pytest.raises(WorkflowHeld, match='DIRECT_QG_MEASUREMENT_NOT_SUPPLIED'):
        evaluate(svc, None)
    assert calls == []


# ---------------------------------------------------------------------------
# Removing QJ did not remove the context gate
# ---------------------------------------------------------------------------
def test_an_unconfirmed_context_is_still_refused():
    svc, calls, measurement = service(contexts=Contexts(packet(status='SUPERSEDED')))
    with pytest.raises(WorkflowHeld, match='BCB_CONFIRMATION_REQUIRED'):
        evaluate(svc, measurement)
    assert calls == []


def test_a_tampered_packet_is_still_refused():
    value = packet()
    value['confirmed_uncertainty']['exact_text'] = 'An unconfirmed rewriting.'
    svc, calls, measurement = service(contexts=Contexts(value))
    with pytest.raises(WorkflowHeld, match='BCB_PACKET_FINGERPRINT_INVALID'):
        evaluate(svc, measurement)
    assert calls == []


# ---------------------------------------------------------------------------
# CP-05: the deferred bank is identifiable, not silently missing
# ---------------------------------------------------------------------------
def test_the_bank_is_deferred_by_contract_and_says_so():
    assert BANK_STATUS == 'DEFERRED_BY_CONTRACT_CHANGE_P1_WORKFLOW_2_0'


def test_gates_report_no_bank_requirement_rather_than_omitting_it():
    svc, _, _ = service()
    gates = svc.gates()
    assert gates['bank_required'] is False
    assert gates['active_stages'] == ['QG']
    assert gates['version_resolution'] is True
    assert gates['contract_version'] == WORKFLOW_CONTRACT_VERSION
    assert gates['fielding_authorized'] is False
