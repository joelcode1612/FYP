"""End-to-end smoke: capture session → storage → worker → canonical panorama.

Drives the real services against the local database and the real Supabase
project: creates a device_38 session, uploads the 38 fixture frames server
side (the signed-URL transport is proven by smoke_capture_storage), confirms
the full manifest, enqueues processing, runs one durable-worker claim that
stitches at 2048 width, and verifies the panorama lands in Storage and in
``fyp.panoramas``. Everything created here is deleted again.

Run:  backend/.venv/Scripts/python.exe backend/scripts/smoke_panorama_worker.py
"""

from __future__ import annotations

import hashlib
import math
import sys
import uuid
from datetime import UTC, datetime
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / "src"))

from dotenv import load_dotenv

load_dotenv(BACKEND / ".env")

import cv2

from sitewise.db.session import Session, engine
from sitewise.panorama.sphere_math import UNIT_X, UNIT_Y, Quat
from sitewise.services import capture_session_service as svc
from sitewise.services import capture_storage, panorama_worker
from sqlalchemy import text

ADMIN_USER = uuid.uuid4()
PROPERTY_ID = 9236
FIXTURES = BACKEND / "var" / "panorama_smoke" / "frames"


def sphere_direction(yaw_deg: float, pitch_deg: float):
    yaw = math.radians(yaw_deg)
    pitch = math.radians(pitch_deg)
    horizontal = math.cos(pitch)
    return (
        math.sin(yaw) * horizontal,
        math.sin(pitch),
        -math.cos(yaw) * horizontal,
    )


def pose_for(yaw_deg: float, pitch_deg: float) -> Quat:
    return Quat.axis_angle(-yaw_deg, UNIT_Y) * Quat.axis_angle(pitch_deg, UNIT_X)


def layout() -> list[tuple[int, float, float]]:
    middle = [0, 30, 60, 90, 120, 150, 180, -150, -120, -90, -60, -30]
    upper = [-30, -60, -90, -120, -150, 180, 150, 120, 90, 60, 30, 0]
    targets: list[tuple[int, float, float]] = []
    target_id = 0
    for yaw in middle:
        target_id += 1
        targets.append((target_id, yaw, 0.0))
    target_id += 1
    targets.append((target_id, 0.0, 90.0))
    for yaw in upper:
        target_id += 1
        targets.append((target_id, yaw, 35.0))
    for yaw in middle:
        target_id += 1
        targets.append((target_id, yaw, -35.0))
    target_id += 1
    targets.append((target_id, 0.0, -90.0))
    return targets


def main() -> int:
    marker = f"smoke-worker-{datetime.now(UTC).strftime('%Y%m%d%H%M%S')}"
    if not FIXTURES.exists():
        raise SystemExit(f"fixtures missing: {FIXTURES} (run the panorama smoke first)")

    with Session(engine) as db:
        session = svc.create_capture_session(
            db,
            property_id=PROPERTY_ID,
            user_id=ADMIN_USER,
            capture_mode="device_38",
            capture_plan_version="smoke",
        )
    session_id = session.id
    print(f"session {session_id} created")

    try:
        # Upload + confirm the 38 frames (server-side writes; transport is
        # separately proven by smoke_capture_storage).
        with Session(engine) as db:
            for target_id, yaw, pitch in layout():
                data = (FIXTURES / f"target_{target_id:02d}.jpg").read_bytes()
                path = capture_storage.frame_object_path(
                    PROPERTY_ID, str(session_id), target_id
                )
                capture_storage.upload_bytes(path, data)
                q = pose_for(yaw, pitch)
                svc.confirm_frame(
                    db,
                    session_id=session_id,
                    target_index=target_id,
                    storage_path=path,
                    checksum_sha256=hashlib.sha256(data).hexdigest(),
                    image_width=768,
                    image_height=1024,
                    capture_pose=[q.x, q.y, q.z, q.w],
                    captured_at=datetime.now(UTC),
                )
            count = svc.confirmed_frame_count(db, session_id)
        assert count == 38, count
        print(f"  ok: 38 frames uploaded + confirmed ({count})")

        job, created = _request(session_id)
        assert created
        print("  ok: job enqueued", job.id)

        ran = panorama_worker.run_once(worker_id="smoke-worker")
        assert ran, "worker found no job"

        with Session(engine) as db:
            done = svc.get_job(db, job.id)
            assert done.status == "done", (done.status, done.error_message)
            assert done.progress == 100
            panorama = svc.latest_property_panorama(db, PROPERTY_ID)
            assert panorama is not None and str(panorama.session_id) == str(session_id)
            assert panorama.coverage_report and panorama.coverage_report.get("passed") is True
        print("  ok: job done, panorama row canonical + coverage passed")

        # The stored panorama must decode as a real 2:1 equirectangular.
        import numpy as np

        data = capture_storage.download(panorama.storage_path)
        buf = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
        assert buf is not None and buf.shape[0] * 2 == buf.shape[1], buf.shape
        print(f"  ok: stored panorama decodes {buf.shape[1]}x{buf.shape[0]} (2:1)")

        view = capture_storage.signed_view_url(panorama.storage_path, expires_in=120)
        import urllib.request

        with urllib.request.urlopen(view, timeout=60) as response:
            assert response.status == 200
        print("  ok: signed view URL serves the panorama")
        print("WORKER SMOKE PASS")
        return 0
    finally:
        # Cleanup: session row (cascades frames/jobs/panorama), storage prefix.
        with Session(engine) as db:
            db.execute(
                text("DELETE FROM fyp.capture_sessions WHERE id = :sid"),
                {"sid": str(session_id)},
            )
            db.commit()
        capture_storage.remove_prefix(f"properties/{PROPERTY_ID}/sessions/{session_id}")
        print("cleanup done")


def _request(session_id: uuid.UUID):
    with Session(engine) as db:
        return svc.request_processing(db, session_id=session_id)


if __name__ == "__main__":
    raise SystemExit(main())
