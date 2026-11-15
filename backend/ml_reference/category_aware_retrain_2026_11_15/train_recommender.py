#!/usr/bin/env python3
"""Train a research-only category-aware recommendation MODEL for SiteWise.

Supervised task: given features of an established (P) F&B outlet, classify its
observed category. This is NOT a learned entrepreneur-preference ranker and not
an estimate of business survival/profitability. U sites are scored only.

Training eligibility: current P outlet category is verified in supplied Excel;
3-year operating history is asserted by data owner but no dates are contained
in this workbook. See MODEL_CARD.md for caveats.
"""
from __future__ import annotations
import argparse, csv, json, math, hashlib, sys, warnings
from pathlib import Path
from collections import Counter
from dataclasses import asdict
import numpy as np
import joblib
from artifact_tool import Blob, SpreadsheetFile
from sklearn.base import clone
from sklearn.dummy import DummyClassifier
from sklearn.ensemble import ExtraTreesClassifier, HistGradientBoostingClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (accuracy_score, f1_score, balanced_accuracy_score,
                             log_loss, top_k_accuracy_score, confusion_matrix,
                             classification_report)
from sklearn.model_selection import GroupShuffleSplit, LeaveOneGroupOut
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

SEED = 20261115
CATS = ['Bakery / Dessert / Beverage','Cafe / Coffee','Fast Food / Takeaway','Restaurant']
EXCLUDE_CATEGORY_LEAKAGE = {
  'fnb_competitors_500m','fnb_competitors_1000m','cafe_count_500m','cafe_count_1000m',
  'restaurant_count_500m','restaurant_count_1000m','fast_food_count_500m',
  'fast_food_count_1000m','bakery_dessert_beverage_count_500m',
  'bakery_dessert_beverage_count_1000m'
}

def num(v):
    try:
        z=float(v)
        return z if np.isfinite(z) else float('nan')
    except (ValueError,TypeError):return float('nan')

def labels_from_excel(file):
    w=SpreadsheetFile.import_xlsx(Blob.load(str(file)))
    sh=w.worksheets.get_item('Complete PU 1796')
    cells=sh.get_range('A1:BC1797').values
    idx={s:i for i,s in enumerate(cells[0])}
    needed={'subject_id','sample_class','business_type','latitude','longitude'}
    assert needed.issubset(idx), f'Absent Excel columns {needed-set(idx)}'
    result={}
    for row in cells[1:]:
        sid=str(row[idx['subject_id']]).strip()
        if sid in result:raise ValueError('Duplicate Excel subject ID '+sid)
        result[sid]=dict(sample_class=str(row[idx['sample_class']]).strip(),
            business_type=str(row[idx['business_type']]).strip() if row[idx['business_type']] else '',
            latitude=num(row[idx['latitude']]),longitude=num(row[idx['longitude']]))
    return result

def csv_writer(path,headers,rows):
    with open(path,'w',encoding='utf-8-sig',newline='') as f:
        w=csv.writer(f);w.writerow(headers);w.writerows(rows)

def build_candidates():
    return {
      'majority_baseline': DummyClassifier(strategy='prior'),
      'logistic_balanced_54': Pipeline([
          ('imputer',SimpleImputer(strategy='median',add_indicator=True)),
          ('scaler',StandardScaler()),
          ('classifier',LogisticRegression(C=0.5,class_weight='balanced',max_iter=1200,random_state=SEED))]),
      'histboost_54': Pipeline([
          ('imputer',SimpleImputer(strategy='median')),
          ('classifier',HistGradientBoostingClassifier(max_iter=120,max_leaf_nodes=9,
            learning_rate=0.055,l2_regularization=5,random_state=SEED))]),
      'extratrees_54': Pipeline([
          ('imputer',SimpleImputer(strategy='median')),
          ('classifier',ExtraTreesClassifier(n_estimators=200,min_samples_leaf=6,
             max_features=0.75,class_weight='balanced',n_jobs=1,random_state=SEED))]),
    }

def metric(y,prob,cls):
    pred=cls[np.argmax(prob,axis=1)]
    return dict(accuracy=float(accuracy_score(y,pred)),
      macro_f1=float(f1_score(y,pred,labels=CATS,average='macro',zero_division=0)),
      balanced_accuracy=float(balanced_accuracy_score(y,pred)),
      top2_accuracy=float(top_k_accuracy_score(y,prob,k=2,labels=cls)),
      log_loss=float(log_loss(y,prob,labels=cls)))

def sha(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for b in iter(lambda:f.read(2**20),b''):h.update(b)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--labels-xlsx',type=Path,required=True)
    p.add_argument('--features-csv',type=Path,required=True)
    p.add_argument('--pu-artifact',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    args=p.parse_args()
    args.out.mkdir(exist_ok=True,parents=True)
    labels=labels_from_excel(args.labels_xlsx)
    with args.features_csv.open(encoding='utf-8-sig',newline='') as f:
        rows=list(csv.DictReader(f))
    if len(rows)!=1796 or len(labels)!=1796:raise ValueError('Unexpected number of subjects')
    ids=[r['subject_id'] for r in rows]
    if len(set(ids))!=1796 or set(ids)!=set(labels):raise ValueError('Unmatched or duplicate subject IDs')
    pu=joblib.load(args.pu_artifact)
    pu_features=list(pu['model_info']['feature_names'])
    if len(pu_features)!=64 or not set(pu_features).issubset(rows[0]):raise ValueError('64-feature PU contract invalid')
    category_features=[x for x in pu_features if x not in EXCLUDE_CATEGORY_LEAKAGE]
    if len(category_features)!=54:raise ValueError(f'Expected 54 category features, found {len(category_features)}')
    for r in rows:
        x=labels[r['subject_id']]
        if r['sample_class']!=x['sample_class']:raise ValueError('P/U mismatch '+r['subject_id'])
        if abs(num(r['latitude'])-x['latitude'])>0.00001 or abs(num(r['longitude'])-x['longitude'])>0.00001:
            raise ValueError('Coordinate mismatch '+r['subject_id'])
    X=np.array([[num(r[k]) for k in category_features] for r in rows],dtype=float)
    X64=np.array([[num(r[k]) for k in pu_features] for r in rows],dtype=float)
    labels_P=[r['subject_id'] for r in rows if r['sample_class']=='P']
    is_P=np.array([r['sample_class']=='P' for r in rows],dtype=bool)
    if is_P.sum()!=880 or (~is_P).sum()!=916:raise ValueError('Unexpected P/U sample composition')
    XP=X[is_P];Y=np.array([labels[s]['business_type'] for s in labels_P]);
    if not set(Y)==set(CATS):raise ValueError('Category labels mismatch')
    states=np.array([r['state_dosm'] for r in rows if r['sample_class']=='P'])
    grids=np.array([f"{math.floor(float(r['latitude'])/0.12)}_{math.floor(float(r['longitude'])/0.12)}" for r in rows if r['sample_class']=='P'])
    folds={'geographic_grid':list(GroupShuffleSplit(n_splits=4,test_size=0.25,random_state=SEED).split(XP,Y,groups=grids)),
           'leave_one_state_out':list(LeaveOneGroupOut().split(XP,Y,groups=states))}
    candidates=build_candidates()
    result=[];held=[]
    for scheme,splits in folds.items():
        for fold,(train,test) in enumerate(splits,1):
            if set(Y[train])!=set(CATS) or set(Y[test])!=set(CATS):raise ValueError(f'{scheme} {fold} class missing')
            for name,proto in candidates.items():
                m=clone(proto).fit(XP[train],Y[train])
                prob=m.predict_proba(XP[test]); cls=np.array(m.classes_)
                data=metric(Y[test],prob,cls)
                result.append(dict(split=scheme,fold=fold,model=name,n_train=len(train),n_test=len(test),**data))
                pred=cls[prob.argmax(axis=1)]
                for j,ind in enumerate(test):
                    held.append([scheme,fold,name,labels_P[ind],states[ind],Y[ind],pred[j],float(prob[j].max())])
                print(f'{scheme} {fold} {name}: macro-F1={data["macro_f1"]:.3f} balanced_acc={data["balanced_accuracy"]:.3f}',flush=True)
    agg=[]
    for scheme in folds:
        for name in candidates:
            rs=[r for r in result if r['split']==scheme and r['model']==name]
            agg.append(dict(split=scheme,model=name,n_folds=len(rs),**{k:float(np.mean([r[k] for r in rs])) for k in
              ['macro_f1','balanced_accuracy','accuracy','top2_accuracy','log_loss']},
              macro_f1_std=float(np.std([r['macro_f1'] for r in rs]))))
    # Holdout geography is model selection criterion; state results offer context.
    non_dummy=[r for r in agg if r['split']=='geographic_grid' and r['model']!='majority_baseline']
    selected=max(non_dummy,key=lambda r:(r['macro_f1'],-r['log_loss']))
    selected_name=selected['model']; classifier=clone(candidates[selected_name]).fit(XP,Y)
    print('SELECTED',selected_name,selected,flush=True)
    # Separate real, nonmissing background (small, stratified categories and P/U).
    validcat=np.where(is_P & np.isfinite(X).all(axis=1))[0]
    chosen=[]
    for cat in CATS:
        pool=[i for i in validcat if labels[rows[i]['subject_id']]['business_type']==cat]
        chosen.extend(pool[::max(1,len(pool)//8)][:8])
    chosen=chosen[:32]
    validall=np.where(np.isfinite(X64).all(axis=1))[0]
    poolP=[i for i in validall if is_P[i]];poolU=[i for i in validall if not is_P[i]]
    pu_bg=poolP[::max(1,len(poolP)//16)][:16]+poolU[::max(1,len(poolU)//16)][:16]
    cat_bg_rows=[rows[i] for i in chosen]
    pu_bg_rows=[rows[i] for i in pu_bg]
    csv_writer(args.out/'SHAP_Background_Category_54.csv',['subject_id']+category_features,
      [[r['subject_id']]+[r[k] for k in category_features] for r in cat_bg_rows])
    csv_writer(args.out/'SHAP_Background_PU_64.csv',['subject_id']+pu_features,
      [[r['subject_id']]+[r[k] for k in pu_features] for r in pu_bg_rows])
    meta={
        'name':'SiteWise_Category_Aware_Recommendation_ResearchOnly',
        'version':'category_recommender_v2_20261115',
        'research_only':True,
        'recommended_use':'Exploratory P-category similarity for U properties; preference-aware ranked lookup',
        'not_supported':'Actual success, profitability, survival or entrepreneur preference outcome predictions',
        'n_total':1796,'n_P':880,'n_U':916,
        'positive_label_semantics':'Known operating F&B outlets; user attests all were operating >=3 years, opening dates not present in supplied workbook',
        'category_counts':dict(Counter(Y.tolist())),
        'categories':CATS,'selected_model':selected_name,
        'pu_feature_names':pu_features,'category_feature_names':category_features,
        'excluded_competitor_features':sorted(EXCLUDE_CATEGORY_LEAKAGE),
        'preference_fit_status':'not trained: no entrepreneur-outcome labels; apply existing deterministic preference rules separately',
        'selection_metric':'mean macro-F1 across four 0.12-degree geographic grid group holdouts',
        'source_labels_sha256':sha(args.labels_xlsx),
        'source_features_sha256':sha(args.features_csv),
        'source_pu_sha256':sha(args.pu_artifact),
        'validation':agg,
    }
    artifact={'metadata':meta,'category_model':classifier,
      'pu_estimators':pu['estimators']}
    outfn=args.out/'SiteWise_Category_Aware_Recommendation_ResearchOnly.joblib'
    joblib.dump(artifact,outfn,compress=3)
    with open(args.out/'Training_Results.json','w') as f:json.dump(meta,f,indent=2)
    csv_writer(args.out/'Model_Comparison.csv',list(agg[0]),[[r.get(k) for k in agg[0]] for r in agg])
    csv_writer(args.out/'Spatial_Fold_Results.csv',list(result[0]),[[r.get(k) for k in result[0]] for r in result])
    csv_writer(args.out/'Spatial_Heldout_Predictions.csv',
      ['split','fold','model','subject_id','state','true_category','predicted_category','top_conditional_association'],held)
    # New U predictions: PU stage = original 64-feature score ensemble, not refitted.
    pu_score=np.mean([m.predict_proba(X64)[:,1] for m in artifact['pu_estimators']],axis=0)
    prob=classifier.predict_proba(X); classes=list(classifier.classes_)
    predrows=[]
    for i,r in enumerate(rows):
        if is_P[i]:continue
        predrows.append([r['subject_id'],r['state_dosm'],r['latitude'],r['longitude'],float(pu_score[i]),
          classes[np.argmax(prob[i])],float(np.max(prob[i])),
          *[float(prob[i,classes.index(c)]) for c in CATS],selected_name,'exploratory_not_success_probability'])
    csv_writer(args.out/'916_U_Category_Aware_Predictions.csv',
      ['subject_id','state','latitude','longitude','general_pu_association','top_category_exploratory',
       'top_category_conditional_association']+[f'category_{c.lower().replace(" / ","_").replace(" ","_")}' for c in CATS]+['model','status'],predrows)
    # Exact matrix retained so SHAP example can be replayed from this package.
    sample_id=next((r['subject_id'] for r in rows if r['subject_id']=='MD-00510'),None)
    if sample_id:
        i=ids.index(sample_id)
        with open(args.out/'Example_MD-00510_Model_Output.json','w') as f:
          json.dump({'subject_id':sample_id,'pu_score':float(pu_score[i]),
           'categories':{c:float(prob[i,classes.index(c)]) for c in CATS},'top_category':classes[np.argmax(prob[i])]},f,indent=2)
    print('OUTPUT',outfn,'U_ROWS',len(predrows),flush=True)

if __name__=='__main__': main()
