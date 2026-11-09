"""Run research SHAP with actual background/reference feature rows.

python -m sitewise.ml.shap_cli --features-json sample.json \
    --background-csv clean_reference_47.csv --output result.json
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

from sitewise.ml.shap_explainer import ShapExplainer


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--features-json", type=Path, required=True)
    p.add_argument("--background-csv", type=Path, required=True)
    p.add_argument("--output", type=Path)
    a = p.parse_args()
    data = json.loads(a.features_json.read_text(encoding="utf-8"))
    features = data.get("features", data)
    with a.background_csv.open(encoding="utf-8-sig", newline="") as stream:
        background = list(csv.DictReader(stream))[:101]
    result = ShapExplainer().explain(features, background=background)
    content = json.dumps(result, ensure_ascii=False, indent=2)
    if a.output:
        a.output.write_text(content, encoding="utf-8")
    else:
        print(content)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
