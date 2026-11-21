"""Retention by crypto-shredding, plus the honest measurement of requirement 3.

No database is needed. `shred()` takes the records that `select_expired()`
would return, so the destruction path -- the part that can be wrong in a way
nobody notices -- is exercised without a connection, a grant or a clone.

What is NOT covered here: the SQL predicate in `select_expired()` and the
`p1ai_audit` identity it needs. Both are database facts, and asserting them
from a pure test would only assert that the string in this file matches itself.
"""
import json
from datetime import datetime, timedelta, timezone

import pytest

from sitewise.project1.bdj import BDJEngine
from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.key_custody import (OUTCOME_DESTROYED, LocalKeyCustody,
                                           CustodyCipher)
from sitewise.project1.result_contracts import classify
from sitewise.project1.result_store import redact_payload
from sitewise.project1.retention import (ACTOR_RETENTION_JOB, RECEIPT_SCHEMA,
                                         ExpiredRecord, run_retention, shred)

NOW = datetime(2026, 6, 1, 12, 0, tzinfo=timezone.utc)
PAST = NOW - timedelta(days=1)


@pytest.fixture
def custody(tmp_path):
    return LocalKeyCustody(tmp_path / 'custody')


@pytest.fixture
def ledger(tmp_path):
    return tmp_path / 'audit' / 'receipts.jsonl'


def lines(path):
    return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]


def test_expired_record_is_shredded_and_ciphertext_is_unchanged(custody, ledger):
    cipher = CustodyCipher(custody)
    plaintext = b'the original model output, containing an answer span'
    ciphertext, key_id = cipher.encrypt(plaintext)
    before = bytes(ciphertext)

    # The deadline is in the past, which is exactly what select_expired()
    # selects on. The selection is SQL; the consequence is asserted here.
    retention_until = PAST
    assert retention_until <= NOW

    report = shred(custody, [ExpiredRecord(result_id='res-A', key_id=key_id)],
                   ledger_path=ledger, now=NOW)

    assert len(report.recorded) == 1
    assert bytes(ciphertext) == before, 'the stored ciphertext must be untouched'
    assert custody.get(key_id) is None
    with pytest.raises(Exception) as caught:
        cipher.decrypt(ciphertext, key_id)
    assert str(caught.value) == 'KEY_DESTROYED'


def test_receipt_carries_actor_result_key_timestamp_reason_and_outcome(custody, ledger):
    cipher = CustodyCipher(custody)
    _, key_id = cipher.encrypt(b'x')
    shred(custody, [ExpiredRecord(result_id='res-A', key_id=key_id)],
          ledger_path=ledger, now=NOW)

    entry = lines(ledger)[0]
    assert entry['schema'] == RECEIPT_SCHEMA
    assert entry['actor'] == ACTOR_RETENTION_JOB
    assert entry['result_id'] == 'res-A'
    assert entry['key_id'] == key_id
    assert entry['timestamp'] == NOW.isoformat()
    assert entry['reason_code'] == 'RETENTION_EXPIRED'
    assert entry['outcome'] == OUTCOME_DESTROYED
    assert set(entry) == {'schema', 'actor', 'result_id', 'key_id', 'timestamp',
                          'destroyed_at', 'reason_code', 'outcome'}


def test_destruction_is_idempotent_with_exactly_one_receipt(custody, ledger):
    cipher = CustodyCipher(custody)
    _, key_id = cipher.encrypt(b'x')
    record = ExpiredRecord(result_id='res-A', key_id=key_id)

    first = shred(custody, [record], ledger_path=ledger, now=NOW)
    second = shred(custody, [record], ledger_path=ledger, now=NOW)

    assert len(first.recorded) == 1
    assert second.recorded == []
    assert second.already_destroyed == [key_id]
    assert len(lines(ledger)) == 1, 'a repeat must not append a second receipt'


def test_one_receipt_per_key_even_if_two_rows_share_it(custody, ledger):
    cipher = CustodyCipher(custody)
    _, key_id = cipher.encrypt(b'x')
    report = shred(custody, [
        ExpiredRecord(result_id='res-A', key_id=key_id),
        ExpiredRecord(result_id='res-B', key_id=key_id),
    ], ledger_path=ledger, now=NOW)
    assert len(report.recorded) == 1
    assert len(lines(ledger)) == 1


def test_shredding_one_record_leaves_the_others_decryptable(custody, ledger):
    """The isolation requirement, proved through the retention job itself."""
    cipher = CustodyCipher(custody)
    kept = {}
    for name in ('B', 'C'):
        plaintext = f'record {name}'.encode()
        ciphertext, key_id = cipher.encrypt(plaintext)
        kept[name] = (plaintext, ciphertext, key_id)
    _, expired_key = cipher.encrypt(b'record A')

    shred(custody, [ExpiredRecord(result_id='res-A', key_id=expired_key)],
          ledger_path=ledger, now=NOW)

    for name, (plaintext, ciphertext, key_id) in kept.items():
        assert cipher.decrypt(ciphertext, key_id) == plaintext, name


def test_ledger_is_append_only(custody, ledger):
    cipher = CustodyCipher(custody)
    _, first_key = cipher.encrypt(b'first')
    shred(custody, [ExpiredRecord(result_id='res-A', key_id=first_key)],
          ledger_path=ledger, now=NOW)
    prefix = ledger.read_bytes()

    _, second_key = cipher.encrypt(b'second')
    shred(custody, [ExpiredRecord(result_id='res-B', key_id=second_key)],
          ledger_path=ledger, now=NOW + timedelta(hours=1))

    assert ledger.read_bytes().startswith(prefix)
    assert [entry['key_id'] for entry in lines(ledger)] == [first_key, second_key]


def test_a_missing_key_is_recorded_as_an_incident(custody, ledger):
    report = shred(custody, [ExpiredRecord(result_id='res-A',
                                           key_id='rec-never-provisioned')],
                   ledger_path=ledger, now=NOW)
    assert report.missing == ['rec-never-provisioned']
    assert lines(ledger)[0]['outcome'] == 'KEY_MISSING'


def test_a_naive_clock_is_refused(custody, ledger):
    """A naive deadline would be compared in the server's local zone."""
    with pytest.raises(ValueError, match='RETENTION_CLOCK_MUST_BE_TIMEZONE_AWARE'):
        shred(custody, [], ledger_path=ledger, now=datetime(2026, 6, 1, 12, 0))


def test_run_retention_composes_select_and_shred(custody, ledger):
    """run_retention is selection + shred; selection is stubbed, shred is real."""
    cipher = CustodyCipher(custody)
    _, key_id = cipher.encrypt(b'x')

    class FakeResult:
        def __init__(self, rows):
            self._rows = rows

        def mappings(self):
            return self

        def all(self):
            return self._rows

    class FakeConnection:
        def __init__(self, rows):
            self._rows = rows
            self.seen = None

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def execute(self, statement, params):
            self.seen = params
            return FakeResult(self._rows)

    class FakeEngine:
        def __init__(self, rows):
            self.conn = FakeConnection(rows)

        def connect(self):
            return self.conn

    engine = FakeEngine([{'result_id': 'res-A', 'key_id': key_id}])
    report = run_retention(engine, custody, ledger_path=ledger, now=NOW)
    assert engine.conn.seen['now'] == NOW
    assert engine.conn.seen['limit'] == 500
    assert len(report.recorded) == 1
    assert lines(ledger)[0]['result_id'] == 'res-A'


# ---------------------------------------------------------------------------
# Requirement 3 measurement.
#
# The directive asks for proof that sensitive plaintext is not retained
# unprotected in bdj_results.result_payload. The quote is now removed at the
# write boundary (`result_store.redact_payload`), so this section measures the
# redacted payload -- and scans *every* string in it, not just the quote field,
# because finding prose can echo a declaration fragment after the quote is
# gone. What remains is reported, not hidden.
# ---------------------------------------------------------------------------
QUOTE = 'Takeaway-only service for busy commuters. QUOTE-MARKER-9f2c'
MARKER = 'QUOTE-MARKER-9f2c'
PACKET_DECLARATIONS = [
    {'item_key': 'M2-04', 'item_version_id': 'ver-04', 'answer_revision_id': 'rev-04',
     'answer_state': 'ANSWERED', 'value': QUOTE},
    {'item_key': 'M2-05', 'item_version_id': 'ver-05', 'answer_revision_id': 'rev-05',
     'answer_state': 'ANSWERED', 'value': 'DINE_IN_FOCUSED'},
]


def _packet():
    from sitewise.domain import bdj_candidate_rules
    content = {
        'schema_version': 'project1-m2-projection/1-candidate',
        'assessment_id': '00000000-0000-0000-0000-000000000001',
        'assessment_revision': 3,
        'instrument_id': '00000000-0000-0000-0000-000000000002',
        'instrument_version': 'M2-20260101-1',
        'instrument_digest': 'b' * 64,
        'declarations': PACKET_DECLARATIONS,
        'governance_items': ['M2-20', 'M2-21'],
        'excluded_items': {'M2-11': 'DEFERRED', 'M2-15': 'PRIVACY_PENDING'},
        'confirmed': True,
        'facts_independently_verified': False,
    }
    return {**content, 'source_fingerprint': digest(content)}, bdj_candidate_rules


def _reviewed_row():
    packet, rules = _packet()
    review = BDJEngine(rules=rules).review(
        packet, recheck_current=lambda: packet['source_fingerprint'])
    assert review['outcome'] == 'reviewed'
    assert review['findings'][0]['source_refs'][0]['quote'] == QUOTE
    return review, classify(review, 'returned', output_digest='a' * 64)


def _strings(value):
    """Every string in the structure, keys included."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from _strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _strings(item)


def test_requirement_3_redacted_payload_contains_no_quote_text():
    review, row = _reviewed_row()
    assert QUOTE in json.dumps(row['result_payload'], ensure_ascii=False), \
        'precondition: the classifier output still carries the quote'

    payload = redact_payload(row['result_payload'])
    stored = json.dumps(payload, ensure_ascii=False, separators=(',', ':'))

    assert QUOTE not in stored
    assert '"quote"' not in stored
    assert [text for text in _strings(payload) if MARKER in text] == []


def test_requirement_3_redaction_preserves_references_and_prose():
    review, row = _reviewed_row()
    payload = redact_payload(row['result_payload'])
    stored_finding = payload['findings'][0]
    source_finding = review['findings'][0]

    assert stored_finding['source_refs'] == [
        {'item_key': 'M2-04', 'answer_revision_id': 'rev-04', 'item_version_id': 'ver-04'},
        {'item_key': 'M2-05', 'answer_revision_id': 'rev-05', 'item_version_id': 'ver-05'},
    ]
    for field in ('rule_id', 'kind', 'observed_condition', 'counterargument',
                  'justification', 'next_action'):
        assert stored_finding[field] == source_finding[field]
    assert len(payload['findings']) == len(review['findings'])


def test_redaction_does_not_mutate_the_callers_payload():
    _, row = _reviewed_row()
    original = json.dumps(row['result_payload'], sort_keys=True)
    redact_payload(row['result_payload'])
    assert json.dumps(row['result_payload'], sort_keys=True) == original
    assert row['result_payload']['findings'][0]['source_refs'][0]['quote'] == QUOTE


def test_redaction_leaves_finding_prose_alone_even_when_it_echoes_the_answer():
    """The residual risk, stated as a test rather than a footnote.

    Model prose that restates a declaration is the finding's substance; stripping
    it would destroy the evidence and still leave a paraphrase. Only encrypting
    the column closes this, and that needs a migration.
    """
    payload = {'findings': [{'rule_id': 'R', 'kind': 'SOURCE_CONFLICT',
                             'source_refs': [{'item_key': 'M2-04', 'quote': QUOTE}],
                             'observed_condition': f'The answer says "{QUOTE}".'}]}
    redacted = redact_payload(payload)
    assert MARKER in redacted['findings'][0]['observed_condition']
    assert 'quote' not in redacted['findings'][0]['source_refs'][0]


def test_redaction_refuses_a_malformed_payload():
    with pytest.raises(WorkflowHeld, match='RESULT_PAYLOAD_SHAPE_INVALID'):
        redact_payload({'findings': ['not-a-mapping']})


def test_redaction_of_an_absent_payload_is_absent():
    assert redact_payload(None) is None
