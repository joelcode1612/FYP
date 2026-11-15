"""SiteWise research-only, two-stage PU -> conditional F&B category learning.

Run: python train_category_pu.py --input-xlsx ... --expanded-csv ... --pu-model ... --out ...

Important: P/U association is not a business-success probability. Known P category
is not an observed counterfactual outcome or profitability label for U properties.
"""
from __future__ import annotations
import argparse
import collections
import csv
import json
import math
from pathlib import Path
import sys

import joblib
import numpy as np
from artifact_tool import Blob, SpreadsheetFile
from sklearn.dummy import DummyClassifier
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, balanced_accuracy_score, f1_score, log_loss, classification_report, confusion_matrix, top_k_accuracy_score
from sklearn.model_selection import GroupShuffleSplit, LeaveOneGroupOut
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

CATEGORIES = ("Bakery / Dessert / Beverage", "Cafe / Coffee", "Fast Food / Takeaway", "Restaurant")
COMPETITOR_COLUMNS = {
    "fnb_competitors_500m", "fnb_competitors_1000m",
    "cafe_count_500m", "cafe_count_1000m", "restaurant_count_500m", "restaurant_count_1000m",
    "fast_food_count_500m", "fast_food_count_1000m",
    "bakery_dessert_beverage_count_500m", "bakery_dessert_beverage_count_1000m",
}


def numeric(v):
    try:
        if v is None or str(v).strip() == "":
            return float("nan")
        f = float(v)
        return f if np.isfinite(f) else float("nan")
    except (ValueError, TypeError):
        return float("nan")


def read_labels(path):
    w = SpreadsheetFile.import_xlsx(Blob.load(str(path)))
    sh = w.worksheets.get_item("Complete PU 1796")
    # Real latest category-labelled Excel, not an inferred reconstruction
    table = sh.get_range("A1:BC1797").values
    h = table[0]
    idx = {name:i for i,name in enumerate(h)}
    required = ["subject_id", "sample_class", "business_type", "latitude", "longitude"]
    if any(k not in idx for k in required):
        raise ValueError("Category workbook missing required columns")
    labels = {}
    for cells in table[1:]:
        subject = str(cells[idx["subject_id"]]).strip()
        if subject in labels:
            raise ValueError("Duplicate subject_id in Excel: "+subject)
        labels[subject] = {
            "sample_class":str(cells[idx["sample_class"]]).strip(),
            "business_type":cells[idx["business_type"]] if cells[idx["business_type"]] else None,
            "latitude":numeric(cells[idx["latitude"]]),
            "longitude":numeric(cells[idx["longitude"]]),
        }
    if len(labels) != 1796:
        raise ValueError(f"Unexpected Excel row count {len(labels)}")
    return labels


def pu_scores(pu, feature64, X):
    ests = pu["estimators"]
    scores = np.mean(np.asarray([est.predict_proba(X)[:,1] for est in ests]), axis=0)
    if len(scores) != len(X) or not np.all(np.isfinite(scores)):
        raise ValueError("Invalid PU scores")
    return scores


def model_candidates():
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
            ("classifier", HistGradientBoostingClassifier(max_iter=110, max_leaf_nodes=9, l2_regularization=5, learning_rate=0.06, random_state=20261115)),
        ]),
    }


def metrics(y, proba, classes):
    ix = np.argmax(proba,axis=1)
    pred = classes[ix]
    return dict(
      accuracy=float(accuracy_score(y,pred)),
      macro_f1=float(f1_score(y,pred,labels=list(CATEGORIES),average="macro",zero_division=0)),
      balanced_accuracy=float(balanced_accuracy_score(y,pred)),
      top2_accuracy=float(top_k_accuracy_score(y,proba,k=2,labels=list(classes))),
      log_loss=float(log_loss(y,proba,labels=list(classes))),
    )


def write_csv(path,headers,rows):
    with open(path,"w",newline="",encoding="utf-8-sig") as f:
        writer=csv.writer(f);writer.writerow(headers);writer.writerows(rows)


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--input-xlsx",required=True)
    ap.add_argument("--expanded-csv",required=True)
    ap.add_argument("--pu-model",required=True)
    ap.add_argument("--out",required=True)
    args=ap.parse_args()
    out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
    labels=read_labels(args.input_xlsx)
    pu=joblib.load(args.pu_model)
    all64=list(pu["model_info"]["feature_names"])
    if len(all64)!=64 or len(set(all64))!=64:
        raise ValueError("PU 64-feature contract mismatch")
    expanded=[]
    with open(args.expanded_csv,encoding="utf-8-sig",newline="") as f:
        rd=csv.DictReader(f)
        if not set(all64).issubset(rd.fieldnames):
            raise ValueError("Expanded CSV missing actual PU features")
        for row in rd: expanded.append(row)
    if len(expanded)!=1796 or len(set(row["subject_id"] for row in expanded))!=1796:
        raise ValueError("Expanded 1796 CSV lacks exact unique IDs")
    if set(labels) != {row["subject_id"] for row in expanded}:
        raise ValueError("Exact category Excel + expanded feature CSV IDs differ")
    for row in expanded:
        lab=labels[row["subject_id"]]
        if row["sample_class"]!=lab["sample_class"]:
            raise ValueError("P/U source label conflict")
        if abs(float(row["latitude"])-lab["latitude"])>0.00001 or abs(float(row["longitude"])-lab["longitude"])>0.00001:
            raise ValueError("Coordinate conflict: "+row["subject_id"])
    base44=[s for s in all64 if not s.startswith("pop_age_") and not s.startswith("residential_")]
    if len(base44)!=44:
        raise ValueError(f"Expected 44 retained base features, got {len(base44)}")
    feats34=[s for s in base44 if s not in COMPETITOR_COLUMNS]
    feats54=[s for s in all64 if s not in COMPETITOR_COLUMNS]
    if len(feats34)!=34 or len(feats54)!=54:
        raise ValueError("Category predictor should use 34 and 54 leakage-reduced features")
    X64=np.asarray([[numeric(row[k]) for k in all64] for row in expanded],dtype=float)
    all_scores=pu_scores(pu,all64,X64)
    p_ix=np.asarray([i for i,row in enumerate(expanded) if row["sample_class"]=="P"])
    u_ix=np.asarray([i for i,row in enumerate(expanded) if row["sample_class"]=="U"])
    y=np.asarray([labels[expanded[i]["subject_id"]]["business_type"] for i in p_ix])
    if len(p_ix)!=880 or len(u_ix)!=916 or set(y)!=set(CATEGORIES):
        raise ValueError("Unexpected F&B category label distribution")
    # Spatial grouping: all locations inside the same ~0.12 degree grid cell are held out together.
    grid=np.asarray([f"{math.floor(float(expanded[i]['latitude'])/0.12)}_{math.floor(float(expanded[i]['longitude'])/0.12)}" for i in p_ix])
    states=np.asarray([expanded[i]["state_dosm"] for i in p_ix])
    if len(set(states))!=4:
        raise ValueError("Expected four region groups for independent transfer check")
    splitters={
        "geographic_grid":list(GroupShuffleSplit(n_splits=4,test_size=0.25,random_state=20261115).split(np.arange(len(p_ix)),y,groups=grid)),
        "leave_one_state_out":list(LeaveOneGroupOut().split(np.arange(len(p_ix)),y,groups=states)),
    }
    # Use the SAME folds and labels for every candidate; categories are never features.
    model_defs=model_candidates()
    features={"dummy_prior":feats34,"logistic_original34":feats34,"logistic_expanded54":feats54,"histboost_expanded54":feats54}
    folds=[]
    heldout=[]
    for split_name,splits in splitters.items():
        for fold,(train_idx,test_idx) in enumerate(splits,1):
            if set(y[train_idx])!=set(CATEGORIES) or set(y[test_idx])!=set(CATEGORIES):
                raise ValueError(f"Unusable fold {split_name} {fold}: class coverage")
            test_region=sorted(set(states[test_idx]))
            for name,proto in model_defs.items():
                from sklearn.base import clone
                features_i=features[name]
                cols=[all64.index(s) for s in features_i]
                Xp=X64[p_ix][:,cols]
                model=clone(proto).fit(Xp[train_idx],y[train_idx])
                cls=np.asarray(model.classes_)
                if set(cls)!=set(CATEGORIES):raise ValueError("Candidate missing class")
                pred=model.predict_proba(Xp[test_idx]); met=metrics(y[test_idx],pred,cls)
                folds.append({"split":split_name,"fold":fold,"model":name,"features":len(features_i),"n_train":len(train_idx),"n_test":len(test_idx),"heldout_state":"; ".join(test_region),**met})
                chosen=np.asarray([cls[j] for j in pred.argmax(axis=1)])
                for q, idx in enumerate(test_idx):
                    heldout.append([split_name,fold,name,expanded[p_ix[idx]]["subject_id"],states[idx],y[idx],chosen[q],float(pred[q].max()),int(y[idx]==chosen[q])])
                print(split_name,fold,name,"macro_f1",round(met['macro_f1'],4),"balanced_acc",round(met['balanced_accuracy'],4),flush=True)
    agg=[]
    for mode in splitters:
        for name in model_defs:
            row=[f for f in folds if f["split"]==mode and f["model"]==name]
            agg.append({"split":mode,"model":name,"features":len(features[name]),"n_folds":len(row),**{k:float(np.mean([r[k] for r in row])) for k in ["accuracy","macro_f1","balanced_accuracy","top2_accuracy","log_loss"]},"macro_f1_std":float(np.std([r["macro_f1"] for r in row]))})
    # Choose among the 34/54 feature candidates by geometric holdout macro F1,
    # with LOSO evidence reported but not used to pick a model.
    eligible=[x for x in agg if x["split"]=="geographic_grid" and x["model"]!="dummy_prior"]
    selected=sorted(eligible,key=lambda z:(z["macro_f1"],z["balanced_accuracy"]),reverse=True)[0]
    name=selected["model"]
    feats=features[name]
    from sklearn.base import clone
    trained=clone(model_defs[name]).fit(X64[p_ix][:,[all64.index(s) for s in feats]],y)
    if list(trained.classes_)!=list(CATEGORIES):
        raise ValueError("Final trained classes don't match canonical order")
    xp=X64[p_ix][:,[all64.index(s) for s in feats]]
    if name.startswith("logistic"):
        mu=np.asarray(trained[:-1].transform(xp)).mean(axis=0)
        xnames=list(trained["imputer"].get_feature_names_out(feats))
    else: mu=None;xnames=None
    bundle={
      "metadata": {
        "project":"SiteWise",
        "model_kind":"research_only_hierarchical_PU_plus_P_category_similarity",
        "version":"fnb_category_pu_v1_20261115",
        "source_xlsx":Path(args.input_xlsx).name,
        "source_csv":Path(args.expanded_csv).name,
        "n_subjects":1796,"n_P":880,"n_U":916,
        "label_counts":dict(collections.Counter(y)),
        "pu_model_version":pu["model_info"].get("model_variant"),
        "pu_feature_names":all64,
        "category_feature_names":feats,
        "competitor_features_EXCLUDED_from_category_training":sorted(COMPETITOR_COLUMNS),
        "selection_metric":"macro F1, 4 group shuffle split folds, 0.12-degree spatial blocks; no independent locked test set",
        "selected_model":name,
        "model_comparison":agg,
        "target_semantics":"Category resemblance among *existing* P F&B outlets, conditioned on an outlet being observed, NOT the most profitable category and NOT success probability",
        "PU_semantics":"Uncalibrated P-versus-U association, U NOT confirmed negatives",
        "availability":"research_only_not_production_validated",
        "provenance_warnings":["Some P category labels not independently verified","Age population partial/low coverage for some locations","Geospatial sources may have time/place mismatch","Only known operating business categories; no outcome or commercial success target","Excluded competitor counts from category training due possible subject self-inclusion","PU model previously selected using these data; no separate external validation"],
        "prediction_provenance":"PU score and conditional category scores are separate; never treat their product as a calibrated commercial-success probability",
      },
      "category_model":trained,
      "pu_estimators":pu["estimators"],
      "reference_mean_transformed":mu,
      "transformed_category_features":xnames,
    }
    joblib.dump(bundle,out/"SiteWise_Two_Stage_PU_FNB_Category_ResearchOnly.joblib",compress=3)
    joblib.dump({k:bundle[k] for k in ["metadata","category_model","reference_mean_transformed","transformed_category_features"]},out/"SiteWise_FNB_Category_Conditional_ResearchOnly.joblib",compress=3)
    # One prediction per original U subject (not used as a negative for category training)
    U_X=X64[u_ix][:,[all64.index(s) for s in feats]]
    U_prob=trained.predict_proba(U_X)
    U_order=np.argsort(-U_prob,axis=1)
    cols=["subject_id","latitude","longitude","state","general_PU_association_0_1","predicted_category_exploratory","runner_up_category_exploratory","top_category_conditional_score_0_1","runner_up_conditional_score_0_1"]+[f"conditional_{s.lower().replace(' ','_').replace('/','_')}_0_1" for s in trained.classes_]+["category_model","warning"]
    predrows=[]
    for j,i in enumerate(u_ix):
        r=expanded[i];order=U_order[j];scores=U_prob[j]
        predrows.append([r["subject_id"],r["latitude"],r["longitude"],r["state_dosm"],round(float(all_scores[i]),7),str(trained.classes_[order[0]]),str(trained.classes_[order[1]]),round(float(scores[order[0]]),7),round(float(scores[order[1]]),7)]+[round(float(p),7) for p in scores]+[name,"Exploratory category resemblance; NOT success/suitability probability"])
    write_csv(out/"SiteWise_916_U_Category_Exploratory_Predictions.csv",cols,predrows)
    write_csv(out/"SiteWise_Category_Model_Validation_Folds.csv",list(folds[0].keys()),[[v for v in f.values()] for f in folds])
    write_csv(out/"SiteWise_Category_Model_Comparison.csv",list(agg[0].keys()),[[x.get(k) for k in agg[0].keys()] for x in agg])
    write_csv(out/"SiteWise_Category_Heldout_Predictions.csv",["validation","fold","model","subject_id","state","observed_category","predicted_category","top_score","correct"],heldout)
    report={"n":1796,"P":len(p_ix),"U":len(u_ix),"categories":dict(collections.Counter(y)),"model_selection":selected,"validation":agg,"selected":name,"feature_names":feats,"PU_model":pu["model_info"]["model_variant"],"source_label_matching":True,"competitive_feature_leakage_control":True,"n_duplicate_P_coordinates":sum(c-1 for c in collections.Counter((expanded[i]["latitude"],expanded[i]["longitude"]) for i in p_ix).values() if c>1)}
    (out/"SiteWise_Category_Training_Audit.json").write_text(json.dumps(report,indent=2,ensure_ascii=False),encoding="utf-8")
    print("FINAL_SELECT",name,"GRID_MACRO_F1",selected["macro_f1"],"LOSO",next(x for x in agg if x['model']==name and x['split']=='leave_one_state_out')['macro_f1'])
    print("DONE",out,flush=True)

if __name__=="__main__":main()
