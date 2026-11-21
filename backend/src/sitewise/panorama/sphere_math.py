"""Pure quaternion / vector maths for the 38-target sphere stitcher.

Faithful port of the Dart reference implementation:

- ``lib/features/virtual_tour/domain/math/quaternions.dart``
- ``lib/features/virtual_tour/domain/math/vectors.dart``

World convention (identical in every ported file): right-handed, ``+Y`` up.
A pose quaternion maps the canonical axes to the world: ``R·x̂`` is the
camera's right, ``R·ŷ`` its up, ``R·ẑ`` its optical axis (forward). The
camera *view* frame used by the projection is the physical one — ``+X``
screen-right, ``+Y`` screen-up, ``−Z`` forward — reached through the
``to_camera_frame`` flip recorded in the Dart source.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

DEG_TO_RAD = math.pi / 180.0
RAD_TO_DEG = 180.0 / math.pi


@dataclass(frozen=True, slots=True)
class Vec3:
    x: float
    y: float
    z: float

    @staticmethod
    def zero() -> "Vec3":
        return Vec3(0.0, 0.0, 0.0)

    def __add__(self, o: "Vec3") -> "Vec3":
        return Vec3(self.x + o.x, self.y + o.y, self.z + o.z)

    def __sub__(self, o: "Vec3") -> "Vec3":
        return Vec3(self.x - o.x, self.y - o.y, self.z - o.z)

    def __mul__(self, s: float) -> "Vec3":
        return Vec3(self.x * s, self.y * s, self.z * s)

    def dot(self, o: "Vec3") -> float:
        return self.x * o.x + self.y * o.y + self.z * o.z

    def cross(self, o: "Vec3") -> "Vec3":
        return Vec3(
            self.y * o.z - self.z * o.y,
            self.z * o.x - self.x * o.z,
            self.x * o.y - self.y * o.x,
        )

    @property
    def length(self) -> float:
        return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z)

    @property
    def normalized(self) -> "Vec3":
        l = self.length
        return Vec3(0.0, 0.0, 0.0) if l == 0 else Vec3(self.x / l, self.y / l, self.z / l)


UNIT_X = Vec3(1.0, 0.0, 0.0)
UNIT_Y = Vec3(0.0, 1.0, 0.0)
UNIT_Z = Vec3(0.0, 0.0, 1.0)


@dataclass(frozen=True, slots=True)
class Quat:
    """Immutable unit quaternion, Hamilton product, stored ``(x, y, z, w)``."""

    x: float
    y: float
    z: float
    w: float

    @staticmethod
    def identity() -> "Quat":
        return Quat(0.0, 0.0, 0.0, 1.0)

    def __mul__(self, o: "Quat") -> "Quat":
        """Hamilton product. ``this * o`` applies ``o`` first, then ``this``."""
        return Quat(
            self.w * o.x + self.x * o.w + self.y * o.z - self.z * o.y,
            self.w * o.y - self.x * o.z + self.y * o.w + self.z * o.x,
            self.w * o.z + self.x * o.y - self.y * o.x + self.z * o.w,
            self.w * o.w - self.x * o.x - self.y * o.y - self.z * o.z,
        )

    @property
    def conjugate(self) -> "Quat":
        return Quat(-self.x, -self.y, -self.z, self.w)

    def dot(self, o: "Quat") -> float:
        return self.x * o.x + self.y * o.y + self.z * o.z + self.w * o.w

    @property
    def length(self) -> float:
        return math.sqrt(
            self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w
        )

    @property
    def normalized(self) -> "Quat":
        l = self.length
        return Quat.identity() if l == 0 else Quat(self.x / l, self.y / l, self.z / l, self.w / l)

    @staticmethod
    def axis_angle(angle_deg: float, axis: Vec3) -> "Quat":
        """Rotation of ``angle_deg`` about ``axis`` (need not be normalised)."""
        h = angle_deg * DEG_TO_RAD / 2
        s = math.sin(h)
        l = axis.length
        k = 1.0 if l == 0 else l
        return Quat(axis.x / k * s, axis.y / k * s, axis.z / k * s, math.cos(h))

    def rotate(self, v: Vec3) -> Vec3:
        """Rotates a world vector: ``v + 2w(u×v) + 2u×(u×v)``."""
        u = Vec3(self.x, self.y, self.z)
        c = u.cross(v)
        cc = u.cross(c)
        return Vec3(
            v.x + 2 * (self.w * c.x + cc.x),
            v.y + 2 * (self.w * c.y + cc.y),
            v.z + 2 * (self.w * c.z + cc.z),
        )

    @staticmethod
    def from_list(values: list[float]) -> "Quat":
        return Quat(values[0], values[1], values[2], values[3])

    def to_list(self) -> list[float]:
        return [self.x, self.y, self.z, self.w]


def sphere_orientation_gap_deg(a: Quat, b: Quat) -> float:
    """Angle in degrees between two camera orientations."""
    dot = min(1.0, max(0.0, abs((a.conjugate * b).w)))
    return 2 * math.acos(dot) * RAD_TO_DEG
