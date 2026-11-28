"""Public property-photo storage (Supabase Storage).

Property photos are DISPLAY media: once a listing is published they must be
reachable by plain ``<img>`` tags on web and mobile, so they live in a public
bucket and the stored URL is a stable public object URL — never a device
path, never a private signed URL. This is deliberately separate from
``verification_storage`` (ownership evidence), which stays private and
authenticated; the two never share a bucket or an endpoint.
"""

from __future__ import annotations

import hashlib
import logging
import uuid

from sitewise.core.config import settings

logger = logging.getLogger(__name__)

BUCKET = "property-photos"
PUBLIC_URL_TEMPLATE = "{base}/storage/v1/object/public/{bucket}/{path}"

# Extension -> allowed MIME types; a photo is accepted only when BOTH the
# extension and the declared content type fall inside the same family.
_ALLOWED: dict[str, set[str]] = {
    ".jpg": {"image/jpeg"},
    ".jpeg": {"image/jpeg"},
    ".png": {"image/png"},
    ".webp": {"image/webp"},
}
DEFAULT_MAX_BYTES = 8 * 1024 * 1024


class PhotoRejected(Exception):
    """Raised with a user-facing message; mapped to 422/413 by the API layer."""

    def __init__(self, message: str, oversized: bool = False):
        super().__init__(message)
        self.oversized = oversized


class PhotoStorageUnavailable(Exception):
    """Storage is not configured or unreachable; the draft stays intact."""


def validate_photo(
    original_filename: str, content_type: str, size: int, max_bytes: int = DEFAULT_MAX_BYTES
) -> str:
    """Validate type/size and return the canonical extension (with dot)."""
    name = (original_filename or "").lower()
    mime = (content_type or "").split(";")[0].strip().lower()
    ext = next((e for e in _ALLOWED if name.endswith(e)), "")
    if ext and mime not in _ALLOWED[ext]:
        # Browsers may send image/jpg; accept it for the JPEG family.
        if not (ext in (".jpg", ".jpeg") and mime in ("image/jpg", "")):
            ext = ""
    if not ext:
        raise PhotoRejected(
            "Photos must be JPG, PNG or WebP images."
        )
    if size <= 0:
        raise PhotoRejected("The photo file is empty.")
    if size > max_bytes:
        raise PhotoRejected(
            f"Photos must be {max_bytes // (1024 * 1024)} MB or smaller.",
            oversized=True,
        )
    return ext


#: A stitched 360° panorama is one wide equirectangular image (a device
#: capture produced 9596 × 4313). That is several times a gallery photo, so
#: the panorama upload gets its own ceiling instead of the 8 MB photo one.
PANORAMA_MAX_BYTES = 32 * 1024 * 1024


def validate_panorama(original_filename: str, content_type: str, size: int) -> str:
    """Validate a stitched panorama and return the canonical extension."""
    ext = validate_photo(
        original_filename, content_type, size, max_bytes=PANORAMA_MAX_BYTES
    )
    return ext


def save_panorama(data: bytes, ext: str, content_type: str) -> str:
    """Upload one stitched panorama and return its permanent public URL.

    Same public bucket and URL contract as listing photos — display media
    that must be reachable by plain ``<img>`` tags — but under a dedicated
    ``panoramas/`` prefix so the two file families never interleave.
    """
    client = _client()
    storage = client.storage.from_(BUCKET)
    path = f"panoramas/{uuid.uuid4().hex}{ext}"
    content_type_value = (content_type or "").split(";")[0] or "image/jpeg"
    try:
        storage.upload(path, data, {"content-type": content_type_value})
    except Exception as exc:  # noqa: BLE001
        message = str(exc)
        if "not found" in message.lower() or "does not exist" in message.lower():
            _ensure_bucket(client)
            storage.upload(path, data, {"content-type": content_type_value})
        else:
            raise PhotoStorageUnavailable(
                "The panorama upload failed. The capture frames are kept "
                "on the device; please retry the upload."
            ) from exc
    return PUBLIC_URL_TEMPLATE.format(
        base=settings.supabase_url.rstrip("/"),
        bucket=BUCKET,
        path=path,
    )


def _client():
    if not settings.supabase_url or not settings.supabase_secret_key:
        raise PhotoStorageUnavailable(
            "Photo storage is not configured on the server "
            "(missing Supabase credentials). Your draft is saved; "
            "please try the upload again later."
        )
    try:
        from supabase import create_client

        return create_client(settings.supabase_url, settings.supabase_secret_key)
    except Exception as exc:  # noqa: BLE001 - surfaced as 503 by the API layer
        raise PhotoStorageUnavailable(
            "Photo storage could not be reached. Your draft is saved; "
            "please retry the upload."
        ) from exc


def _bucket_id(bucket) -> str | None:
    """Read a bucket id from storage3's model or a plain mapping."""
    value = getattr(bucket, "id", None)
    if value is None and isinstance(bucket, dict):
        value = bucket.get("id") or bucket.get("name")
    return str(value) if value else None


def _upload_once(storage, path: str, data: bytes, mime: str) -> None:
    """Upload at a stable path, treating a prior copy of the bytes as success.

    The object path is content-addressed, so an interrupted attempt can leave
    the object behind without its database row. The existence probe lets the
    retry finish by inserting the row instead of creating a second object.
    """
    try:
        if storage.exists(path):
            return
    except Exception:  # noqa: BLE001 - probe only; upload gives the real error
        pass
    try:
        storage.upload(path, data, {"content-type": mime})
    except Exception as exc:  # noqa: BLE001 - concurrent identical retry
        if "already exists" in str(exc).lower() or "duplicate" in str(exc).lower():
            return
        raise


def save_photo(
    data: bytes, ext: str, content_type: str, *, identity: str = ""
) -> str:
    """Upload one photo and return its permanent public URL.

    ``identity`` scopes the content-addressed path to one listing. Retrying the
    same bytes therefore reuses the same object instead of uploading a second
    copy; this is what makes a Step 3 retry safe. It never changes the upload
    credentials or the bucket: the server-side service role remains the only
    writer.
    """
    client = _client()
    storage = client.storage.from_(BUCKET)
    scope = "".join(
        ch for ch in str(identity).strip() if ch.isalnum() or ch in "-_"
    )[:64] or "shared"
    digest = hashlib.sha256(data).hexdigest()[:32]
    path = f"listings/{scope}/{digest}{ext}"
    mime = (content_type or "").split(";")[0] or "image/jpeg"
    try:
        _upload_once(storage, path, data, mime)
    except Exception as exc:  # noqa: BLE001
        message = str(exc).lower()
        if "not found" in message or "does not exist" in message:
            try:
                _ensure_bucket(client)
                _upload_once(storage, path, data, mime)
            except Exception as retry_exc:  # noqa: BLE001
                # Keep the useful exception and traceback in server logs while
                # returning only the safe, user-facing storage message.
                logger.exception(
                    "Property photo storage retry failed (%s)",
                    type(retry_exc).__name__,
                )
                raise PhotoStorageUnavailable(
                    "The photo storage bucket is unavailable. Your draft is saved; "
                    "please retry the upload."
                ) from retry_exc
        else:
            logger.exception(
                "Property photo storage upload failed (%s)", type(exc).__name__
            )
            raise PhotoStorageUnavailable(
                "The photo upload failed. Your draft is saved; "
                "please retry the upload."
            ) from exc
    return PUBLIC_URL_TEMPLATE.format(
        base=settings.supabase_url.rstrip("/"),
        bucket=BUCKET,
        path=path,
    )


def _ensure_bucket(client) -> None:
    """Reuse the configured bucket; create it only when genuinely absent.

    storage3 2.x declares ``create_bucket(id, name=None, options=None)``. The
    previous call passed ``{"name": ..., "public": ...}`` as the second
    positional argument, binding the dict to ``name`` and producing
    ``body/name must be string``. ``options`` is the correct keyword for the
    public/file-size flags. Bucket inventory is read first so a manually
    created bucket is never replaced or duplicated.
    """
    try:
        buckets = client.storage.list_buckets()
        if any(_bucket_id(bucket) == BUCKET for bucket in buckets):
            return
        client.storage.create_bucket(BUCKET, options={"public": True})
    except Exception as exc:  # noqa: BLE001
        if "already exists" in str(exc).lower() or "duplicate" in str(exc).lower():
            return
        logger.exception(
            "Property photo bucket setup failed (%s)", type(exc).__name__
        )
        raise PhotoStorageUnavailable(
            "The photo storage bucket is unavailable. Your draft is saved; "
            "please retry the upload."
        ) from exc


def delete_photo(public_url: str) -> None:
    """Best-effort removal of the underlying object (DB row is the truth)."""
    prefix = f"/storage/v1/object/public/{BUCKET}/"
    base = settings.supabase_url.rstrip("/")
    marker = f"{base}{prefix}"
    if not settings.supabase_url or not public_url.startswith(marker):
        return
    path = public_url[len(marker):]
    try:
        _client().storage.from_(BUCKET).remove([path])
    except Exception as exc:  # noqa: BLE001 - best-effort compensation
        logger.warning("Property photo cleanup failed for %s (%s)", path, type(exc).__name__)
