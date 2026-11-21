"""No-database contract for the disabled protected M2 session binding."""
import hashlib
import hmac
from uuid import uuid4
import pytest

from sitewise.db.m2_identity_assertion import mint_m2_assertion


def test_assertion_uses_verified_uuid_bounded_lifetime_and_fresh_nonce():
    actor, key = uuid4(), 'ab' * 32
    first = mint_m2_assertion(actor, key, now=1000)
    second = mint_m2_assertion(actor, key, now=1000)
    identity, expiry, nonce, signature = first.split('|')
    assert identity == str(actor) and expiry == '1030' and len(nonce) == 32
    assert signature == hmac.new(bytes.fromhex(key), f'{identity}|{expiry}|{nonce}'.encode(), hashlib.sha256).hexdigest()
    assert first != second


@pytest.mark.parametrize('key', ['', 'ab'*31, 'x'*64, 'ab '*32])
def test_invalid_keys_fail_closed(key):
    with pytest.raises(ValueError): mint_m2_assertion(uuid4(), key)


def test_untyped_actor_refused():
    with pytest.raises(ValueError): mint_m2_assertion(str(uuid4()), 'ab'*32)
