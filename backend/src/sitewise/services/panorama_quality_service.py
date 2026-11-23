"""Capture-quality orchestration for the canonical 360° pipeline.

One module owns WHERE and WHEN the expensive verification runs, and HOW the
results are stored:

* :func:`run_panorama_quality` — coverage + seam verification of a stitched
  panorama (one downscaled decode; fast enough for the panorama-confirm
  request path).
* :func:`run_registration_audit_for_files` — pairwise registration /
  geometric-consistency verification over frames that are already on disk
  (worker thread or audit thread).
* :func:`run_session_registration_audit_async` — fire-and-forget daemon
  thread that downloads a session's confirmed originals and runs the audit,
  merging the result into the session's panorama row. Spawned when a
  session's last frame is confirmed; guarded so one session audits once per
  process at a time.
* :func:`merge_quality_into_report` — the ONLY writer of the ``quality``
  key inside a panorama's ``coverage_report``: strictly additive, never
  overwriting the stitcher's own coverage evidence or the device report.

Guarantees, unchanged across every path: verification NEVER deletes frames,
NEVER rewrites panorama bytes, NEVER fails a request or a job, and NEVER
repeats itself — the merge is idempotent per panorama revision because it
replaces only its own ``quality`` key.
"""

from __future__ import annotations

import logging
import shutil
import tempfile
import threading
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from sitewise.panorama.quality.coverage_verification import verify_panorama_coverage
from sitewise.panorama.quality.registration_verification import (
    RegistrationFrame,
    verify_session_registration,
)
from sitewise.panorama.quality.seam_quality_verification import verify_panorama_seams
from sitewise.panorama.quality.thresholds import PanoramaQualityThresholds
from sitewise.services import capture_storage

logger = logging.getLogger("sitewise.panorama.quality")

_audit_lock = threading.Lock()
_audits_in_flight: set[str] = set()


def run_panorama_quality(
    panorama_bytes: bytes,
    thresholds: PanoramaQualityThresholds | None = None,
) -> dict[str, Any]:
    """Coverage + seam verification of one stitched panorama."""
    active = thresholds or PanoramaQualityThresholds.from_env()
    coverage = verify_panorama_coverage(panorama_bytes, active)
    seams = verify_panorama_seams(panorama_bytes, active)
    warning_count = coverage.warning_count + seams.warning_count
    error_count = coverage.error_count + seams.error_count
    return {
        "thresholds_version": active.version,
        "panorama": {
            "verdict": "warning" if (warning_count or error_count) else "pass",
            "warning_count": warning_count,
            "error_count": error_count,
            "coverage": coverage.to_dict(),
            "seam_quality": seams.to_dict(),
        },
    }


def run_registration_audit_for_files(
    frames: list[RegistrationFrame],
    thresholds: PanoramaQualityThresholds | None = None,
    on_stage=None,
) -> dict[str, Any]:
    """Registration verification over frames already present on disk."""
    active = thresholds or PanoramaQualityThresholds.from_env()
    report = verify_session_registration(frames, active, on_stage=on_stage)
    return {"thresholds_version": active.version, "registration": report.to_dict()}


def merge_quality_into_report(
    existing: dict[str, Any] | None, quality: dict[str, Any]
) -> dict[str, Any]:
    """Returns ``existing`` with only its ``quality`` key replaced.

    Everything else in the report (the stitcher's coverage evidence, the
    device's photo coverage, the enhancement record) passes through
    untouched — the verification never overwrites anyone else's evidence.
    """
    report = dict(existing or {})
    report["quality"] = quality
    return report


def _merge_registration_into_panorama(
    session_id: Any, quality: dict[str, Any]
) -> bool:
    """Writes the registration audit into the session's panorama row.

    Best-effort by contract: no panorama row yet (frames confirm before the
    panorama typically) means there is nothing to annotate and the caller's
    next audit attempt will find one. Returns whether a row was updated.
    """
    from sqlmodel import Session, text

    from sitewise.db.session import engine
    from sitewise.services import capture_session_service as svc

    with Session(engine) as db:
        row = db.execute(
            text(
                "SELECT panorama_id FROM fyp.panoramas WHERE session_id = :sid"
            ),
            {"sid": str(session_id)},
        ).first()
        if row is None:
            return False
        panorama = svc.get_panorama(db, row[0])
        if panorama is None:
            return False
        panorama.coverage_report = merge_quality_into_report(
            panorama.coverage_report, quality
        )
        panorama.updated_at = datetime.now(UTC)
        db.add(panorama)
        db.commit()
        return True


def run_session_registration_audit(session_id: Any) -> None:
    """Downloads the session's confirmed originals and audits registration.

    Runs on its own database session and storage reads; every failure is
    logged and swallowed — an audit problem never fails a capture that is
    already durably stored. Frames are downloaded to a temp directory and
    cleaned up afterwards.
    """
    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.services import capture_session_service as svc

    work_dir: Path | None = None
    try:
        with Session(engine) as db:
            session_row = svc.get_capture_session(db, session_id)
            if session_row is None:
                return
            frames = [
                frame
                for frame in svc.list_capture_frames(db, session_id)
                if frame.upload_status == "confirmed"
            ]
        if len(frames) < 2:
            return
        work_dir = Path(tempfile.mkdtemp(prefix="sitewise-quality-"))
        audit_frames: list[RegistrationFrame] = []
        for frame in frames:
            data = capture_storage.download(frame.storage_path)
            path = work_dir / f"frame_{frame.target_index:02d}.jpg"
            path.write_bytes(data)
            audit_frames.append(
                RegistrationFrame(
                    target_id=frame.target_index, image_path=str(path)
                )
            )
        quality = run_registration_audit_for_files(audit_frames)
        _merge_registration_into_panorama(session_id, quality)
        logger.info(
            "Registration audit completed for session %s", session_id
        )
    except Exception:  # noqa: BLE001 - the audit never fails the capture
        logger.exception(
            "Registration audit failed for session %s", session_id
        )
    finally:
        if work_dir is not None:
            shutil.rmtree(work_dir, ignore_errors=True)


def run_session_registration_audit_async(session_id: Any) -> bool:
    """Spawns the audit on a daemon thread, once per session at a time.

    Returns ``False`` when an audit for this session is already running —
    the caller (frame confirm) simply skips spawning a duplicate.
    """
    key = str(session_id)
    with _audit_lock:
        if key in _audits_in_flight:
            return False
        _audits_in_flight.add(key)

    def _run() -> None:
        try:
            run_session_registration_audit(session_id)
        finally:
            with _audit_lock:
                _audits_in_flight.discard(key)

    thread = threading.Thread(
        target=_run, name=f"registration-audit-{key[:8]}", daemon=True
    )
    thread.start()
    return True
