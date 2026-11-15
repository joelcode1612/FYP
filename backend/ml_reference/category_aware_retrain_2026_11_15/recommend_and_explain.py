#!/usr/bin/env python3
"""SiteWise category-aware research recommendation and genuine SHAP explanations.

A saved artifact contains a 54-feature category classifier retrained on known P
outlets and the previously selected 64-feature P-vs-U ensemble. Neither
predicts commercial success or the probability that a new business survives.

Example:
  python recommend_and_explain.py --model SiteWise_Category_Aware_Recommendation_ResearchOnly.joblib \
    --features-csv SiteWise_PU_1796_Expanded_Observed.csv --subject-id MD-00510 \
    --business-type 'Cafe / Coffee' --explain \
    --category-background SHAP_Background_Category_54.csv \
    --pu-background SHAP_Background_PU_64.csv
"""
from __future__ import annotations
import argparse,csv,json,math
from pathlib import Path
from typing import Any
import joblib
import numpy as np


def numeric(v):
    if v is None or isinstance(v,str) and not v.strip():return float('nan')
    try:
        z=float(v)
        return z if math.isfinite(z) else float('nan')
    except (TypeError,ValueError):return float('nan')


def read_rows(csv_path):
    with open(csv_path,encoding='utf-8-sig',newline='') as f:
        return list(csv.DictReader(f))


def load_model(path):
    result=joblib.load(path)  # TRUSTED local artifact only; joblib can execute code
    if not isinstance(result,dict) or not all(k in result for k in ('metadata','category_model','pu_estimators')):
        raise ValueError('This is not a SiteWise category-aware research artifact')
    meta=result['metadata']
    assert meta['research_only'] is True
    assert len(meta['category_feature_names'])==54
    assert len(meta['pu_feature_names'])==64
    if not hasattr(result['category_model'],'predict_proba'):
        raise ValueError('Category classifier has no predict_proba')
    return result


def vector(record,columns):
    missing=[f for f in columns if f not in record]
    if missing:raise ValueError('Input feature columns missing: '+', '.join(missing))
    return np.array([[numeric(record[f]) for f in columns]],dtype=float)


def infer(bundle, record):
    meta=bundle['metadata']
    x64=vector(record,meta['pu_feature_names'])
    x54=vector(record,meta['category_feature_names'])
    scores=[float(model.predict_proba(x64)[0,1]) for model in bundle['pu_estimators']]
    score=float(np.mean(scores))
    pr=bundle['category_model'].predict_proba(x54)[0]
    labels=list(bundle['category_model'].classes_)
    output={c:float(pr[labels.index(c)]) for c in labels}
    return {'subject_id':record.get('subject_id'),
            'pu_positive_label_association':score,
            'category_conditional_associations':output,
            'top_category_exploratory':max(output,key=output.get),
            'model_version':meta['version'],
            'research_only':True,
            'meaning':'Similarities to observed long-operating F&B categories, NOT success or survival probability'}


def rank_for_business_type(bundle,records,business_type,max_results=10,pu_minimum=None):
    """Evidence-based *lookup*, NOT a trained personalised preference ranking.

    Sort by chosen category similarity, tie break with P/U association. Apply
    existing SiteWise budget / size / access gates before calling this helper.
    """
    labels=set(bundle['category_model'].classes_)
    if business_type not in labels:
        raise ValueError(f'Choose a business type from {sorted(labels)}')
    ranked=[]
    for r in records:
        if r.get('sample_class') not in (None,'','U'):
            continue
        pred=infer(bundle,r)
        if pu_minimum is not None and pred['pu_positive_label_association']<pu_minimum:
            continue
        ranked.append({'subject_id':r.get('subject_id'),
          'selected_business_type':business_type,
          'selected_category_conditional_association':pred['category_conditional_associations'][business_type],
          'general_pu_association':pred['pu_positive_label_association'],
          'research_only':True,'model_version':pred['model_version']})
    ranked.sort(key=lambda r:(-r['selected_category_conditional_association'],-r['general_pu_association'],r['subject_id']))
    return ranked[:max_results]


def read_background(path,columns):
    rows=read_rows(path)
    if not rows:raise ValueError('Real SHAP reference background required')
    b=np.array([[numeric(r[f]) for f in columns] for r in rows],dtype=float)
    if b.shape[1]!=len(columns) or not np.isfinite(b).all():
        raise ValueError('SHAP background has missing or nonfinite features')
    if len(b)>100:raise ValueError('Background must contain <=100 real observations')
    return b


def explain_category(bundle,record,business_type,background_path):
    import shap
    meta=bundle['metadata']
    cls=bundle['category_model'];labs=list(cls.classes_)
    if business_type not in labs:raise ValueError('Unknown category '+business_type)
    index=labs.index(business_type)
    cols=meta['category_feature_names']
    X=vector(record,cols)
    B=read_background(background_path,cols)
    f=lambda x: cls.predict_proba(x)[:,index]
    exp=shap.Explainer(f,shap.maskers.Independent(B),algorithm='permutation',feature_names=cols)
    e=exp(X,max_evals=2*len(cols)+1)
    value=float(f(X)[0]);base=float(e.base_values[0]);vals=e.values[0]
    reconstructed=base+float(np.sum(vals));residual=abs(reconstructed-value)
    if residual>1e-5:raise ValueError(f'Category SHAP additivity failure {residual}')
    return {'target':business_type,'score_type':'conditional_category_pattern_similarity_not_success_probability',
      'model_version':meta['version'],'model_output':value,'shap_baseline':base,
      'reconstructed_prediction':reconstructed,'max_additivity_error':residual,
      'background_count':len(B),'top_contributions':top_factors(cols,vals,top_n=12)}


def explain_pu(bundle,record,background_path):
    import shap
    cols=bundle['metadata']['pu_feature_names'];X=vector(record,cols)
    B=read_background(background_path,cols)
    model=bundle['pu_estimators']
    f=lambda x: np.mean([m.predict_proba(x)[:,1] for m in model],axis=0)
    exp=shap.Explainer(f,shap.maskers.Independent(B),algorithm='permutation',feature_names=cols)
    e=exp(X,max_evals=2*len(cols)+1)
    value=float(f(X)[0]);base=float(e.base_values[0]);vals=e.values[0]
    reconstructed=base+float(np.sum(vals));residual=abs(reconstructed-value)
    if residual>1e-5:raise ValueError(f'PU SHAP additivity failure {residual}')
    return {'target':'General F&B P-vs-U association','score_type':'PU_research_association_not_success_probability',
      'model_version':bundle['metadata']['version'],'model_output':value,
      'shap_baseline':base,'reconstructed_prediction':reconstructed,
      'max_additivity_error':residual,'background_count':len(B),
      'top_contributions':top_factors(cols,vals,top_n=12)}


def top_factors(names,values,top_n=10):
    pairs=sorted(zip(names,values),key=lambda x:-abs(float(x[1])))[:top_n]
    return [{'feature':name,'contribution':float(val),
            'direction':'raises association' if val>0 else 'lowers association' if val<0 else 'neutral'} for name,val in pairs]


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--model',type=Path,required=True)
    p.add_argument('--features-csv',type=Path,required=True)
    p.add_argument('--subject-id',default=None)
    p.add_argument('--business-type',default=None)
    p.add_argument('--rank',action='store_true')
    p.add_argument('--top',type=int,default=10)
    p.add_argument('--pu-min',type=float,default=None,help='Optional research PU association cutoff; not a success probability')
    p.add_argument('--explain',action='store_true')
    p.add_argument('--category-background',type=Path)
    p.add_argument('--pu-background',type=Path)
    args=p.parse_args()
    bundle=load_model(args.model)
    rows=read_rows(args.features_csv)
    if args.rank:
        if not args.business_type:raise ValueError('--rank requires --business-type')
        result=rank_for_business_type(bundle,rows,args.business_type,max_results=args.top,pu_minimum=args.pu_min)
    else:
        if not args.subject_id:raise ValueError('--subject-id required for prediction')
        found=[r for r in rows if r.get('subject_id')==args.subject_id]
        if len(found)!=1:raise ValueError(f'Expected exactly one subject ID, got {len(found)}')
        row=found[0];result=infer(bundle,row)
        if args.explain:
            if not args.business_type or not args.category_background or not args.pu_background:
                raise ValueError('--explain requires --business-type and both background paths')
            result['category_shap']=explain_category(bundle,row,args.business_type,args.category_background)
            result['general_pu_shap']=explain_pu(bundle,row,args.pu_background)
    print(json.dumps(result,indent=2))

if __name__=='__main__':main()
