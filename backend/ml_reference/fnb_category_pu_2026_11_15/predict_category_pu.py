"""Run research-only two-stage SiteWise PU + known-F&B-category resemblance.

Examples:
 python predict_category_pu.py --model SiteWise_Two_Stage_PU_FNB_Category_ResearchOnly.joblib --csv SiteWise_PU_1796_Expanded_Observed.csv --subject-id MD-00510
 python predict_category_pu.py --model ... --json path_to_single_64_feature_dict.json

The P-vs-U score is an uncalibrated research association. The category numbers
are conditional category predictions among historically OBSERVED P F&B outlets.
Neither score estimates whether a new business would succeed or be profitable.
"""
from __future__ import annotations
import argparse
import csv
import json
from pathlib import Path
import math
import joblib
import numpy as np

def parse_num(x):
    if x is None or str(x).strip()=="":return float("nan")
    try: num=float(x)
    except (ValueError,TypeError) as e:raise ValueError(f"Feature value not numeric: {x!r}") from e
    return num if math.isfinite(num) else float("nan")


def load_input(args):
    if args.json:
        j=json.loads(Path(args.json).read_text(encoding="utf-8"))
        return j["features"] if "features" in j else j
    if not args.csv or not args.subject_id:
        raise ValueError("Provide --json, or --csv together with --subject-id")
    with open(args.csv,encoding="utf-8-sig",newline="") as f:
        matches=(r for r in csv.DictReader(f) if r.get("subject_id")==args.subject_id)
        row=next(matches,None)
        if row is None: raise ValueError("Subject not found: "+args.subject_id)
        if next(matches,None) is not None:raise ValueError("Duplicate subject ID")
    return row


def predict(bundle,row):
    metadata=bundle["metadata"]
    names=metadata["pu_feature_names"]
    missing=[s for s in names if s not in row]
    if missing:raise ValueError(f"Missing required named model features: {missing}")
    x=np.asarray([[parse_num(row[k]) for k in names]],dtype=float)
    if np.isinf(x).any():raise ValueError("Infinite input feature")
    allowed_missing={f for f in names if f.startswith('residential_')}
    unavailable=[k for k,v in zip(names,x[0]) if not math.isfinite(v) and k not in allowed_missing]
    if unavailable:raise ValueError(f"Source measurements unavailable; not scoring: {unavailable}")
    pu=float(np.mean([m.predict_proba(x)[:,1][0] for m in bundle["pu_estimators"]]))
    cat_names=metadata["category_feature_names"]
    xcat=x[:,[names.index(c) for c in cat_names]]
    classifier=bundle["category_model"]
    probs=classifier.predict_proba(xcat)[0]
    result=[]
    for j in np.argsort(-probs):
        result.append({"business_type":str(classifier.classes_[j]),"category_resemblance_score":round(float(probs[j]),6)})
    evidence={k:parse_num(row.get(k)) for k in metadata["competitor_features_EXCLUDED_from_category_training"] if k in row}
    evidence={k:v for k,v in evidence.items() if math.isfinite(v)}
    return {
       "subject_id":row.get("subject_id"),"model_version":metadata["version"],
       "general_PU_association":round(pu,6),
       "category_rankings_exploratory":result,
       "competition_context_NOT_used_to_train_category_model":evidence,
       "research_only":True,"production_ready":False,
       "interpretation":"Categories resemble types of observed F&B outlets; scores are NOT viability, success or profitability probabilities",
    }

if __name__=="__main__":
    ap=argparse.ArgumentParser();ap.add_argument("--model",required=True);ap.add_argument("--json");ap.add_argument("--csv");ap.add_argument("--subject-id")
    args=ap.parse_args()
    model=joblib.load(args.model) # Only trusted, locally generated artifacts!
    print(json.dumps(predict(model,load_input(args)),ensure_ascii=False,indent=2))
