"""ORB-primary feature extraction, with SIFT as a selective fallback.

## Why ORB runs first

ORB is roughly an order of magnitude cheaper than SIFT on the same frame and
its binary descriptors match with a Hamming distance, so the *designated*
neighbour pairs — the ones the capture plan says must connect — are all
attempted with ORB before anything expensive happens. Most well-exposed
interior pairs connect on ORB alone.

ORB is not, however, a substitute for SIFT on the frames that are genuinely
hard: a dim corner, a low-contrast ceiling, or a repeated tile pattern. For
those, and only those, the caller escalates to SIFT (see
``matching.verify_pair_cascaded``). That keeps the common case fast without
lowering the verification bar where it matters — the fallback is decided by a
measured verdict, never by a feature count.

## The cache

Incremental matching means the same photograph is matched against several
neighbours, and the worker re-runs a session after a failure. Re-detecting
features every time costs about 25 ms (ORB) to 120 ms (SIFT) per 1 MP frame;
caching them turns the second and later passes into a disk read.

The cache key covers the file's identity (path, size, mtime), the decode
resolution, the detector and that detector's parameters, so a replaced
photograph, a switched detector or a changed threshold can never be served a
stale descriptor set. The cache lives under ``backend/var/alignment_cache`` —
derived data only, never a source of truth, safe to delete at any time.
"""

from __future__ import annotations

import hashlib
import json
import logging
import math
import os
import threading
from dataclasses import dataclass
from pathlib import Path

import numpy as np

logger = logging.getLogger("sitewise.panorama.alignment.features")

try:  # OpenCV is optional at import time so the package stays importable.
    import cv2
except Exception:  # pragma: no cover - exercised only on a broken install
    cv2 = None  # type: ignore[assignment]

#: Long side of the image features run on. 0.6–1.0 MP keeps ≈2 000 stable
#: features on an indoor frame while bounding both time and memory.
MATCHING_LONG_SIDE_PX = 1_024
#: SIFT contrast threshold. Lower finds more features on plain walls, at the
#: cost of more spurious ones that RANSAC then rejects.
SIFT_CONTRAST_THRESHOLD = 0.012
SIFT_EDGE_THRESHOLD = 12.0
SIFT_SIGMA = 1.6
#: Cap on descriptors per frame; beyond this the added features are almost all
#: on texture-less surfaces and only slow the ratio test down.
MAX_FEATURES = 3_000
#: Above this count the strongest responses are kept, mirroring OpenCV's own
#: behaviour without needing its internal ordering.

#: Descriptor families. The kind travels with the descriptor set because it
#: decides the matching distance (Hamming for binary, L2 for float), and mixing
#: the two in one comparison would be meaningless.
DESCRIPTOR_ORB = "orb"
DESCRIPTOR_SIFT = "sift"

#: ORB parameters. 1 200 features at 1.2× scale with 8 levels is the standard
#: indoor setting: enough for a wall with a picture on it, cheap enough that
#: 96 designated pairs finish in a couple of seconds. The FAST threshold is
#: lowered from OpenCV's default 20 to 12 because an unfurnished room is
#: genuinely low-contrast; RANSAC still has to agree before an edge is used.
ORB_FEATURES = 1_200
ORB_SCALE_FACTOR = 1.2
ORB_LEVELS = 8
ORB_EDGE_THRESHOLD = 19
ORB_FAST_THRESHOLD = 12
ORB_PATCH_SIZE = 31
ORB_WTA_K = 2
#: Cap on ORB descriptors, matching ``MAX_FEATURES``'s role.
ORB_MAX_FEATURES = 1_500

#: Bumped when either detector's parameters or the cache layout change, so a
#: stale descriptor set can never be served to a new pipeline.
FEATURE_CACHE_VERSION = "orb-sift-v3"

_CACHE_ROOT = (
    Path(__file__).resolve().parents[4] / "var" / "alignment_cache"
)
_CACHE_ENABLED = os.environ.get("SITEWISE_ALIGNMENT_CACHE", "1") != "0"
_lock = threading.Lock()


@dataclass(frozen=True, slots=True)
class FeatureSet:
    """Keypoints and descriptors for one photograph.

    ``points`` is ``(N, 2)`` in **matching-resolution pixels**, i.e. the same
    coordinate system ``descriptors`` was extracted in and the same one the
    reprojection error is quoted in. ``scale`` converts those pixels back to
    the saved image, which is what the camera intrinsics are expressed in.

    ``kind`` is :data:`DESCRIPTOR_ORB` or :data:`DESCRIPTOR_SIFT`. It is part of
    the value, not a caller convention: the matching distance follows from it
    (Hamming for ORB's 32-byte binary rows, L2 for SIFT's 128-float rows) and a
    pair whose two sets disagree is refused rather than silently mismatched.
    """

    points: np.ndarray
    descriptors: np.ndarray
    width: int
    height: int
    scale: float
    source_width: int
    source_height: int
    kind: str = DESCRIPTOR_SIFT

    @property
    def count(self) -> int:
        return int(self.points.shape[0])

    @property
    def is_orb(self) -> bool:
        return self.kind == DESCRIPTOR_ORB

    @property
    def is_usable(self) -> bool:
        return self.count >= 8

    def to_saved_pixels(self, points: np.ndarray | None = None) -> np.ndarray:
        """Map matching-resolution pixels back to the saved image."""
        source = self.points if points is None else points
        return source / self.scale


def _cache_path(key: str) -> Path:
    return _CACHE_ROOT / key[:2] / f"{key}.npz"


def _file_key(path: Path, stat: os.stat_result, kind: str) -> str:
    payload = json.dumps(
        {
            "v": FEATURE_CACHE_VERSION,
            "path": str(path.resolve()),
            "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns,
            "long_side": MATCHING_LONG_SIDE_PX,
            "kind": kind,
            # Only the parameters of the detector actually used, so an ORB
            # entry is not invalidated by a SIFT tuning change and vice versa.
            "contrast": SIFT_CONTRAST_THRESHOLD if kind == DESCRIPTOR_SIFT else None,
            "edge": SIFT_EDGE_THRESHOLD if kind == DESCRIPTOR_SIFT else None,
            "sigma": SIFT_SIGMA if kind == DESCRIPTOR_SIFT else None,
            "orb": (
                {
                    "n": ORB_FEATURES,
                    "scale": ORB_SCALE_FACTOR,
                    "levels": ORB_LEVELS,
                    "edge": ORB_EDGE_THRESHOLD,
                    "fast": ORB_FAST_THRESHOLD,
                    "patch": ORB_PATCH_SIZE,
                    "wta": ORB_WTA_K,
                }
                if kind == DESCRIPTOR_ORB
                else None
            ),
        },
        sort_keys=True,
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _load_cache(key: str) -> FeatureSet | None:
    if not _CACHE_ENABLED:
        return None
    target = _cache_path(key)
    try:
        with np.load(target, allow_pickle=False) as data:
            return FeatureSet(
                points=data["points"],
                descriptors=data["descriptors"],
                width=int(data["width"]),
                height=int(data["height"]),
                scale=float(data["scale"]),
                source_width=int(data["source_width"]),
                source_height=int(data["source_height"]),
                kind=str(data["kind"]) if "kind" in data else DESCRIPTOR_SIFT,
            )
    except (OSError, KeyError, ValueError):
        return None


def _store_cache(key: str, features: FeatureSet) -> None:
    if not _CACHE_ENABLED:
        return
    target = _cache_path(key)
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_suffix(".tmp.npz")
        np.savez_compressed(
            tmp,
            points=features.points,
            descriptors=features.descriptors,
            width=np.int32(features.width),
            height=np.int32(features.height),
            scale=np.float64(features.scale),
            source_width=np.int32(features.source_width),
            source_height=np.int32(features.source_height),
            kind=np.array(features.kind),
        )
        os.replace(tmp, target)
    except OSError:
        logger.debug("Descriptor cache write failed for %s", target, exc_info=True)


def clear_feature_cache() -> int:
    """Delete every cached descriptor set. Returns the number removed."""
    removed = 0
    if not _CACHE_ROOT.exists():
        return removed
    for entry in _CACHE_ROOT.rglob("*.npz"):
        try:
            entry.unlink()
            removed += 1
        except OSError:
            continue
    return removed


def _decode(path: Path) -> tuple[np.ndarray, float, tuple[int, int]] | None:
    """Decode at the matching resolution; return ``(grey, scale, source_size)``."""
    if cv2 is None:
        return None
    image = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if image is None or image.size == 0:
        return None
    source_h, source_w = image.shape[:2]
    long_side = max(source_w, source_h)
    scale = 1.0 if long_side <= MATCHING_LONG_SIDE_PX else MATCHING_LONG_SIDE_PX / long_side
    if scale < 1.0:
        target_w = max(1, int(round(source_w * scale)))
        target_h = max(1, int(round(source_h * scale)))
        image = cv2.resize(image, (target_w, target_h), interpolation=cv2.INTER_AREA)
        # Report the scale actually achieved so pixel maths stays exact.
        scale = target_w / source_w
    grey = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    return grey, scale, (source_w, source_h)


def _empty(kind: str, width: int, height: int, scale: float, source_w: int, source_h: int) -> FeatureSet:
    """A usable-but-empty set: zero features, correct geometry.

    Recorded rather than dropped so a texture-less frame is reported as "no
    stable features here" instead of being confused with an undecodable file.
    """
    rows = 32 if kind == DESCRIPTOR_ORB else 128
    dtype = np.uint8 if kind == DESCRIPTOR_ORB else np.float32
    return FeatureSet(
        points=np.zeros((0, 2), dtype=np.float32),
        descriptors=np.zeros((0, rows), dtype=dtype),
        width=width,
        height=height,
        scale=scale,
        source_width=source_w,
        source_height=source_h,
        kind=kind,
    )


def _detect_orb(grey: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    detector = cv2.ORB_create(
        nfeatures=ORB_FEATURES,
        scaleFactor=ORB_SCALE_FACTOR,
        nlevels=ORB_LEVELS,
        edgeThreshold=ORB_EDGE_THRESHOLD,
        firstLevel=0,
        WTA_K=ORB_WTA_K,
        patchSize=ORB_PATCH_SIZE,
        fastThreshold=ORB_FAST_THRESHOLD,
    )
    keypoints, descriptors = detector.detectAndCompute(grey, None)
    if keypoints is None or descriptors is None or len(keypoints) == 0:
        return np.zeros((0, 2), dtype=np.float32), np.zeros((0, 32), dtype=np.uint8)
    points = np.array([kp.pt for kp in keypoints], dtype=np.float32)
    # Keep the binary rows as uint8: a float conversion would make the Hamming
    # distance meaningless and inflate the cache tenfold.
    descriptors = np.asarray(descriptors, dtype=np.uint8)
    if descriptors.shape[0] > ORB_MAX_FEATURES:
        order = np.argsort([-kp.response for kp in keypoints])[:ORB_MAX_FEATURES]
        points = points[order]
        descriptors = descriptors[order]
    return points, descriptors


def _detect_sift(grey: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    detector = cv2.SIFT_create(
        nfeatures=MAX_FEATURES,
        contrastThreshold=SIFT_CONTRAST_THRESHOLD,
        edgeThreshold=SIFT_EDGE_THRESHOLD,
        sigma=SIFT_SIGMA,
    )
    keypoints, descriptors = detector.detectAndCompute(grey, None)
    if keypoints is None or descriptors is None or len(keypoints) == 0:
        return np.zeros((0, 2), dtype=np.float32), np.zeros((0, 128), dtype=np.float32)
    points = np.array([kp.pt for kp in keypoints], dtype=np.float32)
    descriptors = np.asarray(descriptors, dtype=np.float32)
    if descriptors.shape[0] > MAX_FEATURES:
        order = np.argsort([-kp.response for kp in keypoints])[:MAX_FEATURES]
        points = points[order]
        descriptors = descriptors[order]
    return points, descriptors


def extract_features(
    path: str | Path,
    *,
    kind: str = DESCRIPTOR_SIFT,
) -> FeatureSet | None:
    """Features for [path], served from cache when the file is unchanged.

    [kind] selects the detector: :data:`DESCRIPTOR_ORB` (the primary path) or
    :data:`DESCRIPTOR_SIFT` (the fallback). Both are cached independently.

    Returns ``None`` when the file cannot be decoded — the caller records that
    as an unusable frame rather than inventing features for it.
    """
    if cv2 is None:
        raise RuntimeError(
            "OpenCV is required for image matching; install opencv-python-headless."
        )
    file_path = Path(path)
    try:
        stat = file_path.stat()
    except OSError:
        return None
    key = _file_key(file_path, stat, kind)
    with _lock:
        cached = _load_cache(key)
    if cached is not None:
        return cached

    decoded = _decode(file_path)
    if decoded is None:
        return None
    grey, scale, (source_w, source_h) = decoded
    height, width = grey.shape[:2]

    if kind == DESCRIPTOR_ORB:
        points, descriptors = _detect_orb(grey)
    else:
        points, descriptors = _detect_sift(grey)

    if points.shape[0] == 0:
        features = _empty(kind, width, height, scale, source_w, source_h)
    else:
        features = FeatureSet(
            points=points,
            descriptors=descriptors,
            width=width,
            height=height,
            scale=scale,
            source_width=source_w,
            source_height=source_h,
            kind=kind,
        )
    with _lock:
        _store_cache(key, features)
    return features


def extract_orb_features(path: str | Path) -> FeatureSet | None:
    """ORB features — the primary detector. See :func:`extract_features`."""
    return extract_features(path, kind=DESCRIPTOR_ORB)


def extract_sift_features(path: str | Path) -> FeatureSet | None:
    """SIFT features — used only where ORB could not verify a required pair."""
    return extract_features(path, kind=DESCRIPTOR_SIFT)


def footprint_overlap_fraction(
    first: FeatureSet,
    second: FeatureSet,
    *,
    angular_gap_deg: float,
    first_half_fov_deg: float,
    second_half_fov_deg: float,
) -> float:
    """Rough shared-area fraction between two frames, for pair ordering only.

    The exact figure comes from :mod:`coverage`; this cheap estimate exists so
    candidate pairs can be processed most-promising-first without projecting
    either footprint.
    """
    if first_half_fov_deg <= 0 or second_half_fov_deg <= 0:
        return 0.0
    smaller = min(first_half_fov_deg, second_half_fov_deg)
    if angular_gap_deg >= first_half_fov_deg + second_half_fov_deg:
        return 0.0
    # Linear ramp: full overlap at zero gap, none at the sum of half-FOVs.
    return max(0.0, 1.0 - angular_gap_deg / (first_half_fov_deg + second_half_fov_deg)) * (
        smaller / max(first_half_fov_deg, second_half_fov_deg)
    )


def descriptor_distance_floor() -> float:
    """Smallest plausible Lowe distance, used only to reject degenerate rows."""
    return 1e-6 if math.isfinite(1e-6) else 0.0


__all__ = [
    "DESCRIPTOR_ORB",
    "DESCRIPTOR_SIFT",
    "FEATURE_CACHE_VERSION",
    "FeatureSet",
    "MAX_FEATURES",
    "MATCHING_LONG_SIDE_PX",
    "ORB_FEATURES",
    "ORB_MAX_FEATURES",
    "SIFT_CONTRAST_THRESHOLD",
    "clear_feature_cache",
    "descriptor_distance_floor",
    "extract_features",
    "extract_orb_features",
    "extract_sift_features",
    "footprint_overlap_fraction",
]
