"""The versioned payload envelope, without a database.

`bdj_results.result_payload` is jsonb and cannot change shape in the schema, so
the protection is a shape inside the column. These tests pin the properties that
make that safe:

* a sealed payload round-trips and is distinguishable from a legacy plaintext
  payload by its marker alone;
* a payload with no marker is returned unchanged -- old rows keep reading;
* an envelope with no custody, an unknown version, a tampered token or a
  mismatched digest is refused rather than projected as "no findings";
* the payload key is namespaced and deterministic, and `run_retention()` -- which
  selects `bdj_raw_responses.key_id` -- never destroys it.

The persist/read path against the clone is covered in `test_result_store.py`.
"""
import json
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.key_custody import (PAYLOAD_KEY_PREFIX, STATE_DESTROYED,
                                           STATE_LIVE, CustodyCipher,
                                           LocalKeyCustody, payload_cipher,
                                           payload_key_id)
from sitewise.project1.result_store import (PAYLOAD_ENVELOPE_FIELDS,
                                            PAYLOAD_ENVELOPE_MARKER,
                                            PAYLOAD_ENVELOPE_V1, _open_payload,
                                            _payload_for_read, _project_payload,
                                            _seal_payload)
from sitewise.project1.retention import ExpiredRecord, run_retention

PROSE = 'PROSE-SENTINEL-4b81de'
QUOTE = 'MARKER-QUOTE-4b81de'
PAYLOAD = {'findings': [{
    'rule_id': 'SERVICE_FORMAT_EXPLICIT_CONFLICT', 'kind': 'SOURCE_CONFLICT',
    'observed_condition': f'The answer restates {PROSE} in prose.',
    'counterargument': 'Synthetic counterargument.',
    'justification': 'Synthetic justification.',
    'next_action': 'Synthetic next action.',
    'source_refs': [{'item_key': 'M2-04', 'answer_revision_id': 'r1',
                     'item_version_id': 'v1'}],
}]}


@pytest.fixture
def custody(tmp_path):
    return LocalKeyCustody(tmp_path / 'custody')


def test_sealed_payload_round_trips_and_carries_the_version_marker(custody):
    result_id = uuid.uuid4()
    envelope = _seal_payload(payload_cipher(custody, result_id), PAYLOAD)

    assert set(envelope) == PAYLOAD_ENVELOPE_FIELDS
    assert envelope[PAYLOAD_ENVELOPE_MARKER] == PAYLOAD_ENVELOPE_V1
    assert envelope['key_id'] == payload_key_id(result_id)
    assert envelope['plaintext_bytes'] > 0
    assert PROSE not in json.dumps(envelope)

    assert _open_payload(envelope, CustodyCipher(custody)) == PAYLOAD


def test_a_payload_without_the_marker_is_legacy_and_returned_unchanged(custody):
    """No marker means a row written before the envelope existed."""
    assert _payload_for_read(PAYLOAD, CustodyCipher(custody)) is PAYLOAD
    assert _payload_for_read(PAYLOAD, None) is PAYLOAD
    assert _payload_for_read(None, None) is None


def test_an_envelope_without_custody_is_refused_not_emptied(custody):
    envelope = _seal_payload(payload_cipher(custody, uuid.uuid4()), PAYLOAD)
    with pytest.raises(WorkflowHeld, match='RESULT_PAYLOAD_CIPHER_REQUIRED'):
        _payload_for_read(envelope, None)
    with pytest.raises(WorkflowHeld, match='RESULT_PAYLOAD_CIPHER_REQUIRED'):
        _project_payload(envelope, None)


def test_an_unknown_envelope_version_is_refused(custody):
    envelope = _seal_payload(payload_cipher(custody, uuid.uuid4()), PAYLOAD)
    envelope[PAYLOAD_ENVELOPE_MARKER] = 'v2'
    with pytest.raises(WorkflowHeld, match='RESULT_PAYLOAD_ENVELOPE_UNSUPPORTED'):
        _payload_for_read(envelope, CustodyCipher(custody))


def test_a_tampered_ciphertext_is_refused_without_leaking_key_material(custody):
    result_id = uuid.uuid4()
    envelope = _seal_payload(payload_cipher(custody, result_id), PAYLOAD)
    material = custody.get(payload_key_id(result_id))
    # Flip one character in the middle: same length, same padding, so the token
    # still decodes and Fernet's HMAC -- not base64 -- is what refuses it.
    raw = envelope['ciphertext']
    middle = len(raw) // 2
    envelope['ciphertext'] = (raw[:middle] + ('A' if raw[middle] != 'A' else 'B')
                              + raw[middle + 1:])

    with pytest.raises(WorkflowHeld) as caught:
        _open_payload(envelope, CustodyCipher(custody))
    assert str(caught.value) == 'RESULT_PAYLOAD_UNAVAILABLE'
    assert material.decode('ascii') not in repr(caught.value)
    assert envelope['ciphertext'] not in repr(caught.value)


def test_a_digest_mismatch_is_refused(custody):
    envelope = _seal_payload(payload_cipher(custody, uuid.uuid4()), PAYLOAD)
    envelope['plaintext_digest'] = '0' * 64
    with pytest.raises(WorkflowHeld, match='RESULT_PAYLOAD_INTEGRITY_FAILED'):
        _open_payload(envelope, CustodyCipher(custody))


def test_a_byte_count_mismatch_is_refused(custody):
    envelope = _seal_payload(payload_cipher(custody, uuid.uuid4()), PAYLOAD)
    envelope['plaintext_bytes'] = envelope['plaintext_bytes'] + 1
    with pytest.raises(WorkflowHeld, match='RESULT_PAYLOAD_INTEGRITY_FAILED'):
        _open_payload(envelope, CustodyCipher(custody))


@pytest.mark.parametrize('field', ['key_id', 'ciphertext', 'plaintext_digest',
                                   'plaintext_bytes'])
def test_a_missing_envelope_field_is_refused(custody, field):
    envelope = _seal_payload(payload_cipher(custody, uuid.uuid4()), PAYLOAD)
    del envelope[field]
    with pytest.raises(WorkflowHeld, match='RESULT_PAYLOAD_ENVELOPE_INVALID'):
        _open_payload(envelope, CustodyCipher(custody))


def test_an_extra_envelope_field_is_refused(custody):
    envelope = _seal_payload(payload_cipher(custody, uuid.uuid4()), PAYLOAD)
    envelope['plaintext'] = 'sneaked in'
    with pytest.raises(WorkflowHeld, match='RESULT_PAYLOAD_ENVELOPE_INVALID'):
        _open_payload(envelope, CustodyCipher(custody))


def test_the_payload_key_is_namespaced_and_deterministic():
    result_id = uuid.uuid4()
    assert payload_key_id(result_id) == payload_key_id(result_id)
    assert payload_key_id(result_id).startswith(PAYLOAD_KEY_PREFIX)
    assert not payload_key_id(result_id).startswith('rec-')
    assert payload_key_id(uuid.uuid4()) != payload_key_id(result_id)
    # Short enough for the 1..64 key-id contract that custody enforces.
    assert len(payload_key_id(result_id)) <= 64


def test_destroying_one_payload_key_leaves_the_other_results_readable(custody):
    first, second = uuid.uuid4(), uuid.uuid4()
    envelopes = {rid: _seal_payload(payload_cipher(custody, rid), PAYLOAD)
                 for rid in (first, second)}

    custody.destroy(payload_key_id(first))

    with pytest.raises(WorkflowHeld, match='RESULT_PAYLOAD_UNAVAILABLE'):
        _open_payload(envelopes[first], CustodyCipher(custody))
    assert _open_payload(envelopes[second], CustodyCipher(custody)) == PAYLOAD
    assert custody.state(payload_key_id(second)) == STATE_LIVE


def test_run_retention_never_selects_or_destroys_a_payload_key(custody, tmp_path):
    """The lifecycle proof: retention names raw-response keys only.

    The fake engine returns the raw record that `select_expired()` would have
    selected. The payload key is live in the same custody directory and must
    stay live, because `bdj_results` has no retention deadline to enforce.
    """
    result_id = uuid.uuid4()
    _seal_payload(payload_cipher(custody, result_id), PAYLOAD)
    payload_key = payload_key_id(result_id)
    raw_key = 'rec-raw-response-key'

    class FakeResult:
        def mappings(self):
            return self

        def all(self):
            return [{'result_id': 'raw-result', 'key_id': raw_key}]

    class FakeConnection:
        statement = ''

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def execute(self, statement, params):
            type(self).statement = str(statement)
            return FakeResult()

    class FakeEngine:
        def connect(self):
            return FakeConnection()

    now = datetime.now(timezone.utc) + timedelta(days=3650)
    run_retention(FakeEngine(), custody,
                  ledger_path=tmp_path / 'receipts.jsonl', now=now)

    assert 'bdj_raw_responses' in FakeConnection.statement
    assert custody.state(payload_key) == STATE_LIVE
    # The raw key was named, and it is the one that was destroyed.
    assert custody.state(raw_key) == STATE_DESTROYED


def test_the_projection_still_excludes_the_payload_and_the_quote(custody):
    """Decrypting must not widen the projection: same allow-list as before."""
    envelope = _seal_payload(payload_cipher(custody, uuid.uuid4()),
                             {**PAYLOAD, 'findings': [
                                 {**PAYLOAD['findings'][0],
                                  'source_refs': [{**PAYLOAD['findings'][0]
                                                   ['source_refs'][0],
                                                   'quote': QUOTE}]}]})
    findings, references = _project_payload(envelope, CustodyCipher(custody))

    assert set(findings[0]) == {'rule_id', 'kind', 'observed_condition',
                                'counterargument', 'justification', 'next_action'}
    assert references == [{'item_key': 'M2-04', 'answer_revision_id': 'r1',
                           'item_version_id': 'v1'}]
    assert 'quote' not in json.dumps(references)
    assert QUOTE not in json.dumps(references)
    # The prose is the finding's substance and survives the round trip.
    assert PROSE in json.dumps(findings)
