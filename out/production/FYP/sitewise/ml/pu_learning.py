"""PU-Learning location-suitability integration path.

Verified status (2026-11-04): **no trained PU-Learning artifact exists** in
the repository, so ``PULearning.predict`` raises ``ModelUnavailableError``.
The class implements the full inference contract for when an artifact lands:

* load via :class:`sitewise.ml.model_loader.ModelLoader` (artifact + feature
  contract validation),
* validate an incoming feature dict against the trained feature order,
* run inference and normalise the output to ``PUPrediction``.

Nothing here retrains models, invents weights, or returns a default score.
"""

from __future__ import annotations

from dataclasses import dataclass

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.model_loader import LoadedModel, ModelLoader

DEFAULT_MODEL_NAME = "pu_model"


@dataclass(frozen=True)
class PUPrediction:
    property_id: int
    score: float | None
    label: int | None
    model_version: str | None
    available: bool
    reason: str | None = None


class PULearning:
    def __init__(self, loader: ModelLoader | None = None, model_name: str = DEFAULT_MODEL_NAME):
        self.loader = loader or ModelLoader()
        self.model_name = model_name
        self._loaded: LoadedModel | None = None

    def _ensure_loaded(self) -> LoadedModel:
        if self._loaded is None:
            # Raises ModelUnavailableError with the exact missing prerequisite.
            self._loaded = self.loader.load(self.model_name)
        return self._loaded

    def predict(self, property_id: int, features: dict[str, float]) -> PUPrediction:
        """Score one property's location with the trained PU model.

        ``features`` must provide every training feature; the loader's
        contract check catches missing/extra names before inference.
        """
        loaded = self._ensure_loaded()
        missing = [f for f in loaded.feature_names if f not in features]
        if missing:
            raise ModelUnavailableError(
                f"Cannot score property {property_id}: missing geospatial "
                f"features {missing}. Retrieval failures are reported, never "
                "imputed with zeros."
            )
        import numpy as np

        row = [[float(features[f]) for f in loaded.feature_names]]
        X = np.asarray(row, dtype=float)
        if hasattr(loaded.model, "predict_proba"):
            proba = loaded.model.predict_proba(X)
            score = float(proba[0][-1])
            label = int(loaded.model.predict(X)[0])
        else:
            label = int(loaded.model.predict(X)[0])
            score = None
        return PUPrediction(
            property_id=property_id,
            score=score,
            label=label,
            model_version=str(loaded.meta.get("version")) if loaded.meta else None,
            available=True,
        )

    def predict_or_report(self, property_id: int, features: dict[str, float]) -> dict:
        """Inference, or the explicit availability report (never a fake score)."""
        try:
            p = self.predict(property_id, features)
        except ModelUnavailableError as exc:
            return {
                "property_id": property_id,
                "available": False,
                "score": None,
                "reason": str(exc),
            }
        return {
            "property_id": p.property_id,
            "available": True,
            "score": p.score,
            "label": p.label,
            "model_version": p.model_version,
        }
