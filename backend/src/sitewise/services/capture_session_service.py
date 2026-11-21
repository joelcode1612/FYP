"""Capture-session application service.

One module owns the lifecycle of the canonical 360° records:
``fyp.capture_sessions`` → ``fyp.capture_frames`` → ``fyp.panorama_jobs`` →
``fyp.panoramas``. Routers never touch these tables directly, and the
stitching worker claims jobs through the same module, so authorization,
idempotency and the status vocabulary live in exactly one place.

Authorization is the SAME property-scoped predicate the rest of the property
surface uses (``provider_scope.can_manage_listing``): the verified owner of
the listing, an agent holding the ``public.agent_listing_assignment`` row,
or an administrator. A session is reachable only through its property —
never through ``owner_id`` equality alone, which would keep stale ownership
alive after a listing is reassigned.

Idempotency rules that the mobile client's retry/recovery depends on:

* confirming a frame twice for the same ``(session_id, target_index)``
  updates the stored metadata instead of failing or duplicating;
* requesting processing while a live (queued/processing) job exists returns
  that job instead of enqueueing a second one (enforced by the database with
  a partial unique index, not just by a check).
"""

from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ForbiddenError, NotFoundError, ValidationError
from sitewise.db.models.capture_360 import (
    CaptureFrame,
    CaptureSession,
    Panorama,
    PanoramaJob,
)
from sitewise.services import provider_scope

logger = logging.getLogger("sitewise.capture_session")

#: The three capture modes that must never be merged. The expected frame
#: count comes from the mode, not from the client: a client cannot create a
#: session that expects a different number of photographs than the plan it
#: claims to follow.
CAPTURE_MODES: dict[str, int] = {
    "device_38": 38,
    "arcore_26": 26,
    "arcore_tour_30": 30,
}

_SESSION_STATUSES = frozenset(
    {
        "capturing",
        "pending_upload",
        "uploading",
        "uploaded",
        "processing",
        "completed",
        "failed",
        "cancelled",
    }
)


def _now() -> datetime:
    return datetime.now(UTC)


def ensure_property_access(
    session: Session, *, property_id: int, user_id: Any, role: str
) -> None:
    """404 vs 403 for a property the caller may or may not manage."""
    found, allowed = provider_scope.can_manage_listing(
        session, listing_id=property_id, user_id=user_id, role=role
    )
    if not found:
        raise NotFoundError("Property not found.")
    if not allowed:
        raise ForbiddenError(
            "You can only manage property listings you own or are assigned to."
        )


def create_capture_session(
    session: Session,
    *,
    property_id: int,
    user_id: uuid.UUID,
    capture_mode: str,
    capture_plan_version: str | None,
) -> CaptureSession:
    if capture_mode not in CAPTURE_MODES:
        modes = ", ".join(sorted(CAPTURE_MODES))
        raise ValidationError(f"capture_mode must be one of: {modes}.")
    record = CaptureSession(
        property_id=str(property_id),
        owner_id=user_id,
        status="capturing",
        expected_frames=CAPTURE_MODES[capture_mode],
        capture_mode=capture_mode,
        capture_plan_version=(capture_plan_version or "1").strip() or "1",
    )
    session.add(record)
    session.commit()
    session.refresh(record)
    return record


def get_capture_session(
    session: Session, session_id: uuid.UUID
) -> CaptureSession | None:
    return session.get(CaptureSession, session_id)


def require_capture_session(
    session: Session, *, session_id: uuid.UUID, user_id: Any, role: str
) -> CaptureSession:
    """Resolve a session and enforce the property-scoped access rule."""
    record = session.get(CaptureSession, session_id)
    if record is None:
        raise NotFoundError("Capture session not found.")
    ensure_property_access(
        session,
        property_id=int(record.property_id),
        user_id=user_id,
        role=role,
    )
    return record


def confirmed_frame_count(session: Session, session_id: uuid.UUID) -> int:
    return int(
        session.execute(
            text(
                "SELECT count(*) FROM fyp.capture_frames "
                "WHERE session_id = :sid AND upload_status = 'confirmed'"
            ),
            {"sid": str(session_id)},
        ).scalar_one()
    )


def confirm_frame(
    session: Session,
    *,
    session_id: uuid.UUID,
    target_index: int,
    storage_path: str,
    checksum_sha256: str | None,
    image_width: int | None,
    image_height: int | None,
    capture_pose: dict[str, Any] | list[Any] | None,
    captured_at: datetime | None,
) -> tuple[CaptureFrame, bool]:
    """Register one confirmed frame; re-registration updates in place.

    Returns ``(frame, created)``. The target index must be inside the
    session's capture plan — a frame outside the plan can never participate
    in stitching, so accepting it would silently corrupt the manifest.
    """
    record_session = session.get(CaptureSession, session_id)
    if record_session is None:
        raise NotFoundError("Capture session not found.")
    if target_index < 1 or target_index > record_session.expected_frames:
        raise ValidationError(
            f"target_index must be between 1 and {record_session.expected_frames}."
        )
    frame = session.execute(
        text(
            "SELECT id FROM fyp.capture_frames "
            "WHERE session_id = :sid AND target_index = :t"
        ),
        {"sid": str(session_id), "t": target_index},
    ).first()
    created = frame is None
    if created:
        record = CaptureFrame(
            session_id=session_id,
            target_index=target_index,
            storage_path=storage_path,
        )
    else:
        record = session.get(CaptureFrame, frame[0])
        assert record is not None
    record.storage_path = storage_path
    record.checksum_sha256 = checksum_sha256
    record.image_width = image_width
    record.image_height = image_height
    record.capture_pose = capture_pose
    record.captured_at = captured_at or _now()
    record.upload_status = "confirmed"
    record.uploaded_at = _now()
    session.add(record)
    record_session.updated_at = _now()
    if confirmed_frame_count(session, session_id) >= record_session.expected_frames:
        record_session.status = "uploaded"
    session.add(record_session)
    session.commit()
    session.refresh(record)
    return record, created


def list_capture_frames(
    session: Session, session_id: uuid.UUID
) -> list[CaptureFrame]:
    frames = session.execute(
        text(
            "SELECT id FROM fyp.capture_frames WHERE session_id = :sid "
            "ORDER BY target_index"
        ),
        {"sid": str(session_id)},
    ).scalars().all()
    return [f for f in (session.get(CaptureFrame, fid) for fid in frames) if f]


def request_processing(
    session: Session, *, session_id: uuid.UUID
) -> tuple[PanoramaJob, bool]:
    """Enqueue stitching for a complete session (idempotent).

    ``(job, created)``. The manifest must be complete before a job can be
    queued: an incomplete session is a validation error, never a silent
    partial stitch. A live job is returned as-is so client retries cannot
    double-process one session.
    """
    record_session = session.get(CaptureSession, session_id)
    if record_session is None:
        raise NotFoundError("Capture session not found.")
    confirmed = confirmed_frame_count(session, session_id)
    if confirmed < record_session.expected_frames:
        raise ValidationError(
            "The capture session is incomplete: "
            f"{confirmed}/{record_session.expected_frames} frames confirmed."
        )
    live = session.execute(
        text(
            "SELECT id FROM fyp.panorama_jobs WHERE session_id = :sid "
            "AND status IN ('queued', 'processing')"
        ),
        {"sid": str(session_id)},
    ).first()
    if live is not None:
        job = session.get(PanoramaJob, live[0])
        assert job is not None
        return job, False
    job = PanoramaJob(session_id=session_id, status="queued")
    session.add(job)
    record_session.status = "processing"
    record_session.updated_at = _now()
    session.add(record_session)
    session.commit()
    session.refresh(job)
    return job, True


def get_job(session: Session, job_id: uuid.UUID) -> PanoramaJob | None:
    return session.get(PanoramaJob, job_id)


def retry_job(session: Session, *, job_id: uuid.UUID) -> PanoramaJob:
    """Requeue a failed job without discarding the confirmed frames."""
    job = session.get(PanoramaJob, job_id)
    if job is None:
        raise NotFoundError("Processing job not found.")
    if job.status != "error":
        raise ValidationError("Only a failed job can be retried.")
    job.status = "queued"
    job.retry_count += 1
    job.error_message = None
    job.progress = 0
    job.processing_stage = None
    job.claimed_at = None
    job.claimed_by = None
    job.started_at = None
    job.completed_at = None
    job.updated_at = _now()
    record_session = session.get(CaptureSession, job.session_id)
    if record_session is not None:
        record_session.status = "processing"
        record_session.updated_at = _now()
        session.add(record_session)
    session.add(job)
    session.commit()
    session.refresh(job)
    return job


def claim_next_job(
    session: Session, *, worker_id: str, stale_after_seconds: int
) -> PanoramaJob | None:
    """Claim one queued (or stalled) job with ``FOR UPDATE SKIP LOCKED``.

    Concurrent workers serialise on the row lock; a job whose claim has gone
    stale — worker crash, backend restart — is reclaimed after
    ``stale_after_seconds`` so an interrupted stitch recovers instead of
    being lost. Returns the job with the claim stamped, or ``None``.
    """
    row = session.execute(
        text(
            "SELECT id FROM fyp.panorama_jobs "
            "WHERE (status = 'queued') "
            "   OR (status = 'processing' AND (claimed_at IS NULL "
            "       OR claimed_at < now() - make_interval(secs => :stale))) "
            "ORDER BY created_at "
            "LIMIT 1 FOR UPDATE SKIP LOCKED"
        ),
        {"stale": stale_after_seconds},
    ).first()
    if row is None:
        return None
    job = session.get(PanoramaJob, row[0])
    if job is None:
        session.rollback()
        return None
    job.status = "processing"
    job.claimed_at = _now()
    job.claimed_by = worker_id
    if job.started_at is None:
        job.started_at = _now()
    job.updated_at = _now()
    session.add(job)
    session.commit()
    session.refresh(job)
    return job


def set_job_progress(
    session: Session, *, job_id: uuid.UUID, stage: str, progress: int
) -> None:
    session.execute(
        text(
            "UPDATE fyp.panorama_jobs SET processing_stage = :stage, "
            "progress = :progress, updated_at = now() WHERE id = :jid"
        ),
        {"stage": stage, "progress": int(progress), "jid": str(job_id)},
    )
    session.commit()


def complete_job(
    session: Session,
    *,
    job_id: uuid.UUID,
    output_storage_path: str,
    panorama_id: uuid.UUID,
) -> None:
    """Mark the job done ONLY after the panorama row exists and is stored."""
    job = session.get(PanoramaJob, job_id)
    if job is None:
        return
    job.status = "done"
    job.progress = 100
    job.output_storage_path = output_storage_path
    job.completed_at = _now()
    job.claimed_at = None
    job.claimed_by = None
    job.updated_at = _now()
    record_session = session.get(CaptureSession, job.session_id)
    if record_session is not None:
        record_session.status = "completed"
        record_session.updated_at = _now()
        session.add(record_session)
    session.add(job)
    session.commit()


def fail_job(session: Session, *, job_id: uuid.UUID, message: str) -> None:
    """Record the failure. Frames and session rows are never deleted here."""
    job = session.get(PanoramaJob, job_id)
    if job is None:
        return
    job.status = "error"
    job.error_message = message[:4000]
    job.completed_at = _now()
    job.claimed_at = None
    job.claimed_by = None
    job.updated_at = _now()
    record_session = session.get(CaptureSession, job.session_id)
    if record_session is not None:
        record_session.status = "failed"
        record_session.updated_at = _now()
        session.add(record_session)
    session.add(job)
    session.commit()


def latest_property_panorama(
    session: Session, property_id: int
) -> Panorama | None:
    rows = session.execute(
        text(
            "SELECT * FROM fyp.panoramas WHERE property_id = :pid "
            "ORDER BY created_at DESC LIMIT 1"
        ),
        {"pid": str(property_id)},
    ).mappings()
    row = rows.first()
    if row is None:
        return None
    return Panorama.model_validate(dict(row))


def get_panorama(
    session: Session, panorama_id: uuid.UUID
) -> Panorama | None:
    return session.get(Panorama, panorama_id)


def create_panorama(
    session: Session,
    *,
    session_id: uuid.UUID,
    property_id: str,
    storage_path: str,
    width: int,
    height: int,
    coverage_report: dict[str, Any] | None,
) -> Panorama:
    """Insert the canonical panorama row (one per session)."""
    record_session = session.get(CaptureSession, session_id)
    if record_session is None:
        raise NotFoundError("Capture session not found.")
    existing = session.execute(
        text("SELECT panorama_id FROM fyp.panoramas WHERE session_id = :sid"),
        {"sid": str(session_id)},
    ).first()
    if existing is not None:
        record = session.get(Panorama, existing[0])
        assert record is not None
        record.storage_path = storage_path
        record.width = width
        record.height = height
        record.coverage_report = coverage_report
        record.updated_at = _now()
        session.add(record)
        session.commit()
        session.refresh(record)
        return record
    record = Panorama(
        session_id=session_id,
        property_id=property_id,
        storage_path=storage_path,
        width=width,
        height=height,
        coverage_report=coverage_report,
    )
    session.add(record)
    session.commit()
    session.refresh(record)
    return record
