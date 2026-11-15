"""Standalone inference for SiteWise PU research model dictionary artifacts.

Examples:
  python predict_research_pu.py --model SiteWise_PU_44_Features_recommended_research_ResearchOnly.joblib --csv SiteWise_PU_1796_Observed_47_Features.csv --out pu_research_scores.csv

Never interpret scores as restaurant success probabilities or category-specific fit.
Only load joblib files from a trusted source; pickle/joblib files can execute code on load.
"""
import argparse,csv
from pathlib import Path
import numpy as np,joblib

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--model',required=True);ap.add_argument('--csv',required=True);ap.add_argument('--out',required=True);args=ap.parse_args()
    # Security: joblib unpickling is unsafe for untrusted files.
    artifact=joblib.load(args.model)
    meta=artifact['model_info'];names=meta['feature_names'];models=artifact['estimators']
    assert meta['production_ready'] is False and meta['research_only'] is True
    with open(args.csv,newline='',encoding='utf-8-sig') as f: rows=list(csv.DictReader(f))
    if not rows:raise ValueError('Empty CSV')
    missing=[name for name in names if name not in rows[0]]
    if missing:raise ValueError(f'Expected exact feature columns: {missing}')
    X=np.array([[float(r[name]) for name in names] for r in rows],dtype=np.float64)
    if not np.isfinite(X).all():raise ValueError('Missing or nonfinite feature values; refuse silent imputation')
    probs=np.mean([m.predict_proba(X)[:,1] for m in models],axis=0)
    out=[]
    for r,score in zip(rows,probs):
        out.append({'subject_id':r.get('subject_id',''),'sample_class':r.get('sample_class',''),
            'P_vs_U_association_score':round(float(score),7),
            'interpretation':'RESEARCH ONLY: known positive vs unlabelled association, NOT probability of business success'})
    with open(args.out,'w',newline='',encoding='utf-8-sig') as f:
        w=csv.DictWriter(f,fieldnames=list(out[0]));w.writeheader();w.writerows(out)
    print('Wrote',len(out),'research scores to',args.out,'(model:',meta['feature_subset']+', '+meta['algorithm']+')')

if __name__=='__main__':main()
