"""QJ synthetic disclosure adapter: positive, negative and no-regression tests.

The adapter exists because ``ModelRunner`` calls ``disclosure.require_current()``
before ``ledger.reserve()``, and the only disclosure implementation was BDJ-scoped
and refuses QJ by design. These tests establish that the QJ adapter is a real
control over a **real** ``BusinessContextBuilderV1`` packet, not over a bespoke
shape:

* the context is produced by the production builder under ``BCB-V1-1.1.0`` from
  the preserved synthetic BCB fixture (``tests/project1/bcb/``), with the request
  purpose set to ``QJ_CONTEXT`` and ``geography`` cleared to ``null`` per D02;
* a fully valid packet is accepted and the receipt names the checks performed;
* every refusal condition actually refuses, including "not builder output";
* every refusal happens before ``ledger.reserve()`` -- asserted on the ledger
  port, on the on-disk budget state file, and by proving no HTTP client can be
  constructed;
* the BDJ adapter still refuses QJ, unchanged.

No network call is made. ``settings.tokenharbor_enabled`` is never flipped.
"""
from __future__ import annotations

import json
import sys
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path

BCB_SUPPORT = Path(__file__).resolve().parents[1] / 'bcb'
if str(BCB_SUPPORT) not in sys.path:
    sys.path.insert(0, str(BCB_SUPPORT))

import httpx
import pytest
from sandbox_support import (FixedClock as BcbClock,
                             SyntheticAuthorization as BcbAuthorization,
                             SyntheticSnapshots as BcbSnapshots,
                             load_fixture, request_for)

from sitewise.project1.contracts import QJOutput, WorkflowHeld
from sitewise.project1.provider import ENDPOINT, MODEL
from sitewise.project1.qj_disclosure import (
    CHECKS,
    QjImmutableContextReferences,
    SyntheticQjDisclosure,
    SyntheticQjTestScopeAuthorization,
    context_hash,
    validate_qj_synthetic,
)
from sitewise.services.business_context_v1 import (
    CONTEXT_VERSION,
    CURRENT_CONTEXT_VERSION,
    BusinessContextBuilderV1,
)

from campaign import RecordingLedger

HERE = Path(__file__).resolve().parent
AUTHORIZATION_PATH = HERE / 'qj_scope' / 'qj_test_scope_authorization.json'

NOW = datetime(2026, 11, 17, 12, 0, tzinfo=timezone.utc)
UNCERTAINTY_TEXT = ('Would office workers pay RM12 for a coffee and a light lunch '
                    'at this location?')
OBJECTIVE = {'objective_id': 'SYN-OBJ-QJ-01', 'objective': 'Would office workers pay RM12?'}

QJ_RESPONSE = json.dumps({
    'route': 'SCENARIO_ANALYSIS_REQUIRED',
    'justification': 'Profit needs cost, revenue and sensitivity evidence.',
    'measurement': None,
})


# --------------------------------------------------------------------------
# A real BusinessContextBuilderV1 packet, built offline
# --------------------------------------------------------------------------
def bcb_packet(*, uncertainty=True) -> dict:
    """Build a genuine BCB 1.1 packet from the preserved synthetic fixture.

    This is the production builder, not a hand-made dict: the fixture only
    supplies the synthetic source records. The request purpose is set to
    ``QJ_CONTEXT`` (the fixture is an EXPLANATION case) and ``geography`` is
    cleared because D02 excludes GEO from V1.
    """
    fixture = load_fixture()
    fixture['bindings']['geography'] = None
    fixture['request']['purpose'] = 'QJ_CONTEXT'
    fixture['decision']['scope']['purpose'] = 'QJ_CONTEXT'
    if uncertainty:
        fixture['bindings']['uncertainty'] = {
            'id': 'SYN-UNC-QJ-01',
            'confirmation_id': fixture['confirmation']['id'],
            'actor_user_id': fixture['assessment']['owner_user_id'],
            'exact_text': UNCERTAINTY_TEXT,
        }
    builder = BusinessContextBuilderV1(
        BcbAuthorization(fixture), BcbSnapshots(fixture), BcbClock(),
        contract=CURRENT_CONTEXT_VERSION)
    return builder.get_context(request_for(fixture))


def resign(packet: dict) -> dict:
    """Recompute ``packet_hash`` after a deliberate edit, so only the target check fires."""
    return {**packet, 'packet_hash': context_hash(packet)}


def envelope(packet: dict, **synthetic) -> dict:
    layer = {
        'data_class': 'SYNTHETIC_NONHUMAN',
        'synthetic': True,
        'human_subjects': False,
        'fixture_id': 'BCB-QJ-SYNTHETIC-1',
    }
    layer.update(synthetic)
    return {'context': packet, 'synthetic': layer, 'research_objective': OBJECTIVE}


def references_for(packet: dict) -> QjImmutableContextReferences:
    return QjImmutableContextReferences(
        assessment_id=packet['identity']['assessment_id'],
        confirmation_id=packet['confirmation']['id'],
        confirmed_revision=packet['confirmation']['revision'],
        context_version=packet['context_version'],
        builder_version=packet['context_version'],
        context_hash=packet['packet_hash'],
    )


def authorization_record() -> dict:
    return json.loads(AUTHORIZATION_PATH.read_text(encoding='utf-8'))


def valid_authorization(**overrides) -> SyntheticQjTestScopeAuthorization:
    record = authorization_record()
    values = {
        'authorization_id': record['authorization_id'],
        'valid_until': record['valid_until'],
        'tenant_id': record['tenant_id'],
        'authorised_operations': tuple(record['authorised_operations']),
        'scope': record['scope'],
        'purpose': record['purpose'],
        'data_class': record['data_class'],
        'synthetic': record['synthetic'],
        'human_subjects': record['human_subjects'],
        'production_adoption': record['production_adoption'],
        'owner_signature': record['owner_signature'],
        'scientific_approval': record['scientific_approval'],
        'geo_authority': record['geo_authority'],
        'stage': record['stage'],
    }
    values.update(overrides)
    return SyntheticQjTestScopeAuthorization(**values)


def refusal(*, context=None, packet=None, references=None, authorization=None,
            stage='QJ', endpoint=ENDPOINT, model=MODEL):
    """The code ``validate_qj_synthetic`` raises for this input, or None."""
    bcb = bcb_packet() if context is None else context
    passed = envelope(bcb) if packet is None else packet
    refs = references_for(bcb) if references is None else references
    auth = valid_authorization() if authorization is None else authorization
    try:
        validate_qj_synthetic(stage=stage, packet=passed, endpoint=endpoint,
                              model=model, authorization=auth, references=refs,
                              now=NOW)
    except WorkflowHeld as exc:
        return str(exc)
    return None


def _transport(recorder: dict, *, content=QJ_RESPONSE, model=MODEL):
    """A local ``httpx.MockTransport`` handler. No socket is opened."""
    def handler(request):
        recorder['requests'] = recorder.get('requests', 0) + 1
        recorder['url'] = str(request.url)
        recorder['method'] = request.method
        recorder['body'] = json.loads(request.content)
        return httpx.Response(200, json={
            'model': model,
            'choices': [{'finish_reason': 'stop', 'message': {'content': content}}],
        })

    return httpx.MockTransport(handler)


def _runner_for(transport, ledger, disclosure):
    from pydantic import SecretStr
    from sitewise.project1.prompts import PROMPTS
    from sitewise.project1.provider import ModelRunner, TokenHarbor

    provider = TokenHarbor(SecretStr('synthetic-local-transport-key'), enabled=True,
                           transport=transport)
    return ModelRunner(provider, ledger, PROMPTS, disclosure=disclosure)


def _forbidden_transport():
    def handler(request):
        raise AssertionError('a refusal must not reach the transport')

    return httpx.MockTransport(handler)


# --------------------------------------------------------------------------
# The context really is builder output, and the test record invents nothing
# --------------------------------------------------------------------------
def test_context_is_genuine_builder_output():
    packet = bcb_packet()
    assert packet['context_version'] == CURRENT_CONTEXT_VERSION == 'BCB-V1-1.1.0'
    assert packet['schema_version'] == 'business-context-package/1.1'
    assert packet['identity']['tenant_id'] == 'SYNTHETIC-TENANT-A'
    assert packet['geography'] is None
    assert packet['access']['scope']['purpose'] == 'QJ_CONTEXT'
    assert packet['confirmation']['status'] == 'CURRENT_CONFIRMED'
    assert packet['concept']['status'] == 'ENTREPRENEUR_CONFIRMED'
    assert packet['confirmed_uncertainty']['exact_text'] == UNCERTAINTY_TEXT
    assert not any(packet['permissions'].values())
    # The builder's own hash is reproducible, so a hand-made packet cannot pass.
    assert context_hash(packet) == packet['packet_hash']


def test_test_scope_authorization_invents_no_authority():
    record = authorization_record()
    assert record['scope'] == 'TEST_ONLY'
    assert record['production_adoption'] is False
    assert record['owner_signature'] is None
    assert record['scientific_approval'] is None
    assert record['geo_authority'] is None
    assert record['written_to_env'] is False
    assert record['data_class'] == 'SYNTHETIC_NONHUMAN'
    assert record['synthetic'] is True and record['human_subjects'] is False
    assert record['tenant_id'] == 'SYNTHETIC-TENANT-A'
    assert record['authorised_operations'] == ['QJ_SYNTHETIC_DISPATCH']
    assert any('approved research question' in row
               for row in record['does_not_authorise'])


# --------------------------------------------------------------------------
# Positive
# --------------------------------------------------------------------------
def test_valid_synthetic_qj_context_is_accepted_and_records_checks():
    packet = bcb_packet()
    disclosure = SyntheticQjDisclosure(valid_authorization(), references_for(packet),
                                       clock=lambda: NOW)
    ledger = RecordingLedger()
    recorder: dict = {}
    runner = _runner_for(_transport(recorder), ledger, disclosure)

    output = runner('QJ', envelope(packet), QJOutput)

    assert output['route'] == 'SCENARIO_ANALYSIS_REQUIRED'
    assert len(disclosure.records) == 1
    receipt = disclosure.records[0]
    assert receipt.checks == CHECKS
    assert receipt.stage == 'QJ'
    assert receipt.tenant_id == 'SYNTHETIC-TENANT-A'
    assert receipt.assessment_id == packet['identity']['assessment_id']
    assert receipt.confirmation_id == packet['confirmation']['id']
    assert receipt.confirmed_revision == packet['confirmation']['revision']
    assert receipt.context_version == CURRENT_CONTEXT_VERSION
    assert receipt.builder_version == CURRENT_CONTEXT_VERSION
    assert receipt.context_hash == packet['packet_hash']
    assert receipt.authorization_id == authorization_record()['authorization_id']
    assert receipt.authorization_scope == 'TEST_ONLY'
    # A research objective is ignored, not authorized.
    assert receipt.research_objective_ignored is True
    # No authority of any kind is claimed.
    assert receipt.authority == 'NONE' and receipt.candidate_only is True
    for flag in ('scientific_acceptance', 'owner_authorization', 'publication_authorized',
                 'fielding_authorized', 'report_release_authorized'):
        assert getattr(receipt, flag) is False
    # Reservation precedes dispatch; exactly one local request was handled.
    assert [call[0] for call in ledger.calls] == ['reserve', 'finish']
    assert ledger.calls[0][1] == 'QJ'
    assert ledger.calls[1][2] == 'returned'
    assert recorder['requests'] == 1
    assert recorder['url'] == ENDPOINT


# --------------------------------------------------------------------------
# 1. Stage
# --------------------------------------------------------------------------
def test_wrong_dispatch_stage_is_refused():
    assert refusal(stage='BDJ') == 'QJ_DISCLOSURE_STAGE_NOT_AUTHORIZED'


def test_wrong_authorization_stage_is_refused():
    assert refusal(authorization=valid_authorization(stage='QG')) == \
        'QJ_DISCLOSURE_STAGE_NOT_AUTHORIZED'


# --------------------------------------------------------------------------
# 2. Synthetic layer, separate from the BCB layer
# --------------------------------------------------------------------------
def test_bare_bcb_packet_alone_cannot_authorise_qj():
    packet = bcb_packet()
    assert refusal(context=packet, packet=packet) == \
        'QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'


def test_authorization_with_real_data_class_is_refused():
    assert refusal(authorization=valid_authorization(data_class='REAL_PERSONAL')) == \
        'QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'


def test_envelope_with_real_data_class_is_refused():
    packet = bcb_packet()
    assert refusal(context=packet, packet=envelope(packet, data_class='REAL_PERSONAL')) == \
        'QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'


def test_envelope_with_human_subjects_is_refused():
    packet = bcb_packet()
    assert refusal(context=packet, packet=envelope(packet, human_subjects=True)) == \
        'QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'


def test_envelope_without_fixture_id_is_refused():
    packet = bcb_packet()
    assert refusal(context=packet, packet=envelope(packet, fixture_id='  ')) == \
        'QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'


def test_packet_for_a_tenant_the_record_does_not_name_is_refused():
    # A real assessment's packet is refused unless a TEST_ONLY record names its tenant.
    assert refusal(authorization=valid_authorization(tenant_id='REAL-TENANT-9')) == \
        'QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'


def test_real_authenticated_declaration_marker_is_refused():
    packet = bcb_packet()
    packet['m2_answers'] = [{**packet['m2_answers'][0],
                             'trust_class': 'T2_AUTHENTICATED_ENTREPRENEUR_DECLARATION'}]
    assert refusal(context=packet) == 'QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'


# --------------------------------------------------------------------------
# 3. Genuine builder output
# --------------------------------------------------------------------------
def test_packet_without_provenance_is_refused():
    packet = bcb_packet()
    packet.pop('provenance')
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT'


def test_packet_with_extra_key_is_refused():
    packet = bcb_packet()
    packet['data_class'] = 'SYNTHETIC_NONHUMAN'
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT'


def test_packet_with_wrong_schema_version_is_refused():
    packet = bcb_packet()
    packet['schema_version'] = 'business-context-package/1.0'
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT'


def test_packet_with_stale_hash_is_refused():
    packet = bcb_packet()
    packet['business_description'] = {'text': 'rewritten'}
    assert refusal(context=packet) == 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT'


def test_packet_with_non_false_permission_is_refused():
    packet = bcb_packet()
    packet['permissions'] = {**packet['permissions'], 'qj_execution': True}
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT'


def test_packet_with_tampered_concept_content_is_refused():
    packet = bcb_packet()
    packet['concept'] = {**packet['concept'],
                         'content': {'description': 'A different business.'}}
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT'


def test_packet_with_unauthorised_instrument_is_refused():
    packet = bcb_packet()
    packet['instrument'] = {**packet['instrument'], 'approval_state': 'RESEARCH_ONLY'}
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT'


# --------------------------------------------------------------------------
# 4. Immutable version references
# --------------------------------------------------------------------------
@pytest.mark.parametrize('field, value', [
    ('assessment_id', '22222222-2222-4222-8222-222222222222'),
    ('confirmation_id', '99999999-9999-4999-8999-999999999999'),
    ('confirmed_revision', 99),
    ('context_version', CONTEXT_VERSION),
    ('builder_version', 'BCB-V1-0.9.0'),
    ('context_hash', '0' * 64),
])
def test_immutable_reference_mismatch_is_refused(field, value):
    packet = bcb_packet()
    references = replace(references_for(packet), **{field: value})
    assert refusal(context=packet, references=references) == \
        'QJ_DISCLOSURE_VERSION_MISMATCH'


def test_edited_body_with_recomputed_hash_is_a_version_mismatch():
    packet = bcb_packet()
    references = references_for(packet)
    edited = resign({**packet, 'business_description': {'text': 'rewritten'}})
    assert refusal(context=edited, references=references) == \
        'QJ_DISCLOSURE_VERSION_MISMATCH'


def test_malformed_references_are_refused():
    packet = bcb_packet()
    references = replace(references_for(packet), context_hash='short')
    assert refusal(context=packet, references=references) == \
        'QJ_DISCLOSURE_REFERENCES_INVALID'


def test_missing_authorization_is_refused():
    assert refusal(authorization=object()) == 'QJ_DISCLOSURE_AUTHORIZATION_INVALID'


def test_authorization_without_an_id_is_refused():
    assert refusal(authorization=valid_authorization(authorization_id='')) == \
        'QJ_DISCLOSURE_AUTHORIZATION_INVALID'


# --------------------------------------------------------------------------
# 5. Confirmed research uncertainty
# --------------------------------------------------------------------------
def test_absent_uncertainty_is_refused():
    assert refusal(context=bcb_packet(uncertainty=False)) == \
        'QJ_DISCLOSURE_UNCERTAINTY_NOT_CONFIRMED'


@pytest.mark.parametrize('change', [
    {'confirmation_id': 'SYN-CONF-OTHER'},
    {'actor_user_id': '99999999-9999-4999-8999-999999999999'},
    {'exact_text': '   '},
    {'exact_text': 'x' * 1001},
    {'id': ''},
])
def test_misbound_uncertainty_is_refused(change):
    packet = bcb_packet()
    packet['confirmed_uncertainty'] = {**packet['confirmed_uncertainty'], **change}
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_UNCERTAINTY_NOT_CONFIRMED'


def test_builder_recorded_unconfirmed_unknown_is_refused():
    # The builder records UNCERTAINTY_NOT_CONFIRMED in `unknowns` when the
    # confirmation carries no uncertainty event. A stray block cannot override it.
    packet = bcb_packet(uncertainty=False)
    packet['confirmed_uncertainty'] = {
        'id': 'SYN-UNC-QJ-01',
        'confirmation_id': packet['confirmation']['id'],
        'actor_user_id': packet['identity']['owner_id'],
        'exact_text': UNCERTAINTY_TEXT,
    }
    assert 'UNCERTAINTY_NOT_CONFIRMED' in {row['code'] for row in packet['unknowns']}
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_UNCERTAINTY_NOT_CONFIRMED'


# --------------------------------------------------------------------------
# 6. BCB purpose, GEO exclusion and currency
# --------------------------------------------------------------------------
def test_wrong_purpose_is_refused():
    packet = bcb_packet()
    packet['access']['scope']['purpose'] = 'EXPLANATION'
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_PURPOSE_MISMATCH'


def test_wrong_authorization_purpose_is_refused():
    assert refusal(authorization=valid_authorization(purpose='EE01_CONTEXT')) == \
        'QJ_DISCLOSURE_PURPOSE_MISMATCH'


def test_packet_carrying_geography_is_refused():
    packet = bcb_packet()
    packet['geography'] = {'area_id': 'MY-ADM2-14_1'}
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_GEOGRAPHY_NOT_EXCLUDED'


def test_old_contract_version_is_stale():
    packet = bcb_packet()
    packet['context_version'] = CONTEXT_VERSION
    packet['schema_version'] = 'business-context-package/1.0'
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_CONTEXT_STALE'


def test_superseded_concept_is_stale():
    packet = bcb_packet()
    packet['concept'] = {**packet['concept'], 'status': 'SUPERSEDED'}
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_CONTEXT_STALE'


def test_expired_concept_is_stale():
    packet = bcb_packet()
    packet['concept'] = {**packet['concept'],
                         'valid_until': '2000-01-01T00:00:00+00:00'}
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_CONTEXT_STALE'


def test_superseded_confirmation_is_stale():
    packet = bcb_packet()
    packet['confirmation'] = {**packet['confirmation'], 'status': 'SUPERSEDED'}
    assert refusal(context=resign(packet)) == 'QJ_DISCLOSURE_CONTEXT_STALE'


# --------------------------------------------------------------------------
# 7. Endpoint and model
# --------------------------------------------------------------------------
def test_wrong_endpoint_is_refused():
    assert refusal(endpoint='https://elsewhere.example/v1') == \
        'QJ_DISCLOSURE_ENDPOINT_MISMATCH'


def test_authorization_cannot_widen_the_endpoint():
    assert refusal(authorization=valid_authorization(
        endpoint='https://elsewhere.example/v1')) == 'QJ_DISCLOSURE_ENDPOINT_MISMATCH'


def test_wrong_model_is_refused():
    assert refusal(model='some-other-model') == 'QJ_DISCLOSURE_MODEL_MISMATCH'


def test_authorization_cannot_widen_the_model():
    assert refusal(authorization=valid_authorization(
        model='some-other-model')) == 'QJ_DISCLOSURE_MODEL_MISMATCH'


# --------------------------------------------------------------------------
# 8. Test authorization
# --------------------------------------------------------------------------
@pytest.mark.parametrize('change', [
    {'scope': 'PRODUCTION'},
    {'production_adoption': True},
    {'owner_signature': 'FABRICATED-OWNER'},
    {'scientific_approval': 'FABRICATED-SCIENTIFIC'},
    {'geo_authority': 'FABRICATED-GEO'},
    {'authorised_operations': ('SOMETHING_ELSE',)},
    {'tenant_id': ''},
])
def test_absent_or_over_scoped_test_authorization_is_refused(change):
    expected = ('QJ_DISCLOSURE_AUTHORIZATION_INVALID' if change == {'tenant_id': ''}
                else 'QJ_DISCLOSURE_TEST_AUTHORIZATION_INVALID')
    assert refusal(authorization=valid_authorization(**change)) == expected


def test_expired_test_authorization_is_refused():
    expired = valid_authorization(valid_until='2026-11-16T00:00:00+00:00')
    assert refusal(authorization=expired) == 'QJ_DISCLOSURE_TEST_AUTHORIZATION_STALE'


def test_unparseable_valid_until_is_refused():
    assert refusal(authorization=valid_authorization(valid_until='not-a-date')) == \
        'QJ_DISCLOSURE_TEST_AUTHORIZATION_STALE'


# --------------------------------------------------------------------------
# Ordering: refusals precede reserve(), budget and transport
# --------------------------------------------------------------------------
class _BudgetFileLedger:
    """Ledger port double whose ``reserve()`` is the only budget writer.

    ``ModelRunner`` calls the disclosure before ``ledger.reserve()``, so an
    unchanged budget file plus no ``reserve`` call proves the refusal happened
    before any attempt was consumed.
    """

    def __init__(self, path: Path):
        self.path = path
        self.calls: list[tuple] = []

    def reserve(self, stage, prompt_version, prompt_hash, request_hash):
        state = json.loads(self.path.read_text(encoding='utf-8'))
        state['spent'] += 1
        state['attempts'].append({'n': state['spent'], 'scenario': 'qj:test'})
        self.path.write_text(json.dumps(state, indent=2, sort_keys=True), encoding='utf-8')
        self.calls.append(('reserve', stage))
        return state['spent']

    def finish(self, attempt, outcome, output_digest):
        self.calls.append(('finish', attempt, outcome))


def test_refusal_consumes_no_budget_and_constructs_no_transport(tmp_path, monkeypatch):
    from sitewise.project1 import provider as provider_module

    state = tmp_path / 'budget_state.json'
    state.write_text(json.dumps({
        'limit': 6, 'spent': 1,
        'attempts': [{'n': 1, 'scenario': 'consistent:BDJ'}],
    }, indent=2, sort_keys=True), encoding='utf-8')
    before = state.read_bytes()

    ledger = _BudgetFileLedger(state)
    constructed: list[str] = []

    def bomb(*args, **kwargs):
        constructed.append('transport')
        raise AssertionError('a refusal constructed a transport')

    # TokenHarbor.complete() builds httpx.Client(transport=...) inline, so making
    # it raise proves the refusal never reached the provider at all.
    monkeypatch.setattr(provider_module.httpx, 'Client', bomb)

    packet = bcb_packet()
    disclosure = SyntheticQjDisclosure(
        valid_authorization(tenant_id='REAL-TENANT-9'), references_for(packet),
        clock=lambda: NOW)
    runner = _runner_for(None, ledger, disclosure)

    with pytest.raises(WorkflowHeld) as caught:
        runner('QJ', envelope(packet), QJOutput)

    assert str(caught.value) == 'QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'
    assert state.read_bytes() == before, 'a refused QJ disclosure consumed budget'
    assert ledger.calls == [], 'ledger.reserve() ran before the disclosure refused'
    assert constructed == []
    assert json.loads(state.read_text(encoding='utf-8'))['spent'] == 1


@pytest.mark.parametrize('case, stage, code', [
    ('real_data', 'QJ', 'QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'),
    ('not_builder', 'QJ', 'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT'),
    ('geography', 'QJ', 'QJ_DISCLOSURE_GEOGRAPHY_NOT_EXCLUDED'),
    ('expired_auth', 'QJ', 'QJ_DISCLOSURE_TEST_AUTHORIZATION_STALE'),
    ('wrong_stage', 'BDJ', 'QJ_DISCLOSURE_STAGE_NOT_AUTHORIZED'),
])
def test_every_refusal_precedes_ledger_reservation(case, stage, code):
    packet = bcb_packet()
    authorization = valid_authorization()
    if case == 'real_data':
        authorization = valid_authorization(tenant_id='REAL-TENANT-9')
    elif case == 'not_builder':
        packet.pop('provenance')
        packet = resign(packet)
    elif case == 'geography':
        packet['geography'] = {'area_id': 'MY-ADM2-14_1'}
        packet = resign(packet)
    elif case == 'expired_auth':
        authorization = valid_authorization(valid_until='2026-01-01T00:00:00+00:00')

    ledger = RecordingLedger()
    disclosure = SyntheticQjDisclosure(authorization, references_for(packet),
                                       clock=lambda: NOW)
    runner = _runner_for(_forbidden_transport(), ledger, disclosure)

    with pytest.raises(WorkflowHeld) as caught:
        runner(stage, envelope(packet), QJOutput)

    assert str(caught.value) == code
    assert ledger.calls == []


# --------------------------------------------------------------------------
# Every code is reachable from the predicate (drift guard)
# --------------------------------------------------------------------------
def test_all_refusal_codes_are_reachable_from_this_predicate():
    packet = bcb_packet()
    stale = resign({**packet, 'context_version': CONTEXT_VERSION,
                    'schema_version': 'business-context-package/1.0'})
    geo = resign({**packet, 'geography': {'area_id': 'x'}})
    reached = {
        refusal(stage='X'),
        refusal(context=packet, packet=packet),
        refusal(context=resign({**packet, 'extra': 1})),
        refusal(references=replace(references_for(packet), builder_version='other')),
        refusal(context=bcb_packet(uncertainty=False)),
        refusal(authorization=valid_authorization(purpose='X')),
        refusal(context=stale),
        refusal(context=geo),
        refusal(endpoint='X'),
        refusal(model='X'),
        refusal(authorization=valid_authorization(scope='PRODUCTION')),
        refusal(authorization=valid_authorization(valid_until='2020-01-01T00:00:00+00:00')),
        refusal(authorization=object()),
        refusal(references=object()),
    }
    assert reached == {
        'QJ_DISCLOSURE_STAGE_NOT_AUTHORIZED',
        'QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED',
        'QJ_DISCLOSURE_NOT_BUILDER_OUTPUT',
        'QJ_DISCLOSURE_VERSION_MISMATCH',
        'QJ_DISCLOSURE_UNCERTAINTY_NOT_CONFIRMED',
        'QJ_DISCLOSURE_PURPOSE_MISMATCH',
        'QJ_DISCLOSURE_GEOGRAPHY_NOT_EXCLUDED',
        'QJ_DISCLOSURE_CONTEXT_STALE',
        'QJ_DISCLOSURE_ENDPOINT_MISMATCH',
        'QJ_DISCLOSURE_MODEL_MISMATCH',
        'QJ_DISCLOSURE_TEST_AUTHORIZATION_INVALID',
        'QJ_DISCLOSURE_TEST_AUTHORIZATION_STALE',
        'QJ_DISCLOSURE_AUTHORIZATION_INVALID',
        'QJ_DISCLOSURE_REFERENCES_INVALID',
    }


def test_context_invalid_code_is_reachable_for_a_non_mapping_packet():
    try:
        validate_qj_synthetic(stage='QJ', packet='not-a-packet', endpoint=ENDPOINT,
                              model=MODEL, authorization=valid_authorization(),
                              references=references_for(bcb_packet()), now=NOW)
    except WorkflowHeld as exc:
        assert str(exc) == 'QJ_DISCLOSURE_CONTEXT_INVALID'
    else:
        raise AssertionError('a non-mapping packet was accepted')


# --------------------------------------------------------------------------
# No regression: the BDJ adapter still refuses QJ
# --------------------------------------------------------------------------
def test_bdj_adapter_still_refuses_qj():
    from sitewise.project1.disclosure import (SyntheticBdjAuthorization,
                                              SyntheticBdjDisclosure)

    packet = {'schema_version': 'project1-m2-projection/1-candidate',
              'source_fingerprint': 'f' * 64}
    disclosure = SyntheticBdjDisclosure(SyntheticBdjAuthorization(
        run_id='synthetic-run-qj', source_fingerprint='f' * 64,
        operator_receipt='TEST-SCOPED-BDJ-RECEIPT'))
    with pytest.raises(WorkflowHeld) as caught:
        disclosure.require_current('QJ', packet, ENDPOINT, MODEL)
    assert str(caught.value) == 'DISCLOSURE_STAGE_NOT_AUTHORIZED'


def test_qj_adapter_refuses_a_bdj_projection_packet():
    """A BDJ projection has neither a BCB context nor a synthetic layer."""
    packet = {'schema_version': 'project1-m2-projection/1-candidate',
              'source_fingerprint': 'f' * 64}
    disclosure = SyntheticQjDisclosure(valid_authorization(),
                                       references_for(bcb_packet()),
                                       clock=lambda: NOW)
    with pytest.raises(WorkflowHeld) as caught:
        disclosure.require_current('QJ', packet, ENDPOINT, MODEL)
    assert str(caught.value) == 'QJ_DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'
