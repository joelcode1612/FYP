"""Longitude/latitude interval a frame can contribute to, in radians.

Faithful port of ``lib/features/sphere_capture/domain/equirect_bounds.dart``.

Samples are unwrapped around the frame's own centre longitude before min/max,
so a frame crossing ±180° keeps ``min_lon <= max_lon`` and the caller wraps the
column range with ``% width``. Frames that contain a pole cover every longitude
and are marked full-width.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .sphere_math import Quat, Vec3

TWO_PI = 6.283185307179586
HALF_PI = 1.5707963267948966


@dataclass(frozen=True, slots=True)
class FrameBounds:
    min_lon: float
    max_lon: float
    min_lat: float
    max_lat: float
    full_width: bool


def _unwrap(angle: float, centre: float) -> float:
    value = angle
    while value - centre > math.pi:
        value -= TWO_PI
    while value - centre < -math.pi:
        value += TWO_PI
    return value


def equirect_frame_bounds(
    camera_to_sphere: Quat,
    width: int,
    height: int,
    focal: float,
    cx: float,
    cy: float,
) -> FrameBounds:
    axis = camera_to_sphere.rotate(Vec3(0.0, 0.0, -1.0))
    centre_lon = math.atan2(axis.x, -axis.z)

    min_lon = math.inf
    max_lon = -math.inf
    min_lat = HALF_PI
    max_lat = -HALF_PI

    for i in range(9):
        t = i / 8
        samples = (
            (t * (width - 1), 0.0),
            (t * (width - 1), float(height - 1)),
            (0.0, t * (height - 1)),
            (float(width - 1), t * (height - 1)),
        )
        for u, v in samples:
            cam = Vec3((u - cx) / focal, -(v - cy) / focal, -1.0).normalized
            direction = camera_to_sphere.rotate(cam)
            lon = _unwrap(math.atan2(direction.x, -direction.z), centre_lon)
            lat = math.asin(min(1.0, max(-1.0, direction.y)))
            min_lon = min(min_lon, lon)
            max_lon = max(max_lon, lon)
            min_lat = min(min_lat, lat)
            max_lat = max(max_lat, lat)

    def contains_pole(world: Vec3) -> bool:
        cam = camera_to_sphere.conjugate.rotate(world)
        depth = -cam.z
        if depth <= 0.05:
            return False
        half_w = (width / 2) / focal
        half_h = (height / 2) / focal
        return abs(cam.x / depth) <= half_w and abs(cam.y / depth) <= half_h

    if contains_pole(Vec3(0.0, 1.0, 0.0)):
        max_lat = HALF_PI
    if contains_pole(Vec3(0.0, -1.0, 0.0)):
        min_lat = -HALF_PI

    full_width = (
        max_lat >= HALF_PI or min_lat <= -HALF_PI or (max_lon - min_lon) >= TWO_PI - 0.05
    )

    margin = 0.035
    return FrameBounds(
        min_lon=min_lon - margin,
        max_lon=max_lon + margin,
        min_lat=min(max(min_lat - margin, -HALF_PI), HALF_PI),
        max_lat=min(max(max_lat + margin, -HALF_PI), HALF_PI),
        full_width=full_width,
    )
