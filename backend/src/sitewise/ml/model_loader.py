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
import threading
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from sitewise.core.exceptions import ModelUnavailableError

ARTIFACTS_DIR = Path(__file__).resolve().parent
_NAME = re.compile(r"^[A-Za-z0-9_-]+$")

#: Process-wide deserialised-artifact cache, keyed by the artifact's exact
#: identity (path, mtime_ns, size). A replaced or edited binary changes
#: mtime/size and can never reuse the previous deserialisation, while the
#: per-request ``joblib.load`` of an unchanged artifact — measured at up to
#: 10 s on the first call of a worker process — is paid once.
_LOAD_CACHE: dict[tuple[str, int, int], "LoadedModel"] = {}
_LOAD_CACHE_LOCK = threading.Lock()


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


def _imputable_features(estimator: object, names: list[str]) -> frozenset[str]:
    """The columns this artifact's saved imputer was fitted to fill.

    Read from the fitted ``SimpleImputer(indicator_)``: ``features_`` lists
    exactly the columns that contained a missing value at fit time, which is
    the only set the artifact can accept a NaN for. Falls back to the
    residential prefix (the original artifact's contract) when the estimator
    exposes no indicator.
    """
    steps = getattr(estimator, "steps", None)
    imputer = None
    if steps:
        try:
            imputer = dict(steps).get("imputer")
        except (TypeError, ValueError):
            imputer = None
    indicator = getattr(imputer, "indicator_", None)
    columns = getattr(indicator, "features_", None)
    if columns is None:
        return frozenset(n for n in names if n.startswith("residential_"))
    return frozenset(
        names[int(index)] for index in columns if 0 <= int(index) < len(names)
    )


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
        return self._load(name, use_cache=False)

    def load_cached(self, name: str = "pu_model") -> LoadedModel:
        """``load`` with process-wide deserialisation reuse.

        Cache identity is the artifact file's (path, mtime_ns, size): a
        replaced artifact invalidates automatically, and no test that swaps
        artifacts via a different path can observe another file's model. The
        returned object must be treated as read-only — the same instance is
        shared by every caller in this process.
        """
        return self._load(name, use_cache=True)

    def _load(self, name: str, *, use_cache: bool) -> LoadedModel:
        path = self._find_artifact(name)
        cache_key = None
        if use_cache:
            try:
                stat = path.stat()
                cache_key = (str(path), stat.st_mtime_ns, stat.st_size)
            except OSError:
                cache_key = None
            if cache_key is not None:
                with _LOAD_CACHE_LOCK:
                    hit = _LOAD_CACHE.get(cache_key)
                if hit is not None:
                    return hit
        loaded = self._deserialize(name, path)
        if cache_key is not None:
            with _LOAD_CACHE_LOCK:
                _LOAD_CACHE[cache_key] = loaded
        return loaded

    def _deserialize(self, name: str, path: Path) -> LoadedModel:
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
        elif (
            isinstance(artifact, dict)
            and isinstance(artifact.get("model_info"), dict)
            and "estimators" in artifact
        ):
            # 2026-11-15 expanded PU packages: {model_info, estimators} dicts
            # with no pickled wrapper class. The shim is built in-process and
            # applies the training package's own inference recipe (mean of the
            # bagged members' positive-class probabilities). The exact feature
            # order comes from model_info["feature_names"] — never assumed.
            from sitewise.ml.pu_model_compat import PUExpandedEnsemble

            info = artifact["model_info"]
            raw_names = info.get("feature_names")
            if not isinstance(raw_names, (tuple, list)) or not raw_names:
                raise ModelUnavailableError("Bagged PU artifact feature contract is missing")
            names = [str(x) for x in raw_names]
            estimators = artifact["estimators"]
            if not isinstance(estimators, list) or not estimators:
                raise ModelUnavailableError("Bagged PU artifact has no fitted estimators")
            if not all(hasattr(e, "predict_proba") for e in estimators):
                raise ModelUnavailableError("A bagged PU estimator lacks predict_proba")
            ensemble = PUExpandedEnsemble()
            ensemble.estimators = estimators
            ensemble.estimators_ = list(estimators)  # PULearning imputer inspection
            ensemble.feature_names = names
            ensemble.n_features_in_ = len(names)
            ensemble.feature_names_in_ = names
            # The columns the saved imputer was actually fitted to track. This
            # is the artifact's own declaration of what may be missing, read
            # from the fitted ``SimpleImputer(indicator_)`` rather than guessed
            # from a name prefix: Expanded64_v2 tracks the walkway density in
            # addition to the residential measurements, and the original
            # artifact tracks only the residential ones.
            ensemble.imputable_features = _imputable_features(estimators[0], names)
            model = ensemble
            meta = {
                k: v for k, v in info.items()
                if k != "feature_names"
                and isinstance(v, (str, bool, int, float, type(None), tuple, list))
            }
            meta["artifact_type"] = "bagged_dict_2026_11_15"
        elif (
            isinstance(artifact, dict)
            and isinstance(artifact.get("metadata"), dict)
            and "category_model" in artifact
        ):
            # 2026-11-15 F&B category package: {metadata, category_model, ...}
            # The estimator is a fitted sklearn Pipeline; the exact 54-feature
            # contract (leakage-reduced: the ten competitor-count columns are
            # excluded) comes from metadata["category_feature_names"].
            info = artifact["metadata"]
            raw_names = info.get("category_feature_names")
            if not isinstance(raw_names, (tuple, list)) or not raw_names:
                raise ModelUnavailableError("Category artifact feature contract is missing")
            names = [str(x) for x in raw_names]
            model = artifact["category_model"]
            meta = {
                k: v for k, v in info.items()
                if k not in {"category_feature_names", "pu_feature_names"}
                and isinstance(v, (str, bool, int, float, type(None), tuple, list))
            }
            # The PU contract is retained for auditability without exporting a
            # 64-name list into every response.
            meta["pu_feature_count"] = len(info.get("pu_feature_names") or [])
            meta["artifact_type"] = "category_conditional_2026_11_15"
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
            meta.setdefault("artifact_type", "legacy_pickle")

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
