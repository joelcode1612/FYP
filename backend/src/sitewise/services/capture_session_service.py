"""Capture-session application service.

One module owns the lifecycle of the canonical 360° records:
``fyp.capture_sessions`` → ``fyp.capture_frames`` → ``fyp.panorama_jobs`` →
``fyp.panoramas``. Routers never touch these tables directly, and the
stitching worker claims jobs through the same module, so authorization,
idempotency and the status vocabulary live in exactly one place.

Authorization is the SAME property-scoped predicate the rest of the property
surface uses (``provider_scope.can_manage_listing``): the verified owner of
the listing, an agent holding the ``fyp.agent_listing_assignment`` row,
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
from sqlalchemy.exc import IntegrityError
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.core.exceptions import (
    ConflictError,
    ForbiddenError,
    NotFoundError,
    ValidationError,
)
from sitewise.db.models.capture_360 import (
    CaptureFrame,
    CaptureSession,
    Panorama,
    PanoramaJob,
)
from sitewise.services import capture_storage
from sitewise.services import provider_scope

logger = logging.getLogger("sitewise.capture_session")

#: Capture modes that must never be merged. The expected frame count comes
#: from the mode, not from the client: a client cannot create a session that
#: expects a different number of photographs than the plan it claims to
#: follow. ``device_38_panorama`` is the Flutter-stitched workflow: the same
#: 38-target plan, but the panorama is produced on the device and confirmed
#: through the panorama endpoints instead of a Python stitching job.
BACKEND_38_MODE = "device_38_backend"

#: The adaptive workflow. Its target count is not a constant: the five-ring
#: geometry is generated on the device from the camera's measured field of
#: view, so two devices in the same room can legitimately need 40 and 48
#: photographs. The plan therefore travels with the session and supplies
#: ``expected_frames`` — but it is supplied exactly once, at creation, and
#: ``capture_alignment_service.save_capture_plan`` refuses to replace it
#: afterwards. The invariant the fixed table enforced ("a client cannot claim
#: a plan whose length differs from the photographs it expects") is preserved:
#: the count and the geometry are now written together instead of the count
#: being read from a table that no longer exists.
ADAPTIVE_MODE = "device_adaptive"
#: The adaptive five-ring planner is version 4. Its reference layout is 44
#: targets (12/12/12 at 0°/±30° plus 4+4 at ±65°), but the plan payload is the
#: authority for the count: a measured narrow lens may add positions.
ACTIVE_CAPTURE_PLAN_VERSION = "4"
ACTIVE_CAPTURE_TARGET_COUNT = 44

#: Modes whose expected frame count comes from the stored plan. The ``0`` in
#: the table is a sentinel, never a usable count: ``create_capture_session``
#: rejects an adaptive session that arrives without its plan.
ADAPTIVE_MODES = frozenset({ADAPTIVE_MODE})

CAPTURE_MODES: dict[str, int] = {
    BACKEND_38_MODE: 38,
    "device_38": 38,
    "device_38_panorama": 38,
    "device_56": 56,
    "device_56_backend": 56,
    "arcore_26": 26,
    "arcore_tour_30": 30,
    ADAPTIVE_MODE: 0,
}

#: Modes whose panorama is produced by the backend worker from the uploaded
#: originals. The adaptive workflow belongs here: its whole point is that the
#: rotations are solved jointly on the server, where every original is
#: available at full resolution and the global bundle adjustment can run.
BACKEND_STITCH_MODES = frozenset({BACKEND_38_MODE, "device_56_backend", ADAPTIVE_MODE})

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


def capture_session_id_for_key(key: str) -> uuid.UUID:
    """Derive a stable row id from the client's capture idempotency key.

    UUIDv5 lives entirely in application code: the canonical schema keeps its
    existing UUID primary key and needs no extra column or new table.
    """
    return uuid.uuid5(uuid.NAMESPACE_URL, f"sitewise.capture.v1/{key}")


def _same_capture(
    record: CaptureSession,
    *,
    property_id: int,
    user_id: uuid.UUID,
    capture_mode: str,
    expected_frames: int,
) -> bool:
    return (
        str(record.property_id) == str(property_id)
        and str(record.owner_id) == str(user_id)
        and record.capture_mode == capture_mode
        # Compared against the count this request is about to write, not
        # against the mode table: for an adaptive capture the table holds a
        # sentinel and the plan is the only authority.
        and record.expected_frames == expected_frames
    )


def create_capture_session(
    session: Session,
    *,
    property_id: int,
    user_id: uuid.UUID,
    capture_mode: str,
    capture_plan_version: str | None,
    idempotency_key: str | None = None,
    expected_frames: int | None = None,
) -> CaptureSession:
    """Create a session, or return the one a retried request already created.

    A lost response is the common case on mobile: without this key the same
    completed capture could create a second session and a second job. The
    caller's local station id supplies the key; an existing row is returned
    only when its property, owner and capture plan still agree.

    [expected_frames] carries the adaptive plan's target count. It is required
    for an adaptive mode and ignored for the fixed-count modes, which keep
    reading their count from [CAPTURE_MODES].
    """
    version = str(capture_plan_version or "").strip()
    fixed_id = (
        capture_session_id_for_key(idempotency_key) if idempotency_key else None
    )
    # Versions 1–3 are historical fixed layouts. They may be resumed only by an
    # idempotent retry of the exact session already on record and can never
    # create a new session. Version 4 is the active adaptive plan.
    if version in {"1", "2", "3"}:
        existing = session.get(CaptureSession, fixed_id) if fixed_id is not None else None
        expected_count = (
            expected_frames
            if capture_mode in ADAPTIVE_MODES
            else CAPTURE_MODES.get(capture_mode)
        )
        if (
            existing is not None
            and existing.capture_plan_version == version
            and int(existing.expected_frames or 0) == int(expected_count or 0)
            and str(existing.property_id) == str(property_id)
            and str(existing.owner_id) == str(user_id)
            and existing.capture_mode == capture_mode
            and expected_count is not None
        ):
            return existing
        raise ValidationError("A historical capture may only resume its matching saved session.")
    if capture_mode != ADAPTIVE_MODE or version != ACTIVE_CAPTURE_PLAN_VERSION:
        raise ValidationError(
            "New 360° capture sessions must use the adaptive five-ring plan (version 4)."
        )
    if capture_mode not in CAPTURE_MODES:
        modes = ", ".join(sorted(CAPTURE_MODES))
        raise ValidationError(f"capture_mode must be one of: {modes}.")
    if capture_mode in ADAPTIVE_MODES:
        if not expected_frames or expected_frames < 1:
            raise ValidationError(
                "An adaptive capture session must be created with the plan it "
                "will capture; the target count cannot be assumed."
            )
        frame_count = expected_frames
    else:
        frame_count = CAPTURE_MODES[capture_mode]
    # capture_sessions.property_id is legacy TEXT with no FK, so a bad or
    # deleted property would otherwise create an orphan capture session.
    # Validate the typed id against the canonical table before inserting.
    if property_id <= 0 or session.execute(
        text("SELECT 1 FROM fyp.rental_properties WHERE id = :pid"),
        {"pid": property_id},
    ).scalar_one_or_none() is None:
        raise ValidationError("Capture session requires an existing property.")
    if fixed_id is not None:
        existing = session.get(CaptureSession, fixed_id)
        if existing is not None:
            if not _same_capture(
                existing,
                property_id=property_id,
                user_id=user_id,
                capture_mode=capture_mode,
                expected_frames=frame_count,
            ):
                raise ConflictError(
                    "The capture idempotency key belongs to a different "
                    "property, agent or capture plan."
                )
            return existing
    record = CaptureSession(
        id=fixed_id or uuid.uuid4(),
        property_id=str(property_id),
        owner_id=user_id,
        status="capturing",
        expected_frames=frame_count,
        capture_mode=capture_mode,
        capture_plan_version=version,
    )
    session.add(record)
    try:
        session.commit()
    except IntegrityError:
        # Two requests with the same key raced. The loser reads the winner's
        # row instead of failing the capture; a genuinely different capture
        # cannot land on this id because the key is derived from its identity.
        session.rollback()
        if fixed_id is None:
            raise
        existing = session.get(CaptureSession, fixed_id)
        if existing is None or not _same_capture(
            existing,
            property_id=property_id,
            user_id=user_id,
            capture_mode=capture_mode,
            expected_frames=frame_count,
        ):
            raise ConflictError(
                "The capture idempotency key belongs to a different property, "
                "agent or capture plan."
            ) from None
        return existing
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


def require_mutable_capture_session(
    session: Session, *, session_id: uuid.UUID, user_id: Any, role: str
) -> CaptureSession:
    """Read a session for a write, re-checking the property's current status."""
    record = require_capture_session(
        session, session_id=session_id, user_id=user_id, role=role
    )
    provider_scope.require_mutable_listing(
        session, listing_id=int(record.property_id), role=role
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
    append_only: bool = False,
) -> tuple[CaptureFrame, bool]:
    """Register one confirmed frame; re-registration updates in place.

    Returns ``(frame, created)``. The target index must be inside the
    session's capture plan — a frame outside the plan can never participate
    in stitching, so accepting it would silently corrupt the manifest.
    """
    record_session = session.get(
        CaptureSession, session_id, populate_existing=True, with_for_update=True
    )
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
        if append_only:
            if record.storage_path != storage_path or record.checksum_sha256 != checksum_sha256:
                raise ConflictError("A backed-up original cannot be replaced after submission.")
            return record, False
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
    if (
        record_session.status != "completed"
        and confirmed_frame_count(session, session_id)
        >= record_session.expected_frames
    ):
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
    record_session = session.get(CaptureSession, session_id, with_for_update=True)
    if record_session is None:
        raise NotFoundError("Capture session not found.")
    if record_session.status == "cancelled":
        raise ValidationError("A cancelled capture session cannot be processed.")
    if record_session.capture_mode in BACKEND_STITCH_MODES:
        frames = list_capture_frames(session, session_id)
        ready_targets = {
            frame.target_index for frame in frames
            if frame.upload_status == "confirmed" and frame.checksum_sha256
        }
        expected_targets = set(range(1, record_session.expected_frames + 1))
        if ready_targets != expected_targets:
            raise ValidationError("Confirm every required original frame and checksum before processing.")
    confirmed = confirmed_frame_count(session, session_id)
    if confirmed < record_session.expected_frames:
        raise ValidationError(
            "The capture session is incomplete: "
            f"{confirmed}/{record_session.expected_frames} frames confirmed."
        )
    live = session.execute(
        text(
            "SELECT id FROM fyp.panorama_jobs WHERE session_id = :sid "
            "AND (status IN ('queued', 'processing') OR (:retain_result AND status = 'done')) "
            "ORDER BY created_at DESC LIMIT 1"
        ),
        {"sid": str(session_id), "retain_result": record_session.capture_mode in BACKEND_STITCH_MODES},
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
    """Records the stage AND renews the claim lease.

    ``claimed_at`` is the staleness clock, so a job that keeps reporting
    progress cannot be reclaimed by a second worker mid-stitch — this is the
    heartbeat the durable queue needs, and it costs nothing because progress is
    already written at every stage boundary.
    """
    session.execute(
        text(
            "UPDATE fyp.panorama_jobs SET processing_stage = :stage, "
            "progress = :progress, updated_at = now(), claimed_at = now() "
            "WHERE id = :jid"
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
        if record_session.status == "cancelled" or job.status == "cancelled":
            # A cancelled attempt may finish its stitch in a worker, but its
            # result is never completed or made active. The candidate object
            # remains for reference-aware cleanup, not promotion.
            job.status = "cancelled"
            job.completed_at = _now()
            job.updated_at = _now()
            session.add(job)
            session.commit()
            return
        record_session.status = "completed"
        record_session.updated_at = _now()
        session.add(record_session)
        # Deliberately NO assignment mirror here. A generated panorama is an
        # unconfirmed candidate until the agent explicitly accepts it through
        # accept_panorama_candidate(); the active inspection reference must
        # keep pointing at the previous valid panorama.
    session.add(job)
    session.commit()


def accept_panorama_candidate(
    session: Session,
    *,
    session_id: uuid.UUID,
    panorama_id: uuid.UUID,
    agent_id: int,
    expected_active_panorama_id: uuid.UUID | None = None,
) -> tuple[Panorama, uuid.UUID | None]:
    """Activate one generated candidate for the assigned Agent.

    The worker/device confirmation only registers a candidate. This function is
    the ONLY writer that changes the assignment's active ``panorama_id``. The
    assignment row is locked, the previously active reference is compared, and
    the update is conditional so two concurrent acceptances cannot both win.

    Returns ``(panorama, job_id)``. A repeated acceptance of the same candidate
    is idempotent.
    """
    record_session = session.get(
        CaptureSession, session_id, populate_existing=True, with_for_update=True
    )
    if record_session is None:
        raise NotFoundError("Capture session not found.")
    if record_session.status == "cancelled":
        raise ConflictError("This capture attempt was cancelled.")
    if record_session.status != "completed":
        raise ConflictError("The candidate panorama is not ready for acceptance.")

    panorama = session.get(
        Panorama, panorama_id, populate_existing=True, with_for_update=True
    )
    if panorama is None or panorama.session_id != session_id:
        raise NotFoundError("Candidate panorama not found for this capture.")
    if str(panorama.property_id) != str(record_session.property_id):
        raise ConflictError("Candidate panorama belongs to a different property.")
    if panorama.published_at is not None:
        raise ConflictError("A published panorama cannot be accepted as a draft.")
    if str(panorama.verification_status).lower() == "rejected":
        raise ConflictError("The candidate panorama was rejected and cannot be accepted.")

    assignment = session.execute(
        text(
            """
            SELECT a.listing_id, a.agent_id, a.workflow_status, a.panorama_id,
                   p.verification_status, p.is_published
              FROM fyp.agent_listing_assignment a
              JOIN fyp.rental_properties p ON p.id = a.listing_id
             WHERE a.listing_id = :pid AND a.agent_id = :aid
             FOR UPDATE OF a
            """
        ),
        {"pid": int(record_session.property_id), "aid": int(agent_id)},
    ).mappings().first()
    if assignment is None:
        raise ForbiddenError("Assigned property not found.")
    if assignment["workflow_status"] not in ("accepted", "needs_correction"):
        raise ConflictError("The assignment is not open for Agent changes.")
    if assignment["is_published"] or assignment["verification_status"] in (
        "approved",
        "pending",
        "under_review",
    ):
        raise ConflictError("Property is locked for Admin review or publication.")

    current_active = assignment["panorama_id"]
    current_active_text = str(current_active) if current_active is not None else None
    candidate_text = str(panorama.panorama_id)
    if current_active_text == candidate_text:
        return panorama, _done_job_id(session, session_id, panorama.storage_path)

    if current_active_text is not None:
        if expected_active_panorama_id is None:
            raise ConflictError(
                "The active panorama must be supplied before replacing it."
            )
        if str(expected_active_panorama_id) != current_active_text:
            raise ConflictError(
                "The active panorama changed while this recapture was running. "
                "Review the current panorama before accepting this candidate."
            )
        previous = session.get(Panorama, uuid.UUID(str(current_active)))
        if previous is not None and previous.published_at is not None:
            raise ConflictError(
                "The active panorama is published and cannot be replaced by an "
                "Agent draft."
            )

    job_id: uuid.UUID | None = None
    if record_session.capture_mode in BACKEND_STITCH_MODES:
        job_id = _done_job_id(session, session_id, panorama.storage_path)
        if job_id is None:
            raise ConflictError(
                "The candidate has no completed processing job; it cannot be accepted."
            )

    updated = session.execute(
        text(
            """
            UPDATE fyp.agent_listing_assignment
               SET panorama_id = :pan, panorama_tour_id = :tour,
                   panorama_job_id = :job, panorama_uploaded_at = now(),
                   updated_at = now()
             WHERE listing_id = :pid AND agent_id = :aid
               AND panorama_id IS NOT DISTINCT FROM :current
            """
        ),
        {
            "pan": candidate_text,
            "tour": str(record_session.id),
            "job": str(job_id) if job_id is not None else None,
            "pid": int(record_session.property_id),
            "aid": int(agent_id),
            "current": current_active_text,
        },
    )
    if updated.rowcount != 1:
        session.rollback()
        raise ConflictError(
            "The active panorama changed while this candidate was being accepted."
        )
    session.commit()
    session.refresh(panorama)
    return panorama, job_id


def _done_job_id(
    session: Session, session_id: uuid.UUID, storage_path: str
) -> uuid.UUID | None:
    row = session.execute(
        text(
            """
            SELECT id FROM fyp.panorama_jobs
             WHERE session_id = :sid AND status = 'done'
               AND output_storage_path = :path
             ORDER BY completed_at DESC NULLS LAST
             LIMIT 1
            """
        ),
        {"sid": str(session_id), "path": storage_path},
    ).first()
    return row[0] if row is not None else None


def cancel_capture_session(
    session: Session, *, session_id: uuid.UUID
) -> CaptureSession:
    """Cancel a candidate attempt without touching the active panorama."""
    record_session = session.get(
        CaptureSession, session_id, populate_existing=True, with_for_update=True
    )
    if record_session is None:
        raise NotFoundError("Capture session not found.")
    if record_session.status == "cancelled":
        return record_session
    candidate = panorama_for_session(session, session_id)
    if candidate is not None:
        active = session.execute(
            text(
                "SELECT panorama_id FROM fyp.agent_listing_assignment "
                "WHERE listing_id = :pid FOR UPDATE"
            ),
            {"pid": int(record_session.property_id)},
        ).first()
        if active is not None and str(active[0]) == str(candidate.panorama_id):
            raise ConflictError(
                "The active panorama cannot be cancelled. Start a recapture first."
            )
    session.execute(
        text(
            "UPDATE fyp.panorama_jobs "
            "SET status = 'cancelled', completed_at = now(), "
            "    claimed_at = NULL, claimed_by = NULL, updated_at = now() "
            "WHERE session_id = :sid AND status IN ('queued', 'processing')"
        ),
        {"sid": str(session_id)},
    )
    record_session.status = "cancelled"
    record_session.updated_at = _now()
    session.add(record_session)
    session.commit()
    session.refresh(record_session)
    return record_session


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
        if record_session.status == "cancelled":
            job.status = "cancelled"
            job.updated_at = _now()
            session.add(job)
            session.commit()
            return
        record_session.status = "failed"
        record_session.updated_at = _now()
        session.add(record_session)
    session.add(job)
    session.commit()


def latest_property_panorama(
    session: Session, property_id: int
) -> Panorama | None:
    """The property's ACTIVE panorama, not its newest candidate.

    A generated replacement is an unconfirmed candidate until the Agent
    accepts it. Falling back to ``ORDER BY created_at`` would make every
    successful worker run replace the visible tour before confirmation.
    Historical properties without an assignment row keep the legacy newest-row
    behaviour.
    """
    active = session.execute(
        text(
            "SELECT p.* FROM fyp.agent_listing_assignment a "
            "JOIN fyp.panoramas p ON p.panorama_id = a.panorama_id "
            "WHERE a.listing_id = :pid LIMIT 1"
        ),
        {"pid": int(property_id)},
    ).mappings().first()
    if active is not None:
        return Panorama.model_validate(dict(active))
    assignment_exists = session.execute(
        text(
            "SELECT EXISTS (SELECT 1 FROM fyp.agent_listing_assignment "
            "WHERE listing_id = :pid)"
        ),
        {"pid": int(property_id)},
    ).scalar()
    if assignment_exists:
        return None
    row = session.execute(
        text(
            "SELECT * FROM fyp.panoramas WHERE property_id = :pid "
            "ORDER BY created_at DESC LIMIT 1"
        ),
        {"pid": str(property_id)},
    ).mappings().first()
    return Panorama.model_validate(dict(row)) if row is not None else None


def get_panorama(
    session: Session, panorama_id: uuid.UUID
) -> Panorama | None:
    return session.get(Panorama, panorama_id)


def is_active_panorama(
    session: Session, *, property_id: int, panorama_id: uuid.UUID
) -> bool:
    active = session.execute(
        text(
            "SELECT panorama_id FROM fyp.agent_listing_assignment "
            "WHERE listing_id = :pid LIMIT 1"
        ),
        {"pid": int(property_id)},
    ).scalar()
    return active is not None and str(active) == str(panorama_id)


def panorama_for_session(
    session: Session, session_id: uuid.UUID
) -> Panorama | None:
    """The canonical panorama row for one capture session, when it exists."""
    row = session.execute(
        text("SELECT panorama_id FROM fyp.panoramas WHERE session_id = :sid"),
        {"sid": str(session_id)},
    ).first()
    if row is None:
        return None
    return session.get(Panorama, row[0])


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


def confirm_device_panorama(
    session: Session,
    *,
    session_id: uuid.UUID,
    storage_path: str,
    width: int,
    height: int,
    coverage_report: dict[str, Any] | None,
) -> Panorama:
    """Register the device-generated panorama as the canonical row.

    In the ``device_38_panorama`` workflow Flutter has already stitched the
    38 originals into one 2:1 equirectangular JPEG; the confirmation endpoint
    (which verifies the stored object, its checksum, its JPEG structure and
    the 2:1 geometry BEFORE calling here) is the only writer of
    ``fyp.panoramas`` for this workflow. The worker's ``create_panorama``
    path stays untouched for legacy sessions.

    Confirming twice is idempotent: the same verified object (same path and
    geometry) returns the existing row without touching review state. A
    genuinely different object for an UNPUBLISHED tour replaces the metadata
    and resets the review decision; a published tour can never be silently
    replaced. The session becomes ``completed`` as soon as the canonical
    panorama exists — the original frames are a backup, not a prerequisite
    for the deliverable.
    """
    record_session = session.get(
        CaptureSession, session_id, populate_existing=True, with_for_update=True
    )
    if record_session is None:
        raise NotFoundError("Capture session not found.")
    if record_session.status == "cancelled":
        raise ConflictError("This capture session was cancelled on the server.")
    existing = session.execute(
        text("SELECT panorama_id FROM fyp.panoramas WHERE session_id = :sid"),
        {"sid": str(session_id)},
    ).first()
    if existing is not None:
        record = session.get(Panorama, existing[0])
        assert record is not None
        same_object = (
            record.storage_path == storage_path
            and int(record.width) == int(width)
            and int(record.height) == int(height)
        )
        if record.published_at is not None and not same_object:
            raise ConflictError(
                "This 360° tour is already published; unpublish it before "
                "replacing the panorama."
            )
        if same_object:
            # The retry flow re-confirms the object it already stored; review
            # state and timestamps must survive that unchanged.
            return record
        record.storage_path = storage_path
        record.width = width
        record.height = height
        record.coverage_report = coverage_report
        # Replacing the bytes invalidates any earlier review decision.
        record.verification_status = "pending"
        record.reviewed_by = None
        record.reviewed_at = None
        record.review_reason = None
        record.updated_at = _now()
        session.add(record)
    else:
        record = Panorama(
            session_id=session_id,
            property_id=str(record_session.property_id),
            storage_path=storage_path,
            width=width,
            height=height,
            coverage_report=coverage_report,
        )
        session.add(record)
    if record_session.status != "completed":
        record_session.status = "completed"
        record_session.updated_at = _now()
        session.add(record_session)
    # Deliberately NO assignment mirror. This row is an unconfirmed candidate
    # until the agent accepts it through accept_panorama_candidate(). Keeping
    # the previous assignment reference is what makes recapture safe.
    session.commit()
    session.refresh(record)
    return record


# --------------------------------------------------------------------------
# Administrative review and publication.
#
# Stitching completion is a TECHNICAL event; administrative approval is a
# separate, auditable decision, and publication is a third one. A panorama
# only becomes entrepreneur-visible through publish_panorama, which requires
# the approved verification status AND the listing itself to be approved and
# published — a rejected or merely stitched panorama can never leak into the
# public viewer.
# --------------------------------------------------------------------------

_REVIEW_DECISIONS = frozenset({"approved", "rejected"})


def enhance_panorama(session: Session, *, panorama_id: uuid.UUID) -> Panorama:
    """Optional (default-off) tonal enhancement of a device panorama.

    Section-12 contract: a conservative tonal pass — bounded gray-world white
    balance plus gentle exposure normalization — over the completed canonical
    device panorama. It is NEVER a second stitch, never changes geometry, and
    never invents content. The result is written to a SEPARATE
    ``panorama_enhanced.jpg`` Storage object; the canonical ``panorama.jpg``,
    its path, geometry and review state are untouched. Enhancement status is
    recorded in the existing ``coverage_report`` JSON column, so no schema
    extension is needed. Failure raises before anything is written, leaving
    the valid original fully intact.
    """
    if not settings.sitewise_panorama_enhancement_enabled:
        raise ValidationError(
            "Panorama enhancement is disabled on this deployment "
            "(SITEWISE_PANORAMA_ENHANCEMENT_ENABLED is not enabled)."
        )
    record = get_panorama(session, panorama_id)
    if record is None:
        raise NotFoundError("Panorama not found.")
    enhanced_path = capture_storage.enhanced_panorama_object_path(
        record.property_id, str(record.session_id)
    )
    try:
        original = capture_storage.download(record.storage_path)
    except capture_storage.ObjectMissing as exc:
        raise ConflictError(
            "The canonical panorama object is missing from storage; nothing "
            "to enhance."
        ) from exc
    except capture_storage.CaptureStorageUnavailable as exc:
        raise ConflictError(f"Panorama storage is unavailable: {exc}") from exc

    # Deferred heavy imports keep API startup unchanged when enhancement
    # stays disabled (the default).
    import cv2
    import numpy as np

    image = cv2.imdecode(
        np.frombuffer(original, dtype=np.uint8), cv2.IMREAD_COLOR
    )
    if image is None:
        raise ConflictError("The stored panorama is not a readable JPEG.")

    result = image.astype(np.float32)
    means = result.reshape(-1, 3).mean(axis=0)
    grey = float(means.mean())
    if grey > 1e-3:
        gains = grey / np.maximum(means, 1e-3)
        np.clip(gains, 0.85, 1.18, out=gains)
        result *= gains
    luma = result @ np.array([0.114, 0.587, 0.299], dtype=np.float32)
    mean_luma = float(luma.mean())
    if mean_luma > 1e-3:
        gain = float(np.clip((255.0 * 0.45) / mean_luma, 0.9, 1.25))
        result *= gain
    enhanced = np.clip(result, 0, 255).astype(np.uint8)
    ok, encoded = cv2.imencode(
        ".jpg", enhanced, [int(cv2.IMWRITE_JPEG_QUALITY), 92]
    )
    if not ok:
        raise ConflictError("The enhanced panorama could not be encoded.")
    data = encoded.tobytes()
    if len(data) > capture_storage.PANORAMA_MAX_BYTES:
        raise ConflictError(
            "The enhanced panorama exceeds the 32 MB storage limit."
        )

    try:
        capture_storage.upload_bytes(enhanced_path, data)
    except capture_storage.CaptureStorageUnavailable as exc:
        raise ConflictError(f"Enhanced panorama upload failed: {exc}") from exc

    report = dict(record.coverage_report or {})
    report["enhancement"] = {
        "status": "completed",
        "storage_path": enhanced_path,
        "sha256": capture_storage.sha256_hex(data),
        "bytes": len(data),
        "width": int(enhanced.shape[1]),
        "height": int(enhanced.shape[0]),
        "enhanced_at": _now().isoformat(),
    }
    record.coverage_report = report
    record.updated_at = _now()
    session.add(record)
    session.commit()
    session.refresh(record)
    return record


def list_panoramas(
    session: Session, *, verification_status: str | None = None
) -> list[Panorama]:
    """All canonical panoramas, newest first, optionally filtered by status."""
    if verification_status is not None and verification_status not in (
        "pending",
        "approved",
        "rejected",
    ):
        raise ValidationError(
            "verification_status must be pending, approved or rejected."
        )
    if verification_status is None:
        rows = session.execute(
            text(
                "SELECT * FROM fyp.panoramas ORDER BY created_at DESC LIMIT 200"
            )
        ).mappings()
    else:
        rows = session.execute(
            text(
                "SELECT * FROM fyp.panoramas WHERE verification_status = :status "
                "ORDER BY created_at DESC LIMIT 200"
            ),
            {"status": verification_status},
        ).mappings()
    return [Panorama.model_validate(dict(row)) for row in rows]


def review_panorama(
    session: Session,
    *,
    panorama_id: uuid.UUID,
    reviewer_id: uuid.UUID,
    decision: str,
    reason: str | None = None,
) -> Panorama:
    """Record one administrative review decision on a stitched panorama.

    Only a COMPLETED panorama (one with a storage object the worker actually
    produced) can be reviewed. Rejection requires a reason. A re-review of an
    already-decided panorama updates the decision in place with the new
    reviewer and timestamp — the audit trail keeps exactly the latest
    decision, and publication is never auto-toggled by a review.
    """
    if decision not in _REVIEW_DECISIONS:
        raise ValidationError("decision must be 'approved' or 'rejected'.")
    record = get_panorama(session, panorama_id)
    if record is None:
        raise NotFoundError("Panorama not found.")
    if record.storage_path is None or not str(record.storage_path).strip():
        raise ConflictError("Only a stitched panorama can be reviewed.")
    cleaned = (reason or "").strip()
    if decision == "rejected" and not cleaned:
        raise ValidationError("A rejection reason is required.")
    record.verification_status = decision
    record.reviewed_by = reviewer_id
    record.reviewed_at = _now()
    record.review_reason = cleaned or None
    record.updated_at = _now()
    session.add(record)
    session.commit()
    session.refresh(record)
    return record


def publish_panorama(
    session: Session, *, panorama_id: uuid.UUID, publisher_id: uuid.UUID
) -> Panorama:
    """Make an approved panorama entrepreneur-visible for its property.

    Publication requires: verification approved, the panorama's own listing
    approved AND published, and no other already-published panorama for the
    same property (one tour per property — publishing a second one would make
    two viewer records disagree about the property's tour).
    """
    record = get_panorama(session, panorama_id)
    if record is None:
        raise NotFoundError("Panorama not found.")
    if record.verification_status != "approved":
        raise ConflictError(
            "Only an approved panorama can be published; review it first."
        )
    try:
        property_id = int(record.property_id)
    except (TypeError, ValueError) as exc:
        raise ConflictError(
            "This panorama is not linked to an operational listing."
        ) from exc
    published_listing = session.execute(
        text(
            "SELECT 1 FROM fyp.rental_properties "
            "WHERE id = :pid AND is_published IS TRUE "
            "AND verification_status = 'approved'"
        ),
        {"pid": property_id},
    ).scalar()
    if published_listing is None:
        raise ConflictError(
            "The listing must be approved and published before its 360° "
            "tour can be published."
        )
    other = session.execute(
        text(
            "SELECT panorama_id FROM fyp.panoramas "
            "WHERE property_id = :pid AND published_at IS NOT NULL "
            "AND panorama_id <> :me"
        ),
        {"pid": str(property_id), "me": str(panorama_id)},
    ).first()
    if other is not None:
        raise ConflictError(
            "Another panorama is already published for this property; "
            "unpublish it first."
        )
    record.published_at = _now()
    record.updated_at = _now()
    session.add(record)
    session.commit()
    session.refresh(record)
    return record


def unpublish_panorama(
    session: Session, *, panorama_id: uuid.UUID
) -> Panorama:
    record = get_panorama(session, panorama_id)
    if record is None:
        raise NotFoundError("Panorama not found.")
    if record.published_at is None:
        return record
    record.published_at = None
    record.updated_at = _now()
    session.add(record)
    session.commit()
    session.refresh(record)
    return record


def published_property_panorama(
    session: Session, property_id: int
) -> Panorama | None:
    """The entrepreneur-visible panorama for a listing, if any.

    Reads the canonical record ONLY: approved, published, and belonging to
    the listing. Unpublished, rejected or pending rows are invisible here by
    construction, not by filtering at the viewer.
    """
    rows = session.execute(
        text(
            "SELECT * FROM fyp.panoramas "
            "WHERE property_id = :pid AND verification_status = 'approved' "
            "AND published_at IS NOT NULL "
            "ORDER BY published_at DESC LIMIT 1"
        ),
        {"pid": str(property_id)},
    ).mappings()
    row = rows.first()
    if row is None:
        return None
    return Panorama.model_validate(dict(row))
