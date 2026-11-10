"""Research-only inference using the committed bagged P/U artifact.

A score measures positive F&B outlet association in the sampled P/U dataset.
It is NOT a calibrated business-success probability and must not substitute
for premises suitability or personalized Q1–Q5 recommendation rules.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.model_loader import LoadedModel, ModelLoader

DEFAULT_MODEL_NAME = "pu_model"


@dataclass(frozen=True)
class PUPrediction:
    property_id: str | int
    score: float | None
    label: int | None
    model_version: str | None
    available: bool
    reason: str | None = None
    missing_features: tuple[str, ...] = ()
    score_meaning: str = "research_positive_label_association_NOT_business_success_probability"


def _permits_model_imputation(model: object) -> bool:
    bags = getattr(model, "estimators_", None)
    if bags:
        return all("imputer" in getattr(b, "named_steps", {}) for b in bags)
    return "imputer" in getattr(model, "named_steps", {})


class PULearning:
    def __init__(self, loader: ModelLoader | None = None, model_name: str = DEFAULT_MODEL_NAME):
        self.loader = loader or ModelLoader()
        self.model_name = model_name
        self._loaded: LoadedModel | None = None

    def _ensure_loaded(self) -> LoadedModel:
        if self._loaded is None:
            self._loaded = self.loader.load(self.model_name)
        return self._loaded

    def predict(
        self,
        property_id: str | int,
        features: dict[str, Any],
        *,
        allow_model_imputation: bool = False,
    ) -> PUPrediction:
        loaded = self._ensure_loaded()
        if not isinstance(features, dict):
            raise ModelUnavailableError("Model inputs must be a feature-name dictionary")
        missing = [n for n in loaded.feature_names if features.get(n) is None]
        if missing and not allow_model_imputation:
            raise ModelUnavailableError(
                f"Cannot score property {property_id}: missing geospatial features {missing}"
            )
        if missing and not _permits_model_imputation(loaded.model):
            raise ModelUnavailableError("Model has missing features but no fitted imputer")

        import numpy as np
        values = []
        for n in loaded.feature_names:
            v = features.get(n)
            if v is None:
                values.append(float("nan"))
            elif isinstance(v, bool):
                raise ModelUnavailableError(f"Feature {n} must be numeric, not boolean")
            else:
                try:
                    f = float(v)
                except (TypeError, ValueError) as exc:
                    raise ModelUnavailableError(f"Feature {n} must be numeric") from exc
                if not math.isfinite(f):
                    raise ModelUnavailableError(f"Feature {n} must be finite or explicitly missing")
                values.append(f)
        X = np.asarray([values], dtype=float)
        try:
            probs = np.asarray(loaded.model.predict_proba(X), dtype=float)
            if probs.shape != (1, 2):
                raise ValueError(f"Unexpected predict_proba shape {probs.shape}")
            score = float(probs[0, 1])
            if not math.isfinite(score) or not 0 <= score <= 1:
                raise ValueError("Positive-association score is out of bounds")
            labels = loaded.model.predict(X) if hasattr(loaded.model, "predict") else None
            label = int(labels[0]) if labels is not None else None
        except (ValueError, TypeError, IndexError) as exc:
            raise ModelUnavailableError(f"PU inference failed: {exc}") from exc
        return PUPrediction(
            property_id=property_id,
            score=score,
            label=label,
            model_version=str(loaded.meta.get("version") or loaded.meta.get("feature_set") or "unspecified"),
            available=True,
            missing_features=tuple(missing),
            score_meaning=str(loaded.meta.get("score_meaning") or PUPrediction.score_meaning),
        )

    def predict_or_report(
        self,
        property_id: str | int,
        features: dict[str, Any],
        *,
        allow_model_imputation: bool = False,
    ) -> dict:
        try:
            p = self.predict(property_id, features, allow_model_imputation=allow_model_imputation)
        except ModelUnavailableError as exc:
            return {
                "property_id": property_id,
                "available": False,
                "score": None,
                "reason": str(exc),
                "score_meaning": "research_positive_label_association_NOT_business_success_probability",
                "research_only": True,
            }
        return {
            "property_id": p.property_id,
            "available": True,
            "score": p.score,
            "label": p.label,
            "model_version": p.model_version,
            "score_meaning": p.score_meaning,
            "research_only": True,
            "missing_features": list(p.missing_features),
        }
