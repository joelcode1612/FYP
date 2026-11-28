"""Orientation-guided candidate pairs, including the cross-ring pairs.

## Why not "neighbours" alone

The previous registration selected pairs purely by angular gap and capped each
frame at a fixed number of partners. On a five-ring layout that silently drops
vertical pairs: a middle frame has two horizontal neighbours at 30° and two
polar-ring partners at 65°, so the 30° pairs win every slot and the
middle↔upper/middle↔lower connections — the ones that decide whether the
panorama tears at the horizon — are never even attempted.

This module fixes that structurally:

* the gap test uses the **diagonal** footprint, so a genuinely overlapping
  diagonal pair is a candidate;
* every frame is guaranteed a partner in each *adjacent ring* that exists,
  before the remaining slots go to the closest remaining partners.

The result is a candidate set, never a verified one. Each pair still has to
pass :func:`sitewise.panorama.alignment.matching.verify_pair`.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from ..sphere_math import Quat
from .camera import (
    RING_ADJACENCY,
    RING_MIDDLE,
    PinholeCamera,
    angular_gap_deg,
    frame_pitch_yaw,
    frame_ring,
)

#: Hard ceiling on the number of pairs a single frame may be matched against.
#: Six covers two horizontal, two upper and two lower partners on the reference
#: layout; raising it multiplies worker time without adding connectivity.
DEFAULT_NEIGHBOURS_PER_FRAME = 6


@dataclass(frozen=True, slots=True)
class PairFrame:
    """One accepted photograph as the pair planner sees it."""

    target_id: int
    rotation: Quat
    camera: PinholeCamera
    pitch_deg: float = field(init=False)
    yaw_deg: float = field(init=False)
    ring: str = field(init=False)

    def __post_init__(self) -> None:
        pitch, yaw = frame_pitch_yaw(self.rotation)
        object.__setattr__(self, "pitch_deg", pitch)
        object.__setattr__(self, "yaw_deg", yaw)
        object.__setattr__(self, "ring", frame_ring(pitch))


@dataclass(frozen=True, slots=True)
class CandidatePair:
    first: int
    second: int
    gap_deg: float
    expected_overlap: float
    cross_ring: bool
    rings: tuple[str, str]
    priority: float

    def as_dict(self) -> dict[str, object]:
        return {
            "a": self.first,
            "b": self.second,
            "gapDeg": round(self.gap_deg, 2),
            "expectedOverlap": round(self.expected_overlap, 3),
            "crossRing": self.cross_ring,
            "rings": list(self.rings),
        }


def expected_overlap_fraction(first: PairFrame, second: PairFrame, gap_deg: float) -> float:
    """Shared spherical area as a fraction of the smaller footprint.

    The footprint is approximated as a spherical cap of the frame's diagonal
    half-angle. Two caps of half-angles ``α`` and ``β`` separated by ``γ``
    overlap when ``γ < α + β``; the linear ramp below is the standard
    two-circle overlap approximation, normalised by the smaller cap so the
    result reads as "how much of the smaller photograph is shared".

    This is a *planning* estimate. The reported coverage in
    :mod:`coverage` is measured from projected footprints and is authoritative.
    """
    alpha = math.radians(first.camera.diagonal_fov_deg / 2.0)
    beta = math.radians(second.camera.diagonal_fov_deg / 2.0)
    gamma = math.radians(gap_deg)
    if gamma >= alpha + beta or alpha <= 0 or beta <= 0:
        return 0.0
    smaller = min(alpha, beta)
    larger = max(alpha, beta)
    # Lens-area overlap of two unequal circles, normalised by the smaller.
    if gamma <= larger - smaller:
        return 1.0
    cos_a = (gamma * gamma + smaller * smaller - larger * larger) / (2 * gamma * smaller)
    cos_b = (gamma * gamma + larger * larger - smaller * smaller) / (2 * gamma * larger)
    cos_a = max(-1.0, min(1.0, cos_a))
    cos_b = max(-1.0, min(1.0, cos_b))
    lens = (
        smaller * smaller * math.acos(cos_a)
        + larger * larger * math.acos(cos_b)
        - 0.5
        * math.sqrt(
            max(
                0.0,
                (-gamma + smaller + larger)
                * (gamma + smaller - larger)
                * (gamma - smaller + larger)
                * (gamma + smaller + larger),
            )
        )
    )
    area_smaller = math.pi * smaller * smaller
    return max(0.0, min(1.0, lens / area_smaller))


def candidate_pairs(
    frames: list[PairFrame],
    *,
    neighbours_per_frame: int = DEFAULT_NEIGHBOURS_PER_FRAME,
    min_expected_overlap: float = 0.12,
    max_gap_deg: float | None = None,
) -> list[CandidatePair]:
    """Orientation-guided candidate pairs, cross-ring connections guaranteed.

    [min_expected_overlap] is the floor below which a pair is not worth a
    feature match: the shared area would be too thin for the ratio test to
    produce enough correspondences. It is deliberately low because a thin but
    real overlap is exactly what a polar cap needs to stay attached.
    """
    if len(frames) < 2:
        return []

    if max_gap_deg is None:
        widest = max(f.camera.diagonal_fov_deg for f in frames)
        max_gap_deg = widest * 1.05

    scored: dict[tuple[int, int], CandidatePair] = {}
    for i in range(len(frames)):
        for j in range(i + 1, len(frames)):
            a, b = frames[i], frames[j]
            gap = angular_gap_deg(a.rotation, b.rotation)
            if gap > max_gap_deg:
                continue
            overlap = expected_overlap_fraction(a, b, gap)
            if overlap < min_expected_overlap:
                continue
            cross_ring = a.ring != b.ring
            adjacent_ring = b.ring in RING_ADJACENCY.get(a.ring, ()) or a.ring in (
                RING_ADJACENCY.get(b.ring, ())
            )
            # Priority: real overlap first, then the vertical connections that
            # the panorama's structural integrity depends on.
            priority = overlap + (0.25 if cross_ring and adjacent_ring else 0.0)
            key = (min(a.target_id, b.target_id), max(a.target_id, b.target_id))
            scored[key] = CandidatePair(
                first=a.target_id,
                second=b.target_id,
                gap_deg=gap,
                expected_overlap=overlap,
                cross_ring=cross_ring,
                rings=(a.ring, b.ring),
                priority=priority,
            )

    by_id = {f.target_id: f for f in frames}
    degree: dict[int, int] = {f.target_id: 0 for f in frames}
    chosen: dict[tuple[int, int], CandidatePair] = {}

    def take(pair: CandidatePair) -> bool:
        if degree[pair.first] >= neighbours_per_frame:
            return False
        if degree[pair.second] >= neighbours_per_frame:
            return False
        key = (pair.first, pair.second)
        if key in chosen:
            return False
        chosen[key] = pair
        degree[pair.first] += 1
        degree[pair.second] += 1
        return True

    ordered = sorted(scored.values(), key=lambda p: -p.priority)

    # Pass 1 — every frame gets one partner in each adjacent ring it has.
    for target_id in sorted(by_id):
        frame = by_id[target_id]
        for ring in RING_ADJACENCY.get(frame.ring, ()):
            if degree[target_id] >= neighbours_per_frame:
                break
            already = any(
                chosen.get((min(target_id, other), max(target_id, other))) is not None
                and by_id[other].ring == ring
                for other in by_id
                if other != target_id
            )
            if already:
                continue
            options = [
                p
                for p in ordered
                if target_id in (p.first, p.second)
                and ring in p.rings
                and p.first != p.second
                and (p.first, p.second) not in chosen
            ]
            for option in options:
                if take(option):
                    break

    # Pass 2 — the middle ring's horizontal loop, which is what makes the
    # 0°/360° seam close rather than merely touch.
    middle = [f for f in frames if f.ring == RING_MIDDLE]
    if len(middle) >= 3:
        ordered_middle = sorted(middle, key=lambda f: f.yaw_deg % 360.0)
        for index, frame in enumerate(ordered_middle):
            if degree[frame.target_id] >= neighbours_per_frame:
                continue
            neighbour = ordered_middle[(index + 1) % len(ordered_middle)]
            key = (
                min(frame.target_id, neighbour.target_id),
                max(frame.target_id, neighbour.target_id),
            )
            if key in chosen or key not in scored:
                continue
            take(scored[key])

    # Pass 3 — fill remaining slots with the best-overlapping leftovers.
    for pair in ordered:
        if degree[pair.first] >= neighbours_per_frame and degree[pair.second] >= neighbours_per_frame:
            continue
        take(pair)

    return sorted(
        chosen.values(), key=lambda p: (-p.priority, p.first, p.second)
    )


def pairs_for_frame(
    pairs: list[CandidatePair], target_id: int
) -> list[CandidatePair]:
    """Every candidate pair that touches [target_id], best first."""
    return [p for p in pairs if target_id in (p.first, p.second)]


__all__ = [
    "CandidatePair",
    "DEFAULT_NEIGHBOURS_PER_FRAME",
    "PairFrame",
    "candidate_pairs",
    "expected_overlap_fraction",
    "pairs_for_frame",
]
