"""BdjResultStore against the isolated clone, under the restricted principal.

Requires two environment variables, both pointing at `project1_workflow_tests`:

    PROJECT1_CLONE_URL        login as p1ai_engine (SET ROLE p1ai_runtime)
    PROJECT1_CLONE_ADMIN_URL  fixture setup only (users / M2 / runs rows)

Without them the module skips: the writer's contract is a restricted
principal, and a superuser session is refused by design.
"""
import hashlib
import json
import os
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from cryptography.fernet import Fernet
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import DBAPIError

from sitewise.project1.bdj import BDJEngine
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.key_custody import (STATE_DESTROYED, STATE_LIVE,
                                           CustodyCipher, LocalKeyCustody,
                                           payload_key_id)
from sitewise.project1.ledger import PostgresAttemptLedger
from sitewise.project1.result_store import (PAYLOAD_ENVELOPE_FIELDS,
                                            PAYLOAD_ENVELOPE_MARKER,
                                            PAYLOAD_ENVELOPE_V1, BdjResultStore,
                                            redact_payload, result_id_for,
                                            results_for_assessment)
from sitewise.project1.retention import run_retention, select_expired

RESTRICTED_URL = os.environ.get('PROJECT1_CLONE_URL')
ADMIN_URL = os.environ.get('PROJECT1_CLONE_ADMIN_URL')
CLONE = 'project1_workflow_tests'

if not (RESTRICTED_URL and ADMIN_URL):
    pytest.skip('PROJECT1_CLONE_URL and PROJECT1_CLONE_ADMIN_URL required',
                allow_module_level=True)
if make_url(RESTRICTED_URL).database != CLONE or make_url(ADMIN_URL).database != CLONE:
    pytest.skip('clone-only tests; refusing a non-clone database', allow_module_level=True)

DIGEST = 'a' * 64
PACKET = {'assessment_id': str(uuid4()), 'assessment_revision': 3,
          'source_fingerprint': 'f' * 64}
MARKER = 'MARKER-QUOTE-7f3a9c'
RULESET = 'BDJ-RULESET-0.2-CAND'
PROMPT = 'BDJ-SOURCE-3-CAND'
MODEL = 'mimo-v2.6-flash:free'


class FernetCipher:
    """Test-only cipher: a per-instance random key, never a literal or env key."""

    def __init__(self):
        self._fernet = Fernet(Fernet.generate_key())
        self.key_id = 'test-' + uuid4().hex[:8]

    def encrypt(self, plaintext: bytes):
        return self._fernet.encrypt(plaintext), self.key_id

    def decrypt(self, ciphertext: bytes, key_id: str) -> bytes:
        assert key_id == self.key_id
        return self._fernet.decrypt(ciphertext)


def finding(rule_id='SERVICE_FORMAT_EXPLICIT_CONFLICT', quote=MARKER):
    return {
        'rule_id': rule_id, 'kind': 'SOURCE_CONFLICT',
        'source_refs': [
            {'item_key': 'M2-04', 'answer_revision_id': 'r1',
             'item_version_id': 'v1', 'quote': quote},
            {'item_key': 'M2-05', 'answer_revision_id': 'r2',
             'item_version_id': 'v2', 'quote': 'DINE_IN_FOCUSED'},
        ],
        'observed_condition': 'Synthetic observed condition.',
        'counterargument': 'Synthetic counterargument.',
        'justification': 'Synthetic justification.',
        'next_action': 'Synthetic next action.',
    }


def engine_result(outcome: str, findings=()):
    return BDJEngine._result(PACKET, [], list(findings), outcome)


@pytest.fixture(scope='module')
def engines():
    restricted = create_engine(RESTRICTED_URL, hide_parameters=True)
    admin = create_engine(ADMIN_URL, hide_parameters=True)
    yield restricted, admin
    restricted.dispose()
    admin.dispose()


@pytest.fixture
def case(engines):
    restricted, admin = engines
    actor, instrument, assessment = uuid4(), uuid4(), uuid4()
    revision = 3
    run_id = uuid4()
    finding_ids = [uuid4(), uuid4()]
    with admin.begin() as conn:
        conn.execute(text(
            "INSERT INTO public.users(user_id,email,role,account_status,email_verified,"
            "created_at,updated_at) VALUES (:id,:email,'entrepreneur','active',true,"
            "now(),now())"), {'id': actor, 'email': f'cp04a.store.{actor.hex}@example.test'})
        conn.execute(text(
            "INSERT INTO public.m2_instrument_versions(id,code,version_tag,approval_state,"
            "schema_digest) VALUES (:id,:code,'SYN-V1','AUTHORIZED',:h)"),
            {'id': instrument, 'code': 'STORE-' + instrument.hex[:12], 'h': 'b' * 64})
        conn.execute(text(
            'INSERT INTO public.m2_assessments(id,owner_user_id,instrument_id,revision)'
            ' VALUES (:a,:o,:i,:r)'), {'a': assessment, 'o': actor, 'i': instrument,
                                       'r': revision})
        for number, finding_id in enumerate(finding_ids, start=1):
            conn.execute(text(
                'INSERT INTO public.m2_bdj_findings(id,assessment_id,assessment_revision,'
                'rule_id,rule_version,source_answer_ids,issue_type,explanation,not_proven,'
                'next_action,review_state) VALUES (:id,:a,:r,:rule,:version,'
                "CAST('[]' AS json),'POTENTIAL_DECLARATION_CONFLICT','Synthetic.',"
                "'Synthetic.','Synthetic.','CANDIDATE')"),
                {'id': finding_id, 'a': assessment, 'r': revision,
                 'rule': f'SYNTHETIC_RULE_{number}', 'version': RULESET})
        conn.execute(text(
            'INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,'
            'assessment_revision,source_fingerprint,policy_fingerprint,work_identity)'
            ' VALUES (:r,:o,:a,:rev,:s,:p,:w)'),
            {'r': run_id, 'o': actor, 'a': assessment, 'rev': revision,
             's': 'c' * 64, 'p': 'd' * 64,
             'w': hashlib.sha256(uuid4().bytes).hexdigest()})
    ledger = PostgresAttemptLedger(restricted, actor, run_id)
    attempt = ledger.reserve('BDJ', PROMPT, 'e' * 64, 'f' * 64)
    return SimpleNamespace(restricted=restricted, admin=admin, actor=actor,
                           assessment=assessment, revision=revision, run_id=run_id,
                           ledger=ledger, attempt=attempt, finding_ids=finding_ids)


def store(case, cipher=None, payload_custody=None):
    return BdjResultStore(case.restricted, case.actor, case.run_id, cipher=cipher,
                          payload_custody=payload_custody)


def count(case, table='bdj_results', result_id=None):
    with case.admin.connect() as conn:
        if result_id is None:
            return conn.execute(text(f'SELECT count(*) FROM project1_ai.{table}')).scalar()
        return conn.execute(text(
            f'SELECT count(*) FROM project1_ai.{table} WHERE result_id=:id'),
            {'id': result_id}).scalar()


def persist_kwargs(**overrides):
    values = dict(ruleset_version=RULESET, prompt_version=PROMPT,
                  model_requested=MODEL)
    values.update(overrides)
    return values


# 1. round trip -------------------------------------------------------------
def test_round_trip_persists_parent_and_children(case):
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    findings = [finding(), finding('UNSUPPORTED_PROFIT_GUARANTEE', 'profit quote')]
    sources = [
        {'source_id': 'r1', 'source_version': 'v1', 'source_fingerprint': '1' * 64,
         'locator': 'M2-04@v1'},
        {'source_id': 'r2', 'source_version': 'v2', 'source_fingerprint': '2' * 64,
         'locator': 'M2-05@v2'},
        {'source_id': 'r3', 'source_version': 'v3', 'source_fingerprint': '3' * 64,
         'locator': 'M2-14@v3'},
    ]
    validations = [
        {'check_no': 1, 'check_code': 'SOURCE_PROJECTION_VERIFIED', 'severity': 'INFO',
         'passed': True},
        {'check_no': 2, 'check_code': 'SOURCE_QUOTE_NOT_FOUND', 'severity': 'ERROR',
         'passed': False, 'detail': 'SOURCE_QUOTE_NOT_FOUND'},
    ]
    result_id = store(case).persist(
        case.attempt, engine_result('reviewed', findings), 'returned',
        output_digest=DIGEST, sources=sources, validations=validations,
        findings=case.finding_ids, **persist_kwargs())

    assert result_id == result_id_for(case.run_id, case.attempt)
    row = store(case).read(result_id)
    assert row['validation_status'] == 'valid'
    assert row['finding_count'] == 2
    assert row['finding_authority'] == 'candidate_only'
    assert row['review_outcome'] == 'reviewed'
    assert row['execution_outcome'] == 'returned'
    assert len(row['findings']) == 2
    assert set(row['findings'][0]) == {
        'rule_id', 'kind', 'observed_condition', 'counterargument',
        'justification', 'next_action'}
    assert len(row['references']) == 4
    assert count(case, 'bdj_result_sources', result_id) == 3
    assert count(case, 'bdj_result_validations', result_id) == 2
    assert count(case, 'bdj_result_findings', result_id) == 2


def test_candidate_discovery_round_trip_and_legacy_projection(case):
    from sitewise.project1.result_store import DISCOVERY_RESULT_SCHEMA_VERSION
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    classified = {**finding(), 'discovery_signal': 'POTENTIAL_INCONSISTENCY'}
    result_id = store(case).persist(
        case.attempt, engine_result('reviewed', [classified]), 'returned',
        output_digest=DIGEST, result_schema_version=DISCOVERY_RESULT_SCHEMA_VERSION,
        **persist_kwargs())
    row = store(case).read(result_id)
    assert row['result_schema_version'] == DISCOVERY_RESULT_SCHEMA_VERSION
    assert row['findings'][0]['discovery_signal'] == 'POTENTIAL_INCONSISTENCY'
    assert row['findings'][0]['source_refs'][0]['item_key'] == 'M2-04'
    assert 'quote' not in str(row)
    history = results_for_assessment(case.restricted, case.actor, case.assessment)
    saved = next(item for item in history if item['result_id'] == result_id)
    assert saved['result_schema_version'] == DISCOVERY_RESULT_SCHEMA_VERSION
    assert saved['findings'][0]['source_refs'][0]['item_key'] == 'M2-04'


def test_candidate_discovery_unknown_classification_refused_before_insert(case):
    from sitewise.project1.result_store import DISCOVERY_RESULT_SCHEMA_VERSION
    classified = {**finding(), 'discovery_signal': 'INVENTED'}
    with pytest.raises(WorkflowHeld, match='RESULT_DISCOVERY_CLASSIFICATION_INVALID'):
        store(case).persist(case.attempt, engine_result('reviewed', [classified]), 'returned',
            output_digest=DIGEST, result_schema_version=DISCOVERY_RESULT_SCHEMA_VERSION,
            **persist_kwargs())


def test_mock_runner_to_discovery_validator_to_private_store(case):
    """Isolated composed path; synthetic rules and disclosure are not adoption."""
    from test_bdj_discovery_candidate import sample, candidate
    from sitewise.project1.bdj_discovery_candidate import DiscoveryOutputCandidate, validate_supported_discovery
    from sitewise.project1.contracts import digest
    from sitewise.project1.prompts import PROMPTS
    from sitewise.project1.provider import ModelRunner
    from sitewise.project1.result_store import DISCOVERY_RESULT_SCHEMA_VERSION

    packet, definitions = sample({'M2V1-08': ['UNKNOWN'], 'M2V1-09': ['CONCEPT_INTEREST'],
        'M2V1-10': 'CONCEPT_INTEREST', 'M2V1-11': 'UNSURE'})
    packet['assessment_id'] = str(case.assessment)
    packet['assessment_revision'] = case.revision
    packet['source_fingerprint'] = digest({k: v for k, v in packet.items() if k != 'source_fingerprint'})
    run_id = uuid4()
    with case.admin.begin() as conn:
        conn.execute(text('INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,'
            'assessment_revision,source_fingerprint,policy_fingerprint,work_identity) '
            'VALUES (:r,:o,:a,:rev,:s,:p,:w)'), {'r': run_id, 'o': case.actor,
            'a': case.assessment, 'rev': case.revision, 's': packet['source_fingerprint'],
            'p': 'd'*64, 'w': hashlib.sha256(uuid4().bytes).hexdigest()})

    class Provider:
        mode = 'json_schema'
        model = MODEL
        def complete(self, messages, output_type):
            output = candidate(packet, 'EVIDENCE_LIMITATION', ['M2V1-08'])
            for classification, keys in [('INFORMATION_INTEREST', ['M2V1-09']),
                    ('EXPLICIT_UNCERTAINTY', ['M2V1-11']),
                    ('DECISION_NEED', ['M2V1-10', 'M2V1-11'])]:
                output['issues'].extend(candidate(packet, classification, keys)['issues'])
            return output_type.model_validate(output).model_dump()

    class TestDisclosure:
        def require_current(self, *args):
            pass  # fixture-only consent; no production authority

    ledger = PostgresAttemptLedger(case.restricted, case.actor, run_id)
    runner = ModelRunner(Provider(), ledger, PROMPTS, disclosure=TestDisclosure())
    output = runner('BDJ', packet, DiscoveryOutputCandidate)
    verified = validate_supported_discovery(output, packet, definitions, {'TEST-RULE'})
    receipt = runner.last_execution
    assert receipt['receipt_outcome'] == 'returned'
    result = BDJEngine._result(packet, [], [issue.model_dump() for issue in verified.issues], 'reviewed')
    writer = BdjResultStore(case.restricted, case.actor, run_id)
    result_id = writer.persist(receipt['attempt_no'], result, 'returned',
        output_digest=receipt['output_sha256'], source_fingerprint=packet['source_fingerprint'],
        result_schema_version=DISCOVERY_RESULT_SCHEMA_VERSION, **persist_kwargs())
    stored = writer.read(result_id)
    assert stored['result_schema_version'] == DISCOVERY_RESULT_SCHEMA_VERSION
    assert {x['discovery_signal'] for x in stored['findings']} == {
        'EVIDENCE_LIMITATION', 'INFORMATION_INTEREST', 'EXPLICIT_UNCERTAINTY', 'DECISION_NEED'}
    assert stored['references'][0]['item_key'] == 'M2V1-08'
    assert stored['findings'][0]['source_refs'][0]['item_key'] == 'M2V1-08'
    assert 'quote' not in str(stored)


def test_v102_existing_engine_provider_disclosure_ledger_store(case):
    """Mock transport only: tests assembly, not live authorization/currentness."""
    import importlib.util
    from pathlib import Path
    import httpx
    from pydantic import SecretStr
    from sitewise.project1.disclosure import SyntheticBdjAuthorization, SyntheticBdjDisclosure
    from sitewise.project1.prompts import Prompt
    from sitewise.project1.provider import ModelRunner, TokenHarbor
    from sitewise.project1.result_store import DISCOVERY_RESULT_SCHEMA_VERSION

    source_path = os.environ.get('BDJ_V102_SOURCE')
    request_path = os.environ.get('BDJ_V102_REQUEST')
    if not source_path or not request_path:
        pytest.skip('private exported synthetic source and request evidence path required')
    root = Path(source_path).parent
    source = json.loads(Path(source_path).read_text(encoding='utf-8'))
    assert source['classification'] == 'SYNTHETIC_NONHUMAN' and not source['dispatch_authorized']
    packet, definitions = source['packet'], source['definitions']
    spec = importlib.util.spec_from_file_location('bdj_v101_rules', root/'bdj_synthetic_trial_v1_0_1_rules.py')
    rules = importlib.util.module_from_spec(spec); spec.loader.exec_module(rules)
    prompt = Prompt('BDJ-M2V1-INFO-GAP-TEST-1.0.1', 'You are a bounded business declaration reviewer.',
                    (root/'bdj_synthetic_trial_v1_0_1_prompt.txt').read_text(encoding='utf-8'))
    run_id = uuid4()
    with case.admin.begin() as conn:
        conn.execute(text('INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,'
            'assessment_revision,source_fingerprint,policy_fingerprint,work_identity) '
            'VALUES (:r,:o,:a,:rev,:s,:p,:w)'), {'r':run_id, 'o':case.actor,
            'a':case.assessment, 'rev':case.revision, 's':packet['source_fingerprint'],
            'p':'d'*64, 'w':hashlib.sha256(uuid4().bytes).hexdigest()})
    row = next(x for x in packet['declarations'] if x['item_key'] == 'M2V1-08')
    synthetic_output = {'contract_version':'bdj-discovery-output/1-candidate',
        'overall_note':'Synthetic simulated response; no model was called.', 'issues': [
        {'rule_id':'M2V1_EVIDENCE_INVENTORY_UNKNOWN', 'kind':'INFORMATION_GAP',
         'discovery_signal':'EVIDENCE_LIMITATION', 'source_refs': [{'item_key':row['item_key'],
         'answer_revision_id':row['answer_revision_id'], 'item_version_id':row['item_version_id'],
         'quote':'UNKNOWN'}], 'observed_condition':'Synthetic response UNKNOWN.',
         'counterargument':'This is not a defect.', 'justification':'The declared value is UNKNOWN.',
         'next_action':'Optional clarification.'}]}
    def transport(req):
        Path(request_path).write_bytes(req.content)
        return httpx.Response(200, json={'model':MODEL, 'choices':[{'finish_reason':'stop','message':{
            'role':'assistant','content':json.dumps(synthetic_output)}}]})
    provider = TokenHarbor(SecretStr('test-only-not-a-real-key'), enabled=True,
                           transport=httpx.MockTransport(transport))
    ledger = PostgresAttemptLedger(case.restricted, case.actor, run_id)
    disclosure = SyntheticBdjDisclosure(SyntheticBdjAuthorization(run_id=str(run_id),
        source_fingerprint=packet['source_fingerprint'], operator_receipt='SYNTHETIC-MOCK-ONLY'))
    runner = ModelRunner(provider, ledger, {'BDJ':prompt}, disclosure=disclosure)
    result = BDJEngine(rules, runner).review_discovery_trial(packet, item_definitions=definitions,
        recheck_current=lambda:packet['source_fingerprint'])
    captured = json.loads(Path(request_path).read_bytes())
    body_source = json.loads(captured['messages'][-1]['content'])['source_data']
    assert {x['rule_id'] for x in body_source['rule_catalogue']} == {
        'M2V1_EXPLICIT_PLANNING_UNDECIDED', 'M2V1_EVIDENCE_INVENTORY_UNKNOWN',
        'M2V1_RESEARCH_PURPOSE_UNSURE'}
    assert captured['response_format']['json_schema']['name'] == 'DiscoveryOutputCandidate'
    assert result['findings'][0]['discovery_signal'] == 'EVIDENCE_LIMITATION'
    receipt = runner.last_execution
    writer = BdjResultStore(case.restricted, case.actor, run_id)
    result_id = writer.persist(receipt['attempt_no'], result, 'returned',
        output_digest=receipt['output_sha256'], source_fingerprint=packet['source_fingerprint'],
        result_schema_version=DISCOVERY_RESULT_SCHEMA_VERSION, **persist_kwargs())
    assert writer.read(result_id)['findings'][0]['source_refs'][0]['item_key'] == 'M2V1-08'


def test_private_trial_registry_read_only_and_owner_scoped(case):
    """Only a disposable admin writes test authority; runtime cannot write."""
    from sitewise.project1.synthetic_trial_registry import PrivateSyntheticTrialRegistry
    with case.admin.begin() as conn:
        conn.execute(text('CREATE TABLE IF NOT EXISTS project1_ai.synthetic_trial_authority '
            '(run_id uuid PRIMARY KEY, owner_user_id uuid NOT NULL, authorization_json jsonb NOT NULL)'))
        conn.execute(text('REVOKE ALL ON project1_ai.synthetic_trial_authority FROM PUBLIC'))
        conn.execute(text('GRANT SELECT ON project1_ai.synthetic_trial_authority TO p1ai_runtime'))
        conn.execute(text('INSERT INTO project1_ai.synthetic_trial_authority VALUES '
            '(:r,:o,CAST(:data AS jsonb))'), {'r':case.run_id, 'o':case.actor,
            'data':json.dumps({'decision':'TEST_FIXTURE_NOT_REAL_APPROVAL'})})
    def private_only(session):
        return session.execute(text("SELECT current_database() = 'project1_workflow_tests' "
            "AND inet_server_port() = :port"),
            {'port':int(os.environ.get('PROJECT1_BDJ_PRIVATE_PORT','55438'))}).scalar_one()
    registry = PrivateSyntheticTrialRegistry(case.restricted, case.actor, verify_private_instance=private_only)
    assert registry.get_server_authorization(case.run_id)['decision'] == 'TEST_FIXTURE_NOT_REAL_APPROVAL'
    assert PrivateSyntheticTrialRegistry(case.restricted, uuid4(),
        verify_private_instance=private_only).get_server_authorization(case.run_id) is None
    with pytest.raises(WorkflowHeld, match='SYNTHETIC_PRIVATE_INSTANCE_UNVERIFIED'):
        PrivateSyntheticTrialRegistry(case.restricted, case.actor,
            verify_private_instance=lambda _:False).get_server_authorization(case.run_id)
    with pytest.raises(DBAPIError):
        with case.restricted.begin() as conn:
            conn.execute(text('SET LOCAL ROLE p1ai_runtime'))
            conn.execute(text("UPDATE project1_ai.synthetic_trial_authority SET authorization_json='{}'::jsonb"))
    # RESET ROLE must not allow the login principal to change its own approval.
    # This grant is strictly a disposable negative-test fixture.
    with case.admin.begin() as conn:
        conn.execute(text('GRANT UPDATE ON project1_ai.synthetic_trial_authority TO p1ai_engine'))
    try:
        with pytest.raises(WorkflowHeld, match='SYNTHETIC_AUTHORITY_PERMISSIONS_INVALID'):
            registry.get_server_authorization(case.run_id)
    finally:
        with case.admin.begin() as conn:
            conn.execute(text('REVOKE UPDATE ON project1_ai.synthetic_trial_authority FROM p1ai_engine'))


@pytest.mark.parametrize('trial_artifact', ['v101', 'owner_conditional'])
def test_governed_trial_fixture_with_registry_and_exact_request(case, trial_artifact):
    """Mock transport/decision only; this does not approve or call a model."""
    import importlib.util
    from pathlib import Path
    import httpx
    from pydantic import SecretStr
    from sitewise.project1.contracts import digest
    from sitewise.project1.disclosure import RegisteredSyntheticBdjDisclosure, SyntheticBdjAuthorization
    from sitewise.project1.model_assisted import run_registered_synthetic_bdj_trial
    from sitewise.project1.prompts import Prompt
    from sitewise.project1.provider import ENDPOINT, ModelRunner, TokenHarbor
    from sitewise.project1.bdj_discovery_candidate import DiscoveryOutputCandidate
    from sitewise.project1.synthetic_trial_registry import PrivateSyntheticTrialRegistry
    source_path = os.environ.get('BDJ_V102_SOURCE')
    if not source_path: pytest.skip('synthetic fixture path required')
    root = Path(source_path).parent
    saved = json.loads(Path(source_path).read_text(encoding='utf-8'))
    packet, definitions = saved['packet'], saved['definitions']
    packet['assessment_id'] = str(case.assessment)
    packet['assessment_revision'] = case.revision
    packet['source_fingerprint'] = digest({k:v for k,v in packet.items() if k != 'source_fingerprint'})
    rules_path = (root/'bdj_synthetic_trial_v1_0_1_rules.py' if trial_artifact == 'v101' else
                  Path(__file__).resolve().parents[2]/'tools/cp13_verification/v2/bdj_m2v1_information_gap_proposal.py')
    spec = importlib.util.spec_from_file_location('trial_rules_service', rules_path)
    rules = importlib.util.module_from_spec(spec); spec.loader.exec_module(rules)
    rules_hash = hashlib.sha256(Path(rules.__file__).read_bytes()).hexdigest()
    prompt = Prompt('BDJ-M2V1-INFO-GAP-TEST-1.0.1','You are a bounded business declaration reviewer.',
                    (root/'bdj_synthetic_trial_v1_0_1_prompt.txt').read_text(encoding='utf-8'))
    run_id = uuid4()
    with case.admin.begin() as conn:
        conn.execute(text('CREATE TABLE IF NOT EXISTS project1_ai.synthetic_trial_authority '
            '(run_id uuid PRIMARY KEY, owner_user_id uuid NOT NULL, authorization_json jsonb NOT NULL)'))
        conn.execute(text('REVOKE ALL ON project1_ai.synthetic_trial_authority FROM PUBLIC'))
        conn.execute(text('GRANT SELECT ON project1_ai.synthetic_trial_authority TO p1ai_runtime'))
        conn.execute(text('INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,assessment_revision,'
            'source_fingerprint,policy_fingerprint,work_identity) VALUES (:r,:o,:a,:v,:f,:p,:w)'),
            {'r':run_id,'o':case.actor,'a':case.assessment,'v':case.revision,
             'f':packet['source_fingerprint'],'p':'d'*64,'w':hashlib.sha256(uuid4().bytes).hexdigest()})
    current = {'owner_id':str(case.actor),'assessment_id':str(case.assessment),'revision':case.revision,
        'confirmation_id':packet['confirmation']['confirmation_id'],'source_fingerprint':packet['source_fingerprint']}
    def private_only(session):
        return session.execute(text("SELECT current_database() = 'project1_workflow_tests' AND inet_server_port()=:port"),
            {'port':int(os.environ.get('PROJECT1_BDJ_PRIVATE_PORT','55438'))}).scalar_one()
    registry = PrivateSyntheticTrialRegistry(case.restricted,case.actor,verify_private_instance=private_only)
    authorization = SyntheticBdjAuthorization(run_id=str(run_id),source_fingerprint=packet['source_fingerprint'],
                                              operator_receipt='TEST-ONLY-NOT-OWNER-APPROVAL')
    output = {'contract_version':'bdj-discovery-output/1-candidate','issues':[], 'overall_note':'Simulated output only.'}
    hits=[]
    def transport(request):
        hits.append(request.content)
        return httpx.Response(200,json={'model':MODEL,'choices':[{'finish_reason':'stop',
            'message':{'role':'assistant','content':json.dumps(output)}}]})
    provider = TokenHarbor(SecretStr('fake-only'),enabled=True,transport=httpx.MockTransport(transport))
    model_packet,_ = BDJEngine(rules).prepare_discovery_trial(packet,item_definitions=definitions,
        recheck_current=lambda:packet['source_fingerprint'])
    messages = prompt.messages(model_packet,DiscoveryOutputCandidate.model_json_schema())
    body = httpx.Request('POST', ENDPOINT,json=provider.prepare_payload(messages,DiscoveryOutputCandidate)).content
    body_hash = hashlib.sha256(body).hexdigest()
    gate = RegisteredSyntheticBdjDisclosure(authorization,registry=registry,current_source=lambda:dict(current),
        owner_id=case.actor,assessment_id=case.assessment,revision=case.revision,
        confirmation_id=current['confirmation_id'],rules_sha256=rules_hash,prompt_fingerprint=prompt.fingerprint,
        request_sha256=body_hash)
    ledger=PostgresAttemptLedger(case.restricted,case.actor,run_id)
    runner=ModelRunner(provider,ledger,{'BDJ':prompt},disclosure=gate)
    store=BdjResultStore(case.restricted,case.actor,run_id)
    invoke=lambda:run_registered_synthetic_bdj_trial(enabled=True,packet=packet,item_definitions=definitions,
        rules=rules,runner=runner,store=store,current_fingerprint=lambda:current['source_fingerprint'])
    with pytest.raises(WorkflowHeld,match='DISCLOSURE_REGISTERED_AUTHORIZATION_REQUIRED'): invoke()
    assert not hits
    record={**gate.expected}
    with case.admin.begin() as conn:
        conn.execute(text('INSERT INTO project1_ai.synthetic_trial_authority VALUES (:r,:o,CAST(:data AS jsonb))'),
                     {'r':run_id,'o':case.actor,'data':json.dumps(record)})
    current['owner_id'] = str(uuid4())
    with pytest.raises(WorkflowHeld,match='DISCLOSURE_CURRENT_SOURCE_REQUIRED'): invoke()
    current['owner_id'] = str(case.actor)
    current['source_fingerprint'] = 'e'*64
    with pytest.raises(WorkflowHeld,match='BDJ_TRIAL_CONFIRMATION_SOURCE_MISMATCH'): invoke()
    current['source_fingerprint'] = packet['source_fingerprint']
    gate.expected['request_sha256'] = 'a'*64
    with case.admin.begin() as conn:
        conn.execute(text('UPDATE project1_ai.synthetic_trial_authority SET authorization_json=CAST(:v AS jsonb) WHERE run_id=:r'),
                     {'r':run_id,'v':json.dumps(gate.expected)})
    with pytest.raises(WorkflowHeld,match='DISCLOSURE_REQUEST_MISMATCH'): invoke()
    assert not hits
    gate.expected['request_sha256'] = body_hash
    with case.admin.begin() as conn:
        conn.execute(text('UPDATE project1_ai.synthetic_trial_authority SET authorization_json=CAST(:v AS jsonb) WHERE run_id=:r'),
                     {'r':run_id,'v':json.dumps(gate.expected)})
    persisted = invoke()
    assert persisted['review_outcome'] == 'reviewed'
    assert persisted['model_returned'] == MODEL
    assert hits == [body]


# 2. idempotency ------------------------------------------------------------
def test_persist_same_attempt_twice_is_a_noop(case):
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    first = store(case).persist(case.attempt, engine_result('reviewed', [finding()]),
                                'returned', output_digest=DIGEST, **persist_kwargs())
    before = count(case)
    second = store(case).persist(case.attempt, engine_result('reviewed', [finding()]),
                                 'returned', output_digest=DIGEST, **persist_kwargs())
    assert first == second
    assert count(case) == before


# 3. rejected ---------------------------------------------------------------
def test_rejected_has_no_payload_and_no_finding_rows(case):
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    result_id = store(case).persist(
        case.attempt, engine_result('rejected'), 'returned',
        output_digest=DIGEST, **persist_kwargs())
    row = store(case).read(result_id)
    assert row['review_outcome'] == 'rejected'
    assert row['validation_status'] == 'invalid'
    assert row['findings'] == []
    assert count(case, 'bdj_result_findings', result_id) == 0
    with case.admin.connect() as conn:
        assert conn.execute(text(
            'SELECT result_payload FROM project1_ai.bdj_results WHERE result_id=:id'),
            {'id': result_id}).scalar() is None


# 4. transport failure ------------------------------------------------------
def test_transport_failure_is_not_reviewed(case):
    case.ledger.finish(case.attempt, 'unknown_outcome', None)
    result_id = store(case).persist(
        case.attempt, None, 'unknown_outcome', output_digest=None, **persist_kwargs())
    row = store(case).read(result_id)
    assert row['review_outcome'] is None
    assert row['validation_status'] == 'not_validated'
    assert row['findings'] == []
    assert count(case, 'bdj_result_findings', result_id) == 0


# 5. unclassified -----------------------------------------------------------
def test_unclassified_outcome_writes_nothing(case):
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    before = count(case)
    with pytest.raises(WorkflowHeld, match='RESULT_OUTCOME_UNCLASSIFIED'):
        store(case).persist(case.attempt, engine_result('held'), 'returned',
                            output_digest=DIGEST, **persist_kwargs())
    assert count(case) == before


# 6. raw without a cipher ---------------------------------------------------
def test_raw_output_without_a_cipher_raises(case):
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    before = count(case)
    with pytest.raises(WorkflowHeld, match='RESULT_RAW_RESPONSE_CIPHER_REQUIRED'):
        store(case).persist(case.attempt, engine_result('reviewed', []), 'returned',
                            output_digest=DIGEST, raw_output=b'RAW-MARKER',
                            **persist_kwargs())
    assert count(case) == before


# 7. raw is write-only ------------------------------------------------------
def test_raw_response_is_written_encrypted_and_never_read(case):
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    cipher = FernetCipher()
    plaintext = b'RAW-MARKER-9c1f'
    result_id = store(case, cipher).persist(
        case.attempt, engine_result('reviewed', []), 'returned',
        output_digest=DIGEST, raw_output=plaintext, **persist_kwargs())

    with case.admin.connect() as conn:
        row = conn.execute(text(
            'SELECT ciphertext, key_id, plaintext_digest, plaintext_bytes,'
            ' retention_until > created_at FROM project1_ai.bdj_raw_responses'
            ' WHERE result_id=:id'), {'id': result_id}).one()
    assert row.ciphertext != plaintext
    assert plaintext not in row.ciphertext
    assert row.key_id == cipher.key_id
    assert row.plaintext_digest == hashlib.sha256(plaintext).hexdigest()
    assert row.plaintext_bytes == len(plaintext)
    assert row[4] is True
    assert 'RAW-MARKER-9c1f' not in json.dumps(store(case, cipher).read(result_id),
                                               default=str)

    # p1ai_runtime may INSERT but not SELECT the raw table.
    with case.restricted.connect() as conn:
        conn.execute(text('SET LOCAL ROLE p1ai_runtime'))
        with pytest.raises(DBAPIError):
            conn.execute(text('SELECT * FROM project1_ai.bdj_raw_responses'))


# 8. projection -------------------------------------------------------------
def test_stored_payload_has_no_quote_and_the_projection_still_matches(case):
    """The quote is removed at write, so the projection has nothing to strip.

    Both halves are asserted because either alone is a weaker claim: a stored
    payload with no marker proves redaction ran, and a projection whose
    references and prose match the input proves redaction removed only the
    quote.
    """
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    original = finding()
    result_id = store(case).persist(
        case.attempt, engine_result('reviewed', [original]), 'returned',
        output_digest=DIGEST, **persist_kwargs())

    projected = store(case).read(result_id)
    assert MARKER not in json.dumps(projected, default=str)

    with case.admin.connect() as conn:
        stored = conn.execute(text(
            'SELECT result_payload::text FROM project1_ai.bdj_results'
            ' WHERE result_id=:id'), {'id': result_id}).scalar()
    assert MARKER not in stored
    assert '"quote"' not in stored

    # Nothing the read path consumes was lost.
    assert projected['findings'] == [
        {key: original[key] for key in
         ('rule_id', 'kind', 'observed_condition', 'counterargument',
          'justification', 'next_action')}]
    assert projected['references'] == [
        {key: ref[key] for key in ('item_key', 'answer_revision_id', 'item_version_id')}
        for ref in original['source_refs']]


def test_stored_payload_keeps_the_source_pointers(case):
    """Redaction removes the quote, not the pointer it qualifies."""
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    result_id = store(case).persist(
        case.attempt, engine_result('reviewed', [finding()]), 'returned',
        output_digest=DIGEST, **persist_kwargs())
    with case.admin.connect() as conn:
        payload = conn.execute(text(
            'SELECT result_payload FROM project1_ai.bdj_results'
            ' WHERE result_id=:id'), {'id': result_id}).scalar()
    refs = payload['findings'][0]['source_refs']
    assert [ref['item_key'] for ref in refs] == ['M2-04', 'M2-05']
    assert all(set(ref) == {'item_key', 'answer_revision_id', 'item_version_id'}
               for ref in refs)


def test_source_rows_are_unchanged_by_redaction(case):
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    result_id = store(case).persist(
        case.attempt, engine_result('reviewed', [finding()]), 'returned',
        output_digest=DIGEST,
        sources=[{'source_id': 'r1', 'source_version': 'v1',
                  'source_fingerprint': None, 'locator': 'M2-04@v1'}],
        **persist_kwargs())
    with case.admin.connect() as conn:
        row = conn.execute(text(
            'SELECT source_rank, source_id, source_version, locator'
            ' FROM project1_ai.bdj_result_sources WHERE result_id=:id'),
            {'id': result_id}).one()
    assert tuple(row) == (1, 'r1', 'v1', 'M2-04@v1')


# 8b. locator is a pointer --------------------------------------------------
def test_locator_prose_is_refused_and_nothing_is_written(case):
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    before = count(case)
    with pytest.raises(WorkflowHeld, match='RESULT_SOURCE_LOCATOR_INVALID'):
        store(case).persist(
            case.attempt, engine_result('reviewed', []), 'returned',
            output_digest=DIGEST,
            sources=[{'source_id': 'r1', 'source_version': 'v1',
                      'locator': f'quote {MARKER} was here'}], **persist_kwargs())
    assert count(case) == before


# 8c. detail is a closed code ----------------------------------------------
def test_validation_detail_prose_is_refused_and_nothing_is_written(case):
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    before = count(case)
    with pytest.raises(WorkflowHeld, match='RESULT_VALIDATION_DETAIL_INVALID'):
        store(case).persist(
            case.attempt, engine_result('reviewed', []), 'returned',
            output_digest=DIGEST,
            validations=[{'check_no': 1, 'check_code': 'SOURCE_QUOTE',
                          'severity': 'ERROR', 'passed': False,
                          'detail': f'quote {MARKER} did not match'}],
            **persist_kwargs())
    assert count(case) == before


# 8d. positive pointer/code case -------------------------------------------
def test_structured_locator_and_closed_detail_are_accepted(case):
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    result_id = store(case).persist(
        case.attempt, engine_result('reviewed', []), 'returned',
        output_digest=DIGEST,
        sources=[{'source_id': 'r1', 'source_version': 'v1',
                  'locator': 'M2-04@v1'}],
        validations=[{'check_no': 1, 'check_code': 'SOURCE_QUOTE_NOT_FOUND',
                      'severity': 'ERROR', 'passed': False,
                      'detail': 'SOURCE_QUOTE_NOT_FOUND'}], **persist_kwargs())
    assert store(case).read(result_id)['references'] == []


# 9. atomicity --------------------------------------------------------------
def test_finding_fk_failure_removes_the_parent_row(case):
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    before = count(case)
    with pytest.raises(WorkflowHeld, match='WORKFLOW_STORAGE_UNAVAILABLE'):
        store(case).persist(
            case.attempt, engine_result('reviewed', [finding()]), 'returned',
            output_digest=DIGEST, findings=[uuid4()], **persist_kwargs())
    assert count(case) == before


# Guard: the writer refuses a superuser session ----------------------------
def test_superuser_session_is_refused():
    with pytest.raises(WorkflowHeld, match='RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED'):
        BdjResultStore(create_engine(ADMIN_URL, hide_parameters=True),
                       uuid4(), uuid4()).read(uuid4())


# ---------------------------------------------------------------------------
# 10. Protected payload at rest: the versioned envelope, through persist/read.
#
# `result_payload` is retained indefinitely and readable by the row owner, so
# finding prose -- which redaction cannot remove -- is sealed when custody is
# supplied. Everything below goes through the real writer and the real reader.
# ---------------------------------------------------------------------------
PROSE = 'MARKER-PROSE-5c2e7a'
QUOTE = 'MARKER-QUOTE-5c2e7a'


def prose_finding(marker=PROSE):
    """A finding whose prose and quote both carry a sentinel."""
    return {**finding(quote=marker),
            'observed_condition': f'The declaration states {marker} verbatim.'}


def expected_finding(original):
    return {key: original[key] for key in
            ('rule_id', 'kind', 'observed_condition', 'counterargument',
             'justification', 'next_action')}


def expected_references(original):
    return [{key: ref[key] for key in
             ('item_key', 'answer_revision_id', 'item_version_id')}
            for ref in original['source_refs']]


def stored_payload(case, result_id):
    with case.admin.connect() as conn:
        return conn.execute(text(
            'SELECT result_payload FROM project1_ai.bdj_results WHERE result_id=:id'),
            {'id': result_id}).scalar()


def test_encrypted_payload_round_trips_through_persist_and_read(case, tmp_path):
    custody = LocalKeyCustody(tmp_path / 'custody')
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    original = prose_finding()

    result_id = store(case, payload_custody=custody).persist(
        case.attempt, engine_result('reviewed', [original]), 'returned',
        output_digest=DIGEST, **persist_kwargs())

    row = store(case, payload_custody=custody).read(result_id)
    assert row['validation_status'] == 'valid'
    assert row['findings'] == [expected_finding(original)]
    assert row['references'] == expected_references(original)


def test_stored_envelope_contains_no_plaintext_sentinel(case, tmp_path):
    custody = LocalKeyCustody(tmp_path / 'custody')
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    original = prose_finding()

    result_id = store(case, payload_custody=custody).persist(
        case.attempt, engine_result('reviewed', [original]), 'returned',
        output_digest=DIGEST, **persist_kwargs())

    payload = stored_payload(case, result_id)
    serialised = json.dumps(payload)
    assert payload[PAYLOAD_ENVELOPE_MARKER] == PAYLOAD_ENVELOPE_V1
    assert set(payload) == PAYLOAD_ENVELOPE_FIELDS
    assert payload['key_id'] == payload_key_id(result_id)
    assert PROSE not in serialised, 'finding prose must not be readable at rest'
    assert QUOTE not in serialised
    assert '"quote"' not in serialised
    assert 'observed_condition' not in serialised

    # The envelope seals exactly the redacted payload, not the raw one.
    expected = json.dumps(redact_payload({'findings': [original]}),
                          ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    assert payload['plaintext_bytes'] == len(expected)
    assert payload['plaintext_digest'] == hashlib.sha256(expected).hexdigest()


def test_legacy_plaintext_payload_still_reads_unchanged(case, tmp_path):
    custody = LocalKeyCustody(tmp_path / 'custody')
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    original = prose_finding()

    result_id = store(case).persist(
        case.attempt, engine_result('reviewed', [original]), 'returned',
        output_digest=DIGEST, **persist_kwargs())

    payload = stored_payload(case, result_id)
    assert PAYLOAD_ENVELOPE_MARKER not in payload

    # A row written before the envelope existed reads with or without custody.
    for reader in (store(case), store(case, payload_custody=custody)):
        row = reader.read(result_id)
        assert row['findings'] == [expected_finding(original)]
        assert row['references'] == expected_references(original)


def test_encrypted_payload_without_custody_holds_instead_of_emptying(case, tmp_path):
    custody = LocalKeyCustody(tmp_path / 'custody')
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    result_id = store(case, payload_custody=custody).persist(
        case.attempt, engine_result('reviewed', [prose_finding()]), 'returned',
        output_digest=DIGEST, **persist_kwargs())

    with pytest.raises(WorkflowHeld, match='RESULT_PAYLOAD_CIPHER_REQUIRED'):
        store(case).read(result_id)


def test_wrong_custody_is_denied_without_leaking_key_material(case, tmp_path):
    custody = LocalKeyCustody(tmp_path / 'custody')
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    result_id = store(case, payload_custody=custody).persist(
        case.attempt, engine_result('reviewed', [prose_finding()]), 'returned',
        output_digest=DIGEST, **persist_kwargs())

    material = custody.get(payload_key_id(result_id))
    envelope = stored_payload(case, result_id)
    other = LocalKeyCustody(tmp_path / 'other-custody')

    with pytest.raises(WorkflowHeld) as caught:
        store(case, payload_custody=other).read(result_id)
    assert str(caught.value) == 'RESULT_PAYLOAD_UNAVAILABLE'
    message = repr(caught.value)
    assert material.decode('ascii') not in message
    assert envelope['ciphertext'] not in message
    assert PROSE not in message


def test_destroying_one_payload_key_leaves_the_other_result_readable(case, tmp_path):
    """Key isolation, through two real persisted rows and one destruction."""
    custody = LocalKeyCustody(tmp_path / 'custody')
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    first = store(case, payload_custody=custody).persist(
        case.attempt, engine_result('reviewed', [prose_finding()]), 'returned',
        output_digest=DIGEST, **persist_kwargs())

    # A second attempt on the same run, so the case holds two results. The
    # stage label is irrelevant to bdj_results, whose FK keys on attempt_no.
    second_attempt = case.ledger.reserve('QJ', PROMPT, '9' * 64, '9' * 64)
    case.ledger.finish(second_attempt, 'returned', DIGEST)
    second = store(case, payload_custody=custody).persist(
        second_attempt, engine_result('reviewed', [prose_finding()]), 'returned',
        output_digest=DIGEST, **persist_kwargs())
    assert first != second

    custody.destroy(payload_key_id(first))

    with pytest.raises(WorkflowHeld, match='RESULT_PAYLOAD_UNAVAILABLE'):
        store(case, payload_custody=custody).read(first)
    surviving = store(case, payload_custody=custody).read(second)
    assert surviving['findings'] == [expected_finding(prose_finding())]
    assert custody.state(payload_key_id(second)) == STATE_LIVE
    assert custody.state(payload_key_id(first)) == STATE_DESTROYED


def test_run_retention_does_not_select_or_destroy_the_payload_key(case, tmp_path):
    """The payload has no retention deadline, so retention must not name its key.

    `bdj_results` is retained indefinitely; only `bdj_raw_responses` is on a
    clock. Both rows are written for one result, both keys live in one custody
    directory, and one retention run must destroy exactly the raw key.
    """
    custody = LocalKeyCustody(tmp_path / 'custody')
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    result_id = store(case, cipher=CustodyCipher(custody),
                      payload_custody=custody).persist(
        case.attempt, engine_result('reviewed', [prose_finding()]), 'returned',
        output_digest=DIGEST, raw_output=b'RAW-MARKER-retention', **persist_kwargs())

    with case.admin.connect() as conn:
        raw_key = conn.execute(text(
            'SELECT key_id FROM project1_ai.bdj_raw_responses WHERE result_id=:id'),
            {'id': result_id}).scalar()
    payload_key = payload_key_id(result_id)
    assert raw_key != payload_key
    assert raw_key.startswith('rec-')

    now = datetime.now(timezone.utc) + timedelta(days=3650)
    selected = {record.key_id for record in select_expired(case.admin, now=now)}
    assert raw_key in selected
    assert payload_key not in selected

    run_retention(case.admin, custody, ledger_path=tmp_path / 'receipts.jsonl',
                  now=now)

    assert custody.state(raw_key) == STATE_DESTROYED
    assert custody.state(payload_key) == STATE_LIVE
    row = store(case, payload_custody=custody).read(result_id)
    assert row['findings'] == [expected_finding(prose_finding())]


def test_history_projection_excludes_the_payload_and_the_quote(case, tmp_path):
    custody = LocalKeyCustody(tmp_path / 'custody')
    case.ledger.finish(case.attempt, 'returned', DIGEST)
    original = prose_finding()
    store(case, payload_custody=custody).persist(
        case.attempt, engine_result('reviewed', [original]), 'returned',
        output_digest=DIGEST, **persist_kwargs())

    rows = results_for_assessment(case.restricted, case.actor, case.assessment,
                                  payload_custody=custody)
    assert len(rows) == 1
    assert rows[0]['findings'] == [expected_finding(original)]
    assert rows[0]['references'] == expected_references(original)
    serialised = json.dumps(rows, default=str)
    assert 'result_payload' not in serialised
    assert QUOTE not in serialised
    assert '"quote"' not in serialised
    assert PAYLOAD_ENVELOPE_MARKER not in serialised

    # Without custody the History read fails closed rather than dropping findings.
    with pytest.raises(WorkflowHeld, match='RESULT_PAYLOAD_CIPHER_REQUIRED'):
        results_for_assessment(case.restricted, case.actor, case.assessment)
