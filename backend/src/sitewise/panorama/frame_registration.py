"""ORB/RANSAC registration of sphere frames against their recorded poses.

Faithful port of ``lib/features/sphere_capture/data/sphere_frame_registration.dart``.

Pipeline per station: one quarter-scale decode + ORB detection per frame,
neighbour pairs chosen from the recorded quaternions, BFMatcher knn + Lowe
ratio, ``findHomography`` used purely as an outlier filter, a sequential
rotation pass anchored to frame 0, two Jacobi averaging sweeps, then a bounded
image-space residual affine per frame (``SITEWISE_OBJECT_INTEGRITY_V1``).
A frame that fails at any step keeps its recorded quaternion.
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass, field
from typing import ClassVar

import cv2
import numpy as np

from .sphere_intrinsics import DecodedProjection, decoded_projection
from .sphere_math import Quat, sphere_orientation_gap_deg
from .sphere_registration import (
    SphereCorrespondence,
    SphereEdgeRefinement,
    merge_sphere_corrections,
    refine_rotation_from_correspondences,
)

REGISTRATION_DECODE_FLAG = cv2.IMREAD_REDUCED_COLOR_4
REGISTRATION_FEATURES = 2500
REGISTRATION_RATIO = 0.75
REGISTRATION_RANSAC_PX = 4.0
REGISTRATION_NEIGHBOURS_PER_FRAME = 5
REGISTRATION_MAX_CORRESPONDENCES = 320
REGISTRATION_AVERAGING_PASSES = 2
REGISTRATION_NEIGHBOUR_DEG = 60.0


@dataclass(frozen=True, slots=True)
class SphereRegistrationFrame:
    target_id: int
    image_path: str
    rotation: Quat
    saved_width: int
    saved_height: int
    source_width: int
    source_height: int
    crop_offset_x: int
    crop_offset_y: int


@dataclass(frozen=True, slots=True)
class SphereResidualAffine:
    du0: float = 0.0
    du_x: float = 0.0
    du_y: float = 0.0
    dv0: float = 0.0
    dv_x: float = 0.0
    dv_y: float = 0.0

    # A class-level singleton, NOT a dataclass field: this is a frozen/slots
    # dataclass, so a normal field would add a seventh constructor argument
    # and every SphereResidualAffine(...) call would try to write a read-only
    # slot named IDENTITY.
    IDENTITY: ClassVar["SphereResidualAffine"]

    @property
    def is_identity(self) -> bool:
        return self == SphereResidualAffine.IDENTITY

    def shift_at(self, u: np.ndarray, v: np.ndarray, width: int, height: int, max_px: float = 35.0):
        """Bounded affine displacement; ``u``/``v`` may be scalars or arrays."""
        if width < 1 or height < 1:
            return np.zeros_like(u, dtype=float), np.zeros_like(v, dtype=float)
        nx = 2.0 * u / width - 1.0
        ny = 2.0 * v / height - 1.0
        radius = np.maximum(np.abs(nx), np.abs(ny))
        t = np.clip((radius - 0.15) / 0.75, 0.0, 1.0)
        peripheral = t * t * (3.0 - 2.0 * t)
        du = (self.du0 + self.du_x * nx + self.du_y * ny) * width * peripheral
        dv = (self.dv0 + self.dv_x * nx + self.dv_y * ny) * height * peripheral
        return np.clip(du, -max_px, max_px), np.clip(dv, -max_px, max_px)

    def shift_scalar(self, u: float, v: float, width: int, height: int, max_px: float = 35.0):
        du, dv = self.shift_at(np.asarray(u, dtype=float), np.asarray(v, dtype=float), width, height, max_px)
        return float(du), float(dv)


SphereResidualAffine.IDENTITY = SphereResidualAffine()


@dataclass(frozen=True, slots=True)
class _ResidualPoint:
    x: float
    y: float
    du: float
    dv: float


@dataclass
class SphereRegistrationOutcome:
    rotations: list[Quat]
    correction_deg: list[float]
    pairs_considered: int
    accepted_edges: int
    rejected_edges: int
    feature_total: int
    elapsed_ms: int
    notes: list[str] = field(default_factory=list)
    mean_residual_after_px: float = 0.0
    max_residual_after_px: float = 0.0
    residual_samples: int = 0
    residual_affines: list[SphereResidualAffine] = field(default_factory=list)

    @staticmethod
    def unrefined(frames: list[SphereRegistrationFrame], note: str | None = None) -> "SphereRegistrationOutcome":
        return SphereRegistrationOutcome(
            rotations=[f.rotation for f in frames],
            correction_deg=[0.0] * len(frames),
            pairs_considered=0,
            accepted_edges=0,
            rejected_edges=0,
            feature_total=0,
            elapsed_ms=0,
            notes=[note] if note else [],
            residual_affines=[SphereResidualAffine.IDENTITY] * len(frames),
        )


def _fit_residual_affine(
    points: list[_ResidualPoint], projection: DecodedProjection
) -> SphereResidualAffine:
    if len(points) < 24:
        return SphereResidualAffine.IDENTITY
    us = sorted(p.du for p in points)
    vs = sorted(p.dv for p in points)
    median_u = us[len(us) // 2]
    median_v = vs[len(vs) // 2]
    coherent = [p for p in points if abs(p.du - median_u) <= 6.0 and abs(p.dv - median_v) <= 6.0]
    if len(coherent) < 24 or len(coherent) < len(points) * 0.60:
        return SphereResidualAffine.IDENTITY

    normal = [0.0] * 9
    rhs_u = [0.0] * 3
    rhs_v = [0.0] * 3
    for p in coherent:
        a = (1.0, p.x, p.y)
        for r in range(3):
            rhs_u[r] += a[r] * p.du / projection.width
            rhs_v[r] += a[r] * p.dv / projection.height
            for c in range(3):
                normal[r * 3 + c] += a[r] * a[c]
    normal[0] += 0.01
    normal[4] += 8.0
    normal[8] += 8.0
    u = _solve_affine3(normal, rhs_u)
    v = _solve_affine3(normal, rhs_v)
    if u is None or v is None:
        return SphereResidualAffine.IDENTITY
    fitted = SphereResidualAffine(
        du0=u[0], du_x=u[1], du_y=u[2], dv0=v[0], dv_x=v[1], dv_y=v[2]
    )
    before = 0.0
    after = 0.0
    for p in coherent:
        target_du = (u[0] + u[1] * p.x + u[2] * p.y) * projection.width
        target_dv = (v[0] + v[1] * p.x + v[2] * p.y) * projection.height
        before += math.sqrt(p.du * p.du + p.dv * p.dv)
        after += math.sqrt((p.du - target_du) ** 2 + (p.dv - target_dv) ** 2)
    if before < 0.5 * len(coherent) or after >= 0.85 * before:
        return SphereResidualAffine.IDENTITY
    if (
        abs(u[0] * projection.width) > 25
        or abs(v[0] * projection.height) > 25
        or abs(u[1]) > 0.018
        or abs(u[2]) > 0.018
        or abs(v[1]) > 0.018
        or abs(v[2]) > 0.018
    ):
        return SphereResidualAffine.IDENTITY
    return fitted


def _solve_affine3(coefficients: list[float], rhs: list[float]) -> list[float] | None:
    a = list(coefficients)
    b = list(rhs)
    for k in range(3):
        pivot = k
        for row in range(k + 1, 3):
            if abs(a[row * 3 + k]) > abs(a[pivot * 3 + k]):
                pivot = row
        if abs(a[pivot * 3 + k]) < 1e-10:
            return None
        if pivot != k:
            for col in range(3):
                a[k * 3 + col], a[pivot * 3 + col] = a[pivot * 3 + col], a[k * 3 + col]
            b[k], b[pivot] = b[pivot], b[k]
        for row in range(k + 1, 3):
            ratio = a[row * 3 + k] / a[k * 3 + k]
            for col in range(k, 3):
                a[row * 3 + col] -= ratio * a[k * 3 + col]
            b[row] -= ratio * b[k]
    solution = [0.0, 0.0, 0.0]
    for row in range(2, -1, -1):
        total = b[row]
        for col in range(row + 1, 3):
            total -= a[row * 3 + col] * solution[col]
        solution[row] = total / a[row * 3 + row]
        if not math.isfinite(solution[row]):
            return None
    return solution


@dataclass(frozen=True, slots=True)
class _PairMatches:
    points: list[SphereCorrespondence]
    feature_matches: int

    def reversed(self) -> "_PairMatches":
        return _PairMatches([c.reversed() for c in self.points], self.feature_matches)


def _neighbour_pairs(frames: list[SphereRegistrationFrame]) -> list[tuple[int, int]]:
    candidates: list[tuple[int, int, float]] = []
    for i in range(len(frames)):
        for j in range(i + 1, len(frames)):
            gap = sphere_orientation_gap_deg(frames[i].rotation, frames[j].rotation)
            if gap > REGISTRATION_NEIGHBOUR_DEG:
                continue
            candidates.append((i, j, gap))
    candidates.sort(key=lambda c: c[2])

    per_frame = [0] * len(frames)
    pairs: list[tuple[int, int]] = []
    for i, j, _gap in candidates:
        if per_frame[i] >= REGISTRATION_NEIGHBOURS_PER_FRAME:
            continue
        if per_frame[j] >= REGISTRATION_NEIGHBOURS_PER_FRAME:
            continue
        per_frame[i] += 1
        per_frame[j] += 1
        pairs.append((i, j))
    return pairs


def _match_pair(
    first: int,
    second: int,
    descriptors: list[np.ndarray | None],
    keypoints: list[np.ndarray | None],
    matcher: cv2.BFMatcher,
) -> _PairMatches | None:
    first_descriptors = descriptors[first]
    second_descriptors = descriptors[second]
    first_points = keypoints[first]
    second_points = keypoints[second]
    if (
        first_descriptors is None
        or second_descriptors is None
        or first_points is None
        or second_points is None
    ):
        return None

    try:
        knn = matcher.knnMatch(first_descriptors, second_descriptors, k=2)
        kept: list[tuple[int, int]] = []
        for row in knn:
            if len(row) < 2:
                continue
            best, runner_up = row[0], row[1]
            if best.distance < REGISTRATION_RATIO * runner_up.distance:
                kept.append((best.queryIdx, best.trainIdx))
        if len(kept) < 12:
            return _PairMatches(points=[], feature_matches=len(kept))

        src = np.array(
            [[first_points[q * 2], first_points[q * 2 + 1]] for q, _t in kept],
            dtype=np.float32,
        )
        dst = np.array(
            [[second_points[t * 2], second_points[t * 2 + 1]] for _q, t in kept],
            dtype=np.float32,
        )
        _homography, mask = cv2.findHomography(
            src.reshape(-1, 1, 2), dst.reshape(-1, 1, 2), cv2.RANSAC, REGISTRATION_RANSAC_PX
        )
        if mask is None:
            return _PairMatches(points=[], feature_matches=len(kept))
        mask = mask.ravel()

        points: list[SphereCorrespondence] = []
        for i, (q, t) in enumerate(kept):
            if mask[i] == 0:
                continue
            if len(points) >= REGISTRATION_MAX_CORRESPONDENCES:
                break
            points.append(
                SphereCorrespondence(
                    frame_u=float(first_points[q * 2]),
                    frame_v=float(first_points[q * 2 + 1]),
                    neighbour_u=float(second_points[t * 2]),
                    neighbour_v=float(second_points[t * 2 + 1]),
                )
            )
        return _PairMatches(points=points, feature_matches=len(kept))
    except Exception:
        return None


def register_sphere_frames(
    *,
    frames: list[SphereRegistrationFrame],
    vertical_fov_deg: float,
    on_stage=None,
) -> SphereRegistrationOutcome:
    if len(frames) < 2:
        return SphereRegistrationOutcome.unrefined(
            frames, note="A single photograph has nothing to register against."
        )
    started = time.monotonic()

    def stage(message: str) -> None:
        if on_stage is not None:
            on_stage(message)

    descriptors: list[np.ndarray | None] = [None] * len(frames)
    keypoints: list[np.ndarray | None] = [None] * len(frames)
    projections: list[DecodedProjection | None] = [None] * len(frames)
    usable = [False] * len(frames)
    feature_total = 0

    orb = cv2.ORB_create(nfeatures=REGISTRATION_FEATURES)
    for i, frame in enumerate(frames):
        stage(f"Checking overlap: photograph {i + 1}/{len(frames)}…")
        colour = cv2.imread(frame.image_path, REGISTRATION_DECODE_FLAG)
        if colour is None or colour.size == 0:
            continue
        gray = cv2.cvtColor(colour, cv2.COLOR_BGR2GRAY)
        projection = decoded_projection(
            decoded_width=gray.shape[1],
            decoded_height=gray.shape[0],
            saved_width=frame.saved_width,
            saved_height=frame.saved_height,
            source_width=frame.source_width,
            source_height=frame.source_height,
            vertical_fov_deg=vertical_fov_deg,
            crop_offset_x=frame.crop_offset_x,
            crop_offset_y=frame.crop_offset_y,
        )
        if projection is None:
            continue
        projections[i] = projection
        detected, description = orb.detectAndCompute(gray, None)
        count = 0 if detected is None else len(detected)
        if count < 12 or description is None or len(description) == 0:
            continue
        points = np.empty(count * 2, dtype=np.float32)
        for k, kp in enumerate(detected):
            points[k * 2] = kp.pt[0]
            points[k * 2 + 1] = kp.pt[1]
        descriptors[i] = description
        keypoints[i] = points
        feature_total += count
        usable[i] = True

    pairs = _neighbour_pairs(frames)
    stage(f"Matching {len(pairs)} overlapping pairs ({len(frames)} photographs)…")

    matches: list[_PairMatches | None] = [None] * len(pairs)
    matcher = cv2.BFMatcher_create(cv2.NORM_HAMMING)
    for p, (i, j) in enumerate(pairs):
        if not usable[i] or not usable[j]:
            continue
        matches[p] = _match_pair(i, j, descriptors, keypoints, matcher)

    accepted = 0
    rejected = 0
    residual_sum = 0.0
    residual_count = 0
    residual_max = 0.0
    notes: list[str] = []

    def note_residual(refinement: SphereEdgeRefinement) -> None:
        nonlocal residual_sum, residual_count, residual_max
        value = refinement.residual_after_px
        if not math.isfinite(value) or value < 0:
            return
        residual_sum += value
        residual_count += 1
        residual_max = max(residual_max, value)

    def tally(refinement: SphereEdgeRefinement, target_id: int) -> None:
        nonlocal accepted, rejected
        if refinement.accepted:
            accepted += 1
            note_residual(refinement)
            return
        rejected += 1
        if len(notes) < 6 and refinement.rejection is not None:
            notes.append(f"Frame {target_id}: {refinement.rejection}")

    rotations = [f.rotation for f in frames]
    settled = [False] * len(frames)

    neighbours: list[list[int]] = [[] for _ in frames]
    for p, (i, j) in enumerate(pairs):
        if matches[p] is None:
            continue
        neighbours[i].append(p)
        neighbours[j].append(p)

    def refine(subject: int, pair_index: int) -> SphereEdgeRefinement:
        cached = matches[pair_index]
        if cached is None:
            return SphereEdgeRefinement.none()
        first_is_subject = pairs[pair_index][0] == subject
        reference = pairs[pair_index][1] if first_is_subject else pairs[pair_index][0]
        subject_projection = projections[subject]
        reference_projection = projections[reference]
        if subject_projection is None or reference_projection is None:
            return SphereEdgeRefinement.none()
        return refine_rotation_from_correspondences(
            frame_rotation=rotations[subject],
            neighbour_rotation=rotations[reference],
            frame_projection=subject_projection,
            neighbour_projection=reference_projection,
            correspondences=cached.points if first_is_subject else cached.reversed().points,
            feature_matches=cached.feature_matches,
        )

    # Sequential pass: each frame anchors to an already-corrected neighbour.
    settled[0] = True
    for i in range(1, len(frames)):
        if not usable[i]:
            settled[i] = True
            continue
        proposals: list[SphereEdgeRefinement] = []
        for pair_index in neighbours[i]:
            a, b = pairs[pair_index]
            other = b if a == i else a
            if not settled[other]:
                continue
            refinement = refine(i, pair_index)
            tally(refinement, frames[i].target_id)
            proposals.append(refinement)
        correction = merge_sphere_corrections(proposals)
        if correction is not None:
            rotations[i] = (correction * rotations[i]).normalized
        settled[i] = True
        if i % 6 == 0:
            stage(f"Refining orientations: {i + 1}/{len(frames)}…")

    # Jacobi averaging sweeps from a frozen snapshot.
    for _pass in range(REGISTRATION_AVERAGING_PASSES):
        snapshot = list(rotations)
        updates: list[Quat | None] = [None] * len(frames)
        for i in range(1, len(frames)):
            if not usable[i]:
                continue
            proposals = []
            for pair_index in neighbours[i]:
                refinement = refine(i, pair_index)
                if refinement.accepted:
                    accepted += 1
                    note_residual(refinement)
                else:
                    rejected += 1
                proposals.append(refinement)
            updates[i] = merge_sphere_corrections(proposals)
        for i in range(1, len(frames)):
            update = updates[i]
            if update is None:
                continue
            rotations[i] = (update * snapshot[i]).normalized
        stage(f"Averaging orientations: sweep {_pass + 1}/{REGISTRATION_AVERAGING_PASSES}…")

    # Bounded residual affine per frame, referenced against an earlier neighbour.
    residual_affines: list[SphereResidualAffine] = [
        SphereResidualAffine.IDENTITY
    ] * len(frames)
    for i in range(1, len(frames)):
        if not usable[i] or projections[i] is None:
            continue
        chosen = -1
        reference = -1
        largest_inliers = 0
        for p in neighbours[i]:
            a, b = pairs[p]
            other = b if a == i else a
            candidate = matches[p]
            if other >= i or projections[other] is None or candidate is None or len(candidate.points) < 24:
                continue
            if len(candidate.points) > largest_inliers:
                largest_inliers = len(candidate.points)
                chosen = p
                reference = other
        if chosen < 0:
            continue
        subject_projection = projections[i]
        neighbour_projection = projections[reference]
        cached = matches[chosen]
        subject_first = pairs[chosen][0] == i
        correspondences = cached.points if subject_first else cached.reversed().points
        observations: list[_ResidualPoint] = []
        for c in correspondences:
            ref_shift_du, ref_shift_dv = residual_affines[reference].shift_scalar(
                c.neighbour_u,
                c.neighbour_v,
                neighbour_projection.width,
                neighbour_projection.height,
            )
            world = rotations[reference].rotate(
                unproject_for_residual(
                    c.neighbour_u - ref_shift_du,
                    c.neighbour_v - ref_shift_dv,
                    neighbour_projection,
                )
            )
            predicted = project_for_residual(
                rotations[i].conjugate.rotate(world), subject_projection
            )
            if predicted is None:
                continue
            du = c.frame_u - predicted[0]
            dv = c.frame_v - predicted[1]
            if not math.isfinite(du) or not math.isfinite(dv) or abs(du) > 40 or abs(dv) > 40:
                continue
            observations.append(
                _ResidualPoint(
                    2 * c.frame_u / subject_projection.width - 1,
                    2 * c.frame_v / subject_projection.height - 1,
                    du,
                    dv,
                )
            )
        residual_affines[i] = _fit_residual_affine(observations, subject_projection)

    correction_deg = [
        sphere_orientation_gap_deg(frames[i].rotation, rotations[i]) for i in range(len(frames))
    ]
    if not any(d > 0 for d in correction_deg):
        notes.append(
            "No frame had a trustworthy overlap, so every photograph keeps its "
            "recorded orientation."
        )

    return SphereRegistrationOutcome(
        rotations=rotations,
        correction_deg=correction_deg,
        pairs_considered=len(pairs),
        accepted_edges=accepted,
        rejected_edges=rejected,
        feature_total=feature_total,
        elapsed_ms=int((time.monotonic() - started) * 1000),
        notes=notes,
        mean_residual_after_px=0.0 if residual_count == 0 else residual_sum / residual_count,
        max_residual_after_px=residual_max,
        residual_samples=residual_count,
        residual_affines=residual_affines,
    )


# Local aliases keep the residual-affine section readable; they reuse the
# identical maths from sphere_registration (unproject/project) but without the
# projection-behind-camera epsilon difference: registration uses 1e-6, the
# stitcher's bounds use 0.05.
from .sphere_registration import project_camera_ray as project_for_residual
from .sphere_registration import unproject_pixel as unproject_for_residual


def max_correction_deg(corrections: list[float]) -> float:
    return max(corrections, default=0.0)
