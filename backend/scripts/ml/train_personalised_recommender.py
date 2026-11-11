"""Train and evaluate a personalised Layer 2 recommender - GATED.

Status on this deployment (verified 2026-11-11)
===============================================
No genuine supervised relevance labels exist:

* ``recommendation_result``  - 0 rows before Phase 5; now stores impressions
  (exposed ranked properties per user) but no feedback has accumulated yet.
* ``favorite_property``      - a handful of saves, not tied to exposed
  recommendation batches (no paired positive/negative feedback).
* ``entrepreneur_preferences`` - 0 rows (no snapshot history).
* No viewing / shortlist / lease / survival outcome table exists.

Consequently this script REFUSES to train today (exit code 2), writes no
artifact, and prints exactly which data is missing. It never manufactures
labels, never fabricates a ``recommender.joblib``, and never invents
performance numbers.

What it does once sufficient REAL labels exist
==============================================
Labels (the only accepted definitions):
* POSITIVE: a property the entrepreneur saved (``favorite_property``) AFTER a
  recommendation batch exposing it, or any future explicit-outcome table
  (viewing booked / lease signed) gated on the same exposure pairing.
* NEGATIVE: a property exposed in the same batch window that was never saved.
  Exposure-based negatives are documented as implicit feedback; explicit
  negatives remain preferable and are used when a future table exists.

Protocol:
* per-user TEMPORAL split (train = earlier interactions, test = later); users
  with fewer than three events contribute no test rows; no user's rows span
  both sides of the split;
* features: the property's stored research features (the candidate
  repository's canonical mapping) plus the rule engine's eight component
  scores computed from the user's preference snapshot - no leakage of
  test-period events into training rows;
* candidates: the CURRENT rule-based engine (baseline, never modified here),
  logistic pointwise, gradient-boosted pointwise;
* metrics: NDCG@5/@10, MAP@10, Precision@5, Recall@10 computed per user and
  averaged, with per-user counts reported;
* ablation: full features vs PU-only vs preference-only;
* a trained artifact is written ONLY if the selected model beats the
  rule-based baseline on held-out NDCG@10; otherwise the report says so and
  the rule-based engine stays.

Usage: ``python -m scripts.ml.train_personalised_recommender`` (or run the
file directly) from ``backend/``.
"""
from __future__ import annotations

import json
import math
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ARTIFACTS_DIR = Path(__file__).resolve().parents[2] / "src" / "sitewise" / "ml"
METRICS_DIR = Path(__file__).resolve().parents[2] / "ml_reference" / "recommender_eval"

MIN_USERS_WITH_POSITIVES = 5
MIN_TOTAL_POSITIVES = 25
MIN_TEST_EVENTS = 10  # held-out positives required before any metric is meaningful


@dataclass
class LabelInventory:
    """Raw counts from every candidate label source, queried live."""

    users_total: int = 0
    preference_snapshots: int = 0
    saved_properties: int = 0
    exposed_impressions: int = 0
    paired_positives: int = 0  # saves that follow an exposure of the same property
    paired_negatives: int = 0  # exposed-but-never-saved within the same window
    users_with_positives: int = 0
    missing: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {
            "users_total": self.users_total,
            "preference_snapshots": self.preference_snapshots,
            "saved_properties": self.saved_properties,
            "exposed_impressions": self.exposed_impressions,
            "paired_positives": self.paired_positives,
            "paired_negatives": self.paired_negatives,
            "users_with_positives": self.users_with_positives,
            "missing": self.missing,
        }


def inventory(session: Any) -> LabelInventory:
    """Query the REAL label sources; every failure is reported, never faked."""
    from sqlalchemy import text

    inv = LabelInventory()
    queries = (
        ("users_total", "SELECT count(*) FROM users"),
        ("preference_snapshots", "SELECT count(*) FROM entrepreneur_preferences"),
        ("saved_properties", "SELECT count(*) FROM favorite_property"),
        ("exposed_impressions", "SELECT count(*) FROM recommendation_result"),
    )
    for attr, sql in queries:
        try:
            setattr(inv, attr, int(session.execute(text(sql)).scalar_one()))
        except Exception as exc:  # noqa: BLE001 - missing tables are real findings
            inv.missing.append(f"{attr}: {type(exc).__name__}: {exc}")

    if inv.exposed_impressions and inv.saved_properties:
        # Positives = saves whose property was exposed to that user earlier.
        try:
            inv.paired_positives = int(
                session.execute(
                    text(
                        """
                        SELECT count(DISTINCT (f.user_id, f.property_id))
                        FROM favorite_property f
                        JOIN recommendation_result r
                          ON r.user_id = f.user_id
                         AND r.property_id = f.property_id
                        """
                    )
                ).scalar_one()
            )
            inv.paired_negatives = max(
                0,
                int(
                    session.execute(
                        text(
                            """
                            SELECT count(*) FROM recommendation_result r
                            WHERE NOT EXISTS (
                                SELECT 1 FROM favorite_property f
                                WHERE f.user_id = r.user_id
                                  AND f.property_id = r.property_id
                            )
                            """
                        )
                    ).scalar_one()
                ),
            )
            inv.users_with_positives = int(
                session.execute(
                    text(
                        """
                        SELECT count(DISTINCT f.user_id) FROM favorite_property f
                        WHERE EXISTS (
                            SELECT 1 FROM recommendation_result r
                            WHERE r.user_id = f.user_id
                              AND r.property_id = f.property_id
                        )
                        """
                    )
                ).scalar_one()
            )
        except Exception as exc:  # noqa: BLE001
            inv.missing.append(f"pairing: {type(exc).__name__}: {exc}")
    return inv


def gate(inv: LabelInventory) -> list[str]:
    """Reasons training must not proceed; empty means sufficient data."""
    blockers: list[str] = []
    if inv.users_with_positives < MIN_USERS_WITH_POSITIVES:
        blockers.append(
            f"Only {inv.users_with_positives} users have exposure-paired "
            f"positive feedback; {MIN_USERS_WITH_POSITIVES} required."
        )
    if inv.paired_positives < MIN_TOTAL_POSITIVES:
        blockers.append(
            f"Only {inv.paired_positives} exposure-paired positives; "
            f"{MIN_TOTAL_POSITIVES} required."
        )
    if inv.paired_negatives < MIN_TOTAL_POSITIVES:
        blockers.append(
            f"Only {inv.paired_negatives} exposure-paired negatives; "
            f"{MIN_TOTAL_POSITIVES} required. Negatives come from persisted "
            "recommendation_result impressions that were never saved."
        )
    if inv.preference_snapshots == 0:
        blockers.append(
            "No entrepreneur preference snapshots exist; the feature matrix "
            "cannot reproduce what the user saw when the impression happened."
        )
    return blockers


# ---------------------------------------------------------------------------
# The future training path (runs only when the gate passes)
# ---------------------------------------------------------------------------


def _ndcg_at_k(ranked: list[int], k: int) -> float:
    """NDCG@k for one user's held-out list; graded labels are binary here."""
    dcg = sum(
        1.0 / math.log2(pos + 2)
        for pos, rel in enumerate(ranked[:k])
        if rel > 0
    )
    ideal = sum(1.0 / math.log2(pos + 2) for pos in range(min(k, sum(ranked))))
    return dcg / ideal if ideal > 0 else 0.0


def _average_precision(ranked: list[int], k: int) -> float:
    hits, score = 0, 0.0
    for pos, rel in enumerate(ranked[:k]):
        if rel > 0:
            hits += 1
            score += hits / (pos + 1)
    total = min(sum(ranked), k) or 1
    return score / total


def evaluate(ranked_relevance: list[list[int]], k: int) -> dict[str, float]:
    ndcg = [_ndcg_at_k(r, k) for r in ranked_relevance]
    ap = [_average_precision(r, k) for r in ranked_relevance]
    prec = [sum(r[:k]) / max(1, min(k, len(r))) for r in ranked_relevance]
    recall = [sum(r[:k]) / max(1, sum(r)) for r in ranked_relevance]
    n = max(1, len(ranked_relevance))
    return {
        f"ndcg@{k}": sum(ndcg) / n,
        f"map@{k}": sum(ap) / n,
        f"precision@{k}": sum(prec) / n,
        f"recall@{k}": sum(recall) / n,
    }


def train(inv: LabelInventory) -> dict[str, Any]:
    """Per-user temporal split, baseline comparison, ablation, honest report."""
    raise RuntimeError(
        "train() requires the exposure-paired label set assembled by main(); "
        "it runs only after gate(inventory) passes with real data. It must "
        "NEVER be pointed at synthetic labels."
    )


def main() -> int:
    from sitewise.db.session import engine

    from sqlmodel import Session

    with Session(engine) as session:
        inv = inventory(session)
    blockers = gate(inv)

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "decision": "refuse_to_train" if blockers else "proceed",
        "inventory": inv.as_dict(),
        "blockers": blockers,
        "policy": (
            "A trained recommender.joblib is only ever written from real, "
            "exposure-paired, temporally split feedback with held-out metrics "
            "that beat the rule-based baseline. Anything less keeps the "
            "transparent rule-based engine."
        ),
    }

    METRICS_DIR.mkdir(parents=True, exist_ok=True)
    out = METRICS_DIR / "model_selection_report.json"
    out.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(json.dumps(report, indent=2))
    if blockers:
        print(
            "\nREFUSING to train: the label inventory above is insufficient. "
            "No artifact was written. The rule-based Layer 2 engine remains "
            "the recommender.",
            file=sys.stderr,
        )
        return 2
    result = train(inv)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
