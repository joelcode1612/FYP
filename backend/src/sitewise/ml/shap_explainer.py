"""SHAP explanation integration path.

Verified status (2026-11-04): **no trained model artifact exists**, so there
is nothing to explain yet; additionally the ``shap`` package is not a
declared backend dependency. :class:`ShapExplainer` implements the guarded
integration: it loads a model through the loader, lazily imports ``shap``,
and raises explicit availability errors instead of degrading silently.

Per the task rules, SHAP is only engaged when the trained model supports it
(tree-based models explain cleanly; linear/kernel models need different
explainers - the loader's meta dict should record ``explainer_type``).
"""

from __future__ import annotations

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.model_loader import ModelLoader

DEFAULT_MODEL_NAME = "pu_model"


class ShapExplainer:
    def __init__(self, loader: ModelLoader | None = None, model_name: str = DEFAULT_MODEL_NAME):
        self.loader = loader or ModelLoader()
        self.model_name = model_name

    def explain(self, features: dict[str, float]) -> dict:
        """Return per-feature SHAP contributions for one feature vector."""
        try:
            import shap  # noqa: F401
        except ImportError as exc:  # pragma: no cover - environment-dependent
            raise ModelUnavailableError(
                "The 'shap' package is not installed; explanations are "
                "unavailable. It is intentionally not a hard dependency "
                "because no model artifact exists to explain yet."
            ) from exc

        loaded = self.loader.load(self.model_name)  # ModelUnavailableError if absent
        import numpy as np

        X = np.asarray(
            [[float(features[f]) for f in loaded.feature_names]], dtype=float
        )
        explainer_type = (loaded.meta or {}).get("explainer_type", "TreeExplainer")
        try:
            import shap

            explainer = getattr(shap, explainer_type)(loaded.model)
            values = explainer(X)
            contributions = {
                name: float(value)
                for name, value in zip(loaded.feature_names, values[0].values)
            }
        except Exception as exc:
            raise ModelUnavailableError(
                f"SHAP explanation failed for explainer '{explainer_type}': {exc}"
            ) from exc
        return {
            "model": self.model_name,
            "explainer": explainer_type,
            "contributions": contributions,
        }
