"""Baseline SHAP latency measurement (pre-optimization), per the performance brief.

Measures, on the live deployment configuration (expanded64 variant):

1. Model artifact load (ModelLoader.load) — paid on EVERY request today.
2. Raw ensemble inference on the exact row count one SHAP explanation feeds
   the model (max_evals x background rows).
3. ``import shap`` (first-call, cold process) — paid once per worker.
4. ``ShapExplainer.explain`` for real catalogue properties (MD-00510,
   MD-01755) against the verified 64-feature background — the call that
   produced the ``21.94s/it`` production log.
5. Full ``PropertyInsightsService.insights`` cold-cache and warm-cache.

Run: backend/.venv/Scripts/python backend/scripts/benchmarks/bench_shap_baseline.py
Output: JSON on stdout + a one-line-per-step human log on stderr.
"""
from __future__ import annotations

import json
import statistics
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SRC = REPO / "backend" / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

RESULTS: dict[str, object] = {}


def step(name: str, started: float, extra: dict | None = None) -> None:
    elapsed = time.perf_counter() - started
    print(f"{name}: {elapsed:.3f}s" + (f"  {extra}" if extra else ""), file=sys.stderr)
    RESULTS.setdefault("steps", {})[name] = {"seconds": round(elapsed, 4), **(extra or {})}
    return elapsed


def timed(name: str, fn, extra: dict | None = None, repeats: int = 1):
    """Run fn once per repeat, recording each duration; return last result."""
    durations: list[float] = []
    result = None
    for i in range(repeats):
        start = time.perf_counter()
        result = fn()
        durations.append(time.perf_counter() - start)
    stats = {
        "durations_s": [round(d, 4) for d in durations],
        "median_s": round(statistics.median(durations), 4),
    }
    print(f"{name}: {stats}" + (f"  {extra}" if extra else ""), file=sys.stderr)
    RESULTS.setdefault("steps", {})[name] = {**stats, **(extra or {})}
    return result


def main() -> None:
    from sitewise.ml.model_loader import ModelLoader
    from sitewise.ml.pu_expanded import EXPANDED_MODEL_NAME

    # 1. Artifact load cost, paid per request today.
    loaded = timed("model_load_expanded64", lambda: ModelLoader().load(EXPANDED_MODEL_NAME), repeats=3)
    timed("model_load_pu_model", lambda: ModelLoader().load("pu_model"), repeats=2)

    # 2. Raw inference on the exact SHAP evaluation volume (129 masks x 100 bg).
    import numpy as np

    n_features = len(loaded.feature_names)
    max_evals = 2 * n_features + 1
    background_rows = 100
    volume = max_evals * background_rows
    rng = np.random.default_rng(20261115)
    probe = np.abs(rng.normal(size=(volume, n_features)))
    timed(
        "ensemble_predict_proba_shap_volume",
        lambda: loaded.model.predict_proba(probe),
        extra={"rows": volume, "features": n_features, "max_evals": max_evals},
    )

    # 3-5 need the analytics DB and one real property's resolved features.
    from sitewise.core.config import Settings
    from sitewise.db.analytics_session import analytics_engine
    from sitewise.ml.property_features import PropertyFeatureRepository
    from sitewise.ml.shap_explainer import ShapExplainer
    from sitewise.services.property_insights_service import PropertyInsightsService
    from sqlmodel import Session

    with Session(analytics_engine) as session:
        # Resolve the real feature vector for the benchmark properties.
        vectors: dict[str, dict[str, float]] = {}
        from sitewise.ml.feature_bridge import merge_bridge_features
        from sitewise.ml.pu_expanded import merge_expanded_bridge_features

        for pid in ("MD-00510", "MD-01755"):
            try:
                bundle = PropertyFeatureRepository(session).get(
                    pid, loaded.feature_names, source="catalog"
                )
                coverage = merge_bridge_features(bundle, expected_features=loaded.feature_names)
                coverage = merge_expanded_bridge_features(
                    coverage, expected_features=loaded.feature_names
                )
            except Exception as exc:  # noqa: BLE001 - report, do not crash the bench
                RESULTS.setdefault("feature_resolution", {})[pid] = f"unresolved: {exc}"
                continue
            values = {k: v for k, v in coverage.values.items() if v is not None}
            missing = list(coverage.missing_features)
            vectors[pid] = values
            RESULTS.setdefault("feature_resolution", {})[pid] = {
                "resolved": len(values),
                "missing": len(missing),
            }
            print(f"{pid}: resolved {len(values)}/{n_features}, missing {len(missing)}", file=sys.stderr)

        # 3. First-call SHAP import cost (cold process), measured once.
        start = time.perf_counter()
        import shap  # noqa: F401

        step("import_shap_cold", start)

        # Background exactly as the insights service builds it.
        from sitewise.services.property_insights_service import (
            PropertyInsightsService,
            _background_path,
        )

        background_file = _background_path("expanded64")
        background = PropertyInsightsService._reference_background(
            loaded.feature_names, background_file
        )
        RESULTS["background"] = {
            "file": background_file.name,
            "rows": len(background),
        }

        # 4. The production ShapExplainer call, per property, twice each
        #    (first may include one-time explainer-construction overhead).
        for pid, values in vectors.items():
            if len(values) != n_features:
                continue
            explainer = ShapExplainer(loader=ModelLoader(), model_name=EXPANDED_MODEL_NAME)
            timed(
                f"shap_explain_{pid}_run1",
                lambda v=values: explainer.explain(v, background=background),
                extra={"features": n_features, "background_rows": len(background)},
            )
            timed(
                f"shap_explain_{pid}_run2",
                lambda v=values: explainer.explain(v, background=background),
            )

        # 5. Full insights service, cold-cache then warm-cache.
        import sitewise.services.property_insights_service as insights_module

        service = PropertyInsightsService(session=session, analytics_session=session)
        insights_module.clear_insights_cache()
        for pid in vectors:
            timed(f"insights_{pid}_cold", lambda p=pid: service.insights(p))
            timed(f"insights_{pid}_warm", lambda p=pid: service.insights(p))

    RESULTS["config"] = {
        "variant": Settings().pu_model_variant,
        "artifact": loaded.meta.get("artifact_filename"),
        "feature_count": n_features,
    }
    print(json.dumps(RESULTS, indent=2, default=str))


if __name__ == "__main__":
    main()
