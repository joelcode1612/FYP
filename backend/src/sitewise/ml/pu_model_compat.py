"""Compatibility for the committed SiteWise PU artifacts.

The trusted artifacts' pickles refer to training-time classes in a module
named ``pu_model`` that is absent from the running backend. The loader
registers this module under that legacy name before deserialisation:

* ``BaggedPUClassifier``  - committed production ``PU_model.joblib`` (2026-11-09).
* ``PUScoreEnsemble``     - supplied experimental 47-feature artifact
  (``sitewise_pu_47_experimental.joblib``, bagged Histogram Gradient Boosting,
  validation version ``PU_47_CANDIDATE_2026_11_11``). The class below is a
  faithful inference-only port of the supplied ``pu_model.py``; fitting is
  deliberately not implemented.

Both outputs are *research positive-label association scores*, NOT calibrated
probabilities of commercial success and NOT validated personalized suitability
scores.
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


class PUScoreEnsemble:
    """Inference method for the experimental bagged PU artifact.

    joblib sets the fitted attributes directly: ``estimators`` (bagged
    sklearn pipelines), ``feature_names`` (the exact 47-feature training
    order), ``family``, ``score_meaning`` and ``validation``. Training is
    deliberately not implemented here; the saved estimators must be used
    without fitting or reconstructing them.
    """

    def _prepare(self, X) -> np.ndarray:
        estimators = getattr(self, "estimators", None)
        if not estimators:
            raise ValueError("Unfitted PU model")
        names = list(getattr(self, "feature_names", []))
        if hasattr(X, "columns"):
            # pandas DataFrame input: enforce the exact trained column set/order.
            missing = [n for n in names if n not in X.columns]
            if missing:
                raise ValueError("Missing required features: " + ", ".join(missing))
            frame = X.loc[:, names].apply(lambda c: __import__("pandas").to_numeric(c, errors="coerce"))
            arr = frame.to_numpy(dtype=float)
        else:
            arr = np.asarray(X, dtype=float)
            if arr.ndim != 2 or arr.shape[1] != len(names):
                raise ValueError(f"Expected {len(names)} ordered features")
        # Distances/counts/densities in this contract are nonnegative; inf and
        # negative values are data errors, never silently clamped.
        arr = np.where(np.isinf(arr), np.nan, arr)
        if np.any(np.nan_to_num(arr, nan=0.0) < 0.0):
            raise ValueError("Negative value(s) in nonnegative research features")
        return arr

    def predict_proba(self, X):
        arr = self._prepare(X)
        ps = [np.asarray(estimator.predict_proba(arr), dtype=float)[:, 1] for estimator in self.estimators]
        pos = np.clip(np.mean(ps, axis=0), 0.0, 1.0)
        return np.column_stack((1.0 - pos, pos))

    def score(self, X):
        """PU association index in [0, 1]; uncalibrated research value."""
        return self.predict_proba(X)[:, 1]

    def predict(self, X):
        # Classification cutpoint is research-only, not a business recommendation.
        return (self.score(X) >= 0.5).astype(int)
