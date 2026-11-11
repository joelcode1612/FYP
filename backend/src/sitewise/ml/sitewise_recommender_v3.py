"""Five-Question Recommender V3 — verified calibration snapshot loader.

The user supplied ``RECOMMENDER_V3.joblib`` (948 bytes): a joblib snapshot of
the V3 recommender's CALIBRATION state. Its pickle refers to module
``sitewise_recommender_v3`` (classes ``FiveQuestionRecommender`` and
``Calibration``) — the package's own ``.py`` source was NOT delivered with the
supplied archive, so this module reconstructs a load-compatible home for the
snapshot and anchors every rule constant on the artifact's own values.

Artifact layout (verified by pickle disassembly):
* ``FiveQuestionRecommender`` attributes: ``calibration``, ``pu_weight``,
  ``preference_weight``, ``version``, ``low_pu_caution_bound``.
* ``Calibration`` attributes: ``rent_p10``, ``rent_p90``, ``sqft_p10``,
  ``sqft_p33``, ``sqft_p67``, ``sqft_p90``, ``count_scales``,
  ``population_count``, ``catalogue_fingerprint``.

This is a DETERMINISTIC RULE-BASED scoring engine, not a trained
scikit-learn predictor. Per the integration contract the serialized snapshot
is NEVER asked to ``.predict()`` anything: the rules live in
``sitewise.domain.recommendation_scoring`` (``score_candidate_v3``), and the
artifact is used only to (a) restore and (b) VERIFY the calibration numbers
the rules consume. Any mismatch between the artifact and the domain defaults
fails closed.
"""
from __future__ import annotations

import math
import sys
import threading
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.domain.recommendation_scoring import (
    SCORING_CONFIG_V3,
    SCORING_CONFIG_V3_VERSION,
    CalibrationV3,
    PreferenceProfile,
    PropertyCandidate,
    ScoringConfig,
    ScoredCandidate,
    score_candidate_v3,
)

SNAPSHOT_PATH = Path(__file__).resolve().parent / "recommender_v3.joblib"
_SNAPSHOT_LOCK = threading.Lock()


@dataclass
class Calibration:
    """Pickle-compatible calibration container (field names = artifact's)."""

    rent_p10: float = 0.0
    rent_p90: float = 0.0
    sqft_p10: float = 0.0
    sqft_p33: float = 0.0
    sqft_p67: float = 0.0
    sqft_p90: float = 0.0
    count_scales: dict = field(default_factory=dict)
    population_count: int = 0
    catalogue_fingerprint: str = ""

    def as_dict(self) -> dict[str, Any]:
        return {
            "rent_p10": self.rent_p10,
            "rent_p90": self.rent_p90,
            "sqft_p10": self.sqft_p10,
            "sqft_p33": self.sqft_p33,
            "sqft_p67": self.sqft_p67,
            "sqft_p90": self.sqft_p90,
            "count_scales": dict(self.count_scales),
            "population_count": self.population_count,
            "catalogue_fingerprint": self.catalogue_fingerprint,
        }


class FiveQuestionRecommender:
    """Python implementation wrapper around the verified V3 calibration.

    Holds the calibration restored from the snapshot plus the recommender-level
    constants the snapshot itself carries (blend weights, version string,
    low-PU caution bound). The serialized snapshot is never called for
    predictions — scoring always runs the domain rule implementation so every
    component, weight and reason is inspectable.
    """

    def __init__(
        self,
        calibration: Calibration | None = None,
        pu_weight: float = 0.7,
        preference_weight: float = 0.3,
        version: str = SCORING_CONFIG_V3_VERSION,
        low_pu_caution_bound: float = 0.2,
    ):
        self.calibration = calibration or Calibration()
        self.pu_weight = pu_weight
        self.preference_weight = preference_weight
        self.version = version
        self.low_pu_caution_bound = low_pu_caution_bound

    @property
    def domain_calibration(self) -> CalibrationV3:
        """Adopt the artifact's values into the domain calibration."""
        return CalibrationV3(
            version=self.version,
            rent_p10=self.calibration.rent_p10,
            rent_p90=self.calibration.rent_p90,
            sqft_p10=self.calibration.sqft_p10,
            sqft_p33=self.calibration.sqft_p33,
            sqft_p67=self.calibration.sqft_p67,
            sqft_p90=self.calibration.sqft_p90,
            count_scales=dict(self.calibration.count_scales),
            population_count=self.calibration.population_count,
            catalogue_fingerprint=self.calibration.catalogue_fingerprint,
            pu_weight=self.pu_weight,
            preference_weight=self.preference_weight,
            low_pu_caution_bound=self.low_pu_caution_bound,
        )

    def score_preference(
        self,
        profile: PreferenceProfile,
        candidate: PropertyCandidate,
        *,
        config: ScoringConfig | None = None,
        layer1_model: str = "pu_model",
    ) -> ScoredCandidate:
        """Score ONE candidate with the five-question V3 rules.

        Delegates to the domain engine; this wrapper exists so callers can be
        certain the calibration in use is the artifact-verified one.
        """
        calibration = self.domain_calibration
        return score_candidate_v3(
            candidate,
            profile,
            calibration=calibration,
            config=config if config is not None else SCORING_CONFIG_V3,
            layer1_model=layer1_model,
        )

    def describe(self) -> dict[str, Any]:
        return {
            "engine": "rule_based_5q_v3",
            "trained_recommender": False,
            "version": self.version,
            "pu_weight": self.pu_weight,
            "preference_weight": self.preference_weight,
            "low_pu_caution_bound": self.low_pu_caution_bound,
            "calibration_source": "RECOMMENDER_V3.joblib (serialized calibration snapshot)",
            "implementation": (
                "sitewise.domain.recommendation_scoring.score_candidate_v3 "
                "(documented reconstruction; the package's .py source was not supplied)"
            ),
            "calibration": {
                **self.calibration.as_dict(),
                "pu_weight": self.pu_weight,
                "preference_weight": self.preference_weight,
                "version": self.version,
                "low_pu_caution_bound": self.low_pu_caution_bound,
            },
        }


def _verify_against_domain(recommender: FiveQuestionRecommender) -> None:
    """Fail closed when the artifact disagrees with the documented rules.

    The domain defaults WERE derived from this snapshot; the check guards
    against either side silently drifting in a future edit. Numeric checks use
    a tight tolerance because the snapshot stores binary-float representations
    (e.g. ``5126.700000000001`` for the documented 5126.7).
    """
    expected = CalibrationV3()
    calibration = recommender.calibration
    checks = (
        ("rent_p10", calibration.rent_p10, expected.rent_p10),
        ("rent_p90", calibration.rent_p90, expected.rent_p90),
        ("sqft_p10", calibration.sqft_p10, expected.sqft_p10),
        ("sqft_p33", calibration.sqft_p33, expected.sqft_p33),
        ("sqft_p67", calibration.sqft_p67, expected.sqft_p67),
        ("sqft_p90", calibration.sqft_p90, expected.sqft_p90),
        ("population_count", calibration.population_count, expected.population_count),
        ("pu_weight", recommender.pu_weight, expected.pu_weight),
        ("preference_weight", recommender.preference_weight, expected.preference_weight),
        ("low_pu_caution_bound", recommender.low_pu_caution_bound, expected.low_pu_caution_bound),
    )
    mismatches = [
        f"{name}: artifact={got!r} domain={want!r}"
        for name, got, want in checks
        if abs(float(got) - float(want)) > 1e-6
    ]
    differing = {}
    for key in set(calibration.count_scales) | set(expected.count_scales):
        got = calibration.count_scales.get(key)
        want = expected.count_scales.get(key)
        if got is None or want is None or abs(float(got) - float(want)) > 1e-6:
            differing[key] = (got, want)
    if differing:
        mismatches.append(f"count_scales: {differing}")
    if recommender.version != expected.version:
        mismatches.append(f"version: artifact={recommender.version!r} domain={expected.version!r}")
    if not math.isclose(
        recommender.pu_weight + recommender.preference_weight, 1.0, abs_tol=1e-9
    ):
        mismatches.append("blend weights do not sum to 1.0")
    if mismatches:
        raise ModelUnavailableError(
            "Recommender V3 calibration snapshot does not match the documented "
            "rule constants: " + "; ".join(mismatches)
        )


def load_snapshot(path: str | Path | None = None) -> FiveQuestionRecommender:
    """Load and verify the calibration snapshot once per process."""
    with _SNAPSHOT_LOCK:
        return _load_cached(str(Path(path) if path is not None else SNAPSHOT_PATH))


@lru_cache(maxsize=2)
def _load_cached(path_str: str) -> FiveQuestionRecommender:
    path = Path(path_str)
    if not path.is_file():
        raise ModelUnavailableError(
            f"Recommender V3 calibration snapshot is missing: {path}"
        )
    try:
        import joblib

        # The pickle refers to top-level module 'sitewise_recommender_v3'.
        # Register THIS module under that name before deserialisation, the
        # same pattern ModelLoader uses for the PU artifacts.
        sys.modules.setdefault("sitewise_recommender_v3", sys.modules[__name__])
        artifact = joblib.load(path)
    except ModelUnavailableError:
        raise
    except Exception as exc:  # noqa: BLE001 - fail closed with a clear reason
        raise ModelUnavailableError(
            f"Unable to deserialize the Recommender V3 calibration snapshot: "
            f"{type(exc).__name__}: {exc}"
        ) from exc

    if not isinstance(artifact, FiveQuestionRecommender):
        raise ModelUnavailableError(
            "Recommender V3 snapshot has an unexpected type: "
            f"{type(artifact).__name__}"
        )
    if not isinstance(artifact.calibration, Calibration):
        raise ModelUnavailableError(
            "Recommender V3 snapshot calibration has an unexpected type: "
            f"{type(artifact.calibration).__name__}"
        )
    _verify_against_domain(artifact)
    return artifact


def calibration() -> CalibrationV3:
    """The artifact-verified domain calibration (loads the snapshot once)."""
    return load_snapshot().domain_calibration
