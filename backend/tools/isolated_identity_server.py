"""Isolated identity infrastructure for the GATE 5 end-to-end run.

Why this exists
---------------
The previous authenticated browser probe minted a real token through Supabase and
wrote a profile row into ``Final_Location_Analysis@5432``. The lesson is not "be
careful with Supabase"; it is that a test should not need a production identity
provider at all.

This module runs a *local* OpenID-style key service:

* it generates an EC P-256 key pair in memory at start-up (never written to disk,
  never reused across runs);
* it publishes the public half at ``/auth/v1/.well-known/jwks.json``;
* it mints ES256 access tokens with the issuer and audience the backend verifies.

The backend's own verifier does all the work — signature, algorithm allow-list,
issuer, audience, expiry, ``sub`` — so nothing about verification is weakened.
The only thing that changes is *who signed*: a key that exists for one test run.

What this deliberately does not do
----------------------------------
* no ``none`` or HS256 tokens, and no unsigned tokens;
* no bypass flag, no "trust this token" path, no monkeypatching of the verifier;
* no contact with Supabase, and no reading of its secrets;
* no persistent private key, so a token minted here cannot outlive the process.
"""
from __future__ import annotations

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

import jwt
from cryptography.hazmat.primitives.asymmetric import ec
from jwt.algorithms import ECAlgorithm

#: The audience the backend verifies. Matches ``supabase_jwt_audiences``.
AUDIENCE = 'authenticated'
#: How long a minted token stays valid. Short on purpose.
TOKEN_TTL_SECONDS = 900


class IsolatedIdentity:
    """A local ES256 signing key plus the tokens it issues."""

    def __init__(self, *, host: str = '127.0.0.1', port: int = 0):
        self._private_key = ec.generate_private_key(ec.SECP256R1())
        self._kid = 'isolated-test-key-1'
        self.host = host
        self.port = port
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    # -- key material ----------------------------------------------------
    @property
    def issuer(self) -> str:
        return f'http://{self.host}:{self.port}/auth/v1'

    @property
    def jwks_url(self) -> str:
        return f'{self.issuer}/.well-known/jwks.json'

    def jwk(self) -> dict:
        public = ECAlgorithm.to_jwk(self._private_key.public_key(), as_dict=True)
        public.update({'kid': self._kid, 'use': 'sig', 'alg': 'ES256'})
        return public

    def jwks_document(self) -> dict:
        return {'keys': [self.jwk()]}

    # -- tokens ----------------------------------------------------------
    def mint(self, *, subject: str, email: str | None = None,
             ttl: int = TOKEN_TTL_SECONDS, audience: str = AUDIENCE,
             issuer: str | None = None, extra: dict | None = None) -> str:
        now = int(time.time())
        claims = {
            'sub': subject,
            'aud': audience,
            'iss': issuer or self.issuer,
            'iat': now,
            'exp': now + ttl,
            'role': 'authenticated',
            'email': email or f'{subject}@isolated.test',
            'email_verified': True,
            'session_id': f'isolated-session-{subject}',
        }
        if extra:
            claims.update(extra)
        return jwt.encode(claims, self._private_key, algorithm='ES256',
                          headers={'kid': self._kid})

    def mint_tampered(self, *, subject: str) -> str:
        """A token with a valid shape but a broken signature.

        Used to prove the verifier rejects it, rather than to test a happy path.
        The last four characters of the signature are replaced.
        """
        token = self.mint(subject=subject)
        head, payload, signature = token.split('.')
        broken = signature[:-4] + ('AAAA' if signature[-4:] != 'AAAA' else 'BBBB')
        return f'{head}.{payload}.{broken}'

    # -- HTTP ------------------------------------------------------------
    def _handler(self):
        identity = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 - http.server API
                path = urlparse(self.path).path
                if path.endswith('/.well-known/jwks.json'):
                    body = json.dumps(identity.jwks_document()).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if path.endswith('/health'):
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/plain')
                    self.end_headers()
                    self.wfile.write(b'ok')
                    return
                self.send_response(404)
                self.end_headers()

            def log_message(self, *args):  # silence per-request logging
                return

        return Handler

    def start(self) -> 'IsolatedIdentity':
        self._server = ThreadingHTTPServer((self.host, self.port), self._handler())
        self.port = self._server.server_address[1]
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        return self

    def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5)

    def env(self) -> dict[str, str]:
        """The environment the backend needs to verify tokens from this issuer."""
        return {
            'SUPABASE_URL': f'http://{self.host}:{self.port}',
            'SUPABASE_JWKS_URL': self.jwks_url,
            'SUPABASE_JWT_AUDIENCES': AUDIENCE,
        }

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()
        return False


if __name__ == '__main__':  # manual use: print the env and a token
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--subject', default='00000000-0000-4000-8000-000000000001')
    args = parser.parse_args()
    with IsolatedIdentity(port=args.port) as identity:
        print(json.dumps(identity.env(), indent=2))
        print(identity.mint(subject=args.subject))
        print('serving; Ctrl-C to stop', flush=True)
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
