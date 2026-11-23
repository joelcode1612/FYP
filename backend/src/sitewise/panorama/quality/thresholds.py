"""Configurable thresholds for the backend capture-quality checks.

Every number a verifier compares against lives here as a named field with an
evidence-backed default, overridable through the ``SITEWISE_PQ_*``
environment variables so a deployment can tighten or relax the checks
without a code change. Nothing in the verifiers hard-codes a threshold.

Defaults are set to warn on genuinely wrong captures while never rejecting
valid content:

* Low-texture walls and plain ceilings produce few ORB features; the
  registration check reports "insufficient features" as INFORMATIONAL below
  a generous floor instead of warning on every plain surface.
* Coverage and seam limits tolerate a well-blended 2:1 equirect from the
  documented 38-target layout; only pathological holes or hard unblended
  seam lines trip them.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, fields


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        return int(raw)
    except ValueError:
        return default


@dataclass(frozen=True, slots=True)
class PanoramaQualityThresholds:
    """Thresholds shared by the registration, coverage and seam verifiers."""

    # ── Registration / geometric consistency (per adjacent pair) ──────────
    #: Fewer ratio-test-accepted matches than this and the pair is judged to
    #: have too little shared content to verify — informational, because a
    #: legitimately featureless wall produces the same signature.
    min_matches: int = 30
    #: ORB features requested per frame. 1500 matches the device-side probe.
    orb_features: int = 1500
    #: Lowe ratio test factor (canonical 0.75, same as the device probe and
    #: the stitcher's own registration).
    match_ratio: float = 0.75
    #: RANSAC inlier ratio below which a pair is geometrically INCONSISTENT
    #: (warning). Random-correspondence noise lands far below 0.25.
    min_inlier_ratio: float = 0.25
    #: RANSAC reprojection threshold, in analysis pixels (analysis frames are
    #: downscaled to ``analysis_max_width``).
    ransac_reproj_px: float = 6.0
    #: Median reprojection residual (px) above which the fit is called loose.
    max_median_residual_px: float = 2.0
    #: p95 reprojection residual (px) above which the fit is called loose.
    max_p95_residual_px: float = 6.0
    #: Estimated overlap fraction between neighbours below which the pair is
    #: flagged as possibly insufficiently overlapping (advisory).
    min_overlap_fraction: float = 0.15
    #: Downscale bound for verification decodes. 1024 px retains registration
    #: accuracy at a fraction of the full-resolution cost.
    analysis_max_width: int = 1024

    # ── Whole-panorama coverage ───────────────────────────────────────────
    #: Fraction of the equirect that must hold real image content. The
    #: stitcher black-fills unphotographed directions; anything above the
    #: threshold means the capture genuinely covered the sphere.
    min_coverage_fraction: float = 0.98
    #: Per-band (horizontal stripe) coverage floor — catches a hole that is
    #: locally large even when the global fraction passes.
    min_band_coverage_fraction: float = 0.90
    #: Number of horizontal bands analysed.
    coverage_bands: int = 8
    #: A connected invalid region larger than this fraction of the panorama
    #: is reported as a hole.
    max_hole_area_fraction: float = 0.005
    #: Luma at or below which a pixel counts as unfilled (the stitcher's
    #: black fill).
    hole_luma_max: float = 8.0

    # ── Visible seam quality ──────────────────────────────────────────────
    #: Vertical luminance step (0–255) a column must exceed, in a sustained
    #: run, to count as part of a hard seam. Blended seams stay well below.
    seam_step_threshold: float = 24.0
    #: Fraction of rows sharing a step at one column that marks a hard
    #: vertical seam.
    seam_row_fraction: float = 0.55
    #: Global p95 adjacent-column step above which blending is called rough.
    max_step_p95: float = 30.0

    @property
    def version(self) -> str:
        """Stable identity of the active threshold values."""
        values = ",".join(
            f"{f.name}={getattr(self, f.name)!r}" for f in fields(self)
        )
        return f"panorama-quality-thresholds/1/{values}"

    @classmethod
    def from_env(cls) -> "PanoramaQualityThresholds":
        """Builds a threshold set from ``SITEWISE_PQ_*`` env overrides."""
        return cls(
            min_matches=_env_int("SITEWISE_PQ_MIN_MATCHES", cls.min_matches),
            orb_features=_env_int("SITEWISE_PQ_ORB_FEATURES", cls.orb_features),
            match_ratio=_env_float("SITEWISE_PQ_MATCH_RATIO", cls.match_ratio),
            min_inlier_ratio=_env_float(
                "SITEWISE_PQ_MIN_INLIER_RATIO", cls.min_inlier_ratio
            ),
            ransac_reproj_px=_env_float(
                "SITEWISE_PQ_RANSAC_REPROJ_PX", cls.ransac_reproj_px
            ),
            max_median_residual_px=_env_float(
                "SITEWISE_PQ_MAX_MEDIAN_RESIDUAL_PX", cls.max_median_residual_px
            ),
            max_p95_residual_px=_env_float(
                "SITEWISE_PQ_MAX_P95_RESIDUAL_PX", cls.max_p95_residual_px
            ),
            min_overlap_fraction=_env_float(
                "SITEWISE_PQ_MIN_OVERLAP_FRACTION", cls.min_overlap_fraction
            ),
            analysis_max_width=_env_int(
                "SITEWISE_PQ_ANALYSIS_MAX_WIDTH", cls.analysis_max_width
            ),
            min_coverage_fraction=_env_float(
                "SITEWISE_PQ_MIN_COVERAGE_FRACTION", cls.min_coverage_fraction
            ),
            min_band_coverage_fraction=_env_float(
                "SITEWISE_PQ_MIN_BAND_COVERAGE_FRACTION",
                cls.min_band_coverage_fraction,
            ),
            coverage_bands=_env_int(
                "SITEWISE_PQ_COVERAGE_BANDS", cls.coverage_bands
            ),
            max_hole_area_fraction=_env_float(
                "SITEWISE_PQ_MAX_HOLE_AREA_FRACTION", cls.max_hole_area_fraction
            ),
            hole_luma_max=_env_float("SITEWISE_PQ_HOLE_LUMA_MAX", cls.hole_luma_max),
            seam_step_threshold=_env_float(
                "SITEWISE_PQ_SEAM_STEP_THRESHOLD", cls.seam_step_threshold
            ),
            seam_row_fraction=_env_float(
                "SITEWISE_PQ_SEAM_ROW_FRACTION", cls.seam_row_fraction
            ),
            max_step_p95=_env_float("SITEWISE_PQ_MAX_STEP_P95", cls.max_step_p95),
        )
