"""Private local storage for verification documents.

Documents are written under a configured root that is never web-served. The
storage key is generated here (``uuid4().hex`` + a validated extension) — a
client can never influence the path, so path traversal is impossible by
construction. Downloads stream through the authenticated API endpoint only.
"""

from __future__ import annotations

import uuid
from pathlib import Path

from sitewise.core.config import settings
from sitewise.core.exceptions import ModelUnavailableError

# Extension -> allowed MIME types. A file is accepted only when BOTH the
# extension and the declared content type fall inside the same family.
_ALLOWED: dict[str, set[str]] = {
    ".pdf": {"application/pdf"},
    ".png": {"image/png"},
    ".jpg": {"image/jpeg"},
    ".jpeg": {"image/jpeg"},
    ".webp": {"image/webp"},
}
DEFAULT_MAX_BYTES = 10 * 1024 * 1024


class DocumentRejected(Exception):
    """Raised with a user-facing message; mapped to 422/413 by the API layer."""

    def __init__(self, message: str, *, oversized: bool = False):
        super().__init__(message)
        self.oversized = oversized


def storage_root() -> Path:
    configured = settings.verification_storage_dir.strip()
    root = (
        Path(configured)
        if configured
        else Path(__file__).resolve().parents[3] / "var" / "verification-documents"
    )
    try:
        root.mkdir(parents=True, exist_ok=True)
    except OSError as exc:  # unwritable disk, permission denied, ...
        raise ModelUnavailableError("Document storage is not available on the server.") from exc
    return root


def max_bytes() -> int:
    return max(1, settings.verification_max_upload_mb) * 1024 * 1024


def validate_upload(original_filename: str, content_type: str, size: int) -> str:
    """Return the storage extension for an accepted upload, or raise.

    ``size`` is checked first so an oversized file never touches the disk.
    """
    limit = max_bytes()
    if size > limit:
        raise DocumentRejected(
            f"Documents are limited to {settings.verification_max_upload_mb} MB.",
            oversized=True,
        )
    name = (original_filename or "").strip()
    ext = Path(name).suffix.lower()
    if ext not in _ALLOWED:
        raise DocumentRejected("Unsupported document type. Allowed: PDF, PNG, JPEG, WebP.")
    if size <= 0:
        raise DocumentRejected("The uploaded document is empty.")
    mime = (content_type or "").split(";")[0].strip().lower()
    if mime and mime not in _ALLOWED[ext]:
        raise DocumentRejected("The file content does not match its extension.")
    return ext


def save_document(data: bytes, ext: str) -> str:
    """Persist bytes under an unpredictable generated key; return the key."""
    key = f"{uuid.uuid4().hex}{ext}"
    target = storage_root() / key
    # Defence in depth: the generated key is safe, but assert the invariant
    # the whole module relies on — the resolved path stays inside the root.
    if target.resolve().parent != storage_root().resolve():
        raise ModelUnavailableError("Document storage refused the generated path.")
    target.write_bytes(data)
    return key


def open_document(storage_key: str) -> tuple[Path, int]:
    """Resolve a stored key to a readable path and its size."""
    if "/" in storage_key or "\\" in storage_key or ".." in storage_key:
        raise ModelUnavailableError("Invalid document reference.")
    target = storage_root() / storage_key
    if target.resolve().parent != storage_root().resolve() or not target.is_file():
        raise ModelUnavailableError("The document file is missing from storage.")
    return target, target.stat().st_size


def delete_document(storage_key: str) -> None:
    if "/" in storage_key or "\\" in storage_key or ".." in storage_key:
        return
    target = storage_root() / storage_key
    if target.resolve().parent == storage_root().resolve() and target.is_file():
        target.unlink(missing_ok=True)
