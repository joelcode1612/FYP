"""Reproduce the SiteWise F&B category model (54 features, research-only).

Run from backend/ with the project virtual environment:

    .venv/Scripts/python.exe scripts/ml/retrain_fnb_category.py

This is the repository-adapted port of the supplied ``train_category_pu.py``.
It replaces the packaging-only ``artifact_tool`` Excel reader with openpyxl and
uses the SAME inputs, feature contracts, folds, seeds and model
hyper-parameters, so the resulting metrics can be compared directly with the
supplied audit (``SiteWise_Category_Training_Audit.json``).

What it proves
==============
* the category labels join exactly onto the 1,796-record expanded feature
  matrix (IDs, coordinates, P/U labels);
* the 54-feature contract is leakage-reduced: the ten F&B competitor-count
  columns are excluded because a P outlet may appear in its own competitor
  inventory;
* the reported validation figures are reproducible on identical geographic
  folds with the installed scikit-learn version (1.8.0).

It does NOT overwrite the supplied artifacts: outputs go to ``--out``
(default ``backend/var/ml/category_reproduction``) for comparison.

Research-only: category resemblance among OBSERVED operating F&B outlets is
not a success probability, a profitability forecast or a validated "best
business type" recommendation. U records stay unlabelled.
"""
from __future__ import annotations

import argparse
import collections
import csv
import json
import math
from pathlib import Path

import joblib
import numpy as np
import openpyxl
from sklearn.base import clone
from sklearn.dummy import DummyClassifier
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    accuracy_score,
    balanced_accuracy_score,
    f1_score,
    log_loss,
    top_k_accuracy_score,
)
from sklearn.model_selection import GroupShuffleSplit, LeaveOneGroupOut
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

BACKEND_DIR = Path(__file__).resolve().parents[2]
PACKAGE = BACKEND_DIR / "ml_reference" / "fnb_category_pu_2026_11_15"
DEFAULT_XLSX = PACKAGE / "SiteWise_PU_1796_With_Known_Business_Types.xlsx"
DEFAULT_CSV = PACKAGE / "SiteWise_PU_1796_Expanded_Observed.csv"
DEFAULT_PU = PACKAGE / "SiteWise_PU_64_Logistic_expanded_age_residential_64_ResearchOnly.joblib"
DEFAULT_OUT = BACKEND_DIR / "var" / "ml" / "category_reproduction"

CATEGORIES = ("Bakery / Dessert / Beverage", "Cafe / Coffee", "Fast Food / Takeaway", "Restaurant")
COMPETITOR_COLUMNS = {
    "fnb_competitors_500m", "fnb_competitors_1000m",
    "cafe_count_500m", "cafe_count_1000m", "restaurant_count_500m", "restaurant_count_1000m",
    "fast_food_count_500m", "fast_food_count_1000m",
    "bakery_dessert_beverage_count_500m", "bakery_dessert_beverage_count_1000m",
}


def numeric(value) -> float:
    try:
        if value is None or str(value).strip() == "":
            return float("nan")
        f = float(value)
        return f if np.isfinite(f) else float("nan")
    except (ValueError, TypeError):
        return float("nan")


def read_labels(path: Path) -> dict[str, dict]:
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    ws = wb["Complete PU 1796"]
    rows = ws.iter_rows(min_row=1, values_only=True)
    header = list(next(rows))
    idx = {name: i for i, name in enumerate(header)}
    required = ["subject_id", "sample_class", "business_type", "latitude", "longitude"]
    if any(k not in idx for k in required):
        raise ValueError("Category workbook missing required columns")
    labels: dict[str, dict] = {}
    for cells in rows:
        if cells[idx["subject_id"]] is None:
            continue
        subject = str(cells[idx["subject_id"]]).strip()
        if subject in labels:
            raise ValueError("Duplicate subject_id in Excel: " + subject)
        labels[subject] = {
            "sample_class": str(cells[idx["sample_class"]]).strip(),
            "business_type": cells[idx["business_type"]] or None,
            "latitude": numeric(cells[idx["latitude"]]),
            "longitude": numeric(cells[idx["longitude"]]),
        }
    wb.close()
    if len(labels) != 1796:
        raise ValueError(f"Unexpected Excel row count {len(labels)}")
    return labels


def model_candidates() -> dict[str, object]:
    return {
        "dummy_prior": DummyClassifier(strategy="prior"),
        "logistic_original34": Pipeline([
            ("imputer", SimpleImputer(strategy="median", add_indicator=True)),
            ("scale", StandardScaler()),
            ("classifier", LogisticRegression(C=0.5, class_weight="balanced", max_iter=500, random_state=20261115)),
        ]),
        "logistic_expanded54": Pipeline([
            ("imputer", SimpleImputer(strategy="median", add_indicator=True)),
            ("scale", StandardScaler()),
            ("classifier", LogisticRegression(C=0.5, class_weight="balanced", max_iter=500, random_state=20261115)),
        ]),
        "histboost_expanded54": Pipeline([
            ("imputer", SimpleImputer(strategy="median")),
            ("classifier", HistGradientBoostingClassifier(
                max_iter=110, max_leaf_nodes=9, l2_regularization=5,
                learning_rate=0.06, random_state=20261115,
            )),
        ]),
    }


def metrics(y, proba, classes) -> dict:
    ix = np.argmax(proba, axis=1)
    pred = classes[ix]
    return dict(
        accuracy=float(accuracy_score(y, pred)),
        macro_f1=float(f1_score(y, pred, labels=list(CATEGORIES), average="macro", zero_division=0)),
        balanced_accuracy=float(balanced_accuracy_score(y, pred)),
        top2_accuracy=float(top_k_accuracy_score(y, proba, k=2, labels=list(classes))),
        log_loss=float(log_loss(y, proba, labels=list(classes))),
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input-xlsx", default=str(DEFAULT_XLSX))
    ap.add_argument("--expanded-csv", default=str(DEFAULT_CSV))
    ap.add_argument("--pu-model", default=str(DEFAULT_PU))
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    labels = read_labels(Path(args.input_xlsx))
    pu = joblib.load(args.pu_model)  # trusted local artifact only
    all64 = list(pu["model_info"]["feature_names"])
    if len(all64) != 64 or len(set(all64)) != 64:
        raise ValueError("PU 64-feature contract mismatch")

    expanded: list[dict] = []
    with open(args.expanded_csv, encoding="utf-8-sig", newline="") as f:
        rd = csv.DictReader(f)
        if not set(all64).issubset(rd.fieldnames):
            raise ValueError("Expanded CSV missing actual PU features")
        expanded = list(rd)
    if len(expanded) != 1796 or len({row["subject_id"] for row in expanded}) != 1796:
        raise ValueError("Expanded 1796 CSV lacks exact unique IDs")
    if set(labels) != {row["subject_id"] for row in expanded}:
        raise ValueError("Exact category Excel + expanded feature CSV IDs differ")
    for row in expanded:
        lab = labels[row["subject_id"]]
        if row["sample_class"] != lab["sample_class"]:
            raise ValueError("P/U source label conflict")
        if abs(float(row["latitude"]) - lab["latitude"]) > 0.00001 or abs(
            float(row["longitude"]) - lab["longitude"]
        ) > 0.00001:
            raise ValueError("Coordinate conflict: " + row["subject_id"])

    base44 = [s for s in all64 if not s.startswith("pop_age_") and not s.startswith("residential_")]
    if len(base44) != 44:
        raise ValueError(f"Expected 44 retained base features, got {len(base44)}")
    feats34 = [s for s in base44 if s not in COMPETITOR_COLUMNS]
    feats54 = [s for s in all64 if s not in COMPETITOR_COLUMNS]
    if len(feats34) != 34 or len(feats54) != 54:
        raise ValueError("Category predictor should use 34 and 54 leakage-reduced features")

    X64 = np.asarray([[numeric(row[k]) for k in all64] for row in expanded], dtype=float)
    p_ix = np.asarray([i for i, row in enumerate(expanded) if row["sample_class"] == "P"])
    u_ix = np.asarray([i for i, row in enumerate(expanded) if row["sample_class"] == "U"])
    y = np.asarray([labels[expanded[i]["subject_id"]]["business_type"] for i in p_ix])
    if len(p_ix) != 880 or len(u_ix) != 916 or set(y) != set(CATEGORIES):
        raise ValueError("Unexpected F&B category label distribution")

    grid = np.asarray([
        f"{math.floor(float(expanded[i]['latitude']) / 0.12)}_{math.floor(float(expanded[i]['longitude']) / 0.12)}"
        for i in p_ix
    ])
    states = np.asarray([expanded[i]["state_dosm"] for i in p_ix])
    if len(set(states)) != 4:
        raise ValueError("Expected four region groups for independent transfer check")

    splitters = {
        "geographic_grid": list(GroupShuffleSplit(
            n_splits=4, test_size=0.25, random_state=20261115
        ).split(np.arange(len(p_ix)), y, groups=grid)),
        "leave_one_state_out": list(LeaveOneGroupOut().split(np.arange(len(p_ix)), y, groups=states)),
    }
    model_defs = model_candidates()
    features = {
        "dummy_prior": feats34,
        "logistic_original34": feats34,
        "logistic_expanded54": feats54,
        "histboost_expanded54": feats54,
    }

    folds: list[dict] = []
    for split_name, splits in splitters.items():
        for fold, (train_idx, test_idx) in enumerate(splits, 1):
            if set(y[train_idx]) != set(CATEGORIES) or set(y[test_idx]) != set(CATEGORIES):
                raise ValueError(f"Unusable fold {split_name} {fold}: class coverage")
            for name, proto in model_defs.items():
                features_i = features[name]
                cols = [all64.index(s) for s in features_i]
                Xp = X64[p_ix][:, cols]
                model = clone(proto).fit(Xp[train_idx], y[train_idx])
                cls = np.asarray(model.classes_)
                if set(cls) != set(CATEGORIES):
                    raise ValueError("Candidate missing class")
                pred = model.predict_proba(Xp[test_idx])
                met = metrics(y[test_idx], pred, cls)
                folds.append({
                    "split": split_name, "fold": fold, "model": name,
                    "features": len(features_i), "n_train": len(train_idx),
                    "n_test": len(test_idx),
                    "heldout_state": "; ".join(sorted(set(states[test_idx]))),
                    **met,
                })
                print(split_name, fold, name, "macro_f1", round(met["macro_f1"], 4),
                      "balanced_acc", round(met["balanced_accuracy"], 4), flush=True)

    agg: list[dict] = []
    for mode in splitters:
        for name in model_defs:
            row = [f for f in folds if f["split"] == mode and f["model"] == name]
            agg.append({
                "split": mode, "model": name, "features": len(features[name]),
                "n_folds": len(row),
                **{k: float(np.mean([r[k] for r in row]))
                   for k in ["accuracy", "macro_f1", "balanced_accuracy", "top2_accuracy", "log_loss"]},
                "macro_f1_std": float(np.std([r["macro_f1"] for r in row])),
            })

    eligible = [x for x in agg if x["split"] == "geographic_grid" and x["model"] != "dummy_prior"]
    selected = sorted(eligible, key=lambda z: (z["macro_f1"], z["balanced_accuracy"]), reverse=True)[0]
    name = selected["model"]
    feats = features[name]
    trained = clone(model_defs[name]).fit(X64[p_ix][:, [all64.index(s) for s in feats]], y)
    if list(trained.classes_) != list(CATEGORIES):
        raise ValueError("Final trained classes don't match canonical order")

    n_duplicate_p_coords = sum(
        c - 1 for c in collections.Counter(
            (expanded[i]["latitude"], expanded[i]["longitude"]) for i in p_ix
        ).values() if c > 1
    )
    audit = {
        "n": 1796, "P": len(p_ix), "U": len(u_ix),
        "categories": dict(collections.Counter(y)),
        "model_selection": selected, "validation": agg, "selected": name,
        "feature_names": feats, "PU_model": pu["model_info"]["model_variant"],
        "source_label_matching": True, "competitive_feature_leakage_control": True,
        "n_duplicate_P_coordinates": n_duplicate_p_coords,
        "sklearn_version": __import__("sklearn").__version__,
        "reproduction_of": "SiteWise_Category_Training_Audit.json (package, 2026-11-15)",
    }
    (out / "reproduction_audit.json").write_text(json.dumps(audit, indent=2, ensure_ascii=False), encoding="utf-8")
    with (out / "reproduction_comparison.csv").open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=list(agg[0].keys()))
        writer.writeheader()
        writer.writerows(agg)

    # --- compare with the supplied audit -----------------------------------
    supplied = json.loads((PACKAGE / "SiteWise_Category_Training_Audit.json").read_text(encoding="utf-8"))
    supplied_sel = supplied["model_selection"]
    print("\n--- reproduction vs supplied audit (geographic_grid) ---")
    for row in [r for r in agg if r["split"] == "geographic_grid"]:
        srow = next((r2 for r2 in supplied["validation"]
                     if r2["split"] == "geographic_grid" and r2["model"] == row["model"]), None)
        if srow is None:
            continue
        print(f"{row['model']:22s} macro_f1 {row['macro_f1']:.6f} vs {srow['macro_f1']:.6f} | "
              f"balanced {row['balanced_accuracy']:.6f} vs {srow['balanced_accuracy']:.6f}")
    print(f"\nselected: {name} | supplied: {supplied_sel['model']}")
    print(f"macro_f1: {selected['macro_f1']:.6f} vs {supplied_sel['macro_f1']:.6f}")
    print(f"duplicate P coordinates: {n_duplicate_p_coords} | "
          f"supplied: {supplied.get('n_duplicate_P_coordinates')}")


if __name__ == "__main__":
    main()
