"""Research-only PU model inference. Load only artifacts you trust.
python predict_expanded_pu.py --model SiteWise_PU_64_Logistic_expanded_age_residential_64_ResearchOnly.joblib --row-json sample_property.json
The JSON keys must include each model feature; only residential fields may be null.
"""
import argparse, json
from pathlib import Path
import numpy as np, joblib

def predict(model_path: str, data: dict):
 artifact=joblib.load(model_path)
 info=artifact['model_info'];names=info['feature_names']
 absent=[n for n in names if n not in data]
 if absent: raise ValueError('Missing input feature keys: '+', '.join(absent))
 vals=[]
 for name in names:
  v=data[name]
  if v is None or v=='':
   if not name.startswith('residential_'):
    raise ValueError('Observed non-residential feature required: '+name)
   vals.append(float('nan'))
  else:
   vals.append(float(v))
 X=np.asarray([vals],dtype=float)
 if np.isinf(X).any():raise ValueError('Nonfinite input')
 ps=[float(m.predict_proba(X)[0,1]) for m in artifact['estimators']]
 return {'score_P_vs_U':sum(ps)/len(ps),'model_variant':info['model_variant'],
         'features_used':len(names),'research_only':True,
         'meaning':'Association with known F&B vs unlabelled reference; not success or category probability'}

if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--model',required=True);ap.add_argument('--row-json',required=True)
 a=ap.parse_args();print(json.dumps(predict(a.model,json.loads(Path(a.row_json).read_text())),indent=2))
