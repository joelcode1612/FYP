"""Pairwise verification of two photographs under a rotation-only model.

## The model

The capture protocol asks the photographer to stay in one place and rotate, so
two frames of the same scene differ by **camera rotation only**. For a purely
rotating camera the image-to-image mapping is an exact homography regardless of
scene depth::

    p_b  ∝  K_b · (R_b⁻¹ R_a) · K_a⁻¹ · p_a

That is what makes a homography the honest geometric model here rather than a
convenience. If the observed motion cannot be explained by *some* rotation —
because the photographer walked, or because the correspondences are wrong —
RANSAC leaves few inliers and the edge is refused. Nothing is forced through.

## Why the thresholds are not the whole story

Thirty inliers can be thirty copies of one repeated tile. Every edge therefore
also reports:

* **inlier ratio** — inliers over ratio-test survivors;
* **median and 95th-percentile reprojection error**, in *matching-resolution*
  pixels, the same resolution the descriptors were extracted at;
* **spatial spread** — how many cells of a 3×3 image grid contain inliers;
* **azimuth spread** — how many sectors of the sphere the inliers cover.

An edge that clears the numeric thresholds but concentrates its inliers in one
corner is downgraded to ``weak``: it is reported, it is never used as evidence
that two regions are reliably connected.

## Two detectors, one bar

:func:`verify_pair_cascaded` runs ORB first because it is roughly ten times
cheaper, and escalates to SIFT only when ORB could not *verify* the pair. The
decision is made on the measured verdict — inliers, ratio, reprojection error,
spread — never on a feature count, and the winning verdict records which
detector produced it so a report never implies SIFT-grade evidence it does not
have.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Callable

import numpy as np

from ..sphere_math import RAD_TO_DEG, Quat
from .camera import PinholeCamera
from .features import DESCRIPTOR_ORB, DESCRIPTOR_SIFT, FeatureSet

try:  # pragma: no cover - import guard only
    import cv2
except Exception:  # pragma: no cover
    cv2 = None  # type: ignore[assignment]

#: Edge states. ``strong`` is the only state the graph may treat as verified.
STATE_STRONG = "strong"
STATE_WEAK = "weak"
STATE_FAILED = "failed"
STATE_INSUFFICIENT = "insufficient"


@dataclass(frozen=True, slots=True)
class MatchThresholds:
    """Conservative starting thresholds; tune per device, not per session.

    Every value is deliberately explicit so a reviewer can see what "verified"
    meant for a given capture. They are **not** claimed to be universally
    valid: a low-texture interior needs a lower inlier count to connect at all,
    which is why a failure here is reported as a weak region rather than as a
    broken capture.
    """

    lowe_ratio: float = 0.75
    min_inliers: int = 30
    min_inlier_ratio: float = 0.50
    median_error_px: float = 2.0
    p95_error_px: float = 5.0
    ransac_px: float = 4.0
    #: Minimum ratio-test survivors before RANSAC is even attempted.
    min_candidates: int = 12
    #: 3×3 image grid: at least this many cells must hold inliers.
    min_spread_cells: int = 5
    #: Eight azimuth sectors: at least this many must hold inliers.
    min_azimuth_sectors: int = 3
    #: A measured rotation further than this from the sensor prior means the
    #: match disagrees with the recorded orientation; the edge is downgraded.
    max_rotation_disagreement_deg: float = 20.0
    #: Reject a relative rotation that would need more than this correction to
    #: the recorded poses; that is a parallax or a mismatch, not a refinement.
    max_rotation_correction_deg: float = 12.0

    def as_dict(self) -> dict[str, float | int]:
        return {
            "loweRatio": self.lowe_ratio,
            "minInliers": self.min_inliers,
            "minInlierRatio": self.min_inlier_ratio,
            "medianErrorPx": self.median_error_px,
            "p95ErrorPx": self.p95_error_px,
            "ransacPx": self.ransac_px,
            "minSpreadCells": self.min_spread_cells,
            "minAzimuthSectors": self.min_azimuth_sectors,
        }


DEFAULT_THRESHOLDS = MatchThresholds()


@dataclass(frozen=True, slots=True)
class MatchVerdict:
    """The outcome of verifying one candidate pair."""

    state: str
    inliers: int
    candidates: int
    inlier_ratio: float
    median_error_px: float
    p95_error_px: float
    spread_cells: int
    azimuth_sectors: int
    #: ``R_b⁻¹ R_a`` measured from the image pair, or ``None`` when refused.
    relative_rotation: Quat | None
    #: Angle between the measured relative rotation and the sensor prior.
    rotation_disagreement_deg: float
    reason: str
    #: Which detector produced this verdict — ``orb`` or ``sift``. Carried so a
    #: report can distinguish "verified with the cheap detector" from "verified
    #: only after escalating", and never presents one as the other.
    detector: str = DESCRIPTOR_SIFT

    @property
    def is_strong(self) -> bool:
        return self.state == STATE_STRONG

    @property
    def is_usable(self) -> bool:
        return self.state in (STATE_STRONG, STATE_WEAK)

    @property
    def confidence(self) -> float:
        """0…1 summary for the UI. Not a probability of correctness."""
        if self.state in (STATE_FAILED, STATE_INSUFFICIENT):
            return 0.0
        inlier_term = min(1.0, self.inliers / 120.0)
        ratio_term = min(1.0, self.inlier_ratio / 0.8)
        error_term = max(0.0, 1.0 - self.median_error_px / 6.0)
        spread_term = self.spread_cells / 9.0
        return round(
            0.35 * inlier_term + 0.25 * ratio_term + 0.2 * error_term + 0.2 * spread_term,
            3,
        )

    def as_dict(self) -> dict[str, object]:
        return {
            "state": self.state,
            "inliers": self.inliers,
            "candidates": self.candidates,
            "inlierRatio": round(self.inlier_ratio, 4),
            "medianErrorPx": round(self.median_error_px, 3),
            "p95ErrorPx": round(self.p95_error_px, 3),
            "spreadCells": self.spread_cells,
            "azimuthSectors": self.azimuth_sectors,
            "rotationDisagreementDeg": round(self.rotation_disagreement_deg, 3),
            "confidence": self.confidence,
            "reason": self.reason,
            "detector": self.detector,
        }


def _refused(
    state: str,
    reason: str,
    *,
    candidates: int = 0,
    inliers: int = 0,
    ratio: float = 0.0,
    median: float = 0.0,
    p95: float = 0.0,
    spread: int = 0,
    sectors: int = 0,
    disagreement: float = 0.0,
    detector: str = DESCRIPTOR_SIFT,
) -> MatchVerdict:
    return MatchVerdict(
        state=state,
        inliers=inliers,
        candidates=candidates,
        inlier_ratio=ratio,
        median_error_px=median,
        p95_error_px=p95,
        spread_cells=spread,
        azimuth_sectors=sectors,
        relative_rotation=None,
        rotation_disagreement_deg=disagreement,
        reason=reason,
        detector=detector,
    )


def matching_camera(features: FeatureSet, saved: PinholeCamera) -> PinholeCamera:
    """The same lens expressed in matching-resolution pixels.

    ``FeatureSet.scale`` is matching pixels per saved pixel, so every intrinsic
    scales by it. Reprojection errors are then in the coordinate system the
    descriptors live in, which is what the thresholds are documented against.
    """
    s = features.scale
    return PinholeCamera(
        width=features.width,
        height=features.height,
        focal=saved.focal * s,
        cx=saved.principal_x * s,
        cy=saved.principal_y * s,
    )


def _intrinsic_matrix(camera: PinholeCamera) -> np.ndarray:
    return np.array(
        [
            [camera.focal, 0.0, camera.principal_x],
            [0.0, camera.focal, camera.principal_y],
            [0.0, 0.0, 1.0],
        ],
        dtype=np.float64,
    )


def _nearest_rotation(matrix: np.ndarray) -> Quat:
    """Project a 3×3 matrix onto SO(3) and return it as a quaternion."""
    u, _s, vt = np.linalg.svd(matrix)
    rotation = u @ vt
    if np.linalg.det(rotation) < 0:
        u[:, -1] *= -1.0
        rotation = u @ vt
    trace = float(np.trace(rotation))
    w = math.sqrt(max(0.0, 1.0 + trace)) / 2.0
    if w < 1e-8:
        # 180° rotation: recover the axis from the symmetric part.
        axis_matrix = (rotation + np.eye(3)) / 2.0
        axis = np.sqrt(np.maximum(np.diag(axis_matrix), 0.0))
        return Quat(float(axis[0]), float(axis[1]), float(axis[2]), 0.0).normalized
    x = (rotation[2, 1] - rotation[1, 2]) / (4.0 * w)
    y = (rotation[0, 2] - rotation[2, 0]) / (4.0 * w)
    z = (rotation[1, 0] - rotation[0, 1]) / (4.0 * w)
    return Quat(float(x), float(y), float(z), float(w)).normalized


def relative_rotation_from_homography(
    homography: np.ndarray,
    first: PinholeCamera,
    second: PinholeCamera,
) -> Quat | None:
    """Recover ``R_b⁻¹ R_a`` from an image-to-image homography.

    ``H = K_b · (R_b⁻¹ R_a) · K_a⁻¹`` for a rotating camera, so the rotation is
    ``K_b⁻¹ · H · K_a`` up to scale. The scale is removed before projecting
    onto SO(3); the projection absorbs the residual noise that makes the raw
    product only approximately orthogonal.
    """
    if homography is None or homography.shape != (3, 3):
        return None
    if not np.all(np.isfinite(homography)):
        return None
    k_first = _intrinsic_matrix(first)
    k_second = _intrinsic_matrix(second)
    try:
        raw = np.linalg.inv(k_second) @ homography @ k_first
    except np.linalg.LinAlgError:
        return None
    norm = float(np.linalg.norm(raw))
    if not math.isfinite(norm) or norm < 1e-9:
        return None
    raw = raw / norm
    # A rotation matrix has unit singular values; a degenerate homography does
    # not, and its "nearest rotation" would be meaningless.
    singular = np.linalg.svd(raw, compute_uv=False)
    if singular[-1] < 1e-3 or singular[0] / max(singular[-1], 1e-12) > 25.0:
        return None
    return _nearest_rotation(raw)


def _rotation_angle_deg(a: Quat, b: Quat) -> float:
    """Angle of ``a · b⁻¹`` in degrees."""
    dot = abs(min(1.0, max(-1.0, (a * b.conjugate).w)))
    return 2.0 * math.acos(dot) * RAD_TO_DEG


def _spread(points: np.ndarray, width: float, height: float) -> tuple[int, int]:
    """Occupied 3×3 image cells and occupied 8-way azimuth sectors."""
    if points.size == 0:
        return 0, 0
    cells = set()
    for u, v in points:
        column = 0 if u < width / 3 else (1 if u < 2 * width / 3 else 2)
        row = 0 if v < height / 3 else (1 if v < 2 * height / 3 else 2)
        cells.add((row, column))
    # Azimuth around the image centre: eight 45° sectors, so a match spread
    # along one wall only cannot masquerade as a whole-frame connection.
    centre_u = width / 2.0
    centre_v = height / 2.0
    sectors = {
        int(((math.atan2(v - centre_v, u - centre_u) + math.pi) / (math.pi / 4.0))) % 8
        for u, v in points
    }
    return len(cells), len(sectors)


def _flann_matcher():
    index_params = dict(algorithm=1, trees=5)  # FLANN_INDEX_KDTREE
    search_params = dict(checks=64)
    return cv2.FlannBasedMatcher(index_params, search_params)


def _hamming_matcher():
    """Brute-force Hamming matcher for ORB's binary descriptors.

    FLANN's LSH index would also work, but for ≈1 200 × 32-byte rows a
    brute-force Hamming knn is faster to build (no index construction at all)
    and exact, which matters because the ratio test is only meaningful on true
    nearest neighbours.
    """
    return cv2.BFMatcher(cv2.NORM_HAMMING)


def _matcher_for(kind: str):
    return _hamming_matcher() if kind == DESCRIPTOR_ORB else _flann_matcher()


def _knn_pairs(matcher, query: np.ndarray, train: np.ndarray, ratio: float):
    knn = matcher.knnMatch(query, train, k=2)
    kept: list[tuple[int, int]] = []
    for row in knn:
        if len(row) < 2:
            continue
        best, runner_up = row[0], row[1]
        if runner_up.distance <= 0:
            continue
        if best.distance < ratio * runner_up.distance:
            kept.append((int(best.queryIdx), int(best.trainIdx)))
    return kept


def verify_pair(
    first: FeatureSet,
    second: FeatureSet,
    *,
    first_camera: PinholeCamera,
    second_camera: PinholeCamera,
    prior_relative_rotation: Quat | None = None,
    thresholds: MatchThresholds = DEFAULT_THRESHOLDS,
) -> MatchVerdict:
    """Match and geometrically verify two frames.

    [first_camera] and [second_camera] must be the **saved-image** intrinsics;
    they are rescaled to matching resolution internally. [prior_relative_rotation]
    is ``R_b⁻¹ R_a`` from the recorded sensor poses, used only to detect a match
    that contradicts the sensors — never to create one.
    """
    if cv2 is None:
        raise RuntimeError("OpenCV is required for image matching.")
    if not first.is_usable or not second.is_usable:
        return _refused(
            STATE_INSUFFICIENT,
            "Not enough stable features were found in one of the photographs.",
            detector=first.kind,
        )
    if first.kind != second.kind:
        # Comparing a binary descriptor with a float one has no meaning; the
        # caller must pass the same detector for both frames.
        return _refused(
            STATE_INSUFFICIENT,
            f"The two frames were described by different detectors "
            f"({first.kind} and {second.kind}), so they cannot be compared.",
            detector=first.kind,
        )

    matcher = _matcher_for(first.kind)
    forward = _knn_pairs(matcher, first.descriptors, second.descriptors, thresholds.lowe_ratio)
    if len(forward) < thresholds.min_candidates:
        return _refused(
            STATE_INSUFFICIENT,
            f"Only {len(forward)} ratio-test matches survived; "
            f"{thresholds.min_candidates} are needed to attempt verification.",
            candidates=len(forward),
            detector=first.kind,
        )

    # Mutual filtering: a correspondence must be each other's best ratio-test
    # candidate. Repetitive structure produces many one-way matches and very
    # few two-way ones, which is exactly the discrimination wanted here.
    backward = _knn_pairs(matcher, second.descriptors, first.descriptors, thresholds.lowe_ratio)
    backward_set = {(t, q) for q, t in backward}
    mutual = [(q, t) for q, t in forward if (q, t) in backward_set]
    candidates = mutual if len(mutual) >= thresholds.min_candidates else forward
    mutual_filtered = len(mutual) >= thresholds.min_candidates
    if len(candidates) < thresholds.min_candidates:
        return _refused(
            STATE_INSUFFICIENT,
            f"Only {len(candidates)} mutual matches survived the ratio test.",
            candidates=len(candidates),
            detector=first.kind,
        )

    return _verify_from_candidates(
        first,
        second,
        candidates,
        mutual_filtered=mutual_filtered,
        first_camera=first_camera,
        second_camera=second_camera,
        prior_relative_rotation=prior_relative_rotation,
        thresholds=thresholds,
    )


class PairMatcher:
    """Reusable matcher for one session.

    FLANN builds a KD-tree per descriptor set; a session matches each frame
    against several neighbours, so the index is built once per frame here
    instead of once per pair. Indices are keyed by ``(detector, frame)`` because
    a frame can legitimately hold both an ORB set and a SIFT set once the
    fallback has run.
    """

    def __init__(self) -> None:
        self._forward: dict[tuple[str, int], object] = {}
        self._backward: dict[tuple[str, int], object] = {}

    def _index(self, cache: dict[tuple[str, int], object], key: int, features: FeatureSet):
        cache_key = (features.kind, key)
        matcher = cache.get(cache_key)
        if matcher is None:
            matcher = _matcher_for(features.kind)
            matcher.add([features.descriptors])
            matcher.train()
            cache[cache_key] = matcher
        return matcher

    def verify(
        self,
        first_key: int,
        second_key: int,
        first: FeatureSet,
        second: FeatureSet,
        *,
        first_camera: PinholeCamera,
        second_camera: PinholeCamera,
        prior_relative_rotation: Quat | None = None,
        thresholds: MatchThresholds = DEFAULT_THRESHOLDS,
    ) -> MatchVerdict:
        if cv2 is None:
            raise RuntimeError("OpenCV is required for image matching.")
        if not first.is_usable or not second.is_usable:
            return _refused(
                STATE_INSUFFICIENT,
                "Not enough stable features were found in one of the photographs.",
                detector=first.kind,
            )
        if first.kind != second.kind:
            return _refused(
                STATE_INSUFFICIENT,
                f"The two frames were described by different detectors "
                f"({first.kind} and {second.kind}), so they cannot be compared.",
                detector=first.kind,
            )
        matcher_a = self._index(self._forward, first_key, first)
        matcher_b = self._index(self._forward, second_key, second)
        forward = _knn_pairs(
            matcher_a, first.descriptors, second.descriptors, thresholds.lowe_ratio
        )
        if len(forward) < thresholds.min_candidates:
            return _refused(
                STATE_INSUFFICIENT,
                f"Only {len(forward)} ratio-test matches survived.",
                candidates=len(forward),
                detector=first.kind,
            )
        backward = _knn_pairs(
            matcher_b, second.descriptors, first.descriptors, thresholds.lowe_ratio
        )
        backward_set = {(t, q) for q, t in backward}
        mutual = [(q, t) for q, t in forward if (q, t) in backward_set]
        candidates = mutual if len(mutual) >= thresholds.min_candidates else forward
        return _verify_from_candidates(
            first,
            second,
            candidates,
            mutual_filtered=len(mutual) >= thresholds.min_candidates,
            first_camera=first_camera,
            second_camera=second_camera,
            prior_relative_rotation=prior_relative_rotation,
            thresholds=thresholds,
        )


def _verify_from_candidates(
    first: FeatureSet,
    second: FeatureSet,
    candidates: list[tuple[int, int]],
    *,
    mutual_filtered: bool,
    first_camera: PinholeCamera,
    second_camera: PinholeCamera,
    prior_relative_rotation: Quat | None,
    thresholds: MatchThresholds,
) -> MatchVerdict:
    """Shared tail of :func:`verify_pair` and :meth:`PairMatcher.verify`."""
    detector = first.kind
    src = np.asarray([first.points[q] for q, _t in candidates], dtype=np.float32)
    dst = np.asarray([second.points[t] for _q, t in candidates], dtype=np.float32)
    homography, mask = cv2.findHomography(
        src.reshape(-1, 1, 2), dst.reshape(-1, 1, 2), cv2.RANSAC, thresholds.ransac_px
    )
    if homography is None or mask is None:
        return _refused(
            STATE_FAILED,
            "The correspondences did not fit any rotation-consistent mapping.",
            candidates=len(candidates),
            detector=detector,
        )
    inlier_mask = mask.ravel().astype(bool)
    inliers = int(inlier_mask.sum())
    ratio = inliers / len(candidates)
    if inliers == 0:
        return _refused(
            STATE_FAILED,
            "No correspondence survived geometric verification.",
            candidates=len(candidates),
            detector=detector,
        )
    src_in = src[inlier_mask]
    dst_in = dst[inlier_mask]
    projected = cv2.perspectiveTransform(src_in.reshape(-1, 1, 2), homography).reshape(-1, 2)
    errors = np.linalg.norm(projected - dst_in, axis=1)
    median_error = float(np.median(errors))
    p95_error = float(np.percentile(errors, 95))
    spread_cells, sectors = _spread(src_in, first.width, first.height)
    measured = relative_rotation_from_homography(
        homography,
        matching_camera(first, first_camera),
        matching_camera(second, second_camera),
    )
    disagreement = 0.0
    if measured is not None and prior_relative_rotation is not None:
        disagreement = _rotation_angle_deg(measured, prior_relative_rotation)

    def verdict(state: str, reason: str) -> MatchVerdict:
        return MatchVerdict(
            state=state,
            inliers=inliers,
            candidates=len(candidates),
            inlier_ratio=ratio,
            median_error_px=median_error,
            p95_error_px=p95_error,
            spread_cells=spread_cells,
            azimuth_sectors=sectors,
            relative_rotation=measured,
            rotation_disagreement_deg=disagreement,
            reason=reason,
            detector=detector,
        )

    if measured is None:
        return verdict(STATE_FAILED, "The fit could not be read as a camera rotation.")
    if inliers < thresholds.min_inliers:
        return verdict(
            STATE_FAILED,
            f"{inliers} verified correspondences is below the "
            f"{thresholds.min_inliers} required.",
        )
    if ratio < thresholds.min_inlier_ratio:
        return verdict(
            STATE_FAILED,
            f"Only {ratio * 100:.0f}% of matches were geometrically consistent.",
        )
    if median_error > thresholds.median_error_px or p95_error > thresholds.p95_error_px:
        return verdict(
            STATE_FAILED,
            f"Reprojection error {median_error:.1f} px median / {p95_error:.1f} px "
            "95th percentile is too high.",
        )
    if disagreement > thresholds.max_rotation_correction_deg:
        return verdict(
            STATE_FAILED,
            f"The match implies a {disagreement:.1f}° correction to the recorded "
            "orientation, which indicates parallax or a wrong correspondence.",
        )
    if spread_cells < thresholds.min_spread_cells:
        return verdict(
            STATE_WEAK,
            f"Verified matches concentrate in {spread_cells}/9 image cells.",
        )
    if sectors < thresholds.min_azimuth_sectors:
        return verdict(
            STATE_WEAK,
            f"Verified matches cover {sectors}/8 azimuth sectors.",
        )
    if not mutual_filtered:
        return verdict(
            STATE_WEAK,
            "Too few correspondences were each other's best match.",
        )
    return verdict(
        STATE_STRONG,
        f"{inliers} verified correspondences, median error {median_error:.2f} px.",
    )


def _prefer(orb: MatchVerdict, sift: MatchVerdict) -> MatchVerdict:
    """Which of two verdicts for the same pair to keep.

    A strong verdict always wins. Between two non-strong verdicts the higher
    confidence wins, so a weak-but-spread SIFT result replaces a weak-but-
    concentrated ORB one. A verdict that at least *ran* beats one that had too
    few features to try, because it carries measured evidence.
    """
    if orb.is_strong:
        return orb
    if sift.is_strong:
        return sift
    if orb.state == STATE_INSUFFICIENT and sift.state != STATE_INSUFFICIENT:
        return sift
    if sift.state == STATE_INSUFFICIENT and orb.state != STATE_INSUFFICIENT:
        return orb
    return sift if sift.confidence > orb.confidence else orb


def verify_pair_cascaded(
    first_key: int,
    second_key: int,
    *,
    first_camera: PinholeCamera,
    second_camera: PinholeCamera,
    prior_relative_rotation: Quat | None = None,
    thresholds: MatchThresholds = DEFAULT_THRESHOLDS,
    matcher: PairMatcher | None = None,
    orb_features: Callable[[int], FeatureSet | None],
    sift_features: Callable[[int], FeatureSet | None],
    allow_sift_fallback: bool = True,
) -> MatchVerdict:
    """Verify one pair, ORB first and SIFT only where ORB did not verify it.

    [orb_features] and [sift_features] are keyed by frame id and are expected to
    memoise — the session passes closures over its own caches, so a frame is
    extracted once per detector no matter how many neighbours it is matched
    against.

    The fallback is *selective*: it runs only when ORB's verdict is not
    ``strong``, i.e. when the measured evidence was insufficient, failed or
    merely weak. It is never triggered by a feature count, and a strong ORB
    verdict is returned untouched so the common case stays cheap.
    """
    matcher = matcher or PairMatcher()
    first_orb = orb_features(first_key)
    second_orb = orb_features(second_key)
    if first_orb is None or second_orb is None:
        return _refused(
            STATE_FAILED,
            "A photograph could not be decoded for matching.",
            detector=DESCRIPTOR_ORB,
        )

    orb = matcher.verify(
        first_key,
        second_key,
        first_orb,
        second_orb,
        first_camera=first_camera,
        second_camera=second_camera,
        prior_relative_rotation=prior_relative_rotation,
        thresholds=thresholds,
    )
    if orb.is_strong or not allow_sift_fallback:
        return orb

    first_sift = sift_features(first_key)
    second_sift = sift_features(second_key)
    if first_sift is None or second_sift is None:
        return orb
    sift = matcher.verify(
        first_key,
        second_key,
        first_sift,
        second_sift,
        first_camera=first_camera,
        second_camera=second_camera,
        prior_relative_rotation=prior_relative_rotation,
        thresholds=thresholds,
    )
    chosen = _prefer(orb, sift)
    if chosen is sift and sift.state != orb.state:
        # Record the escalation in the reason so a report shows *why* the
        # expensive detector ran, not just that it did.
        return MatchVerdict(
            state=sift.state,
            inliers=sift.inliers,
            candidates=sift.candidates,
            inlier_ratio=sift.inlier_ratio,
            median_error_px=sift.median_error_px,
            p95_error_px=sift.p95_error_px,
            spread_cells=sift.spread_cells,
            azimuth_sectors=sift.azimuth_sectors,
            relative_rotation=sift.relative_rotation,
            rotation_disagreement_deg=sift.rotation_disagreement_deg,
            reason=f"{sift.reason} (escalated from ORB: {orb.state})",
            detector=DESCRIPTOR_SIFT,
        )
    return chosen


__all__ = [
    "DEFAULT_THRESHOLDS",
    "MatchThresholds",
    "MatchVerdict",
    "PairMatcher",
    "STATE_FAILED",
    "STATE_INSUFFICIENT",
    "STATE_STRONG",
    "STATE_WEAK",
    "matching_camera",
    "relative_rotation_from_homography",
    "verify_pair",
    "verify_pair_cascaded",
]
