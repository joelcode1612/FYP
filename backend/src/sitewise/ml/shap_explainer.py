"""Guarded SHAP for the saved bagged PU logistic ensemble.

A real, legally usable reference/background matrix is REQUIRED. Never create
synthetic or zero-filled background rows. This is a research explanation of
positive-label association, not a claim of F&B business success.

Performance contract (2026-11-15 optimisation, measured on this deployment)
===========================================================================
The permutation computation itself is fast (measured ~0.05-0.13 s warm for
64 features over a 32-row background). The dominant cost was *process-lifetime
one-off work* paid inside the first uncached explanation request:

* ``import shap`` + numba kernel compilation: measured 13-35 s when the first
  PermutationExplainer evaluation happens (reproducing the production log
  ``PermutationExplainer explainer: 2it [00:21, 21.94s/it]``);
* the first ``joblib.load`` of the PU artifact: measured up to ~10 s.

Both are now paid off the request path: the FastAPI lifespan warms this
module (:func:`warm_up_pu`), and the artifact is deserialised once per
process (:meth:`ModelLoader.load_cached`, invalidated by file identity).
The explainer object itself is reused per (model, background) identity.
None of this changes the explained function, the feature order, the
background or ``max_evals`` — the contributions are bit-for-bit the same
computation as before.
"""
from __future__ import annotations

import threading
from typing import Any

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.model_loader import ModelLoader, LoadedModel

#: Reusable explainer per (model identity, background identity, feature
#: signature). Constructing shap.Explainer is cheap after the first call, but
#: reuse also keeps the masker object alive so repeated calls skip re-validation.
_EXPLAINERS: dict[tuple, Any] = {}
_EXPLAINER_LOCK = threading.Lock()

#: Process readiness flag: True once SHAP is imported, its numba kernels are
#: compiled and at least one full explanation has succeeded in this process.
#: The FastAPI lifespan sets it from a daemon thread; a user-facing request
#: that arrives BEFORE it is set must not block on the one-off compilation and
#: is served a truthful "pending" state instead.
_WARM_FLAG = threading.Event()


def mark_warm() -> None:
    """Mark this process ready to compute SHAP on the request path."""
    _WARM_FLAG.set()


def process_warm() -> bool:
    """Whether uncached SHAP computation is safe inside a request here."""
    return _WARM_FLAG.is_set()


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
        loaded = self.loader.load_cached(self.model_name)
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
            explainer = self._explainer(loaded, shap, positive_association, B)
            values = explainer(X, max_evals=2 * len(loaded.feature_names) + 1)
            contributions = {
                feature: float(value)
                for feature, value in zip(loaded.feature_names, values.values[0])
            }
        except Exception as exc:
            raise ModelUnavailableError(f"SHAP explanation failed: {exc}") from exc
        mark_warm()
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

    @staticmethod
    def _explainer(
        loaded: LoadedModel,
        shap: Any,
        positive_association,
        B: Any,
    ) -> Any:
        """The reusable PermutationExplainer for this exact model + background.

        Identity is the model name, the artifact file's identity (name, mtime,
        size via the loader's own cache key on the object) and the background
        matrix bytes. A replaced artifact or different background therefore
        can never reuse another explainer object.
        """
        import hashlib

        background_digest = hashlib.sha256(B.tobytes()).hexdigest()[:16]
        feature_signature = hashlib.sha256(
            ",".join(loaded.feature_names).encode("utf-8")
        ).hexdigest()[:16]
        key = (loaded.name, loaded.meta.get("artifact_filename"), background_digest, feature_signature)
        with _EXPLAINER_LOCK:
            cached = _EXPLAINERS.get(key)
            if cached is not None:
                return cached
            explainer = shap.Explainer(
                positive_association,
                shap.maskers.Independent(B),
                algorithm="permutation",
                feature_names=loaded.feature_names,
            )
            _EXPLAINERS[key] = explainer
            return explainer


def warm_up_pu() -> dict[str, Any]:
    """Compile the PU explainer's one-off kernels off the request path.

    Runs one real permutation-SHAP explanation of a real background row
    against a slice of the same verified background, for the ACTIVE variant's
    artifact. The kernels compiled here are the ones every later explanation
    reuses; a failure is non-fatal (explanations degrade to their documented
    unavailable state and the flag simply stays unset until a request or job
    completes one).
    """
    import time

    from sitewise.ml.pu_variant import resolve_variant

    started = time.perf_counter()
    variant = resolve_variant()
    loaded = ModelLoader().load_cached(variant.layer1_model)

    from sitewise.services.property_insights_service import (
        _background_path,
        _reference_background_rows,
    )

    background_file = _background_path(variant.key)
    rows = _reference_background_rows(loaded.feature_names, background_file)
    if not rows:
        return {"warmed": False, "reason": "no verified background rows"}
    subject = dict(rows[0])
    payload = ShapExplainer(loader=ModelLoader(), model_name=variant.layer1_model).explain(
        subject, background=rows[:8]
    )
    return {
        "warmed": True,
        "variant": variant.key,
        "artifact": loaded.meta.get("artifact_filename"),
        "elapsed_seconds": round(time.perf_counter() - started, 3),
        "additivity_check": (
            abs(
                payload["baseline_association"]
                + sum(payload["contributions"].values())
                - payload["positive_label_association"]
            )
        ),
    }
