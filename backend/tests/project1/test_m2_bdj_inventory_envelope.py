"""Offline projection regression; no network, database, or authority grants."""
from copy import deepcopy
from uuid import uuid4

import pytest

from scripts.register_m2_v1 import definition
from sitewise.core.exceptions import ConflictError
from sitewise.project1.contracts import digest
from sitewise.project1.projection import M2SourceProjection, verify_bdj_inventory, bind_bdj_inventory_to_confirmation


def test_authenticated_source_path_binds_inventory_to_current_confirmation(monkeypatch):
    from contextlib import contextmanager
    from types import SimpleNamespace
    from sitewise.api.v1 import project1_workflow as api
    from sitewise.project1 import database_identity
    monkeypatch.setattr(database_identity, 'verify_workflow_database', lambda session: True)
    repo = Source()
    confirmation_id = uuid4()
    repo.latest_confirmation = lambda assessment, owner: {'id':confirmation_id}
    class Session:
        def execute(self, *_): return SimpleNamespace(one=lambda: ('Dss', False, False))
        def rollback(self): pass
    class M2:
        def __init__(self, _repo): pass
        @contextmanager
        def locked_confirmed_source(self, assessment, owner, **kwargs):
            assert (assessment, owner) == (repo.assessment, repo.owner)
            assert kwargs == {'confirmation_id':confirmation_id, 'expected_revision':repo.rev}
            yield {'confirmation_id':confirmation_id, 'snapshot_digest':'a'*64}
    monkeypatch.setattr(api, 'SqlModelM2Repository', lambda session: repo)
    monkeypatch.setattr(api, 'M2Service', M2)
    user = SimpleNamespace(user_id=repo.owner)
    ordinary = api.source(Session(), user, repo.assessment, repo.rev)
    envelope = api.source(Session(), user, repo.assessment, repo.rev, include_inventory=True)
    assert envelope['projection'] == ordinary
    assert envelope['projection']['confirmation']['confirmation_id'] == str(confirmation_id)
    verify_bdj_inventory(envelope, item_definitions=repo.items)
    assert len(envelope['item_inventory']['items']) == 11


class Source:
    def __init__(self):
        data, self.schema_digest, self.instrument, self.items = definition()
        self.version = data['version_tag']
        self.owner, self.assessment = uuid4(), uuid4()
        self.answers = {}
        self.rev = 5
        self.rollback_count = 0
        for key, value in [('M2V1-02', 'DELIVERY'), ('M2V1-04', ['STUDENTS']),
                           ('M2V1-08', ['UNKNOWN']), ('M2V1-09', ['NONE'])]:
            item = next(i for i in self.items if i['item_key'] == key)
            self.answers[key] = {'id':uuid4(), 'assessment_id':self.assessment,
                'item_version_id':item['id'], 'assessment_revision':1,
                'answer_state':'ANSWERED', 'value_json':value}

    def get_assessment_for_update(self, assessment, owner):
        return {'id':self.assessment, 'revision':self.rev, 'confirmed_revision':self.rev,
                'instrument_id':self.instrument} if (assessment,owner)==(self.assessment,self.owner) else None

    def get_instrument(self, _):
        return {'id':self.instrument, 'approval_state':'AUTHORIZED', 'version_tag':self.version,
                'schema_digest':self.schema_digest}

    def list_items(self, _): return self.items
    def get_latest_answers(self, *_): return self.answers
    def rollback(self): self.rollback_count += 1


def test_inventory_is_bound_to_unchanged_legacy_projection_and_all_items():
    repo = Source()
    projection = M2SourceProjection(repo)
    original = deepcopy(repo.answers)
    historical = projection.read(repo.assessment, repo.owner, repo.rev)
    envelope = projection.read(repo.assessment, repo.owner, repo.rev, include_inventory=True)
    verify_bdj_inventory(envelope, item_definitions=repo.items)
    assert envelope['projection'] == historical
    assert repo.answers == original and repo.rollback_count == 2
    rows = {x['item_key']:x for x in envelope['item_inventory']['items']}
    assert len(rows) == 11
    assert rows['M2V1-05']['state'] == 'DERIVED' and rows['M2V1-05']['answer_revision_id'] is None
    assert rows['M2V1-05']['derived_from']['answer_revision_id'] == str(repo.answers['M2V1-04']['id'])
    assert rows['M2V1-07']['state'] == 'NOT_APPLICABLE'
    assert rows['M2V1-11']['state'] == 'NOT_APPLICABLE'
    assert rows['M2V1-01']['state'] == 'MISSING'
    assert rows['M2V1-08']['state'] == 'ANSWERED' and rows['M2V1-08']['value'] == ['UNKNOWN']


def test_inventory_rejects_tampering_and_untrusted_definitions():
    repo = Source()
    envelope = M2SourceProjection(repo).read(repo.assessment, repo.owner, repo.rev, include_inventory=True)
    envelope['item_inventory']['items'][0]['value'] = 'invented'
    with pytest.raises(ConflictError): verify_bdj_inventory(envelope, item_definitions=repo.items)
    # An unkeyed digest is not authorization: even a recomputed digest must
    # not make an invented revision appear in the authenticated projection.
    forged = M2SourceProjection(repo).read(repo.assessment, repo.owner, repo.rev, include_inventory=True)
    missing = next(x for x in forged['item_inventory']['items'] if x['item_key'] == 'M2V1-01')
    missing['answer_revision_id'] = str(uuid4())
    bound = {k:v for k,v in forged['item_inventory'].items() if k != 'inventory_fingerprint'}
    forged['item_inventory']['inventory_fingerprint'] = digest(bound)
    with pytest.raises(ConflictError, match='invented'): verify_bdj_inventory(forged, item_definitions=repo.items)
    forged = M2SourceProjection(repo).read(repo.assessment, repo.owner, repo.rev, include_inventory=True)
    row = next(x for x in forged['item_inventory']['items'] if x['item_key'] == 'M2V1-01')
    row['state'], row['value'] = 'ANSWERED', 'FABRICATED'
    bound = {k:v for k,v in forged['item_inventory'].items() if k != 'inventory_fingerprint'}
    forged['item_inventory']['inventory_fingerprint'] = digest(bound)
    with pytest.raises(ConflictError, match='recomputed'): verify_bdj_inventory(forged, item_definitions=repo.items)
    repo.items[0]['instrument_id'] = uuid4()
    with pytest.raises(ConflictError):
        M2SourceProjection(repo).read(repo.assessment, repo.owner, repo.rev, include_inventory=True)


def test_inventory_rebinds_only_to_the_same_current_confirmed_projection():
    repo = Source()
    envelope = M2SourceProjection(repo).read(repo.assessment, repo.owner, repo.rev, include_inventory=True)
    confirmed = {**envelope['projection'], 'confirmation':{'confirmation_id':str(uuid4()), 'snapshot_digest':'a'*64}}
    confirmed['source_fingerprint'] = digest({k:v for k,v in confirmed.items() if k != 'source_fingerprint'})
    bound = bind_bdj_inventory_to_confirmation(envelope, confirmed, item_definitions=repo.items)
    verify_bdj_inventory(bound, item_definitions=repo.items)
    assert bound['item_inventory']['source_fingerprint'] == confirmed['source_fingerprint']
    changed = deepcopy(confirmed)
    changed['assessment_revision'] += 1
    changed['source_fingerprint'] = digest({k:v for k,v in changed.items() if k != 'source_fingerprint'})
    with pytest.raises(ConflictError, match='changed'):
        bind_bdj_inventory_to_confirmation(envelope, changed, item_definitions=repo.items)
    malformed = deepcopy(confirmed)
    malformed['confirmation']['snapshot_digest'] = 'invalid'
    malformed['source_fingerprint'] = digest({k:v for k,v in malformed.items() if k != 'source_fingerprint'})
    with pytest.raises(ConflictError, match='confirmation'):
        bind_bdj_inventory_to_confirmation(envelope, malformed, item_definitions=repo.items)


def test_synthetic_trial_provider_payload_includes_verified_eleven_item_inventory():
    import importlib.util
    from pathlib import Path
    import json
    from pydantic import SecretStr
    from sitewise.project1.bdj import BDJEngine
    from sitewise.project1.bdj_discovery_candidate import DiscoveryOutputCandidate
    from sitewise.project1.prompts import PROMPTS
    from sitewise.project1.provider import TokenHarbor
    repo = Source()
    envelope = M2SourceProjection(repo).read(repo.assessment, repo.owner, repo.rev, include_inventory=True)
    # Marker is a fixture, not a real server-side classification or approval.
    packet = {**envelope['projection'], 'data_class':'SYNTHETIC_NONHUMAN',
              'confirmation':{'confirmation_id':str(uuid4()), 'snapshot_digest':'a'*64}}
    packet['source_fingerprint'] = digest({k:v for k,v in packet.items() if k != 'source_fingerprint'})
    fixture_inventory = {**envelope['item_inventory'], 'source_fingerprint':packet['source_fingerprint']}
    fixture_inventory['inventory_fingerprint'] = digest({k:v for k,v in fixture_inventory.items() if k != 'inventory_fingerprint'})
    bound = {'projection':packet, 'item_inventory':fixture_inventory}
    path = Path(__file__).resolve().parents[2]/'tools/cp13_verification/v2/bdj_m2v1_information_gap_proposal.py'
    spec = importlib.util.spec_from_file_location('inventory_rule_fixture', path)
    rules = importlib.util.module_from_spec(spec); spec.loader.exec_module(rules)
    model_packet, _ = BDJEngine(rules).prepare_discovery_trial(packet, item_definitions=repo.items,
        recheck_current=lambda:packet['source_fingerprint'], inventory_envelope=bound)
    payload = TokenHarbor(SecretStr('offline-only')).prepare_payload(
        PROMPTS['BDJ'].messages(model_packet, DiscoveryOutputCandidate.model_json_schema()), DiscoveryOutputCandidate)
    sent = json.loads(payload['messages'][-1]['content'])['source_data']
    assert sent['item_inventory'] == fixture_inventory
    assert len(sent['item_inventory']['items']) == 11
    assert sent['source_fingerprint'] == packet['source_fingerprint']
    bound['item_inventory']['items'][0]['value'] = 'fabricated'
    with pytest.raises(ConflictError):
        BDJEngine(rules).prepare_discovery_trial(packet, item_definitions=repo.items,
            recheck_current=lambda:packet['source_fingerprint'], inventory_envelope=bound)
