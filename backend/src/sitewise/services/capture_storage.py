"""Capture-frame storage gateway (Supabase Storage, PRIVATE bucket).

The 360° capture originals and stitched panoramas are source imagery tied to
a property — the opposite of ``photo_storage``'s display media — so they live
in a dedicated PRIVATE bucket and are reached only through short-lived
signed URLs issued by this backend after authorization. The service-role key
stays server-side; Flutter receives upload/view URLs, never credentials.

Object paths are deterministic and property-scoped:

    properties/{property_id}/sessions/{session_id}/frames/{target_index}.jpg
    properties/{property_id}/sessions/{session_id}/panorama.jpg

Determinism is what makes uploads retry-safe: the same frame re-uploaded
after a network failure overwrites the same object (the client sends
``x-upsert: true``), and the frame-confirm endpoint can verify the object it
is about to register actually exists.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass

from sitewise.core.config import settings

BUCKET = "property-panoramas"
UPLOAD_URL_TTL_SECONDS = 900
VIEW_URL_TTL_SECONDS = 3600
FRAME_MAX_BYTES = 16 * 1024 * 1024
PANORAMA_MAX_BYTES = 32 * 1024 * 1024


class CaptureStorageUnavailable(Exception):
    """Storage is not configured or unreachable; captures stay on the device."""


class ObjectMissing(Exception):
    """The object the caller referenced does not exist in the bucket."""


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


def signed_upload_url(
    *, storage_path: str, target_index: int
) -> SignedUpload:
    """A short-lived, path-pinned upload permission for one frame.

    Supabase fixes the server-side lifetime of signed upload URLs (one hour);
    the client-facing TTL promised in responses is the shorter
    ``UPLOAD_URL_TTL_SECONDS`` so the device re-requests long before expiry.
    """
    _ensure_once()
    client = _client()
    try:
        result = client.storage.from_(BUCKET).create_signed_upload_url(storage_path)
    except Exception as exc:  # noqa: BLE001
        raise CaptureStorageUnavailable(
            "The upload URL could not be issued. The capture frames are "
            "kept on the device; please retry later."
        ) from exc
    return SignedUpload(
        target_index=target_index,
        storage_path=storage_path,
        upload_url=_absolute(result["signedUrl"]),
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
