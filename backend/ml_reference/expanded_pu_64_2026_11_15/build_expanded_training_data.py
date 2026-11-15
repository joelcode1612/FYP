"""Build SiteWise expanded PU training matrix from verified observed-only inputs.
Uses artifact_tool for spreadsheet reads and csv stdlib for model-ready export.
Never changes the original workbooks or database. Only existing 1796 complete-case IDs used.
"""
import csv, json, math
from collections import Counter
from pathlib import Path
from artifact_tool import Blob, SpreadsheetFile

ROOT = Path('/mnt/data')
OUT = ROOT / 'SiteWise_PU_Expanded_2026_11_15'
BASE = ROOT / 'SiteWise_PU_Retraining_1796' / 'SiteWise_PU_1796_Observed_47_Features.csv'
AGE = ROOT / 'SiteWise_PU_1849_Recovery_Verified.xlsx'
RES = ROOT / 'SiteWise_PU_Residential_Density_1849.xlsx'
OUT.mkdir(exist_ok=True)
AGE_FEATURES = [f'pop_age_{band}_{radius}' for radius in ['500m', '1km'] for band in ['0_14','15_24','25_34','35_49','50_64','65_plus']]
RES_FEATURES = [f'residential_{field}_{radius}' for field in ['building_count', 'building_density', 'footprint_coverage', 'landuse_coverage'] for radius in ['500m','1000m']]
RES_FEATURES = [x.replace('residential_building_count_', 'residential_building_count_').replace('residential_building_density_', 'residential_building_density_')+('_km2' if 'building_density' in x else '_pct' if 'coverage' in x else '') for x in RES_FEATURES]

with BASE.open('r',encoding='utf-8-sig',newline='') as f:
 reader=csv.DictReader(f); base_rows=list(reader); base_names=list(reader.fieldnames)
assert len(base_rows)==1796 and len({r['subject_id'] for r in base_rows})==1796

w_age=SpreadsheetFile.import_xlsx(Blob.load(str(AGE))); s_age=w_age.worksheets.get_item('PU 47 Features')
h_age=s_age.get_range('A1:CK1').values[0]
assert set(AGE_FEATURES).issubset(h_age)
# Import only needed slices for memory efficiency
ids_age=s_age.get_range('A2:B1850').values
age_values=s_age.get_range('BT2:CE1850').values # 12 age count columns
age_status=s_age.get_range('CJ2:CJ1850').values
age_source=s_age.get_range('CH2:CI1850').values
age_map={}
for (sid,cl), v, st, src in zip(ids_age,age_values,age_status,age_source):
 sid=str(sid).strip()
 assert sid not in age_map, sid
 assert len(v)==12
 age_map[sid]=(str(cl).strip(),v,str(st[0]),src)

w_res=SpreadsheetFile.import_xlsx(Blob.load(str(RES))); s_res=w_res.worksheets.get_item('01_Combined_P_U')
head_res=s_res.get_range('A1:S1').values[0]
res_vals=s_res.get_range('A2:S1850').values
assert set(RES_FEATURES).issubset(head_res), (RES_FEATURES,head_res)
res_map={}
for row in res_vals:
 sid=str(row[0]).strip()
 assert sid not in res_map, sid
 res_map[sid]=dict(zip(head_res,row))

miss=Counter(); status=Counter(); source=Counter(); checks={'age_mismatch':[], 'res_mismatch':[]}
output=[]
for r in base_rows:
 sid=r['subject_id'];cl=r['sample_class']
 assert sid in age_map and sid in res_map, sid
 cl_age,ages,st,src=age_map[sid];res=res_map[sid]
 assert cl_age==cl, ('age label mismatched',sid,cl,cl_age)
 assert str(res['sample_class']).strip()==cl, ('res label mismatched',sid,cl,res['sample_class'])
 status[st]+=1
 source[str(src[1])]+=1
 combined={k:r[k] for k in base_names}
 for name,val in zip(AGE_FEATURES,ages):
  if val is None or str(val).strip()=='': miss[name]+=1; combined[name]='';continue
  f=float(val);assert math.isfinite(f) and f>=0,(sid,name,val)
  combined[name]=f
 for name in RES_FEATURES:
  val=res[name]
  if val is None or str(val).strip()=='': miss[name]+=1;combined[name]='';continue
  f=float(val);assert math.isfinite(f) and f>=0,(sid,name,val)
  combined[name]=f
 combined['age_data_status']=st
 combined['age_data_source_year']=src[1]
 output.append(combined)

with (OUT/'SiteWise_PU_1796_Expanded_Observed.csv').open('w',encoding='utf-8-sig',newline='') as f:
 names=base_names+AGE_FEATURES+RES_FEATURES+['age_data_status','age_data_source_year']
 wr=csv.DictWriter(f,fieldnames=names);wr.writeheader();wr.writerows(output)
result={'source_workbooks':[str(BASE),str(AGE),str(RES)],'unique_subjects':len(output),'labels':dict(Counter(r['sample_class'] for r in output)),'baseline_features':47,'added_age_features':AGE_FEATURES,'added_residential_features':RES_FEATURES,'numeric_features_total_before_landscan_removal':47+len(AGE_FEATURES)+len(RES_FEATURES),'age_source_years':dict(source),'age_status_counts':dict(status),'new_feature_missing_counts':dict(miss),'nonmissing_new_feature_cells':len(output)*(len(AGE_FEATURES)+len(RES_FEATURES))-sum(miss.values()),'training_hold':'Research only. Age raster incomplete for flagged rows. LandScan restrictions remain. Positive labels need independent validation.'}
(OUT/'Expanded_Data_QA.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result,indent=2),flush=True)
