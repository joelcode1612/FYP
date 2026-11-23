"""Visible seam-quality verification for a stitched panorama.

A hard seam — a column where nearly every row shows the same luminance jump
— is the visible signature of unblended frame boundaries. This verifier
measures adjacent-column (and adjacent-row) luminance steps on a downscaled
equirect, then reports:

* the share of rows that step at the worst column (a sustained vertical
  line is a seam; texture noise is not, because the steps do not align),
* the global p95 step, which catches generally rough blending.

Both thresholds live in :mod:`thresholds` and are env-overridable. Findings
are advisory evidence for review; nothing is re-stitched or altered.
"""

from __future__ import annotations

import logging

import cv2
import numpy as np

from sitewise.panorama.quality.report import QualityFinding, QualityReport
from sitewise.panorama.quality.thresholds import PanoramaQualityThresholds

logger = logging.getLogger("sitewise.panorama.quality")

CHECK = "seam_quality"


def verify_panorama_seams(
    panorama_bytes: bytes,
    thresholds: PanoramaQualityThresholds | None = None,
) -> QualityReport:
    """Measures visible seam quality on the stitched panorama."""
    active = thresholds or PanoramaQualityThresholds()
    report = QualityReport(
        check=CHECK,
        measurements={"thresholds_version": active.version},
    )
    decoded = cv2.imdecode(
        np.frombuffer(panorama_bytes, dtype=np.uint8), cv2.IMREAD_COLOR
    )
    if decoded is None:
        report.add(
            QualityFinding.error(
                CHECK,
                "panorama_unreadable",
                "The stitched panorama could not be decoded for the seam "
                "check. The original photographs are kept.",
            )
        )
        return report
    height, width = decoded.shape[:2]
    if width > active.analysis_max_width:
        scale = active.analysis_max_width / width
        decoded = cv2.resize(
            decoded,
            (active.analysis_max_width, max(1, int(height * scale))),
            interpolation=cv2.INTER_AREA,
        )
    height, width = decoded.shape[:2]
    luma = cv2.cvtColor(decoded, cv2.COLOR_BGR2GRAY).astype(np.float32)

    # Adjacent-column step per pixel, then how many rows carry a step beyond
    # the threshold at each column. A hard seam aligns across many rows;
    # ordinary texture does not.
    column_steps = np.abs(np.diff(luma, axis=1))
    step_mask = column_steps > active.seam_step_threshold
    row_fraction_per_column = (
        step_mask.mean(axis=0) if step_mask.size else np.zeros((1,))
    )
    worst_column = int(np.argmax(row_fraction_per_column))
    worst_fraction = float(row_fraction_per_column[worst_column])
    step_p95 = float(np.percentile(column_steps, 95)) if column_steps.size else 0.0
    report.measurements.update(
        {
            "worst_column_fraction": worst_fraction,
            "worst_column_x": float(worst_column),
            "step_p95": step_p95,
            "width": float(width),
        }
    )

    # Ring-boundary rows: the same test along y for horizontal frame joins.
    row_steps = np.abs(np.diff(luma, axis=0))
    row_step_p95 = float(np.percentile(row_steps, 95)) if row_steps.size else 0.0
    report.measurements["row_step_p95"] = row_step_p95

    if worst_fraction >= active.seam_row_fraction:
        report.add(
            QualityFinding.warning(
                CHECK,
                "vertical_seam",
                "A visible vertical seam was detected in the panorama "
                f"(share of affected rows: {worst_fraction * 100:.0f}%). The "
                "tour is usable; retaking the neighbouring photographs and "
                "re-stitching would soften it.",
                column_fraction=worst_fraction,
                column_x=float(worst_column),
            )
        )
    if step_p95 > active.max_step_p95:
        report.add(
            QualityFinding.warning(
                CHECK,
                "rough_blending",
                "Luminance steps across the panorama are larger than a "
                "well-blended stitch produces. The tour is usable; the "
                "seams may be visible in bright areas.",
                step_p95=step_p95,
            )
        )
    return report
