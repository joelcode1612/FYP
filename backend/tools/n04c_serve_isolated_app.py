"""Serve the real governed app for the N04-C application-path gate.

The process environment is adopted from backend/var/e2e/app.env, the same file
the operator scripts read. It refuses to bind unless every engine resolves to
project1_workflow_tests@5433. Nothing here enables the provider or changes a
budget; those values must already be present in the deployment environment.
"""
from __future__ import annotations

import os
import re
import socket
import sys
from pathlib import Path
from urllib.parse import urlparse

BACKEND = Path(__file__).resolve().parents[1]
ENV_FILE = BACKEND / 'var' / 'e2e' / 'app.env'
sys.path.insert(0, str(BACKEND / 'src'))
sys.path.insert(0, str(BACKEND))


def load_environment(path: Path) -> None:
    if not path.is_file():
        raise SystemExit(f'REFUSED: configuration not found: {path}')
    pattern = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$')
    for raw in path.read_text(encoding='utf-8', errors='replace').splitlines():
        match = pattern.match(raw.strip())
        if match is None:
            continue
        key, value = match.groups()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
            value = value[1:-1]
        os.environ[key] = value


def _proxy_is_reachable(value: str) -> bool:
    """A dead local proxy must not silently become the provider transport."""
    parsed = urlparse(value)
    host = parsed.hostname
    if host not in {'127.0.0.1', 'localhost', '::1'}:
        return True
    port = parsed.port or (443 if parsed.scheme == 'https' else 80)
    probe = socket.socket()
    probe.settimeout(0.75)
    try:
        probe.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def _drop_unreachable_proxies() -> None:
    """Refuse to inherit a stale proxy from the host environment.

    ``httpx`` trusts ``HTTP(S)_PROXY`` by default. The isolated launcher used to
    inherit a dead ``127.0.0.1:58185`` and every provider call failed as
    ``ConnectError`` before an HTTP status existed. Dropping a *provably
    unreachable local* proxy is a transport correction, not a provider bypass;
    the event is printed so it cannot be mistaken for a silent success.
    """
    for key in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
                'http_proxy', 'https_proxy', 'all_proxy'):
        value = os.environ.get(key)
        if value and not _proxy_is_reachable(value):
            print(f'DROPPING_UNREACHABLE_PROXY {key}={value}', flush=True)
            os.environ.pop(key, None)


def main() -> int:
    load_environment(ENV_FILE)
    _drop_unreachable_proxies()

    from tools.phase4_serve_disposable_20261122 import build_app, _assert_environment
    engines = _assert_environment()

    import uvicorn
    print('N04-C isolated app starting on 127.0.0.1:8092', flush=True)
    print(f'engines={engines}', flush=True)
    print(f'TOKENHARBOR_ENABLED={os.environ.get("TOKENHARBOR_ENABLED")}', flush=True)
    print(f'TOKENHARBOR_MAX_TOKENS={os.environ.get("TOKENHARBOR_MAX_TOKENS")}', flush=True)
    uvicorn.run(build_app(), host='127.0.0.1', port=8092,
                log_level=os.environ.get('LOG_LEVEL', 'warning').lower())
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
