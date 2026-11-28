"""The visibility-derived capture plan (version 7), as FastAPI knows it.

The device owns target generation; this module owns the **identity contract**
and the **geometry audit**. Target id 37 must mean the same direction for every
session that claims plan version 7, or the match rows, coverage audits and
stored poses of one capture would be silently reinterpreted against another
capture's layout.

## Why this layout exists

Plans 4 and 5 spaced the main rings 30° apart. At the documented 51.08°
horizontal field of view that puts the previous target at
``tan(30°) / tan(25.5°) = 1.09`` of the half-frame — *outside the picture*. The
photographer turned, the reticle was empty, and the resulting frame shared only
a corner sliver with its predecessor. The independent 44-photo analysis
measured exactly that signature: 11 photographs with no reliable connection,
concentrated in the plain-wall and polar bands.

The spacing here is derived from the lens instead of assumed:

* usable half-frame = ``tan(fov/2) · (1 − margin)`` with a 10% safe margin,
* maximum step = ``atan(usable half-frame)``,
* columns = ``ceil(360 / maximum yaw step)``,
* rows = multiples of ``floor(maximum pitch step)`` until the outermost row can
  still see the pole.

For 3072 × 4096 at 65° vertical that is 16 columns at 22.5° and rows at
0°, ±29°, ±58° — 80 targets, captured as a **vertical serpentine** (up one
column, down the next) so no transition ever jumps across the sphere.

## What this module does and does not do

* It **does** answer "is this geometry the canonical version-7 grid?" and
  "which row is target N in?".
* It does **not** reject a capture. A disagreement is reported as a warning so
  it reaches the report; failing a sweep over a label is worse than recording
  that the label was wrong.

Historical plans (versions 1–6) are never reinterpreted through this table.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable

#: Plan version of the visibility-derived 80-target layout.
PLAN_V7_VERSION = "7"
#: Plan version of the deterministic densification, used only when the
#: calibrated lens cannot keep the previous photograph in frame at the
#: canonical spacing.
PLAN_V7_DENSE_VERSION = "8"
#: Canonical target count.
PLAN_V7_TARGET_COUNT = 80
#: Densified target count.
PLAN_V7_DENSE_TARGET_COUNT = 126
#: Column count of the canonical layout.
PLAN_V7_COLUMNS = 16
#: Row pitches of the canonical layout, outermost last.
PLAN_V7_ROWS: tuple[float, ...] = (0.0, 29.0, -29.0, 58.0, -58.0)
#: Rows of the densified fallback.
PLAN_V7_DENSE_ROWS: tuple[float, ...] = (0.0, 25.0, -25.0, 50.0, -50.0, 75.0, -75.0)
#: Column count of the densified fallback.
PLAN_V7_DENSE_COLUMNS = 18
#: The usable fraction of the frame: a 10% margin on every side.
PLAN_V7_SAFE_MARGIN = 0.10
#: The alignment cone the capture gate already enforces.
PLAN_V7_TOLERANCE_DEG = 2.0

#: Row keys in capture order for the stage list.
STAGE_ORDER: tuple[str, ...] = ("middle", "upper", "ceiling", "lower", "floor")


@dataclass(frozen=True, slots=True)
class GridTarget:
    """One row of the derived grid, in capture order."""

    target_id: int
    yaw_deg: float
    pitch_deg: float
    ring: str
    column: int


def ring_key(pitch_deg: float) -> str:
    """The row a pitch belongs to."""
    if abs(pitch_deg) < 1e-9:
        return "middle"
    if pitch_deg > 0:
        return "ceiling" if pitch_deg >= 50 else "upper"
    return "floor" if pitch_deg <= -50 else "lower"


def build_grid(
    columns: int = PLAN_V7_COLUMNS,
    rows: Iterable[float] = PLAN_V7_ROWS,
) -> tuple[GridTarget, ...]:
    """The derived grid, in capture order.

    Deterministic and identical to ``planV7Table()`` in
    ``fyp_mobile_app/lib/features/capture_360/domain/sphere/sphere_plan_v7.dart``:
    the same integers produce the same table, which is what lets the device and
    this backend agree without shipping a copy of each other's source.

    The order is a vertical serpentine — column 0 walks upward, column 1
    downward, and so on — so consecutive photographs are never more than one
    row apart.
    """
    pitches = [float(row) for row in rows]
    step = 360.0 / columns
    table: list[GridTarget] = []
    target_id = 0
    upward = True
    for column in range(columns):
        yaw = column * step
        # Explicitly sorted: the rows list is documentation order, not walk
        # order, and a column must be a monotone sweep or the camera would jump
        # the height of the sphere inside one column.
        ordered = sorted(pitches) if upward else sorted(pitches, reverse=True)
        for pitch in ordered:
            target_id += 1
            table.append(
                GridTarget(
                    target_id=target_id,
                    yaw_deg=yaw,
                    pitch_deg=pitch,
                    ring=ring_key(pitch),
                    column=column,
                )
            )
        upward = not upward
    return tuple(table)


CANONICAL_TARGETS: tuple[GridTarget, ...] = build_grid()
DENSE_TARGETS: tuple[GridTarget, ...] = build_grid(
    columns=PLAN_V7_DENSE_COLUMNS, rows=PLAN_V7_DENSE_ROWS
)

#: Ring counts of the canonical layout, for reporting.
RING_COUNTS: dict[str, int] = {
    key: sum(1 for target in CANONICAL_TARGETS if target.ring == key)
    for key in STAGE_ORDER
}


def is_canonical_version(version: str | int | None) -> bool:
    """Whether this module is responsible for auditing the version."""
    return str(version).strip() in {PLAN_V7_VERSION, PLAN_V7_DENSE_VERSION}


def expected_table(version: str | int | None) -> tuple[GridTarget, ...]:
    return (
        DENSE_TARGETS
        if str(version).strip() == PLAN_V7_DENSE_VERSION
        else CANONICAL_TARGETS
    )


def validate_plan_geometry(
    geometry: Iterable[Any],
    version: str | int | None,
) -> list[str]:
    """Compare a received plan against the derived grid.

    Returns human-readable problems; an empty list means the geometry matches
    the table for the version it claims. Versions this module does not own are
    never inspected — historical geometry is left exactly as it is.
    """
    if not is_canonical_version(version):
        return []

    targets = [t for t in geometry if isinstance(t, dict)]
    if not targets:
        return ["The plan claims the derived layout but carries no targets."]

    expected = expected_table(version)
    problems: list[str] = []
    if len(targets) != len(expected):
        problems.append(
            f"Plan version {version} must have {len(expected)} targets, "
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

    for row in expected:
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
                f"belongs to the {row.ring} row."
            )
    return problems


def plan_summary(geometry: Iterable[Any], version: str | int | None) -> dict[str, Any]:
    """A compact description for the stored report."""
    targets = [t for t in geometry if isinstance(t, dict)]
    columns = len({round(float(t.get("yawDeg") or 0.0), 3) for t in targets})
    pitches = sorted({round(float(t.get("pitchDeg") or 0.0), 3) for t in targets})
    return {
        "planVersion": str(version),
        "targetCount": len(targets),
        "columns": columns,
        "rowPitches": pitches,
        "expectedTargetCount": len(expected_table(version)),
        "matchesCanonical": not validate_plan_geometry(geometry, version),
    }
