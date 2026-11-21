"""§5.4 composition: the workflow is now reachable from production-shaped code.

These tests prove the composition exists, wires the real authority, and fails
closed at every gate. They deliberately do **not** prove a production execution:
the persisted context reports ``qj_execution_authorized: False`` and that gate is
what stops a real run. Faking that flag in a test would prove only that a flag can
be set.
"""
from __future__ import annotations

import copy

import pytest

from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.measurement_policy import lab_authority
from sitewise.project1.qj_qg_service import QjQgService, build_service

UNCERTAINTY_ID = 'a1b2c3d4-0000-4000-8000-000000000000'
CONFIRMATION_ID = 'b2c3d4e5-0000-4000-8000-000000000000'


def packet():
    value = {
        'schema_version': 'business-context-package/1.1',
        'context_version': 'BCB-V1-1.1.0',
        'identity': {'assessment_id': 'c3d4e5f6-0000-4000-8000-000000000000',
                     'tenant_id': 'd4e5f6a7-0000-4000-8000-000000000000',
                     'owner_id': 'e5f6a7b8-0000-4000-8000-000000000000'},
        'confirmation': {'status': 'CURRENT_CONFIRMED', 'id': CONFIRMATION_ID,
                         'revision': 1, 'digest': 'synthetic'},
        'confirmed_uncertainty': {
            'id': UNCERTAINTY_ID, 'confirmation_id': CONFIRMATION_ID,
            'actor_user_id': 'e5f6a7b8-0000-4000-8000-000000000000',
            'exact_text': ('Would eligible customers find RM13 acceptable for a '
                           '12 oz takeaway iced latte?')},
        'geography': None,
        'permissions': {'report_admission': False, 'report_release': False,
                        'qj_execution': False, 'qg_execution': False},
        'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04'}],
        'supporting_sources': [],
    }
    value['packet_hash'] = digest(value)
    return value


def measurement():
    return dict(
        uncertainty_version=UNCERTAINTY_ID,
        construct='stated price acceptability',
        population='eligible screened respondents',
        timeframe='at presentation of the hypothetical offer',
        stimulus='12 oz takeaway iced latte at RM13',
        response_options=['Acceptable', 'Not acceptable', 'Unsure'],
        response_codes=['ACCEPTABLE', 'NOT_ACCEPTABLE', 'UNSURE'],
        routing={code: 'RECORD' for code in
                 ('ACCEPTABLE', 'NOT_ACCEPTABLE', 'UNSURE')},
        denominator='ACCEPTABLE and NOT_ACCEPTABLE respondents; UNSURE apart',
        source_refs=[UNCERTAINTY_ID],
        limitations=('Stated acceptability of one hypothetical price; not a maximum '
                     'willingness-to-pay and not a purchase forecast.'))


class Contexts:
    """Stands in for PersistedBusinessContextService.retrieve."""

    def __init__(self, *, authorized=False, payload=None):
        self.authorized = authorized
        self.payload = payload if payload is not None else packet()

    def retrieve(self, assessment_id, context_id, actor):
        return {'contract_version': 'persisted-business-context/1',
                'context_id': context_id,
                'assessment_id': assessment_id,
                'packet': copy.deepcopy(self.payload),
                'qj_execution_authorized': self.authorized,
                'qg_execution_authorized': False}


class Bank:
    def lookup(self, *_args):
        return {'outcome': 'verified_equivalent', 'item_version': 'SYNTHETIC-Q1@1',
                'approval_receipt': 'SYNTHETIC-PRIVATE-LAB-ONLY',
                'scope': 'SYNTHETIC_PRIVATE_LAB_ONLY'}

    def verify_receipt(self, *_args):
        pass


def runner(stage, _packet, _output_type):
    assert stage == 'QJ'
    return {'route': 'CUSTOMER_SURVEY_CANDIDATE',
            'justification': 'Synthetic composition fixture.',
            'measurement': measurement()}


_UNSET = object()


def service(*, enabled=True, authorized=False, bank=_UNSET, authority=_UNSET):
    """Build the composition; an explicit ``None`` means 'omit this dependency'."""
    return build_service(contexts=Contexts(authorized=authorized),
                         authority=lab_authority() if authority is _UNSET else authority,
                         bank=Bank() if bank is _UNSET else bank,
                         runner=runner, enabled=enabled)


def held(code: str, function) -> None:
    with pytest.raises(WorkflowHeld) as caught:
        function()
    assert str(caught.value) == code


def test_the_workflow_is_now_reachable_from_a_production_shaped_composition():
    """Before §5.4 there was no production caller at all; now there is one."""
    result = service(authorized=True).evaluate(assessment_id='a', context_id='b',
                                               actor=object())
    assert result['qj']['route'] == 'CUSTOMER_SURVEY_CANDIDATE'
    assert result['composition']['source'] == 'persisted-business-context/1'


def test_a_composed_run_never_confers_authority():
    result = service(authorized=True).evaluate(assessment_id='a', context_id='b',
                                               actor=object())
    for flag in ('scientific_acceptance', 'owner_authorization', 'publication_authorized',
                 'fielding_authorized', 'report_release_authorized'):
        assert result[flag] is False
    assert result['composition']['qj_execution_authorized'] is False
    assert result['composition']['qg_execution_authorized'] is False


def test_the_persisted_context_gate_stops_a_real_run():
    """The honest production state: composition succeeds, execution is refused."""
    held('QJQG_CONTEXT_DOES_NOT_AUTHORIZE_QJ',
         lambda: service(authorized=False).evaluate(assessment_id='a', context_id='b',
                                                    actor=object()))


def test_a_disabled_service_does_not_compose_at_all():
    held('QJQG_NOT_ENABLED',
         lambda: service(enabled=False).evaluate(assessment_id='a', context_id='b',
                                                 actor=object()))


def test_a_missing_bank_is_refused():
    held('QJQG_BANK_MISSING',
         lambda: service(authorized=True, bank=None).evaluate(
             assessment_id='a', context_id='b', actor=object()))


def test_an_unverified_authority_is_refused_by_the_composition():
    class NoOp:
        def admit_qj(self, p): return {'uncertainty_version': UNCERTAINTY_ID}
        def require_current(self, *a): pass
        def validate_measurement(self, *a): pass
        def require_drafting(self, *a): pass

    held('QJQG_AUTHORITY_UNVERIFIED',
         lambda: service(authorized=True, authority=NoOp()).evaluate(
             assessment_id='a', context_id='b', actor=object()))


def test_the_gate_report_states_what_is_missing():
    report = service(enabled=False).gates()
    assert report['service_enabled'] is False
    assert report['measurement_authority'] == 'QJ-MEASUREMENT-INVARIANTS-0.1'
    assert report['fielding_authorized'] is False
    assert report['scientific_acceptance'] is False
