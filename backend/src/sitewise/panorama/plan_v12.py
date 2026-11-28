"""The canonical adaptive five-ring capture plan (version 12), as FastAPI knows it.

Plan 12 is the one production plan for every new capture session. It carries
the reference configuration — 36 primary targets on the 0°/±30° rings plus 8
polar targets at ±65° — with target ids equal to the connected-sector capture
order. Plans 4 and 11 remain readable for sessions captured with them; they
are never selected for a new capture.

## Geometry

Five rings; the three main rings share their yaw positions and the polar
rings sit directly above and below ring targets:

* middle       12 targets, pitch   0°, yaw step 30°, yaws 0° … 330°
* upper        12 targets, pitch +30°, yaw step 30°, yaws 0° … 330°
* lower        12 targets, pitch −30°, yaw step 30°, yaws 0° … 330°
* upper_polar   4 targets, pitch +65°, yaw step 90°, yaws 0/90/180/270°
* lower_polar   4 targets, pitch −65°, yaw step 90°, yaws 0/90/180/270°

## Identity and sequence

Target ids ARE the capture order (id 1 is the first photograph). The
connected-sector sequence establishes two horizontal and two vertical
connections before the photographer turns away from the start, then completes
middle → upper → polar → lower → polar per sector. The table mirrors
``kSpherePlanV12Table`` in
``fyp_mobile_app/lib/features/capture_360/domain/sphere/sphere_plan_v12.dart``.

## Honest coverage

Completing 44 photographs satisfies the plan's geometry; it does not by
itself prove full spherical coverage. The worker's coverage verification
reports actual overlap from real image content, and a coverage hole is
reported rather than hidden.
"""

from __future__ import annotations

from typing import Any, Iterable

from sitewise.panorama import plan_geometry

#: Plan version of the canonical adaptive five-ring plan.
PLAN_V12_VERSION = "12"
#: Target count. Fixed: 36 primary + 8 polar.
PLAN_V12_TARGET_COUNT = 44
#: Pitch of the upper and lower rings.
PLAN_V12_RING_PITCH_DEG = 30.0
#: Pitch of the upper and lower polar rings.
PLAN_V12_POLAR_PITCH_DEG = 65.0

#: Ring keys, in the order the plan payload lists them.
STAGE_ORDER: tuple[str, ...] = (
    "middle",
    "upper",
    "lower",
    "upper_polar",
    "lower_polar",
)

#: Display names, matching ``SphereTargetSpec.ringName`` on the device.
RING_NAMES: dict[str, str] = {
    "middle": "Middle ring",
    "upper": "Upper ring",
    "lower": "Lower ring",
    "upper_polar": "Upper polar ring",
    "lower_polar": "Lower polar ring",
}

#: The row type is shared with the other plan modules: the tables differ, the
#: record does not.
PlanTarget = plan_geometry.PlanTarget


def _target(target_id: int, ring: str, yaw: float, pitch: float) -> PlanTarget:
    return plan_geometry._target(target_id, ring, yaw, pitch)


#: The canonical table, in capture order: target id equals capture position.
CANONICAL_TARGETS: tuple[PlanTarget, ...] = (
    # Seed sector: two neighbouring middle frames, their upper and lower
    # counterparts, and the first polar pair.
    _target(1, "middle", 0, 0),
    _target(2, "middle", 30, 0),
    _target(3, "upper", 0, 30),
    _target(4, "upper", 30, 30),
    _target(5, "upper_polar", 0, 65),
    _target(6, "lower", 0, -30),
    _target(7, "lower", 30, -30),
    _target(8, "lower_polar", 0, -65),
    # Sector 60°.
    _target(9, "middle", 60, 0),
    _target(10, "upper", 60, 30),
    _target(11, "lower", 60, -30),
    # Sector 90°: carries the second polar pair.
    _target(12, "middle", 90, 0),
    _target(13, "upper", 90, 30),
    _target(14, "upper_polar", 90, 65),
    _target(15, "lower", 90, -30),
    _target(16, "lower_polar", 90, -65),
    # Sector 120°.
    _target(17, "middle", 120, 0),
    _target(18, "upper", 120, 30),
    _target(19, "lower", 120, -30),
    # Sector 150°.
    _target(20, "middle", 150, 0),
    _target(21, "upper", 150, 30),
    _target(22, "lower", 150, -30),
    # Sector 180°: third polar pair.
    _target(23, "middle", 180, 0),
    _target(24, "upper", 180, 30),
    _target(25, "upper_polar", 180, 65),
    _target(26, "lower", 180, -30),
    _target(27, "lower_polar", 180, -65),
    # Sector 210°.
    _target(28, "middle", 210, 0),
    _target(29, "upper", 210, 30),
    _target(30, "lower", 210, -30),
    # Sector 240°.
    _target(31, "middle", 240, 0),
    _target(32, "upper", 240, 30),
    _target(33, "lower", 240, -30),
    # Sector 270°: last polar pair.
    _target(34, "middle", 270, 0),
    _target(35, "upper", 270, 30),
    _target(36, "upper_polar", 270, 65),
    _target(37, "lower", 270, -30),
    _target(38, "lower_polar", 270, -65),
    # Sector 300°.
    _target(39, "middle", 300, 0),
    _target(40, "upper", 300, 30),
    _target(41, "lower", 300, -30),
    # Sector 330°: the loop closes back onto target 1.
    _target(42, "middle", 330, 0),
    _target(43, "upper", 330, 30),
    _target(44, "lower", 330, -30),
)


def build_tour() -> tuple[PlanTarget, ...]:
    """The same table generated from the rule, for cross-checking the literal."""
    table: list[PlanTarget] = []
    target_id = 0

    def add(ring: str, yaw: float, pitch: float) -> None:
        nonlocal target_id
        target_id += 1
        table.append(_target(target_id, ring, yaw % 360, pitch))

    polar_yaws = (90.0, 180.0, 270.0)
    # Seed sector: two neighbouring middle frames, their upper and lower
    # counterparts, and the first polar pair — horizontal and vertical
    # alignment exist before the photographer turns away from the start.
    add("middle", 0.0, 0.0)
    add("middle", 30.0, 0.0)
    add("upper", 0.0, PLAN_V12_RING_PITCH_DEG)
    add("upper", 30.0, PLAN_V12_RING_PITCH_DEG)
    add("upper_polar", 0.0, PLAN_V12_POLAR_PITCH_DEG)
    add("lower", 0.0, -PLAN_V12_RING_PITCH_DEG)
    add("lower", 30.0, -PLAN_V12_RING_PITCH_DEG)
    add("lower_polar", 0.0, -PLAN_V12_POLAR_PITCH_DEG)
    # Every later sector completes middle → upper → (polar) → lower → (polar)
    # exactly as the canonical table lists them.
    for step in range(2, 12):
        yaw = 30.0 * step
        add("middle", yaw, 0.0)
        add("upper", yaw, PLAN_V12_RING_PITCH_DEG)
        if yaw in polar_yaws:
            add("upper_polar", yaw, PLAN_V12_POLAR_PITCH_DEG)
        add("lower", yaw, -PLAN_V12_RING_PITCH_DEG)
        if yaw in polar_yaws:
            add("lower_polar", yaw, -PLAN_V12_POLAR_PITCH_DEG)
    return tuple(table)


if build_tour() != CANONICAL_TARGETS:  # pragma: no cover - import-time guard
    raise RuntimeError("plan_v12: the literal table and the generator disagree")

#: Ring counts, for reporting.
RING_COUNTS: dict[str, int] = {
    key: sum(1 for target in CANONICAL_TARGETS if target.ring == key)
    for key in STAGE_ORDER
}


def is_canonical_version(version: str | int | None) -> bool:
    """Whether this module is responsible for auditing the version."""
    return str(version).strip() == PLAN_V12_VERSION


def expected_table(version: str | int | None) -> tuple[PlanTarget, ...]:
    return CANONICAL_TARGETS


def target_by_id(target_id: int) -> PlanTarget | None:
    for target in CANONICAL_TARGETS:
        if target.target_id == target_id:
            return target
    return None


def target_ids_for_ring(ring: str) -> tuple[int, ...]:
    """Every target id in one ring, in capture order."""
    return tuple(
        target.target_id for target in CANONICAL_TARGETS if target.ring == ring
    )


# ----------------------------------------------------------------- geometry
# The projection machinery is version-neutral and lives in plan_geometry; this
# module supplies only the table.
CameraProfile = plan_geometry.CameraProfile
Transition = plan_geometry.Transition


def transition_audit(
    camera: CameraProfile | None = None,
    table: Iterable[PlanTarget] = CANONICAL_TARGETS,
) -> list[Transition]:
    """Every consecutive transition, projected into the active target's frame."""
    return plan_geometry.transition_audit(camera, table)


def audit_summary(camera: CameraProfile | None = None) -> dict[str, Any]:
    """Worst transition, failures and the ring breakdown.

    Self-contained rather than delegated: the shared summary iterates the
    shared ``STAGE_ORDER``, which does not carry the polar ring keys this plan
    uses. The projection itself stays shared.
    """
    rows = CANONICAL_TARGETS
    transitions = plan_geometry.transition_audit(camera, rows)
    worst = max(transitions, key=lambda t: t.worst_fraction, default=None)
    counts: dict[str, int] = {}
    for row in rows:
        counts[row.ring] = counts.get(row.ring, 0) + 1
    return {
        "planVersion": PLAN_V12_VERSION,
        "targetCount": len(rows),
        "ringCounts": {ring: counts.get(ring, 0) for ring in STAGE_ORDER},
        "transitions": len(transitions),
        "failures": [t.current_id for t in transitions if not t.visible],
        "worstFraction": worst.worst_fraction if worst else 0.0,
        "worstTransition": (
            [worst.previous_id, worst.current_id] if worst else None
        ),
    }


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
    return plan_geometry.compare_geometry(geometry, CANONICAL_TARGETS, version)


def plan_summary(geometry: Iterable[Any], version: str | int | None) -> dict[str, Any]:
    """A compact description for the stored report."""
    return plan_geometry.summarise_geometry(
        geometry, CANONICAL_TARGETS, version, RING_NAMES
    )


__all__ = [
    "CANONICAL_TARGETS",
    "PLAN_V12_POLAR_PITCH_DEG",
    "PLAN_V12_RING_PITCH_DEG",
    "PLAN_V12_TARGET_COUNT",
    "PLAN_V12_VERSION",
    "RING_COUNTS",
    "RING_NAMES",
    "STAGE_ORDER",
    "audit_summary",
    "build_tour",
    "expected_table",
    "is_canonical_version",
    "plan_summary",
    "target_by_id",
    "target_ids_for_ring",
    "transition_audit",
    "validate_plan_geometry",
]
