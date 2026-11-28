"""The enhanced adaptive 44-target plan (version 11), as FastAPI knows it.

Version 11 restores the adaptive 44-target five-ring layout that version 4
introduced, with the ceiling and floor photographs repositioned so they share
visible structure with the ring beneath them.

## Geometry

Five rings, staggered so a cap sits *between* two ring targets rather than
above one:

* middle   12 targets, pitch   0°, yaw step 30°, offset  0°
* upper    12 targets, pitch +30°, yaw step 30°, offset 15°
* lower    12 targets, pitch −30°, yaw step 30°, offset 15°
* ceiling   4 targets, pitch +60°, yaw step 90°, offset  0° (steps 0/3/6/9)
* floor     4 targets, pitch −60°, yaw step 90°, offset  0° (steps 1/4/7/10)

Version 4 put its four ceiling targets at +65° directly above middle targets.
At the documented 51.08° × 65° frame the nearest upper photograph was then 30°
of yaw and 35° of pitch away, projecting to 1.18 of the half-frame — outside
the picture. That is why the independent audit found 0 of 4 ceiling frames
registered. At +60° and offset onto the upper ring's gaps the cap → upper step
projects to 0.938, inside the frame with 2.0° of margin.

## The four transitions that cannot be visible

Counting the edges a Hamiltonian path must spend:

    e(M-U) + e(M-L) = 2 × 12      middle-ring slots
    e(M-U) = 2 × 12 − 2 × 4       upper slots consumed by ceiling caps
    e(M-L) = 2 × 12 − 2 × 4       lower slots consumed by floor caps

32 edges are demanded from 24 slots, so four upper→lower steps necessarily
fall outside the frame. ``PREVIOUS_VISIBILITY_EXEMPT`` names them. The plan
keeps 44 photographs; it does not densify to make the requirement true.

Historical sessions are never reinterpreted through this table; V11 is the
only plan used for new capture sessions.
"""

from __future__ import annotations

from typing import Any, Iterable

from sitewise.panorama import plan_geometry

#: Plan version of the enhanced adaptive 44-target layout.
PLAN_V11_VERSION = "11"
#: Target count. Fixed: this plan never densifies.
PLAN_V11_TARGET_COUNT = 44
#: Pitch of the upper and lower rings.
PLAN_V11_RING_PITCH_DEG = 30.0
#: Pitch of the ceiling and floor rings. 60°, not 62°: at 62° the cap → upper
#: exit projects to 1.012 of the half-frame, i.e. outside the photograph.
PLAN_V11_POLAR_PITCH_DEG = 60.0
#: Yaw offset between the middle ring and its upper/lower neighbours.
PLAN_V11_STAGGER_DEG = 15.0
#: Yaw offset of the ceiling caps from the middle ring.
PLAN_V11_CEILING_OFFSET_DEG = 0.0
#: Yaw offset of the floor caps from the middle ring.
#:
#: Zero: a floor cap sits at the middle yaw of its own arch (30°, 120°, 210°,
#: 300°), which is 15° from each of the two lower targets that flank it. The
#: 30° separation from a ceiling cap comes from the arches occupying different
#: middle-ring steps, not from a second offset.
PLAN_V11_FLOOR_OFFSET_DEG = 0.0

#: Ring keys, in the order the plan payload lists them.
STAGE_ORDER: tuple[str, ...] = plan_geometry.STAGE_ORDER

#: Display names, matching ``SphereTargetSpec.ringName`` on the device.
RING_NAMES: dict[str, str] = dict(plan_geometry.RING_NAMES)

#: The row type is shared with plans 9 and 10: the tables differ, the record
#: does not.
PlanTarget = plan_geometry.PlanTarget


def _target(target_id: int, ring: str, yaw: float, pitch: float) -> PlanTarget:
    return plan_geometry._target(target_id, ring, yaw, pitch)


#: The canonical table, in capture order. Identical to ``kSpherePlanV11Table``
#: in ``fyp_mobile_app/lib/features/capture_360/domain/sphere/
#: sphere_plan_v11.dart``.
CANONICAL_TARGETS: tuple[PlanTarget, ...] = (
    # 0°: horizon-level first photograph, then the ceiling arch.
    _target(1, "middle", 0, 0),
    _target(2, "upper", 345, 30),
    _target(3, "ceiling", 0, 60),
    _target(4, "upper", 15, 30),
    # 30°: floor arch, then the next upper.
    _target(5, "middle", 30, 0),
    _target(6, "lower", 15, -30),
    _target(7, "floor", 30, -60),
    _target(8, "lower", 45, -30),
    # 60°.
    _target(9, "middle", 60, 0),
    _target(10, "upper", 45, 30),
    _target(11, "lower", 75, -30),
    # 90°.
    _target(12, "middle", 90, 0),
    _target(13, "upper", 75, 30),
    _target(14, "ceiling", 90, 60),
    _target(15, "upper", 105, 30),
    # 120°.
    _target(16, "middle", 120, 0),
    _target(17, "lower", 105, -30),
    _target(18, "floor", 120, -60),
    _target(19, "lower", 135, -30),
    # 150°.
    _target(20, "middle", 150, 0),
    _target(21, "upper", 135, 30),
    _target(22, "lower", 165, -30),
    # 180°.
    _target(23, "middle", 180, 0),
    _target(24, "upper", 165, 30),
    _target(25, "ceiling", 180, 60),
    _target(26, "upper", 195, 30),
    # 210°.
    _target(27, "middle", 210, 0),
    _target(28, "lower", 195, -30),
    _target(29, "floor", 210, -60),
    _target(30, "lower", 225, -30),
    # 240°.
    _target(31, "middle", 240, 0),
    _target(32, "upper", 225, 30),
    _target(33, "lower", 255, -30),
    # 270°.
    _target(34, "middle", 270, 0),
    _target(35, "upper", 255, 30),
    _target(36, "ceiling", 270, 60),
    _target(37, "upper", 285, 30),
    # 300°.
    _target(38, "middle", 300, 0),
    _target(39, "lower", 285, -30),
    _target(40, "floor", 300, -60),
    _target(41, "lower", 315, -30),
    _target(42, "middle", 330, 0),
    _target(43, "upper", 315, 30),
    _target(44, "lower", 345, -30),
)

#: Target ids whose previous-target-visibility check is unsatisfiable by
#: construction: the four upper→lower steps the 4+4 cap layout forces.
PREVIOUS_VISIBILITY_EXEMPT: frozenset[int] = frozenset({11, 22, 33, 44})


def build_tour() -> tuple[PlanTarget, ...]:
    """The same table generated from the rule, for cross-checking the literal."""
    table: list[PlanTarget] = []
    target_id = 0

    def add(ring: str, yaw: float, pitch: float) -> None:
        nonlocal target_id
        target_id += 1
        table.append(_target(target_id, ring, yaw % 360, pitch))

    for step in range(12):
        middle_yaw = 30.0 * step
        add("middle", middle_yaw, 0.0)
        if step % 3 == 0:
            add("upper", middle_yaw - PLAN_V11_STAGGER_DEG, PLAN_V11_RING_PITCH_DEG)
            add("ceiling", middle_yaw + PLAN_V11_CEILING_OFFSET_DEG,
                 PLAN_V11_POLAR_PITCH_DEG)
            add("upper", middle_yaw + PLAN_V11_STAGGER_DEG, PLAN_V11_RING_PITCH_DEG)
        elif step % 3 == 1:
            add("lower", middle_yaw - PLAN_V11_STAGGER_DEG, -PLAN_V11_RING_PITCH_DEG)
            add("floor", middle_yaw + PLAN_V11_FLOOR_OFFSET_DEG,
                 -PLAN_V11_POLAR_PITCH_DEG)
            add("lower", middle_yaw + PLAN_V11_STAGGER_DEG, -PLAN_V11_RING_PITCH_DEG)
        else:
            add("upper", middle_yaw - PLAN_V11_STAGGER_DEG, PLAN_V11_RING_PITCH_DEG)
            add("lower", middle_yaw + PLAN_V11_STAGGER_DEG, -PLAN_V11_RING_PITCH_DEG)
    return tuple(table)


if build_tour() != CANONICAL_TARGETS:  # pragma: no cover - import-time guard
    raise RuntimeError("plan_v11: the literal table and the generator disagree")

#: Ring counts, for reporting.
RING_COUNTS: dict[str, int] = {
    key: sum(1 for target in CANONICAL_TARGETS if target.ring == key)
    for key in STAGE_ORDER
}


def is_canonical_version(version: str | int | None) -> bool:
    """Whether this module is responsible for auditing the version."""
    return str(version).strip() == PLAN_V11_VERSION


def expected_table(version: str | int | None) -> tuple[PlanTarget, ...]:
    return CANONICAL_TARGETS


def target_by_id(target_id: int) -> PlanTarget | None:
    for target in CANONICAL_TARGETS:
        if target.target_id == target_id:
            return target
    return None


def target_ids_for_ring(ring: str) -> tuple[int, ...]:
    """Every target id in one ring, in capture order.

    The stitcher asks for the cap photographs by ring rather than by a
    historical "target 37 is the zenith" convention: plan 11 has four oblique
    ceiling frames and four oblique floor frames, no isolated pole frame.
    """
    return tuple(
        target.target_id for target in CANONICAL_TARGETS if target.ring == ring
    )


# ----------------------------------------------------------------- geometry
# The projection machinery is version-neutral and lives in plan_geometry; this module
# supplies only the table.
CameraProfile = plan_geometry.CameraProfile
Transition = plan_geometry.Transition


def transition_audit(
    camera: CameraProfile | None = None,
    table: Iterable[PlanTarget] = CANONICAL_TARGETS,
) -> list[Transition]:
    """Every consecutive transition, projected into the active target's frame."""
    return plan_geometry.transition_audit(camera, table)


def audit_summary(camera: CameraProfile | None = None) -> dict[str, Any]:
    """Worst transition, failures and the ring breakdown."""
    return plan_geometry.audit_summary(camera, CANONICAL_TARGETS, PLAN_V11_VERSION)


def validate_plan_geometry(
    geometry: Iterable[Any],
    version: str | int | None,
) -> list[str]:
    """Compare a received plan against the canonical 44-target table."""
    if not is_canonical_version(version):
        return []
    return plan_geometry.compare_geometry(geometry, CANONICAL_TARGETS, version)


def plan_summary(geometry: Iterable[Any], version: str | int | None) -> dict[str, Any]:
    """A compact description for the stored report."""
    return plan_geometry.summarise_geometry(
        geometry, CANONICAL_TARGETS, version, RING_NAMES
    )


# Keep the shared row/geometry helpers in one place: plan 10 exposes the same
# names, and importing it here would be a cycle.
__all__ = [
    "CANONICAL_TARGETS",
    "PLAN_V11_CEILING_OFFSET_DEG",
    "PLAN_V11_FLOOR_OFFSET_DEG",
    "PLAN_V11_POLAR_PITCH_DEG",
    "PLAN_V11_RING_PITCH_DEG",
    "PLAN_V11_STAGGER_DEG",
    "PLAN_V11_TARGET_COUNT",
    "PLAN_V11_VERSION",
    "PREVIOUS_VISIBILITY_EXEMPT",
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
