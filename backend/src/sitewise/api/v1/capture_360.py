"""360° capture API — authorized capture sessions, frames, processing jobs.

The mobile app captures; THIS backend owns the authoritative panorama. Every
route here passes through the same property-scoped predicate as the rest of
the property surface (``provider_scope.can_manage_listing``): the verified
listing owner, an assigned agent, or an administrator. Coarse role gating
plus MFA comes from ``require_property_owner``; the record-level rule comes
from the session's property, resolved per request — ownership is never
inherited from a stale ``owner_id`` comparison alone.

Storage transport lives in the storage gateway (signed direct uploads), so
these routes register metadata and enqueue work; they never proxy image
bytes.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import (
    ConflictError,
    NotFoundError,
    ValidationError,
)
from sitewise.db.session import get_db
from sitewise.dependencies import (
    AdminMfaUser,
    AuthenticatedUser,
    require_property_owner,
)
from sitewise.services import capture_session_service as svc
from sitewise.services import capture_storage
from sitewise.services.agent_inspection_policy import (
    agent_assignment,
    require_frame_backup,
    require_owner_published_view,
)

router = APIRouter()

DbSession = Annotated[Session, Depends(get_db)]
ProviderUser = Annotated[AuthenticatedUser, Depends(require_property_owner)]


def _session_json(record, confirmed: int) -> dict[str, Any]:
    return {
        "sessionId": str(record.id),
        "propertyId": record.property_id,
        "status": record.status,
        "captureMode": record.capture_mode,
        "capturePlanVersion": record.capture_plan_version,
        "expectedFrames": record.expected_frames,
        "confirmedFrames": confirmed,
        "createdAt": record.created_at.isoformat(),
        "updatedAt": record.updated_at.isoformat(),
    }


def _frame_json(record, created: bool) -> dict[str, Any]:
    return {
        "frameId": str(record.id),
        "sessionId": str(record.session_id),
        "targetIndex": record.target_index,
        "storagePath": record.storage_path,
        "checksumSha256": record.checksum_sha256,
        "imageWidth": record.image_width,
        "imageHeight": record.image_height,
        "capturePose": record.capture_pose,
        "capturedAt": record.captured_at.isoformat() if record.captured_at else None,
        "uploadStatus": record.upload_status,
        "created": created,
    }


def _job_json(record) -> dict[str, Any]:
    # Claim lease columns are worker internals and never leave the API.
    return {
        "jobId": str(record.id),
        "sessionId": str(record.session_id),
        "status": record.status,
        "progress": record.progress,
        "processingStage": record.processing_stage,
        "retryCount": record.retry_count,
        "errorMessage": record.error_message,
        "outputStoragePath": record.output_storage_path,
        "createdAt": record.created_at.isoformat(),
        "startedAt": record.started_at.isoformat() if record.started_at else None,
        "completedAt": (
            record.completed_at.isoformat() if record.completed_at else None
        ),
    }


def _panorama_json(record) -> dict[str, Any]:
    return {
        "panoramaId": str(record.panorama_id),
        "sessionId": str(record.session_id),
        "propertyId": record.property_id,
        "storagePath": record.storage_path,
        "format": record.format,
        "width": record.width,
        "height": record.height,
        "verificationStatus": record.verification_status,
        "publishedAt": (
            record.published_at.isoformat() if record.published_at else None
        ),
        "reviewedBy": str(record.reviewed_by) if record.reviewed_by else None,
        "reviewedAt": (
            record.reviewed_at.isoformat() if record.reviewed_at else None
        ),
        "reviewReason": record.review_reason,
        # Optional derived enhancement (default-off feature). Admin review
        # sees exactly which image versions exist for this record.
        "enhancement": (record.coverage_report or {}).get("enhancement"),
        "createdAt": record.created_at.isoformat(),
    }


class SessionCreate(BaseModel):
    property_id: int = Field(gt=0)
    capture_mode: str = "device_38"
    capture_plan_version: str | None = None
    # Optional stable key from the device's local station id. It lets a retry
    # after a lost create response resolve the SAME session row without
    # storing another column: the service derives a UUIDv5 from it.
    idempotency_key: str | None = Field(
        default=None, min_length=1, max_length=200,
        pattern=r"^[A-Za-z0-9._:-]+$",
    )


# Pose keys beyond the orientation quaternion that the capture manifest may
# carry — the stitcher consumes the normalizer's pre-crop geometry.
FRAME_POSE_EXTRAS = frozenset(
    {"sourceImageWidth", "sourceImageHeight", "cropOffsetX", "cropOffsetY"}
)


class FrameConfirm(BaseModel):
    target_index: int = Field(ge=1)
    storage_path: str = Field(min_length=1, max_length=512)
    checksum_sha256: str | None = Field(default=None, max_length=64)
    image_width: int | None = Field(default=None, gt=0)
    image_height: int | None = Field(default=None, gt=0)
    # The recorded device→world orientation [x, y, z, w], exactly as the
    # capture manifest writes it. The dict form may additionally carry the
    # capture manifest's source-geometry keys, which pass through to the
    # frame row verbatim instead of being stripped.
    capture_pose: list[float] | dict[str, float | int] | None = None
    captured_at: datetime | None = None

    @field_validator("checksum_sha256")
    @classmethod
    def _checksum_hex(cls, value: str | None) -> str | None:
        if value is None:
            return value
        cleaned = value.strip().lower()
        if len(cleaned) != 64 or any(c not in "0123456789abcdef" for c in cleaned):
            raise ValueError("checksum_sha256 must be a 64-character hex digest.")
        return cleaned

    @field_validator("capture_pose")
    @classmethod
    def _pose_shape(cls, value):
        if value is None:
            return value
        if isinstance(value, list):
            if len(value) != 4 or not all(isinstance(v, (int, float)) for v in value):
                raise ValueError("capture_pose must be [x, y, z, w].")
            return [float(v) for v in value]
        keys = set(value.keys())
        if not {"x", "y", "z", "w"} <= keys:
            raise ValueError("capture_pose must carry x, y, z, w.")
        if not keys <= {"x", "y", "z", "w"} | FRAME_POSE_EXTRAS:
            raise ValueError(
                "capture_pose accepts only x, y, z, w plus the manifest "
                f"keys {sorted(FRAME_POSE_EXTRAS)}."
            )
        pose: dict[str, Any] = {k: float(value[k]) for k in ("x", "y", "z", "w")}
        for key in sorted(keys & FRAME_POSE_EXTRAS):
            v = value[key]
            if isinstance(v, bool) or not isinstance(v, (int, float)):
                raise ValueError(f"capture_pose.{key} must be numeric.")
            pose[key] = int(v)
        return pose


def _validated_frame_path(
    record, session_id: uuid.UUID, storage_path: str
) -> str:
    """Only the session's own deterministic prefix may be registered.

    A frame pointing at another property's objects — even from an authorized
    caller — would let one capture contaminate another's stitch, so the path
    is pinned to ``properties/{property_id}/sessions/{session_id}/frames/``.
    """
    cleaned = storage_path.strip()
    prefix = f"properties/{record.property_id}/sessions/{session_id}/frames/"
    if not cleaned.startswith(prefix) or not cleaned.endswith(".jpg"):
        raise ValidationError(
            "storage_path must be inside this session's frames directory "
            f"({prefix}*.jpg)."
        )
    return cleaned


@router.post("/sessions")
def create_session(
    body: SessionCreate,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    try:
        agent_assignment(db, body.property_id, current, writable=True)
    except HTTPException as exc:
        # Queue recovery replays the original create request after a restart.
        # During review it may resolve the pinned session without creating one.
        if exc.status_code != 409 or body.idempotency_key is None:
            raise
        session_id = svc.capture_session_id_for_key(body.idempotency_key)
        existing = svc.get_capture_session(db, session_id)
        if (
            existing is None
            or str(existing.property_id) != str(body.property_id)
            or existing.capture_mode != body.capture_mode
            or (
                body.capture_plan_version is not None
                and existing.capture_plan_version != body.capture_plan_version
            )
        ):
            raise
        if not require_frame_backup(db, existing, current):
            raise
        svc.ensure_property_access(
            db, property_id=body.property_id, user_id=current.user_id, role=current.role
        )
        return _session_json(existing, svc.confirmed_frame_count(db, session_id))
    svc.ensure_property_access(
        db,
        property_id=body.property_id,
        user_id=current.user_id,
        role=current.role,
    )
    record = svc.create_capture_session(
        db,
        property_id=body.property_id,
        user_id=current.user_id,
        capture_mode=body.capture_mode,
        capture_plan_version=body.capture_plan_version,
        idempotency_key=body.idempotency_key,
    )
    return _session_json(record, svc.confirmed_frame_count(db, record.id))


@router.get("/sessions/{session_id}")
def get_session(
    session_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    record = svc.require_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    return _session_json(record, svc.confirmed_frame_count(db, session_id))


@router.post("/sessions/{session_id}/frames")
def confirm_frame(
    session_id: uuid.UUID,
    body: FrameConfirm,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    record = svc.require_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    append_only = require_frame_backup(db, record, current)
    if body.target_index > record.expected_frames:
        raise ValidationError(f"target_index must be between 1 and {record.expected_frames}.")
    path = _validated_frame_path(record, session_id, body.storage_path)
    if append_only and (
        body.checksum_sha256 is None
        or path != capture_storage.frame_object_path(record.property_id, str(session_id), body.target_index)
    ):
        raise ValidationError("A backup must identify its original target and checksum.")
    try:
        uploaded = capture_storage.object_exists(path)
    except capture_storage.CaptureStorageUnavailable as exc:
        raise _storage_unavailable(exc) from exc
    if not uploaded:
        # Confirming metadata for bytes nobody stored would create a manifest
        # the worker cannot stitch; the device retries the frame instead.
        raise ConflictError(
            "The frame object has not reached storage yet; upload it again."
        )
    # A repaired checksum (the client found a hashing mistake, or a stale
    # manifest row) may replace metadata ONLY when the stored bytes really
    # match it. Without this check a retake could silently relabel old bytes.
    if body.checksum_sha256 is not None:
        previous = next(
            (
                f for f in svc.list_capture_frames(db, session_id)
                if f.target_index == body.target_index
            ),
            None,
        )
        if append_only or (
            previous is not None
            and previous.checksum_sha256
            and previous.checksum_sha256.lower() != body.checksum_sha256.lower()
        ):
            try:
                stored = capture_storage.download(path)
            except capture_storage.ObjectMissing as exc:
                raise ConflictError("The original photograph has not reached storage.") from exc
            except capture_storage.CaptureStorageUnavailable as exc:
                raise _storage_unavailable(exc) from exc
            if not capture_storage.verify_checksum(stored, body.checksum_sha256):
                raise ConflictError(
                    "The stored photograph does not match the corrected "
                    "checksum; upload this frame again."
                )
    frame, created = svc.confirm_frame(
        db,
        session_id=session_id,
        target_index=body.target_index,
        storage_path=path,
        checksum_sha256=body.checksum_sha256,
        image_width=body.image_width,
        image_height=body.image_height,
        capture_pose=body.capture_pose,
        captured_at=body.captured_at,
        append_only=append_only,
    )
    return _frame_json(frame, created)


@router.get("/sessions/{session_id}/frames")
def list_frames(
    session_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    svc.require_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    frames = svc.list_capture_frames(db, session_id)
    return {
        "sessionId": str(session_id),
        "frames": [_frame_json(f, created=False) for f in frames],
    }


class UploadUrlRequest(BaseModel):
    targets: list[int] = Field(min_length=1)

    @field_validator("targets")
    @classmethod
    def _dedupe(cls, value: list[int]) -> list[int]:
        return sorted(set(value))


def _storage_unavailable(exc: Exception) -> HTTPException:
    # 503 with the gateway's client-facing reason; captures stay on the
    # device and every metadata row is untouched.
    return HTTPException(status_code=503, detail=str(exc))


@router.post("/sessions/{session_id}/upload-urls")
def issue_upload_urls(
    session_id: uuid.UUID,
    body: UploadUrlRequest,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    """Short-lived signed upload permissions for the session's own frames.

    The device PUTs each JPEG straight to Supabase Storage with the returned
    URL, then confirms the frame through POST /frames. Authorization happens
    HERE, once — the URL is pinned to this session's deterministic prefix and
    expires in minutes, so it cannot outlive the session or outspread its
    scope. Supabase signed uploads do not accept upsert flags: a repeat PUT
    of the SAME bytes answers 409 Duplicate, which IS the idempotent success
    the retry flow needs — the object is already stored.
    """
    record = svc.require_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    require_frame_backup(db, record, current)
    out_of_plan = [t for t in body.targets if t < 1 or t > record.expected_frames]
    if out_of_plan:
        raise ValidationError(
            f"targets must be between 1 and {record.expected_frames}."
        )
    urls = []
    try:
        for target in body.targets:
            signed = capture_storage.signed_upload_url(
                storage_path=capture_storage.frame_object_path(
                    record.property_id, str(session_id), target
                ),
                target_index=target,
            )
            urls.append(
                {
                    "targetIndex": signed.target_index,
                    "storagePath": signed.storage_path,
                    "uploadUrl": signed.upload_url,
                    "method": "PUT",
                    "headers": {"content-type": "image/jpeg"},
                    # Supabase signed uploads do not accept x-upsert: a
                    # repeat PUT of the SAME bytes answers 409 Duplicate,
                    # which IS the idempotent success the retry flow needs —
                    # the object is already stored.
                    "duplicateStatusIsSuccess": True,
                }
            )
    except capture_storage.CaptureStorageUnavailable as exc:
        raise _storage_unavailable(exc) from exc
    return {
        "sessionId": str(session_id),
        "expiresInSeconds": capture_storage.UPLOAD_URL_TTL_SECONDS,
        "uploads": urls,
    }


# --------------------------------------------------------------------------
# Device-generated panorama upload (capture_plan_version 2).
#
# Flutter stitches the 38 originals into one 2:1 equirectangular JPEG before
# any byte reaches the cloud, so the backend never enqueues a stitching job
# for these sessions. The panorama goes up FIRST through the same signed-URL
# transport as the frames; the confirmation endpoint is the only writer of
# the canonical ``fyp.panoramas`` row for this workflow, and it verifies the
# stored object end to end before any row exists.
# --------------------------------------------------------------------------


@router.post("/sessions/{session_id}/panorama/upload-url")
def issue_panorama_upload_url(
    session_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    """A short-lived signed upload permission for the session's panorama.

    Same authorization and transport as the frame upload URLs, pinned to the
    session's single deterministic panorama object.
    """
    record = svc.require_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    agent_assignment(db, int(record.property_id), current, writable=True)
    if str(record.owner_id) != str(current.user_id):
        raise HTTPException(
            status_code=403, detail="Capture session belongs to a different Agent."
        )
    path = capture_storage.panorama_object_path(record.property_id, str(session_id))
    try:
        signed = capture_storage.signed_upload_url(storage_path=path, target_index=0)
    except capture_storage.CaptureStorageUnavailable as exc:
        raise _storage_unavailable(exc) from exc
    return {
        "sessionId": str(session_id),
        "storagePath": signed.storage_path,
        "uploadUrl": signed.upload_url,
        "method": "PUT",
        "headers": {"content-type": "image/jpeg"},
        # A repeat PUT of the SAME panorama answers 409 Duplicate, which is
        # the idempotent success the retry flow needs.
        "duplicateStatusIsSuccess": True,
        "expiresInSeconds": capture_storage.UPLOAD_URL_TTL_SECONDS,
        "maxBytes": capture_storage.PANORAMA_MAX_BYTES,
    }


class PanoramaConfirm(BaseModel):
    storage_path: str = Field(min_length=1, max_length=512)
    # Required: the device hashed the exact bytes it PUT; confirmation
    # verifies the stored object against this digest before any row exists.
    checksum_sha256: str = Field(max_length=64)
    coverage_report: dict[str, Any] | None = None

    @field_validator("checksum_sha256")
    @classmethod
    def _checksum_hex(cls, value: str | None) -> str | None:
        if value is None:
            return value
        cleaned = value.strip().lower()
        if len(cleaned) != 64 or any(c not in "0123456789abcdef" for c in cleaned):
            raise ValueError("checksum_sha256 must be a 64-character hex digest.")
        return cleaned


def _validated_panorama_path(
    record, session_id: uuid.UUID, storage_path: str
) -> str:
    """Only the session's own single panorama object may be confirmed."""
    cleaned = storage_path.strip()
    expected = (
        f"properties/{record.property_id}/sessions/{session_id}/panorama.jpg"
    )
    if cleaned != expected:
        raise ValidationError(
            "storage_path must be this session's panorama object "
            f"({expected})."
        )
    return cleaned


def _decode_panorama(data: bytes) -> tuple[int, int]:
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


def _validate_reported_photo_coverage(report: dict[str, Any] | None, checksum: str) -> None:
    # Older captures have no coverage sidecar. Current captures can provide
    # device measurements tied to the exact JPEG, for review and validation.
    if report is None or "photo_coverage" not in report:
        return
    coverage = report["photo_coverage"]
    if not isinstance(coverage, dict) or coverage.get("panorama_sha256") != checksum:
        raise ValidationError("The coverage report does not match the uploaded panorama.")
    photo_percent = coverage.get("photo_coverage_percent")
    viewport_gap = coverage.get("worst_viewport_gap_percent")
    filled = coverage.get("gap_filled_pixels")
    if (
        type(photo_percent) not in (int, float)
        or not 99.5 <= photo_percent <= 100
        or type(viewport_gap) not in (int, float)
        or not 0 <= viewport_gap <= 25
        or type(filled) is not int
        or filled < 0
    ):
        raise ValidationError("The panorama coverage report requires retakes or a fresh stitch.")


@router.post("/sessions/{session_id}/panorama")
def confirm_panorama(
    session_id: uuid.UUID,
    body: PanoramaConfirm,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    """Verify and register the device-generated panorama.

    The full verification chain runs BEFORE any canonical row exists: the
    caller is the session's owning agent, the path is the session's own
    panorama object, the object has reached storage, its bytes match the
    device's SHA-256 digest, the payload decodes as a JPEG within the size
    and geometry limits (2:1 equirectangular). Only then is
    ``fyp.panoramas`` written and the session completed.
    """
    record = svc.require_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    agent_assignment(db, int(record.property_id), current, writable=True)
    if str(record.owner_id) != str(current.user_id):
        raise HTTPException(
            status_code=403, detail="Capture session belongs to a different Agent."
        )
    path = _validated_panorama_path(record, session_id, body.storage_path)
    try:
        try:
            if not capture_storage.object_exists(path):
                raise ConflictError(
                    "The panorama object has not reached storage yet; "
                    "upload it again."
                )
            data = capture_storage.download(path)
        except capture_storage.ObjectMissing as exc:
            raise ConflictError(
                "The panorama object has not reached storage yet; "
                "upload it again."
            ) from exc
    except capture_storage.CaptureStorageUnavailable as exc:
        raise _storage_unavailable(exc) from exc
    if len(data) > capture_storage.PANORAMA_MAX_BYTES:
        raise ValidationError(
            "The panorama exceeds the "
            f"{capture_storage.PANORAMA_MAX_BYTES // (1024 * 1024)} MB limit."
        )
    if not capture_storage.verify_checksum(data, body.checksum_sha256):
        raise ConflictError(
            "The stored panorama does not match its checksum; upload it again."
        )
    width, height = _decode_panorama(data)
    if height * 2 != width:
        raise ValidationError(
            "The panorama must be a 2:1 equirectangular image."
        )
    if not 512 <= width <= 8192:
        raise ValidationError(
            "The panorama width must be between 512 and 8192 pixels."
        )
    _validate_reported_photo_coverage(body.coverage_report, body.checksum_sha256)
    panorama = svc.confirm_device_panorama(
        db,
        session_id=session_id,
        storage_path=path,
        width=width,
        height=height,
        coverage_report=body.coverage_report,
    )
    return _panorama_json(panorama)


@router.get("/panoramas/{panorama_id}/view")
def view_panorama(
    panorama_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
    version: str = "original",
) -> dict[str, Any]:
    """An authorized temporary viewing URL for one stored panorama.

    ``version=enhanced`` serves the optional derived enhancement only when
    the record actually carries a completed one; the canonical original is
    always available. Neither version ever becomes a public URL.
    """
    panorama = svc.get_panorama(db, panorama_id)
    if panorama is None:
        raise NotFoundError("Panorama not found.")
    require_owner_published_view(db, int(panorama.property_id), current)
    svc.ensure_property_access(
        db,
        property_id=int(panorama.property_id),
        user_id=current.user_id,
        role=current.role,
    )
    storage_path = panorama.storage_path
    if version == "enhanced":
        enhancement = (panorama.coverage_report or {}).get("enhancement") or {}
        enhanced_path = enhancement.get("storage_path")
        if enhancement.get("status") != "completed" or not enhanced_path:
            raise NotFoundError(
                "No enhanced panorama exists for this record; request the "
                "original version."
            )
        storage_path = enhanced_path
    elif version != "original":
        raise ValidationError("version must be 'original' or 'enhanced'.")
    try:
        url = capture_storage.signed_view_url(storage_path)
    except capture_storage.CaptureStorageUnavailable as exc:
        raise _storage_unavailable(exc) from exc
    return {
        "panoramaId": str(panorama.panorama_id),
        "version": version,
        "viewUrl": url,
        "expiresInSeconds": capture_storage.VIEW_URL_TTL_SECONDS,
    }


@router.post("/sessions/{session_id}/process")
def request_processing(
    session_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    svc.require_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    record = svc.get_capture_session(db, session_id)
    if record is None: raise HTTPException(status_code=404, detail="Capture session not found.")
    agent_assignment(db, int(record.property_id), current, writable=True)
    if str(record.owner_id) != str(current.user_id):
        raise HTTPException(status_code=403, detail="Capture session belongs to a different Agent.")
    job, created = svc.request_processing(db, session_id=session_id)
    return {**_job_json(job), "created": created}


def _job_with_access(
    db: Session, job_id: uuid.UUID, current: AuthenticatedUser
):
    job = svc.get_job(db, job_id)
    if job is None:
        raise NotFoundError("Processing job not found.")
    svc.require_capture_session(
        db, session_id=job.session_id, user_id=current.user_id, role=current.role
    )
    return job


@router.get("/jobs/{job_id}")
def get_job(
    job_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    return _job_json(_job_with_access(db, job_id, current))


@router.post("/jobs/{job_id}/retry")
def retry_job(
    job_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    _job_with_access(db, job_id, current)
    job = svc.get_job(db, job_id)
    if job is None: raise HTTPException(status_code=404, detail="Processing job not found.")
    record = svc.get_capture_session(db, job.session_id)
    if record is None: raise HTTPException(status_code=404, detail="Capture session not found.")
    agent_assignment(db, int(record.property_id), current, writable=True)
    if str(record.owner_id) != str(current.user_id):
        raise HTTPException(status_code=403, detail="Capture session belongs to a different Agent.")
    return _job_json(svc.retry_job(db, job_id=job_id))


@router.get("/properties/{property_id}/panorama")
def property_panorama(
    property_id: int,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    svc.ensure_property_access(
        db,
        property_id=property_id,
        user_id=current.user_id,
        role=current.role,
    )
    require_owner_published_view(db, property_id, current)
    submitted_id = db.execute(
        text(
            "SELECT panorama_id FROM fyp.agent_listing_assignment "
            "WHERE listing_id = :pid AND workflow_status = 'submitted'"
        ),
        {"pid": property_id},
    ).scalar()
    if submitted_id is not None:
        panorama = svc.get_panorama(db, submitted_id)
        if panorama is None or str(panorama.property_id) != str(property_id):
            raise NotFoundError("The submitted panorama is unavailable.")
    else:
        panorama = svc.latest_property_panorama(db, property_id)
    if panorama is None:
        raise NotFoundError("No panorama exists for this property yet.")
    return _panorama_json(panorama)


# --------------------------------------------------------------------------
# Administrative review and publication of the canonical panorama.
#
# Stitching "done" is a technical state; only an administrator (with MFA,
# reusing the existing admin dependency) may approve, reject with a reason,
# publish, or unpublish. Reviewing never publishes and publishing never
# approves — the three decisions stay separate so a completed-but-unreviewed
# stitch can never reach an entrepreneur viewer.
# --------------------------------------------------------------------------

AdminUser = AdminMfaUser


class PanoramaReview(BaseModel):
    decision: str = Field(pattern="^(approved|rejected)$")
    reason: str | None = Field(default=None, max_length=2000)

    @field_validator("reason")
    @classmethod
    def _reason_required_on_rejection(cls, value, info):
        if info.data.get("decision") == "rejected" and not (value or "").strip():
            raise ValueError("A rejection reason is required.")
        return value


@router.get("/admin/panoramas")
def list_admin_panoramas(
    db: DbSession,
    _admin: AdminUser,
    verification_status: str | None = None,
) -> dict[str, Any]:
    """Review queue: every canonical panorama with its review metadata."""
    panoramas = svc.list_panoramas(db, verification_status=verification_status)
    return {"panoramas": [_panorama_json(p) for p in panoramas]}


@router.post("/admin/panoramas/{panorama_id}/review")
def review_admin_panorama(
    panorama_id: uuid.UUID,
    body: PanoramaReview,
    db: DbSession,
    admin: AdminUser,
) -> dict[str, Any]:
    record = svc.review_panorama(
        db,
        panorama_id=panorama_id,
        reviewer_id=admin.user_id,
        decision=body.decision,
        reason=body.reason,
    )
    return _panorama_json(record)


@router.post("/admin/panoramas/{panorama_id}/enhance")
def enhance_admin_panorama(
    panorama_id: uuid.UUID,
    db: DbSession,
    admin: AdminUser,
) -> dict[str, Any]:
    """Optional (default-off) enhancement producing a SEPARATE derived image.

    Never a second stitch and never a replacement: the canonical
    ``panorama.jpg`` stays untouched, the derived object is recorded in the
    panorama's metadata, and an enhancement failure leaves the valid original
    fully intact. Reviewers choose which version to view through the
    ``version`` query parameter on the panorama view endpoint.
    """
    record = svc.enhance_panorama(db, panorama_id=panorama_id)
    return _panorama_json(record)


@router.post("/admin/panoramas/{panorama_id}/publish")
def publish_admin_panorama(
    panorama_id: uuid.UUID,
    db: DbSession,
    admin: AdminUser,
) -> dict[str, Any]:
    record = svc.publish_panorama(
        db, panorama_id=panorama_id, publisher_id=admin.user_id
    )
    return _panorama_json(record)


@router.post("/admin/panoramas/{panorama_id}/unpublish")
def unpublish_admin_panorama(
    panorama_id: uuid.UUID,
    db: DbSession,
    _admin: AdminUser,
) -> dict[str, Any]:
    return _panorama_json(svc.unpublish_panorama(db, panorama_id=panorama_id))
