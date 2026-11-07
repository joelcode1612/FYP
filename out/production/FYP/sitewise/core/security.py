"""Supabase access-token verification (infrastructure adapter).

Supabase projects with asymmetric JWT signing publish their public keys at
``/auth/v1/.well-known/jwks.json``. The verified project exposes a single
ES256 (EC P-256) signing key, so tokens are verified locally against the
JWKS - no network call, no shared secret.

Design notes
------------
* ``JWKSClient`` caches the key set for ``cache_seconds`` and force-refreshes
  when a token arrives with an unknown ``kid`` - this is how signing-key
  rotation is handled without restarts.
* ``SupabaseJWTVerifier.verify`` enforces: signature, an explicit allow-list
  of algorithms (ES256 only), issuer, audience, expiration, not-before and
  the presence of ``sub``. Tokens signed with ``none`` or HS256 are rejected
  by the algorithm allow-list before any key material is touched.
* The legacy symmetric fallback (``verify_via_userinfo``) validates a token
  against ``/auth/v1/user`` - used only when a project has no JWKS keys.
  It never touches or stores the project's JWT signing secret.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

import jwt

from sitewise.core.exceptions import AuthError, AuthUnavailableError

_ALLOWED_ALGORITHMS = {"ES256", "RS256", "PS256"}
_REQUIRED_CLAIMS = ("sub", "exp", "iat", "aud", "iss")


@dataclass(frozen=True)
class VerifiedToken:
    subject: str
    email: str | None
    email_verified: bool | None
    session_id: str | None
    claims: dict[str, Any]


class JWKSClient:
    """Fetches and caches the Supabase JWKS document."""

    def __init__(self, url: str, cache_seconds: int = 600, timeout: int = 10):
        self.url = url
        self.cache_seconds = cache_seconds
        self.timeout = timeout
        self._keys: dict[str, dict[str, Any]] = {}
        self._fetched_at: float | None = None

    def _fetch(self) -> dict[str, dict[str, Any]]:
        try:
            with urllib.request.urlopen(self.url, timeout=self.timeout) as response:
                document = json.load(response)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise AuthUnavailableError(
                "The authentication key service (JWKS) is unreachable."
            ) from exc
        keys = {
            key["kid"]: key
            for key in document.get("keys", [])
            if key.get("kid") and key.get("use", "sig") == "sig"
        }
        if not keys:
            # No asymmetric keys published: the project is either still on
            # legacy symmetric JWT signing or misconfigured. Fail closed with
            # an explicit message rather than guessing.
            raise AuthUnavailableError(
                "No asymmetric signing keys are published for this Supabase "
                "project. Enable asymmetric JWT signing, or switch the "
                "verifier to the /auth/v1/user fallback."
            )
        self._keys = keys
        self._fetched_at = time.monotonic()
        return keys

    def get_key(self, kid: str | None, *, force_refresh: bool = False) -> dict[str, Any]:
        """Return the JWK for ``kid``, refreshing the cache when required.

        Rotation handling: an unknown ``kid`` triggers exactly one forced
        refresh so newly rotated keys are picked up immediately, even when the
        cache has not expired yet.
        """
        if (
            force_refresh
            or self._fetched_at is None
            or time.monotonic() - self._fetched_at > self.cache_seconds
        ):
            keys = self._fetch()
            # Fail closed when the fetched key set is empty regardless of
            # where the fetch came from (network or test substitute).
            if not keys:
                raise AuthUnavailableError(
                    "No asymmetric signing keys are published for this Supabase "
                    "project. Enable asymmetric JWT signing, or switch the "
                    "verifier to the /auth/v1/user fallback."
                )
        key = self._keys.get(kid or "")
        if key is None and not force_refresh:
            key = self.get_key(kid, force_refresh=True)
        if key is None:
            raise AuthError("The token was signed with an unknown key.")
        return key


class SupabaseJWTVerifier:
    """Verifies Supabase access tokens against the project JWKS."""

    def __init__(
        self,
        *,
        jwks_url: str,
        issuer: str,
        audiences: list[str],
        cache_seconds: int = 600,
        leeway: int = 30,
        allowed_algorithms: set[str] | None = None,
    ):
        if not jwks_url:
            raise AuthUnavailableError(
                "SUPABASE_JWKS_URL is not configured; token verification is unavailable."
            )
        self.jwks = JWKSClient(jwks_url, cache_seconds=cache_seconds)
        self.issuer = issuer
        self.audiences = audiences
        self.leeway = leeway
        self.allowed_algorithms = allowed_algorithms or {"ES256"}

    def verify(self, token: str) -> VerifiedToken:
        try:
            header = jwt.get_unverified_header(token)
        except jwt.PyJWTError as exc:
            raise AuthError("The token is malformed.") from exc
        algorithm = header.get("alg")
        if algorithm not in self.allowed_algorithms:
            # Rejects "none", HS256 forgery attempts and any other algorithm
            # before any key lookup happens.
            raise AuthError("The token uses a disallowed signing algorithm.")
        jwk = self.jwks.get_key(header.get("kid"))
        signing_key = jwt.PyJWK.from_dict(jwk).key
        try:
            claims = jwt.decode(
                token,
                signing_key,
                algorithms=[algorithm],
                audience=self.audiences,
                issuer=self.issuer,
                leeway=self.leeway,
                options={"require": list(_REQUIRED_CLAIMS)},
            )
        except jwt.ExpiredSignatureError as exc:
            raise AuthError("The session has expired. Sign in again.") from exc
        except jwt.InvalidIssuerError as exc:
            raise AuthError("The token was issued by an unrecognised issuer.") from exc
        except jwt.InvalidAudienceError as exc:
            raise AuthError("The token audience is not accepted.") from exc
        except jwt.ImmatureSignatureError as exc:
            raise AuthError("The token is not yet valid.") from exc
        except jwt.MissingRequiredClaimError as exc:
            raise AuthError("The token is missing required claims.") from exc
        except jwt.InvalidSignatureError as exc:
            raise AuthError("The token signature is invalid.") from exc
        except jwt.PyJWTError as exc:
            raise AuthError("The token is invalid.") from exc

        return VerifiedToken(
            subject=claims["sub"],
            email=claims.get("email"),
            email_verified=claims.get("email_verified"),
            session_id=claims.get("session_id"),
            claims=claims,
        )


class SupabaseUserinfoVerifier:
    """Fallback verification for projects still on legacy symmetric signing.

    Validates the token by asking Supabase itself who it belongs to
    (``GET /auth/v1/user``). Slower than local verification and requires a
    network round-trip, but never needs the project's JWT signing secret.
    """

    def __init__(self, *, base_url: str, publishable_key: str, timeout: int = 10):
        self.userinfo_url = f"{base_url.rstrip('/')}/auth/v1/user"
        self.publishable_key = publishable_key
        self.timeout = timeout

    def verify(self, token: str) -> VerifiedToken:
        if not self.publishable_key:
            raise AuthUnavailableError(
                "SUPABASE_PUBLISHABLE_KEY is not configured; userinfo fallback is unavailable."
            )
        request = urllib.request.Request(
            self.userinfo_url,
            headers={"apikey": self.publishable_key, "Authorization": f"Bearer {token}"},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                user = json.load(response)
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                raise AuthError("Your session is invalid or expired.") from exc
            raise AuthUnavailableError(
                "The authentication service is temporarily unavailable."
            ) from exc
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise AuthUnavailableError(
                "The authentication service is temporarily unavailable."
            ) from exc
        user_id = user.get("id") or user.get("sub")
        if not user_id:
            raise AuthError("The authentication service returned an unusable identity.")
        return VerifiedToken(
            subject=user_id,
            email=user.get("email"),
            email_verified=user.get("email_confirmed_at") is not None,
            session_id=None,
            claims=user,
        )
