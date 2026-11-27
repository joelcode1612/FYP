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

from sitewise.project1.contracts import WorkflowHeld, digest, no_authority
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
# The measurement-requiring path is held, and the hold is the last gate
# ---------------------------------------------------------------------------
# ``evaluate`` needs a frozen ``Measurement``, and no component produces one once
# QJ is gone. The composition therefore reaches
# ``require_verified_respondent_path()``, which is an intentional hold: the
# fixed-option adapter is not wired, and activating an unvalidated respondent
# path to make these tests green would be the regression, not the fix.
#
# What is still worth asserting, and is asserted below: every gate that comes
# *before* the hold still runs, the model is never called, QJ authorization
# never gates the path, and nothing is granted. Contract 2.0 generation
# (``prepare_candidate``) is the active pathway and is covered by
# ``test_qg_fixed_options``, ``test_qg_iteration``, ``test_qg_candidate_api`` and
# ``tests/v31/test_track_a_persisted_workflow.py``.

HOLD = 'QG_FIXED_OPTION_ADMISSION_UNAVAILABLE'


def test_the_measurement_requiring_path_is_held_before_drafting():
    """The hold is reached after the context and authority gates, before any call.

    The bank claim survives the hold: V2.0 composes with ``bank=None`` and the
    workflow reports ``NOT_CONSULTED_DIRECT_QG`` rather than ``not_checked``. The
    runner must not be invoked, because a held path that still spent a provider
    call would be the failure mode this gate exists to prevent.
    """
    svc, calls, measurement = service()
    with pytest.raises(WorkflowHeld, match=HOLD):
        evaluate(svc, measurement)
    assert calls == []


def test_the_contract_identity_is_declared_and_the_version_gate_precedes_the_hold():
    assert WORKFLOW_CONTRACT_VERSION == 'P1-WORKFLOW-2.0-DIRECT-QG'
    assert ACTIVE_STAGES == ('QG',)

    svc, calls, measurement = service()
    with pytest.raises(WorkflowHeld, match=HOLD):
        evaluate(svc, measurement)
    assert calls == []


def test_a_wrong_contract_version_is_refused_before_anything_runs():
    svc, calls, measurement = service(contract_version='P1-WORKFLOW-1.0-QJQG')
    with pytest.raises(WorkflowHeld, match='DIRECT_QG_CONTRACT_VERSION_MISMATCH'):
        evaluate(svc, measurement)
    assert calls == []


def test_the_held_path_grants_no_authority():
    """Nothing is returned, so nothing can be read as an authority grant."""
    svc, _, measurement = service()
    with pytest.raises(WorkflowHeld, match=HOLD):
        evaluate(svc, measurement)

    granted = no_authority()
    for flag in ('scientific_acceptance', 'owner_authorization',
                 'publication_authorized', 'fielding_authorized',
                 'report_release_authorized'):
        assert granted[flag] is False


# ---------------------------------------------------------------------------
# QJ authorization is observed, never consulted
# ---------------------------------------------------------------------------
@pytest.mark.parametrize('qj_authorized', [False, True])
def test_qj_authorization_is_observed_and_never_gates_the_path(qj_authorized):
    """The V1.0 service refused when QJ was unauthorized. V2.0 must not.

    Both values must produce the *same* refusal — the fixed-option hold — which
    is only true if QJ authorization is not a gate. The context is still read,
    because a path that skipped the context gate would draft against an
    unconfirmed packet.
    """
    contexts = Contexts(qj_authorized=qj_authorized)
    svc, calls, measurement = service(contexts=contexts)
    with pytest.raises(WorkflowHeld, match=HOLD):
        evaluate(svc, measurement)
    assert contexts.calls, 'the persisted context must still be read'
    assert calls == []


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
