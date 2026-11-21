"""Server-side panorama stitching port (Dart → Python/OpenCV).

The maths mirrors ``lib/features/sphere_capture`` in the capture reference
repo one file at a time; the entry point is :func:`stitcher.stitch_equirectangular`.
"""

from .frame_registration import (
    SphereRegistrationFrame,
    SphereRegistrationOutcome,
    SphereResidualAffine,
    register_sphere_frames,
)
from .graph_cut_seams import find_seam_labels, seam_cut_graph_bytes
from .seam_blend import SeamBlendStats, composite_seams
from .sphere_intrinsics import DecodedProjection, decoded_projection, focal_from_height
from .sphere_math import Quat, Vec3, sphere_orientation_gap_deg
from .sphere_registration import (
    MAX_CORRECTION_DEG,
    MAX_RESIDUAL_PX,
    MIN_INLIERS,
    MIN_INLIER_RATIO,
    merge_sphere_corrections,
    refine_rotation_from_correspondences,
)
from .stitcher import (
    FrameRecord,
    StitchOutcome,
    ViewportGap,
    fill_uncovered,
    resolve_stitch_width,
    solve_channel_median_gains,
    sphere_stitch_accumulator_bytes,
    stitch_equirectangular,
    worst_viewport_gap,
)

__all__ = [
    "DecodedProjection",
    "FrameRecord",
    "MAX_CORRECTION_DEG",
    "MAX_RESIDUAL_PX",
    "MIN_INLIERS",
    "MIN_INLIER_RATIO",
    "Quat",
    "SeamBlendStats",
    "SphereRegistrationFrame",
    "SphereRegistrationOutcome",
    "SphereResidualAffine",
    "StitchOutcome",
    "Vec3",
    "ViewportGap",
    "composite_seams",
    "decoded_projection",
    "fill_uncovered",
    "find_seam_labels",
    "focal_from_height",
    "merge_sphere_corrections",
    "refine_rotation_from_correspondences",
    "register_sphere_frames",
    "resolve_stitch_width",
    "seam_cut_graph_bytes",
    "sphere_orientation_gap_deg",
    "sphere_stitch_accumulator_bytes",
    "stitch_equirectangular",
    "solve_channel_median_gains",
    "worst_viewport_gap",
]
