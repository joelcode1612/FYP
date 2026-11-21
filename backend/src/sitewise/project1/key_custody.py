"""Per-record key custody, so a retention deadline can be honoured.

WHY THIS EXISTS
``project1_ai.bdj_raw_responses.retention_until`` is NOT NULL and carries a
forward-only CHECK, but the table also carries
``immutable_history BEFORE UPDATE OR DELETE`` -> ``deny_mutation()``. No row can
ever be updated or deleted, so no code path can honour the deadline by removing
the row. Crypto-shredding resolves the deadlock: destroy the per-record key at
expiry and the ciphertext becomes permanently unreadable while the audit row,
its digest and its byte count survive untouched.

WHAT THIS IS NOT
It is not a KMS. Key material lives in a local directory with restrictive
permissions, outside the ``project1_ai`` schema and outside the database, which
is the minimum that makes shredding possible without a migration. It is also
not a backup-erasure mechanism: a key that a backup already captured is still
in that backup. The property proved here is that the *live* store can no longer
decrypt the row.

GRANULARITY
One key per record. ``CustodyCipher.encrypt()`` provisions a fresh key for each
call, so destroying record A's key cannot affect record B or C. That isolation
is asserted by test, because a shared key would turn one expired record into a
whole-table outage -- or, worse, into a reason to keep every key forever.

ERRORS
Every failure is a fixed code on ``KeyCustodyError``. Key material, ciphertext,
plaintext and filesystem paths never appear in a message: a custody error is
the one place where an over-helpful message would print the secret.
"""
from __future__ import annotations

import os
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Protocol, runtime_checkable

from cryptography.fernet import Fernet, InvalidToken

from sitewise.core.config import settings

# Mirrors the CHECK on bdj_raw_responses.key_id (1..64) and doubles as the
# traversal guard: a key id becomes a filename, so anything outside this
# alphabet is refused before a path is built.
_KEY_ID = re.compile(r'^[A-Za-z0-9._:-]{1,64}$')

# Key namespaces. Raw-response keys live under RAW_KEY_PREFIX and are the only
# keys retention can name (it selects `bdj_raw_responses.key_id`). Result-payload
# keys live under PAYLOAD_KEY_PREFIX and have no retention deadline: the row in
# `bdj_results` is kept indefinitely, so destroying its key would destroy the
# result. The prefixes are what make the two lifecycles distinguishable at a
# glance, and the reason a raw key must never be reused for a payload.
RAW_KEY_PREFIX = 'rec-'
PAYLOAD_KEY_PREFIX = 'payload-'

STATE_LIVE = 'LIVE'
STATE_DESTROYED = 'DESTROYED'
STATE_MISSING = 'MISSING'

OUTCOME_DESTROYED = 'DESTROYED'
OUTCOME_ALREADY_DESTROYED = 'ALREADY_DESTROYED'
OUTCOME_KEY_MISSING = 'KEY_MISSING'

REASON_RETENTION_EXPIRED = 'RETENTION_EXPIRED'


class KeyCustodyError(Exception):
    """Fixed reason code only; never key material, ciphertext or a path."""


class KeyUnavailable(KeyCustodyError):
    """Decryption refused. The code says which refusal, not what the key was."""


@dataclass(frozen=True)
class DestructionReceipt:
    """What one destroy() call did. Never contains key material."""

    key_id: str
    destroyed_at: str
    outcome: str
    reason_code: str


@runtime_checkable
class KeyCustody(Protocol):
    """Custody port. A KMS-backed implementation must satisfy the same four."""

    def provision(self, key_id: str) -> bytes:
        """Create and return the key for ``key_id``; idempotent while live."""
        ...

    def get(self, key_id: str) -> bytes | None:
        """Return the key, or None when it is destroyed or absent."""
        ...

    def destroy(self, key_id: str, *,
                reason_code: str = REASON_RETENTION_EXPIRED) -> DestructionReceipt:
        """Make the key unrecoverable. Idempotent."""
        ...

    def state(self, key_id: str) -> str:
        """LIVE / DESTROYED / MISSING.

        Part of the port because ``get()`` collapses destroyed and missing into
        None, and an auditor must be able to tell a completed retention action
        from a custody incident. A cipher that could not distinguish them would
        report both as the same error.
        """
        ...


def default_custody_root() -> Path:
    """``PROJECT1_KEY_CUSTODY_DIR`` or ``<backend>/var/key-custody``.

    Deliberately not inside the source tree's importable packages and not
    inside the database: key material must not travel with a schema dump.
    """
    configured = settings.project1_key_custody_dir.strip()
    if configured:
        return Path(configured)
    return Path(__file__).resolve().parents[3] / 'var' / 'key-custody'


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _check_key_id(key_id: str) -> str:
    if not isinstance(key_id, str) or not _KEY_ID.fullmatch(key_id):
        raise KeyCustodyError('KEY_ID_INVALID')
    return key_id


class LocalKeyCustody:
    """Filesystem custody: one file per key, one tombstone per destroyed key.

    Layout under ``root``::

        keys/<key_id>.key          0600, raw Fernet key
        destroyed/<key_id>.json    tombstone; presence means "never readable"

    The tombstone is written *before* the key file is unlinked, so a crash
    between the two steps leaves a key that ``get()`` already refuses to serve.
    The failure mode is therefore "key lost", never "destroyed key still
    readable".
    """

    def __init__(self, root: Path | str | None = None):
        self.root = Path(root) if root is not None else default_custody_root()
        self._keys = self.root / 'keys'
        self._tombs = self.root / 'destroyed'
        self._ensure_layout()

    # -- layout ------------------------------------------------------------
    def _ensure_layout(self) -> None:
        for directory in (self.root, self._keys, self._tombs):
            directory.mkdir(parents=True, exist_ok=True)
            self._restrict(directory)

    @staticmethod
    def _restrict(directory: Path) -> None:
        # 0700/0600 is the POSIX control. On Windows only the read-only bit is
        # honoured by chmod, so the effective control there is the directory
        # ACL inherited from the profile -- a real limitation, stated rather
        # than papered over.
        try:
            os.chmod(directory, 0o700)
        except OSError:
            pass

    def _key_path(self, key_id: str) -> Path:
        return self._keys / f'{key_id}.key'

    def _tomb_path(self, key_id: str) -> Path:
        return self._tombs / f'{key_id}.json'

    # -- port --------------------------------------------------------------
    def provision(self, key_id: str) -> bytes:
        key_id = _check_key_id(key_id)
        if self._tomb_path(key_id).exists():
            # Re-provisioning a destroyed id would silently resurrect a record
            # whose retention deadline already passed.
            raise KeyCustodyError('KEY_RETIRED')
        path = self._key_path(key_id)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            existing = self._read_key(key_id)
            if existing is None:
                raise KeyCustodyError('KEY_MATERIAL_INVALID') from None
            return existing
        except OSError:
            raise KeyCustodyError('KEY_STORAGE_UNAVAILABLE') from None
        key = Fernet.generate_key()
        try:
            os.write(fd, key)
            os.fsync(fd)
        except OSError:
            raise KeyCustodyError('KEY_STORAGE_UNAVAILABLE') from None
        finally:
            os.close(fd)
        return key

    def get(self, key_id: str) -> bytes | None:
        key_id = _check_key_id(key_id)
        if self._tomb_path(key_id).exists():
            return None
        return self._read_key(key_id)

    def destroy(self, key_id: str, *,
                reason_code: str = REASON_RETENTION_EXPIRED) -> DestructionReceipt:
        key_id = _check_key_id(key_id)
        tomb = self._tomb_path(key_id)
        if tomb.exists():
            return DestructionReceipt(key_id=key_id, destroyed_at=_read_tomb_time(tomb),
                                      outcome=OUTCOME_ALREADY_DESTROYED,
                                      reason_code=reason_code)
        existed = self._key_path(key_id).exists()
        destroyed_at = _now()
        payload = (f'{{"key_id":"{key_id}","destroyed_at":"{destroyed_at}",'
                   f'"reason_code":"{reason_code}"}}\n')
        try:
            fd = os.open(tomb, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            return DestructionReceipt(key_id=key_id, destroyed_at=_read_tomb_time(tomb),
                                      outcome=OUTCOME_ALREADY_DESTROYED,
                                      reason_code=reason_code)
        except OSError:
            raise KeyCustodyError('KEY_STORAGE_UNAVAILABLE') from None
        try:
            os.write(fd, payload.encode('utf-8'))
            os.fsync(fd)
        except OSError:
            raise KeyCustodyError('KEY_STORAGE_UNAVAILABLE') from None
        finally:
            os.close(fd)
        try:
            self._key_path(key_id).unlink(missing_ok=True)
        except OSError:
            # The tombstone is already durable, so get() refuses this key from
            # now on even though the file survived. Report the weaker outcome
            # rather than claiming the file is gone.
            raise KeyCustodyError('KEY_UNLINK_FAILED') from None
        return DestructionReceipt(key_id=key_id, destroyed_at=destroyed_at,
                                  outcome=OUTCOME_DESTROYED if existed
                                  else OUTCOME_KEY_MISSING,
                                  reason_code=reason_code)

    def state(self, key_id: str) -> str:
        key_id = _check_key_id(key_id)
        if self._tomb_path(key_id).exists():
            return STATE_DESTROYED
        return STATE_LIVE if self._key_path(key_id).exists() else STATE_MISSING

    # -- internals ---------------------------------------------------------
    def _read_key(self, key_id: str) -> bytes | None:
        try:
            raw = self._key_path(key_id).read_bytes()
        except FileNotFoundError:
            return None
        except OSError:
            raise KeyCustodyError('KEY_STORAGE_UNAVAILABLE') from None
        try:
            Fernet(raw)
        except (ValueError, TypeError):
            raise KeyCustodyError('KEY_MATERIAL_INVALID') from None
        return raw


def _read_tomb_time(tomb: Path) -> str:
    """Best-effort original destruction time; the file's mtime is the fallback."""
    try:
        text = tomb.read_text(encoding='utf-8')
        match = re.search(r'"destroyed_at":"([^"]{1,64})"', text)
        if match:
            return match.group(1)
    except OSError:
        pass
    try:
        return datetime.fromtimestamp(tomb.stat().st_mtime, timezone.utc).isoformat()
    except OSError:
        return ''


class CustodyCipher:
    """``KeyCipher`` (core/cipher.py) backed by per-record custody keys.

    Satisfies the existing port, so ``BdjResultStore(cipher=...)`` accepts it
    unchanged. One key per ``encrypt()`` call is what makes per-record
    crypto-shredding possible; a rotating shared key would make expiry a
    table-wide operation.
    """

    def __init__(self, custody: KeyCustody,
                 key_id_factory: Callable[[], str] | None = None):
        self.custody = custody
        self._factory = key_id_factory or (lambda: RAW_KEY_PREFIX + uuid.uuid4().hex)

    def encrypt(self, plaintext: bytes) -> tuple[bytes, str]:
        if not isinstance(plaintext, (bytes, bytearray)) or not plaintext:
            raise KeyUnavailable('PLAINTEXT_EMPTY')
        key_id = self._factory()
        key = self.custody.provision(key_id)
        try:
            return Fernet(key).encrypt(bytes(plaintext)), key_id
        except (ValueError, TypeError):
            raise KeyUnavailable('KEY_MATERIAL_INVALID') from None

    def decrypt(self, ciphertext: bytes, key_id: str) -> bytes:
        key = self.custody.get(key_id)
        if key is None:
            state = self.custody.state(key_id)
            # A destroyed key is an expected retention outcome; a missing one is
            # an incident. Reporting them identically would hide the incident.
            raise KeyUnavailable('KEY_DESTROYED' if state == STATE_DESTROYED
                                 else 'KEY_UNAVAILABLE')
        try:
            return Fernet(key).decrypt(ciphertext)
        except (InvalidToken, ValueError, TypeError):
            # Wrong key, truncated token or tampered ciphertext. The code is
            # deliberately the same for all three: distinguishing them is an
            # oracle, and the caller can do nothing different anyway.
            raise KeyUnavailable('KEY_DECRYPTION_REFUSED') from None


def payload_key_id(result_id) -> str:
    """Deterministic, namespaced key id for one ``bdj_results.result_payload``.

    Deterministic because the id is derived from ``result_id``, which is itself
    derived from ``(run_id, attempt_no)``: re-persisting the same attempt
    re-provisions the same key instead of stranding a second one. Namespaced
    because retention selects keys from ``bdj_raw_responses`` only -- a payload
    key can never appear in that selection, and the prefix makes the difference
    visible to an operator reading a key directory.
    """
    return _check_key_id(f'{PAYLOAD_KEY_PREFIX}{result_id}')


def payload_cipher(custody: KeyCustody, result_id) -> CustodyCipher:
    """A ``CustodyCipher`` bound to the payload key of exactly one result.

    ``result_store`` uses this to seal ``result_payload``; a caller passes the
    custody (``BdjResultStore(payload_custody=...)``), not this cipher, so the
    key name is never chosen at a call site. It must NOT be used for
    ``raw_output``: raw keys are the only ones retention destroys, and giving a
    payload a raw key would put the result on a retention clock it does not have.
    """
    key_id = payload_key_id(result_id)
    return CustodyCipher(custody, key_id_factory=lambda: key_id)
