"""Pairwise registration and geometric-consistency verification.

The computationally expensive half of the capture-quality checks — ORB
detection, descriptor matching and RANSAC homography for every adjacent
frame pair — runs ONLY on the worker thread (or an explicitly spawned audit
thread), never inside a request handler on the capture path.

What it verifies, per pair of recorded neighbours:

* **Shared content**: enough ratio-test matches survive to reason at all.
  A featureless wall yields the same signature as a mis-aimed frame, so a
  shortage is INFORMATIONAL by design — low-texture rooms are valid captures.
* **Geometric consistency**: the RANSAC inlier ratio and the reprojection
  residual spread. A pair whose matches cannot be explained by one image
  motion is geometrically inconsistent — the classic signature of a frame
  captured while the phone was still moving.
* **Overlap confidence**: the fraction of the first frame's area whose
  homography-mapped corners land inside the second frame — the backend's
  authoritative version of the device's advisory overlap hint.

The verifier reads what the capture actually recorded and reports evidence.
It never deletes, re-orders or re-stitches anything.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import cv2
import numpy as np

from sitewise.panorama.quality.report import QualityFinding, QualityReport
from sitewise.panorama.quality.thresholds import PanoramaQualityThresholds

logger = logging.getLogger("sitewise.panorama.quality")

CHECK = "registration"


@dataclass(frozen=True, slots=True)
class RegistrationFrame:
    """One original photograph as the verifier needs it."""

    target_id: int
    image_path: str


@dataclass(frozen=True, slots=True)
class _PairResult:
    match_count: int
    inlier_ratio: float
    median_residual_px: float
    p95_residual_px: float
    overlap_fraction: float | None


def _load_gray(image_path: str, max_width: int) -> np.ndarray | None:
    """Decodes one frame downscaled to ``max_width``; None when unreadable."""
    data = Path(image_path).read_bytes()
    decoded = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_GRAYSCALE)
    if decoded is None:
        return None
    height, width = decoded.shape[:2]
    if width <= max_width:
        return decoded
    scale = max_width / width
    new_size = (max_width, max(1, int(height * scale)))
    return cv2.resize(decoded, new_size, interpolation=cv2.INTER_AREA)


def _verify_pair(
    first_gray: np.ndarray,
    second_gray: np.ndarray,
    orb: cv2.ORB,
    matcher: cv2.BFMatcher,
    thresholds: PanoramaQualityThresholds,
) -> _PairResult | None:
    """ORB match + RANSAC homography for one pair, with evidence numbers."""
    first_keypoints, first_descriptors = orb.detectAndCompute(first_gray, None)
    second_keypoints, second_descriptors = orb.detectAndCompute(second_gray, None)
    if first_descriptors is None or second_descriptors is None:
        return None
    if len(first_keypoints) < 8 or len(second_keypoints) < 8:
        return None

    knn = matcher.knnMatch(first_descriptors, second_descriptors, k=2)
    kept: list[tuple[tuple[float, float], tuple[float, float]]] = []
    for row in knn:
        if len(row) < 2:
            continue
        best, runner_up = row[0], row[1]
        if best.distance < thresholds.match_ratio * runner_up.distance:
            kept.append(
                (
                    first_keypoints[best.queryIdx].pt,
                    second_keypoints[best.trainIdx].pt,
                )
            )
    match_count = len(kept)
    if match_count < thresholds.min_matches:
        return _PairResult(
            match_count=match_count,
            inlier_ratio=0.0,
            median_residual_px=0.0,
            p95_residual_px=0.0,
            overlap_fraction=None,
        )

    src = np.asarray([point[0] for point in kept], dtype=np.float32)
    dst = np.asarray([point[1] for point in kept], dtype=np.float32)
    homography, mask = cv2.findHomography(
        src.reshape(-1, 1, 2),
        dst.reshape(-1, 1, 2),
        cv2.RANSAC,
        thresholds.ransac_reproj_px,
    )
    if homography is None or mask is None:
        return _PairResult(
            match_count=match_count,
            inlier_ratio=0.0,
            median_residual_px=0.0,
            p95_residual_px=0.0,
            overlap_fraction=None,
        )
    mask = mask.ravel().astype(bool)
    inlier_ratio = float(mask.sum()) / float(match_count)

    residuals = np.linalg.norm(
        _project(src[mask], homography) - dst[mask], axis=1
    )
    median_residual = float(np.median(residuals)) if residuals.size else 0.0
    p95_residual = (
        float(np.percentile(residuals, 95)) if residuals.size else 0.0
    )

    # Overlap: how much of the first frame's area maps inside the second.
    height, width = first_gray.shape[:2]
    corners = np.asarray(
        [[[0.0, 0.0], [width, 0.0], [width, height], [0.0, height]]],
        dtype=np.float32,
    )
    mapped = cv2.perspectiveTransform(corners, homography)[0]
    second_height, second_width = second_gray.shape[:2]
    inside = 0
    for x_coord, y_coord in mapped:
        if -1 <= x_coord <= second_width and -1 <= y_coord <= second_height:
            inside += 1
    overlap = inside / 4.0

    return _PairResult(
        match_count=match_count,
        inlier_ratio=inlier_ratio,
        median_residual_px=median_residual,
        p95_residual_px=p95_residual,
        overlap_fraction=overlap,
    )


def _project(points: np.ndarray, homography: np.ndarray) -> np.ndarray:
    """Applies ``homography`` to an (N, 2) point array."""
    stacked = np.hstack([points, np.ones((points.shape[0], 1), dtype=np.float64)])
    projected = stacked @ homography.T
    weights = projected[:, 2]
    weights[np.abs(weights) < 1e-9] = 1e-9
    return (projected[:, :2] / weights[:, None]).astype(np.float64)


def verify_session_registration(
    frames: list[RegistrationFrame],
    thresholds: PanoramaQualityThresholds | None = None,
    on_stage: Callable[[str], None] | None = None,
) -> QualityReport:
    """Verifies registration and geometric consistency across all neighbours.

    Adjacent pairs are the frames whose recorded targets are nearest
    neighbours on the capture sphere — implemented here as consecutive
    entries of the (target-ordered) frame list, which is exactly the stitch
    path order. A pair whose JPEG cannot be read produces an ERROR finding
    (that frame genuinely cannot serve the panorama); everything else is
    measured evidence.
    """
    active = thresholds or PanoramaQualityThresholds()
    report = QualityReport(
        check=CHECK,
        measurements={
            "thresholds_version": active.version,
            "frames": len(frames),
        },
    )
    if len(frames) < 2:
        report.add(
            QualityFinding.info(
                CHECK,
                "single_frame",
                "A single photograph has no neighbour to register against.",
            )
        )
        return report

    orb = cv2.ORB_create(nfeatures=active.orb_features)
    matcher = cv2.BFMatcher.create(normType=cv2.NORM_HAMMING)

    decoded: list[np.ndarray | None] = [None] * len(frames)
    unreadable: list[int] = []
    for index, frame in enumerate(frames):
        if on_stage is not None:
            on_stage(f"Verifying capture quality: frame {index + 1}/{len(frames)}…")
        try:
            decoded[index] = _load_gray(frame.image_path, active.analysis_max_width)
        except OSError:
            decoded[index] = None
        except Exception:  # noqa: BLE001 - a broken decode is evidence, not a crash
            logger.warning(
                "Registration verification could not decode %s", frame.image_path,
                exc_info=True,
            )
            decoded[index] = None
        if decoded[index] is None:
            unreadable.append(frame.target_id)
    for target_id in unreadable:
        report.add(
            QualityFinding.error(
                CHECK,
                "frame_unreadable",
                f"The photograph for target {target_id} could not be decoded "
                "on the server. Retake that target and re-sync.",
                target_id=float(target_id),
            )
        )

    pair_results: list[_PairResult] = []
    for index in range(len(frames) - 1):
        first = decoded[index]
        second = decoded[index + 1]
        if first is None or second is None:
            continue
        result = _verify_pair(first, second, orb, matcher, active)
        if result is None:
            continue
        pair_results.append(
            _PairResult(
                first=frames[index].target_id,
                second=frames[index + 1].target_id,
                match_count=result.match_count,
                inlier_ratio=result.inlier_ratio,
                median_residual_px=result.median_residual_px,
                p95_residual_px=result.p95_residual_px,
                overlap_fraction=result.overlap_fraction,
            )
        )

    matcher_masked = [
        result for result in pair_results if result.match_count < active.min_matches
    ]
    for result in matcher_masked:
        report.add(
            QualityFinding.info(
                CHECK,
                "insufficient_features",
                f"Targets {result.first}→{result.second} share too little "
                "surface detail to verify registration — common for plain "
                "walls; the frame is kept.",
                first=float(result.first),
                second=float(result.second),
                match_count=float(result.match_count),
            )
        )

    for result in pair_results:
        if result.match_count < active.min_matches:
            continue
        if result.inlier_ratio < active.min_inlier_ratio:
            report.add(
                QualityFinding.warning(
                    CHECK,
                    "geometric_inconsistency",
                    f"Targets {result.first}→{result.second} do not agree on "
                    "one image motion — the phone may have been moving when "
                    "the photograph was taken. The frame is kept; review the "
                    "panorama seam there.",
                    first=float(result.first),
                    second=float(result.second),
                    inlier_ratio=result.inlier_ratio,
                )
            )
        if result.median_residual_px > active.max_median_residual_px or (
            result.p95_residual_px > active.max_p95_residual_px
        ):
            report.add(
                QualityFinding.warning(
                    CHECK,
                    "loose_registration",
                    f"Targets {result.first}→{result.second} register with a "
                    "loose fit. The frame is kept; the seam there may show.",
                    first=float(result.first),
                    second=float(result.second),
                    median_residual_px=result.median_residual_px,
                    p95_residual_px=result.p95_residual_px,
                )
            )
        if (
            result.overlap_fraction is not None
            and result.overlap_fraction < active.min_overlap_fraction
        ):
            report.add(
                QualityFinding.warning(
                    CHECK,
                    "overlap_low",
                    f"Targets {result.first}→{result.second} share less "
                    "content than the capture plan promises. The frame is "
                    "kept; retake if the seam there matters.",
                    first=float(result.first),
                    second=float(result.second),
                    overlap_fraction=result.overlap_fraction,
                )
            )

    if pair_results:
        report.measurements.update(
            {
                "pairs": len(pair_results),
                "median_inlier_ratio": float(
                    np.median([r.inlier_ratio for r in pair_results])
                ),
                "median_overlap_fraction": float(
                    np.median(
                        [
                            r.overlap_fraction
                            for r in pair_results
                            if r.overlap_fraction is not None
                        ]
                    )
                ),
            }
        )
    return report
