"""Model artifact loading (infrastructure).

Verified status (2026-11-04): **no trained model artifacts exist** anywhere in
the repository (searched for ``*.pkl`` / ``*.joblib`` / ``*.onnx`` /
``*model*.json``). The loader below is the real integration path: the moment
an artifact is placed at the configured path it is loaded, cached, and its
feature contract validated. Until then every load raises
``ModelUnavailableError`` - callers report that state instead of fabricating
predictions.

Expected artifact layout (documented contract for the future training run):

    backend/ml/artifacts/
        pu_model.pkl        joblib dump with ``predict_proba`` or ``predict``
        pu_features.json    {"features": [...]} - exact training feature order
        model_meta.json     {"version": "...", "trained_on": "...",
                             "notes": "..."}

The feature list file is deliberately separate so the loader can validate a
request's feature vector against the trained order BEFORE inference - the
classic silent-failure mode is a model receiving shuffled columns.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from sitewise.core.exceptions import ModelUnavailableError

ARTIFACTS_DIR = Path(__file__).resolve().parent.parent / "ml" / "artifacts"


@dataclass(frozen=True)
class LoadedModel:
    name: str
    model: object
    feature_names: list[str]
    meta: dict


def _validate_feature_names(requested: list[str], expected: list[str]) -> None:
    missing = [f for f in expected if f not in requested]
    extra = [f for f in requested if f not in expected]
    if missing or extra:
        raise ModelUnavailableError(
            "Feature contract mismatch: "
            + (f"missing={missing} " if missing else "")
            + (f"unexpected={extra}" if extra else "")
        )


class ModelLoader:
    """Loads and caches a joblib-serialized model plus its feature contract."""

    def __init__(self, artifacts_dir: Path | str | None = None):
        self.artifacts_dir = Path(artifacts_dir) if artifacts_dir else ARTIFACTS_DIR

    def load(self, name: str = "pu_model") -> LoadedModel:
        model_path = self.artifacts_dir / f"{name}.pkl"
        features_path = self.artifacts_dir / f"{name}_features.json"
        meta_path = self.artifacts_dir / f"{name}_meta.json"

        if not model_path.exists():
            raise ModelUnavailableError(
                f"No trained model artifact at '{model_path}'. Place the "
                "joblib-dumped PU-Learning model there (see module docstring "
                "for the expected layout); predictions are not fabricated "
                "while it is absent."
            )
        if not features_path.exists():
            raise ModelUnavailableError(
                f"The model artifact exists but its feature contract "
                f"'{features_path.name}' is missing; refusing to guess the "
                "training feature order."
            )

        import joblib

        model = joblib.load(model_path)
        feature_names = list(json.loads(features_path.read_text())["features"])
        meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
        if hasattr(model, "feature_names_in_"):
            trained = [str(f) for f in model.feature_names_in_]
            _validate_feature_names(trained, feature_names)
        return LoadedModel(name=name, model=model, feature_names=feature_names, meta=meta)


@lru_cache(maxsize=8)
def cached_loader(artifacts_dir: str | None = None) -> ModelLoader:
    return ModelLoader(artifacts_dir)
