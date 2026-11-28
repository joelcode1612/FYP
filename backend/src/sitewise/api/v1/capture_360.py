"""360° capture API — authorized capture sessions, frames, processing jobs.

The mobile app captures; THIS backend owns the authoritative panorama. Every
route here passes through the same property-scoped predicate as the rest of
the property surface (``provider_scope.can_manage_listing``): the verified
listing owner, an assigned agent, or an administrator. Coarse role gating
plus MFA comes from ``require_property_owner``; the record-level rule comes
from the session's property, resolved per request — ownership is never
inherited from a stale ``owner_id`` comparison alone.

Adaptive frame transport is proxied through FastAPI: the device streams one
original JPEG to ``/frames/{target}/photo`` and this process owns the
Supabase write and checksum verification. Signed URLs remain for the legacy
device-panorama workflow and for viewing, never for active frame capture.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import tempfile
import threading
import uuid
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from pydantic import BaseModel, Field, ValidationError as PydanticValidationError, field_validator
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
from sitewise.domain import rbac
from sitewise.panorama.alignment import (
    FrameAlignmentInput,
    PairFrame,
    candidate_pairs,
    match_new_frame,
    pairs_for_frame,
)
from sitewise.panorama.sphere_math import Quat
from sitewise.services import capture_alignment_service
from sitewise.services import capture_session_service as svc
from sitewise.services import capture_storage, provider_scope
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


#: The user-facing stage for a job, derived from the worker's own stage text.
#: Order matters: the specific stages are tested before the generic ones, so a
#: frame download is never reported as "creating the panorama".
_STAGE_LABELS: tuple[tuple[str, str], ...] = (
    ("downloading", "Finishing photo uploads"),
    ("matching", "Checking image connections"),
    ("checking image alignment", "Checking image connections"),
    ("optimising all camera orientations", "Aligning photographs"),
    ("refining", "Aligning photographs"),
    ("measuring spherical coverage", "Checking spherical coverage"),
    ("verifying cross-ring", "Checking spherical coverage"),
    ("project", "Creating your 360° panorama"),
    ("blend", "Blending photographs"),
    ("seam", "Blending photographs"),
    ("verifying capture quality", "Verifying panorama quality"),
    ("uploading panorama", "Saving your panorama"),
    ("recording the canonical", "Saving your panorama"),
    ("loading capture manifest", "Preparing your photographs"),
)


def _stage_label(record) -> str:
    """The stage sentence for the mobile app.

    Derived from the stage the worker actually wrote, never invented: a job with
    no stage is queued, and a stage this table does not recognise keeps its own
    wording rather than being guessed at.
    """
    if record.status == "done":
        return "Panorama ready"
    if record.status in ("error", "failed"):
        return "Panorama processing needs a retry"
    raw = str(record.processing_stage or "").strip()
    if not raw:
        return "Your photos are saved. Panorama processing will begin shortly."
    lowered = raw.lower()
    for needle, label in _STAGE_LABELS:
        if needle in lowered:
            return label
    return "Creating your 360° panorama"


def _job_json(record) -> dict[str, Any]:
    # Worker stages and exception details stay in backend logs/database only;
    # the polling contract exposes a safe, stage-derived sentence and the one
    # decision the client needs to make: retry this stage, or wait.
    #
    # `failed` used to test for the literal "failed", but ``fail_job`` writes
    # "error", so a failed job reported no error message and no retry hint.
    failed = record.status in ("error", "failed")
    return {
        "jobId": str(record.id),
        "sessionId": str(record.session_id),
        "status": record.status,
        # A queued or processing job is NOT a failure. The client must not
        # offer "Retry" for either.
        "isTerminal": record.status in ("done", "error", "failed"),
        "isFailure": failed,
        "retryable": failed and record.retry_count < 3,
        "progress": record.progress,
        "processingStage": _stage_label(record),
        "retryCount": record.retry_count,
        "errorMessage": (
            "We couldn't prepare your 360° preview. Your photographs are saved — "
            "retry processing, or recapture manually if the photographs "
            "themselves are the problem."
            if failed
            else None
        ),
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


class PlanTarget(BaseModel):
    """One planned camera direction.

    ``target_id`` is the stable key every frame and match row is recorded
    against, so it is required and never re-derived from list position.
    """

    target_id: int = Field(gt=0)
    yaw_deg: float
    pitch_deg: float
    ring: str = Field(min_length=1, max_length=40)
    capture_order: int | None = Field(default=None, ge=1)


class PlanPayload(BaseModel):
    plan_version: str = Field(min_length=1, max_length=16)
    intrinsics: dict[str, Any] = Field(default_factory=dict)
    targets: list[PlanTarget] = Field(min_length=1)

    @field_validator("targets")
    @classmethod
    def _unique_targets(cls, value: list[PlanTarget]) -> list[PlanTarget]:
        ids = [target.target_id for target in value]
        if len(set(ids)) != len(ids):
            raise ValueError("target_id values must be unique.")
        return value


class SessionCreate(BaseModel):
    property_id: int = Field(gt=0)
    capture_mode: str = "device_adaptive"
    capture_plan_version: str | None = None
    # Optional stable key from the device's local station id. It lets a retry
    # after a lost create response resolve the SAME session row without
    # storing another column: the service derives a UUIDv5 from it.
    idempotency_key: str | None = Field(
        default=None, min_length=1, max_length=200,
        pattern=r"^[A-Za-z0-9._:-]+$",
    )
    # The adaptive plan, for adaptive capture modes. It arrives with the
    # session because it decides how many photographs the session expects:
    # storing the geometry and the count in one request is what keeps a
    # client from claiming one plan while the server waits for another.
    plan: PlanPayload | None = None


# Pose keys beyond the orientation quaternion that the capture manifest may
# carry — the stitcher consumes the normalizer's pre-crop geometry.
FRAME_POSE_EXTRAS = frozenset(
    {
        "sourceImageWidth", "sourceImageHeight", "cropOffsetX", "cropOffsetY",
        "targetYawDegrees", "targetPitchDegrees", "alignmentErrorDeg",
        "toleranceDeg", "quality", "captureTimestampNs", "focalLengthXPx",
        "focalLengthYPx", "principalPointXPx", "principalPointYPx",
        "cameraPosition",
    }
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
    capture_pose: list[float] | dict[str, Any] | None = None
    captured_at: datetime | None = None
    # False when the device did NOT upload because storage already held the
    # object (a resumed backup). The stored bytes are then read back and
    # compared with `checksum_sha256` before any row is written, so a stale
    # object from an interrupted attempt can never be registered as this
    # capture's photograph.
    uploaded: bool = True

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
            if key == "quality":
                if not isinstance(v, dict):
                    raise ValueError("capture_pose.quality must be an object.")
                pose[key] = v
                continue
            if key == "cameraPosition":
                if not isinstance(v, (list, tuple)) or len(v) != 3 or not all(
                    isinstance(n, (int, float)) and not isinstance(n, bool)
                    for n in v
                ):
                    raise ValueError("capture_pose.cameraPosition must have 3 numbers.")
                pose[key] = [float(n) for n in v]
                continue
            if isinstance(v, bool) or not isinstance(v, (int, float)):
                raise ValueError(f"capture_pose.{key} must be numeric.")
            pose[key] = int(v) if key in {
                "sourceImageWidth", "sourceImageHeight", "cropOffsetX",
                "cropOffsetY", "captureTimestampNs",
            } else float(v)
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


def _plan_geometry(plan: PlanPayload) -> list[dict[str, Any]]:
    """The stored shape of a plan: one row per target, sorted by target id.

    Sorting is deliberate. The geometry is compared and re-read by target id
    everywhere downstream (frames, match rows, the aligner's frame order), so
    the stored list must not depend on the order the device happened to
    serialise its capture sequence in.
    """
    return [
        {
            "targetId": target.target_id,
            "yawDeg": target.yaw_deg,
            "pitchDeg": target.pitch_deg,
            "ring": target.ring,
            "captureOrder": target.capture_order,
        }
        for target in sorted(plan.targets, key=lambda t: t.target_id)
    ]


@router.post("/sessions")
def create_session(
    body: SessionCreate,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    # The adaptive planner's count is derived from the measured lens. The
    # reference layout is 44 targets, but a narrow lens may legitimately need
    # more, so the plan payload is validated by bounds rather than by equality
    # with 44. The lower bound rejects a truncated plan; the upper bound keeps
    # a malformed client from opening an unbounded session.
    adaptive_count = len(body.plan.targets) if body.plan is not None else 0
    active_adaptive = (
        body.capture_mode == svc.ADAPTIVE_MODE
        and body.capture_plan_version == svc.ACTIVE_CAPTURE_PLAN_VERSION
        and body.plan is not None
        and body.plan.plan_version == svc.ACTIVE_CAPTURE_PLAN_VERSION
        and 24 <= adaptive_count <= 96
    )
    historical_retry = (
        body.capture_plan_version in {"1", "2", "3"}
        and body.idempotency_key is not None
        and body.plan is None
    )
    if not (active_adaptive or historical_retry):
        raise ValidationError(
            "New 360° capture sessions must use the adaptive five-ring plan "
            "(version 4) with its generated target geometry."
        )
    provider_scope.require_mutable_listing(
        db, listing_id=body.property_id, role=current.role
    )
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
            or (
                body.plan is not None
                and existing.expected_frames != len(body.plan.targets)
            )
        ):
            raise
        if not require_frame_backup(db, existing, current):
            raise
        svc.ensure_property_access(
            db, property_id=body.property_id, user_id=current.user_id, role=current.role
        )
        # A replay may resolve an existing session without creating one. It
        # must still prove the plan it is replaying is the SAME plan, not just
        # the same target count: otherwise a changed yaw/pitch could be
        # silently accepted against already-captured frames.
        if body.plan is not None:
            capture_alignment_service.save_capture_plan(
                db,
                session_id=session_id,
                geometry=_plan_geometry(body.plan),
                intrinsics=body.plan.intrinsics,
                plan_version=body.plan.plan_version,
            )
            refreshed = svc.get_capture_session(db, session_id)
            if refreshed is not None:
                existing = refreshed
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
        expected_frames=len(body.plan.targets) if body.plan is not None else None,
    )
    if body.plan is not None:
        capture_alignment_service.save_capture_plan(
            db,
            session_id=record.id,
            geometry=_plan_geometry(body.plan),
            intrinsics=body.plan.intrinsics,
            plan_version=body.plan.plan_version,
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


@router.get("/sessions/{session_id}/quality")
def get_session_quality(
    session_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    """The capture-quality evidence for one session, when it exists.

    Returns the panorama-level verification (coverage + seam checks run at
    panorama confirmation) and the registration audit (pairwise geometric
    consistency over the confirmed originals), exactly as stored inside the
    canonical row's ``coverage_report``. An absent ``quality`` block means
    the checks have not run yet — never a failure. Reading is authorized by
    the same property-scoped rule as every other session route.
    """
    record = svc.require_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    panorama = svc.panorama_for_session(db, session_id)
    quality = (panorama.coverage_report or {}).get("quality") if panorama else None
    return {
        "sessionId": str(session_id),
        "sessionStatus": record.status,
        "panoramaId": str(panorama.panorama_id) if panorama else None,
        "quality": quality,
    }


@router.put("/sessions/{session_id}/plan")
def save_plan(
    session_id: uuid.UUID,
    body: PlanPayload,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    """Persist the adaptive target geometry generated on the device.

    The plan is generated from the camera's measured field of view, so the
    backend cannot reproduce it and must not guess: target identifiers would
    drift between a capture and its resume, and every frame already recorded
    would point at the wrong direction. Writing a *different* plan over an
    existing one is refused for the same reason.
    """
    svc.require_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    geometry = _plan_geometry(body)
    try:
        capture_alignment_service.save_capture_plan(
            db,
            session_id=session_id,
            geometry=geometry,
            intrinsics=body.intrinsics,
            plan_version=body.plan_version,
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {
        "sessionId": str(session_id),
        "planVersion": body.plan_version,
        "targets": len(geometry),
    }


@router.get("/sessions/{session_id}/plan")
def read_plan(
    session_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    """The stored plan, or ``None`` for a session captured before plans were
    stored. A historical session keeps its original geometry."""
    svc.require_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    plan = capture_alignment_service.stored_plan(db, session_id)
    return {"sessionId": str(session_id), "plan": plan}


@router.get("/sessions/{session_id}/alignment")
def get_alignment(
    session_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    """The incremental matching graph: verified, weak and refused pairs."""
    svc.require_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    return capture_alignment_service.alignment_state(db, session_id)


class FrameMatchRequest(BaseModel):
    target_index: int = Field(gt=0)


@router.post("/sessions/{session_id}/match")
def match_frame(
    session_id: uuid.UUID,
    body: FrameMatchRequest,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    """Verify one freshly captured photograph against its overlapping neighbours.

    This is what lets the capture screen say "image connection verified" while
    the photographer is still in the room, instead of discovering a weak
    vertical connection after the session ends.

    Only the new frame and the photographs that actually overlap it are
    downloaded. The candidate set comes from recorded orientation and the
    camera footprint, so the endpoint does not need the whole session in
    memory to decide what to compare.
    """
    svc.require_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    frames = [
        frame
        for frame in svc.list_capture_frames(db, session_id)
        if frame.upload_status == "confirmed"
    ]
    target = next(
        (frame for frame in frames if frame.target_index == body.target_index), None
    )
    if target is None:
        raise HTTPException(status_code=404, detail="That photograph is not confirmed.")

    inputs = [_alignment_input_for(frame) for frame in frames]
    inputs = [item for item in inputs if item is not None]
    if not any(item.target_id == body.target_index for item in inputs):
        raise HTTPException(
            status_code=422,
            detail="That photograph has no usable orientation or dimensions.",
        )

    candidate_partners = _overlapping_partners(inputs, body.target_index)
    to_download = {body.target_index} | candidate_partners

    try:
        with tempfile.TemporaryDirectory(prefix="sitewise-match-") as work:
            work_dir = Path(work)
            for frame in frames:
                if frame.target_index not in to_download:
                    continue
                data = capture_storage.download(frame.storage_path)
                (work_dir / f"frame_{frame.target_index:02d}.jpg").write_bytes(data)
            resolved: list[FrameAlignmentInput] = []
            for item in inputs:
                if item.target_id in to_download:
                    resolved.append(
                        replace(
                            item,
                            image_path=str(
                                work_dir / f"frame_{item.target_id:02d}.jpg"
                            ),
                        )
                    )
                else:
                    resolved.append(item)
            new_frame = next(
                item for item in resolved if item.target_id == body.target_index
            )
            accepted = [
                item for item in resolved if item.target_id != body.target_index
            ]
            result = match_new_frame(
                new_frame,
                accepted,
                partner_ids=candidate_partners,
            )
    except capture_storage.CaptureStorageUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    payload = result.as_dict()
    capture_alignment_service.record_matches(
        db, session_id=session_id, matches=payload.get("matches", [])
    )
    if result.coverage:
        capture_alignment_service.save_coverage_contributions(
            db,
            session_id=session_id,
            contributions=result.coverage.per_frame_fraction,
        )
    return payload


def _alignment_input_for(frame):
    """Build the aligner's input for a stored frame, or ``None`` if unusable."""
    pose = frame.capture_pose
    raw = pose if isinstance(pose, dict) else None
    if raw is None and isinstance(pose, list) and len(pose) == 4:
        raw = dict(zip(("x", "y", "z", "w"), pose))
    if not raw or not all(key in raw for key in ("x", "y", "z", "w")):
        return None
    width = int(frame.image_width or raw.get("sourceImageWidth") or 0)
    height = int(frame.image_height or raw.get("sourceImageHeight") or 0)
    if width <= 0 or height <= 0:
        return None
    try:
        rotation = Quat(
            float(raw["x"]), float(raw["y"]), float(raw["z"]), float(raw["w"])
        ).normalized
    except (TypeError, ValueError):
        return None
    focal = raw.get("focalLengthYPx")
    try:
        focal = float(focal) if focal is not None else 0.0
    except (TypeError, ValueError):
        focal = 0.0
    if focal <= 0:
        focal = (height / 2.0) / math.tan(math.radians(65.0) / 2.0)
    return FrameAlignmentInput(
        target_id=frame.target_index,
        image_path="",
        rotation=rotation,
        width=width,
        height=height,
        focal=focal,
        cx=raw.get("principalPointXPx"),
        cy=raw.get("principalPointYPx"),
    )


def _overlapping_partners(
    inputs: list[FrameAlignmentInput], target_index: int
) -> set[int]:
    """Targets whose footprint overlaps [target_index], from orientation alone."""
    frames = [
        PairFrame(target_id=item.target_id, rotation=item.rotation, camera=item.camera)
        for item in inputs
    ]
    return {
        (pair.second if pair.first == target_index else pair.first)
        for pair in pairs_for_frame(candidate_pairs(frames), target_index)
    }


@router.post("/sessions/{session_id}/frames")
def confirm_frame(
    session_id: uuid.UUID,
    body: FrameConfirm,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    record = svc.require_mutable_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    if record.status == "cancelled":
        raise ConflictError("This capture attempt was cancelled.")
    append_only = require_frame_backup(db, record, current)
    if body.target_index > record.expected_frames:
        raise ValidationError(f"target_index must be between 1 and {record.expected_frames}.")
    path = _validated_frame_path(record, session_id, body.storage_path)
    require_original = append_only or record.capture_mode in svc.BACKEND_STITCH_MODES
    if require_original and (
        body.checksum_sha256 is None
        or path != capture_storage.frame_object_path(record.property_id, str(session_id), body.target_index)
    ):
        raise ValidationError("An original frame must identify its target and checksum.")
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
    # A frame the device did NOT upload (resumed backup) is always verified:
    # the object predates this confirmation, so its bytes must be proven to
    # be the photograph the device is registering.
    if body.checksum_sha256 is not None:
        previous = next(
            (
                f for f in svc.list_capture_frames(db, session_id)
                if f.target_index == body.target_index
            ),
            None,
        )
        if (
            require_original
            or not body.uploaded
            or (
                previous is not None
                and previous.checksum_sha256
                and previous.checksum_sha256.lower() != body.checksum_sha256.lower()
            )
        ):
            try:
                stored = capture_storage.download(path)
            except capture_storage.ObjectMissing as exc:
                raise ConflictError("The original photograph has not reached storage.") from exc
            except capture_storage.CaptureStorageUnavailable as exc:
                raise _storage_unavailable(exc) from exc
            if not capture_storage.verify_checksum(stored, body.checksum_sha256):
                raise ConflictError(
                    "The stored photograph does not match the supplied "
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
    # Once the session's manifest is complete, the registration audit runs
    # off-thread (frames confirmed → panorama usually already canonical).
    # Fire-and-forget and once-per-session-per-process: the audit downloads
    # the originals and merges evidence into the panorama row; a failure is
    # logged inside the service and never touches this response.
    if svc.confirmed_frame_count(db, session_id) >= record.expected_frames:
        try:
            from sitewise.services import panorama_quality_service

            panorama_quality_service.run_session_registration_audit_async(
                session_id
            )
        except Exception:  # noqa: BLE001 - the audit is best-effort evidence
            pass
    return _frame_json(frame, created)


#: Server-side frame writes are bounded. The device is already limited to one
#: active transfer; this is the second guard, for several agents or a retry
#: storm hitting the same process.
_FRAME_UPLOAD_SLOTS = threading.BoundedSemaphore(2)
_UPLOAD_CHUNK_BYTES = 1024 * 1024


def _persist_received_frame(file: UploadFile) -> tuple[Path, str, int]:
    """Stream an uploaded JPEG to a durable temporary file.

    The file is flushed and fsynced before any storage/DB work so a FastAPI
    acknowledgment never describes bytes that only exist in a request buffer.
    """
    temp = tempfile.NamedTemporaryFile(
        prefix="fyp-frame-", suffix=".jpg", delete=False
    )
    path = Path(temp.name)
    digest = hashlib.sha256()
    total = 0
    try:
        with temp:
            while True:
                chunk = file.file.read(_UPLOAD_CHUNK_BYTES)
                if not chunk:
                    break
                total += len(chunk)
                if total > capture_storage.FRAME_MAX_BYTES:
                    raise ValidationError(
                        "The photograph exceeds the maximum frame size."
                    )
                digest.update(chunk)
                temp.write(chunk)
            temp.flush()
            os.fsync(temp.fileno())
        if total <= 0:
            raise ValidationError("The uploaded photograph is empty.")
        return path, digest.hexdigest(), total
    except Exception:
        path.unlink(missing_ok=True)
        raise


@router.post("/sessions/{session_id}/frames/{target_index}/photo")
def upload_frame_photo(
    session_id: uuid.UUID,
    target_index: int,
    db: DbSession,
    current: ProviderUser,
    file: Annotated[UploadFile, File(...)],
    metadata: Annotated[str, Form(...)],
) -> dict[str, Any]:
    """Receive one original photograph, store it, and confirm the frame.

    This is the only photograph transport for the adaptive capture flow. The
    device no longer receives Supabase credentials or signed frame-upload URLs;
    FastAPI writes the object with the service-role client, reads it back to
    verify the digest, and only then writes ``fyp.capture_frames``.
    """
    record = svc.require_mutable_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    if record.status == "cancelled":
        raise ConflictError("This capture attempt was cancelled.")
    append_only = require_frame_backup(db, record, current)
    if target_index < 1 or target_index > record.expected_frames:
        raise ValidationError(
            f"target_index must be between 1 and {record.expected_frames}."
        )
    content_type = (file.content_type or "").lower()
    if content_type and not (
        content_type.startswith("image/") or content_type == "application/octet-stream"
    ):
        raise ValidationError("The frame must be uploaded as a JPEG image.")

    storage_path = capture_storage.frame_object_path(
        record.property_id, str(session_id), target_index
    )
    try:
        payload = json.loads(metadata)
    except (TypeError, ValueError) as exc:
        raise ValidationError("The frame metadata is not valid JSON.") from exc
    if not isinstance(payload, dict):
        raise ValidationError("The frame metadata must be a JSON object.")
    payload["target_index"] = target_index
    payload["storage_path"] = storage_path
    payload["uploaded"] = True
    try:
        body = FrameConfirm.model_validate(payload)
    except PydanticValidationError as exc:
        raise ValidationError(f"The frame metadata is invalid: {exc}") from exc

    path, checksum, byte_count = _persist_received_frame(file)
    try:
        # Decode before writing to storage: a truncated or non-JPEG body must
        # never create a frame row that the panorama worker cannot read.
        decoded = path.read_bytes()
        width, height = capture_storage.decode_panorama(decoded)
        if body.image_width is not None and body.image_width != width:
            raise ValidationError(
                "The photograph width does not match the capture metadata."
            )
        if body.image_height is not None and body.image_height != height:
            raise ValidationError(
                "The photograph height does not match the capture metadata."
            )

        previous = next(
            (
                frame
                for frame in svc.list_capture_frames(db, session_id)
                if frame.target_index == target_index
            ),
            None,
        )
        # Idempotent retry: the same bytes already confirmed and still present
        # in storage need no second upload or row update.
        if (
            previous is not None
            and previous.upload_status == "confirmed"
            and previous.checksum_sha256
            and previous.checksum_sha256.lower() == checksum
        ):
            try:
                if capture_storage.object_exists(storage_path):
                    result = _frame_json(previous, False)
                    result["uploadedBytes"] = byte_count
                    return result
            except capture_storage.CaptureStorageUnavailable as exc:
                raise _storage_unavailable(exc) from exc

        # Append-only backup may not replace a submitted original.
        if (
            append_only
            and previous is not None
            and previous.checksum_sha256
            and previous.checksum_sha256.lower() != checksum
        ):
            raise ConflictError(
                "A backed-up original cannot be replaced after submission."
            )

        with _FRAME_UPLOAD_SLOTS:
            try:
                capture_storage.upload_file(storage_path, path)
                stored = capture_storage.download(storage_path)
            except capture_storage.ObjectMissing as exc:
                raise ConflictError(
                    "The photograph did not reach storage; retry the frame."
                ) from exc
            except capture_storage.CaptureStorageUnavailable as exc:
                raise _storage_unavailable(exc) from exc
            if not capture_storage.verify_checksum(stored, checksum):
                raise ConflictError(
                    "The stored photograph does not match the received bytes; "
                    "retry the frame."
                )

        frame, created = svc.confirm_frame(
            db,
            session_id=session_id,
            target_index=target_index,
            storage_path=storage_path,
            checksum_sha256=checksum,
            image_width=width,
            image_height=height,
            capture_pose=body.capture_pose,
            captured_at=body.captured_at,
            append_only=append_only,
        )
        result = _frame_json(frame, created)
        result["uploadedBytes"] = byte_count
        return result
    finally:
        path.unlink(missing_ok=True)


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
    # Targets whose stored object must be REPLACED (a stale or corrupt object
    # for the same deterministic path). Everything else is create-only, so a
    # resume can never destroy bytes that are already correct.
    overwrite: list[int] = Field(default_factory=list)

    @field_validator("targets")
    @classmethod
    def _dedupe(cls, value: list[int]) -> list[int]:
        return sorted(set(value))

    @field_validator("overwrite")
    @classmethod
    def _dedupe_overwrite(cls, value: list[int]) -> list[int]:
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
    scope.

    Each target is resolved independently because a resumed backup is the
    normal case, not an error: Supabase Storage refuses to mint an upload
    token for a path that already holds an object (``409 Duplicate``), which
    used to abort the whole batch. An occupied path is therefore reported as
    ``alreadyStored`` with no URL — the device confirms the stored bytes
    instead of uploading them again — and only a target listed in
    ``overwrite`` receives an upsert URL that may replace the object.
    """
    record = svc.require_mutable_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    require_frame_backup(db, record, current)
    out_of_plan = [t for t in body.targets if t < 1 or t > record.expected_frames]
    if out_of_plan:
        raise ValidationError(
            f"targets must be between 1 and {record.expected_frames}."
        )
    overwrite = {
        t for t in body.overwrite if 1 <= t <= record.expected_frames
    }
    urls: list[dict[str, Any]] = []
    for target in body.targets:
        path = capture_storage.frame_object_path(
            record.property_id, str(session_id), target
        )
        entry: dict[str, Any] = {
            "targetIndex": target,
            "storagePath": path,
            "method": "PUT",
            "headers": {"content-type": "image/jpeg"},
            # A repeat PUT of the SAME bytes answers 409 Duplicate, which IS
            # the idempotent success the retry flow needs — the object is
            # already stored.
            "duplicateStatusIsSuccess": True,
            "alreadyStored": False,
            "uploadUrl": None,
        }
        replace = target in overwrite
        # Create-only first: the storage API itself reports an occupied path
        # (``409 Duplicate``), so one request both mints the token and tells
        # us whether the bytes are already there — no separate existence
        # probe, and no window between the two.
        try:
            signed = capture_storage.signed_upload_url(
                storage_path=path, target_index=target, upsert=replace
            )
        except capture_storage.ObjectAlreadyStored:
            # The stored object wins; the device verifies its bytes at
            # confirmation instead of uploading them again.
            entry["alreadyStored"] = True
            urls.append(entry)
            continue
        except capture_storage.CaptureStorageUnavailable as exc:
            raise _storage_unavailable(exc) from exc
        entry["uploadUrl"] = signed.upload_url
        urls.append(entry)
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


def _require_replaceable_panorama(db: Session, session_id: uuid.UUID) -> None:
    """An approved or published tour must never be overwritten in place.

    ``confirm_device_panorama`` already refuses to re-point a published row,
    but that check runs AFTER the bytes are stored — too late, the evidence
    would already be gone. This guard runs before an upsert URL is issued.
    """
    row = db.execute(
        text(
            "SELECT verification_status, published_at FROM fyp.panoramas "
            "WHERE session_id = :sid"
        ),
        {"sid": str(session_id)},
    ).mappings().first()
    if row is None:
        return
    if row["published_at"] is not None:
        raise ConflictError(
            "This 360° tour is already published; unpublish it before "
            "replacing the panorama."
        )
    if row["verification_status"] == "approved":
        raise ConflictError(
            "This 360° panorama has been approved; it cannot be replaced by "
            "a new upload."
        )


@router.post("/sessions/{session_id}/panorama/upload-url")
def issue_panorama_upload_url(
    session_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
    overwrite: bool = False,
) -> dict[str, Any]:
    """A short-lived signed upload permission for the session's panorama.

    Same authorization and transport as the frame upload URLs, pinned to the
    session's single deterministic panorama object. When the object already
    exists and no replacement is requested, the response reports
    ``alreadyStored`` with no URL: the device confirms the stored panorama it
    produced, which is exactly the resumed-upload case. ``overwrite=true`` is
    the explicit replacement path and is refused for an approved or published
    tour.
    """
    record = svc.require_mutable_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    agent_assignment(db, int(record.property_id), current, writable=True)
    if str(record.owner_id) != str(current.user_id):
        raise HTTPException(
            status_code=403, detail="Capture session belongs to a different Agent."
        )
    path = capture_storage.panorama_object_path(record.property_id, str(session_id))
    if overwrite:
        _require_replaceable_panorama(db, session_id)
    try:
        signed = capture_storage.signed_upload_url(
            storage_path=path, target_index=0, upsert=overwrite
        )
    except capture_storage.ObjectAlreadyStored:
        # The panorama from an interrupted attempt is already stored. The
        # device confirms the object it produced; nothing is re-uploaded.
        return {
            "sessionId": str(session_id),
            "storagePath": path,
            "uploadUrl": None,
            "method": "PUT",
            "headers": {"content-type": "image/jpeg"},
            "alreadyStored": True,
            "duplicateStatusIsSuccess": True,
            "expiresInSeconds": capture_storage.UPLOAD_URL_TTL_SECONDS,
            "maxBytes": capture_storage.PANORAMA_MAX_BYTES,
        }
    except capture_storage.CaptureStorageUnavailable as exc:
        raise _storage_unavailable(exc) from exc
    return {
        "sessionId": str(session_id),
        "storagePath": signed.storage_path,
        "uploadUrl": signed.upload_url,
        "method": "PUT",
        "headers": {"content-type": "image/jpeg"},
        "alreadyStored": False,
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


class PanoramaAcceptRequest(BaseModel):
    """The active reference the Agent saw when recapture began.

    Supplying it turns the acceptance into a compare-and-swap: if another
    device accepted a different candidate meanwhile, this request fails instead
    of silently replacing the newer active panorama.
    """

    expected_active_panorama_id: uuid.UUID | None = None


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
    record = svc.require_mutable_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    if record.capture_mode in svc.BACKEND_STITCH_MODES:
        raise ValidationError("A backend-first session must use its worker-generated panorama.")
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
    width, height = capture_storage.decode_panorama(data)
    if height * 2 != width:
        raise ValidationError(
            "The panorama must be a 2:1 equirectangular image."
        )
    if not 512 <= width <= 8192:
        raise ValidationError(
            "The panorama width must be between 512 and 8192 pixels."
        )
    _validate_reported_photo_coverage(body.coverage_report, body.checksum_sha256)
    # Panorama-level quality verification (coverage + visible-seam checks):
    # one downscaled decode of the bytes already verified above, merged
    # ADDITIVELY into the stored coverage report. The verification never
    # fails the confirmation and never alters the panorama bytes — a check
    # error simply leaves the device's report untouched.
    merged_report = dict(body.coverage_report or {})
    merged_report["submitted_image_sha256"] = body.checksum_sha256.lower()
    try:
        from sitewise.services import panorama_quality_service

        quality = panorama_quality_service.run_panorama_quality(data)
        merged_report = panorama_quality_service.merge_quality_into_report(
            merged_report, quality
        )
    except Exception:  # noqa: BLE001 - verification is evidence, never a gate
        pass
    panorama = svc.confirm_device_panorama(
        db,
        session_id=session_id,
        storage_path=path,
        width=width,
        height=height,
        coverage_report=merged_report,
    )
    return _panorama_json(panorama)


@router.post("/sessions/{session_id}/panoramas/{panorama_id}/accept")
def accept_panorama_candidate(
    session_id: uuid.UUID,
    panorama_id: uuid.UUID,
    body: PanoramaAcceptRequest,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    """Agent accepts one generated candidate as the active inspection panorama.

    Processing/storage confirmation only registered the candidate. This route is
    the explicit promotion step; it verifies the stored object and the
    completed job, then updates the assignment under a row lock. It never
    changes a published panorama reference.
    """
    record = svc.require_mutable_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    assignment = agent_assignment(db, int(record.property_id), current, writable=True)
    panorama = svc.get_panorama(db, panorama_id)
    if panorama is None or panorama.session_id != session_id:
        raise NotFoundError("Candidate panorama not found for this capture.")
    if panorama.published_at is not None:
        raise ConflictError("A published panorama cannot be accepted as a draft.")
    if not panorama.coverage_report:
        raise ConflictError(
            "The candidate has no quality verification report and cannot be accepted."
        )
    try:
        if not capture_storage.object_exists(panorama.storage_path):
            raise ConflictError(
                "The candidate panorama object is not in storage yet."
            )
        data = capture_storage.download(panorama.storage_path)
    except capture_storage.ObjectMissing as exc:
        raise ConflictError(
            "The candidate panorama object is not in storage yet."
        ) from exc
    except capture_storage.CaptureStorageUnavailable as exc:
        raise _storage_unavailable(exc) from exc
    width, height = capture_storage.decode_panorama(data)
    if height * 2 != width:
        raise ValidationError(
            "The candidate panorama is not a 2:1 equirectangular image."
        )
    accepted, job_id = svc.accept_panorama_candidate(
        db,
        session_id=session_id,
        panorama_id=panorama_id,
        agent_id=int(assignment["agent_id"]),
        expected_active_panorama_id=body.expected_active_panorama_id,
    )
    result = _panorama_json(accepted)
    result["activePanoramaId"] = str(accepted.panorama_id)
    result["jobId"] = str(job_id) if job_id is not None else None
    result["accepted"] = True
    return result


@router.post("/sessions/{session_id}/cancel")
def cancel_capture(
    session_id: uuid.UUID,
    db: DbSession,
    current: ProviderUser,
) -> dict[str, Any]:
    """Cancel a candidate attempt without touching the active panorama."""
    record = svc.require_mutable_capture_session(
        db, session_id=session_id, user_id=current.user_id, role=current.role
    )
    agent_assignment(db, int(record.property_id), current, writable=True)
    cancelled = svc.cancel_capture_session(db, session_id=session_id)
    return _session_json(
        cancelled,
        svc.confirmed_frame_count(db, cancelled.id),
    )


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
    svc.require_mutable_capture_session(
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
    job = _job_with_access(db, job_id, current)
    payload = _job_json(job)
    if job.status == "done":
        panorama = svc.panorama_for_session(db, job.session_id)
        if panorama is not None and panorama.storage_path == job.output_storage_path:
            payload["panoramaId"] = str(panorama.panorama_id)
    return payload


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
    if rbac.can_administer_users(current.role):
        if current.assurance_level != rbac.REQUIRED_STAFF_AAL:
            raise HTTPException(403, "Administrator MFA is required.")
        row = db.execute(text("""
            SELECT p.panorama_id, cs.owner_id, a.agent_id
            FROM fyp.agent_listing_assignment a
            JOIN fyp.panoramas p ON p.panorama_id=a.panorama_id
            JOIN fyp.capture_sessions cs ON cs.id=p.session_id
            WHERE a.listing_id=:pid AND a.workflow_status='submitted'
              AND p.property_id=CAST(:pid AS text) AND cs.property_id=p.property_id
              AND cs.status='completed' AND p.created_at<=a.submitted_at
              AND (cs.capture_plan_version='2' OR EXISTS (
                SELECT 1 FROM fyp.panorama_jobs j WHERE j.session_id=cs.id AND j.status='done'
              ))
              AND p.storage_path IS NOT NULL AND p.verification_status<>'rejected'
        """), {"pid": property_id}).mappings().first()
        if row is None:
            raise NotFoundError("No submitted inspection panorama is available.")
        from sitewise.services.property_verification_service import AdminPropertyReviewService

        AdminPropertyReviewService.verify_panorama_agent(row["agent_id"], row["owner_id"])
        return _panorama_json(svc.get_panorama(db, row["panorama_id"]))
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


def _require_standalone_panorama(db: Session, panorama_id: uuid.UUID) -> None:
    current = svc.get_panorama(db, panorama_id)
    if current is None:
        raise NotFoundError("Panorama not found.")
    if not str(current.property_id).isdigit():
        return
    pid = int(current.property_id)
    db.execute(text("SELECT id FROM fyp.rental_properties WHERE id=:id FOR UPDATE"), {"id": pid})
    if db.execute(text("""
        SELECT 1 FROM fyp.agent_listing_assignment WHERE listing_id=:id
        UNION ALL SELECT 1 FROM fyp.property_verification WHERE property_id=:id LIMIT 1
    """), {"id": pid}).first():
        raise ConflictError("Use the consolidated Admin property decision for this panorama.")


@router.post("/admin/panoramas/{panorama_id}/review")
def review_admin_panorama(
    panorama_id: uuid.UUID,
    body: PanoramaReview,
    db: DbSession,
    admin: AdminUser,
) -> dict[str, Any]:
    _require_standalone_panorama(db, panorama_id)
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
    _require_standalone_panorama(db, panorama_id)
    record = svc.enhance_panorama(db, panorama_id=panorama_id)
    return _panorama_json(record)


@router.post("/admin/panoramas/{panorama_id}/publish")
def publish_admin_panorama(
    panorama_id: uuid.UUID,
    db: DbSession,
    admin: AdminUser,
) -> dict[str, Any]:
    _require_standalone_panorama(db, panorama_id)
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
    _require_standalone_panorama(db, panorama_id)
    return _panorama_json(svc.unpublish_panorama(db, panorama_id=panorama_id))
