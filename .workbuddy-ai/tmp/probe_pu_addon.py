"""Pre-integration probe: verify both PU artifacts load and honor contracts.

The selected model is loaded from the EXTRACTED ADD-ON directory (not yet
copied into the repository) so structure verification happens before any
file lands in the repo. The original model loads from the repo as-is.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, "src")

from sitewise.ml.model_loader import ModelLoader  # noqa: E402
from sitewise.ml.pu_learning import PULearning  # noqa: E402

ADDON_ML = Path(
    "C:/Users/Lenovo/AndroidStudioProjects/FYP/.workbuddy-ai/tmp/pu_addon/"
    "backend/src/sitewise/ml"
)
EXAMPLE = Path(
    "C:/Users/Lenovo/AndroidStudioProjects/FYP/.workbuddy-ai/tmp/pu_addon/"
    "backend/ml_reference/example_property_47.json"
)

# 1. Original default model: must load and predict unchanged.
original = ModelLoader().load("pu_model")
print("ORIGINAL OK:",
      original.meta.get("artifact_filename"),
      "features:", len(original.feature_names))

# 2. Selected model: loaded via a separate loader pointed at the add-on dir.
selected = ModelLoader(artifacts_dir=ADDON_ML).load("sitewise_selected_pu_model")
print("SELECTED OK:",
      selected.meta.get("artifact_filename"),
      "features:", len(selected.feature_names),
      "feature_set:", selected.meta.get("feature_set"),
      "version:", selected.meta.get("version") or selected.meta.get("model_version"))
assert len(selected.feature_names) == 47, "selected model must have 47 features"

# 3. Example property predicts on BOTH models with the same feature vector.
import json  # noqa: E402

payload = json.loads(EXAMPLE.read_text(encoding="utf-8"))
features = payload["features"]
missing_for_selected = [f for f in selected.feature_names if features.get(f) is None]
missing_for_original = [f for f in original.feature_names if features.get(f) is None]
print("example property:", payload.get("property_id"),
      "missing for selected:", missing_for_selected,
      "missing for original:", len(missing_for_original))

sel_pred = PULearning(loader=ModelLoader(artifacts_dir=ADDON_ML),
                      model_name="sitewise_selected_pu_model").predict_or_report(
    payload["property_id"], features)
print("SELECTED prediction:", json.dumps(sel_pred, ensure_ascii=False)[:400])

if not missing_for_original:
    orig_pred = PULearning().predict_or_report(payload["property_id"], features)
    print("ORIGINAL prediction:", json.dumps(orig_pred, ensure_ascii=False)[:400])
else:
    # Score the original on the intersection of complete features is not
    # allowed (no fabrication); report honestly instead.
    print("ORIGINAL cannot score this example:",
          f"{len(missing_for_original)} of its features are absent "
          "(different feature contract) - expected, contracts differ")

# 4. SHAP smoke test with the add-on background CSV against the selected model.
import csv  # noqa: E402

from sitewise.ml.shap_explainer import ShapExplainer  # noqa: E402

bg_path = ADDON_ML.parents[2] / "ml_reference" / "shap_background_47.csv"
with bg_path.open(encoding="utf-8-sig", newline="") as fp:
    background = list(csv.DictReader(fp))
print("background rows:", len(background))
expl = ShapExplainer(
    loader=ModelLoader(artifacts_dir=ADDON_ML),
    model_name="sitewise_selected_pu_model",
).explain(features, background=background)

score = float(expl["positive_label_association"])
baseline = float(expl["baseline_association"])
total = sum(float(v) for v in expl["contributions"].values())
print(f"score={score:.6f} baseline={baseline:.6f} "
      f"sum(contributions)={total:.6f} reconstruction_err={abs(baseline + total - score):.2e}")

top_pos = sorted(expl["contributions"].items(), key=lambda kv: -kv[1])[:3]
top_neg = sorted(expl["contributions"].items(), key=lambda kv: kv[1])[:3]
print("top positive:", top_pos)
print("top negative:", top_neg)
