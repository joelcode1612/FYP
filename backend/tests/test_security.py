"""JWT verification matrix (spec section 15 - authentication tests 6-12)."""

import time

import jwt
import pytest

from sitewise.core.exceptions import AuthError, AuthUnavailableError
from sitewise.core.security import SupabaseJWTVerifier

from .conftest import TEST_AUDIENCE, TEST_ISSUER, TEST_KID, make_token

PRIVATE_KEY_PEM = None  # keys are generated in conftest; verifier is patched at class level


@pytest.fixture()
def verifier():
    from sitewise.core.security import JWKSClient

    v = SupabaseJWTVerifier(
        jwks_url="https://jwks.test/keys",
        issuer=TEST_ISSUER,
        audiences=[TEST_AUDIENCE],
        cache_seconds=60,
        leeway=5,
    )
    return v


def test_valid_token_verifies(verifier):
    token = make_token()
    verified = verifier.verify(token)
    assert verified.email == "user@jwks-test.example"
    assert verified.email_verified is True
    assert verified.session_id
    assert verified.claims["aud"] == TEST_AUDIENCE


def test_expired_token_rejected(verifier):
    token = make_token(expires_in=-600)
    with pytest.raises(AuthError, match="expired"):
        verifier.verify(token)


def test_wrong_issuer_rejected(verifier):
    token = make_token(issuer="https://evil.example/auth/v1")
    with pytest.raises(AuthError, match="issuer"):
        verifier.verify(token)


def test_wrong_audience_rejected(verifier):
    token = make_token(audience="someone-else")
    with pytest.raises(AuthError, match="audience"):
        verifier.verify(token)


def test_unknown_kid_rejected(verifier):
    token = make_token(headers={"kid": "no-such-key"})
    with pytest.raises(AuthError, match="unknown key"):
        verifier.verify(token)


def test_hs256_forgery_rejected_by_algorithm_allowlist(verifier):
    # Signed with the attacker's own secret as HS256 - the classic confusion
    # attack. Must be rejected by the algorithm allow-list before any key use.
    token = jwt.encode(
        {"sub": "attacker", "aud": TEST_AUDIENCE, "iss": TEST_ISSUER,
         "exp": int(time.time()) + 600, "iat": int(time.time())},
        "attacker-secret",
        algorithm="HS256",
    )
    with pytest.raises(AuthError, match="disallowed signing algorithm"):
        verifier.verify(token)


def test_unsigned_token_rejected(verifier):
    token = jwt.encode(
        {"sub": "x", "aud": TEST_AUDIENCE, "iss": TEST_ISSUER},
        key=None,
        algorithm="none",
    )
    with pytest.raises(AuthError, match="disallowed signing algorithm"):
        verifier.verify(token)


def test_tampered_signature_rejected(verifier):
    from .conftest import _private_key

    other = ec_other_key()
    token = make_token(key=_private_key)
    # Re-sign the same payload with a different key: signature must fail.
    claims = jwt.decode(token, options={"verify_signature": False})
    forged = jwt.encode(claims, other, algorithm="ES256", headers={"kid": TEST_KID})
    with pytest.raises(AuthError):
        verifier.verify(forged)


def ec_other_key():
    from cryptography.hazmat.primitives.asymmetric import ec

    return ec.generate_private_key(ec.SECP256R1())


def test_missing_sub_claim_rejected(verifier):
    token = make_token(omit=("sub",))
    with pytest.raises(AuthError, match="required claims"):
        verifier.verify(token)


def test_missing_audience_claim_rejected(verifier):
    token = make_token(omit=("aud",))
    with pytest.raises(AuthError, match="required claims|audience"):
        verifier.verify(token)


def test_not_before_future_rejected(verifier):
    from datetime import datetime, timedelta, timezone

    token = make_token(not_before=datetime.now(timezone.utc) + timedelta(hours=1))
    with pytest.raises(AuthError, match="not yet valid"):
        verifier.verify(token)


def test_malformed_token_rejected(verifier):
    with pytest.raises(AuthError):
        verifier.verify("not-a-jwt")


def test_jwks_unreachable_is_503_not_fail_open(monkeypatch):
    import sitewise.core.security as sec

    def boom(self):
        raise AuthUnavailableError("The authentication key service (JWKS) is unreachable.")

    monkeypatch.setattr(sec.JWKSClient, "_fetch", boom)
    v = sec.SupabaseJWTVerifier(
        jwks_url="https://jwks.test/keys",
        issuer=TEST_ISSUER,
        audiences=[TEST_AUDIENCE],
    )
    with pytest.raises(AuthUnavailableError):
        v.verify(make_token())


def test_empty_jwks_fails_closed(monkeypatch):
    import sitewise.core.security as sec

    monkeypatch.setattr(sec.JWKSClient, "_fetch", lambda self: {})
    v = sec.SupabaseJWTVerifier(
        jwks_url="https://jwks.test/keys",
        issuer=TEST_ISSUER,
        audiences=[TEST_AUDIENCE],
    )
    with pytest.raises(AuthUnavailableError, match="No asymmetric signing keys"):
        v.verify(make_token())


def test_key_rotation_picked_up_on_unknown_kid(monkeypatch):
    """A token signed with a NEW rotated key must verify without restart.

    Simulates rotation: the key service serves only the OLD key on the first
    fetch; the token arrives signed with the NEW kid; the forced refresh on
    unknown kid picks up the published NEW key.
    """
    import sitewise.core.security as sec
    from cryptography.hazmat.primitives.asymmetric import ec

    new_key = ec.generate_private_key(ec.SECP256R1())
    new_kid = "rotated-kid"
    new_pub = jwt.algorithms.ECAlgorithm.to_jwk(new_key.public_key(), as_dict=True)
    new_pub.update({"kid": new_kid, "kty": "EC", "alg": "ES256", "use": "sig"})
    old_key = ec.generate_private_key(ec.SECP256R1())
    old_pub = jwt.algorithms.ECAlgorithm.to_jwk(old_key.public_key(), as_dict=True)
    old_pub.update({"kid": TEST_KID, "kty": "EC", "alg": "ES256", "use": "sig"})

    calls = {"n": 0}

    def fetch(self):
        calls["n"] += 1
        self._keys = {new_kid: new_pub} if calls["n"] >= 2 else {TEST_KID: old_pub}
        self._fetched_at = time.monotonic()
        return self._keys

    monkeypatch.setattr(sec.JWKSClient, "_fetch", fetch)
    v = sec.SupabaseJWTVerifier(
        jwks_url="https://jwks.test/keys",
        issuer=TEST_ISSUER,
        audiences=[TEST_AUDIENCE],
    )
    token = make_token(key=new_key, headers={"kid": new_kid})
    assert calls["n"] == 0
    verified = v.verify(token)  # fetch#1 (old set) -> miss -> fetch#2 (new set)
    assert calls["n"] == 2
    assert verified.email == "user@jwks-test.example"
