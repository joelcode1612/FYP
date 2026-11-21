"""Candidate authenticated-backend assertion; not sufficient without DB policy migration.

Never log the key or returned bearer assertion. A verified database function
must validate the signature and enforce owner/reviewer policies independently.
"""
import hashlib
import hmac
import secrets
import time
from uuid import UUID


def mint_m2_assertion(actor_id: UUID, key_hex: str, *, now: int | None = None) -> str:
    if not isinstance(actor_id, UUID):
        raise ValueError('Authenticated actor UUID required.')
    try:
        key = bytes.fromhex(key_hex)
    except (TypeError, ValueError):
        raise ValueError('M2 identity assertion key must be hex encoded.') from None
    if len(key) < 32 or len(key_hex) != len(key) * 2:
        raise ValueError('M2 identity assertion key must be at least 32 bytes.')
    issued = int(time.time()) if now is None else int(now)
    body = f'{actor_id}|{issued + 30}|{secrets.token_hex(16)}'
    signature = hmac.new(key, body.encode('ascii'), hashlib.sha256).hexdigest()
    return body + '|' + signature
