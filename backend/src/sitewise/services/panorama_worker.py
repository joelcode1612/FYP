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
import math
import os
import shutil
import threading
import time
import uuid
from pathlib import Path

from sitewise.db.session import Session, engine
from sitewise.panorama.quality.registration_verification import RegistrationFrame
from sitewise.panorama.stitcher import StitchOutcome, stitch_equirectangular
from sitewise.panorama.sphere_math import Quat, UNIT_X, UNIT_Y
from sitewise.services import capture_session_service as svc
from sitewise.services import capture_storage, panorama_quality_service

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
    if "Verifying capture quality" in message:
        return 33
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


def _plan_target(target_id: int, plan_version: str) -> tuple[float, float] | None:
    """Return the documented yaw/pitch prior for a known 38-target plan."""
    version = str(plan_version or "1")
    if version == "3":
        if not 1 <= target_id <= 56:
            return None
        middle = tuple(float(((i * 20 + 180) % 360) - 180) for i in range(18))
        upper = tuple(float(((340 - i * 20 + 180) % 360) - 180) for i in range(18))
        if target_id <= 18:
            return middle[target_id - 1], 0.0
        if target_id == 19:
            return 0.0, 90.0
        if target_id <= 37:
            return upper[target_id - 20], 40.0
        if target_id <= 55:
            return middle[target_id - 38], -40.0
        return 0.0, -90.0
    if not 1 <= target_id <= 38 or version not in {"1", "2"}:
        return None
    middle = (0, 30, 60, 90, 120, 150, 180, -150, -120, -90, -60, -30)
    upper = (-30, -60, -90, -120, -150, 180, 150, 120, 90, 60, 30, 0)
    lower = middle
    pitch = 35.0 if str(plan_version or "1") == "1" else 40.0
    if target_id <= 12:
        return float(middle[target_id - 1]), 0.0
    if target_id == 13:
        return 0.0, 90.0
    if target_id <= 25:
        return float(upper[target_id - 14]), pitch
    if target_id <= 37:
        return float(lower[target_id - 26]), -pitch
    return 0.0, -90.0


def _plan_orientation(yaw_deg: float, pitch_deg: float) -> Quat:
    # Same right-handed +Y convention as sphere_math and the mobile target map.
    return (
        Quat.axis_angle(-yaw_deg, UNIT_Y)
        * Quat.axis_angle(pitch_deg, UNIT_X)
    ).normalized


def _build_records(
    session_row, frames, frame_dir: Path, *, use_measured: bool = True
) -> tuple[list[dict], list[str]]:
    """Worker-side records for the stitcher, one per confirmed frame.

    ``capture_pose`` is the recorded device→world orientation; when the
    device's manifest carried source dimensions or crop offsets they ride
    along inside the same JSON blob and are forwarded to the stitcher
    unchanged (the intrinsics transform needs the PRE-crop geometry).
    """
    records: list[dict] = []
    problems: list[str] = []
    plan = str(getattr(session_row, "capture_plan_version", "1") or "1")
    measured: dict[int, Quat] = {}
    for frame in frames:
        if frame.upload_status != "confirmed":
            continue
        pose = frame.capture_pose
        raw = pose if isinstance(pose, dict) else None
        if raw is None and isinstance(pose, list) and len(pose) == 4:
            raw = dict(zip(("x", "y", "z", "w"), pose))
        if raw is None or not all(k in raw for k in ("x", "y", "z", "w")):
            continue
        try:
            q = Quat(*(float(raw[k]) for k in ("x", "y", "z", "w")))
            if all(math.isfinite(v) for v in (q.x, q.y, q.z, q.w)) and q.length > 1e-6:
                measured[frame.target_index] = q.normalized
        except (TypeError, ValueError):
            continue

    # A measured frame establishes the session's orientation origin. The plan
    # supplies only missing poses; those inferred values remain transient and
    # are explicitly labelled so they are never mistaken for sensor readings.
    origin = Quat.identity()
    if measured and use_measured:
        anchor_id = min(measured)
        anchor_target = _plan_target(anchor_id, plan)
        if anchor_target is not None:
            origin = measured[anchor_id] * _plan_orientation(*anchor_target).conjugate
            origin = origin.normalized
    for frame in frames:
        if frame.upload_status != "confirmed":
            continue
        path = frame_dir / f"frame_{frame.target_index:02d}.jpg"
        pose = frame.capture_pose
        metadata = pose if isinstance(pose, dict) else {}
        yaw_pitch = _plan_target(frame.target_index, plan)
        inferred = False
        if isinstance(pose, dict):
            q = measured.get(frame.target_index) if use_measured else None
            source_w = int(pose.get("sourceImageWidth") or 0)
            source_h = int(pose.get("sourceImageHeight") or 0)
            crop_x = int(pose.get("cropOffsetX") or 0)
            crop_y = int(pose.get("cropOffsetY") or 0)
        elif isinstance(pose, list) and len(pose) == 4:
            q = measured.get(frame.target_index) if use_measured else None
            source_w = source_h = 0
            crop_x = crop_y = 0
        else:
            q = None
            source_w = source_h = 0
            crop_x = crop_y = 0
        if q is None:
            if yaw_pitch is None:
                problems.append(f"frame {frame.target_index} has no usable capture-plan target")
                continue
            q = origin * _plan_orientation(*yaw_pitch)
            inferred = True
        orientation = [q.x, q.y, q.z, q.w]
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
                "poseSource": "capture_plan_prior" if inferred else "measured_camera_orientation",
                "targetYawDegrees": metadata.get("targetYawDegrees", yaw_pitch[0] if yaw_pitch else None),
                "targetPitchDegrees": metadata.get("targetPitchDegrees", yaw_pitch[1] if yaw_pitch else None),
                "focalLengthXPx": metadata.get("focalLengthXPx"),
                "focalLengthYPx": metadata.get("focalLengthYPx"),
                "principalPointXPx": metadata.get("principalPointXPx"),
                "principalPointYPx": metadata.get("principalPointYPx"),
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
        prior_panorama = svc.panorama_for_session(db, session_id)
        if prior_panorama is not None and (
            prior_panorama.published_at is not None
            or str(prior_panorama.verification_status).lower()
            in {"approved", "published", "verified"}
        ):
            svc.fail_job(
                db,
                job_id=job_id,
                message="An approved panorama is read-only and was preserved.",
            )
            return
    _report_progress(job_id, f"Loading capture manifest: {len(frames)} frames…")

    confirmed = [f for f in frames if f.upload_status == "confirmed"]
    expected = list(range(1, session_row.expected_frames + 1))
    if sorted(frame.target_index for frame in confirmed) != expected:
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

        has_measured_poses = any(
            r["poseSource"] == "measured_camera_orientation" for r in records
        )
        selected_out_dir = out_dir
        stored_attempt = "measured_pose" if has_measured_poses else "capture_plan_legacy"
        try:
            outcome = stitch_equirectangular(
                records=records,
                out_dir=out_dir,
                width=STITCH_WIDTH,
                refine_registration=True,
                strict_photo_coverage=True,
                progress=lambda message: _report_progress(job_id, message),
            )
        except Exception:
            logger.exception(
                "Initial stitch raised for job %s; trying compatible fallbacks",
                job_id,
            )
            outcome = StitchOutcome(
                ok=False,
                message="Initial stitch failed; capture-plan fallback will be attempted.",
            )
        if not outcome.ok and has_measured_poses:
            # A camera-pose run can fail on noisy or inconsistent metadata.
            # Retry through the established capture-plan registration path;
            # each attempt gets its own output directory and leaves all source
            # frames and any existing panorama untouched.
            logger.warning(
                "Measured-pose stitch failed for job %s; retrying capture-plan fallback: %s",
                job_id,
                outcome.message,
            )
            fallback_records, fallback_problems = _build_records(
                session_row, confirmed, frame_dir, use_measured=False
            )
            fallback_dir = work_dir / "fallback_out"
            fallback_dir.mkdir(parents=True, exist_ok=True)
            fallback = stitch_equirectangular(
                records=fallback_records,
                out_dir=fallback_dir,
                width=STITCH_WIDTH,
                refine_registration=True,
                strict_photo_coverage=True,
                progress=lambda message: _report_progress(job_id, message),
            )
            if fallback.ok:
                records, problems, outcome = fallback_records, fallback_problems, fallback
                selected_out_dir = fallback_dir
                stored_attempt = "capture_plan_fallback"
            else:
                logger.error(
                    "Capture-plan fallback also failed for job %s: %s",
                    job_id,
                    fallback.message,
                )
        if not outcome.ok:
            # The established plan geometry is also the safe fallback for
            # metadata-free sessions. Registration refinement can introduce
            # tiny raster coverage gaps even when every target is present;
            # this final pass keeps the same source frames and plan geometry,
            # while the stitcher's normal 99.5% coverage and viewport gates
            # still reject materially incomplete spheres. The report records
            # any interpolated pixels for audit.
            fallback_records, fallback_problems = _build_records(
                session_row, confirmed, frame_dir, use_measured=False
            )
            fallback_dir = work_dir / "fallback_plan_only_out"
            fallback_dir.mkdir(parents=True, exist_ok=True)
            fallback = stitch_equirectangular(
                records=fallback_records,
                out_dir=fallback_dir,
                width=STITCH_WIDTH,
                refine_registration=False,
                strict_photo_coverage=False,
                progress=lambda message: _report_progress(job_id, message),
            )
            if fallback.ok and not fallback_problems:
                records, problems, outcome = fallback_records, fallback_problems, fallback
                selected_out_dir = fallback_dir
                stored_attempt = "capture_plan_unrefined_fallback"
            else:
                logger.error(
                    "Unrefined capture-plan fallback failed for job %s: %s",
                    job_id,
                    fallback.message,
                )
        if not outcome.ok:
            _fail(job_id, outcome.message)
            return

        panorama_bytes = (selected_out_dir / "panorama.jpg").read_bytes()

        # Capture-quality verification (registration + geometric
        # consistency over the downloaded originals; coverage + seam checks
        # over the fresh panorama). Evidence only: merged ADDITIVELY into
        # the stored coverage report, never gating the job, never altering
        # a byte. A verifier failure keeps the plain stitcher report.
        stored_report = dict(outcome.report)
        stored_report["stitchingMethod"] = stored_attempt
        stored_report["poseSources"] = {
            "measured": sum(r["poseSource"] == "measured_camera_orientation" for r in records),
            "capturePlanPrior": sum(r["poseSource"] == "capture_plan_prior" for r in records),
        }
        _report_progress(job_id, "Verifying capture quality…")
        try:
            audit_frames = [
                RegistrationFrame(
                    target_id=int(record["targetId"]),
                    image_path=record["imagePath"],
                )
                for record in records
            ]
            registration = panorama_quality_service.run_registration_audit_for_files(
                audit_frames,
                on_stage=lambda message: _report_progress(job_id, message),
            )
            panorama_quality = panorama_quality_service.run_panorama_quality(
                panorama_bytes
            )
            quality_block: dict[str, object] = {
                "panorama": panorama_quality["panorama"],
                **registration,
            }
            stored_report = panorama_quality_service.merge_quality_into_report(
                stored_report, quality_block
            )
        except Exception:  # noqa: BLE001 - verification is evidence, not a gate
            logger.exception(
                "Capture-quality verification failed for job %s", job_id
            )

        _report_progress(job_id, "Uploading panorama to storage…")
        if prior_panorama is None:
            storage_path = capture_storage.panorama_object_path(
                property_id, str(session_id)
            )
        else:
            storage_path = capture_storage.panorama_candidate_object_path(
                property_id, str(session_id), str(job_id)
            )
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
                coverage_report=stored_report,
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


_worker = PanoramaWorker()


def is_running() -> bool:
    return _worker._thread is not None and _worker._thread.is_alive()


def startup() -> str:
    _worker.start()
    return "durable stitching worker polling every %.0fs" % POLL_SECONDS
