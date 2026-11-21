"""Rotation refinement for the 38-target sphere flow.

Faithful port of ``lib/features/sphere_capture/domain/sphere_registration.dart``.

The recorded sensor quaternion stays the prior; this refines it against the
pixels two neighbouring photographs share. The refinement is deliberately
small-angle: corrections are expected to be a degree or two and anything larger
is treated as a bad match. The residual is measured through the same projection
the stitcher uses (``depth = −camZ``), so camera conventions cancel by
construction.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from .sphere_intrinsics import DecodedProjection
from .sphere_math import Quat, UNIT_X, UNIT_Y, UNIT_Z, Vec3

MIN_INLIERS = 12
MIN_INLIER_RATIO = 0.35
MAX_CORRECTION_DEG = 12.0
MAX_RESIDUAL_PX = 8.0
NEIGHBOUR_DEG = 60.0


def unproject_pixel(u: float, v: float, projection: DecodedProjection) -> Vec3:
    return Vec3(
        (u - projection.cx) / projection.focal_px,
        -(v - projection.cy) / projection.focal_px,
        -1.0,
    )


def project_camera_ray(ray: Vec3, projection: DecodedProjection) -> tuple[float, float] | None:
    depth = -ray.z
    if depth <= 1e-6:
        return None
    return (
        projection.cx + projection.focal_px * ray.x / depth,
        projection.cy - projection.focal_px * ray.y / depth,
    )


@dataclass(frozen=True, slots=True)
class SphereCorrespondence:
    frame_u: float
    frame_v: float
    neighbour_u: float
    neighbour_v: float

    def reversed(self) -> "SphereCorrespondence":
        return SphereCorrespondence(self.neighbour_u, self.neighbour_v, self.frame_u, self.frame_v)


@dataclass(frozen=True, slots=True)
class SphereEdgeRefinement:
    correction: Quat
    correction_deg: float
    inliers: int
    inlier_ratio: float
    residual_before_px: float
    residual_after_px: float
    accepted: bool
    rejection: str | None

    @staticmethod
    def none() -> "SphereEdgeRefinement":
        return SphereEdgeRefinement(
            correction=Quat.identity(),
            correction_deg=0.0,
            inliers=0,
            inlier_ratio=0.0,
            residual_before_px=0.0,
            residual_after_px=0.0,
            accepted=False,
            rejection="No correspondence was measured.",
        )


def _apply_world_rotation(rotation: Quat, axis_angle: Vec3) -> Quat:
    length = axis_angle.length
    if length <= 1e-12:
        return rotation
    return (Quat.axis_angle(length * 180 / math.pi, axis_angle) * rotation).normalized


def _axis_angle_vector(correction: Quat, correction_deg: float) -> Vec3:
    axis = Vec3(correction.x, correction.y, correction.z)
    length = axis.length
    if length <= 1e-12:
        return Vec3.zero()
    return axis * (correction_deg * math.pi / 180 / length)


def _mean_residual(
    rotation: Quat,
    world_rays: list[Vec3],
    correspondences: list[SphereCorrespondence],
    projection: DecodedProjection,
) -> float:
    to_camera = rotation.conjugate
    total = 0.0
    count = 0
    for i, c in enumerate(correspondences):
        predicted = project_camera_ray(to_camera.rotate(world_rays[i]), projection)
        if predicted is None:
            continue
        du = predicted[0] - c.frame_u
        dv = predicted[1] - c.frame_v
        total += math.sqrt(du * du + dv * dv)
        count += 1
    return 0.0 if count == 0 else total / count


def _linearise(
    rotation: Quat,
    world_rays: list[Vec3],
    correspondences: list[SphereCorrespondence],
    projection: DecodedProjection,
) -> tuple[list[float], list[float]]:
    h = 1e-4  # radians
    count = len(correspondences)
    jacobian = [0.0] * (count * 6)
    residual = [0.0] * (count * 2)

    to_camera = rotation.conjugate
    for i, c in enumerate(correspondences):
        predicted = project_camera_ray(to_camera.rotate(world_rays[i]), projection)
        if predicted is None:
            continue
        residual[i * 2] = predicted[0] - c.frame_u
        residual[i * 2 + 1] = predicted[1] - c.frame_v

    for axis_index, unit in enumerate((UNIT_X, UNIT_Y, UNIT_Z)):
        plus = (Quat.axis_angle(h * 180 / math.pi, unit) * rotation).normalized
        minus = (Quat.axis_angle(-h * 180 / math.pi, unit) * rotation).normalized
        plus_to_camera = plus.conjugate
        minus_to_camera = minus.conjugate
        for i in range(count):
            p = project_camera_ray(plus_to_camera.rotate(world_rays[i]), projection)
            m = project_camera_ray(minus_to_camera.rotate(world_rays[i]), projection)
            if p is None or m is None:
                continue
            jacobian[i * 6 + axis_index] = (p[0] - m[0]) / (2 * h)
            jacobian[i * 6 + 3 + axis_index] = (p[1] - m[1]) / (2 * h)
    return jacobian, residual


def _normal_equations(
    jacobian: list[float], residual: list[float]
) -> tuple[list[float], list[float]]:
    matrix = [0.0] * 9
    gradient = [0.0] * 3
    rows = len(jacobian) // 6
    for i in range(rows):
        o = i * 6
        ru = residual[i * 2]
        rv = residual[i * 2 + 1]
        for a in range(3):
            ja_u = jacobian[o + a]
            ja_v = jacobian[o + 3 + a]
            gradient[a] += ja_u * ru + ja_v * rv
            for b in range(3):
                matrix[a * 3 + b] += ja_u * jacobian[o + b] + ja_v * jacobian[o + 3 + b]
    return matrix, gradient


def _det3(a, b, c, d, e, f, g, h, i) -> float:
    return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)


def _solve3x3(m: list[float], rhs: list[float]) -> list[float] | None:
    det = _det3(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
    if abs(det) < 1e-12:
        return None
    x = _det3(rhs[0], m[1], m[2], rhs[1], m[4], m[5], rhs[2], m[7], m[8]) / det
    y = _det3(m[0], rhs[0], m[2], m[3], rhs[1], m[5], m[6], rhs[2], m[8]) / det
    z = _det3(m[0], m[1], rhs[0], m[3], m[4], rhs[1], m[6], m[7], rhs[2]) / det
    return [x, y, z]


def refine_rotation_from_correspondences(
    *,
    frame_rotation: Quat,
    neighbour_rotation: Quat,
    frame_projection: DecodedProjection,
    neighbour_projection: DecodedProjection,
    correspondences: list[SphereCorrespondence],
    feature_matches: int,
) -> SphereEdgeRefinement:
    inlier_ratio = 0.0 if feature_matches == 0 else len(correspondences) / feature_matches

    def refused(deg: float, before: float, after: float, reason: str) -> SphereEdgeRefinement:
        return SphereEdgeRefinement(
            correction=Quat.identity(),
            correction_deg=deg,
            inliers=len(correspondences),
            inlier_ratio=inlier_ratio,
            residual_before_px=before,
            residual_after_px=after,
            accepted=False,
            rejection=reason,
        )

    if len(correspondences) < MIN_INLIERS:
        return refused(
            0.0,
            0.0,
            0.0,
            f"Only {len(correspondences)} matches survived geometric "
            f"verification; {MIN_INLIERS} are needed to trust a rotation.",
        )
    if inlier_ratio < MIN_INLIER_RATIO:
        return refused(
            0.0,
            0.0,
            0.0,
            f"Only {inlier_ratio * 100:.0f}% of the matches were geometrically consistent.",
        )

    world_rays = [
        neighbour_rotation.rotate(unproject_pixel(c.neighbour_u, c.neighbour_v, neighbour_projection))
        for c in correspondences
    ]

    before = _mean_residual(frame_rotation, world_rays, correspondences, frame_projection)

    rotation = frame_rotation
    accepted_delta = Vec3.zero()
    residual = before

    for _iteration in range(8):
        jacobian, residual_lin = _linearise(rotation, world_rays, correspondences, frame_projection)
        if not jacobian:
            break
        matrix, gradient = _normal_equations(jacobian, residual_lin)

        trace = matrix[0] + matrix[4] + matrix[8]
        if trace <= 0:
            break
        lam = 1e-6 * trace / 3
        damped = [
            matrix[0] + lam,
            matrix[1],
            matrix[2],
            matrix[3],
            matrix[4] + lam,
            matrix[5],
            matrix[6],
            matrix[7],
            matrix[8] + lam,
        ]
        solved = _solve3x3(damped, [-gradient[0], -gradient[1], -gradient[2]])
        if solved is None:
            break
        step = Vec3(solved[0], solved[1], solved[2])
        if step.length < 1e-9:
            break

        candidate = _apply_world_rotation(rotation, step)
        updated = _mean_residual(candidate, world_rays, correspondences, frame_projection)
        if updated > residual + 1e-9:
            break

        rotation = candidate
        accepted_delta = accepted_delta + step
        residual = updated

    correction_deg = accepted_delta.length * 180 / math.pi
    if correction_deg > MAX_CORRECTION_DEG:
        return refused(
            correction_deg,
            before,
            residual,
            f"The matches would rotate this frame by {correction_deg:.1f}°, too far "
            "from the sensor estimate to be a refinement.",
        )
    if residual > MAX_RESIDUAL_PX:
        return refused(
            correction_deg,
            before,
            residual,
            f"The matches still disagree by {residual:.1f} px after correction.",
        )
    if residual > before and before > 0:
        return refused(
            0.0,
            before,
            before,
            f"Correcting this frame made the alignment worse "
            f"({before:.1f} px → {residual:.1f} px).",
        )
    if correction_deg < 0.01:
        return refused(
            0.0,
            before,
            residual,
            "The sensor estimate was already correct to within 0.01°.",
        )

    return SphereEdgeRefinement(
        correction=_apply_world_rotation(Quat.identity(), accepted_delta),
        correction_deg=correction_deg,
        inliers=len(correspondences),
        inlier_ratio=inlier_ratio,
        residual_before_px=before,
        residual_after_px=residual,
        accepted=True,
        rejection=None,
    )


def merge_sphere_corrections(refinements: list[SphereEdgeRefinement]) -> Quat | None:
    """Weighted mean of the accepted proposals, shrunk when they disagree."""
    accepted = [r for r in refinements if r.accepted and r.correction_deg > 0]
    if not accepted:
        return None

    vectors: list[Vec3] = []
    weights: list[float] = []
    weight_sum = 0.0
    for r in accepted:
        weight = r.inliers * r.inlier_ratio
        if weight <= 0:
            continue
        vectors.append(_axis_angle_vector(r.correction, r.correction_deg))
        weights.append(weight)
        weight_sum += weight
    if weight_sum <= 0:
        return None

    mean = Vec3.zero()
    for v, w in zip(vectors, weights):
        mean = mean + v * w
    mean = mean * (1 / weight_sum)
    if mean.length <= 1e-9:
        return None

    deviation = 0.0
    for v, w in zip(vectors, weights):
        deviation += w * (v - mean).length
    deviation /= weight_sum

    shrunk = mean * 0.5 if deviation > 0.5 * mean.length else mean
    degrees = shrunk.length * 180 / math.pi
    if degrees < 0.01:
        return None
    return _apply_world_rotation(Quat.identity(), shrunk)
