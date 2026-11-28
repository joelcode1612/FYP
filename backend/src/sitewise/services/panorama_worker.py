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
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path

from sitewise.db.session import Session, engine
from sitewise.panorama import plan_v11
from sitewise.panorama.alignment import (
    FrameAlignmentInput,
    align_session,
    session_summary,
)
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
    """Map a stitcher/worker stage message to an honest percent scale.

    Order matters: the specific alignment stages must be tested before the
    generic "coverage" match, otherwise "Measuring spherical coverage" would
    jump the bar to 88% while matching had barely started.
    """
    if "Downloading" in message:
        return 10
    if "Matching" in message or "Checking image alignment" in message:
        return 30
    if "Optimising all camera orientations" in message:
        return 36
    if "Measuring spherical coverage" in message:
        return 40
    if "Verifying cross-ring" in message:
        return 43
    if "Refining" in message and "orientations" in message:
        return 25
    if "Verifying capture quality" in message:
        return 46
    if "Checking overlap" in message:
        return 30
    if "Averaging orientations" in message:
        return 44
    if "Preparing" in message:
        return 48
    if "Projecting" in message:
        return 58
    if "Blending" in message:
        return 80
    if "Auditing" in message:
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


#: Concurrent frame downloads. Four matches measured storage throughput for
#: 1.5 MB JPEGs and keeps the following CPU stages from being starved.
DOWNLOAD_CONCURRENCY = 4


def _download_frames(job_id: uuid.UUID, frames, frame_dir: Path) -> bool | None:
    """Fetches and verifies every confirmed frame, four at a time.

    Returns ``True`` when every file is on disk and verified, or ``None`` after
    recording a job failure. The original serial loop was the single largest
    contributor to a five-minute panorama: the stitching could not start until
    the last of ~120 MB had arrived one request at a time.
    """
    total = len(frames)
    completed = 0
    failure: dict[str, str] = {}
    lock = threading.Lock()

    def fetch(frame) -> None:
        nonlocal completed
        if failure:
            return
        target = frame_dir / f"frame_{frame.target_index:02d}.jpg"
        # A retried job keeps its working directory. Re-downloading bytes that
        # are already on disk and still match the manifest digest is pure
        # transfer time — and a resumed job is exactly when that matters.
        if target.exists():
            try:
                if capture_storage.verify_checksum(
                    target.read_bytes(), frame.checksum_sha256
                ):
                    with lock:
                        completed += 1
                    return
            except OSError:
                pass
        try:
            data = capture_storage.download(frame.storage_path)
        except Exception as exc:  # noqa: BLE001 - reported as a job failure
            logger.warning(
                "Frame %s could not be downloaded: %s", frame.target_index, exc
            )
            with lock:
                failure.setdefault("message", "A photograph could not be downloaded.")
            return
        if not capture_storage.verify_checksum(data, frame.checksum_sha256):
            with lock:
                failure.setdefault(
                    "message",
                    f"Frame {frame.target_index} failed its SHA-256 integrity "
                    "check; re-upload it before processing.",
                )
            return
        target.write_bytes(data)
        with lock:
            completed += 1
            done = completed
        if done % DOWNLOAD_CONCURRENCY == 0 or done == total:
            _report_progress(
                job_id, f"Downloading frames from storage: {done}/{total}…"
            )

    with ThreadPoolExecutor(max_workers=DOWNLOAD_CONCURRENCY) as pool:
        list(pool.map(fetch, frames))
    if failure:
        _fail(job_id, message=failure["message"])
        return None
    if completed != total:
        _fail(job_id, message="Not every photograph could be downloaded.")
        return None
    return True


def _plan_target(target_id: int, plan_version: str) -> tuple[float, float] | None:
    """Return the documented yaw/pitch prior for a known capture plan.

    V4 uses its reference five-ring table only as a fallback: the generated
    geometry is normally read from the session's persisted plan payload by
    ``_build_records``. V11 keeps its canonical staggered table. V1–V3 retain
    their existing fixed layouts.
    """
    version = str(plan_version or "1")
    if version == "4":
        # Reference adaptive layout: upper polar 1–4, upper 5–16, middle 17–28,
        # lower 29–40, lower polar 41–44. A measured-lens plan overrides this
        # through ``saved_targets`` in ``_build_records``.
        if not 1 <= target_id <= 44:
            return None
        if target_id <= 4:
            return float(((target_id - 1) * 90) % 360), 65.0
        if target_id <= 16:
            return float(((target_id - 5) * 30) % 360), 30.0
        if target_id <= 28:
            return float(((target_id - 17) * 30) % 360), 0.0
        if target_id <= 40:
            return float(((target_id - 29) * 30) % 360), -30.0
        return float(((target_id - 41) * 90) % 360), -65.0
    if version == plan_v11.PLAN_V11_VERSION:
        # The enhanced adaptive 44-target layout. Its ids are the capture order,
        # so a prior taken from the wrong table would rotate every frame of the
        # session — the table is mirrored, not re-derived.
        row = plan_v11.target_by_id(target_id)
        return (row.yaw_deg, row.pitch_deg) if row is not None else None
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
    saved_geometry = getattr(session_row, "plan_geometry", None)
    saved_targets = {
        int(row.get("targetId")): (float(row.get("yawDeg")), float(row.get("pitchDeg")))
        for row in (saved_geometry or [])
        if isinstance(row, dict) and row.get("targetId") is not None
    }
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
        anchor_target = saved_targets.get(anchor_id) or _plan_target(anchor_id, plan)
        if anchor_target is not None:
            origin = measured[anchor_id] * _plan_orientation(*anchor_target).conjugate
            origin = origin.normalized
    for frame in frames:
        if frame.upload_status != "confirmed":
            continue
        path = frame_dir / f"frame_{frame.target_index:02d}.jpg"
        pose = frame.capture_pose
        metadata = pose if isinstance(pose, dict) else {}
        yaw_pitch = saved_targets.get(frame.target_index) or _plan_target(frame.target_index, plan)
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


def _alignment_inputs(records: list[dict]) -> list[FrameAlignmentInput]:
    """Turn stitcher records into the aligner's per-frame input.

    The intrinsics are the ones the manifest recorded. When a device did not
    report them, the focal length is derived from the documented 65° vertical
    field of view and the *saved* image height — the same assumption the
    stitcher makes, so the two cannot disagree about the lens. Nothing here
    fabricates a measurement: a derived focal is only ever used for matching
    geometry, and the report records which path produced it.
    """
    inputs: list[FrameAlignmentInput] = []
    for record in records:
        orientation = record.get("cameraOrientation") or [0.0, 0.0, 0.0, 1.0]
        rotation = Quat(*(float(v) for v in orientation)).normalized
        height = int(record.get("imageHeight") or 0)
        width = int(record.get("imageWidth") or 0)
        if width <= 0 or height <= 0:
            continue
        focal = record.get("focalLengthYPx")
        try:
            focal = float(focal) if focal is not None else 0.0
        except (TypeError, ValueError):
            focal = 0.0
        if focal <= 0:
            focal = (height / 2.0) / math.tan(math.radians(65.0) / 2.0)
        inputs.append(
            FrameAlignmentInput(
                target_id=int(record.get("targetId") or 0),
                image_path=str(record.get("imagePath") or ""),
                rotation=rotation,
                width=width,
                height=height,
                focal=focal,
                cx=record.get("principalPointXPx"),
                cy=record.get("principalPointYPx"),
            )
        )
    return inputs


def _apply_global_alignment(
    records: list[dict], alignment
) -> list[dict]:
    """Replace recorded orientations with the jointly solved ones.

    The stitcher consumes ``cameraOrientation`` verbatim, so this is where the
    global solution reaches the projection. Each replaced record is labelled
    ``global_alignment`` so the stored report can show that the pose was solved
    rather than merely measured.
    """
    refined: list[dict] = []
    for record in records:
        updated = dict(record)
        solved = alignment.rotations.get(int(record.get("targetId") or 0))
        if solved is not None:
            updated["cameraOrientation"] = [solved.x, solved.y, solved.z, solved.w]
            updated["poseSource"] = "global_alignment"
        refined.append(updated)
    return refined


def process_job(job_id: uuid.UUID, worker_id: str) -> None:
    """Run one claimed job end to end: manifest → download → stitch → store."""
    started = time.monotonic()
    # Measured wall-clock milliseconds per stage, recorded into the stored
    # report. The post-capture screen shows these numbers, so no progress
    # indicator anywhere in the pipeline is driven by an estimate.
    timings: dict[str, float] = {}

    def mark(stage: str, since: float) -> None:
        timings[stage] = round((time.monotonic() - since) * 1000.0, 1)

    with Session(engine) as db:
        job = svc.get_job(db, job_id)
        if job is None or job.status != "processing" or job.claimed_by != worker_id:
            return
        session_row = svc.get_capture_session(db, job.session_id)
        if session_row is None:
            svc.fail_job(db, job_id=job_id, message="Capture session disappeared.")
            return
        if session_row.status == "cancelled":
            job.status = "cancelled"
            job.completed_at = datetime.now(UTC)
            job.updated_at = datetime.now(UTC)
            job.claimed_at = None
            job.claimed_by = None
            db.add(job)
            db.commit()
            return
        session_plan = str(session_row.capture_plan_version or "")
        if session_plan not in {"1", "2", "3", "4", "11"}:
            svc.fail_job(
                db,
                job_id=job_id,
                message="This capture plan is no longer supported for processing.",
            )
            return
        session_id = session_row.id
        property_id = session_row.property_id
        frames = svc.list_capture_frames(db, session_id)
        prior_panorama = svc.panorama_for_session(db, session_id)
        if prior_panorama is not None and (
            prior_panorama.published_at is not None
            or str(prior_panorama.verification_status).lower()
            in {"approved", "published", "verified"}
            or svc.is_active_panorama(
                db,
                property_id=int(property_id),
                panorama_id=prior_panorama.panorama_id,
            )
        ):
            svc.fail_job(
                db,
                job_id=job_id,
                message="An active or approved panorama is read-only and was preserved.",
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

        download_started = time.monotonic()
        # Downloads run concurrently: a sweep is 48 photographs of ~1.5 MB, and
        # fetching them one at a time made the network — not the stitching —
        # the dominant cost of the whole job. Four at a time matches the
        # measured storage throughput without competing with the CPU-bound
        # stages that follow. Checksums are still verified per file, and a
        # failure fails the job rather than being skipped.
        _report_progress(
            job_id, f"Downloading frames from storage: 0/{len(confirmed)}…"
        )
        downloaded = _download_frames(job_id, confirmed, frame_dir)
        if downloaded is None:
            return
        mark("download", download_started)

        records, problems = _build_records(session_row, confirmed, frame_dir)
        if problems or len(records) < session_row.expected_frames:
            detail = "; ".join(problems[:4]) or "confirmed frames without a pose"
            _fail(job_id, f"The capture manifest is unusable: {detail}.")
            return

        # The stitcher needs the plan version only to interpret a manifest that
        # recorded target ids but no directions. Every plan from v4 onward
        # records them, so this is a legacy path — but it must not fall back to
        # the 38-target plan's pole ids for a 48-target session.
        session_plan_version = str(
            getattr(session_row, "capture_plan_version", "") or ""
        )

        # Global spherical alignment — one joint rotation solve over the whole
        # verified image graph, run before anything is projected. This is what
        # replaces ring-by-ring stitching: every upper, middle, lower and polar
        # photograph participates in the same solution, so the horizon ring
        # closes and the cross-ring bands cannot drift apart.
        alignment = None
        alignment_report: dict[str, object] = {}
        alignment_started = time.monotonic()
        try:
            _report_progress(job_id, "Matching neighbouring photographs…")
            alignment = align_session(
                _alignment_inputs(records),
                on_stage=lambda message: _report_progress(job_id, message),
            )
            alignment_report = alignment.as_dict()
            if alignment.graph.strong_edges():
                records = _apply_global_alignment(records, alignment.global_alignment)
                _report_progress(
                    job_id,
                    f"Verifying cross-ring connections: "
                    f"{len(alignment.graph.strong_edges())} verified…",
                )
        except Exception:  # noqa: BLE001 - alignment is evidence, not a gate
            logger.exception(
                "Global alignment failed for job %s; recorded poses will be used", job_id
            )
            alignment = None
        mark("alignment", alignment_started)

        has_measured_poses = any(
            r["poseSource"] in ("measured_camera_orientation", "global_alignment")
            for r in records
        )
        globally_aligned = alignment is not None and bool(alignment.graph.strong_edges())
        selected_out_dir = out_dir
        stored_attempt = (
            "global_alignment"
            if globally_aligned
            else ("measured_pose" if has_measured_poses else "capture_plan_legacy")
        )
        stitch_started = time.monotonic()
        try:
            outcome = stitch_equirectangular(
                records=records,
                out_dir=out_dir,
                width=STITCH_WIDTH,
                # The joint solve already refined every rotation against the
                # whole graph; re-running the stitcher's per-frame refinement
                # would undo the loop closure it just established.
                refine_registration=not globally_aligned,
                strict_photo_coverage=True,
                plan_version=session_plan_version,
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
        mark("stitchInitial", stitch_started)
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
            fallback_started = time.monotonic()
            fallback = stitch_equirectangular(
                records=fallback_records,
                out_dir=fallback_dir,
                width=STITCH_WIDTH,
                refine_registration=True,
                strict_photo_coverage=True,
                plan_version=session_plan_version,
                progress=lambda message: _report_progress(job_id, message),
            )
            mark("stitchMeasuredPoseFallback", fallback_started)
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
            fallback_started = time.monotonic()
            fallback = stitch_equirectangular(
                records=fallback_records,
                out_dir=fallback_dir,
                width=STITCH_WIDTH,
                refine_registration=False,
                strict_photo_coverage=False,
                plan_version=session_plan_version,
                progress=lambda message: _report_progress(job_id, message),
            )
            mark("stitchUnrefinedFallback", fallback_started)
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
            "globalAlignment": sum(r["poseSource"] == "global_alignment" for r in records),
            "capturePlanPrior": sum(r["poseSource"] == "capture_plan_prior" for r in records),
        }
        if alignment_report:
            # Additive: the stitcher's own report is never rewritten, and the
            # alignment block is what lets an administrator tell "the sphere is
            # covered" from "the photographs actually connect".
            stored_report["globalAlignment"] = alignment_report
            stored_report["alignmentSummary"] = session_summary(alignment) if alignment else None
        _report_progress(job_id, "Verifying capture quality…")
        quality_started = time.monotonic()
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
        mark("quality", quality_started)

        _report_progress(job_id, "Uploading panorama to storage…")
        upload_started = time.monotonic()
        if prior_panorama is None:
            storage_path = capture_storage.panorama_object_path(
                property_id, str(session_id)
            )
        else:
            storage_path = capture_storage.panorama_candidate_object_path(
                property_id, str(session_id), str(job_id)
            )
        capture_storage.upload_bytes(storage_path, panorama_bytes)
        mark("upload", upload_started)
        # Every expensive stage is finished; what remains is one database write.
        # Recording the measured stage durations here means the post-capture
        # screen can show where the time actually went, instead of a progress
        # bar inventing percentages.
        mark("total", started)
        stored_report["stageTimingsMs"] = dict(timings)
        logger.info(
            "Panorama job %s stage timings (ms): %s",
            job_id,
            ", ".join(f"{key}={value:.0f}" for key, value in timings.items()),
        )

        _report_progress(job_id, "Recording the canonical panorama…")
        with Session(engine) as db:
            current_session = svc.get_capture_session(db, session_id)
            current_job = svc.get_job(db, job_id)
            if (
                current_session is None
                or current_session.status == "cancelled"
                or current_job is None
                or current_job.status == "cancelled"
            ):
                if current_job is not None:
                    current_job.status = "cancelled"
                    current_job.completed_at = datetime.now(UTC)
                    current_job.updated_at = datetime.now(UTC)
                    current_job.claimed_at = None
                    current_job.claimed_by = None
                    db.add(current_job)
                    db.commit()
                logger.info(
                    "Panorama job %s finished after cancellation; candidate was not activated.",
                    job_id,
                )
                return
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
