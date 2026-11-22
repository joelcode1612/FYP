"""Durable local-to-Supabase assignment mirror; never an authorization source."""
from __future__ import annotations

import logging
import threading
from urllib.parse import urlsplit

import httpx

log = logging.getLogger(__name__)
_stop = threading.Event()
_lock = threading.Lock()
_thread: threading.Thread | None = None

CLAIM = """
WITH candidate AS (
 SELECT listing_id FROM sitewise_sync.assignment_outbox
 WHERE synced_at IS NULL AND next_attempt_at <= now()
 ORDER BY next_attempt_at,listing_id LIMIT 1 FOR UPDATE SKIP LOCKED
)
UPDATE sitewise_sync.assignment_outbox o
SET attempts=o.attempts+1,next_attempt_at=now()+interval '60 seconds'
FROM candidate c WHERE o.listing_id=c.listing_id
RETURNING o.listing_id,o.revision,o.operation,o.snapshot,o.attempts
"""
SUCCESS = """
UPDATE sitewise_sync.assignment_outbox
SET synced_at=now(),last_error=NULL
WHERE listing_id=:listing_id AND revision=:revision
"""
FAILURE = """
UPDATE sitewise_sync.assignment_outbox
SET last_error=:error,next_attempt_at=now()+(:delay * interval '1 second')
WHERE listing_id=:listing_id AND revision=:revision AND synced_at IS NULL
"""
BLOCKED = {'mapping_required', 'mapping_changed', 'mapping_conflict',
           'property_missing', 'agent_missing', 'unowned_remote_row'}


def retry_delay(attempts: int) -> int:
    return min(300, 2 ** min(8, max(1, attempts)))


def request_headers(key: str) -> dict[str, str]:
    headers = {'apikey': key, 'Content-Profile': 'fyp', 'Accept-Profile': 'fyp'}
    if not key.startswith('sb_secret_'):
        headers['Authorization'] = f'Bearer {key}'
    return headers


def deliver(client: httpx.Client, base: str, key: str, event: dict) -> str | None:
    """None is a confirmed success; all other values are safe retry reasons."""
    payload = {'p_listing_id': event['listing_id'], 'p_revision': event['revision'],
               'p_operation': event['operation'], 'p_snapshot': event['snapshot']}
    try:
        res = client.post(base.rstrip('/') + '/rest/v1/rpc/sync_agent_assignment',
                          headers=request_headers(key), json=payload)
    except httpx.HTTPError:
        return 'supabase_connection_failed'
    if res.status_code != 200:
        # No response body or credential ever enters the outbox or logs.
        return f'supabase_http_{res.status_code}'
    try:
        body = res.json()
    except ValueError:
        return 'invalid_sync_response'
    if not isinstance(body, dict):
        return 'invalid_sync_response'
    status = body.get('status')
    if status in ('applied', 'already_applied'):
        revision = body.get('revision')
        if isinstance(revision, int) and not isinstance(revision, bool) and revision >= event['revision']:
            return None
        return 'invalid_sync_revision'
    return status if isinstance(status, str) and status in BLOCKED else 'invalid_sync_response'


def run_once(engine, client: httpx.Client, base: str, key: str) -> bool:
    from sqlalchemy import text
    # Commit the claim before HTTP. A crashed process is retried after its lease.
    with engine.begin() as conn:
        row = conn.execute(text(CLAIM)).mappings().first()
        event = dict(row) if row else None
    if event is None:
        return False
    error = deliver(client, base, key, event)
    params = {k: event[k] for k in ('listing_id', 'revision')}
    with engine.begin() as conn:
        if error is None:
            conn.execute(text(SUCCESS), params)
        else:
            conn.execute(text(FAILURE), {**params, 'error': error,
                         'delay': retry_delay(event['attempts'])})
            log.warning('Assignment mirror pending: listing=%s reason=%s', event['listing_id'], error)
    return True


def startup() -> str:
    from sitewise.core.config import settings
    from sitewise.db.session import engine
    from sqlalchemy import text
    global _thread
    if not settings.assignment_sync_enabled:
        return 'disabled (set ASSIGNMENT_SYNC_ENABLED=true after installing both SQL migrations)'
    parsed = urlsplit(settings.supabase_url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ('', '/'):
        raise RuntimeError('Assignment sync requires a valid HTTPS Supabase project URL')
    if not settings.supabase_secret_key:
        raise RuntimeError('Assignment sync requires the server Supabase secret key')
    with engine.connect() as conn:
        database, table = conn.execute(text("SELECT current_database(), to_regclass('sitewise_sync.assignment_outbox')")).one()
        if database != 'Final_Location_Analysis' or table is None:
            raise RuntimeError('Install assignment outbox on the configured Final_Location_Analysis database')
    with _lock:
        if _thread is not None and _thread.is_alive():
            return 'already running'
        _stop.clear()
        def loop():
            with httpx.Client(timeout=12.0, follow_redirects=False) as client:
                while not _stop.is_set():
                    try:
                        worked = run_once(engine, client, settings.supabase_url, settings.supabase_secret_key)
                    except Exception as exc:
                        # Avoid SQL exceptions with embedded snapshots or credentials.
                        log.error('Assignment sync worker error: %s', type(exc).__name__)
                        worked = False
                    _stop.wait(0.2 if worked else 3.0)
        _thread = threading.Thread(target=loop, name='assignment-mirror', daemon=True)
        _thread.start()
    return 'running'


def shutdown() -> None:
    _stop.set()
    # An unfinished request leaves the durable lease to expire on restart.
    if _thread is not None:
        _thread.join(timeout=2)
