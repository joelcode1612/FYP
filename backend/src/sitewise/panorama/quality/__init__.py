"""Capture-quality verification for the canonical 360° pipeline.

Everything in this package is *verification only*: it measures evidence and
reports findings. It never deletes a frame, never rewrites a photograph,
never repeats a stitch, and never gates a canonical row on its own — the
results are stored as additive JSON inside ``fyp.panoramas.coverage_report``
under a ``quality`` key, next to the stitcher's own coverage evidence.

Layout:

* :mod:`thresholds` — configurable, evidence-based thresholds (env-overridable).
* :mod:`report` — finding/report models shared by every verifier.
* :mod:`registration_verification` — pairwise ORB/RANSAC registration and
  geometric-consistency verification over the confirmed originals
  (computationally expensive — worker thread only).
* :mod:`coverage_verification` — whole-panorama coverage/hole verification.
* :mod:`seam_quality_verification` — visible-seam (luminance step) analysis.
"""

from sitewise.panorama.quality.report import QualityFinding, QualityReport
from sitewise.panorama.quality.thresholds import PanoramaQualityThresholds

__all__ = ["QualityFinding", "QualityReport", "PanoramaQualityThresholds"]
