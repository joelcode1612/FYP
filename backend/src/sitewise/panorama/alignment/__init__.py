"""Global spherical image alignment for SiteWise 360° panoramas.

This package replaces ring-by-ring stitching with one joint solution:

* :mod:`camera` — the pinhole camera model, spherical footprints and the
  equal-area sampling grid every coverage figure is measured on.
* :mod:`features` — SIFT extraction with an on-disk descriptor cache.
* :mod:`matching` — Lowe ratio, mutual filter, RANSAC, calibrated relative
  rotation and the reprojection statistics that decide an edge's state.
* :mod:`pairs` — orientation-guided candidate pairs, including the cross-ring
  pairs vertical alignment depends on.
* :mod:`graph` — the image graph, its connectivity and its weak regions.
* :mod:`global_rotation` — robust joint optimisation of every camera rotation.
* :mod:`coverage` — single/double coverage, uncovered regions, hemisphere and
  pole coverage, measured from projected footprints rather than target counts.
* :mod:`session` — the orchestration used by the worker and the incremental
  capture endpoint.

Nothing here invents a match: an edge is only ``strong`` when a calibrated
rotation model explains the correspondences with enough inliers spread across
the frame. Weak regions are reported as weak.
"""

from __future__ import annotations

from .camera import (
    RING_ADJACENCY,
    RING_LOWER,
    RING_MIDDLE,
    RING_ORDER,
    RING_POLAR_LOWER,
    RING_POLAR_UPPER,
    RING_UPPER,
    EqualAreaGrid,
    PinholeCamera,
    angular_gap_deg,
    coverage_grid,
    footprint_directions,
    frame_pitch_yaw,
    frame_ring,
    frame_visible,
    rotation_matrix,
    yaw_difference_deg,
)
from .coverage import (
    CoverageRegion,
    CoverageReport,
    FrameFootprint,
    measure_coverage,
    suggest_extra_directions,
)
from .features import (
    DESCRIPTOR_ORB,
    DESCRIPTOR_SIFT,
    FeatureSet,
    clear_feature_cache,
    extract_features,
    extract_orb_features,
    extract_sift_features,
)
from .global_rotation import GlobalAlignment, align_global_rotations, exp_rotation, log_rotation
from .graph import GraphEdge, ImageGraph, build_graph
from .matching import (
    DEFAULT_THRESHOLDS,
    STATE_FAILED,
    STATE_INSUFFICIENT,
    STATE_STRONG,
    STATE_WEAK,
    MatchThresholds,
    MatchVerdict,
    PairMatcher,
    matching_camera,
    verify_pair,
    verify_pair_cascaded,
)
from .pairs import CandidatePair, PairFrame, candidate_pairs, pairs_for_frame
from .session import (
    FrameAlignmentInput,
    IncrementalMatchResult,
    SessionAlignment,
    align_session,
    evaluate_completion,
    match_new_frame,
    session_summary,
)

__all__ = [
    "CandidatePair",
    "CoverageRegion",
    "CoverageReport",
    "DEFAULT_THRESHOLDS",
    "EqualAreaGrid",
    "FeatureSet",
    "FrameAlignmentInput",
    "FrameFootprint",
    "GlobalAlignment",
    "GraphEdge",
    "ImageGraph",
    "IncrementalMatchResult",
    "MatchThresholds",
    "MatchVerdict",
    "PairFrame",
    "PairMatcher",
    "PinholeCamera",
    "RING_ADJACENCY",
    "RING_LOWER",
    "RING_MIDDLE",
    "RING_ORDER",
    "RING_POLAR_LOWER",
    "RING_POLAR_UPPER",
    "RING_UPPER",
    "STATE_FAILED",
    "STATE_INSUFFICIENT",
    "STATE_STRONG",
    "STATE_WEAK",
    "SessionAlignment",
    "align_global_rotations",
    "align_session",
    "angular_gap_deg",
    "build_graph",
    "candidate_pairs",
    "clear_feature_cache",
    "coverage_grid",
    "evaluate_completion",
    "exp_rotation",
    "extract_features",
    "extract_orb_features",
    "extract_sift_features",
    "footprint_directions",
    "frame_pitch_yaw",
    "frame_ring",
    "frame_visible",
    "log_rotation",
    "match_new_frame",
    "matching_camera",
    "measure_coverage",
    "pairs_for_frame",
    "rotation_matrix",
    "session_summary",
    "suggest_extra_directions",
    "verify_pair",
    "verify_pair_cascaded",
    "yaw_difference_deg",
]
