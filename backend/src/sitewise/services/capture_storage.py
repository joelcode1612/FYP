"""Capture-frame storage gateway (Supabase Storage, PRIVATE bucket).

The 360° capture originals and stitched panoramas are source imagery tied to
a property — the opposite of ``photo_storage``'s display media — so they live
in a dedicated PRIVATE bucket and are reached only through short-lived
signed URLs issued by this backend after authorization. The service-role key
stays server-side; Flutter receives upload/view URLs, never credentials.

Object paths are deterministic and property-scoped:

    properties/{property_id}/sessions/{session_id}/frames/{target_index}.jpg
    properties/{property_id}/sessions/{session_id}/panorama.jpg

Determinism is what makes uploads retry-safe: the same frame always resolves
to the same object, so an interrupted attempt leaves a path that a resume can
verify and confirm instead of uploading again. Supabase refuses to mint an
upload token for an occupied path unless the caller explicitly asks to
replace it (``x-upsert: true``), so "already stored" is reported as its own
condition ([ObjectAlreadyStored]) and only an authorized replacement request
overwrites bytes.
"""

from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass

from sitewise.core.config import settings
from sitewise.core.exceptions import ValidationError

logger = logging.getLogger(__name__)

BUCKET = "property-panoramas"
UPLOAD_URL_TTL_SECONDS = 900
VIEW_URL_TTL_SECONDS = 3600
FRAME_MAX_BYTES = 16 * 1024 * 1024
PANORAMA_MAX_BYTES = 32 * 1024 * 1024


class CaptureStorageUnavailable(Exception):
    """Storage is not configured or unreachable; captures stay on the device."""


class ObjectMissing(Exception):
    """The object the caller referenced does not exist in the bucket."""


class ObjectAlreadyStored(Exception):
    """The target path already holds an object and no upsert was requested.

    Supabase Storage refuses to mint an upload token for an occupied path
    (``409 Duplicate / The resource already exists``). That is a RESUME
    signal, not an outage: the bytes the device wanted to send are usually
    already there from an interrupted attempt, so the caller should confirm
    the existing object instead of uploading again.
    """

    def __init__(self, storage_path: str) -> None:
        super().__init__(storage_path)
        self.storage_path = storage_path


@dataclass(frozen=True)
class SignedUpload:
    target_index: int
    storage_path: str
    upload_url: str
    expires_at: str | None


def frame_object_path(property_id: int | str, session_id: str, target_index: int) -> str:
    return f"properties/{property_id}/sessions/{session_id}/frames/{target_index}.jpg"


def panorama_object_path(property_id: int | str, session_id: str) -> str:
    return f"properties/{property_id}/sessions/{session_id}/panorama.jpg"


def enhanced_panorama_object_path(property_id: int | str, session_id: str) -> str:
    """The SEPARATE derived enhancement object; never the canonical path."""
    return f"properties/{property_id}/sessions/{session_id}/panorama_enhanced.jpg"


def panorama_candidate_object_path(
    property_id: int | str, session_id: str, attempt_id: str
) -> str:
    """Unique, non-destructive artifact path for replacing an existing draft."""
    return (
        f"properties/{property_id}/sessions/{session_id}/panorama-candidates/"
        f"{attempt_id}.jpg"
    )


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify_checksum(data: bytes, expected_hex: str | None) -> bool:
    if not expected_hex:
        return True
    return sha256_hex(data) == expected_hex.strip().lower()


def _client():
    if not settings.supabase_url or not settings.supabase_secret_key:
        raise CaptureStorageUnavailable(
            "Capture storage is not configured on the server "
            "(missing Supabase credentials)."
        )
    try:
        from supabase import create_client

        return create_client(settings.supabase_url, settings.supabase_secret_key)
    except Exception as exc:  # noqa: BLE001 - surfaced as 503 by the API layer
        raise CaptureStorageUnavailable(
            "Capture storage could not be reached. The capture frames are "
            "kept on the device; please retry later."
        ) from exc


def ensure_bucket() -> None:
    client = _client()
    try:
        client.storage.create_bucket(BUCKET, options={"public": False})
    except Exception as exc:  # noqa: BLE001
        message = str(exc).lower()
        if "duplicate" in message or "already exists" in message:
            return
        raise CaptureStorageUnavailable(
            "The capture storage bucket is unavailable."
        ) from exc


_bucket_ready = False


def _ensure_once() -> None:
    """Create the private bucket once per process before first use."""
    global _bucket_ready
    if _bucket_ready:
        return
    ensure_bucket()
    _bucket_ready = True


def _absolute(url: str) -> str:
    if url.startswith("http://") or url.startswith("https://"):
        return url
    return f"{settings.supabase_url.rstrip('/')}{url}"


def _log_refusal(operation: str, storage_path: str, exc: Exception) -> None:
    """Log the storage API's own code and message — never a URL or a token.

    ``StorageApiError`` carries ``status``, ``code`` and ``message``; the
    signed upload URL itself embeds a JWT and must never reach a log line.
    The object path is derived from ids the caller already supplied, so it is
    safe to record and is what makes a duplicate diagnosable.
    """
    logger.warning(
        "Supabase storage refused %s for %s: status=%s code=%s message=%s",
        operation,
        storage_path,
        getattr(exc, "status", None),
        getattr(exc, "code", None),
        getattr(exc, "message", None) or str(exc),
    )


def _is_duplicate(exc: Exception) -> bool:
    """True when the storage API rejected the path because it is occupied.

    Supabase answers ``409`` with ``code=Duplicate`` and the message
    ``The resource already exists``; older storage-api builds answer ``400``
    with ``KeyAlreadyExists``. Both are the same condition and both are
    recoverable by confirming the stored object.
    """
    code = str(getattr(exc, "code", "") or "").strip().lower()
    status = getattr(exc, "status", None)
    message = str(getattr(exc, "message", "") or exc).lower()
    if code in {"duplicate", "keyalreadyexists", "resourcealreadyexists"}:
        return True
    return status in (400, 409) and (
        "already exists" in message or "duplicate" in message
    )


def _signed_upload_options(upsert: bool):
    """The SDK's upsert option, or ``None`` for the default create-only mode.

    ``storage3`` 2.34.1 (installed) supports
    ``create_signed_upload_url(path, options)`` with
    ``CreateSignedUploadUrlOptions(upsert="true")``, which forwards
    ``x-upsert: true``. Older builds did not accept the argument at all, so
    an authorized replacement reports a clear error instead of silently
    issuing a create-only URL that the storage API would refuse.
    """
    if not upsert:
        return None
    try:
        from storage3.types import CreateSignedUploadUrlOptions
    except ImportError as exc:  # pragma: no cover - pinned SDK always has it
        raise CaptureStorageUnavailable(
            "This server's storage client cannot replace an existing "
            "photograph. Please retry later."
        ) from exc
    return CreateSignedUploadUrlOptions(upsert="true")


def signed_upload_url(
    *, storage_path: str, target_index: int, upsert: bool = False
) -> SignedUpload:
    """A short-lived, path-pinned upload permission for one frame.

    Supabase fixes the server-side lifetime of signed upload URLs (one hour);
    the client-facing TTL promised in responses is the shorter
    ``UPLOAD_URL_TTL_SECONDS`` so the device re-requests long before expiry.

    ``upsert=True`` is the EXPLICIT replacement path: it is only used when an
    authorized retry must overwrite the object (a stale or corrupt object for
    the same deterministic path). A create-only request that hits an existing
    object raises [ObjectAlreadyStored] so the caller can confirm the stored
    bytes instead of failing the whole batch.
    """
    _ensure_once()
    client = _client()
    try:
        result = client.storage.from_(BUCKET).create_signed_upload_url(
            storage_path, options=_signed_upload_options(upsert)
        )
    except Exception as exc:  # noqa: BLE001
        if not upsert and _is_duplicate(exc):
            # Expected on resume: the object from an interrupted attempt is
            # still there. Log the API's own words at info level (no token,
            # no URL) so a repeated 409 is diagnosable without being an alarm.
            logger.info(
                "Supabase storage reported an existing object for %s: "
                "status=%s code=%s message=%s (resumed upload)",
                storage_path,
                getattr(exc, "status", None),
                getattr(exc, "code", None),
                getattr(exc, "message", None) or str(exc),
            )
            raise ObjectAlreadyStored(storage_path) from exc
        _log_refusal(
            f"create_signed_upload_url(upsert={upsert})", storage_path, exc
        )
        raise CaptureStorageUnavailable(
            "The upload URL could not be issued. The capture frames are "
            "kept on the device; please retry later."
        ) from exc
    url = result.get("signedUrl") or result.get("signed_url")
    if not url:
        raise CaptureStorageUnavailable(
            "The upload URL could not be issued. The capture frames are "
            "kept on the device; please retry later."
        )
    return SignedUpload(
        target_index=target_index,
        storage_path=storage_path,
        upload_url=_absolute(url),
        expires_at=None,
    )


def signed_view_url(storage_path: str, expires_in: int = VIEW_URL_TTL_SECONDS) -> str:
    """A short-lived GET URL for one object — never stored in the database."""
    client = _client()
    try:
        result = client.storage.from_(BUCKET).create_signed_url(
            storage_path, expires_in
        )
    except Exception as exc:  # noqa: BLE001
        raise CaptureStorageUnavailable(
            "The viewing URL could not be issued. Please retry later."
        ) from exc
    return _absolute(result["signedURL"])


def object_exists(storage_path: str) -> bool:
    client = _client()
    try:
        return bool(client.storage.from_(BUCKET).exists(storage_path))
    except Exception:  # noqa: BLE001 - older storage API: fall back to listing
        pass
    try:
        parent = storage_path.rsplit("/", 1)[0]
        name = storage_path.rsplit("/", 1)[1]
        entries = client.storage.from_(BUCKET).list(parent)
        return any(entry.get("name") == name for entry in entries or [])
    except Exception as exc:  # noqa: BLE001
        raise CaptureStorageUnavailable(
            "Capture storage could not be reached; the frame's receipt "
            "cannot be verified. Please retry later."
        ) from exc


def download(storage_path: str) -> bytes:
    """Read one object back — the worker's integrity check starts here."""
    client = _client()
    try:
        data = client.storage.from_(BUCKET).download(storage_path)
    except Exception as exc:  # noqa: BLE001
        message = str(exc).lower()
        if "not found" in message or "does not exist" in message:
            raise ObjectMissing(storage_path) from exc
        raise CaptureStorageUnavailable(
            "Capture storage could not be reached; the frame cannot be "
            "downloaded. Please retry later."
        ) from exc
    return bytes(data)


def decode_panorama(data: bytes) -> tuple[int, int]:
    """Decode the stored bytes as a JPEG and return ``(width, height)``.

    A corrupt, truncated or non-image payload decodes to ``None`` and is
    rejected before any canonical row can reference it. cv2 is imported
    lazily: the router is imported at startup and the vision stack must not
    pay for that.
    """
    if not data.startswith(b"\xff\xd8\xff"):
        raise ValidationError("The stored panorama must be a JPEG image.")

    import cv2
    import numpy as np

    decoded = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
    if decoded is None:
        raise ValidationError(
            "The panorama is not a readable JPEG image; upload it again."
        )
    height, width = decoded.shape[:2]
    return int(width), int(height)


def upload_bytes(storage_path: str, data: bytes, content_type: str = "image/jpeg") -> None:
    """Server-side write — the stitched panorama path only.

    Frames are uploaded by the device through signed URLs; the backend writes
    only the panorama it produced itself.
    """
    client = _client()
    try:
        client.storage.from_(BUCKET).upload(
            storage_path,
            data,
            {"content-type": content_type, "x-upsert": "true"},
        )
    except Exception as exc:  # noqa: BLE001
        message = str(exc).lower()
        if "not found" in message or "does not exist" in message:
            ensure_bucket()
            client.storage.from_(BUCKET).upload(
                storage_path,
                data,
                {"content-type": content_type, "x-upsert": "true"},
            )
            return
        raise CaptureStorageUnavailable(
            "The panorama upload failed. The original capture frames are kept."
        ) from exc


def remove_prefix(prefix: str) -> int:
    """Best-effort removal of all objects under a prefix (test runs only).

    Supabase ``list`` is one level deep: subfolders appear as entries with a
    name but no object id, so the walk recurses until it reaches real files.
    """
    client = _client()
    removed = 0

    def walk(path: str) -> None:
        nonlocal removed
        try:
            entries = client.storage.from_(BUCKET).list(path)
        except Exception:  # noqa: BLE001 - cleanup must never fail the caller
            return
        for entry in entries or []:
            name = entry.get("name")
            if not name:
                continue
            child = f"{path}/{name}"
            if entry.get("id"):
                try:
                    client.storage.from_(BUCKET).remove([child])
                    removed += 1
                except Exception:  # noqa: BLE001
                    pass
            else:
                walk(child)

    walk(prefix.rstrip("/"))
    return removed
