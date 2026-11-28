"""The 48-target alternating tour (version 9) — **superseded by plan 10**.

Plan 10 (:mod:`sitewise.panorama.plan_v10`) is the canonical layout for new
sessions: the same five rings, walked as interleaved arches. This module is kept
because a session captured with plan 9 must keep its own geometry, and because
it owns the version-neutral projection and comparison machinery plan 10 reuses
(``transition_audit``, ``compare_geometry``, ``summarise_geometry``).

The device owns target generation; this module owns the **identity contract**
and the **geometry audit**. Target id 26 must mean the same direction for every
session that claims plan version 9, or the match rows, coverage audits and
stored poses of one capture would be silently reinterpreted against another
capture's layout.

## Why 48 targets are enough here, when 48 were not enough before

Plan 5 also had 48 targets, but captured them ring by ring. A 12-target ring is
30° apart in yaw, and at the documented 51.08° horizontal field of view a 30°
turn puts the previous photograph at ``tan(30°) / tan(25.5°) = 1.21`` of the
half-frame — outside the picture. The photographer turned, saw an empty
reticle, and shot a frame that shared only a corner sliver with its
predecessor.

The frame is **wider vertically (65°) than horizontally (51°)**, so a step is
cheap when it climbs and expensive when it turns:

* pure 30° yaw step   -> 1.21 of the half-frame (outside)
* pure 30° pitch step -> 0.906 (inside)
* 15° yaw + 30° pitch -> 0.65 horizontally, 0.94 vertically (inside)

Plan 9 therefore keeps the five rings (12/12/12/6/6) but staggers the upper and
lower rings by half a step and captures the sphere as **one tour that
alternates up and down**, so every one of the 47 transitions is a 15° turn with
a 30° tilt. The count never changes: a lens that cannot meet the requirement
keeps its 48 targets and the conflict is reported, never densified.

## What this module does and does not do

* It **does** answer "is this geometry the canonical version-9 table?", "which
  ring is target N in?" and "does the previous photograph stay in frame?".
* It does **not** reject a capture. A disagreement is reported as a warning so
  it reaches the report; failing a sweep over a label is worse than recording
  that the label was wrong.

Historical plans (versions 1–8) are never reinterpreted through this table.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Iterable

#: Plan version of the 48-target interleaved layout.
PLAN_V9_VERSION = "9"
#: Target count. Fixed: this plan never densifies.
PLAN_V9_TARGET_COUNT = 48
#: Pitch of the upper and lower rings.
PLAN_V9_RING_PITCH_DEG = 30.0
#: Pitch of the oblique ceiling and floor rings (the pole sits at 0.906 of the
#: ceiling frame's half-height, so 60° is the flattest ring that still covers
#: the zenith with margin).
PLAN_V9_POLAR_PITCH_DEG = 60.0
#: Yaw offset between the middle ring and its upper/lower neighbours.
PLAN_V9_STAGGER_DEG = 15.0
#: The alignment cone the capture gate already enforces.
PLAN_V9_TOLERANCE_DEG = 2.0

#: Ring keys, in the order the plan payload lists them.
STAGE_ORDER: tuple[str, ...] = ("middle", "upper", "lower", "ceiling", "floor")

#: Display names, matching ``SphereTargetSpec.ringName`` on the device.
RING_NAMES: dict[str, str] = {
    "middle": "Middle ring",
    "upper": "Upper ring",
    "lower": "Lower ring",
    "ceiling": "Ceiling ring",
    "floor": "Floor ring",
}


@dataclass(frozen=True, slots=True)
class PlanTarget:
    """One capture direction, in capture order."""

    target_id: int
    ring: str
    yaw_deg: float
    pitch_deg: float


def _target(target_id: int, ring: str, yaw: float, pitch: float) -> PlanTarget:
    return PlanTarget(target_id, ring, yaw % 360.0, pitch)


#: The canonical table, in capture order. Identical to
#: ``kSpherePlanV9Table`` in
#: ``fyp_mobile_app/lib/features/capture_360/domain/sphere/sphere_plan_v9.dart``.
CANONICAL_TARGETS: tuple[PlanTarget, ...] = (
    # 0°: middle, then the lower excursion (lower -> floor -> lower).
    _target(1, "middle", 0, 0),
    _target(2, "lower", 15, -30),
    _target(3, "floor", 30, -60),
    _target(4, "lower", 45, -30),
    # 30°: middle, then the upper excursion (upper -> ceiling -> upper).
    _target(5, "middle", 30, 0),
    _target(6, "upper", 45, 30),
    _target(7, "ceiling", 60, 60),
    _target(8, "upper", 75, 30),
    # 60°.
    _target(9, "middle", 60, 0),
    _target(10, "lower", 75, -30),
    _target(11, "floor", 90, -60),
    _target(12, "lower", 105, -30),
    # 90°.
    _target(13, "middle", 90, 0),
    _target(14, "upper", 105, 30),
    _target(15, "ceiling", 120, 60),
    _target(16, "upper", 135, 30),
    # 120°.
    _target(17, "middle", 120, 0),
    _target(18, "lower", 135, -30),
    _target(19, "floor", 150, -60),
    _target(20, "lower", 165, -30),
    # 150°.
    _target(21, "middle", 150, 0),
    _target(22, "upper", 165, 30),
    _target(23, "ceiling", 180, 60),
    _target(24, "upper", 195, 30),
    # 180°.
    _target(25, "middle", 180, 0),
    _target(26, "lower", 195, -30),
    _target(27, "floor", 210, -60),
    _target(28, "lower", 225, -30),
    # 210°.
    _target(29, "middle", 210, 0),
    _target(30, "upper", 225, 30),
    _target(31, "ceiling", 240, 60),
    _target(32, "upper", 255, 30),
    # 240°.
    _target(33, "middle", 240, 0),
    _target(34, "lower", 255, -30),
    _target(35, "floor", 270, -60),
    _target(36, "lower", 285, -30),
    # 270°.
    _target(37, "middle", 270, 0),
    _target(38, "upper", 285, 30),
    _target(39, "ceiling", 300, 60),
    _target(40, "upper", 315, 30),
    # 300°.
    _target(41, "middle", 300, 0),
    _target(42, "lower", 315, -30),
    _target(43, "floor", 330, -60),
    _target(44, "lower", 345, -30),
    # 330°: the tour closes through the ceiling and stops on the upper ring.
    _target(45, "middle", 330, 0),
    _target(46, "upper", 345, 30),
    _target(47, "ceiling", 0, 60),
    _target(48, "upper", 15, 30),
)


def build_tour() -> tuple[PlanTarget, ...]:
    """The same table generated from the rule, for cross-checking the literal.

    Each middle-ring target is followed by an excursion: down to the lower ring
    and the floor on even steps, up to the upper ring and the ceiling on odd
    ones. The final return edge to target 1 is dropped, so the tour is a path of
    48 photographs rather than a loop that would repeat a direction.
    """
    table: list[PlanTarget] = []
    target_id = 0

    def add(ring: str, yaw: float, pitch: float) -> None:
        nonlocal target_id
        target_id += 1
        table.append(_target(target_id, ring, yaw, pitch))

    for step in range(12):
        middle_yaw = 30.0 * step
        add("middle", middle_yaw, 0.0)
        if step % 2 == 0:
            add("lower", middle_yaw + 15.0, -PLAN_V9_RING_PITCH_DEG)
            add("floor", middle_yaw + 30.0, -PLAN_V9_POLAR_PITCH_DEG)
            add("lower", middle_yaw + 45.0, -PLAN_V9_RING_PITCH_DEG)
        else:
            add("upper", middle_yaw + 15.0, PLAN_V9_RING_PITCH_DEG)
            add("ceiling", middle_yaw + 30.0, PLAN_V9_POLAR_PITCH_DEG)
            add("upper", middle_yaw + 45.0, PLAN_V9_RING_PITCH_DEG)
    return tuple(table)


if build_tour() != CANONICAL_TARGETS:  # pragma: no cover - import-time guard
    raise RuntimeError("plan_v9: the literal table and the generator disagree")

#: Ring counts, for reporting.
RING_COUNTS: dict[str, int] = {
    key: sum(1 for target in CANONICAL_TARGETS if target.ring == key)
    for key in STAGE_ORDER
}


def is_canonical_version(version: str | int | None) -> bool:
    """Whether this module is responsible for auditing the version."""
    return str(version).strip() == PLAN_V9_VERSION


def expected_table(version: str | int | None) -> tuple[PlanTarget, ...]:
    return CANONICAL_TARGETS


def target_by_id(target_id: int) -> PlanTarget | None:
    for target in CANONICAL_TARGETS:
        if target.target_id == target_id:
            return target
    return None


# ----------------------------------------------------------------- geometry
def _direction(yaw_deg: float, pitch_deg: float) -> tuple[float, float, float]:
    yaw = math.radians(yaw_deg)
    pitch = math.radians(pitch_deg)
    return (
        math.sin(yaw) * math.cos(pitch),
        math.sin(pitch),
        -math.cos(yaw) * math.cos(pitch),
    )


def _cross(a: tuple[float, float, float], b: tuple[float, float, float]):
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _dot(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _normalise(a: tuple[float, float, float]) -> tuple[float, float, float]:
    length = math.sqrt(_dot(a, a)) or 1.0
    return (a[0] / length, a[1] / length, a[2] / length)


def _basis(yaw_deg: float, pitch_deg: float):
    forward = _direction(yaw_deg, pitch_deg)
    right = _cross(forward, (0.0, 1.0, 0.0))
    if math.sqrt(_dot(right, right)) < 1e-6:
        right = (1.0, 0.0, 0.0)
    right = _normalise(right)
    return forward, right, _cross(right, forward)


@dataclass(frozen=True, slots=True)
class CameraProfile:
    """The lens a plan is evaluated against."""

    image_width: int = 3072
    image_height: int = 4096
    vertical_fov_deg: float = 65.0

    @property
    def focal_px(self) -> float:
        return (self.image_height / 2.0) / math.tan(
            math.radians(self.vertical_fov_deg) / 2.0
        )

    @property
    def half_width_ratio(self) -> float:
        return (self.image_width / 2.0) / self.focal_px

    @property
    def half_height_ratio(self) -> float:
        return (self.image_height / 2.0) / self.focal_px


@dataclass(frozen=True, slots=True)
class Transition:
    """One consecutive capture step, validated."""

    previous_id: int
    current_id: int
    separation_deg: float
    x: float
    y: float

    @property
    def visible(self) -> bool:
        return abs(self.x) <= 1.0 and abs(self.y) <= 1.0

    @property
    def worst_fraction(self) -> float:
        return max(abs(self.x), abs(self.y))


def transition_audit(
    camera: CameraProfile | None = None,
    table: Iterable[PlanTarget] = CANONICAL_TARGETS,
) -> list[Transition]:
    """The previous target's position in the active target's camera frame.

    ``x`` and ``y`` are fractions of the half-frame (``+x`` screen-right,
    ``+y`` screen-up), so ``1.0`` is the frame edge and ``visible`` is the
    requirement itself rather than a proxy for it.
    """
    lens = camera or CameraProfile()
    rows = list(table)
    out: list[Transition] = []
    for index in range(1, len(rows)):
        previous = rows[index - 1]
        current = rows[index]
        forward, right, up = _basis(current.yaw_deg, current.pitch_deg)
        previous_direction = _direction(previous.yaw_deg, previous.pitch_deg)
        depth = _dot(previous_direction, forward)
        separation = math.degrees(
            math.acos(max(-1.0, min(1.0, depth)))
        )
        if depth <= 1e-9:
            out.append(Transition(previous.target_id, current.target_id, separation, 9.99, 9.99))
            continue
        out.append(
            Transition(
                previous_id=previous.target_id,
                current_id=current.target_id,
                separation_deg=separation,
                x=_dot(previous_direction, right) / depth / lens.half_width_ratio,
                y=_dot(previous_direction, up) / depth / lens.half_height_ratio,
            )
        )
    return out


def audit_summary(
    camera: CameraProfile | None = None,
    table: Iterable[PlanTarget] = CANONICAL_TARGETS,
    version: str = PLAN_V9_VERSION,
) -> dict[str, Any]:
    """Worst transition, failures and the ring breakdown.

    Table-parameterised so a sibling plan version can report its own audit
    through the same projection instead of a second implementation.
    """
    rows = tuple(table)
    transitions = transition_audit(camera, rows)
    worst = max(transitions, key=lambda t: t.worst_fraction, default=None)
    counts: dict[str, int] = {}
    for row in rows:
        counts[row.ring] = counts.get(row.ring, 0) + 1
    return {
        "planVersion": str(version),
        "targetCount": len(rows),
        "ringCounts": {ring: counts.get(ring, 0) for ring in STAGE_ORDER},
        "transitions": len(transitions),
        "failures": [t.current_id for t in transitions if not t.visible],
        "worstFraction": worst.worst_fraction if worst else 0.0,
        "worstTransition": (
            [worst.previous_id, worst.current_id] if worst else None
        ),
    }


def compare_geometry(
    geometry: Iterable[Any],
    table: Iterable[PlanTarget],
    version: str | int | None,
) -> list[str]:
    """Compare received geometry against any table, entry for entry.

    The single implementation behind every plan version's
    ``validate_plan_geometry``: the tables differ, the comparison does not.
    """
    rows = tuple(table)
    targets = [t for t in geometry if isinstance(t, dict)]
    if not targets:
        return [f"The plan claims the {len(rows)}-target layout but carries no targets."]

    problems: list[str] = []
    if len(targets) != len(rows):
        problems.append(
            f"Plan version {version} must have {len(rows)} targets, "
            f"but {len(targets)} were received."
        )

    by_id: dict[int, dict[str, Any]] = {}
    for target in targets:
        try:
            target_id = int(target.get("targetId"))
        except (TypeError, ValueError):
            problems.append("A target carries no integer targetId.")
            continue
        by_id[target_id] = target

    for row in rows:
        received = by_id.get(row.target_id)
        if received is None:
            problems.append(f"Target {row.target_id} is missing.")
            continue
        try:
            yaw = float(received.get("yawDeg"))
            pitch = float(received.get("pitchDeg"))
        except (TypeError, ValueError):
            problems.append(f"Target {row.target_id} has no numeric yaw/pitch.")
            continue
        if abs(yaw - row.yaw_deg) > 0.01 or abs(pitch - row.pitch_deg) > 0.01:
            problems.append(
                f"Target {row.target_id} is at ({yaw:.2f}, {pitch:.2f}) but "
                f"plan {version} puts it at ({row.yaw_deg:.2f}, "
                f"{row.pitch_deg:.2f})."
            )
        received_ring = str(received.get("ring") or "").strip().lower()
        if received_ring and received_ring.replace(" ring", "") != row.ring:
            problems.append(
                f"Target {row.target_id} is labelled '{received_ring}' but "
                f"belongs to the {row.ring} ring."
            )
    return problems


def validate_plan_geometry(
    geometry: Iterable[Any],
    version: str | int | None,
) -> list[str]:
    """Compare a received plan against the canonical table.

    Returns human-readable problems; an empty list means the geometry matches
    the table for the version it claims. Versions this module does not own are
    never inspected — historical geometry is left exactly as it is.
    """
    if not is_canonical_version(version):
        return []
    return compare_geometry(geometry, CANONICAL_TARGETS, version)


def summarise_geometry(
    geometry: Iterable[Any],
    table: Iterable[PlanTarget],
    version: str | int | None,
    ring_names: dict[str, str] | None = None,
) -> dict[str, Any]:
    """The stored-report description shared by every interleaved plan.

    These plans are tours, not grids, so they report ring membership and
    distinct headings rather than the plan-7 "columns" vocabulary: the 15°
    stagger means 24 headings carry the 48 photographs.
    """
    rows = tuple(table)
    names = ring_names or RING_NAMES
    targets = [t for t in geometry if isinstance(t, dict)]
    headings = len({round(float(t.get("yawDeg") or 0.0), 3) for t in targets})
    pitches = sorted({round(float(t.get("pitchDeg") or 0.0), 3) for t in targets})
    counts: dict[str, int] = {}
    for target in targets:
        ring = str(target.get("ring") or "").strip().lower().replace(" ring", "")
        if ring:
            counts[ring] = counts.get(ring, 0) + 1
    return {
        "planVersion": str(version),
        "targetCount": len(targets),
        "ringCounts": {ring: counts.get(ring, 0) for ring in names},
        "distinctHeadings": headings,
        "rowPitches": pitches,
        "expectedTargetCount": len(rows),
        "matchesCanonical": not compare_geometry(geometry, rows, version),
    }


def plan_summary(geometry: Iterable[Any], version: str | int | None) -> dict[str, Any]:
    """A compact description for the stored report."""
    return summarise_geometry(geometry, CANONICAL_TARGETS, version)
