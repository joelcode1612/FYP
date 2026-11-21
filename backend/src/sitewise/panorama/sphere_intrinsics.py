"""Camera-intrinsics transformation for the 38-target sphere flow.

Faithful port of ``lib/features/sphere_capture/domain/sphere_intrinsics.dart``.

A photograph passes through three coordinate systems before the stitcher
samples it: source (uncropped frame), saved (after the centred 3:4 crop) and
decoded (what ``cv.imread`` returns at a reduced scale). The pinhole focal
length is a property of the lens, computed once on the *source* frame and then
multiplied by the decode scale; the principal point follows the recorded crop
offsets. Getting this wrong overstates the focal 4× on quarter-scale decodes
and collapses every frame's angular footprint.
"""

from __future__ import annotations

import math
from dataclasses import dataclass


def focal_from_height(image_height: float, vertical_fov_deg: float) -> float:
    if image_height <= 0:
        raise ValueError("imageHeight must be positive")
    return (image_height / 2) / math.tan(vertical_fov_deg * math.pi / 360)


def horizontal_fov_from_pixels(width_px: float, focal_px: float) -> float:
    if focal_px <= 0:
        raise ValueError("focalPx must be positive")
    return 2 * math.atan(width_px / 2 / focal_px) * 180 / math.pi


def vertical_fov_from_pixels(height_px: float, focal_px: float) -> float:
    if focal_px <= 0:
        raise ValueError("focalPx must be positive")
    return 2 * math.atan(height_px / 2 / focal_px) * 180 / math.pi


@dataclass(frozen=True, slots=True)
class DecodedProjection:
    """Projection parameters for one decoded frame, ready for the stitcher."""

    focal_px: float
    cx: float
    cy: float
    width: int
    height: int
    horizontal_fov_deg: float
    vertical_fov_deg: float
    decode_scale: float


def decoded_projection(
    *,
    decoded_width: int,
    decoded_height: int,
    saved_width: int,
    saved_height: int,
    source_width: int,
    source_height: int,
    vertical_fov_deg: float,
    crop_offset_x: int = 0,
    crop_offset_y: int = 0,
) -> DecodedProjection | None:
    """Transforms the assumed lens through source → crop → decode."""
    if decoded_width <= 0 or decoded_height <= 0:
        return None
    if vertical_fov_deg <= 0 or vertical_fov_deg >= 180:
        return None

    eff_source_h = (
        source_height
        if source_height > 0
        else (saved_height if saved_height > 0 else decoded_height)
    )
    eff_source_w = (
        source_width
        if source_width > 0
        else (saved_width if saved_width > 0 else decoded_width)
    )
    eff_saved_h = saved_height if saved_height > 0 else decoded_height

    focal_source = focal_from_height(float(eff_source_h), vertical_fov_deg)
    scale = decoded_height / eff_saved_h
    focal = focal_source * scale

    cx = (eff_source_w / 2 - crop_offset_x) * scale
    cy = (eff_source_h / 2 - crop_offset_y) * scale

    return DecodedProjection(
        focal_px=focal,
        cx=cx,
        cy=cy,
        width=decoded_width,
        height=decoded_height,
        horizontal_fov_deg=horizontal_fov_from_pixels(float(decoded_width), focal),
        vertical_fov_deg=vertical_fov_from_pixels(float(decoded_height), focal),
        decode_scale=scale,
    )
