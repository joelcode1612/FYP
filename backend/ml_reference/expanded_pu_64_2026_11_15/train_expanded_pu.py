"""Side-by-side 44/52/56/64 feature SiteWise PU research training.
Run: python train_expanded_pu.py --input SiteWise_PU_1796_Expanded_Observed.csv --out .
Does not touch current deployed model or database. U are unlabelled, not negatives.
"""
import argparse, csv, hashlib, json, math, sys
from pathlib import Path
from collections import Counter
import numpy as np
import sklearn, joblib
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score, average_precision_score, balanced_accuracy_score
from sklearn.model_selection import GroupShuffleSplit
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

LANDSCAN=['landscan_ambient_pop_1000m','landscan_ambient_pop_2000m','landscan_ambient_pop_3000m']
AGE=[f'pop_age_{band}_{radius}' for radius in ['500m', '1km'] for band in ['0_14','15_24','25_34','35_49','50_64','65_plus']]
RES=[f'residential_{field}_{radius}{suffix}' for field,suffix in [('building_count',''),('building_density','_km2'),('footprint_coverage','_pct'),('landuse_coverage','_pct')] for radius in ['500m','1000m']]


def read(path):
 with open(path,newline='',encoding='utf-8-sig') as f:
  reader=csv.DictReader(f); rows=list(reader); headers=reader.fieldnames
 original=headers[5:52]
 assert len(original)==47 and len(set(original))==47
 assert set(AGE+RES).issubset(headers)
 assert len(rows)==1796 and len({r['subject_id'] for r in rows})==1796
 features=[x for x in original if x not in LANDSCAN]+AGE+RES
 assert len(features)==64 and len(set(features))==64
 y=np.array([1 if r['sample_class']=='P' else 0 if r['sample_class']=='U' else -1 for r in rows],dtype=int)
 assert Counter(y)==Counter({1:880,0:916})
 ids=[r['subject_id'] for r in rows]
 X=np.empty((len(rows),len(features)),dtype=float)
 for i,r in enumerate(rows):
  for j,k in enumerate(features):
   v=r[k];X[i,j]=float(v) if str(v).strip() else np.nan
 assert np.isfinite(X[:,0:56]).all(), 'The 44 baseline and 12 age features must be observed'
 assert not np.isinf(X).any()
 latlon=np.array([[float(r[k]) for k in ('latitude','longitude')] for r in rows]);assert np.isfinite(latlon).all()
 groups=np.array([f'{math.floor(lat/0.07):04d}_{math.floor(lon/0.07):04d}' for lat,lon in latlon])
 statuses=np.array([r['age_data_status'] for r in rows])
 return rows,ids,features,X,y,groups,statuses


def make_pipe(kind,seed):
 if kind=='HistogramGradientBoosting':
  # HGB supports NaNs natively; there are 232 unavailable residential values.
  return Pipeline([('estimator',HistGradientBoostingClassifier(max_iter=105,max_leaf_nodes=13,min_samples_leaf=28,learning_rate=.06,l2_regularization=4.,random_state=seed))])
 if kind=='Logistic':
  return Pipeline([('imputer',SimpleImputer(strategy='median',add_indicator=True)),
                   ('scale',StandardScaler()),
                   ('estimator',LogisticRegression(C=.5,max_iter=650,solver='lbfgs',class_weight='balanced',random_state=seed))])
 raise ValueError(kind)


def bag_fit(X,y,kind,seed,bags=3):
 pi=np.flatnonzero(y==1);ui=np.flatnonzero(y==0);fitted=[]
 for j in range(bags):
  rng=np.random.default_rng(seed+j*17)
  chosen=rng.choice(ui,size=max(1,int(round(len(ui)*.78))),replace=False)
  ix=np.concatenate([pi,chosen]);rng.shuffle(ix)
  m=make_pipe(kind,seed+43*j);m.fit(X[ix],y[ix]);fitted.append(m)
 return fitted


def bag_predict(fitted,X):
 return np.mean(np.stack([m.predict_proba(X)[:,1] for m in fitted],axis=0),axis=0)


def save_csv(path, rows):
 if not rows: return
 with open(path,'w',newline='',encoding='utf-8-sig') as f:
  writer=csv.DictWriter(f,fieldnames=list(rows[0].keys()));writer.writeheader();writer.writerows(rows)


def main():
 parser=argparse.ArgumentParser();parser.add_argument('--input',required=True);parser.add_argument('--out',required=True)
 args=parser.parse_args();out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
 src=Path(args.input);rows,ids,features,X,y,groups,statuses=read(src)
 print('DATA',X.shape,'NaNs',int(np.isnan(X).sum()),'age_quality',Counter(statuses),'unique grids',len(set(groups)),flush=True)
 subsets={
   'baseline_44':list(range(44)),
   'baseline_plus_age_56':list(range(56)),
   'baseline_plus_residential_52':list(range(44))+list(range(56,64)),
   'expanded_age_residential_64':list(range(64)),
 }
 splits=list(GroupShuffleSplit(n_splits=3,test_size=.23,random_state=20261115).split(X,y,groups))
 results=[];predictions=[]
 for fold,(tr,va) in enumerate(splits,1):
  print('FOLD',fold,'train',len(tr),'valid',len(va),'groups',len(set(groups[va])),'classes',Counter(y[va]),flush=True)
  assert len(set(y[tr]))==len(set(y[va]))==2
  for name,ix in subsets.items():
   for kind in ['Logistic','HistogramGradientBoosting']:
    models=bag_fit(X[tr][:,ix],y[tr],kind,seed=1000+fold*111+len(ix),bags=3)
    scores=bag_predict(models,X[va][:,ix])
    auc=float(roc_auc_score(y[va],scores));ap=float(average_precision_score(y[va],scores))
    balanced=float(balanced_accuracy_score(y[va],scores>=0.5))
    results.append(dict(fold=fold,variant=name,n_features=len(ix),algorithm=kind,train_count=len(tr),valid_count=len(va),train_P=int(sum(y[tr])),train_U=int(len(tr)-sum(y[tr])),valid_P=int(sum(y[va])),valid_U=int(len(va)-sum(y[va])),heldout_grid_cells=len(set(groups[va])),roc_auc_P_vs_U=round(auc,6),average_precision_P_vs_U=round(ap,6),balanced_accuracy_at_05=round(balanced,6)))
    if name in ['baseline_44','expanded_age_residential_64'] and kind=='HistogramGradientBoosting':
     predictions.extend(dict(fold=fold,variant=name,subject_id=ids[k],sample_class=rows[k]['sample_class'],age_data_status=statuses[k],score_P_vs_U=float(round(p,8))) for k,p in zip(va,scores))
    print(' ',name,kind,'AUC',round(auc,5),'AP',round(ap,5),'BA',round(balanced,5),flush=True)
  # consistency check, no rows in holdout share training grid cell
  assert set(groups[tr]).isdisjoint(set(groups[va]))
 save_csv(out/'Expanded_Spatial_Fold_Results.csv',results)
 save_csv(out/'Expanded_Heldout_Predictions.csv',predictions)
 summary=[]
 for name,ix in subsets.items():
  for kind in ['Logistic','HistogramGradientBoosting']:
   subset=[r for r in results if r['variant']==name and r['algorithm']==kind]
   summary.append(dict(variant=name,n_features=len(ix),algorithm=kind,mean_auc_P_vs_U=round(float(np.mean([r['roc_auc_P_vs_U'] for r in subset])),6),std_auc_P_vs_U=round(float(np.std([r['roc_auc_P_vs_U'] for r in subset],ddof=1)),6),mean_average_precision=round(float(np.mean([r['average_precision_P_vs_U'] for r in subset])),6),mean_balanced_accuracy=round(float(np.mean([r['balanced_accuracy_at_05'] for r in subset])),6)))
 save_csv(out/'Expanded_Model_Comparison.csv',summary)
 # Save one expanded HGB model for research, and a matched refit of baseline-44.
 for name in ['baseline_44','expanded_age_residential_64']:
  ix=subsets[name];kind='HistogramGradientBoosting';trained=bag_fit(X[:,ix],y,kind,seed=20261115,bags=5)
  auc=[r for r in summary if r['variant']==name and r['algorithm']==kind][0]['mean_auc_P_vs_U']
  obj={'model_info':{
   'project':'SiteWise','model_family':'PU research proxy classifier',
   'dataset_source':src.name,'features':[features[i] for i in ix], 'n_features':len(ix),
   'model_variant':name,'algorithm':kind,'sample_counts':{'P':880,'U':916,'total':1796},
   'model_purpose':'P-vs-U association only, not business success or category prediction',
   'U_are_unlabelled':True,'research_only':True,'production_ready':False,
   'age_source':'WorldPop Malaysia 2025 age and sex structures; raster coverage flags preserved in source CSV',
   'residential_source':'OSM residential buildings/land use; missing values stay NaN and are handled by HGB',
   'landscan':'excluded due unresolved ML licensing/provenance',
   'validation':'0.07 degree spatial grouped splits, three holdouts; random grid splits can still have residual geographic correlation',
   'mean_auc_P_vs_U':auc, 'not_for_direct_integration':'Existing backend expects 47 features. Adapter and matching live extraction required.',
   'positive_label_proof':'Not independently verified for all P records; interpretation is research only',
   'trained_sklearn':sklearn.__version__,'random_seed':20261115},'estimators':trained}
  fname=f'SiteWise_PU_{len(ix)}_{name}_ResearchOnly.joblib';joblib.dump(obj,out/fname,compress=3)
  reloaded=joblib.load(out/fname)
  s=bag_predict(reloaded['estimators'],X[:6][:,ix])
  assert np.isfinite(s).all() and (s>=0).all() and (s<=1).all()
  print('SAVED',fname,'scores',np.round(s[:3],4),flush=True)
 details={'data':{'rows':len(rows),'P':880,'U':916,'all_features_before_landscan_exclusion':67,'LandScan_excluded':LANDSCAN,'age_count_features':AGE,'residential_features':RES,'residential_missing_cells':int(np.isnan(X[:,56:64]).sum()),'age_quality_status':dict(Counter(statuses))},'fold_design':'Same seeds/grids as prior 44-feature comparison, 3 grouped shuffle holdouts','results':summary,'feature_variants':{name:[features[i] for i in ix] for name,ix in subsets.items()},'caveats':['Positive records not independently verified for every source','U are not confirmed negatives','P-vs-U ROC-AUC is not business success accuracy','Age WorldPop partial/low raster coverage for some records','OSM building data missing for some records','LandScan omitted due licence hold','No DOI or final production release','Selection made from repeated exploratory holdout comparisons; independent validation needed']}
 (out/'Expanded_PU_Training_Results.json').write_text(json.dumps(details,indent=2),encoding='utf-8')
 print('FINISHED',flush=True)

if __name__=='__main__':main()
