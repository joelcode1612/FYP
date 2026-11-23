"""Integration tests: canonical panorama administrative review + publication.

Exercises the real ``fyp.panoramas`` lifecycle through
``capture_session_service`` against the live application database, like
``tests/test_database.py``. Every row created here is cleaned up; existing
catalogue rows are only ever read, never modified.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ConflictError, ValidationError
from sitewise.db.session import engine
from sitewise.services import capture_session_service as svc


@pytest.fixture()
def panorama_rows():
    """Bookkeeping for (session_id, panorama_id) rows to remove afterwards."""
    created: list[tuple[str, str]] = []
    yield created
    with Session(engine) as db:
        for session_id, panorama_id in created:
            db.execute(
                text("DELETE FROM fyp.panoramas WHERE panorama_id = :pid"),
                {"pid": panorama_id},
            )
            db.execute(
                text("DELETE FROM fyp.panorama_jobs WHERE session_id = :sid"),
                {"sid": session_id},
            )
            db.execute(
                text("DELETE FROM fyp.capture_frames WHERE session_id = :sid"),
                {"sid": session_id},
            )
            db.execute(
                text("DELETE FROM fyp.capture_sessions WHERE id = :sid"),
                {"sid": session_id},
            )
        db.commit()


def _make_panorama(
    db: Session, created: list, property_id: int
) -> uuid.UUID:
    session_row = svc.create_capture_session(
        db,
        property_id=property_id,
        user_id=uuid.uuid4(),
        capture_mode="device_38",
        capture_plan_version=None,
    )
    panorama = svc.create_panorama(
        db,
        session_id=session_row.id,
        property_id=str(property_id),
        storage_path=f"properties/{property_id}/sessions/{session_row.id}/panorama.jpg",
        width=2048,
        height=1024,
        coverage_report={"engine": "test"},
    )
    created.append((str(session_row.id), str(panorama.panorama_id)))
    return panorama.panorama_id


def _published_listing_id(db: Session) -> int | None:
    return db.execute(
        text(
            "SELECT id FROM fyp.rental_properties "
            "WHERE is_published IS TRUE AND verification_status = 'approved' "
            "LIMIT 1"
        )
    ).scalar()


def _unpublished_listing_id(db: Session) -> int | None:
    return db.execute(
        text(
            "SELECT id FROM fyp.rental_properties "
            "WHERE NOT (is_published IS TRUE AND verification_status = 'approved') "
            "LIMIT 1"
        )
    ).scalar()


def test_rejection_requires_reason(panorama_rows):
    with Session(engine) as db:
        listing = _published_listing_id(db)
        if listing is None:
            pytest.skip("No published listing available for the test.")
        panorama_id = _make_panorama(db, panorama_rows, listing)
        with pytest.raises(ValidationError):
            svc.review_panorama(
                db,
                panorama_id=panorama_id,
                reviewer_id=uuid.uuid4(),
                decision="rejected",
                reason=None,
            )
        with pytest.raises(ValidationError):
            svc.review_panorama(
                db,
                panorama_id=panorama_id,
                reviewer_id=uuid.uuid4(),
                decision="rejected",
                reason="   ",
            )
        row = db.execute(
            text(
                "SELECT verification_status FROM fyp.panoramas "
                "WHERE panorama_id = :pid"
            ),
            {"pid": str(panorama_id)},
        ).scalar()
        assert row == "pending", "A failed rejection must not mutate the row."


def test_invalid_decision_rejected(panorama_rows):
    with Session(engine) as db:
        listing = _published_listing_id(db)
        if listing is None:
            pytest.skip("No published listing available for the test.")
        panorama_id = _make_panorama(db, panorama_rows, listing)
        with pytest.raises(ValidationError):
            svc.review_panorama(
                db,
                panorama_id=panorama_id,
                reviewer_id=uuid.uuid4(),
                decision="published",
            )


def test_publish_requires_approval_first(panorama_rows):
    with Session(engine) as db:
        listing = _published_listing_id(db)
        if listing is None:
            pytest.skip("No published listing available for the test.")
        panorama_id = _make_panorama(db, panorama_rows, listing)
        with pytest.raises(ConflictError):
            svc.publish_panorama(
                db, panorama_id=panorama_id, publisher_id=uuid.uuid4()
            )


def test_publish_requires_published_listing(panorama_rows):
    with Session(engine) as db:
        listing = _unpublished_listing_id(db)
        if listing is None:
            pytest.skip("No unpublished listing available for the test.")
        panorama_id = _make_panorama(db, panorama_rows, listing)
        svc.review_panorama(
            db,
            panorama_id=panorama_id,
            reviewer_id=uuid.uuid4(),
            decision="approved",
        )
        with pytest.raises(ConflictError):
            svc.publish_panorama(
                db, panorama_id=panorama_id, publisher_id=uuid.uuid4()
            )


def test_full_review_publish_unpublish_flow(panorama_rows):
    with Session(engine) as db:
        listing = _published_listing_id(db)
        if listing is None:
            pytest.skip("No published listing available for the test.")
        # Only one published tour per property: never publish onto a listing
        # that an earlier test or real data already published for.
        existing = db.execute(
            text(
                "SELECT panorama_id FROM fyp.panoramas "
                "WHERE property_id = :pid AND published_at IS NOT NULL"
            ),
            {"pid": str(listing)},
        ).scalar()
        if existing is not None:
            pytest.skip(
                "The chosen listing already carries a published panorama."
            )
        panorama_id = _make_panorama(db, panorama_rows, listing)

        # Stitched-but-unreviewed: invisible to entrepreneurs.
        assert svc.published_property_panorama(db, listing) is None

        # Rejection first — still invisible.
        rejected = svc.review_panorama(
            db,
            panorama_id=panorama_id,
            reviewer_id=uuid.uuid4(),
            decision="rejected",
            reason="Seam duplication across the doorway.",
        )
        assert rejected.verification_status == "rejected"
        assert rejected.review_reason == "Seam duplication across the doorway."
        assert svc.published_property_panorama(db, listing) is None

        # Re-review approves; the audit trail keeps the latest decision.
        approved = svc.review_panorama(
            db,
            panorama_id=panorama_id,
            reviewer_id=uuid.uuid4(),
            decision="approved",
        )
        assert approved.verification_status == "approved"
        assert approved.reviewed_by is not None
        assert approved.reviewed_at is not None
        assert svc.published_property_panorama(db, listing) is None

        # Publish makes exactly this row entrepreneur-visible.
        published = svc.publish_panorama(
            db, panorama_id=panorama_id, publisher_id=uuid.uuid4()
        )
        assert published.published_at is not None
        visible = svc.published_property_panorama(db, listing)
        assert visible is not None
        assert visible.panorama_id == panorama_id

        # A second publish for the same property would disagree with the
        # first tour — refused.
        second = _make_panorama(db, panorama_rows, listing)
        svc.review_panorama(
            db,
            panorama_id=second,
            reviewer_id=uuid.uuid4(),
            decision="approved",
        )
        with pytest.raises(ConflictError):
            svc.publish_panorama(
                db, panorama_id=second, publisher_id=uuid.uuid4()
            )

        # Unpublish hides it again without deleting anything.
        svc.unpublish_panorama(db, panorama_id=panorama_id)
        assert svc.published_property_panorama(db, listing) is None
        still_there = svc.get_panorama(db, panorama_id)
        assert still_there is not None
        assert still_there.verification_status == "approved"
