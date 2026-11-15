"""Refit the selected research-only 64-feature Logistic PU-proxy candidate and a 52-feature sensitivity model."""
import json, sys
from pathlib import Path
import numpy as np, joblib, sklearn
from train_expanded_pu import read, bag_fit, bag_predict, AGE, RES
ROOT=Path(__file__).resolve().parent
rows,ids,features,X,y,groups,statuses=read(ROOT/'SiteWise_PU_1796_Expanded_Observed.csv')
comparison=json.loads((ROOT/'Expanded_PU_Training_Results.json').read_text())['results']
for label,idx in [('expanded_age_residential_64',list(range(64))),('baseline_plus_residential_52',list(range(44))+list(range(56,64)))]:
 auc=next(x['mean_auc_P_vs_U'] for x in comparison if x['variant']==label and x['algorithm']=='Logistic')
 m=bag_fit(X[:,idx],y,'Logistic',seed=20261115,bags=5)
 obj={'model_info':{
   'project':'SiteWise','model_family':'PU research P-vs-U proxy classifier',
   'model_variant':label,'algorithm':'Bagged LogisticRegression','feature_names':[features[i] for i in idx],
   'n_features':len(idx), 'sample_counts':{'P':880,'U':916,'total':1796},
   'source_csv':'SiteWise_PU_1796_Expanded_Observed.csv',
   'source_xlsx':['SiteWise_PU_1849_Recovery_Verified.xlsx','SiteWise_PU_Residential_Density_1849.xlsx'],
   'new_features':'WorldPop MYS 2025 population age groups; OSM residential buildings and landuse',
   'new_data_missing':'232 residential-feature values are missing across 38 locations; within-estimator median imputation and missingness indicators; original 47 features remain observed',
   'worldpop_age_coverage':'1067 completed, 590 partial coverage, 139 low coverage',
   'excluded_landscan':'3 LandScan ambient population fields omitted due licence provenance concerns',
   'spatial_validation':'3 0.07-degree grid-cell GroupShuffleSplit holdouts with identical splits across variants',
   'mean_cv_auc_P_vs_U':auc,
   'prediction_semantics':'Research-only P-vs-U association. Unlabelled are not confirmed negatives. NOT probability of profitable F&B, NOT category suitability.',
   'pu_method':'Resample 78% of unlabelled reference backgrounds in each bag, fit one logistic classifier with all P; mean probability across 5 bags',
   'license_and_provenance_hold':'Age raster incomplete for some properties; some source/positive verification and potential competitor self-match concerns remain',
   'research_only':True,'production_ready':False,
   'integration_warning':'Do not replace existing 47-feature SiteWise joblib; this requires versioned feature extraction and adapter',
   'sklearn_version':sklearn.__version__,'random_seed':20261115
 },'estimators':m}
 fname=f'SiteWise_PU_{len(idx)}_Logistic_{label}_ResearchOnly.joblib'
 path=ROOT/fname
 joblib.dump(obj,path,compress=3)
 test=joblib.load(path)
 probs=bag_predict(test['estimators'],X[:10][:,idx]);assert np.isfinite(probs).all()
 assert (probs>=0).all() and (probs<=1).all()
 print('SAVED',fname,'size',path.stat().st_size,'sample',np.round(probs[:3],4),flush=True)
