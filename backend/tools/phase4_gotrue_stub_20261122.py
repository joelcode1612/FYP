"""Minimal GoTrue-compatible identity provider for the disposable browser E2E.

Why this exists
---------------
Priority 4 requires an *authenticated* browser journey. Two things are
forbidden: contacting the live Supabase project with borrowed credentials, and
injecting a fabricated session into the browser. What is allowed is standing up
a local identity provider that the browser genuinely signs in to, whose tokens
the backend genuinely verifies with a public key it genuinely fetches.

This stub implements just enough of the GoTrue HTTP surface for ``supabase-js``
to perform a password sign-in and keep a session:

    GET  /auth/v1/settings
    GET  /auth/v1/.well-known/jwks.json
    POST /auth/v1/token?grant_type=password
    POST /auth/v1/token?grant_type=refresh_token
    GET  /auth/v1/user
    POST /auth/v1/logout

Tokens are real ES256 JWTs signed with ``var/test-auth/es256-test.pem``. The
backend verifies them through its normal code path — signature, algorithm
allow-list, ``iss``, ``aud``, ``exp``, required claims — because the only thing
overridden is *where the JWKS bytes come from*, not whether verification runs.

Safety
------
* Binds to 127.0.0.1 only.
* Refuses to start unless ``SITEWISE_ALLOW_LOCAL_AUTH=disposable-e2e`` is set
  exactly, and unless every configured database resolves to a disposable
  database on a non-5432 port. The same guard the backend launcher uses.
* Lives in ``backend/tools/``. Nothing under ``sitewise`` imports it, so it
  cannot be reached from the application at all.
* Synthetic identities only. There are no real credentials here and nothing
  leaves the machine.

Usage::

    python tools/phase4_gotrue_stub_20261122.py --port 54329
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

BACKEND = Path(__file__).resolve().parents[1]
KEY_PATH = BACKEND / 'var' / 'test-auth' / 'es256-test.pem'

#: The key id MUST match the one the backend's offline JWKS publishes, otherwise
#: verification fails with "The token was signed with an unknown key". Imported
#: from the same module that mints the disposable tokens so there is exactly one
#: source of truth for the kid.
sys.path.insert(0, str(BACKEND))
from tools.phase4_local_auth_20261122 import KID  # noqa: E402

TARGET_DB = 'project1_workflow_tests'
TARGET_PORT = 5433
REQUIRED_FLAG = ('SITEWISE_ALLOW_LOCAL_AUTH', 'disposable-e2e')

#: PKCE authorization codes issued by ``/auth/v1/authorize`` and consumed once by
#: ``/auth/v1/token?grant_type=pkce``. In-memory and short-lived by design: the
#: stub has no session store and must not grow one.
PENDING_CODES: dict[str, dict] = {}
CODE_TTL_SECONDS = 300

#: Who the provider button signs in as when the client sends no ``login_hint``.
#: Overridden by ``--default-identity``.
DEFAULT_IDENTITY: str = ''

#: Password accepted for any auto-provisioned identity. Fixed and obvious: this
#: is a local stub, not an authentication system.
AUTO_PROVISION_PASSWORD = 'e2e-local-password'

#: Namespace for deriving a stable ``sub`` from an email that is not one of the
#: declared identities. Deterministic so the same email always maps to the same
#: user id across restarts, which keeps local profiles from multiplying.
AUTO_SUB_NAMESPACE = uuid.UUID('6f1c9a2e-3b47-4d18-9c55-8a0e2d7b41cc')

EMAIL_RE = re.compile(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')


def resolve_identity(email: str) -> dict | None:
    """Return the identity for ``email``, provisioning one if it is well-formed.

    Declared identities keep their fixed ``sub`` so the seeded assessment keeps
    its owner. Anything else gets a deterministic ``sub`` derived from the email,
    which is what lets a developer sign in with their own address instead of
    being locked to the two synthetic accounts.
    """
    key = email.strip().lower()
    if key in SYNTHETIC_USERS:
        return SYNTHETIC_USERS[key]
    if not EMAIL_RE.match(key):
        return None
    local = key.split('@', 1)[0]
    return {
        'id': str(uuid.uuid5(AUTO_SUB_NAMESPACE, key)),
        'password': AUTO_PROVISION_PASSWORD,
        'full_name': local.replace('.', ' ').title() or 'Local User',
        'role': 'entrepreneur',
        'auto_provisioned': True,
    }

#: Synthetic identities. The user ids and emails match the ones
#: ``phase4_stage3_journey_20261122.py`` seeds, so the browser signs in as the
#: actual owner of the seeded assessment rather than a different stranger.
SYNTHETIC_USERS = {
    'gatebc-e2e-b9e62014@example.invalid': {
        'id': 'b9e62014-b7bc-426e-a950-a95b25965639',
        'password': 'e2e-local-password',
        'full_name': 'E2E Owner',
        'role': 'entrepreneur',
    },
    'gatebc-e2e-c70a999a@example.invalid': {
        'id': 'c70a999a-50c6-4a31-8f7a-b914d0a5c641',
        'password': 'e2e-local-password',
        'full_name': 'E2E Intruder',
        'role': 'entrepreneur',
    },
}


def _guard() -> None:
    """Refuse to run outside an explicitly disposable environment."""
    flag, expected = REQUIRED_FLAG
    if os.environ.get(flag) != expected:
        raise SystemExit(
            f'REFUSED: set {flag}={expected} to acknowledge this is a local stub'
        )

    from sqlalchemy import create_engine, text

    for name in ('DATABASE_URL', 'M2_DATABASE_URL', 'PROJECT1_RUNTIME_DATABASE_URL'):
        url = os.environ.get(name, '').strip()
        if not url:
            continue
        engine = create_engine(url)
        try:
            with engine.connect() as conn:
                db, port = conn.execute(
                    text('SELECT current_database(), inet_server_port()')
                ).one()
        finally:
            engine.dispose()
        if db != TARGET_DB or int(port) != TARGET_PORT:
            raise SystemExit(f'REFUSED: {name} resolves to {db}@{port}, expected {TARGET_DB}@{TARGET_PORT}')


def _load_key():
    import jwt
    from cryptography.hazmat.primitives import serialization

    private = serialization.load_pem_private_key(KEY_PATH.read_bytes(), password=None)
    public_jwk = jwt.algorithms.ECAlgorithm.to_jwk(private.public_key(), as_dict=True)
    public_jwk.update({'kid': KID, 'alg': 'ES256', 'use': 'sig'})
    return private, public_jwk


def _user_payload(email: str, spec: dict) -> dict:
    now = datetime.now(timezone.utc).isoformat()
    return {
        'id': spec['id'],
        'aud': 'authenticated',
        'role': 'authenticated',
        'email': email,
        'email_confirmed_at': now,
        'confirmed_at': now,
        'last_sign_in_at': now,
        'created_at': now,
        'updated_at': now,
        'app_metadata': {'provider': 'email', 'providers': ['email']},
        'user_metadata': {'full_name': spec['full_name'], 'role': spec['role']},
        'identities': [],
    }


def _mint(private, issuer: str, email: str, spec: dict, ttl: int = 3600) -> dict:
    import jwt

    now = datetime.now(timezone.utc)
    session_id = str(uuid.uuid4())
    claims = {
        'sub': spec['id'],
        'email': email,
        'email_verified': True,
        'phone': '',
        'aud': 'authenticated',
        'iss': issuer,
        'role': 'authenticated',
        'iat': int(now.timestamp()),
        'exp': int((now + timedelta(seconds=ttl)).timestamp()),
        'session_id': session_id,
        'aal': 'aal1',
        'amr': [{'method': 'password', 'timestamp': int(now.timestamp())}],
        'app_metadata': {'provider': 'email', 'providers': ['email']},
        'user_metadata': {'full_name': spec['full_name'], 'role': spec['role']},
    }
    token = jwt.encode(claims, private, algorithm='ES256', headers={'kid': KID})
    return {
        'access_token': token,
        'token_type': 'bearer',
        'expires_in': ttl,
        'expires_at': int((now + timedelta(seconds=ttl)).timestamp()),
        'refresh_token': f'refresh-{session_id}',
        'user': _user_payload(email, spec),
    }


def _decode_unverified(token: str) -> dict:
    import jwt

    return jwt.decode(token, options={'verify_signature': False, 'verify_aud': False})


class Handler(BaseHTTPRequestHandler):
    server_version = 'SitewiseE2EGoTrue/1.0'
    protocol_version = 'HTTP/1.1'

    # injected by main()
    private_key = None
    public_jwk = None
    issuer = ''
    log_path: Path | None = None

    def log_message(self, fmt, *args):  # silence stderr noise
        pass

    def _record(self, status: int, note: str = '') -> None:
        if not self.log_path:
            return
        entry = {
            'at': datetime.now(timezone.utc).isoformat(),
            'method': self.command,
            'path': self.path,
            'status': status,
            'note': note,
        }
        with self.log_path.open('a', encoding='utf-8') as fh:
            fh.write(json.dumps(entry) + '\n')

    def _cors(self) -> None:
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'authorization, apikey, content-type, x-client-info, x-supabase-api-version')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')

    def _send(self, status: int, payload, note: str = '') -> None:
        body = json.dumps(payload).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)
        self._record(status, note)

    def _body(self) -> dict:
        length = int(self.headers.get('Content-Length') or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode('utf-8'))
        except Exception:  # noqa: BLE001 - a malformed body is a 400, not a crash
            return {}

    # -- routes ------------------------------------------------------------
    def do_OPTIONS(self):  # noqa: N802
        self.send_response(204)
        self._cors()
        self.send_header('Content-Length', '0')
        self.end_headers()
        self._record(204, 'preflight')

    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path.endswith('/.well-known/jwks.json'):
            return self._send(200, {'keys': [self.public_jwk]}, 'jwks')
        if parsed.path.endswith('/auth/v1/settings'):
            return self._send(200, {
                'external': {'email': True, 'phone': False},
                'disable_signup': False,
                'mailer_autoconfirm': True,
                'phone_autoconfirm': False,
                'sms_provider': '',
            }, 'settings')
        if parsed.path.endswith('/auth/v1/authorize'):
            return self._authorize(parsed)
        if parsed.path.endswith('/auth/v1/user'):
            return self._user()
        if parsed.path.endswith('/rest/v1/users'):
            return self._rest_users(parsed)
        return self._send(404, {'error': 'not_found', 'path': parsed.path})

    def _rest_users(self, parsed):
        """The authoritative identity row, served the way PostgREST serves it.

        The backend reads ``public.users`` through the Supabase client at request
        time and treats that row as the authoritative source for role, account
        status and email verification. Without this route the lookup 404s and
        every authenticated request fails with 503 — the app can mint a token but
        can never resolve who it belongs to.

        PostgREST semantics are reproduced exactly, because the client depends on
        them: a filter that matches nothing is ``200 []``, never 404. A 404 here
        means "no such table", and conflating the two is what made the failure
        look like a missing service rather than a missing row.

        Read-only and local: it serves only the synthetic identities this stub can
        mint a token for, so it cannot disclose an identity it did not issue.
        """
        query = parse_qs(parsed.query)
        wanted = None
        for raw in query.get('user_id', []):
            if raw.startswith('eq.'):
                wanted = raw[3:].strip().lower()
        rows = []
        for email, spec in SYNTHETIC_USERS.items():
            if wanted is not None and str(spec['id']).lower() != wanted:
                continue
            rows.append({
                'user_id': spec['id'],
                'email': email,
                'full_name': spec.get('full_name'),
                'phone_number': spec.get('phone_number'),
                'role': spec.get('role', 'entrepreneur'),
                'account_status': spec.get('account_status', 'active'),
                'email_verified': spec.get('email_verified', True),
            })
        limit = (query.get('limit') or [''])[0]
        if limit.isdigit():
            rows = rows[:int(limit)]
        return self._send(200, rows, 'rest_users')

    def do_POST(self):  # noqa: N802
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path.endswith('/auth/v1/token'):
            grant = (query.get('grant_type') or [''])[0]
            if grant == 'password':
                return self._password()
            if grant == 'refresh_token':
                return self._refresh()
            if grant == 'pkce':
                return self._pkce()
            return self._send(400, {'error': 'unsupported_grant_type', 'grant_type': grant})
        if parsed.path.endswith('/auth/v1/logout'):
            return self._send(204, {}, 'logout')
        return self._send(404, {'error': 'not_found', 'path': parsed.path})

    def _authorize(self, parsed):
        """Simulate the provider consent step and hand back a PKCE code.

        A real GoTrue bounces the browser to Google, Google asks a human to pick
        an account, and the browser returns to ``redirect_to`` with a ``code``.
        There is no Google here, so the "consent" is resolved immediately to a
        configured identity and the browser is redirected exactly as it would be.

        The identity is chosen by ``login_hint`` when the caller supplies one,
        otherwise the first synthetic user. This is a local stub: it cannot and
        does not authenticate a real Google account.
        """
        query = parse_qs(parsed.query)
        redirect_to = (query.get('redirect_to') or query.get('redirect_uri') or [''])[0]
        if not redirect_to:
            return self._send(400, {'error': 'redirect_to is required'}, 'authorize_no_redirect')

        hint = (query.get('login_hint') or [''])[0].strip().lower()
        # ``--default-identity`` lets the operator choose who the provider button
        # signs in as. Without it, the first declared identity is used so the
        # seeded assessment still has a reachable owner.
        email = hint or DEFAULT_IDENTITY or next(iter(SYNTHETIC_USERS))
        spec = resolve_identity(email)
        if not spec:
            return self._send(400, {'error': 'unknown identity', 'email': email},
                              'authorize_unknown_user')

        code = f'code-{uuid.uuid4().hex}'
        PENDING_CODES[code] = {
            'email': email,
            'challenge': (query.get('code_challenge') or [''])[0],
            'method': (query.get('code_challenge_method') or [''])[0] or 'plain',
            'created_at': time.time(),
        }
        separator = '&' if '?' in redirect_to else '?'
        location = f'{redirect_to}{separator}code={code}'
        self.send_response(302)
        self.send_header('Location', location)
        self._cors()
        self.send_header('Content-Length', '0')
        self.end_headers()
        self._record(302, f'authorize_redirect:{email}')

    def _pkce(self):
        body = self._body()
        code = str(body.get('auth_code') or body.get('code') or '')
        verifier = str(body.get('code_verifier') or '')
        entry = PENDING_CODES.pop(code, None)
        if not entry:
            return self._send(400, {'error': 'invalid_grant',
                                    'error_description': 'authorization code not recognised'}, 'pkce_fail')
        if entry['challenge']:
            if entry['method'].upper() == 'S256':
                digest = hashlib.sha256(verifier.encode('ascii')).digest()
                computed = base64.urlsafe_b64encode(digest).rstrip(b'=').decode('ascii')
                ok = computed == entry['challenge']
            else:
                ok = verifier == entry['challenge']
            if not ok:
                return self._send(400, {'error': 'invalid_grant',
                                        'error_description': 'code verifier mismatch'}, 'pkce_mismatch')
        spec = resolve_identity(entry['email'])
        if not spec:
            return self._send(400, {'error': 'invalid_grant',
                                    'error_description': 'identity no longer resolvable'}, 'pkce_unknown')
        return self._send(200, _mint(self.private_key, self.issuer, entry['email'], spec), 'pkce_ok')

    def _user(self):
        auth = self.headers.get('Authorization', '')
        token = auth[7:] if auth.lower().startswith('bearer ') else ''
        if not token:
            return self._send(401, {'error': 'no_authorization'})
        try:
            claims = _decode_unverified(token)
        except Exception:  # noqa: BLE001
            return self._send(401, {'error': 'bad_jwt'})
        email = str(claims.get('email', '')).lower()
        spec = SYNTHETIC_USERS.get(email)
        if not spec:
            return self._send(404, {'error': 'user_not_found'})
        return self._send(200, _user_payload(email, spec), 'user')

    def _password(self):
        body = self._body()
        email = str(body.get('email', '')).strip().lower()
        password = str(body.get('password', ''))
        spec = resolve_identity(email)
        if not spec or spec['password'] != password:
            return self._send(400, {
                'error': 'invalid_grant',
                'error_description': 'Invalid login credentials',
                'msg': 'Invalid login credentials',
            }, 'bad_password')
        note = 'password_ok_auto_provisioned' if spec.get('auto_provisioned') else 'password_ok'
        return self._send(200, _mint(self.private_key, self.issuer, email, spec), note)

    def _refresh(self):
        body = self._body()
        token = str(body.get('refresh_token', ''))
        auth = self.headers.get('Authorization', '')
        access = auth[7:] if auth.lower().startswith('bearer ') else ''
        email = ''
        for candidate in (access,):
            if not candidate:
                continue
            try:
                email = str(_decode_unverified(candidate).get('email', '')).lower()
            except Exception:  # noqa: BLE001
                email = ''
        if not email and token.startswith('refresh-'):
            # The stub keeps no session table; a refresh token identifies the
            # session id only. Recover the email from the request body when the
            # client sends it, otherwise refuse rather than guess an identity.
            email = str(body.get('email', '')).strip().lower()
        spec = resolve_identity(email)
        if not spec:
            return self._send(400, {'error': 'invalid_grant',
                                    'error_description': 'refresh token not recognised'}, 'refresh_fail')
        return self._send(200, _mint(self.private_key, self.issuer, email, spec), 'refresh_ok')


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=54329)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--log', default=str(BACKEND / 'var' / 'e2e' / 'gotrue_requests.jsonl'))
    parser.add_argument(
        '--default-identity', default='',
        help='Email the provider button signs in as when no login_hint is sent. '
             'Any well-formed email is accepted; declared identities keep their fixed sub.',
    )
    args = parser.parse_args()

    _guard()
    private, public_jwk = _load_key()

    global DEFAULT_IDENTITY
    DEFAULT_IDENTITY = args.default_identity.strip().lower()
    if DEFAULT_IDENTITY and not EMAIL_RE.match(DEFAULT_IDENTITY):
        raise SystemExit(f'--default-identity is not an email address: {DEFAULT_IDENTITY!r}')

    issuer = os.environ.get('SUPABASE_URL', f'http://{args.host}:{args.port}').rstrip('/') + '/auth/v1'
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text('', encoding='utf-8')

    Handler.private_key = private
    Handler.public_jwk = public_jwk
    Handler.issuer = issuer
    Handler.log_path = log_path

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(json.dumps({
        'serving': f'http://{args.host}:{args.port}/auth/v1',
        'issuer': issuer,
        'kid': KID,
        'declared_identities': sorted(SYNTHETIC_USERS),
        'auto_provision': 'any well-formed email, password e2e-local-password',
        'provider_button_default': DEFAULT_IDENTITY or next(iter(SYNTHETIC_USERS)),
        'log': str(log_path),
    }, indent=1), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
