"""Guarded SHAP for the saved bagged PU logistic ensemble.

A real, legally usable reference/background matrix is REQUIRED. Never create
synthetic or zero-filled background rows. This is a research explanation of
positive-label association, not a claim of F&B business success.
"""
from __future__ import annotations

from typing import Any

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.model_loader import ModelLoader


class ShapExplainer:
    def __init__(self, loader: ModelLoader | None = None, model_name: str = "pu_model"):
        self.loader = loader or ModelLoader()
        self.model_name = model_name

    def explain(
        self,
        features: dict[str, float],
        *,
        background: list[dict[str, float]] | None = None,
    ) -> dict:
        loaded = self.loader.load(self.model_name)
        if not background:
            raise ModelUnavailableError(
                "SHAP requires real background samples with the exact training features. "
                "None were supplied."
            )
        try:
            import numpy as np
            import shap
        except ImportError as exc:
            raise ModelUnavailableError("Install SHAP and numpy for explanations") from exc

        def vector(row: dict[str, Any]) -> list[float]:
            missing = [f for f in loaded.feature_names if row.get(f) is None]
            if missing:
                raise ModelUnavailableError(f"SHAP background or subject is missing {missing}")
            return [float(row[name]) for name in loaded.feature_names]

        if len(background) > 100:
            raise ModelUnavailableError("Provide up to 100 representative background observations")
        X = np.asarray([vector(features)], dtype=float)
        B = np.asarray([vector(r) for r in background], dtype=float)
        if not np.all(np.isfinite(X)) or not np.all(np.isfinite(B)):
            raise ModelUnavailableError("SHAP inputs contain nonfinite values")

        def positive_association(rows):
            return np.asarray(loaded.model.predict_proba(rows), dtype=float)[:, 1]

        try:
            explainer = shap.Explainer(
                positive_association,
                shap.maskers.Independent(B),
                algorithm="permutation",
                feature_names=loaded.feature_names,
            )
            values = explainer(X, max_evals=2 * len(loaded.feature_names) + 1)
            contributions = {
                feature: float(value)
                for feature, value in zip(loaded.feature_names, values.values[0])
            }
        except Exception as exc:
            raise ModelUnavailableError(f"SHAP explanation failed: {exc}") from exc
        return {
            "model": self.model_name,
            "explainer": "Permutation SHAP",
            "research_only": True,
            "score_meaning": loaded.meta.get("score_meaning"),
            "positive_label_association": float(positive_association(X)[0]),
            "baseline_association": float(values.base_values[0]),
            "contributions": contributions,
            "background_size": len(background),
        }
