"""Pinhole camera model, spherical footprints and the equal-area sampling grid.

## Why footprints rather than target counts

A target is a *direction to point at*. Whether that direction actually covers
the sphere depends on the lens: a 65° vertical field of view at 30° yaw spacing
overlaps far more than a 40° one would. Every coverage and overlap figure in
this package is therefore derived from the projected image footprint, never
from the planned target angles.

## The sampling grid

Coverage is measured on an **equal-area** grid: samples are uniform in
``z = sin(latitude)``, and each band carries ``round(2·sqrt(N_z·π)·sqrt(1−z²))``
longitudes so every sample owns the same solid angle, ``4π/N``. A plain
latitude/longitude raster would over-weight the poles by a factor of
``1/cos(latitude)`` and report a polar hole as far larger than it is.

The grid is deterministic, so two runs over the same photographs produce the
same numbers, and the reported resolution is exact rather than nominal.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from ..sphere_math import DEG_TO_RAD, RAD_TO_DEG, Quat, Vec3

TWO_PI = 6.283185307179586
HALF_PI = 1.5707963267948966

#: Default number of equal-area cells. 12 288 cells put the linear resolution
#: at roughly 1.0° — fine enough that a genuinely missing 5° region cannot hide,
#: coarse enough that 44 footprints cost well under a second.
DEFAULT_GRID_CELLS = 12_288


@dataclass(frozen=True, slots=True)
class PinholeCamera:
    """The intrinsics of one *saved* frame, in that frame's own pixels.

    ``focal`` is in pixels of the image ``width × height`` describes. A centred
    crop keeps the focal length (it is a lens property) and moves the principal
    point; the caller is responsible for passing the values that match the
    image the stitcher will actually decode.
    """

    width: int
    height: int
    focal: float
    cx: float | None = None
    cy: float | None = None

    def __post_init__(self) -> None:
        if self.width <= 0 or self.height <= 0:
            raise ValueError("camera dimensions must be positive")
        if not math.isfinite(self.focal) or self.focal <= 0:
            raise ValueError("camera focal length must be a positive number")

    @property
    def principal_x(self) -> float:
        return self.width / 2.0 if self.cx is None else float(self.cx)

    @property
    def principal_y(self) -> float:
        return self.height / 2.0 if self.cy is None else float(self.cy)

    @property
    def half_width_ratio(self) -> float:
        """``(W/2)/f`` — the tangent of the horizontal half field of view."""
        return (self.width / 2.0) / self.focal

    @property
    def half_height_ratio(self) -> float:
        return (self.height / 2.0) / self.focal

    @property
    def horizontal_fov_deg(self) -> float:
        return 2.0 * math.atan(self.half_width_ratio) * RAD_TO_DEG

    @property
    def vertical_fov_deg(self) -> float:
        return 2.0 * math.atan(self.half_height_ratio) * RAD_TO_DEG

    @property
    def diagonal_fov_deg(self) -> float:
        ratio = math.hypot(self.half_width_ratio, self.half_height_ratio)
        return 2.0 * math.atan(ratio) * RAD_TO_DEG

    @property
    def solid_angle_sr(self) -> float:
        """Exact solid angle of the image rectangle on the unit sphere.

        ``Ω = 4·asin( (w/2·h/2) / sqrt(1 + (w/2)² + (h/2)²) )`` for a centred
        rectangle in tangent coordinates. This is the honest footprint area;
        ``2π(1−cos(fov/2))`` would understate a wide rectangle's corners.
        """
        a = self.half_width_ratio
        b = self.half_height_ratio
        return 4.0 * math.asin((a * b) / math.sqrt(1.0 + a * a + b * b))

    @property
    def sphere_fraction(self) -> float:
        """Fraction of the full 4π sphere one frame covers."""
        return self.solid_angle_sr / (4.0 * math.pi)

    def pixel_to_camera_ray(self, u: float, v: float) -> Vec3:
        """Unit ray in the camera frame for pixel ``(u, v)``.

        Camera frame: ``+X`` screen-right, ``+Y`` screen-up, ``−Z`` forward.
        """
        return Vec3(
            (u - self.principal_x) / self.focal,
            -(v - self.principal_y) / self.focal,
            -1.0,
        ).normalized


def rotation_matrix(quat: Quat) -> np.ndarray:
    """3×3 matrix of ``quat``, matching :meth:`Quat.rotate` exactly."""
    x, y, z, w = quat.x, quat.y, quat.z, quat.w
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ],
        dtype=np.float64,
    )


def footprint_directions(
    camera_to_sphere: Quat,
    camera: PinholeCamera,
    *,
    steps: int = 12,
) -> np.ndarray:
    """Unit directions of an evenly spaced grid over the image rectangle.

    The grid includes the exact border, so the returned set bounds the true
    footprint: no direction inside the image is further from the set than one
    grid cell. Used to draw footprints and to seed adaptive targets.
    """
    steps = max(2, int(steps))
    us = np.linspace(0.0, camera.width - 1.0, steps)
    vs = np.linspace(0.0, camera.height - 1.0, steps)
    grid_u, grid_v = np.meshgrid(us, vs, indexing="xy")
    x = (grid_u - camera.principal_x) / camera.focal
    y = -(grid_v - camera.principal_y) / camera.focal
    rays = np.stack([x.ravel(), y.ravel(), -np.ones(x.size)], axis=1)
    rays /= np.linalg.norm(rays, axis=1, keepdims=True)
    world = rays @ rotation_matrix(camera_to_sphere).T
    return world


@dataclass(frozen=True, slots=True)
class EqualAreaGrid:
    """Deterministic equal-area sampling of the sphere.

    ``directions`` is ``(N, 3)``; every row owns ``4π/N`` steradians, so a
    count of rows is a solid angle without further weighting.
    """

    directions: np.ndarray

    @property
    def cells(self) -> int:
        return int(self.directions.shape[0])

    @property
    def cell_solid_angle(self) -> float:
        return 4.0 * math.pi / self.cells

    @property
    def resolution_deg(self) -> float:
        """Nominal angular resolution: the side of a square of equal area."""
        return math.degrees(math.sqrt(self.cell_solid_angle))

    @property
    def tolerance(self) -> float:
        """Worst-case area error from sampling, as a fraction of the sphere.

        One cell: a region narrower than a cell can be missed entirely, so no
        coverage figure here is ever quoted more precisely than ``1/N``.
        """
        return 1.0 / self.cells


def coverage_grid(cells: int = DEFAULT_GRID_CELLS) -> EqualAreaGrid:
    """Build the equal-area grid with approximately [cells] samples.

    With ``B`` bands the ring sizes sum to ``≈ B²·π/2``, so ``B = sqrt(2N/π)``
    lands on the requested cell count. The count is approximate by design —
    rings must be whole cells — and the report states the exact count it got.
    """
    cells = max(64, int(cells))
    bands = max(4, int(round(math.sqrt(2.0 * cells / math.pi))))
    zs: list[np.ndarray] = []
    phis: list[np.ndarray] = []
    for band in range(bands):
        # Cell centres in z, so the poles are not sampled on their singular point.
        z = -1.0 + (2.0 * band + 1.0) / bands
        ring = max(1, int(round(2.0 * bands * math.sqrt(max(0.0, 1.0 - z * z)))))
        phi = (np.arange(ring, dtype=np.float64) + 0.5) * (TWO_PI / ring)
        zs.append(np.full(ring, z, dtype=np.float64))
        phis.append(phi)
    z_all = np.concatenate(zs)
    phi_all = np.concatenate(phis)
    radial = np.sqrt(np.maximum(0.0, 1.0 - z_all * z_all))
    directions = np.stack(
        [radial * np.cos(phi_all), z_all, radial * np.sin(phi_all)], axis=1
    )
    return EqualAreaGrid(directions=directions)


def frame_pitch_yaw(camera_to_sphere: Quat) -> tuple[float, float]:
    """``(pitch_deg, yaw_deg)`` of the optical axis, in the session frame.

    ``pitch`` is elevation: ``+90`` looks at the ceiling, ``−90`` at the floor.
    ``yaw`` grows to the photographer's right, matching the mobile target map
    (``x = sin(yaw)cos(pitch)``, ``z = −cos(yaw)cos(pitch)``).
    """
    axis = camera_to_sphere.rotate(Vec3(0.0, 0.0, -1.0))
    pitch = math.asin(max(-1.0, min(1.0, axis.y))) * RAD_TO_DEG
    yaw = math.atan2(axis.x, -axis.z) * RAD_TO_DEG
    return pitch, yaw


#: Ring classification thresholds, in degrees of elevation.
RING_POLAR_UPPER = "upper_polar"
RING_UPPER = "upper"
RING_MIDDLE = "middle"
RING_LOWER = "lower"
RING_POLAR_LOWER = "lower_polar"

RING_ORDER = (
    RING_POLAR_UPPER,
    RING_UPPER,
    RING_MIDDLE,
    RING_LOWER,
    RING_POLAR_LOWER,
)

#: Each ring's neighbour, used to guarantee cross-ring candidate coverage.
RING_ADJACENCY = {
    RING_POLAR_UPPER: (RING_UPPER,),
    RING_UPPER: (RING_POLAR_UPPER, RING_MIDDLE),
    RING_MIDDLE: (RING_UPPER, RING_LOWER),
    RING_LOWER: (RING_MIDDLE, RING_POLAR_LOWER),
    RING_POLAR_LOWER: (RING_LOWER,),
}


def frame_ring(pitch_deg: float) -> str:
    """Classify an elevation into one of the five capture rings."""
    if pitch_deg >= 50.0:
        return RING_POLAR_UPPER
    if pitch_deg >= 15.0:
        return RING_UPPER
    if pitch_deg > -15.0:
        return RING_MIDDLE
    if pitch_deg > -50.0:
        return RING_LOWER
    return RING_POLAR_LOWER


def frame_visible(
    camera_to_sphere: Quat, camera: PinholeCamera, directions: np.ndarray
) -> np.ndarray:
    """Boolean mask of [directions] that project inside [camera]'s image.

    Vectorised over the whole grid: the world directions are rotated into the
    camera frame once, then the pinhole test is applied to all of them.
    """
    inverse = rotation_matrix(camera_to_sphere).T
    cam = directions @ inverse.T
    depth = -cam[:, 2]
    visible = depth > 1e-6
    if not np.any(visible):
        return visible
    safe_depth = np.where(visible, depth, 1.0)
    u = cam[:, 0] / safe_depth
    v = cam[:, 1] / safe_depth
    visible &= np.abs(u) <= camera.half_width_ratio
    visible &= np.abs(v) <= camera.half_height_ratio
    return visible


def angular_gap_deg(a: Quat, b: Quat) -> float:
    """Angle between two optical axes, in degrees."""
    va = a.rotate(Vec3(0.0, 0.0, -1.0))
    vb = b.rotate(Vec3(0.0, 0.0, -1.0))
    dot = max(-1.0, min(1.0, va.dot(vb)))
    return math.acos(dot) * RAD_TO_DEG


def yaw_difference_deg(a: float, b: float) -> float:
    """Signed shortest yaw difference ``a − b`` in ``(−180, 180]``."""
    delta = (a - b + 180.0) % 360.0 - 180.0
    return delta


__all__ = [
    "DEFAULT_GRID_CELLS",
    "EqualAreaGrid",
    "PinholeCamera",
    "RING_ADJACENCY",
    "RING_LOWER",
    "RING_MIDDLE",
    "RING_ORDER",
    "RING_POLAR_LOWER",
    "RING_POLAR_UPPER",
    "RING_UPPER",
    "angular_gap_deg",
    "coverage_grid",
    "footprint_directions",
    "frame_pitch_yaw",
    "frame_ring",
    "frame_visible",
    "rotation_matrix",
    "yaw_difference_deg",
]
