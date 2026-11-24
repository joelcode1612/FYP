"""One shared guard for the dead-loopback-proxy defect.

History, because this defect has now recurred twice:

* N02 (BDJ live run) inherited ``HTTP(S)_PROXY=http://127.0.0.1:58185`` from the
  captured ``var/e2e/app.env``. Nothing was listening, ``httpx`` trusted it, and
  the provider call died as ``ConnectError`` before any HTTP status existed.
  Fixed privately in ``var/e2e/n01_start_app.py``.
* N04-C (Direct-QG) hit the same dead port and was fixed separately in
  ``tools/n04c_serve_isolated_app.py``.

Two private fixes, one shared poison. This module is the single implementation
both should have used.

Scope of the correction
-----------------------
Only a **loopback** proxy is probed and dropped. That keeps the change a
transport correction rather than an egress-policy change: no traffic is sent to
an external host to decide whether to trust it, and a configured *remote* proxy
is left exactly as the operator set it. Dropping a dead ``127.0.0.1`` proxy
restores the direct connection the host was already using for everything else.

Every action is printed, so a dropped proxy can never be mistaken for a silent
success.
"""
from __future__ import annotations

import os
import socket
from urllib.parse import urlparse

PROXY_VARS = (
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
    'http_proxy', 'https_proxy', 'all_proxy',
)
LOOPBACK_HOSTS = {'127.0.0.1', 'localhost', '::1'}


def proxy_is_reachable(value: str, *, timeout: float = 0.75) -> bool:
    """True when a TCP connect to a loopback proxy's host:port succeeds.

    A non-loopback proxy is reported reachable without probing, because probing
    it would be an outbound request and this guard must not make one.
    """
    parsed = urlparse(value if '://' in value else 'http://' + value)
    host = parsed.hostname
    if not host:
        return False
    if host not in LOOPBACK_HOSTS:
        return True
    port = parsed.port or (443 if parsed.scheme == 'https' else 80)
    probe = socket.socket()
    probe.settimeout(timeout)
    try:
        probe.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def drop_unreachable_proxies(*, verbose: bool = True) -> list[str]:
    """Remove loopback proxy variables that point at nothing. Returns what went.

    Idempotent and safe to call from every launcher.
    """
    dropped: list[str] = []
    for key in PROXY_VARS:
        value = os.environ.get(key)
        if not value:
            continue
        if proxy_is_reachable(value):
            if verbose:
                print(f'KEEPING_REACHABLE_PROXY {key}={value}', flush=True)
            continue
        if verbose:
            print(f'DROPPING_UNREACHABLE_PROXY {key}={value}', flush=True)
        os.environ.pop(key, None)
        dropped.append(key)
    if verbose and not dropped:
        print('proxy guard: nothing to drop', flush=True)
    return dropped
