"""LLM-01: prove the harness prepares a valid synthetic request without dispatch.

What this file establishes, and what it deliberately does not:

* the M2V1-20261114-1 instrument is read from its versioned fields, and the
  packet is produced by the production projection over those fields;
* five synthetic cases exist and validate against the registered codebook;
* the candidate ruleset loads under an explicit *test-scoped* receipt;
* the production runner accepts the packet and the adapter builds a well-formed
  request body, which is handed to a local ``httpx.MockTransport`` only.

No database is written, no migration is run, no gate is edited, and no provider
or network call is made. ``settings.tokenharbor_enabled`` stays False.
"""
from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest

from sitewise.core.config import settings
from sitewise.modules.decision_engine.domain.m2_rules import (resolve_m2_items,
                                                              validate_m2_answer)
from sitewise.project1.bdj import BDJEngine, load_rules
from sitewise.project1.contracts import BDJOutput, WorkflowHeld, digest
from sitewise.project1.projection import verify_projection
from sitewise.project1.provider import MODEL
from sitewise.services.business_context_v1 import current_business_description

from campaign import (FIXTURES, RecordingLedger, authorization, build_case,
                      disclosure_for, expected_item_keys, fake_transport,
                      instrument, load_fixture, runner_for, source_hash)

EXPECTED_KEYS = ['M2V1-01', 'M2V1-02', 'M2V1-03', 'M2V1-04', 'M2V1-05',
                 'M2V1-06', 'M2V1-07', 'M2V1-08', 'M2V1-09', 'M2V1-10',
                 'M2V1-11', 'M2-20', 'M2-21']
EXPECTED_SOURCE_SHA256 = (
    'd09a7db532cbd2e41458d9776004de2830c67c91cacb0a264dc4cfbe5c432c6b')
NO_ISSUES = json.dumps({'issues': [], 'overall_note': 'Synthetic structural check only.'})


def test_instrument_loads_from_versioned_fields():
    definition, schema_digest, instrument_id, rows = instrument()
    assert definition['version_tag'] == 'M2V1-20261114-1'
    assert definition['code'] == 'M2V1'
    assert [row['item_key'] for row in rows] == EXPECTED_KEYS == expected_item_keys()
    assert len(rows) == 13
    assert sum(row['answer_kind'] == 'ACTION' for row in rows) == 2
    assert source_hash() == definition['source_sha256'] == EXPECTED_SOURCE_SHA256
    assert len(schema_digest) == 64 and str(instrument_id)
    # Codebook entries resolve: every option is a labelled code, not a constant.
    by_key = {row['item_key']: row for row in rows}
    assert by_key['M2V1-02']['option_values']['options'][0] == {
        'code': 'DINE_IN', 'label': 'Primarily dine-in'}
    assert by_key['M2V1-04']['option_values']['rules'] == {'exclusive': ['UNDECIDED']}
    assert by_key['M2V1-10']['option_values']['rules']['source_item'] == 'M2V1-09'


@pytest.mark.parametrize('name', sorted(FIXTURES))
def test_packet_is_populated_from_the_versioned_instrument(name):
    case = build_case(name)
    packet = case.packet
    verify_projection(packet)  # the synthetic markers are inside the fingerprint
    definition, schema_digest, instrument_id, rows = instrument()
    by_key = {row['item_key']: row for row in rows}

    assert packet['instrument_version'] == definition['version_tag']
    assert packet['instrument_digest'] == schema_digest
    assert packet['instrument_id'] == str(instrument_id)
    assert packet['schema_version'] == 'project1-m2-projection/1-candidate'
    assert packet['assessment_revision'] == case.revision

    declarations = {d['item_key']: d for d in packet['declarations']}
    answerable = {k: v for k, v in case.answers.items()
                  if by_key[k]['answer_kind'] != 'ACTION'}
    assert set(declarations) == set(answerable)
    for key, declaration in declarations.items():
        assert declaration['question'] == by_key[key]['question_text']
        assert declaration['item_version_id'] == str(by_key[key]['id'])
        assert declaration['value'] == answerable[key]['value_json']
        assert declaration['answer_state'] == answerable[key]['answer_state']
        assert declaration['trust_class'] == 'ENTREPRENEUR_DECLARED'
    assert packet['facts_independently_verified'] is False
    assert packet['governance_items'] == ['M2-20', 'M2-21']


@pytest.mark.parametrize('name', sorted(FIXTURES))
def test_fixture_answers_validate_against_the_registered_codebook(name):
    case = build_case(name)
    fixture = case.fixture
    assert fixture['label'].startswith('SYNTHETIC')
    assert fixture['synthetic'] is True and fixture['contains_personal_data'] is False
    assert fixture['business_description'].strip()
    # No pre-baked model output may be recorded in a fixture (LLM-05 owns that).
    assert fixture['no_expected_output_recorded'] is True
    assert not {'expected', 'expected_findings', 'expected_route'} & set(fixture)

    resolved = {item['item_key']: item for item in resolve_m2_items(case.items, case.answers)}
    for key, answer in case.answers.items():
        validate_m2_answer(resolved[key], answer['answer_state'], answer['value_json'])


def test_contradictory_fixture_carries_its_tension_inside_the_packet():
    """The narrative is not projected, so the tension must live in versioned answers."""
    case = build_case('contradictory')
    values = {d['item_key']: d['value'] for d in case.packet['declarations']}
    assert values['M2V1-02'] == 'TAKEAWAY'
    assert values['M2V1-07'] == 'STUDY_WORK'
    assert case.fixture['business_description'] not in json.dumps(case.packet)


def test_business_description_is_rendered_from_the_codebook_not_the_fixture_prose():
    case = build_case('consistent')
    description = current_business_description(case.items, case.answers)
    assert description['template_version'] == 'V1'
    assert description['source'] == 'CONFIRMED_M2'
    assert description['source_question_ids'] == [
        'M2V1-02', 'M2V1-03', 'M2V1-04', 'M2V1-05', 'M2V1-06', 'M2V1-07']
    text = description['text']
    for label in ('Primarily dine-in', 'Coffee and espresso beverages',
                  'Office workers', 'Product quality or specialty'):
        assert label in text
    # The fixture's prose is context, never the rendered description.
    assert case.fixture['business_description'][:40] not in text


@pytest.mark.parametrize('name,confirmed', [
    ('consistent', False), ('contradictory', False), ('missing', False),
    ('confirmed_uncertainty', True), ('requires_clarification', True)])
def test_confirmation_record_shape(name, confirmed):
    case = build_case(name)
    assert case.packet['confirmed'] is confirmed
    record = case.fixture.get('confirmation')
    if not confirmed:
        assert record is None
        return
    assert record['record_kind'] == 'SYNTHETIC_SHAPE_ONLY'
    assert record['authority'] == 'NONE' and record['persisted'] is False
    uncertainty = record['confirmed_uncertainty']
    assert uncertainty['evidence_class'] == 'SYNTHETIC_NONHUMAN'
    assert 0 < len(uncertainty['exact_text'].strip()) <= 1000
    assert uncertainty['scientific_approval'] is False
    assert uncertainty['fielding_authorized'] is False
    # No fabricated signature of any kind.
    assert 'owner_signature' not in record and 'approval_ref' not in record


def test_test_scoped_receipt_loads_the_candidate_ruleset_without_adopting_it():
    auth = authorization()
    assert auth['scope'] == 'TEST_ONLY' and auth['production_adoption'] is False
    assert auth['owner_signature'] is None and auth['scientific_approval'] is None
    assert auth['geo_authority'] is None
    assert auth['written_to_env'] is False and auth['written_to_schema_versions'] is False
    receipt = auth['adoption_receipt']
    assert receipt.startswith('TEST-SCOPED ONLY')
    assert 'NOT a production ruleset adoption' in receipt

    rules = load_rules(auth['ruleset_version'], auth['ruleset_sha256'], receipt)
    assert rules.RULE_VERSION == 'BDJ-RULESET-0.2-CAND'
    # The M2V1 re-key is recorded as retired and is never loaded here.
    assert 'BDJ-RULESET-0.3-M2V1-CAND' in auth['retirement_record']
    # The receipt is test-local: it is not the process-wide configured receipt.
    assert receipt not in settings.project1_rules_adoption_receipt


def test_m2v1_catalogue_is_empty_under_the_adopted_ruleset():
    """D02: M2V1 BDJ is contradiction-free by design, so the vocabulary is empty."""
    auth = authorization()
    rules = load_rules(auth['ruleset_version'], auth['ruleset_sha256'],
                       auth['adoption_receipt'])
    case = build_case('contradictory')
    seen: dict = {}

    def capture(stage, packet, output_type):
        seen.update(packet)
        return {'issues': [], 'overall_note': 'capture only'}

    BDJEngine(rules, model_runner=capture).review(
        case.packet, recheck_current=lambda: case.packet['source_fingerprint'])
    assert seen['rule_catalogue'] == []


def test_rule_loading_controls_remain_live():
    auth = authorization()
    with pytest.raises(WorkflowHeld, match='BDJ_RULE_ADOPTION_REQUIRED'):
        load_rules(auth['ruleset_version'], auth['ruleset_sha256'], '')
    with pytest.raises(WorkflowHeld, match='BDJ_RULE_FINGERPRINT_MISMATCH'):
        load_rules(auth['ruleset_version'], '0' * 64, auth['adoption_receipt'])


def test_disclosure_predicate_accepts_the_synthetic_packet_and_refuses_a_real_one():
    from sitewise.project1.disclosure import validate_synthetic

    case = build_case('consistent')
    disclosure_for(case.packet).require_current(
        'BDJ', case.packet, 'https://tokenharbor.ai/v1/chat/completions', MODEL)

    # An unmarked projection is what the production route actually produces;
    # run_model_assisted() passes packet.get('data_class'), i.e. None.
    content = {k: v for k, v in case.packet.items() if k != 'source_fingerprint'}
    content.pop('data_class')
    unmarked = {**content, 'source_fingerprint': digest(content)}
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'):
        validate_synthetic(
            data_class=unmarked.get('data_class'), purpose=unmarked.get('purpose'),
            stage='BDJ', endpoint='https://tokenharbor.ai/v1/chat/completions',
            model=MODEL, max_attempts=1,
            operator_receipt=authorization()['adoption_receipt'],
            source_fingerprint=unmarked['source_fingerprint'], packet=unmarked)


def test_runner_request_body_is_valid_and_never_sent():
    case = build_case('contradictory')
    ledger = RecordingLedger()
    recorder: dict = {}
    transport = fake_transport(recorder, content=NO_ISSUES)
    assert isinstance(transport, httpx.MockTransport)
    composed = runner_for(transport, ledger, case.packet)
    rules = load_rules(*[authorization()[key] for key in
                         ('ruleset_version', 'ruleset_sha256', 'adoption_receipt')])

    result = BDJEngine(rules, model_runner=composed.runner).review(
        case.packet, recheck_current=lambda: case.packet['source_fingerprint'])

    assert result['outcome'] == 'reviewed'
    assert result['finding_authority'] == 'CANDIDATE_ONLY'
    assert recorder['requests'] == 1, 'exactly one request, handled locally'
    assert recorder['method'] == 'POST'
    assert recorder['url'] == 'https://tokenharbor.ai/v1/chat/completions'

    body = recorder['body']
    assert body['model'] == MODEL == 'mimo-v2.6-flash:free'
    assert body['max_tokens'] == 4000
    assert body['temperature'] == 0
    assert body['stream'] is False
    assert body['response_format']['type'] == 'json_schema'
    assert body['response_format']['json_schema']['name'] == 'BDJOutput'
    assert body['response_format']['json_schema']['strict'] is True
    assert set(body['response_format']['json_schema']['schema']) == set(
        BDJOutput.model_json_schema())
    assert len(json.dumps(body).encode()) <= 64_000

    assert body['messages'][0]['role'] == 'system'
    assert 'untrusted data' in body['messages'][0]['content']
    user = json.loads(body['messages'][-1]['content'])['source_data']
    assert user['instrument_version'] == 'M2V1-20261114-1'
    keys = {d['item_key'] for d in user['declarations']}
    assert keys and keys <= set(EXPECTED_KEYS)
    assert {'M2V1-02', 'M2V1-07'} <= keys
    assert user['synthetic_fixture_id'] == 'LLM01-02'

    # Reservation precedes dispatch; the receipt follows it.
    assert [call[0] for call in ledger.calls] == ['reserve', 'finish']
    assert ledger.calls[0][1] == 'BDJ'
    assert ledger.calls[1][2] == 'returned'

    # The process-wide provider flag was never turned on.
    assert settings.tokenharbor_enabled is False


def test_campaign_artifacts_are_confined_and_labelled():
    folder = Path(__file__).resolve().parent
    files = sorted(p.name for p in folder.glob('*.json'))
    assert files == ['test_scope_authorization.json']
    fixtures = sorted(p.name for p in (folder / 'fixtures').glob('*.json'))
    assert fixtures == sorted(FIXTURES.values())
    assert all(json.loads((folder / 'fixtures' / f).read_text(encoding='utf-8'))['synthetic']
               for f in fixtures)


class _IdentitySession:
    """Minimal session double for the gate's two probes.

    ``verify_workflow_database`` reads two things: the **connected** URL from
    ``session.get_bind().url`` (to prove the session is bound to the database the
    settings name) and the **principal** from the catalog query. This double
    reports the URL it was constructed with, defaulting to the configured one,
    and varies only the principal — which is what these tests are about.
    """

    def __init__(self, identity, connected_url=None):
        self.identity, self.rollbacks = identity, 0
        self._connected_url = connected_url

    def get_bind(self):
        from types import SimpleNamespace

        from sqlalchemy.engine import make_url

        from sitewise.core.config import settings

        return SimpleNamespace(
            url=make_url(self._connected_url or settings.database_url))

    def execute(self, statement):
        from types import SimpleNamespace
        return SimpleNamespace(one=lambda: self.identity)

    def rollback(self):
        self.rollbacks += 1


def test_configuration_gate_is_intact_and_accepts_only_a_non_superuser_dss_principal(monkeypatch):
    """The gate is exercised, never edited. Evidence for the runnable-configuration answer.

    Three cases, each of which the gate can actually produce. The first case used
    to be "a ``postgres`` URL is refused with ``WORKFLOW_CONFIGURATION_REQUIRED``",
    which the gate never implemented: it decides the principal from the *catalog*
    (``current_user``/``session_user``), not from the username in the URL, and the
    only source of ``WORKFLOW_CONFIGURATION_REQUIRED`` is the workflow flag. That
    case could not pass once the double could answer ``get_bind()``, because it
    described a state no real session can be in — a ``postgres`` connection whose
    catalog row says it is not a superuser.

    The refusal itself is unchanged and still asserted: a superuser principal is
    refused, now by the code the gate really raises for it.
    """
    from fastapi import HTTPException
    from sitewise.api.v1 import project1_workflow as api
    from pydantic import SecretStr

    monkeypatch.setattr(settings, 'm2_database_url', SecretStr(''))

    # 1. The workflow is not enabled.
    monkeypatch.setattr(settings, 'project1_workflow_enabled', False)
    with pytest.raises(HTTPException) as caught:
        api.configuration_gate(_IdentitySession(('Dss', None, False)))
    assert caught.value.detail['code'] == 'WORKFLOW_CONFIGURATION_REQUIRED'

    # 2. A superuser principal, as a `postgres` connection would actually report.
    #    ``configuration_gate`` re-raises ``WorkflowHeld`` unchanged (it only
    #    translates ``ValueError``/``SQLAlchemyError``), so the refusal arrives as
    #    the hold itself rather than as an ``HTTPException``.
    from sitewise.project1.contracts import WorkflowHeld

    monkeypatch.setattr(settings, 'project1_workflow_enabled', True)
    monkeypatch.setattr(
        settings, 'database_url',
        'postgresql+psycopg2://postgres:placeholder@localhost:5432/Dss')
    with pytest.raises(WorkflowHeld) as caught:
        api.configuration_gate(_IdentitySession(('Dss', None, True)))
    assert str(caught.value) == 'SOURCE_PRINCIPAL_REVIEW_REQUIRED'

    # 3. p1ai_engine on Dss. Nothing else was relaxed to reach this point; the
    #    downstream grants are a separate fact.
    monkeypatch.setattr(
        settings, 'database_url',
        'postgresql+psycopg2://p1ai_engine:placeholder@localhost:5432/Dss')
    session = _IdentitySession(('Dss', None, False))
    api.configuration_gate(session)
    assert session.rollbacks == 1


def test_the_gate_refuses_a_session_bound_to_another_database(monkeypatch):
    """The identity check reads the *connected* database, not just the settings.

    Added with the ``get_bind`` repair: once the double reports a URL, the branch
    that compares it with the configured target has to be exercised, or the
    double would be proving only that the gate accepts whatever it is told.
    """
    from sitewise.api.v1 import project1_workflow as api
    from sitewise.core.config import settings
    from sitewise.project1.contracts import WorkflowHeld
    from pydantic import SecretStr

    monkeypatch.setattr(settings, 'project1_workflow_enabled', True)
    monkeypatch.setattr(settings, 'm2_database_url', SecretStr(''))
    monkeypatch.setattr(
        settings, 'database_url',
        'postgresql+psycopg2://p1ai_engine:placeholder@localhost:5432/Dss')

    session = _IdentitySession(
        ('Dss', False, False),
        connected_url='postgresql+psycopg2://p1ai_engine:placeholder@localhost:5432/other_db')
    with pytest.raises(WorkflowHeld) as caught:
        api.configuration_gate(session)
    assert str(caught.value) == 'WORKFLOW_DATABASE_IDENTITY_MISMATCH'
    assert session.rollbacks == 1, 'the gate must roll back even when it refuses'


def test_model_assisted_gate_requires_all_four_settings(monkeypatch):
    from fastapi import HTTPException
    from sitewise.api.v1 import project1_workflow as api

    present = {
        'tokenharbor_enabled': True,
        'project1_rules_version': 'BDJ-RULESET-0.2-CAND',
        'project1_rules_sha256': authorization()['ruleset_sha256'],
        'project1_rules_adoption_receipt': authorization()['adoption_receipt'],
    }
    for key, value in present.items():
        monkeypatch.setattr(settings, key, value)
    api.model_assisted_gate()

    for key in present:
        with monkeypatch.context() as patch:
            patch.setattr(settings, key, False if key == 'tokenharbor_enabled' else '')
            with pytest.raises(HTTPException) as caught:
                api.model_assisted_gate()
            assert caught.value.detail['code'] == 'MODEL_ASSISTED_NOT_CONFIGURED'
