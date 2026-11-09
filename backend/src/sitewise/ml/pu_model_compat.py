"""Compatibility for the committed 2026-11-09 PU_model.joblib.

The trusted artifact's pickle refers to ``pu_model.BaggedPUClassifier`` (a
training-time module absent from the running backend). The loader registers
this module as that legacy name before deserialisation.

The model is a bagged positive-vs-unlabelled classifier. Its output is a
*research positive-label association score*, NOT a calibrated probability of
commercial success and NOT a validated personalized suitability score.
"""
from __future__ import annotations

import numpy as np


class BaggedPUClassifier:
    """Inference method for previously fitted sklearn estimator pipelines.

    joblib sets the fitted attributes directly, including ``estimators_``.
    Training is deliberately not implemented here; the saved estimators must
    be used without fitting or reconstructing them.
    """

    def predict_proba(self, X):
        estimators = getattr(self, "estimators_", None)
        if not estimators:
            raise ValueError("Bagged PU artifact has no fitted estimators_")
        positives = []
        for estimator in estimators:
            if not hasattr(estimator, "predict_proba"):
                raise TypeError("A bagged PU estimator lacks predict_proba")
            probabilities = np.asarray(estimator.predict_proba(X), dtype=float)
            classes = getattr(estimator, "classes_", None)
            if classes is None:
                classes = getattr(estimator.steps[-1][1], "classes_", None)
            if classes is None:
                raise ValueError("A bagged PU estimator does not expose class labels")
            cls = list(classes)
            if 1 not in cls:
                raise ValueError("The positive (P) class label 1 is missing")
            positives.append(probabilities[:, cls.index(1)])
        p = np.mean(np.vstack(positives), axis=0)
        if not np.all(np.isfinite(p)) or np.any((p < 0) | (p > 1)):
            raise ValueError("Model returned invalid positive-class scores")
        return np.column_stack([1.0 - p, p])

    def predict(self, X):
        """P/U decision at the model's default 0.5 threshold, not success."""
        return (self.predict_proba(X)[:, 1] >= 0.5).astype(int)
