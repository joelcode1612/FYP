"""Key-custody port for the protected model-output store.

Key custody is an open Owner decision (CP-04A B3), so this module defines the
*shape* of a cipher and nothing else. No production implementation, no key
location, no environment-variable default and no KMS call lives here: a store
that hard-coded any of those would make the B3 decision by accident.

`BdjResultStore` accepts any object satisfying this Protocol. With no cipher it
stores the structured result only and refuses to accept raw output bytes --
there is deliberately no plaintext fallback.
"""
from typing import Protocol, runtime_checkable


@runtime_checkable
class KeyCipher(Protocol):
    """Encrypt/decrypt with a caller-held key identified by a rotation label."""

    def encrypt(self, plaintext: bytes) -> tuple[bytes, str]:
        """Return ``(ciphertext, key_id)``. Never return the key itself."""
        ...

    def decrypt(self, ciphertext: bytes, key_id: str) -> bytes:
        """Return the plaintext for ``ciphertext`` under ``key_id``."""
        ...
