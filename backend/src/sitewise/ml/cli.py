"""CLI: python -m sitewise.ml.cli inspect|coverage|predict [arguments]."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import FeatureResolutionError, PropertyFeatureRepository
from sitewise.ml.pu_learning import PULearning


def main() -> int:
    p = argparse.ArgumentParser(description="SiteWise 47-feature research PU model")
    p.add_argument("command", choices=("inspect", "coverage", "predict"))
    p.add_argument("--property-id", help="Catalogue text id, e.g. MD-00510")
    p.add_argument("--source", choices=("catalog", "rental"), default="catalog")
    p.add_argument("--features-json", type=Path, help="JSON with exact trained feature names")
    p.add_argument("--allow-model-imputation", action="store_true",
                   help="Research only: permit trained median imputer to fill missing feature values")
    p.add_argument("--aliases", action="store_true",
                   help="Research only: allow unverified F&B competitor count aliases")
    p.add_argument("--artifact-dir", type=Path, default=None)
    args = p.parse_args()
    loader = ModelLoader(args.artifact_dir)
    try:
        loaded = loader.load()
        if args.command == "inspect":
            print(json.dumps({
                "available": True,
                "artifact": loaded.meta.get("artifact_filename"),
                "feature_set": loaded.meta.get("feature_set"),
                "model_kind": getattr(loaded.model, "kind", None),
                "bags": len(getattr(loaded.model, "estimators_", [])),
                "score_meaning": loaded.meta.get("score_meaning"),
                "experiment_tag": loaded.meta.get("experiment_tag"),
                "features": loaded.feature_names,
                "research_only": True,
            }, indent=2))
            return 0
        if not args.property_id:
            p.error("--property-id is required for coverage and prediction")
        if args.features_json:
            data = json.loads(args.features_json.read_text(encoding="utf-8"))
            features = data.get("features", data)
            if not isinstance(features, dict):
                p.error("Feature JSON must contain a dictionary or a 'features' dictionary")
            missing = [n for n in loaded.feature_names if features.get(n) is None]
            coverage = {
                "property_id": args.property_id,
                "feature_count": len(loaded.feature_names),
                "available_features": len(loaded.feature_names) - len(missing),
                "missing_features": missing,
                "source": "explicit-json",
            }
        else:
            # Use the existing read-only analytics connection from the project.
            from sqlmodel import Session
            from sitewise.db.analytics_session import analytics_engine
            with Session(analytics_engine) as session:
                bundle = PropertyFeatureRepository(session).get(
                    args.property_id, loaded.feature_names, source=args.source,
                    use_unverified_competitor_aliases=args.aliases,
                )
            features, coverage = bundle.values, bundle.as_coverage()
        if args.command == "coverage":
            print(json.dumps(coverage, indent=2))
            return 0
        if coverage["missing_features"] and not args.allow_model_imputation:
            print(json.dumps({
                **coverage, "available": False, "score": None,
                "reason": "Missing trained features; use coverage to diagnose sources."
            }, indent=2))
            return 2
        out = PULearning(loader=loader).predict_or_report(
            args.property_id, features,
            allow_model_imputation=args.allow_model_imputation,
        )
        print(json.dumps({**coverage, **out}, indent=2))
        return 0 if out["available"] else 2
    except (ModelUnavailableError, FeatureResolutionError, FileNotFoundError,
            ValueError, json.JSONDecodeError) as exc:
        print(json.dumps({"available": False, "error": str(exc)}, indent=2))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
