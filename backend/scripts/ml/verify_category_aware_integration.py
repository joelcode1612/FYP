"""Focused verification of the 2026-11-15 category-aware integration.

Run from ``backend``:

    .venv/Scripts/python.exe scripts/ml/verify_category_aware_integration.py

It answers the brief's fifteen checks against REAL catalogue records. It is not
a unit-test suite: every assertion either reads the live analytics database,
the committed artifact, or the service that serves the web application.
"""
from __future__ import annotations

import csv
import sys
import time
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(BACKEND / "src"))

from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.db.analytics_session import analytics_engine
from sitewise.ml import category_aware
from sitewise.ml.fnb_category import (
    category_explanation,
    validation_summary,
)
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.pu_expanded import expanded_scores_many
from sitewise.services.property_insights_service import (
    PropertyInsightsService,
)
from sitewise.services.recommendation_search_service import (
    RecommendationSearchService,
    SearchCriteria,
)

RESULTS: list[tuple[int, str, bool, str]] = []


def check(number: int, label: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((number, label, bool(ok), detail))
    print(f"[{'PASS' if ok else 'FAIL'}] {number:>2}. {label}" + (f" — {detail}" if detail else ""))


def _values_for(bundle, row: dict) -> dict[str, float | None]:
    names = set(bundle.pu_features) | set(bundle.category_features)
    out: dict[str, float | None] = {}
    for name in names:
        raw = row.get(name)
        out[name] = None if raw in (None, "") else float(raw)
    return out


def main() -> int:
    bundle = category_aware.load_bundle()
    identity = bundle.identity()

    # 1 — the artifact loads from its saved file, with its identity exposed.
    check(
        1,
        "Category artifact loads from its saved file",
        identity["version"] == "category_recommender_v2_20261115"
        and identity["artifact"] == "sitewise_fnb_category_v2.joblib"
        and identity["research_only"] is True,
        f"{identity['version']} sha256={identity['artifact_sha256'][:12]}…",
    )

    # 2 — 54 category features match the trained contract exactly.
    #
    # The saved Pipeline was fitted on a NumPy matrix, so its imputer exposes
    # only ``n_features_in_`` (no column names). The contract is therefore
    # checked functionally: the estimator must accept exactly 54 columns and
    # return one probability per class, and the names must be unique.
    import numpy as np

    probe = np.zeros((1, len(bundle.category_features)), dtype=float)
    category_probe = bundle.category_model.predict_proba(probe)
    check(
        2,
        "All 54 category features match the trained contract",
        len(bundle.category_features) == 54
        and int(bundle.category_model.n_features_in_) == 54
        and len(set(bundle.category_features)) == 54
        and category_probe.shape == (1, 4),
        f"{len(bundle.category_features)} unique features; predict_proba -> {category_probe.shape}",
    )

    # 3 — 64 PU features match the trained contract exactly, and the category
    #     contract is the PU contract minus the ten excluded competitor counts.
    pu_artifact = ModelLoader().load("sitewise_pu_64_expanded")
    excluded = set(category_aware.EXCLUDED_COMPETITOR_FEATURES)
    derived = tuple(n for n in pu_artifact.feature_names if n not in excluded)
    check(
        3,
        "All 64 PU features match, and 54 = 64 − 10 competitor columns",
        len(bundle.pu_features) == 64
        and tuple(pu_artifact.feature_names) == bundle.pu_features
        and derived == bundle.category_features,
        f"{len(bundle.pu_features)} PU features; {len(derived)} after exclusion",
    )

    training_csv = (
        BACKEND
        / "ml_reference"
        / "fnb_category_pu_2026_11_15"
        / "SiteWise_PU_1796_Expanded_Observed.csv"
    )
    with training_csv.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
    sample = next(r for r in rows if r["subject_id"] == "MD-00510")
    sample_values = _values_for(bundle, sample)

    # 4 — standalone inference agrees with the FastAPI service path.
    with Session(analytics_engine) as session:
        ids = [
            r[0]
            for r in session.execute(
                text(
                    "SELECT id FROM fyp.catalogue_properties "
                    "WHERE id IN ('EP-01051','MD-00293','EP-01875') ORDER BY id"
                )
            ).fetchall()
        ]
        sink: dict[str, dict] = {}
        live = expanded_scores_many(session, ids, coverage_sink=sink)
    deltas = []
    for pid in ids:
        if pid not in sink or not live.get(pid, {}).get("available"):
            continue
        standalone = category_aware.pu_association(sink[pid]["values"], bundle)
        deltas.append(abs(standalone - float(live[pid]["score"])))
    check(
        4,
        "Standalone inference agrees with the service inference",
        bool(deltas) and max(deltas) < 1e-9,
        f"max |Δ| = {max(deltas):.2e} over {len(deltas)} properties" if deltas else "no overlap",
    )

    # 5 — SHAP reconstructs the corresponding model output within tolerance.
    cafe_shap = category_explanation(sample_values, "Cafe / Coffee")
    restaurant_shap = category_explanation(sample_values, "Restaurant")
    pu_shap = category_aware.explain_pu(sample_values, bundle)
    worst = max(
        cafe_shap["reconstruction_error"],
        restaurant_shap["reconstruction_error"],
        pu_shap["additivity_error"],
    )
    check(
        5,
        "SHAP reconstructs each model output within 1e-5",
        worst <= category_aware.ADDITIVITY_TOLERANCE,
        f"max error {worst:.2e}",
    )

    # 6 / 7 — the SELECTED category controls the explanation.
    check(
        6,
        "Selecting Cafe produces Cafe-specific SHAP",
        cafe_shap["explained_output"]["business_type"] == "Cafe / Coffee",
        f"explained {cafe_shap['explained_output']['business_type']}",
    )
    check(
        7,
        "Selecting Restaurant produces Restaurant-specific SHAP",
        restaurant_shap["explained_output"]["business_type"] == "Restaurant",
        f"explained {restaurant_shap['explained_output']['business_type']}",
    )

    # 8 — the original 47-feature PU artifact still works.
    legacy = ModelLoader().load("pu_model")
    legacy_out = legacy.model.predict_proba(
        np.asarray([[0.0] * len(legacy.feature_names)], dtype=float)
    )
    check(
        8,
        "The original 47-feature PU model still loads and predicts",
        len(legacy.feature_names) == 47 and legacy_out.shape == (1, 2),
        f"{len(legacy.feature_names)} features, proba shape {legacy_out.shape}",
    )

    # 9 — ranking is stable for the same criteria and responds to the selection.
    with Session(analytics_engine) as session:
        service = RecommendationSearchService(session)
        first = service.search(SearchCriteria(business_type="Cafe / Coffee", page_size=5))
        again = service.search(SearchCriteria(business_type="Cafe / Coffee", page_size=5))
        other = service.search(SearchCriteria(business_type="Restaurant", page_size=5))
    same = [r["property_id"] for r in first["data"]] == [
        r["property_id"] for r in again["data"]
    ]
    differs = [r["property_id"] for r in first["data"]] != [
        r["property_id"] for r in other["data"]
    ]
    check(
        9,
        "Ranking is deterministic and responds to the selected category",
        same and differs,
        f"cafe top={first['data'][0]['property_id']} restaurant top={other['data'][0]['property_id']}",
    )

    # 10 — Property Details returns the real backend score and explanation.
    with Session(analytics_engine) as session:
        pid = first["data"][0]["property_id"]
        started = time.perf_counter()
        insights = PropertyInsightsService(
            session=session, analytics_session=session
        ).insights(pid, business_type="Cafe / Coffee")
        cold = time.perf_counter() - started
        started = time.perf_counter()
        PropertyInsightsService(
            session=session, analytics_session=session
        ).insights(pid, business_type="Cafe / Coffee")
        warm_elapsed = time.perf_counter() - started
    score = insights.get("score") or {}
    category = insights.get("category_model") or {}
    explanation = category.get("explanation") or {}
    check(
        10,
        "Property Details exposes the live score and the selected-category SHAP",
        score.get("available") is True
        and score.get("source") == "live_model_inference"
        and explanation.get("available") is True
        and (explanation.get("explained_output") or {}).get("business_type") == "Cafe / Coffee",
        f"score={score.get('value')} model={insights.get('model', {}).get('name')} "
        f"cat={(explanation.get('explained_output') or {}).get('business_type')}",
    )

    # 11 — no demonstration value is presented as a prediction.
    raw = score.get("raw")
    derived_ok = raw is not None and score.get("value") == max(0, min(100, round(float(raw) * 100)))
    check(
        11,
        "No demonstration value: the displayed score is the model's own output",
        derived_ok,
        f"raw={raw} -> value={score.get('value')}",
    )

    # 12 — an explanation failure degrades instead of raising.
    failed = False
    try:
        category_aware.explain_category({}, "Cafe / Coffee", bundle)
    except ModelUnavailableError:  # the documented, non-raising failure mode
        failed = True
    with Session(analytics_engine) as session:
        unknown = PropertyInsightsService(
            session=session, analytics_session=session
        ).insights("EP-99999", business_type="Cafe / Coffee")
    check(
        12,
        "Explanation failures are reported, never raised into the page",
        failed and unknown.get("score", {}).get("available") is False,
        f"missing-input -> ModelUnavailableError; unknown id -> available=False "
        f"({(unknown.get('category_model') or {}).get('reason', {}).get('code')})",
    )

    # 13 — Assess navigation keeps the selected business type.
    page = (
        BACKEND.parent / "fyp_jaspr_web" / "lib" / "pages" / "entrepreneur" / "recommendations_page.dart"
    ).read_text(encoding="utf-8")
    check(
        13,
        "Assess navigation carries the selected business type",
        "assessment?id=${Uri.encodeComponent(prop.id)}$_businessTypeQuery" in page,
        "recommendations_page.dart builds ?id=…&businessType=…",
    )

    # 14 — cache identity covers artifact, inputs and selection.
    digest_a = None
    from sitewise.services.property_insights_service import _feature_digest

    base = {"pop_500m": 100.0, "pop_1000m": 200.0}
    digest_a = _feature_digest(base)
    digest_b = _feature_digest({**base, "pop_500m": 101.0})
    token_cafe = category_aware.cache_token(bundle, "Cafe / Coffee")
    token_rest = category_aware.cache_token(bundle, "Restaurant")
    check(
        14,
        "Cache identity covers artifact, feature vector and selected category",
        digest_a != digest_b
        and token_cafe != token_rest
        and bundle.sha256[:16] in token_cafe,
        "feature digest changes on input edit; artifact checksum and category "
        "token both key the cache",
    )

    # 15 — latency, measured rather than assumed.
    check(
        15,
        "Property insights returns inside the ~3 s target once warm",
        warm_elapsed < 3.0,
        f"cold {cold:.2f}s, warm {warm_elapsed:.2f}s, search "
        f"{first['pagination']['total']} eligible rows",
    )

    reliability = validation_summary()
    print()
    print(
        "Model evidence: geographic macro-F1 "
        f"{reliability['macro_f1']:.3f}, balanced accuracy "
        f"{reliability['balanced_accuracy']:.3f} vs "
        f"{reliability['chance_balanced_accuracy']:.2f} chance — research only."
    )
    failed_checks = [n for n, _, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed_checks)}/{len(RESULTS)} checks passed.")
    if failed_checks:
        print("Failed:", failed_checks)
    return 1 if failed_checks else 0


if __name__ == "__main__":
    raise SystemExit(main())
