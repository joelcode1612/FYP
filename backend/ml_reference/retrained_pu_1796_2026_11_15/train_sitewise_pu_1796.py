"""Reproducible SiteWise PU *research* retraining, observed-only 1,796 subjects.

Run: python train_sitewise_pu_1796.py --input SiteWise_PU_1796_Observed_47_Features.csv --out .
No imputed 103 values and no direct DB modifications. P-vs-U evaluation is NOT success prediction.
CSV from verified workbook; model artifacts are research-only, not direct substitutes for SiteWise's current ModelLoader.
"""
import argparse, csv, json, hashlib, math, os, sys
from pathlib import Path
from collections import Counter
import numpy as np
from sklearn.base import clone
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score, average_precision_score, balanced_accuracy_score
from sklearn.model_selection import GroupShuffleSplit
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
import sklearn, joblib

SOURCE='SiteWise_PU_1849_Recovery_Verified.xlsx'
LANDSCAN=['landscan_ambient_pop_1000m','landscan_ambient_pop_2000m','landscan_ambient_pop_3000m']
FNB_COMPETITOR=['fnb_competitors_500m','fnb_competitors_1000m','cafe_count_500m','cafe_count_1000m','restaurant_count_500m','restaurant_count_1000m','fast_food_count_500m','fast_food_count_1000m','bakery_dessert_beverage_count_500m','bakery_dessert_beverage_count_1000m']

def read_input(path):
    with open(path,encoding='utf-8-sig',newline='') as f:
        rd=csv.DictReader(f)
        cols=rd.fieldnames
        assert cols[:5]==['subject_id','sample_class','latitude','longitude','state_dosm']
        names=cols[5:]
        assert len(names)==47 and len(set(names))==47
        rows=list(rd)
    assert len(rows)==1796 and len(set(r['subject_id'] for r in rows))==1796
    y=np.array([1 if r['sample_class']=='P' else 0 if r['sample_class']=='U' else -1 for r in rows],dtype=int)
    assert Counter(y)=={0:916,1:880}
    X=np.array([[float(r[n]) for n in names] for r in rows],dtype=np.float64)
    assert X.shape==(1796,47) and np.isfinite(X).all(), 'Input must contain no missing/estimated feature cells'
    ll=np.array([[float(r['latitude']),float(r['longitude'])] for r in rows]);assert np.isfinite(ll).all()
    group=np.array([f'{math.floor(lat/0.07):04d}_{math.floor(lon/0.07):04d}' for lat,lon in ll])
    return rows, names, X, y, group

def make_pipe(kind,seed):
    if kind=='Logistic':
        return Pipeline([
            ('imputer',SimpleImputer(strategy='median', add_indicator=False)),
            ('scale', StandardScaler()),
            ('estimator',LogisticRegression(C=0.5,max_iter=600,solver='lbfgs',class_weight='balanced',random_state=seed))
        ])
    if kind=='HistogramGradientBoosting':
        return Pipeline([
            ('imputer',SimpleImputer(strategy='median', add_indicator=False)),
            ('estimator',HistGradientBoostingClassifier(max_iter=105,max_leaf_nodes=13,min_samples_leaf=28,learning_rate=0.06,l2_regularization=4.,random_state=seed))
        ])
    raise ValueError(kind)

def fitted_bag(X,y,kind,seed,n_bags=3,frac=.78):
    p=np.where(y==1)[0];u=np.where(y==0)[0]
    models=[]
    for j in range(n_bags):
        rng=np.random.default_rng(seed+j*17)
        u_sel=rng.choice(u,size=max(1,int(round(len(u)*frac))),replace=False)
        idx=np.concatenate([p,u_sel])
        rng.shuffle(idx)
        model=make_pipe(kind,seed+43*j)
        model.fit(X[idx],y[idx]);models.append(model)
    return models

def predict_bag(models,X):
    return np.mean(np.stack([m.predict_proba(X)[:,1] for m in models],axis=0),axis=0)

def evaluate_cv(X,y,groups,subsets):
    split=GroupShuffleSplit(n_splits=3,test_size=.23,random_state=20261115)
    splits=list(split.split(X,y,groups))
    all_results=[]; heldout=[]
    for fold,(tr,va) in enumerate(splits,1):
        trc=Counter(y[tr]);vac=Counter(y[va]); ng=len(set(groups[va]))
        assert len(trc)==2 and len(vac)==2 and min(vac.values())>25,(fold,trc,vac)
        print(f'FOLD {fold}: train={len(tr)} {trc}, validation={len(va)} {vac}, heldout_grid_cells={ng}',flush=True)
        for subset_name, indices in subsets.items():
            for kind in ['Logistic','HistogramGradientBoosting']:
                bag=fitted_bag(X[tr][:,indices],y[tr],kind,seed=1000+fold*111+len(indices),n_bags=3)
                score=predict_bag(bag,X[va][:,indices])
                auc=float(roc_auc_score(y[va],score));ap=float(average_precision_score(y[va],score))
                bal=float(balanced_accuracy_score(y[va],score>=.5))
                all_results.append({'fold':fold,'feature_subset':subset_name,'n_features':len(indices),'algorithm':kind,'train_rows':len(tr),'test_rows':len(va),'train_P':trc[1],'train_U':trc[0],'test_P':vac[1],'test_U':vac[0], 'heldout_spatial_groups':ng,'roc_auc_P_vs_U':round(auc,6),'average_precision_P_vs_U':round(ap,6),'balanced_accuracy_at_05':round(bal,6)})
                heldout.extend([{'fold':fold,'subject_id':str(ids[k]),'sample_class':('P' if y[k] else 'U'),'feature_subset':subset_name,'algorithm':kind,'score_P_vs_U':round(float(p),8)} for k,p in zip(va,score)])
                print('  ',subset_name,kind,'AUC',round(auc,4),'AP',round(ap,4),'BA',round(bal,4),flush=True)
    return all_results,heldout

def save_csv(filename,rows,fields=None):
    if not rows: return
    fields=fields or list(rows[0].keys())
    with open(filename,'w',newline='',encoding='utf-8-sig') as f:
        w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(rows)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--input',required=True);parser.add_argument('--out',required=True)
    args=parser.parse_args();dest=Path(args.out);dest.mkdir(parents=True,exist_ok=True)
    global ids
    rows,names,X,y,groups=read_input(args.input);ids=[r['subject_id'] for r in rows]
    subsets={
       'full_47_licence_hold':np.arange(47,dtype=int),
       'no_landscan_44':np.array([i for i,n in enumerate(names) if n not in LANDSCAN],dtype=int),
       'conservative_34':np.array([i for i,n in enumerate(names) if n not in (LANDSCAN+FNB_COMPETITOR)],dtype=int)
    }
    assert {k:len(x) for k,x in subsets.items()}=={'full_47_licence_hold':47,'no_landscan_44':44,'conservative_34':34}
    print('DATA',X.shape,'class',Counter(y),'unique geo cells',len(set(groups)),flush=True)
    res,pred=evaluate_cv(X,y,groups,subsets)
    save_csv(dest/'SiteWise_PU_Spatial_Validation_Fold_Results.csv',res)
    save_csv(dest/'SiteWise_PU_Spatial_Validation_Predictions.csv',pred)
    summary=[]
    for subset,indices in subsets.items():
        for kind in ['Logistic','HistogramGradientBoosting']:
            rs=[r for r in res if r['feature_subset']==subset and r['algorithm']==kind]
            summary.append({'feature_subset':subset,'features':len(indices),'algorithm':kind,'mean_auc_P_vs_U':round(float(np.mean([r['roc_auc_P_vs_U'] for r in rs])),6),'std_auc':round(float(np.std([r['roc_auc_P_vs_U'] for r in rs],ddof=1)),6),'mean_ap_P_vs_U':round(float(np.mean([r['average_precision_P_vs_U'] for r in rs])),6),'mean_bal_acc':round(float(np.mean([r['balanced_accuracy_at_05'] for r in rs])),6)})
    save_csv(dest/'SiteWise_PU_Model_Comparison.csv',summary)
    # Select from lower-risk feature sets only; full_47 is for compatibility research and explicitly licence held.
    safe=[r for r in summary if r['feature_subset']!='full_47_licence_hold']
    best=max(safe,key=lambda r:(r['mean_auc_P_vs_U'],r['mean_ap_P_vs_U']))
    full_best=max([r for r in summary if r['feature_subset']=='full_47_licence_hold'],key=lambda r:(r['mean_auc_P_vs_U'],r['mean_ap_P_vs_U']))
    chosen=[('recommended_research',best),('full47_restricted',full_best)]
    artifact_paths=[]
    for tag,config in chosen:
        feats=config['feature_subset'];idx=subsets[feats];kind=config['algorithm']
        models=fitted_bag(X[:,idx],y,kind,seed=20261115,n_bags=5,frac=.78)
        meta={'project':'SiteWise','dataset_source':SOURCE,'source_csv':Path(args.input).name,
            'sample_counts':{'P':880,'U':916,'total':1796},'excluded_missing_subjects':53,'source_imputed_values_used':0,
            'model_purpose':'Research proxy P-vs-U location association. U are NOT confirmed negatives.',
            'score_interpretation':'Mean bagged P-versus-U association score; NOT calibrated success or business-category suitability probability.',
            'feature_subset':feats,'feature_names':[names[i] for i in idx],
            'n_features':len(idx),'algorithm':kind,'method':'bagged positive-vs-unlabelled proxy classifier with resampled U background',
            'spatial_validation':'0.07-degree cell GroupShuffleSplit 3 holdouts, cells held out entirely; no test data used in fitting',
            'validated_mean_auc_P_vs_U':config['mean_auc_P_vs_U'],
            'research_only':True,'production_ready':False,
            'source_validation_hold':'P positive proof, competitor self-matches and raster coverage not fully checked',
            'licence_hold':('LandScan provenance/rights not cleared by workbook' if feats=='full_47_licence_hold' else 'LandScan omitted; review other data-source licence/provenance before production'),
            'integration_warning':'Not a drop-in replacement for current SiteWise PULearning/ModelLoader; use standalone inference script.',
            'trained_with_sklearn':sklearn.__version__,'random_seed':20261115}
        artifact={'model_info':meta,'estimators':models}
        name=f'SiteWise_PU_{len(idx)}_Features_{tag}_ResearchOnly.joblib'
        destpath=dest/name
        joblib.dump(artifact,destpath,compress=3)
        assert len(artifact['estimators'])==5
        loaded=joblib.load(destpath)
        trial=predict_bag(loaded['estimators'],X[:10][:,idx]);assert np.isfinite(trial).all() and min(trial)>=0 and max(trial)<=1
        print('SAVED MODEL',destpath, 'test first scores', np.round(trial[:3],3).tolist(),flush=True)
        artifact_paths.append(name)
    result={'source':SOURCE,'observed_complete_rows':1796,'excluded_missing_rows':53,'excluded_missing_cells':103,
       'P':880,'U':916,'cv_design':'Three spatial group held-out partitions, no label outcome',
       'feature_subsets':{k:[names[i] for i in v] for k,v in subsets.items()},
       'comparison':summary,'recommended':best,'restricted_47':full_best,'trained_artifacts':artifact_paths,
       'note':'This evaluation tests P-vs-U identification, not business profitability, calibrated P(success), or F&B category prediction.'}
    (dest/'SiteWise_PU_Training_Results.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('SELECTED',best,flush=True);print('FINISHED',flush=True)

if __name__=='__main__':main()
