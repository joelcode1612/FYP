"""Smoke test for the capture-session service against the local database.

Exercises authorization, frame idempotency, manifest completeness, the
one-live-job guard, worker claiming (FOR UPDATE SKIP LOCKED), retry and
panorama persistence — the rules the /360 API and the stitching worker both
depend on. Rows created here are deleted again at the end.

Run:  backend/.venv/Scripts/python.exe backend/scripts/smoke_capture_360_service.py
"""

from __future__ import annotations

import sys
import uuid
from datetime import UTC, datetime
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / "src"))

from dotenv import load_dotenv

load_dotenv(BACKEND / ".env")

from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ForbiddenError, NotFoundError, ValidationError
from sitewise.db.session import engine
from sitewise.services import capture_session_service as svc

USER_A = uuid.uuid4()  # acting owner/admin identity for the run
OTHER_USER = uuid.uuid4()


def pick_property(db: Session) -> tuple[int, str]:
    row = db.execute(
        text(
            "SELECT id, owner_user_id FROM fyp.rental_properties "
            "WHERE owner_user_id IS NOT NULL ORDER BY id DESC LIMIT 1"
        )
    ).first()
    if row is None:
        raise SystemExit("no rental_properties with an owner to test against")
    return int(row[0]), str(row[1])


def expect_error(fn, exc_type, label: str) -> None:
    try:
        fn()
    except exc_type:
        print(f"  ok: {label} -> {exc_type.__name__}")
        return
    raise AssertionError(f"{label} did not raise {exc_type.__name__}")


def main() -> int:
    marker = f"smoke-capture-{uuid.uuid4().hex[:8]}"
    session_id: uuid.UUID | None = None
    session_id_2: uuid.UUID | None = None
    with Session(engine) as db:
        property_id, real_owner = pick_property(db)
        print(f"property {property_id} (owner {real_owner[:8]}…)")

        # ── Authorization ────────────────────────────────────────────────
        svc.ensure_property_access(
            db, property_id=property_id, user_id=USER_A, role="admin"
        )
        print("  ok: admin passes")
        expect_error(
            lambda: svc.ensure_property_access(
                db, property_id=property_id, user_id=OTHER_USER, role="entrepreneur"
            ),
            ForbiddenError,
            "unrelated entrepreneur blocked",
        )
        expect_error(
            lambda: svc.ensure_property_access(
                db, property_id=999999999, user_id=USER_A, role="admin"
            ),
            NotFoundError,
            "unknown property 404",
        )

        # ── Session lifecycle ────────────────────────────────────────────
        session = svc.create_capture_session(
            db,
            property_id=property_id,
            user_id=USER_A,
            capture_mode="device_38",
            capture_plan_version="test-1",
        )
        session_id = session.id
        assert session.expected_frames == 38 and session.status == "capturing"
        print("  ok: session created, 38 expected")
        expect_error(
            lambda: svc.create_capture_session(
                db,
                property_id=property_id,
                user_id=USER_A,
                capture_mode="device_99",
                capture_plan_version=None,
            ),
            ValidationError,
            "unknown capture_mode rejected",
        )
        resolved = svc.require_capture_session(
            db, session_id=session_id, user_id=USER_A, role="admin"
        )
        assert resolved.id == session_id
        print("  ok: session access resolved")

        # ── Frame confirmation + idempotency ─────────────────────────────
        prefix = f"properties/{property_id}/sessions/{session_id}/frames/"
        pose = [0.0, 0.0, 0.0, 1.0]
        frame, created = svc.confirm_frame(
            db,
            session_id=session_id,
            target_index=1,
            storage_path=f"{prefix}1.jpg",
            checksum_sha256="a" * 64,
            image_width=768,
            image_height=1024,
            capture_pose=pose,
            captured_at=datetime.now(UTC),
        )
        assert created and frame.upload_status == "confirmed"
        frame2, created2 = svc.confirm_frame(
            db,
            session_id=session_id,
            target_index=1,
            storage_path=f"{prefix}1.jpg",
            checksum_sha256="b" * 64,
            image_width=768,
            image_height=1024,
            capture_pose=pose,
            captured_at=None,
        )
        assert not created2 and frame2.id == frame.id
        assert frame2.checksum_sha256 == "b" * 64
        print("  ok: frame confirm idempotent (same id, checksum updated)")

        expect_error(
            lambda: svc.confirm_frame(
                db,
                session_id=session_id,
                target_index=39,
                storage_path=f"{prefix}39.jpg",
                checksum_sha256=None,
                image_width=None,
                image_height=None,
                capture_pose=None,
                captured_at=None,
            ),
            ValidationError,
            "target_index beyond plan rejected",
        )

        for target in range(2, 39):
            svc.confirm_frame(
                db,
                session_id=session_id,
                target_index=target,
                storage_path=f"{prefix}{target}.jpg",
                checksum_sha256=None,
                image_width=768,
                image_height=1024,
                capture_pose=pose,
                captured_at=None,
            )
        assert svc.confirmed_frame_count(db, session_id) == 38
        refreshed = svc.get_capture_session(db, session_id)
        assert refreshed.status == "uploaded", refreshed.status
        print("  ok: 38 frames confirmed, session -> uploaded")

        # ── Processing guards ────────────────────────────────────────────
        incomplete = svc.create_capture_session(
            db,
            property_id=property_id,
            user_id=USER_A,
            capture_mode="arcore_26",
            capture_plan_version=None,
        )
        session_id_2 = incomplete.id
        expect_error(
            lambda: svc.request_processing(db, session_id=incomplete.id),
            ValidationError,
            "incomplete session cannot process",
        )

        job, created_job = svc.request_processing(db, session_id=session_id)
        assert created_job and job.status == "queued"
        job_again, created_again = svc.request_processing(db, session_id=session_id)
        assert not created_again and job_again.id == job.id
        print("  ok: processing enqueued once (live-job guard)")

        # ── Worker claiming ──────────────────────────────────────────────
        claimed = svc.claim_next_job(
            db, worker_id="worker-smoke", stale_after_seconds=900
        )
        assert claimed is not None and claimed.id == job.id
        assert claimed.status == "processing" and claimed.claimed_by == "worker-smoke"
        none_left = svc.claim_next_job(
            db, worker_id="worker-smoke-2", stale_after_seconds=900
        )
        assert none_left is None
        print("  ok: FOR UPDATE SKIP LOCKED claim, no double claim")

        svc.set_job_progress(db, job_id=job.id, stage="projection", progress=40)
        svc.fail_job(db, job_id=job.id, message="smoke failure")
        failed = svc.get_job(db, job.id)
        assert failed.status == "error" and failed.error_message == "smoke failure"
        retried = svc.retry_job(db, job_id=job.id)
        assert retried.status == "queued" and retried.retry_count == 1
        expect_error(
            lambda: svc.retry_job(db, job_id=job.id),
            ValidationError,
            "queued job cannot retry",
        )
        print("  ok: fail -> retry requeued, retry_count=1")

        svc.claim_next_job(db, worker_id="worker-smoke", stale_after_seconds=900)
        panorama = svc.create_panorama(
            db,
            session_id=session_id,
            property_id=str(property_id),
            storage_path=f"properties/{property_id}/sessions/{session_id}/panorama.jpg",
            width=2048,
            height=1024,
            coverage_report={"passed": True},
        )
        svc.complete_job(
            db,
            job_id=job.id,
            output_storage_path=panorama.storage_path,
            panorama_id=panorama.panorama_id,
        )
        done = svc.get_job(db, job.id)
        assert done.status == "done" and done.progress == 100
        assert svc.get_capture_session(db, session_id).status == "completed"
        panorama_again = svc.create_panorama(
            db,
            session_id=session_id,
            property_id=str(property_id),
            storage_path=panorama.storage_path,
            width=2048,
            height=1024,
            coverage_report={"passed": True},
        )
        assert panorama_again.panorama_id == panorama.panorama_id
        latest = svc.latest_property_panorama(db, property_id)
        assert latest.panorama_id == panorama.panorama_id
        print("  ok: panorama persisted once, job done, session completed")

        expect_error(
            lambda: svc.require_capture_session(
                db, session_id=session_id, user_id=OTHER_USER, role="entrepreneur"
            ),
            ForbiddenError,
            "session read blocked for outsider",
        )
        print("SERVICE SMOKE PASS")

    # ── Cleanup: remove the rows this run created ────────────────────────
    with Session(engine) as db:
        if session_id is not None:
            db.execute(
                text("DELETE FROM fyp.capture_sessions WHERE id = :sid"),
                {"sid": str(session_id)},
            )
        if session_id_2 is not None:
            db.execute(
                text("DELETE FROM fyp.capture_sessions WHERE id = :sid"),
                {"sid": str(session_id_2)},
            )
        db.commit()
    print("cleanup done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
