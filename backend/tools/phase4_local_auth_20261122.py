"""Disposable ES256 auth environment for browser E2E.

Why this exists
---------------
The browser and the backend already agree on *who signs tokens*: both point at
the same Supabase project. The real gap is the **identity space** — a token from
the live project carries a Supabase user id that does not exist in the
disposable database, and obtaining one means writing to a live third-party
project, which is not disposable.

So this harness substitutes the *key source*, not the verification. It:

* generates a local EC P-256 keypair (never leaves `backend/var/test-auth/`);
* serves the matching JWKS document over HTTP;
* mints ES256 tokens whose ``sub`` is a synthetic local user id.

The backend still performs real ES256 signature verification against a real
JWKS document, and still enforces ``iss``, ``aud``, ``exp``, ``nbf`` and the
presence of ``sub``. Nothing in `sitewise.core.security` is bypassed, mocked or
weakened — only the issuer URL and the key material are pointed at this
loopback process, via environment variables that exist for exactly this purpose.

The live Supabase project is never contacted.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
import jwt

ROOT = Path(__file__).resolve().parents[2]
KEY_DIR = ROOT / 'backend' / 'var' / 'test-auth'
KEY_PATH = KEY_DIR / 'es256-test.pem'
KID = 'sitewise-disposable-test-key'


def _b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def _load_or_create_key() -> ec.EllipticCurvePrivateKey:
    KEY_DIR.mkdir(parents=True, exist_ok=True)
    if KEY_PATH.exists():
        return serialization.load_pem_private_key(KEY_PATH.read_bytes(), password=None)
    key = ec.generate_private_key(ec.SECP256R1())
    KEY_PATH.write_bytes(key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()))
    return key


def _jwk(key: ec.EllipticCurvePrivateKey) -> dict:
    numbers = key.public_key().public_numbers()
    size = 32
    return {
        'kty': 'EC', 'crv': 'P-256', 'alg': 'ES256', 'use': 'sig', 'kid': KID,
        'x': _b64u(numbers.x.to_bytes(size, 'big')),
        'y': _b64u(numbers.y.to_bytes(size, 'big')),
    }


def mint(key, *, sub: str, issuer: str, audience: str = 'authenticated',
         ttl_seconds: int = 3600, email: str | None = None) -> str:
    now = int(time.time())
    claims = {
        'sub': sub, 'aud': audience, 'iss': issuer,
        'iat': now, 'exp': now + ttl_seconds, 'role': 'authenticated',
        'session_id': 'disposable-e2e-session',
    }
    if email:
        claims['email'] = email
        claims['email_verified'] = True
    return jwt.encode(claims, key, algorithm='ES256', headers={'kid': KID})


class _Handler(BaseHTTPRequestHandler):
    jwks: dict = {}

    def do_GET(self):  # noqa: N802 - http.server contract
        if self.path.rstrip('/').endswith('/.well-known/jwks.json'):
            body = json.dumps(self.jwks).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_args):  # silence per-request logging
        return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8123)
    parser.add_argument('--sub', required=True, help='synthetic local user id')
    parser.add_argument('--email', default=None)
    parser.add_argument('--ttl', type=int, default=3600)
    parser.add_argument('--mint-only', action='store_true')
    parser.add_argument(
        '--issuer', default=None,
        help='Token issuer. Defaults to this loopback JWKS host. Pass the '
             'production issuer to keep `iss` identical while only the key '
             'material is local, which is what the backend E2E harness does.')
    args = parser.parse_args()

    key = _load_or_create_key()
    jwk = _jwk(key)
    issuer = args.issuer or f'http://127.0.0.1:{args.port}/auth/v1'
    token = mint(key, sub=args.sub, issuer=issuer, ttl_seconds=args.ttl,
                 email=args.email)

    payload = {
        'token': token,
        'issuer': issuer,
        'audience': 'authenticated',
        'sub': args.sub,
        'jwks_url': f'{issuer}/.well-known/jwks.json',
        'kid': KID,
        'key_path': str(KEY_PATH),
        'expires_in': args.ttl,
    }
    if args.mint_only:
        print(json.dumps(payload, indent=1))
        return 0

    _Handler.jwks = {'keys': [jwk]}
    server = HTTPServer(('127.0.0.1', args.port), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print(json.dumps(payload, indent=1), flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        return 0


if __name__ == '__main__':
    raise SystemExit(main())
