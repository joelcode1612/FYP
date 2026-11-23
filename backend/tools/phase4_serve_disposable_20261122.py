"""Serve the unified SiteWise app in a disposable, offline-auth configuration.

This is the browser-E2E counterpart of the in-process harness in
``phase2_gateBC_http_e2e_20261122.py``. It composes the **real** application —
same routers, same dependencies, same RLS, same governed workflow — and changes
exactly two things, both of which are already seams the project provides for
testing:

1. **Key source.** ``JWKSClient._fetch`` is bound to the local ES256 public key
   in ``backend/var/test-auth/es256-test.pem`` instead of the network. Signature
   verification still runs for real: ``SupabaseJWTVerifier.verify`` enforces the
   algorithm allow-list, issuer, audience, expiry, not-before and ``sub``.
2. **Identity profile.** ``get_admin_service`` is overridden with the project's
   own ``FakeSupabaseAdmin``, which declares ``strict_identity = False`` so the
   request-time sync keeps the local ``public.users`` path. This is the same
   double the governed backend E2E uses, not a new invention.

The issuer claim stays the production issuer, so ``iss`` validation is not
relaxed. The live Supabase project is never contacted.

Nothing here may point at ``Dss`` or ``Final_Location_Analysis``; the target is
asserted before the server binds.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
sys.path.insert(0, str(BACKEND / 'src'))
sys.path.insert(0, str(BACKEND))

KEY_PATH = BACKEND / 'var' / 'test-auth' / 'es256-test.pem'
KID = 'sitewise-disposable-test-key'
TARGET_DB = 'project1_workflow_tests'
TARGET_PORT = 5433


def _public_jwk() -> dict:
    import jwt
    from cryptography.hazmat.primitives import serialization
    key = serialization.load_pem_private_key(KEY_PATH.read_bytes(), password=None)
    coords = jwt.algorithms.ECAlgorithm.to_jwk(key.public_key(), as_dict=True)
    return {'kid': KID, 'kty': 'EC', 'alg': 'ES256', 'use': 'sig',
            'crv': 'P-256', 'x': coords['x'], 'y': coords['y']}


def _assert_environment() -> dict:
    """Refuse to serve unless every engine points at the disposable cluster."""
    from sqlalchemy import create_engine, text
    urls = {name: os.environ.get(name, '') for name in
            ('DATABASE_URL', 'M2_DATABASE_URL', 'PROJECT1_RUNTIME_DATABASE_URL')}
    seen = {}
    for name, url in urls.items():
        if TARGET_DB not in url or f':{TARGET_PORT}/' not in url:
            raise SystemExit(f'REFUSED: {name} is not {TARGET_DB}@{TARGET_PORT}')
        engine = create_engine(url)
        with engine.connect() as conn:
            db, port = conn.execute(text(
                'SELECT current_database(), inet_server_port()')).one()
        if db != TARGET_DB or port != TARGET_PORT:
            raise SystemExit(f'REFUSED: {name} resolves to {db}@{port}')
        seen[name] = {'database': db, 'port': port}
    return seen


def build_app():
    import jwt  # noqa: F401  (imported for the JWK helper)

    from sitewise.core.security import JWKSClient

    jwk = _public_jwk()

    def offline_fetch(self):
        self._keys = {KID: dict(jwk)}
        self._fetched_at = time.monotonic()
        return self._keys

    JWKSClient._fetch = offline_fetch
    import sitewise.dependencies as deps
    deps._verifier = None

    from sitewise.core.supabase_admin import get_admin_service
    from sitewise.main import app
    from tests.fakes import FakeSupabaseAdmin

    app.dependency_overrides[get_admin_service] = lambda: FakeSupabaseAdmin()
    return app


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8091)
    parser.add_argument('--host', default='127.0.0.1')
    args = parser.parse_args()

    engines = _assert_environment()
    app = build_app()

    import uvicorn
    print(json.dumps({
        'serving': f'http://{args.host}:{args.port}',
        'engines': engines,
        'issuer': os.environ.get('SUPABASE_URL', '') + '/auth/v1',
        'jwks': 'LOCAL KEY (offline_fetch)',
        'identity': 'FakeSupabaseAdmin(strict_identity=False)',
        'frontend': 'fyp_jaspr_web/build/jaspr',
    }, indent=1), flush=True)
    # Access logging is needed to attribute a write to a specific request. It
    # stays off by default so the log is not drowned in noise, but an operator
    # can raise it without editing this file.
    uvicorn.run(app, host=args.host, port=args.port,
                log_level=os.environ.get('LOG_LEVEL', 'warning').lower())
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
