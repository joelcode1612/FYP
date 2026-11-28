"""Persistence for the adaptive capture plan and the incremental image graph.

Two responsibilities, both narrow:

* **The plan.** The five-ring layout is generated from the camera's actual
  field of view, so it cannot be re-derived from a frame count. It is stored
  with the session and returned verbatim on resume, which is what keeps target
  identifiers stable across an app restart. A historical session has no stored
  plan and is never given one — its geometry stays whatever
  ``capture_plan_version`` says it was.
* **The matches.** Each verified or refused image pair is one row. Writes are
  upserts on the ordered pair, so re-matching a connection corrects the record
  instead of adding a contradictory second opinion.

Nothing here recomputes geometry. The mobile client owns target generation and
the backend owns verification; this module only records what both decided.
"""

from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime
from typing import Any, Iterable

from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import NotFoundError
from sitewise.panorama import plan_v11, plan_v12
from sitewise.services.capture_session_service import ADAPTIVE_MODES

logger = logging.getLogger("sitewise.services.capture_alignment")

#: Frames need this many verified connections to count as connected.
VERIFIED_CONNECTION_FLOOR = 2


def _now() -> datetime:
    return datetime.now(UTC)


def _require_session(session: Session, session_id: uuid.UUID) -> None:
    exists = session.execute(
        text("SELECT 1 FROM fyp.capture_sessions WHERE id = :sid"),
        {"sid": str(session_id)},
    ).first()
    if exists is None:
        raise NotFoundError("Capture session not found.")


def _geometry_signature(geometry: list[dict[str, Any]]) -> list[tuple[Any, ...]]:
    """The full, order-independent identity of a stored target plan.

    Target ids alone are not enough: two plans can use the same ids with
    different yaw/pitch or a different guided order. Refusing only on id
    changes would let a retry silently reinterpret already-captured frames.
    """
    signature: list[tuple[Any, ...]] = []
    for target in geometry:
        if not isinstance(target, dict):
            continue
        order = target.get("captureOrder")
        signature.append(
            (
                int(target.get("targetId") or 0),
                round(float(target.get("yawDeg") or 0), 6),
                round(float(target.get("pitchDeg") or 0), 6),
                str(target.get("ring") or ""),
                int(order) if order is not None else None,
            )
        )
    return sorted(signature, key=lambda item: item[0])


def save_capture_plan(
    session: Session,
    *,
    session_id: uuid.UUID,
    geometry: list[dict[str, Any]],
    intrinsics: dict[str, Any] | None = None,
    plan_version: str | None = None,
) -> None:
    """Persist the generated target geometry for this session.

    Idempotent by design: writing the same plan twice is a no-op, and writing a
    *different* plan for a session that already has one is refused, because
    silently replacing the geometry would orphan every photograph already
    captured against the old target identifiers.
    """
    _require_session(session, session_id)
    # Identity check against the canonical layout. Deliberately non-fatal: the
    # device owns target generation, and aborting a sweep over a label mismatch
    # would be worse than recording it. The discrepancy is logged here and
    # surfaced in the report through ``plan_summary``.
    version = str(plan_version or "")
    if version in {"5", "6", "7", "8", "9", "10"}:
        raise ValueError(f"Capture plan {version} is no longer supported for execution.")
    # Version 4 is an earlier adaptive five-ring plan. Its geometry is
    # generated from the measured lens, so it is not compared against a fixed
    # table; the stored payload is the authority. Version 11 remains readable
    # for sessions captured with its fixed staggered layout.
    if version == plan_v11.PLAN_V11_VERSION and len(geometry) != plan_v11.PLAN_V11_TARGET_COUNT:
        raise ValueError("Capture plan 11 must contain exactly 44 targets.")
    # Plan 12 is the canonical plan for every new session. Unlike 4 and 11 it
    # has a fixed reference table, so a payload claiming 12 must match it
    # exactly: two different geometries under one version label would silently
    # mix target identities across sessions.
    if version == plan_v12.PLAN_V12_VERSION:
        if len(geometry) != plan_v12.PLAN_V12_TARGET_COUNT:
            raise ValueError("Capture plan 12 must contain exactly 44 targets.")
        plan_problems = plan_v12.validate_plan_geometry(geometry, plan_version)
        if plan_problems:
            raise ValueError(
                "Capture plan 12 geometry does not match the canonical "
                f"layout: {plan_problems[0]}"
            )
        logger.info(
            "Capture session %s saved the canonical plan 12 layout.",
            session_id,
        )
    problems = plan_v11.validate_plan_geometry(geometry, plan_version)
    if problems:
        logger.warning(
            "Capture session %s claims plan version %s but its geometry differs "
            "from the canonical layout: %s",
            session_id,
            plan_version,
            "; ".join(problems[:4]),
        )
    row = session.execute(
        text(
            "SELECT plan_geometry, capture_mode, expected_frames, "
            "capture_plan_version FROM fyp.capture_sessions WHERE id = :sid"
        ),
        {"sid": str(session_id)},
    ).first()
    existing = row[0] if row else None
    if existing:
        if _geometry_signature(existing) != _geometry_signature(geometry):
            raise ValueError(
                "This capture session already has a different target plan; "
                "resume it rather than replacing its geometry."
            )
        stored_version = row[3] if row is not None else None
        if plan_version is not None and str(stored_version or "") != str(plan_version):
            # Same geometry, missing/older label: settle the version now so the
            # device's plan-version assertion on create cannot fail on retry.
            session.execute(
                text(
                    "UPDATE fyp.capture_sessions "
                    "SET capture_plan_version = :version, updated_at = now() "
                    "WHERE id = :sid"
                ),
                {"version": str(plan_version), "sid": str(session_id)},
            )
            session.commit()
        return

    # An adaptive session's frame count is the plan's target count. A plan
    # written after the session was created must therefore settle that count —
    # but only while the session is still empty: changing how many photographs
    # are expected after some exist would make the completeness check lie.
    expected = None
    if row is not None and row[1] in ADAPTIVE_MODES:
        if int(row[2] or 0) != len(geometry):
            captured = session.execute(
                text(
                    "SELECT COUNT(*) FROM fyp.capture_frames WHERE session_id = :sid"
                ),
                {"sid": str(session_id)},
            ).scalar_one()
            if captured:
                raise ValueError(
                    "This capture session has already recorded photographs, so "
                    "its target count cannot be changed."
                )
            expected = len(geometry)

    session.execute(
        text(
            "UPDATE fyp.capture_sessions "
            "SET plan_geometry = CAST(:geometry AS jsonb), "
            "    plan_intrinsics = CAST(:intrinsics AS jsonb), "
            "    capture_plan_version = COALESCE(:version, capture_plan_version), "
            "    expected_frames = COALESCE(:expected, expected_frames), "
            "    updated_at = now() "
            "WHERE id = :sid"
        ),
        {
            "geometry": _json(geometry),
            "intrinsics": _json(intrinsics) if intrinsics is not None else None,
            "version": plan_version,
            "expected": expected,
            "sid": str(session_id),
        },
    )
    session.commit()


def stored_plan(session: Session, session_id: uuid.UUID) -> dict[str, Any] | None:
    """The persisted plan, or ``None`` for a historical session."""
    row = session.execute(
        text(
            "SELECT plan_geometry, plan_intrinsics, capture_plan_version "
            "FROM fyp.capture_sessions WHERE id = :sid"
        ),
        {"sid": str(session_id)},
    ).first()
    if row is None:
        raise NotFoundError("Capture session not found.")
    if not row[0]:
        return None
    return {
        "geometry": row[0],
        "intrinsics": row[1],
        "planVersion": row[2],
        # Additive: lets a report state whether the stored geometry still
        # matches the canonical layout it claims, without re-deriving it.
        "summary": plan_v11.plan_summary(row[0], row[2])
        if plan_v11.is_canonical_version(row[2])
        else None,
    }


def record_matches(
    session: Session,
    *,
    session_id: uuid.UUID,
    matches: Iterable[dict[str, Any]],
) -> int:
    """Upsert image-pair verdicts. Returns the number of rows written."""
    written = 0
    for match in matches:
        first = int(match.get("a") or 0)
        second = int(match.get("b") or 0)
        if first <= 0 or second <= 0 or first == second:
            continue
        target_a, target_b = (first, second) if first < second else (second, first)
        session.execute(
            text(
                """
                INSERT INTO fyp.capture_frame_matches (
                    session_id, target_a, target_b, state, inliers, candidates,
                    inlier_ratio, median_error_px, p95_error_px, spread_cells,
                    azimuth_sectors, confidence, reason, updated_at
                ) VALUES (
                    :sid, :a, :b, :state, :inliers, :candidates,
                    :ratio, :median, :p95, :spread,
                    :sectors, :confidence, :reason, now()
                )
                ON CONFLICT (session_id, target_a, target_b) DO UPDATE SET
                    state = EXCLUDED.state,
                    inliers = EXCLUDED.inliers,
                    candidates = EXCLUDED.candidates,
                    inlier_ratio = EXCLUDED.inlier_ratio,
                    median_error_px = EXCLUDED.median_error_px,
                    p95_error_px = EXCLUDED.p95_error_px,
                    spread_cells = EXCLUDED.spread_cells,
                    azimuth_sectors = EXCLUDED.azimuth_sectors,
                    confidence = EXCLUDED.confidence,
                    reason = EXCLUDED.reason,
                    updated_at = now()
                """
            ),
            {
                "sid": str(session_id),
                "a": target_a,
                "b": target_b,
                "state": str(match.get("state") or "failed"),
                "inliers": int(match.get("inliers") or 0),
                "candidates": int(match.get("candidates") or 0),
                "ratio": float(match.get("inlierRatio") or 0.0),
                "median": float(match.get("medianErrorPx") or 0.0),
                "p95": float(match.get("p95ErrorPx") or 0.0),
                "spread": int(match.get("spreadCells") or 0),
                "sectors": int(match.get("azimuthSectors") or 0),
                "confidence": float(match.get("confidence") or 0.0),
                "reason": match.get("reason"),
            },
        )
        written += 1
    if written:
        _refresh_frame_status(session, session_id)
    session.commit()
    return written


def _refresh_frame_status(session: Session, session_id: uuid.UUID) -> None:
    """Recompute each frame's matching status from its verified edges.

    Computed in Python rather than as one large UPDATE…FROM: the aggregation is
    three lines here and the SQL equivalent needed two CTEs and a lateral join
    to express the same thing, which is a maintenance cost with no benefit at
    44 rows per session.
    """
    rows = session.execute(
        text(
            "SELECT target_a, target_b, state, confidence "
            "FROM fyp.capture_frame_matches WHERE session_id = :sid"
        ),
        {"sid": str(session_id)},
    ).mappings().all()

    strong: dict[int, int] = {}
    best_confidence: dict[int, float] = {}
    for row in rows:
        for target in (row["target_a"], row["target_b"]):
            confidence = float(row["confidence"] or 0.0)
            if confidence > best_confidence.get(target, 0.0):
                best_confidence[target] = confidence
            if row["state"] == "strong":
                strong[target] = strong.get(target, 0) + 1

    frames = session.execute(
        text("SELECT target_index FROM fyp.capture_frames WHERE session_id = :sid"),
        {"sid": str(session_id)},
    ).scalars().all()

    for target in frames:
        count = strong.get(target, 0)
        if count >= VERIFIED_CONNECTION_FLOOR:
            status = "verified"
        elif count > 0:
            status = "connected"
        elif target in best_confidence:
            status = "weak"
        else:
            status = "pending"
        session.execute(
            text(
                "UPDATE fyp.capture_frames "
                "SET matching_status = :status, matching_confidence = :confidence "
                "WHERE session_id = :sid AND target_index = :target"
            ),
            {
                "status": status,
                "confidence": best_confidence.get(target),
                "sid": str(session_id),
                "target": int(target),
            },
        )


def alignment_state(session: Session, session_id: uuid.UUID) -> dict[str, Any]:
    """Everything the capture screen and the admin panel read about alignment."""
    _require_session(session, session_id)
    matches = session.execute(
        text(
            "SELECT target_a, target_b, state, inliers, candidates, inlier_ratio, "
            "       median_error_px, p95_error_px, spread_cells, azimuth_sectors, "
            "       confidence, reason "
            "FROM fyp.capture_frame_matches WHERE session_id = :sid "
            "ORDER BY target_a, target_b"
        ),
        {"sid": str(session_id)},
    ).mappings().all()
    frames = session.execute(
        text(
            "SELECT target_index, matching_status, matching_confidence, "
            "       coverage_contribution "
            "FROM fyp.capture_frames WHERE session_id = :sid "
            "ORDER BY target_index"
        ),
        {"sid": str(session_id)},
    ).mappings().all()
    summary = session.execute(
        text("SELECT alignment_summary FROM fyp.capture_sessions WHERE id = :sid"),
        {"sid": str(session_id)},
    ).scalar()

    strong = [m for m in matches if m["state"] == "strong"]
    weak = [m for m in matches if m["state"] == "weak"]
    verified_targets = sorted(
        {m["target_a"] for m in strong} | {m["target_b"] for m in strong}
    )
    return {
        "sessionId": str(session_id),
        "verifiedConnections": len(strong),
        "weakConnections": len(weak),
        "failedConnections": len(matches) - len(strong) - len(weak),
        "verifiedTargets": verified_targets,
        "frames": [
            {
                "targetId": row["target_index"],
                "status": row["matching_status"] or "pending",
                "confidence": row["matching_confidence"],
                "coverageContribution": row["coverage_contribution"],
            }
            for row in frames
        ],
        "matches": [
            {
                "a": row["target_a"],
                "b": row["target_b"],
                "state": row["state"],
                "inliers": row["inliers"],
                "candidates": row["candidates"],
                "inlierRatio": row["inlier_ratio"],
                "medianErrorPx": row["median_error_px"],
                "p95ErrorPx": row["p95_error_px"],
                "spreadCells": row["spread_cells"],
                "azimuthSectors": row["azimuth_sectors"],
                "confidence": row["confidence"],
                "reason": row["reason"],
            }
            for row in matches
        ],
        "summary": summary,
    }


def save_alignment_summary(
    session: Session, *, session_id: uuid.UUID, summary: dict[str, Any]
) -> None:
    """Store the last full-session alignment result on the session row."""
    session.execute(
        text(
            "UPDATE fyp.capture_sessions "
            "SET alignment_summary = CAST(:summary AS jsonb), updated_at = now() "
            "WHERE id = :sid"
        ),
        {"summary": _json(summary), "sid": str(session_id)},
    )
    session.commit()


def save_coverage_contributions(
    session: Session,
    *,
    session_id: uuid.UUID,
    contributions: dict[int, float],
) -> None:
    """Record each photograph's share of the sphere, for the coverage panel."""
    for target_id, fraction in contributions.items():
        session.execute(
            text(
                "UPDATE fyp.capture_frames SET coverage_contribution = :value "
                "WHERE session_id = :sid AND target_index = :target"
            ),
            {"value": float(fraction), "sid": str(session_id), "target": int(target_id)},
        )
    session.commit()


def _json(value: Any) -> str:
    import json

    return json.dumps(value, separators=(",", ":"), default=str)


__all__ = [
    "VERIFIED_CONNECTION_FLOOR",
    "alignment_state",
    "record_matches",
    "save_alignment_summary",
    "save_capture_plan",
    "save_coverage_contributions",
    "stored_plan",
]
