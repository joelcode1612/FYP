"""Durable panorama stitching worker.

The backend owns the authoritative stitch, so the work must survive a
restart and never run twice on one job. The mechanism — no Redis, no Celery,
matching this deployment's one-uvicorn-worker reality:

* Jobs live in ``fyp.panorama_jobs``. ``claim_next_job`` takes one row with
  ``FOR UPDATE SKIP LOCKED`` (concurrent workers cannot share a claim) and
  stamps a lease (``claimed_at``/``claimed_by``); a claim older than
  ``CLAIM_STALE_SECONDS`` is reclaimable, so a worker crash or a backend
  restart recovers the job instead of stranding it in ``processing``.
* Progress/stage flow through the same row, so the mobile client's poll of
  ``GET /api/v1/360/jobs/{id}`` shows real work, not a spinner.
* The stitcher's own stage messages drive the percent scale — one mapping,
  here, so reported progress stays honest to what actually ran.
* Failure never deletes anything: frames stay in Storage and the SQLite/
  metadata rows keep their checksums; the job records the stitcher's
  message and the session returns to ``failed`` — retryable by the client.
* The canonical ``fyp.panoramas`` row and the job's ``done`` status are
  written only AFTER the panorama bytes are confirmed in Supabase Storage.
"""

from __future__ import annotations

import logging
import os
import shutil
import threading
import time
import uuid
from pathlib import Path

from sitewise.db.session import Session, engine
from sitewise.panorama.stitcher import stitch_equirectangular
from sitewise.services import capture_session_service as svc
from sitewise.services import capture_storage

logger = logging.getLogger("sitewise.panorama_worker")

POLL_SECONDS = 5.0
CLAIM_STALE_SECONDS = 900
STITCH_WIDTH = 2048
WORK_ROOT = Path(__file__).resolve().parents[3] / "var" / "panorama_jobs"


def _fail(job_id: uuid.UUID, message: str) -> None:
    """Record the failure in its own short-lived session."""
    with Session(engine) as db:
        svc.fail_job(db, job_id=job_id, message=message)


def _percent_for_stage(message: str) -> int:
    """Map a stitcher/worker stage message to an honest percent scale."""
    if "Downloading" in message:
        return 10
    if "Refining" in message and "orientations" in message:
        return 25
    if "Checking overlap" in message or "Matching" in message:
        return 30
    if "Averaging orientations" in message:
        return 40
    if "Preparing" in message:
        return 45
    if "Projecting" in message:
        return 55
    if "Blending" in message:
        return 80
    if "Auditing" in message or "coverage" in message.lower():
        return 88
    if "Uploading" in message:
        return 92
    return 50


def _report_progress(job_id: uuid.UUID, message: str) -> None:
    percent = min(95, _percent_for_stage(message))
    try:
        with Session(engine) as db:
            svc.set_job_progress(db, job_id=job_id, stage=message, progress=percent)
    except Exception:  # noqa: BLE001 - progress reporting never fails the job
        logger.warning("Progress update failed for job %s", job_id, exc_info=True)


def _build_records(session_row, frames, frame_dir: Path) -> tuple[list[dict], list[str]]:
    """Worker-side records for the stitcher, one per confirmed frame.

    ``capture_pose`` is the recorded device→world orientation; when the
    device's manifest carried source dimensions or crop offsets they ride
    along inside the same JSON blob and are forwarded to the stitcher
    unchanged (the intrinsics transform needs the PRE-crop geometry).
    """
    records: list[dict] = []
    problems: list[str] = []
    for frame in frames:
        if frame.upload_status != "confirmed":
            continue
        path = frame_dir / f"frame_{frame.target_index:02d}.jpg"
        pose = frame.capture_pose
        if isinstance(pose, dict):
            orientation = [
                float(pose.get("x", 0.0)),
                float(pose.get("y", 0.0)),
                float(pose.get("z", 0.0)),
                float(pose.get("w", 1.0)),
            ]
            source_w = int(pose.get("sourceImageWidth") or 0)
            source_h = int(pose.get("sourceImageHeight") or 0)
            crop_x = int(pose.get("cropOffsetX") or 0)
            crop_y = int(pose.get("cropOffsetY") or 0)
        elif isinstance(pose, list) and len(pose) == 4:
            orientation = [float(v) for v in pose]
            source_w = source_h = 0
            crop_x = crop_y = 0
        else:
            problems.append(f"frame {frame.target_index} has no recorded pose")
            continue
        records.append(
            {
                "targetId": frame.target_index,
                "imagePath": str(path),
                "cameraOrientation": orientation,
                "imageWidth": frame.image_width or 0,
                "imageHeight": frame.image_height or 0,
                "sourceImageWidth": source_w,
                "sourceImageHeight": source_h,
                "cropOffsetX": crop_x,
                "cropOffsetY": crop_y,
            }
        )
    return records, problems


def process_job(job_id: uuid.UUID, worker_id: str) -> None:
    """Run one claimed job end to end: manifest → download → stitch → store."""
    started = time.monotonic()
    with Session(engine) as db:
        job = svc.get_job(db, job_id)
        if job is None or job.status != "processing" or job.claimed_by != worker_id:
            return
        session_row = svc.get_capture_session(db, job.session_id)
        if session_row is None:
            svc.fail_job(db, job_id=job_id, message="Capture session disappeared.")
            return
        session_id = session_row.id
        property_id = session_row.property_id
        frames = svc.list_capture_frames(db, session_id)
    _report_progress(job_id, f"Loading capture manifest: {len(frames)} frames…")

    confirmed = [f for f in frames if f.upload_status == "confirmed"]
    if len(confirmed) < session_row.expected_frames:
        _fail(
            job_id,
            message=(
                "The frame manifest is incomplete: "
                f"{len(confirmed)}/{session_row.expected_frames} confirmed."
            ),
        )
        return

    work_dir = WORK_ROOT / str(job_id)
    frame_dir = work_dir / "frames"
    out_dir = work_dir / "out"
    try:
        frame_dir.mkdir(parents=True, exist_ok=True)
        out_dir.mkdir(parents=True, exist_ok=True)

        for index, frame in enumerate(confirmed, start=1):
            _report_progress(
                job_id, f"Downloading frames from storage: {index}/{len(confirmed)}…"
            )
            data = capture_storage.download(frame.storage_path)
            if not capture_storage.verify_checksum(data, frame.checksum_sha256):
                _fail(
                    job_id,
                    message=(
                        f"Frame {frame.target_index} failed its SHA-256 "
                        "integrity check; re-upload it before processing."
                    ),
                )
                return
            (frame_dir / f"frame_{frame.target_index:02d}.jpg").write_bytes(data)

        records, problems = _build_records(session_row, confirmed, frame_dir)
        if problems or len(records) < session_row.expected_frames:
            detail = "; ".join(problems[:4]) or "confirmed frames without a pose"
            _fail(job_id, f"The capture manifest is unusable: {detail}.")
            return

        outcome = stitch_equirectangular(
            records=records,
            out_dir=out_dir,
            width=STITCH_WIDTH,
            refine_registration=True,
            strict_photo_coverage=True,
            progress=lambda message: _report_progress(job_id, message),
        )
        if not outcome.ok:
            _fail(job_id, outcome.message)
            return

        panorama_bytes = (out_dir / "panorama.jpg").read_bytes()
        _report_progress(job_id, "Uploading panorama to storage…")
        storage_path = capture_storage.panorama_object_path(property_id, str(session_id))
        capture_storage.upload_bytes(storage_path, panorama_bytes)

        _report_progress(job_id, "Recording the canonical panorama…")
        with Session(engine) as db:
            panorama = svc.create_panorama(
                db,
                session_id=session_id,
                property_id=str(property_id),
                storage_path=storage_path,
                width=outcome.report["panorama"]["width"],
                height=outcome.report["panorama"]["height"],
                coverage_report=outcome.report,
            )
            svc.complete_job(
                db,
                job_id=job_id,
                output_storage_path=storage_path,
                panorama_id=panorama.panorama_id,
            )
        logger.info(
            "Panorama job %s completed in %.1fs (%s)", job_id, time.monotonic() - started, storage_path
        )
    except capture_storage.CaptureStorageUnavailable as exc:
        _fail(job_id, str(exc))
    except Exception as exc:  # noqa: BLE001 - the job must record the failure
        logger.exception("Panorama job %s failed", job_id)
        _fail(job_id, f"{type(exc).__name__}: {exc}")
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


def run_once(worker_id: str | None = None) -> bool:
    """Claim and process at most one job. False when the queue is empty."""
    wid = worker_id or f"panorama-worker-{os.getpid()}"
    with Session(engine) as db:
        job = svc.claim_next_job(
            db, worker_id=wid, stale_after_seconds=CLAIM_STALE_SECONDS
        )
    if job is None:
        return False
    logger.info("Panorama worker %s claimed job %s", wid, job.id)
    process_job(job.id, wid)
    return True


class PanoramaWorker:
    """Daemon loop: claim → stitch → store, one job at a time."""

    def __init__(self) -> None:
        self._thread: threading.Thread | None = None
        self._start_lock = threading.Lock()

    def start(self) -> None:
        with self._start_lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._thread = threading.Thread(
                target=self._run, name="panorama-worker", daemon=True
            )
            self._thread.start()

    def _run(self) -> None:
        while True:
            try:
                ran = run_once()
            except Exception:  # noqa: BLE001 - the loop outlives any error
                logger.exception("Panorama worker tick failed")
                ran = False
            if not ran:
                time.sleep(POLL_SECONDS)


def startup() -> str:
    worker = PanoramaWorker()
    worker.start()
    return "durable stitching worker polling every %.0fs" % POLL_SECONDS
