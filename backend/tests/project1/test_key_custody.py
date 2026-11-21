"""Key custody and crypto-shredding, without a database.

`bdj_raw_responses` is append-only, so the only way to honour
`retention_until` is to destroy the key that makes the row readable. These
tests pin the three properties that makes the mechanism trustworthy:

* a live key round-trips;
* a destroyed key, a wrong key and a missing key are all refused with a fixed
  code that contains no key material;
* destroying one record's key leaves every other record readable.

The last one is the hard requirement. A shared key would make one expiry a
table-wide blackout, which is exactly the argument that would be used to keep
keys forever.
"""
import os

import pytest

from sitewise.project1.key_custody import (KeyCustodyError, KeyUnavailable,
                                           LocalKeyCustody, CustodyCipher,
                                           STATE_DESTROYED, STATE_LIVE,
                                           STATE_MISSING, OUTCOME_DESTROYED,
                                           OUTCOME_ALREADY_DESTROYED)


@pytest.fixture
def custody(tmp_path):
    return LocalKeyCustody(tmp_path / 'custody')


@pytest.fixture
def cipher(custody):
    return CustodyCipher(custody)


def test_live_key_round_trips(custody, cipher):
    plaintext = b'{"issues":[]}'
    ciphertext, key_id = cipher.encrypt(plaintext)
    assert ciphertext != plaintext
    assert custody.state(key_id) == STATE_LIVE
    assert cipher.decrypt(ciphertext, key_id) == plaintext


def test_round_trip_survives_a_new_custody_instance(tmp_path):
    """Key material is on disk, not in the object: a restart must still decrypt."""
    cipher = CustodyCipher(LocalKeyCustody(tmp_path / 'custody'))
    ciphertext, key_id = cipher.encrypt(b'raw model output')
    reopened = CustodyCipher(LocalKeyCustody(tmp_path / 'custody'))
    assert reopened.decrypt(ciphertext, key_id) == b'raw model output'


def test_encrypt_uses_a_distinct_key_per_record(cipher, custody):
    _, first = cipher.encrypt(b'one')
    _, second = cipher.encrypt(b'two')
    assert first != second
    assert custody.get(first) != custody.get(second)


def test_wrong_key_is_refused_without_leaking_material(custody, cipher):
    ciphertext, key_a = cipher.encrypt(b'record A plaintext')
    _, key_b = cipher.encrypt(b'record B plaintext')
    material = custody.get(key_b)
    with pytest.raises(KeyUnavailable) as caught:
        cipher.decrypt(ciphertext, key_b)
    assert str(caught.value) == 'KEY_DECRYPTION_REFUSED'
    assert material not in str(caught.value).encode('utf-8')
    assert material.decode('ascii') not in repr(caught.value)


def test_destroyed_key_is_refused_and_reported_as_destroyed(custody, cipher):
    ciphertext, key_id = cipher.encrypt(b'record A plaintext')
    receipt = custody.destroy(key_id)
    assert receipt.outcome == OUTCOME_DESTROYED
    assert custody.state(key_id) == STATE_DESTROYED
    assert custody.get(key_id) is None
    with pytest.raises(KeyUnavailable) as caught:
        cipher.decrypt(ciphertext, key_id)
    assert str(caught.value) == 'KEY_DESTROYED'


def test_missing_key_is_distinguishable_from_a_destroyed_one(cipher):
    ciphertext, key_id = cipher.encrypt(b'x')
    # Simulate loss rather than retention: the ciphertext names a key that was
    # never provisioned here.
    with pytest.raises(KeyUnavailable) as caught:
        cipher.decrypt(ciphertext, 'rec-never-provisioned')
    assert str(caught.value) == 'KEY_UNAVAILABLE'


def test_destroying_one_key_leaves_the_other_records_readable(custody, cipher):
    """Key isolation: three independent records, one expiry."""
    records = {}
    for name in ('A', 'B', 'C'):
        plaintext = f'record {name} plaintext'.encode()
        ciphertext, key_id = cipher.encrypt(plaintext)
        records[name] = (plaintext, ciphertext, key_id)

    custody.destroy(records['A'][2])

    with pytest.raises(KeyUnavailable):
        cipher.decrypt(records['A'][1], records['A'][2])
    for name in ('B', 'C'):
        plaintext, ciphertext, key_id = records[name]
        assert cipher.decrypt(ciphertext, key_id) == plaintext
        assert custody.state(key_id) == STATE_LIVE


def test_ciphertext_is_byte_identical_after_destruction(custody, cipher):
    ciphertext, key_id = cipher.encrypt(b'evidence span that must survive')
    before = bytes(ciphertext)
    custody.destroy(key_id)
    assert bytes(ciphertext) == before


def test_destroy_is_idempotent(custody):
    key_id = 'rec-idempotent'
    custody.provision(key_id)
    first = custody.destroy(key_id)
    second = custody.destroy(key_id)
    assert first.outcome == OUTCOME_DESTROYED
    assert second.outcome == OUTCOME_ALREADY_DESTROYED
    assert second.destroyed_at == first.destroyed_at
    assert custody.state(key_id) == STATE_DESTROYED


def test_destroying_an_absent_key_records_a_tombstone(custody):
    receipt = custody.destroy('rec-never-provisioned')
    assert receipt.outcome == 'KEY_MISSING'
    assert custody.state('rec-never-provisioned') == STATE_DESTROYED


def test_provision_is_idempotent_while_live(custody):
    key_id = 'rec-stable'
    assert custody.provision(key_id) == custody.provision(key_id)


def test_a_destroyed_key_cannot_be_reprovisioned(custody):
    key_id = 'rec-retired'
    custody.provision(key_id)
    custody.destroy(key_id)
    with pytest.raises(KeyCustodyError) as caught:
        custody.provision(key_id)
    assert str(caught.value) == 'KEY_RETIRED'
    assert custody.state(key_id) == STATE_DESTROYED


@pytest.mark.parametrize('key_id', ['', '../escape', 'a/b', 'x' * 65,
                                    'rec id', 'rec\x00id'])
def test_key_id_is_validated_before_it_becomes_a_path(custody, key_id):
    with pytest.raises(KeyCustodyError) as caught:
        custody.provision(key_id)
    assert str(caught.value) == 'KEY_ID_INVALID'


def test_key_material_is_not_world_readable(custody):
    key_id = 'rec-permissions'
    custody.provision(key_id)
    path = custody.root / 'keys' / f'{key_id}.key'
    if os.name == 'nt':  # chmod only toggles the read-only bit on Windows
        assert path.exists()
    else:
        assert path.stat().st_mode & 0o077 == 0


def test_state_of_an_unknown_key_is_missing(custody):
    assert custody.state('rec-unknown') == STATE_MISSING


def test_corrupt_key_material_is_refused_without_echoing_it(custody, cipher):
    key_id = 'rec-corrupt'
    custody.provision(key_id)
    (custody.root / 'keys' / f'{key_id}.key').write_bytes(b'not-a-fernet-key')
    with pytest.raises(KeyCustodyError) as caught:
        cipher.decrypt(b'whatever', key_id)
    assert str(caught.value) == 'KEY_MATERIAL_INVALID'
    assert 'not-a-fernet-key' not in str(caught.value)
