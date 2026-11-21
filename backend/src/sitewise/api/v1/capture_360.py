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
from sqlmodel import Session

from sitewise.core.exceptions import (
    ConflictError,
    NotFoundError,
    ValidationError,
)
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, require_property_owner
from sitewise.services import capture_session_service as svc
from sitewise.services import capture_storage
from sitewise.services.agent_inspection_policy import agent_assignment, require_owner_published_view

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
        "createdAt": record.created_at.isoformat(),
    }


class SessionCreate(BaseModel):
    property_id: int = Field(gt=0)
    capture_mode: str = "device_38"
    capture_plan_version: str | None = None


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
    agent_assignment(db, body.property_id, current, writable=True)
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
    )
    return _session_json(record, 0)


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
    agent_assignment(db, int(record.property_id), current, writable=True)
    if str(record.owner_id) != str(current.user_id):
        raise HTTPException(status_code=403, detail="Capture session belongs to a different Agent.")
    path = _validated_frame_path(record, session_id, body.storage_path)
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
    agent_assignment(db, int(record.property_id), current, writable=True)
    if str(record.owner_id) != str(current.user_id):
        raise HTTPException(status_code=403, detail="Capture session belongs to a different Agent.")
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


@router.get("/panoramas/{panorama_id}/view")
def view_panorama(
    panorama_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    """An authorized temporary viewing URL for one stored panorama."""
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
    try:
        url = capture_storage.signed_view_url(panorama.storage_path)
    except capture_storage.CaptureStorageUnavailable as exc:
        raise _storage_unavailable(exc) from exc
    return {
        "panoramaId": str(panorama.panorama_id),
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
    panorama = svc.latest_property_panorama(db, property_id)
    if panorama is None:
        raise NotFoundError("No panorama exists for this property yet.")
    return _panorama_json(panorama)
