"""Side-by-side ORIGINAL vs SELECTED PU predictions on REAL supplied inputs.

Inputs: the add-on's real complete-case example property (MD-00510) and the
25 real training observations in the supplied SHAP background CSV. All are
real feature vectors with the exact 47-feature contract; nothing is
fabricated. Also demonstrates the fail-closed behaviour on one database-
resolved property (pre-existing analytics data duplication).
"""

from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

sys.path.insert(0, "src")

from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import (
    FeatureResolutionError,
    PropertyFeatureRepository,
)
from sitewise.ml.pu_learning import PULearning

BACKEND = Path(__file__).resolve().parents[2] / "backend"
EXAMPLE = BACKEND / "ml_reference" / "example_property_47.json"
BACKGROUND = BACKEND / "ml_reference" / "shap_background_47.csv"

original = PULearning()
selected = PULearning(model_name="sitewise_selected_pu_model")

rows: list[tuple[str, dict]] = []
payload = json.loads(EXAMPLE.read_text(encoding="utf-8"))
rows.append((str(payload["property_id"]), payload["features"]))
with BACKGROUND.open(encoding="utf-8-sig", newline="") as fp:
    for i, row in enumerate(csv.DictReader(fp), start=1):
        rows.append((f"background#{i}", dict(row)))

same = 0
diff = 0
print(f"{'input':<15} {'original':>9} {'selected':>9}  label")
for name, features in rows:
    o = original.predict_or_report(name, features)
    s = selected.predict_or_report(name, features)
    if o["available"] and s["available"]:
        marker = "=" if abs(o["score"] - s["score"]) < 1e-9 else "!"
        same += marker == "="
        diff += marker == "!"
        print(f"{name:<15} {o['score']:>9.6f} {s['score']:>9.6f}  "
              f"orig_label={o['label']} sel_label={s['label']} {marker}")
    else:
        print(f"{name:<15} {str(o.get('reason', ''))[:40]}")
print(f"\nidentical scores: {same}, differing scores: {diff}, total: {len(rows)}")

# Fail-closed demonstration on a database-resolved property (pre-existing
# analytics duplication; the API returns the same controlled error).
names = ModelLoader().load("pu_model").feature_names
with Session(analytics_engine) as session:
    try:
        bundle = PropertyFeatureRepository(session).get(
            "EP-01051", names, source="catalog"
        )
        print("DB resolution unexpectedly succeeded:", bundle.missing_features)
    except FeatureResolutionError as exc:
        print(f"DB-resolved EP-01051 fails closed as designed: {exc}")
