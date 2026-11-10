"""Orchestrates real research PU inference without writing to PostgreSQL."""
from __future__ import annotations

from typing import Any

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import FeatureResolutionError, PropertyFeatureRepository
from sitewise.ml.pu_learning import PULearning


class PropertyPUPredictor:
    def __init__(self, analytics_session: Any, loader: ModelLoader | None = None):
        self.repo = PropertyFeatureRepository(analytics_session)
        self.pu = PULearning(loader=loader)

    def coverage(self, property_id: str, source: str = "catalog") -> dict:
        model = self.pu._ensure_loaded()
        result = self.repo.get(property_id, model.feature_names, source=source)
        return result.as_coverage()

    def predict(self, property_id: str, source: str = "catalog") -> dict:
        """Strict: no missing-feature imputation or alternate-provider aliases."""
        loaded = self.pu._ensure_loaded()
        result = self.repo.get(property_id, loaded.feature_names, source=source)
        base = result.as_coverage()
        if result.missing_features:
            return {
                **base,
                "available": False,
                "score": None,
                "reason": "Required model features are missing; no score was generated.",
                "research_only": True,
                "score_meaning": str(loaded.meta.get("score_meaning") or "research_positive_label_association"),
            }
        out = self.pu.predict_or_report(property_id, result.values)
        return {**base, **out, "research_only": True}
