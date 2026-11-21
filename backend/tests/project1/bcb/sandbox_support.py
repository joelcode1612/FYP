"""Synthetic adapter only; never imports the real application or database."""
from contextlib import contextmanager
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
from uuid import UUID

from sitewise.services.business_context_v1 import source_hash
from sitewise.services.ports.business_context_v1_port import ContextRequest, ContextReadView


def load_fixture():
    return json.loads((Path(__file__).parent/'fixtures/valid_confirmed.json').read_text(encoding='utf-8'))


def request_for(fixture):
    r = deepcopy(fixture['request'])
    for k in ('viewer_id', 'assessment_id', 'confirmation_id'):
        r[k] = UUID(r[k])
    return ContextRequest(**r)


def rebind(f):
    """Test setup only: simulate a new authoritative confirmation, not app logic."""
    s = f['confirmation']['snapshot_json']
    s['answer_revisions'] = [
        {'item_key': k, 'answer_revision_id': a['id'], 'item_version_id': a['item_version_id'],
         'answer_state': a['answer_state'], 'value': a['value_json']}
        for k, a in sorted(f['answers'].items())]
    s['unresolved_candidate_findings'] = sorted(x['id'] for x in f['findings'])
    f['confirmation']['acknowledged_issue_ids'] = s['unresolved_candidate_findings'][:]
    s['finding_decision_event_refs'] = {x['id']: 'SYNTHETIC-DECISION-'+x['id'] for x in f['findings']}
    f['confirmation']['snapshot_digest'] = source_hash(s)
    f['bindings']['concept']['m2_snapshot_digest'] = source_hash(s)


class FixedClock:
    def now(self): return datetime(2026, 11, 8, tzinfo=timezone.utc)


class SyntheticAuthorization:
    def __init__(self, f): self.f, self.calls = f, 0
    def authorize(self, request):
        self.calls += 1
        return deepcopy(self.f['decision'])


class SyntheticSnapshots:
    def __init__(self, f): self.f, self.opens, self.calls = f, 0, []
    @contextmanager
    def open_read(self, request, decision):
        self.opens += 1
        frozen = deepcopy(self.f)
        yield ContextReadView(SyntheticM2Read(frozen, self.calls), frozen['bindings'])


class SyntheticM2Read:
    def __init__(self, f, calls): self.f, self.calls = f, calls
    def _read(self, name):
        self.calls.append(name)
        return deepcopy(self.f[name])
    def get_assessment(self, assessment_id, actor_id): return self._read('assessment')
    def get_confirmation(self, confirmation_id, actor_id): return self._read('confirmation')
    def get_instrument(self, instrument_id): return self._read('instrument')
    def list_items(self, instrument_id): return self._read('items')
    def get_latest_answers(self, assessment_id, revision): return self._read('answers')
    def get_findings(self, assessment_id, revision): return self._read('findings')
    def __getattr__(self, name):
        raise AssertionError('Write or unsupported access attempted: '+name)
