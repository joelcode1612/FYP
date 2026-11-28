"""Version-neutral geometry projection and persisted-plan comparison helpers."""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Iterable

STAGE_ORDER: tuple[str, ...] = ("middle", "upper", "lower", "ceiling", "floor")
RING_NAMES: dict[str, str] = {"middle": "Middle ring", "upper": "Upper ring", "lower": "Lower ring", "ceiling": "Ceiling ring", "floor": "Floor ring"}

@dataclass(frozen=True, slots=True)
class PlanTarget:
    """One capture direction, in capture order."""

    target_id: int
    ring: str
    yaw_deg: float
    pitch_deg: float


def _target(target_id: int, ring: str, yaw: float, pitch: float) -> PlanTarget:
    return PlanTarget(target_id, ring, yaw % 360.0, pitch)


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
    table: Iterable[PlanTarget] = (),
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
    table: Iterable[PlanTarget] = (),
    version: str = "",
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
        # Underscores and spaces are interchangeable across the plan tables
        # ("upper_polar" in a table, "Upper polar ring" from a payload), so
        # both sides are normalised to space-separated words before comparing.
        def _ring_words(value: str) -> str:
            return value.replace("_", " ").replace(" ring", "").strip()
        if received_ring and _ring_words(received_ring) != _ring_words(row.ring):
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


