"""Permutation SHAP explaining the CONDITIONAL category-model probability only.

Does not explain PU scores or predict commercial success.
Uses real known-positive P outlet feature rows as background, no synthetic values.
"""
from __future__ import annotations
import argparse,csv,json
from pathlib import Path
import joblib,numpy as np
from predict_category_pu import load_input,parse_num

def explain(model_path,background_path,row):
    import shap
    bundle=joblib.load(model_path)  # trusted local artifact only
    names=list(bundle['metadata']['category_feature_names'])
    background=[]
    with open(background_path,encoding='utf-8-sig',newline='') as f:
        for item in csv.DictReader(f):
            background.append([parse_num(item.get(n)) for n in names])
    if len(background)>100 or len(background)<5:raise ValueError('Need 5-100 measured background P examples')
    B=np.asarray(background,dtype=float)
    if not np.isfinite(B).all():raise ValueError('Background P records must be fully observed')
    X=np.asarray([[parse_num(row.get(n)) for n in names]],dtype=float)
    model=bundle['category_model']
    expected=model.predict_proba(X)[0]
    fn=lambda z: model.predict_proba(z)
    explainer=shap.Explainer(fn,shap.maskers.Independent(B),algorithm='permutation',feature_names=names)
    values=explainer(X,max_evals=2*len(names)+1)
    vals=np.asarray(values.values[0]);base=np.asarray(values.base_values[0]).reshape(-1)
    reconstructed=base+vals.sum(axis=0)
    if not np.allclose(reconstructed,expected,atol=2e-3):
        raise RuntimeError(f'SHAP reconstruction failed: {reconstructed} != {expected}')
    cats=list(model.classes_); j=int(np.argmax(expected))
    items=sorted([{'feature':name,'shap_category_probability_contribution':round(float(vals[i,j]),6)} for i,name in enumerate(names)],key=lambda z:abs(z['shap_category_probability_contribution']),reverse=True)
    return {'subject_id':row.get('subject_id'),'target':'conditional probability among observed F&B categories, not business success','predicted_category':cats[j],'model_score':round(float(expected[j]),6),'shap_baseline':round(float(base[j]),6),'shap_sum':round(float(reconstructed[j]),6),'reconstruction_absolute_error':float(abs(reconstructed[j]-expected[j])),'top_12_contributions':items[:12],'background_n':len(background),'research_only':True}

if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('--model',required=True);ap.add_argument('--background',required=True)
    ap.add_argument('--json');ap.add_argument('--csv');ap.add_argument('--subject-id')
    args=ap.parse_args()
    print(json.dumps(explain(args.model,args.background,load_input(args)),indent=2,ensure_ascii=False))
