"""Backwards-compatible SiteWise PU artifact loader.

Priority for the default model:
1. backend/src/sitewise/ml/PU_model.joblib (real latest-main artifact)
2. legacy pu_model.pkl + pu_model_features.json under a configured directory

The new artifact is a dict with keys ``model``, ``features``, ``feature_set``,
``score_meaning`` and research metadata. Never infer a training feature order
from database column order. Only load trusted joblib files: pickle can execute
arbitrary Python code when deserialised.
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from sitewise.core.exceptions import ModelUnavailableError

ARTIFACTS_DIR = Path(__file__).resolve().parent
_NAME = re.compile(r"^[A-Za-z0-9_-]+$")


@dataclass(frozen=True)
class LoadedModel:
    name: str
    model: object
    feature_names: list[str]
    meta: dict


def _validate_feature_names(actual: list[str], expected: list[str]) -> None:
    if actual == expected:
        return
    missing = [x for x in expected if x not in actual]
    extra = [x for x in actual if x not in expected]
    raise ModelUnavailableError(
        f"Feature contract mismatch: missing={missing}, unexpected={extra}, "
        "or the feature order differs from the trained estimator"
    )


def _model_feature_count(model: object) -> int | None:
    count = getattr(model, "n_features_in_", None)
    if count is None:
        estimators = getattr(model, "estimators_", [])
        if estimators:
            count = getattr(estimators[0], "n_features_in_", None)
    return int(count) if count is not None else None


class ModelLoader:
    def __init__(self, artifacts_dir: Path | str | None = None):
        self.artifacts_dir = Path(artifacts_dir) if artifacts_dir is not None else ARTIFACTS_DIR

    def _find_artifact(self, name: str) -> Path:
        if not _NAME.fullmatch(name):
            raise ModelUnavailableError("Invalid ML artifact name")
        choices = []
        if name == "pu_model":
            choices.append(self.artifacts_dir / "PU_model.joblib")
        choices += [self.artifacts_dir / f"{name}.joblib", self.artifacts_dir / f"{name}.pkl"]
        if name == "pu_model":
            choices += [self.artifacts_dir / "artifacts" / "pu_model.pkl"]
        for path in choices:
            if path.is_file():
                return path
        raise ModelUnavailableError(
            "No trained model artifact found. Expected 'PU_model.joblib' at "
            f"'{self.artifacts_dir}' or the legacy {name}.pkl."
        )

    def load(self, name: str = "pu_model") -> LoadedModel:
        path = self._find_artifact(name)
        try:
            import joblib
            # Required by the committed pickle: global pu_model.BaggedPUClassifier.
            from sitewise.ml import pu_model_compat
            existing = sys.modules.get("pu_model")
            if existing is not None and not hasattr(existing, "BaggedPUClassifier"):
                raise ModelUnavailableError("An incompatible pu_model module is already loaded")
            sys.modules.setdefault("pu_model", pu_model_compat)
            artifact = joblib.load(path)
        except ModelUnavailableError:
            raise
        except Exception as exc:
            raise ModelUnavailableError(
                f"Unable to deserialize trusted PU artifact: {type(exc).__name__}: {exc}"
            ) from exc

        if isinstance(artifact, dict) and "model" in artifact:
            model = artifact["model"]
            raw_names = artifact.get("features")
            if not isinstance(raw_names, (tuple, list)):
                raise ModelUnavailableError("PU artifact feature contract is missing")
            names = list(raw_names)
            meta = {
                k: v for k, v in artifact.items()
                if k not in {"model", "features"}
                and isinstance(v, (str, bool, int, float, type(None), tuple, list))
            }
            meta["artifact_type"] = "bundled_joblib"
        else:
            model = artifact
            features_path = path.with_name(f"{name}_features.json")
            meta_path = path.with_name(f"{name}_meta.json")
            if not features_path.is_file():
                raise ModelUnavailableError("The legacy model feature contract is missing")
            try:
                names = list(json.loads(features_path.read_text(encoding="utf-8"))["features"])
                meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.is_file() else {}
            except (OSError, KeyError, ValueError, TypeError) as exc:
                raise ModelUnavailableError("The legacy feature contract cannot be parsed") from exc
            meta["artifact_type"] = "legacy_pickle"

        if not names or any(not isinstance(x, str) or not x.strip() for x in names):
            raise ModelUnavailableError("Artifact feature names are invalid")
        if len(names) != len(set(names)):
            raise ModelUnavailableError("Artifact feature names contain duplicates")
        trained = getattr(model, "feature_names_in_", None)
        if trained is not None:
            _validate_feature_names([str(x) for x in trained], names)
        model_count = _model_feature_count(model)
        if model_count is not None and model_count != len(names):
            raise ModelUnavailableError(
                f"Model expects {model_count} inputs but artifact declares {len(names)} features"
            )
        if not hasattr(model, "predict_proba"):
            raise ModelUnavailableError("The saved PU model has no predict_proba method")
        meta["feature_count"] = len(names)
        meta["artifact_filename"] = path.name
        return LoadedModel(name=name, model=model, feature_names=names, meta=meta)


@lru_cache(maxsize=8)
def cached_loader(artifacts_dir: str | None = None) -> ModelLoader:
    return ModelLoader(artifacts_dir)
