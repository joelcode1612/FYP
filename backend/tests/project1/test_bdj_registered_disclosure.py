"""Pure tests: no database, no real decision and no external requests."""
import hashlib
from copy import deepcopy
from types import SimpleNamespace

import httpx
import pytest
from pydantic import SecretStr

from sitewise.project1.contracts import BDJOutput, WorkflowHeld
from sitewise.project1.disclosure import RegisteredSyntheticBdjDisclosure, SyntheticBdjAuthorization
from sitewise.project1.prompts import Prompt
from sitewise.project1.provider import ENDPOINT, MODEL, ModelRunner, TokenHarbor


@pytest.fixture
def world():
    packet = {'schema_version':'project1-m2-projection/1-candidate', 'assessment_id':'assessment',
              'assessment_revision':11, 'source_fingerprint':'f'*64,
              'confirmation':{'confirmation_id':'confirmation'}}
    current = {'owner_id':'owner','assessment_id':'assessment','revision':11,
               'confirmation_id':'confirmation','source_fingerprint':'f'*64}
    prompt = Prompt('SYNTHETIC-UNIT', 'Test only', 'Return a test object.')
    provider = TokenHarbor(SecretStr('fake-test-key'), enabled=False)
    messages = prompt.messages(packet, BDJOutput.model_json_schema())
    body = httpx.Request('POST', ENDPOINT, json=provider.prepare_payload(messages, BDJOutput)).content
    authorization = SyntheticBdjAuthorization(run_id='run', source_fingerprint='f'*64,
                                               operator_receipt='MOCK-DECISION-ONLY')
    expected = {'run_id':'run','owner_id':'owner','assessment_id':'assessment','revision':11,
        'confirmation_id':'confirmation','source_fingerprint':'f'*64,'endpoint':ENDPOINT,'model':MODEL,
        'rules_sha256':'a'*64,'prompt_fingerprint':prompt.fingerprint,
        'request_sha256':hashlib.sha256(body).hexdigest(), 'approval_receipt':'MOCK-DECISION-ONLY',
        'data_class':'SYNTHETIC_NONHUMAN','decision':'APPROVED','max_attempts':1}
    registry = SimpleNamespace(get_server_authorization=lambda run: deepcopy(expected))
    gate = RegisteredSyntheticBdjDisclosure(authorization, registry=registry,
        current_source=lambda:deepcopy(current), owner_id='owner', assessment_id='assessment',
        revision=11, confirmation_id='confirmation', rules_sha256='a'*64,
        prompt_fingerprint=prompt.fingerprint, request_sha256=expected['request_sha256'])
    return SimpleNamespace(packet=packet,current=current,expected=expected,gate=gate,
                           provider=provider,prompt=prompt,messages=messages,registry=registry)


def test_exact_fixture_binding_and_body(world):
    world.gate.require_current('BDJ',world.packet,ENDPOINT,MODEL)
    world.gate.require_request(world.provider,world.prompt,world.messages,BDJOutput)


@pytest.mark.parametrize('key', ['owner_id','assessment_id','revision','confirmation_id',
    'source_fingerprint','endpoint','model','rules_sha256','prompt_fingerprint',
    'request_sha256','approval_receipt','data_class','decision','max_attempts'])
def test_each_registry_binding_is_required(world,key):
    world.expected[key] = 'wrong'
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_REGISTERED_AUTHORIZATION_REQUIRED'):
        world.gate.require_current('BDJ',world.packet,ENDPOINT,MODEL)


def test_current_source_and_request_tampering_refused(world):
    world.current['revision'] = 12
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_CURRENT_SOURCE_REQUIRED'):
        world.gate.require_current('BDJ',world.packet,ENDPOINT,MODEL)
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_REQUEST_MISMATCH'):
        world.gate.require_request(world.provider,world.prompt,world.messages + [{'role':'user','content':'changed'}],BDJOutput)


def test_runner_enforces_registered_gate_before_attempt_reservation(world):
    class Ledger:
        def __init__(self): self.calls = []
        def reserve(self, *args): self.calls.append(args); return 1
        def finish(self, *args): self.calls.append(args)
    ledger = Ledger()
    runner = ModelRunner(world.provider, ledger, {'BDJ':world.prompt}, disclosure=world.gate)
    world.expected['decision'] = 'PENDING'
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_REGISTERED_AUTHORIZATION_REQUIRED'):
        runner('BDJ', world.packet, BDJOutput)
    assert ledger.calls == []
