"""Contract layer for the retrained category-aware recommendation artifact.

The 2026-11-15 retrain ships ONE joblib bundle with three top-level keys::

    {
      "metadata":       {...},   # version, 54/64 feature names, validation rows
      "category_model": Pipeline, # median imputer -> HistGradientBoosting (54)
      "pu_estimators":  [5 x fitted logistic pipelines],  # general P-vs-U (64)
    }

That shape is deliberately NOT fed through :class:`sitewise.ml.model_loader.ModelLoader`.
The generic loader answers "which single estimator scores this property?" and
discards everything else; this bundle carries two independent estimators whose
feature contracts must stay bound together, plus the provenance the UI has to
show. Loading it through the generic loader would silently drop
``pu_estimators`` and make the general PU explanation impossible.

What this module guarantees
===========================
* **One load per worker.** ``load_bundle`` is ``lru_cache``d; the artifact is
  deserialised once, not once per request. ``joblib.load`` executes code, so
  only the repository-tracked path is accepted — a caller cannot point it at an
  arbitrary file.
* **The artifact's own feature order.** ``metadata.category_feature_names`` and
  ``metadata.pu_feature_names`` are the contract. They are validated for
  length (54 / 64), uniqueness and agreement with the fitted estimator's
  ``feature_names_in_``. No database column order is ever inferred.
* **Both stages stay separate.** ``pu_association`` returns the mean
  positive-class probability of the five bagged PU estimators (the package's own
  inference recipe); ``category_probabilities`` returns the four conditional
  class outputs. Neither is a success probability and the two are never summed.
* **Genuine SHAP or nothing.** Explanations are permutation SHAP against real
  background rows from the package. ``base_value + sum(contributions)`` must
  reconstruct the explained output within :data:`ADDITIVITY_TOLERANCE` (1e-5,
  the package's own tolerance); otherwise ``ModelUnavailableError`` is raised
  and the caller reports the explanation as unavailable. No value is invented.
* **Category SHAP follows the ENTREPRENEUR'S choice.** ``explain_category``
  takes the selected class index, so a Café selection explains the Café output
  even when Restaurant scores higher.

Research-only. ``metadata["research_only"]`` is asserted at load time, and the
selected model's geographic holdout results (macro-F1 0.289, balanced accuracy
0.292 against a 0.25 chance level) travel with every payload so no caller can
present the output as a validated best-business-type prediction.
"""
from __future__ import annotations

import csv
import hashlib
import math
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

from sitewise.core.exceptions import ModelUnavailableError

#: Repository-tracked artifact. Never accept a caller-supplied path: joblib
#: deserialisation executes arbitrary code.
BUNDLE_PATH = Path(__file__).resolve().parent / "sitewise_fnb_category_v2.joblib"

#: Provenance package installed alongside the backend (model card, evidence
#: CSVs and the exact SHAP backgrounds the artifact was validated with).
PACKAGE_DIR = (
    Path(__file__).resolve().parents[3] / "ml_reference" / "category_aware_retrain_2026_11_15"
)
CATEGORY_BACKGROUND_CSV = PACKAGE_DIR / "SHAP_Background_Category_54.csv"
PU_BACKGROUND_CSV = PACKAGE_DIR / "SHAP_Background_PU_64.csv"

#: The package's own additivity tolerance (``recommend_and_explain.py``).
ADDITIVITY_TOLERANCE = 1e-5

#: Package contract sizes. Asserted, never assumed.
CATEGORY_FEATURE_COUNT = 54
PU_FEATURE_COUNT = 64

#: Canonical classes in the artifact's class order.
CATEGORIES: tuple[str, ...] = (
    "Bakery / Dessert / Beverage",
    "Cafe / Coffee",
    "Fast Food / Takeaway",
    "Restaurant",
)

#: The ten competitor-count columns the category model excludes (self-inclusion
#: leakage control). Reported as local context only, never as model input.
EXCLUDED_COMPETITOR_FEATURES: tuple[str, ...] = (
    "fnb_competitors_500m",
    "fnb_competitors_1000m",
    "cafe_count_500m",
    "cafe_count_1000m",
    "restaurant_count_500m",
    "restaurant_count_1000m",
    "fast_food_count_500m",
    "fast_food_count_1000m",
    "bakery_dessert_beverage_count_500m",
    "bakery_dessert_beverage_count_1000m",
)

SCORE_MEANING = (
    "Exploratory resemblance to the location characteristics of observed "
    "operating F&B outlets in this category. NOT a probability of success, "
    "profitability, or a validated 'best business type'."
)

PU_SCORE_MEANING = (
    "Uncalibrated Positive-vs-Unlabelled association index: how closely this "
    "location's measured characteristics resemble the operating F&B sites the "
    "model learned from. NOT a probability of commercial success."
)


@dataclass(frozen=True)
class CategoryBundle:
    """The validated, in-memory form of the retrained artifact."""

    category_model: Any
    pu_estimators: tuple[Any, ...]
    category_features: tuple[str, ...]
    pu_features: tuple[str, ...]
    meta: Mapping[str, Any]
    version: str
    sha256: str
    path: Path

    @property
    def classes(self) -> tuple[str, ...]:
        return tuple(str(c) for c in self.category_model.classes_)

    @property
    def research_only(self) -> bool:
        return bool(self.meta.get("research_only", False))

    def identity(self) -> dict[str, Any]:
        """Artifact identity for API responses and cache keys."""
        return {
            "name": str(self.meta.get("name") or self.path.stem),
            "version": self.version,
            "artifact": self.path.name,
            "artifact_sha256": self.sha256,
            "category_feature_count": len(self.category_features),
            "pu_feature_count": len(self.pu_features),
            "pu_estimator_count": len(self.pu_estimators),
            "research_only": self.research_only,
            "production_ready": bool(self.meta.get("production_ready", False)),
            "selected_model": self.meta.get("selected_model"),
        }


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _feature_contract(raw: Any, expected_count: int, label: str) -> tuple[str, ...]:
    if not isinstance(raw, (list, tuple)) or not raw:
        raise ModelUnavailableError(f"The {label} feature contract is missing from the artifact")
    names = tuple(str(x) for x in raw)
    if len(names) != expected_count:
        raise ModelUnavailableError(
            f"The {label} contract declares {len(names)} features; the package requires "
            f"{expected_count}"
        )
    if any(not name.strip() for name in names):
        raise ModelUnavailableError(f"The {label} feature contract contains an empty name")
    if len(set(names)) != len(names):
        raise ModelUnavailableError(f"The {label} feature contract contains duplicates")
    return names


def _validate_against_estimator(model: Any, names: Sequence[str], label: str) -> None:
    trained = getattr(model, "feature_names_in_", None)
    if trained is None:
        count = getattr(model, "n_features_in_", None)
        if count is not None and int(count) != len(names):
            raise ModelUnavailableError(
                f"The {label} estimator expects {count} inputs but the contract declares "
                f"{len(names)} features"
            )
        return
    actual = [str(x) for x in trained]
    if actual != list(names):
        missing = [n for n in names if n not in actual]
        extra = [n for n in actual if n not in names]
        raise ModelUnavailableError(
            f"The {label} estimator was trained on a different feature order: "
            f"missing={missing}, unexpected={extra}"
        )


@lru_cache(maxsize=1)
def load_bundle() -> CategoryBundle:
    """Load and validate the retrained artifact exactly once per worker."""
    path = BUNDLE_PATH
    if not path.is_file():
        raise ModelUnavailableError(
            f"The category-aware research artifact is missing: {path.name}"
        )
    try:
        import joblib

        artifact = joblib.load(path)  # TRUSTED repository artifact only
    except ModelUnavailableError:
        raise
    except Exception as exc:
        raise ModelUnavailableError(
            f"Unable to deserialize the category-aware artifact: {type(exc).__name__}: {exc}"
        ) from exc

    if not isinstance(artifact, dict) or not {
        "metadata",
        "category_model",
        "pu_estimators",
    }.issubset(artifact):
        raise ModelUnavailableError(
            "This is not a SiteWise category-aware research artifact: expected "
            "'metadata', 'category_model' and 'pu_estimators'."
        )

    meta = artifact["metadata"]
    if not isinstance(meta, dict):
        raise ModelUnavailableError("The artifact metadata is not a mapping")
    if meta.get("research_only") is not True:
        raise ModelUnavailableError("The artifact is not marked research-only; refusing to serve it")

    category_model = artifact["category_model"]
    if not hasattr(category_model, "predict_proba") or not hasattr(category_model, "classes_"):
        raise ModelUnavailableError("The category estimator has no predict_proba/classes_")

    estimators = artifact["pu_estimators"]
    if not isinstance(estimators, (list, tuple)) or not estimators:
        raise ModelUnavailableError("The artifact carries no general PU estimators")
    if not all(hasattr(e, "predict_proba") for e in estimators):
        raise ModelUnavailableError("A general PU estimator has no predict_proba")

    category_features = _feature_contract(
        meta.get("category_feature_names"), CATEGORY_FEATURE_COUNT, "category (54-feature)"
    )
    pu_features = _feature_contract(
        meta.get("pu_feature_names"), PU_FEATURE_COUNT, "general PU (64-feature)"
    )
    _validate_against_estimator(category_model, category_features, "category")

    declared = tuple(str(c) for c in (meta.get("categories") or ()))
    trained_classes = tuple(str(c) for c in category_model.classes_)
    if declared and set(declared) != set(trained_classes):
        raise ModelUnavailableError(
            f"The artifact declares categories {declared} but the estimator was fitted on "
            f"{trained_classes}"
        )

    return CategoryBundle(
        category_model=category_model,
        pu_estimators=tuple(estimators),
        category_features=category_features,
        pu_features=pu_features,
        meta=meta,
        version=str(meta.get("version") or "unknown"),
        sha256=_sha256(path),
        path=path,
    )


# ---------------------------------------------------------------------------
# Background samples
# ---------------------------------------------------------------------------


@lru_cache(maxsize=2)
def _load_background(path: str, features: tuple[str, ...]) -> tuple[tuple[float, ...], ...]:
    """Real, complete background rows in the exact contract order."""
    source = Path(path)
    if not source.is_file():
        raise ModelUnavailableError(f"The SHAP background is missing: {source.name}")
    rows: list[tuple[float, ...]] = []
    with source.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        if not reader.fieldnames or not set(features).issubset(reader.fieldnames):
            raise ModelUnavailableError(
                f"The SHAP background {source.name} does not carry every contract feature"
            )
        for record in reader:
            try:
                row = tuple(float(record[name]) for name in features)
            except (KeyError, TypeError, ValueError):
                continue
            if all(math.isfinite(value) for value in row):
                rows.append(row)
    if not rows:
        raise ModelUnavailableError(
            f"The SHAP background {source.name} has no complete rows"
        )
    return tuple(rows[:100])


def category_background(bundle: CategoryBundle | None = None) -> tuple[tuple[float, ...], ...]:
    bundle = bundle or load_bundle()
    return _load_background(str(CATEGORY_BACKGROUND_CSV), bundle.category_features)


def pu_background(bundle: CategoryBundle | None = None) -> tuple[tuple[float, ...], ...]:
    bundle = bundle or load_bundle()
    return _load_background(str(PU_BACKGROUND_CSV), bundle.pu_features)


# ---------------------------------------------------------------------------
# Inference
# ---------------------------------------------------------------------------


def _vector(values: Mapping[str, Any], names: Sequence[str], label: str) -> list[float]:
    missing = [name for name in names if values.get(name) is None]
    if missing:
        raise ModelUnavailableError(
            f"The {label} model requires {len(missing)} unresolved feature(s): "
            + ", ".join(missing)
        )
    vector: list[float] = []
    for name in names:
        value = values.get(name)
        if isinstance(value, bool):
            raise ModelUnavailableError(f"Feature {name} must be numeric, not boolean")
        try:
            number = float(value)  # type: ignore[arg-type]
        except (TypeError, ValueError) as exc:
            raise ModelUnavailableError(f"Feature {name} must be numeric") from exc
        if not math.isfinite(number):
            raise ModelUnavailableError(f"Feature {name} must be finite")
        vector.append(number)
    return vector


def pu_association(values: Mapping[str, Any], bundle: CategoryBundle | None = None) -> float:
    """Mean positive-class probability of the five bagged general PU estimators."""
    bundle = bundle or load_bundle()
    import numpy as np

    x = np.asarray([_vector(values, bundle.pu_features, "general PU (64-feature)")], dtype=float)
    scores = [float(model.predict_proba(x)[0, 1]) for model in bundle.pu_estimators]
    return float(np.mean(scores))


def category_probabilities(
    values: Mapping[str, Any], bundle: CategoryBundle | None = None
) -> dict[str, float]:
    """The four conditional category outputs for one resolved vector."""
    bundle = bundle or load_bundle()
    import numpy as np

    x = np.asarray(
        [_vector(values, bundle.category_features, "category (54-feature)")], dtype=float
    )
    probabilities = np.asarray(bundle.category_model.predict_proba(x), dtype=float)
    classes = bundle.classes
    if probabilities.shape != (1, len(classes)):
        raise ModelUnavailableError(
            f"Unexpected category predict_proba shape {probabilities.shape}"
        )
    return {cls: float(probabilities[0, i]) for i, cls in enumerate(classes)}


# ---------------------------------------------------------------------------
# SHAP
# ---------------------------------------------------------------------------


def _explain(
    *,
    predict,
    x_row: Sequence[float],
    background: Sequence[Sequence[float]],
    feature_names: Sequence[str],
    label: str,
) -> dict[str, Any]:
    """Permutation SHAP with the package's additivity check (1e-5)."""
    try:
        import numpy as np
        import shap
    except ImportError as exc:  # pragma: no cover - environment guard
        raise ModelUnavailableError("Install SHAP and numpy for explanations") from exc

    x = np.asarray([list(x_row)], dtype=float)
    b = np.asarray([list(row) for row in background], dtype=float)
    if not np.all(np.isfinite(x)) or not np.all(np.isfinite(b)):
        raise ModelUnavailableError("SHAP inputs contain non-finite values")

    try:
        explainer = shap.Explainer(
            predict,
            shap.maskers.Independent(b),
            algorithm="permutation",
            feature_names=list(feature_names),
        )
        explanation = explainer(x, max_evals=2 * len(feature_names) + 1)
        values = np.asarray(explanation.values[0], dtype=float).reshape(-1)
        base = float(np.asarray(explanation.base_values[0], dtype=float).reshape(-1)[0])
        output = float(np.asarray(predict(x), dtype=float).reshape(-1)[0])
    except ModelUnavailableError:
        raise
    except Exception as exc:
        raise ModelUnavailableError(f"{label} SHAP failed: {type(exc).__name__}: {exc}") from exc

    reconstructed = base + float(np.sum(values))
    error = abs(reconstructed - output)
    if not math.isfinite(error) or error > ADDITIVITY_TOLERANCE:
        raise ModelUnavailableError(
            f"{label} SHAP failed its additivity check: baseline {base:.9f} + "
            f"contributions {reconstructed:.9f} != output {output:.9f} "
            f"(error {error:.3e} > {ADDITIVITY_TOLERANCE:g})"
        )

    ordered = sorted(
        ((name, float(values[i])) for i, name in enumerate(feature_names)),
        key=lambda kv: -abs(kv[1]),
    )
    return {
        "explainer": "Permutation SHAP",
        "model_output": output,
        "base_value": base,
        "reconstructed": reconstructed,
        "additivity_error": error,
        "additivity_tolerance": ADDITIVITY_TOLERANCE,
        "background_size": len(background),
        "feature_count": len(feature_names),
        "contributions": [{"technical": name, "contribution": value} for name, value in ordered],
    }


def explain_category(
    values: Mapping[str, Any],
    business_type: str,
    bundle: CategoryBundle | None = None,
) -> dict[str, Any]:
    """SHAP for the SELECTED category's class output (54 features).

    Explains the entrepreneur's chosen class, never the model's top class, so a
    Café selection returns Café contributions even when Restaurant scores
    higher.
    """
    bundle = bundle or load_bundle()
    classes = bundle.classes
    if business_type not in classes:
        raise ModelUnavailableError(
            f"'{business_type}' is not one of the model's categories: {list(classes)}"
        )
    index = classes.index(business_type)
    model = bundle.category_model
    x_row = _vector(values, bundle.category_features, "category (54-feature)")
    background = category_background(bundle)

    def predict(rows):
        return model.predict_proba(rows)[:, index]

    payload = _explain(
        predict=predict,
        x_row=x_row,
        background=background,
        feature_names=bundle.category_features,
        label=f"{business_type} category",
    )
    payload.update(
        {
            "target": business_type,
            "target_kind": "selected_business_type",
            "score_type": "conditional_category_association_not_success_probability",
            "model_version": bundle.version,
            "artifact_sha256": bundle.sha256,
            "research_only": True,
            "score_meaning": SCORE_MEANING,
        }
    )
    return payload


def explain_pu(
    values: Mapping[str, Any], bundle: CategoryBundle | None = None
) -> dict[str, Any]:
    """SHAP for the general 64-feature P-vs-U association."""
    bundle = bundle or load_bundle()
    import numpy as np

    estimators = bundle.pu_estimators
    x_row = _vector(values, bundle.pu_features, "general PU (64-feature)")
    background = pu_background(bundle)

    def predict(rows):
        return np.mean([model.predict_proba(rows)[:, 1] for model in estimators], axis=0)

    payload = _explain(
        predict=predict,
        x_row=x_row,
        background=background,
        feature_names=bundle.pu_features,
        label="General PU (64-feature)",
    )
    payload.update(
        {
            "target": "General F&B P-vs-U association",
            "target_kind": "general_pu",
            "score_type": "pu_research_association_not_success_probability",
            "model_version": bundle.version,
            "artifact_sha256": bundle.sha256,
            "research_only": True,
            "score_meaning": PU_SCORE_MEANING,
        }
    )
    return payload


# ---------------------------------------------------------------------------
# Validation evidence
# ---------------------------------------------------------------------------


def validation_summary(bundle: CategoryBundle | None = None) -> dict[str, Any]:
    """The selected model's geographic holdout results, read from the artifact."""
    bundle = bundle or load_bundle()
    selected = str(bundle.meta.get("selected_model") or "")
    rows = bundle.meta.get("validation") or bundle.meta.get("model_comparison") or []
    chosen: dict[str, Any] | None = None
    if isinstance(rows, Iterable):
        for item in rows:
            if (
                isinstance(item, Mapping)
                and item.get("split") == "geographic_grid"
                and item.get("model") == selected
            ):
                chosen = dict(item)
                break
    per_category: dict[str, Any] = {}
    counts = bundle.meta.get("category_counts")
    if isinstance(counts, Mapping):
        per_category = {str(k): int(v) for k, v in counts.items() if isinstance(v, int)}
    return {
        "split": "geographic_grid (4 x 0.12 degree spatial blocks)",
        "selected_model": selected or None,
        "macro_f1": (chosen or {}).get("macro_f1"),
        "balanced_accuracy": (chosen or {}).get("balanced_accuracy"),
        "top2_accuracy": (chosen or {}).get("top2_accuracy"),
        "accuracy": (chosen or {}).get("accuracy"),
        "chance_balanced_accuracy": 0.25,
        "n_folds": (chosen or {}).get("n_folds"),
        "trained_category_counts": per_category,
        "status": "weak_discrimination_research_only",
        "note": (
            "Balanced accuracy is only modestly above the 25% chance level for four "
            "categories; category rankings are exploratory location-pattern evidence."
        ),
    }


# ---------------------------------------------------------------------------
# Cache helper
# ---------------------------------------------------------------------------


def cache_token(bundle: CategoryBundle | None = None, business_type: str | None = None) -> str:
    """Identity for any cache that stores per-property category results.

    Model version + artifact checksum + selected business type: a replaced
    artifact or a different entrepreneur selection can never reuse an entry.
    """
    bundle = bundle or load_bundle()
    return f"{bundle.version}:{bundle.sha256[:16]}:{business_type or 'top'}"


def warm_up() -> dict[str, Any]:
    """Import SHAP and compile its kernels once, off the request path.

    Called from the FastAPI lifespan in a daemon thread. It explains a real
    background observation against a small slice of the same background, which
    is enough to exercise the full permutation path without touching the
    database or a user's property.
    """
    import time

    started = time.perf_counter()
    bundle = load_bundle()
    background = category_background(bundle)
    sample = background[0]
    model = bundle.category_model

    def predict(rows):
        return model.predict_proba(rows)[:, 0]

    payload = _explain(
        predict=predict,
        x_row=sample,
        background=background[:8],
        feature_names=bundle.category_features,
        label="Warm-up",
    )
    return {
        "version": bundle.version,
        "artifact_sha256": bundle.sha256,
        "elapsed_seconds": round(time.perf_counter() - started, 3),
        "additivity_error": payload["additivity_error"],
    }

