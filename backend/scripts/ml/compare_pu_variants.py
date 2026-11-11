"""Legacy vs experimental 47-feature PU model comparison (research evidence).

Compares, over the SAME eligible research catalogue:

* the ORIGINAL production model score stored per row
  (``sitewise_app.properties.source_data.research_p_association_score`` — the
  baseline_47 artifact's own saved output), against
* the NEW experimental bagged Histogram Gradient Boosting artifact
  (``sitewise_pu_47_experimental.joblib``, version
  ``hist_gradient_boosting@PU_47_CANDIDATE_2026_11_11``) scored LIVE from the
  exact 47-feature vector (database + committed training bridge).

Outputs ``backend/ml_reference/pu_variant_comparison_2026_11_11/``:
``comparison.json`` (distribution, differences, rank correlation, coverage),
``scores.csv`` (per-property), and prints a summary. The experimental ranking
also produces an example top-20 under one fixed five-question V3 profile.

NO superiority claim is made from these numbers: both score families are
uncalibrated P-vs-U research indices; the experimental artifact's spatial-CV
AUROC (0.76007) is in-sample research evidence, not independent validation.
"""
from __future__ import annotations

import csv
import json
import math
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

from sqlmodel import Session  # noqa: E402

from sitewise.db.analytics_session import analytics_engine  # noqa: E402
from sitewise.domain.recommendation_scoring import (  # noqa: E402
    PropertyCandidate,
    preference_profile_from,
    rank_candidates,
)
from sitewise.ml.pu_variant import experimental_prediction  # noqa: E402
from sitewise.ml.sitewise_recommender_v3 import load_snapshot  # noqa: E402
from sitewise.repositories.recommendation_candidate_repository import (  # noqa: E402
    RecommendationCandidateRepository,
)

OUT_DIR = Path(__file__).resolve().parents[2] / "ml_reference" / "pu_variant_comparison_2026_11_11"

V3_PROFILE = {
    "requirements_version": 3,
    "fnb_concept": "cafe_coffee_shop",
    "service_model": "dine_in",
    "target_customers": ["nearby_residents", "office_workers"],
    "recommendation_priority": "balanced_suitability",
    "space_size_preference": "standard_business_space",
}


def _pearson(xs, ys) -> float:
    n = len(xs)
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    vx = math.fsum((x - mx) ** 2 for x in xs) ** 0.5
    vy = math.fsum((y - my) ** 2 for y in ys) ** 0.5
    return cov / (vx * vy) if vx and vy else float("nan")


def _spearman(xs, ys) -> float:
    def ranks(values):
        ordered = sorted(range(len(values)), key=lambda i: values[i])
        out = [0.0] * len(values)
        for rank, index in enumerate(ordered):
            out[index] = float(rank + 1)
        return out

    return _pearson(ranks(xs), ranks(ys))


def _distribution(values: list[float]) -> dict:
    if not values:
        return {}
    ordered = sorted(values)
    n = len(ordered)

    def pct(p):
        return ordered[min(n - 1, max(0, int(round(p * (n - 1)))))]

    return {
        "n": n,
        "mean": round(statistics.fmean(ordered), 6),
        "median": round(statistics.median(ordered), 6),
        "min": round(ordered[0], 6),
        "p10": round(pct(0.10), 6),
        "p90": round(pct(0.90), 6),
        "max": round(ordered[-1], 6),
    }


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rows = RecommendationCandidateRepository(None)  # placeholder; replaced below

    with Session(analytics_engine) as session:
        repo = RecommendationCandidateRepository(session)
        rows = repo.list_candidates(limit=None)
        print(f"catalogue rows: {len(rows)}")

        results = []
        unavailable = []
        for index, row in enumerate(rows):
            pid = str(row.get("property_id") or "")
            legacy = row.get("pu_association_score")
            prediction = experimental_prediction(session, pid)
            entry = {
                "property_id": pid,
                "state": row.get("state"),
                "legacy_stored_score": legacy,
                "experimental_score": prediction.get("score"),
                "experimental_available": bool(prediction.get("available")),
                "model_version": prediction.get("model_version"),
            }
            if prediction.get("available"):
                entry["feature_coverage"] = (prediction.get("feature_coverage") or {}).get(
                    "available_features"
                )
                results.append(entry)
            else:
                entry["missing_features"] = (prediction.get("feature_coverage") or {}).get(
                    "missing_features", []
                )
                unavailable.append(entry)
            if (index + 1) % 100 == 0:
                print(f"  scored {index + 1}/{len(rows)}")

    paired = [
        (float(e["legacy_stored_score"]), float(e["experimental_score"]))
        for e in results
        if e.get("legacy_stored_score") is not None
        and e.get("experimental_score") is not None
    ]
    legacy_values = [x for x, _ in paired]
    exp_values = [y for _, y in paired]
    diffs = [y - x for x, y in paired]

    comparison = {
        "generated_for": "joel branch integration 2026-11-11",
        "legacy_model": {
            "source": "stored research_p_association_score (baseline_47 artifact output)",
            "distribution": _distribution(legacy_values),
        },
        "experimental_model": {
            "artifact": "sitewise_pu_47_experimental.joblib",
            "sha256": "1d09cb9a44301d1020bb367a1b3dcb1803935e853c348eccad357f0ede8fd1e2",
            "version": "hist_gradient_boosting@PU_47_CANDIDATE_2026_11_11",
            "spatial_cv_auroc": 0.76007,
            "production_ready": False,
            "landscan_provenance": "unresolved (NO_PENDING_LICENCE record flag)",
            "distribution": _distribution(exp_values),
        },
        "coverage": {
            "catalogue_rows": len(rows),
            "experimental_scored": len(results),
            "experimental_unavailable": len(unavailable),
            "paired_with_legacy": len(paired),
        },
        "score_differences": {
            "mean_abs_diff": round(statistics.fmean([abs(d) for d in diffs]), 6) if diffs else None,
            "max_abs_diff": round(max((abs(d) for d in diffs), default=0.0), 6),
            "mean_signed_diff": round(statistics.fmean(diffs), 6) if diffs else None,
        },
        "rank_correlation": {
            "pearson_r": round(_pearson(legacy_values, exp_values), 6) if paired else None,
            "spearman_rho": round(_spearman(legacy_values, exp_values), 6) if paired else None,
        },
        "interpretation": (
            "Both are uncalibrated P-vs-U research association indices on the same "
            "1,849-row training sample. Agreement metrics describe consistency, "
            "NOT correctness; the experimental artifact's spatial-CV AUROC (0.76007) "
            "is in-sample research evidence and no independent holdout exists. No "
            "superiority claim is made."
        ),
        "unavailable_examples": [
            {"property_id": e["property_id"], "missing_features": e["missing_features"][:5]}
            for e in unavailable[:10]
        ],
    }

    # Example top-20 under one fixed five-question V3 profile (research demo).
    profile = preference_profile_from(V3_PROFILE)
    recommender = load_snapshot()
    scored = []
    with Session(analytics_engine) as session:
        repo = RecommendationCandidateRepository(session)
        for row in repo.list_candidates(limit=None):
            pid = str(row.get("property_id") or "")
            match = next((e for e in results if e["property_id"] == pid), None)
            if not match:
                continue
            candidate = PropertyCandidate.from_row(
                {**row, "pu_association_score": match["experimental_score"]}
            )
            from sitewise.domain.recommendation_scoring import eligibility_failures

            if eligibility_failures(candidate, profile):
                continue
            scored.append(
                recommender.score_preference(
                    profile, candidate, layer1_model="sitewise_pu_47_experimental"
                )
            )
    ranked = rank_candidates(scored)[:20]
    top20 = [
        {
            "rank": item.rank,
            "property_id": item.property_id,
            "final_score_0_100": round(item.final_score * 100, 1),
            "pu_score_0_100": round(item.pu_association_score * 100, 1),
            "preference_fit_0_100": (
                None
                if item.preference_match_score is None
                else round(item.preference_match_score * 100, 1)
            ),
            "monthly_rental_myr": item.candidate.monthly_rental_myr,
            "built_up_sqft": item.candidate.built_up_sqft,
            "state": item.candidate.state,
        }
        for item in ranked
    ]
    comparison["example_top20_experimental_v3"] = {
        "profile": V3_PROFILE,
        "note": (
            "Research example on the experimental PU pathway with the V3 rule "
            "engine (balanced priority). Not a production ranking."
        ),
        "results": top20,
    }

    (OUT_DIR / "comparison.json").write_text(
        json.dumps(comparison, indent=2) + "\n", encoding="utf-8"
    )
    with (OUT_DIR / "scores.csv").open("w", encoding="utf-8", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=list(results[0].keys()))
        writer.writeheader()
        writer.writerows(results)

    print(json.dumps({k: comparison[k] for k in ("coverage", "score_differences", "rank_correlation")}, indent=2))
    print("top-5 experimental example:")
    for entry in top20[:5]:
        print("  ", entry)
    print(f"written: {OUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
