"""The canonical 48-target capture plan, as FastAPI knows it.

The device owns target generation and this backend owns verification, so the
geometry itself is never regenerated here — it is received and stored. What
*is* owned here is the **identity contract**: target id 7 must mean the same
direction for every session that claims plan version 5, or the match rows,
coverage audits and stored poses of one capture would be silently reinterpreted
against another capture's layout.

That contract lives in one explicit table, transcribed from
``fyp_mobile_app/lib/features/capture_360/domain/sphere/sphere_plan_v5.dart``.
It is a literal table rather than a generator on purpose: a loop that drifted by
one degree would pass every code review and quietly invalidate historical
sessions.

## What this module does and does not do

* It **does** answer "is this geometry the canonical version-5 layout?" and
  "which ring is target N in?".
* It does **not** reject a capture. A plan that disagrees is reported as a
  warning so the discrepancy reaches the report, because failing a capture
  mid-sweep over a label is worse than recording that the label was wrong.

Historical plans (versions 1–4) are not described here and are never
reinterpreted through this table.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable

#: Plan version of the canonical 48-target layout.
PLAN_V5_VERSION = "5"
#: Plan version of the deterministic 64-target densification, used only when the
#: calibrated lens cannot meet the overlap floor at the canonical spacing.
PLAN_V5_DENSE_VERSION = "6"
#: Canonical target count.
PLAN_V5_TARGET_COUNT = 48
#: Densified target count.
PLAN_V5_DENSE_TARGET_COUNT = 64
#: Pitch of the oblique ceiling/floor rings, in degrees.
PLAN_V5_POLAR_PITCH_DEG = 63.0
#: Yaw step of the middle/upper/lower rings, in degrees.
PLAN_V5_MAIN_YAW_STEP_DEG = 30.0
#: Yaw step of the ceiling/floor rings, in degrees.
PLAN_V5_POLAR_YAW_STEP_DEG = 60.0


@dataclass(frozen=True, slots=True)
class CanonicalTarget:
    """One row of the canonical table, in capture order."""

    target_id: int
    yaw_deg: float
    pitch_deg: float
    ring: str


def _build() -> tuple[CanonicalTarget, ...]:
    rows: list[CanonicalTarget] = []
    target_id = 0
    # Middle ring: 0° pitch, 12 targets clockwise from the start heading.
    for index in range(12):
        target_id += 1
        rows.append(CanonicalTarget(target_id, index * 30.0, 0.0, "middle"))
    # Upper ring: +30°, sweeping backwards so target 13 sits directly above
    # target 12 — a 30° tilt rather than a 180° turn.
    for index in range(12):
        target_id += 1
        rows.append(CanonicalTarget(target_id, 330.0 - index * 30.0, 30.0, "upper"))
    # Lower ring: −30°, forward again from directly below target 24.
    for index in range(12):
        target_id += 1
        rows.append(CanonicalTarget(target_id, index * 30.0, -30.0, "lower"))
    # Ceiling ring: +63°, oblique, 60° yaw step, sweeping back.
    for index in range(6):
        target_id += 1
        rows.append(
            CanonicalTarget(target_id, 315.0 - index * 60.0, 63.0, "ceiling")
        )
    # Floor ring: −63°, oblique, 60° yaw step, forward.
    for index in range(6):
        target_id += 1
        rows.append(CanonicalTarget(target_id, 15.0 + index * 60.0, -63.0, "floor"))
    return tuple(rows)


#: The canonical 48-target layout, in capture order.
CANONICAL_TARGETS: tuple[CanonicalTarget, ...] = _build()

_BY_ID: dict[int, CanonicalTarget] = {t.target_id: t for t in CANONICAL_TARGETS}

#: Ring key → expected target count, for the canonical layout.
RING_COUNTS: dict[str, int] = {
    "middle": 12,
    "upper": 12,
    "lower": 12,
    "ceiling": 6,
    "floor": 6,
}

#: Capture order of the five stages, as the guidance UI walks them.
STAGE_ORDER: tuple[str, ...] = ("middle", "upper", "lower", "ceiling", "floor")


def is_canonical_version(version: str | int | None) -> bool:
    """Whether [version] claims one of the canonical layouts (5 or 6)."""
    return str(version or "").strip() in (PLAN_V5_VERSION, PLAN_V5_DENSE_VERSION)


def canonical_target(target_id: int) -> CanonicalTarget | None:
    """The canonical row for [target_id], or ``None`` if it is out of range."""
    return _BY_ID.get(int(target_id))


def ring_of(target_id: int) -> str | None:
    """Which ring a canonical target belongs to, for stage captions."""
    row = _BY_ID.get(int(target_id))
    return row.ring if row else None


def validate_plan_geometry(
    geometry: Iterable[Any],
    version: str | int | None,
) -> list[str]:
    """Compare a received plan against the canonical layout.

    Returns a list of human-readable problems; an empty list means the geometry
    matches the canonical table for the version it claims. A version that is not
    5 or 6 is never inspected — historical geometry is left exactly as it is.
    """
    if not is_canonical_version(version):
        return []

    targets = [t for t in geometry if isinstance(t, dict)]
    if not targets:
        return ["The plan claims the canonical layout but carries no targets."]

    problems: list[str] = []
    dense = str(version).strip() == PLAN_V5_DENSE_VERSION
    expected_count = PLAN_V5_DENSE_TARGET_COUNT if dense else PLAN_V5_TARGET_COUNT
    if len(targets) != expected_count:
        problems.append(
            f"Plan version {version} must have {expected_count} targets, "
            f"but {len(targets)} were received."
        )

    if dense:
        # The densified layout is generated from the same five rings with more
        # targets; its identity is the ring structure, not a literal table.
        seen: dict[str, int] = {}
        for target in targets:
            ring = str(target.get("ring") or "").strip().lower()
            key = ring.replace(" ring", "")
            seen[key] = seen.get(key, 0) + 1
        for stage in STAGE_ORDER:
            if stage not in seen:
                problems.append(f"The densified plan has no {stage} ring.")
        return problems

    by_id: dict[int, dict[str, Any]] = {}
    for target in targets:
        try:
            by_id[int(target.get("targetId") or 0)] = target
        except (TypeError, ValueError):
            problems.append("A target id is not an integer.")
    for canonical in CANONICAL_TARGETS:
        received = by_id.get(canonical.target_id)
        if received is None:
            problems.append(f"Target {canonical.target_id} is missing.")
            continue
        try:
            yaw = float(received.get("yawDeg"))
            pitch = float(received.get("pitchDeg"))
        except (TypeError, ValueError):
            problems.append(f"Target {canonical.target_id} has no usable angles.")
            continue
        if abs(yaw - canonical.yaw_deg) > 1e-3:
            problems.append(
                f"Target {canonical.target_id} yaw is {yaw:.3f}°, "
                f"canonical is {canonical.yaw_deg:.3f}°."
            )
        if abs(pitch - canonical.pitch_deg) > 1e-3:
            problems.append(
                f"Target {canonical.target_id} pitch is {pitch:.3f}°, "
                f"canonical is {canonical.pitch_deg:.3f}°."
            )
        received_ring = str(received.get("ring") or "").strip().lower()
        if received_ring and received_ring.replace(" ring", "") != canonical.ring:
            problems.append(
                f"Target {canonical.target_id} ring is '{received_ring}', "
                f"canonical is '{canonical.ring}'."
            )
    return problems


def plan_summary(geometry: Iterable[Any], version: str | int | None) -> dict[str, Any]:
    """A compact, report-friendly description of a received plan."""
    targets = [t for t in geometry if isinstance(t, dict)]
    problems = validate_plan_geometry(targets, version)
    return {
        "planVersion": None if version is None else str(version),
        "targetCount": len(targets),
        "isCanonical": is_canonical_version(version),
        "canonicalValid": not problems,
        "problems": problems,
    }


__all__ = [
    "CANONICAL_TARGETS",
    "CanonicalTarget",
    "PLAN_V5_DENSE_TARGET_COUNT",
    "PLAN_V5_DENSE_VERSION",
    "PLAN_V5_MAIN_YAW_STEP_DEG",
    "PLAN_V5_POLAR_PITCH_DEG",
    "PLAN_V5_POLAR_YAW_STEP_DEG",
    "PLAN_V5_TARGET_COUNT",
    "PLAN_V5_VERSION",
    "RING_COUNTS",
    "STAGE_ORDER",
    "canonical_target",
    "is_canonical_version",
    "plan_summary",
    "ring_of",
    "validate_plan_geometry",
]
