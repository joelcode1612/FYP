"""The 48-target interleaved **arch** plan (version 10), as FastAPI knows it.

Version 10 is the canonical layout for new capture sessions. It supersedes the
ring-by-ring plans (5, 7, 8) and the earlier alternating tour (9), which stays
readable so historical sessions are never reinterpreted.

## Geometry

Five rings, staggered so no step is ever a pure 30° turn:

* middle  12 targets, pitch   0°, yaw step 30°, offset  0°
* upper   12 targets, pitch +30°, yaw step 30°, offset 15°
* lower   12 targets, pitch −30°, yaw step 30°, offset 15°
* ceiling  6 targets, pitch +60°, yaw step 60°, offset  0°
* floor    6 targets, pitch −60°, yaw step 60°, offset 30°

## Traversal

Ring-by-ring capture is what forced 80 targets: a 12-target ring is 30° apart
in yaw, and at the documented 51.08° horizontal field of view a 30° turn puts
the previous photograph at ``tan(30°)/tan(25.5°) = 1.21`` of the half-frame —
outside the picture. The frame is wider vertically (65°) than horizontally
(51°), so a step is cheap when it climbs and expensive when it turns.

Plan 10 therefore walks **arches** instead of rings. Each middle-ring target is
followed by an excursion that climbs to the ceiling or drops to the floor and
returns, then the next middle target:

    M0 → U−15 → C0 → U+15 → M30 → L+15 → F30 → L+45 → M60 → …

Every step is a 15° turn with a 30° tilt (max 0.648 of the half-frame
horizontally, 0.938 vertically), so the photograph just taken stays in frame
while cross-ring connections are established progressively rather than after an
entire ring is finished.

The count never changes: a lens that cannot meet the requirement keeps its 48
targets and the conflict is reported, never densified.

Historical plans (versions 1–9) are never reinterpreted through this table.
"""

from __future__ import annotations

from typing import Any, Iterable

from sitewise.panorama import plan_v9

#: Plan version of the interleaved arch layout.
PLAN_V10_VERSION = "10"
#: Target count. Fixed: this plan never densifies.
PLAN_V10_TARGET_COUNT = 48
#: Pitch of the upper and lower rings.
PLAN_V10_RING_PITCH_DEG = 30.0
#: Pitch of the oblique ceiling and floor rings.
PLAN_V10_POLAR_PITCH_DEG = 60.0
#: Yaw offset between the middle ring and its upper/lower neighbours.
PLAN_V10_STAGGER_DEG = 15.0

#: Ring keys, in the order the plan payload lists them.
STAGE_ORDER: tuple[str, ...] = plan_v9.STAGE_ORDER

#: Display names, matching ``SphereTargetSpec.ringName`` on the device.
RING_NAMES: dict[str, str] = dict(plan_v9.RING_NAMES)

#: The row type is shared with plan 9: the tables differ, the record does not.
PlanTarget = plan_v9.PlanTarget


def _target(target_id: int, ring: str, yaw: float, pitch: float) -> PlanTarget:
    return plan_v9._target(target_id, ring, yaw, pitch)


#: The canonical table, in capture order. Identical to ``kSpherePlanV10Table``
#: in
#: ``fyp_mobile_app/lib/features/capture_360/domain/sphere/sphere_plan_v10.dart``
#: and to ``sitewise_48_interleaved_capture_plan.json``.
CANONICAL_TARGETS: tuple[PlanTarget, ...] = (
    # 0°: middle, then the upward arch (upper -> ceiling -> upper).
    _target(1, "middle", 0, 0),
    _target(2, "upper", 345, 30),
    _target(3, "ceiling", 0, 60),
    _target(4, "upper", 15, 30),
    # 30°: middle, then the downward arch (lower -> floor -> lower).
    _target(5, "middle", 30, 0),
    _target(6, "lower", 15, -30),
    _target(7, "floor", 30, -60),
    _target(8, "lower", 45, -30),
    # 60°: up again.
    _target(9, "middle", 60, 0),
    _target(10, "upper", 45, 30),
    _target(11, "ceiling", 60, 60),
    _target(12, "upper", 75, 30),
    # 90°: down.
    _target(13, "middle", 90, 0),
    _target(14, "lower", 75, -30),
    _target(15, "floor", 90, -60),
    _target(16, "lower", 105, -30),
    # 120°: up.
    _target(17, "middle", 120, 0),
    _target(18, "upper", 105, 30),
    _target(19, "ceiling", 120, 60),
    _target(20, "upper", 135, 30),
    # 150°: down.
    _target(21, "middle", 150, 0),
    _target(22, "lower", 135, -30),
    _target(23, "floor", 150, -60),
    _target(24, "lower", 165, -30),
    # 180°: up.
    _target(25, "middle", 180, 0),
    _target(26, "upper", 165, 30),
    _target(27, "ceiling", 180, 60),
    _target(28, "upper", 195, 30),
    # 210°: down.
    _target(29, "middle", 210, 0),
    _target(30, "lower", 195, -30),
    _target(31, "floor", 210, -60),
    _target(32, "lower", 225, -30),
    # 240°: up.
    _target(33, "middle", 240, 0),
    _target(34, "upper", 225, 30),
    _target(35, "ceiling", 240, 60),
    _target(36, "upper", 255, 30),
    # 270°: down.
    _target(37, "middle", 270, 0),
    _target(38, "lower", 255, -30),
    _target(39, "floor", 270, -60),
    _target(40, "lower", 285, -30),
    # 300°: up.
    _target(41, "middle", 300, 0),
    _target(42, "upper", 285, 30),
    _target(43, "ceiling", 300, 60),
    _target(44, "upper", 315, 30),
    # 330°: down, and the walk stops on the lower ring rather than returning
    # to target 1 — a path of 48 photographs, not a loop that repeats one.
    _target(45, "middle", 330, 0),
    _target(46, "lower", 315, -30),
    _target(47, "floor", 330, -60),
    _target(48, "lower", 345, -30),
)


def build_tour() -> tuple[PlanTarget, ...]:
    """The same table generated from the rule, for cross-checking the literal."""
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
            add("upper", middle_yaw - PLAN_V10_STAGGER_DEG, PLAN_V10_RING_PITCH_DEG)
            add("ceiling", middle_yaw, PLAN_V10_POLAR_PITCH_DEG)
            add("upper", middle_yaw + PLAN_V10_STAGGER_DEG, PLAN_V10_RING_PITCH_DEG)
        else:
            add("lower", middle_yaw - PLAN_V10_STAGGER_DEG, -PLAN_V10_RING_PITCH_DEG)
            add("floor", middle_yaw, -PLAN_V10_POLAR_PITCH_DEG)
            add("lower", middle_yaw + PLAN_V10_STAGGER_DEG, -PLAN_V10_RING_PITCH_DEG)
    return tuple(table)


if build_tour() != CANONICAL_TARGETS:  # pragma: no cover - import-time guard
    raise RuntimeError("plan_v10: the literal table and the generator disagree")

#: Ring counts, for reporting.
RING_COUNTS: dict[str, int] = {
    key: sum(1 for target in CANONICAL_TARGETS if target.ring == key)
    for key in STAGE_ORDER
}


def is_canonical_version(version: str | int | None) -> bool:
    """Whether this module is responsible for auditing the version."""
    return str(version).strip() == PLAN_V10_VERSION


def expected_table(version: str | int | None) -> tuple[PlanTarget, ...]:
    return CANONICAL_TARGETS


def target_by_id(target_id: int) -> PlanTarget | None:
    for target in CANONICAL_TARGETS:
        if target.target_id == target_id:
            return target
    return None


def target_ids_for_ring(ring: str) -> tuple[int, ...]:
    """Every target id in one ring, in capture order.

    The stitcher asks for the pole-adjacent photographs by ring rather than by
    the historical "target 37 is the zenith" convention: plan 10 has no
    isolated zenith or nadir frame, only oblique ceiling and floor ones.
    """
    return tuple(
        target.target_id for target in CANONICAL_TARGETS if target.ring == ring
    )


# ----------------------------------------------------------------- geometry
# The projection machinery is version-neutral and lives in plan_v9; this module
# supplies only the table. Sharing it is what keeps the two mirrors from
# drifting into two subtly different notions of "in frame".
CameraProfile = plan_v9.CameraProfile
Transition = plan_v9.Transition


def transition_audit(
    camera: CameraProfile | None = None,
    table: Iterable[PlanTarget] = CANONICAL_TARGETS,
) -> list[Transition]:
    """Every consecutive transition, projected into the active target's frame."""
    return plan_v9.transition_audit(camera, table)


def audit_summary(camera: CameraProfile | None = None) -> dict[str, Any]:
    """Worst transition, failures and the ring breakdown."""
    return plan_v9.audit_summary(camera, CANONICAL_TARGETS, PLAN_V10_VERSION)


def validate_plan_geometry(
    geometry: Iterable[Any],
    version: str | int | None,
) -> list[str]:
    """Compare a received plan against the canonical arch table.

    Returns human-readable problems; an empty list means the geometry matches
    the table for the version it claims. Versions this module does not own are
    never inspected — historical geometry is left exactly as it is.
    """
    if not is_canonical_version(version):
        return []
    return plan_v9.compare_geometry(geometry, CANONICAL_TARGETS, version)


def plan_summary(geometry: Iterable[Any], version: str | int | None) -> dict[str, Any]:
    """A compact description for the stored report."""
    return plan_v9.summarise_geometry(
        geometry, CANONICAL_TARGETS, version, RING_NAMES
    )
