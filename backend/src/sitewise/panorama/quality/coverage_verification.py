"""Whole-panorama coverage verification.

The stitcher black-fills directions no photograph covered. This verifier
turns that fill into evidence: the overall content fraction, per-band
coverage (which catches a locally large hole even when the global fraction
passes) and connected-hole detection. Run after a stitch — worker thread in
the ``device_38`` workflow, or synchronously at panorama confirmation in the
device-panorama workflow, where it analyses a single downscaled image.
"""

from __future__ import annotations

import logging

import cv2
import numpy as np

from sitewise.panorama.quality.report import QualityFinding, QualityReport
from sitewise.panorama.quality.thresholds import PanoramaQualityThresholds

logger = logging.getLogger("sitewise.panorama.quality")

CHECK = "coverage"


def _load_panorama(data: bytes, max_width: int) -> np.ndarray | None:
    decoded = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
    if decoded is None:
        return None
    height, width = decoded.shape[:2]
    if width <= max_width:
        return decoded
    scale = max_width / width
    new_size = (max_width, max(1, int(height * scale)))
    return cv2.resize(decoded, new_size, interpolation=cv2.INTER_AREA)


def verify_panorama_coverage(
    panorama_bytes: bytes,
    thresholds: PanoramaQualityThresholds | None = None,
) -> QualityReport:
    """Verifies that the stitched panorama actually covers the sphere."""
    active = thresholds or PanoramaQualityThresholds()
    report = QualityReport(
        check=CHECK,
        measurements={"thresholds_version": active.version},
    )
    decoded = _load_panorama(panorama_bytes, active.analysis_max_width)
    if decoded is None:
        report.add(
            QualityFinding.error(
                CHECK,
                "panorama_unreadable",
                "The stitched panorama could not be decoded for the "
                "coverage check. The original photographs are kept.",
            )
        )
        return report

    height, width = decoded.shape[:2]
    luma = cv2.cvtColor(decoded, cv2.COLOR_BGR2GRAY).astype(np.float32)
    # The stitcher's unfilled pixels are black; a small tolerance keeps JPEG
    # ringing around genuinely dark content from being misread as holes.
    valid_mask = luma > active.hole_luma_max
    coverage_fraction = float(valid_mask.mean()) if valid_mask.size else 0.0
    report.measurements["coverage_fraction"] = coverage_fraction

    # Per-band coverage: 8 horizontal stripes, each of which must stand on
    # its own. A single band failing marks a locally large hole.
    bands = max(1, active.coverage_bands)
    band_height = max(1, height // bands)
    band_fractions: list[float] = []
    for band in range(bands):
        top = band * band_height
        bottom = height if band == bands - 1 else min(height, (band + 1) * band_height)
        strip = valid_mask[top:bottom]
        band_fractions.append(float(strip.mean()) if strip.size else 0.0)
    report.measurements["band_coverage_fractions"] = band_fractions

    # Connected invalid regions larger than the threshold are real holes.
    invalid_u8 = (~valid_mask).astype(np.uint8)
    label_count, labels, _stats, _centroids = cv2.connectedComponentsWithStats(
        invalid_u8, connectivity=8
    )
    total_pixels = float(height * width)
    holes: list[dict[str, float]] = []
    for label in range(1, label_count):
        area = float(_stats[label, cv2.CC_STAT_AREA])
        if total_pixels <= 0 or area / total_pixels < active.max_hole_area_fraction:
            continue
        holes.append(
            {
                "x": float(_stats[label, cv2.CC_STAT_LEFT]),
                "y": float(_stats[label, cv2.CC_STAT_TOP]),
                "width": float(_stats[label, cv2.CC_STAT_WIDTH]),
                "height": float(_stats[label, cv2.CC_STAT_HEIGHT]),
                "area_fraction": area / total_pixels,
            }
        )
    report.measurements["holes"] = holes

    if coverage_fraction < active.min_coverage_fraction:
        report.add(
            QualityFinding.warning(
                CHECK,
                "coverage_low",
                f"The panorama covers {coverage_fraction * 100:.1f}% of the "
                "sphere; some directions were not photographed. Retake the "
                "missing targets if the tour should show them.",
                coverage_fraction=coverage_fraction,
            )
        )
    for band, fraction in enumerate(band_fractions):
        if fraction < active.min_band_coverage_fraction:
            report.add(
                QualityFinding.warning(
                    CHECK,
                    "band_gap",
                    f"Horizontal band {band + 1}/{bands} of the panorama is "
                    f"only {fraction * 100:.1f}% filled — a hole in that "
                    "elevation. Retaking the surrounding targets would "
                    "close it.",
                    band=float(band + 1),
                    coverage_fraction=fraction,
                )
            )
    for hole in holes:
        report.add(
            QualityFinding.warning(
                CHECK,
                "hole_detected",
                "A hole of "
                f"{hole['area_fraction'] * 100:.2f}% of the panorama was "
                "found near the marked region. The frame is kept; retake "
                "the direction to fill it.",
                x=hole["x"],
                y=hole["y"],
                width=hole["width"],
                height=hole["height"],
                area_fraction=hole["area_fraction"],
            )
        )
    return report
