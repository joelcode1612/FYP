"""Explicit operator diagnostic over actual saved synthetic case answers.

Refuses a non-completed case. No collection, consent or report admission.
"""
import argparse
from datetime import datetime,timezone
import json
from pathlib import Path
from uuid import UUID
from import_mock_to_dss import configured_urls
from sqlalchemy import create_engine,text
from sitewise.services.ee01_service import Ee01Service
from sitewise.services.synthetic_execution_service import SyntheticExecutionService
from sitewise.services.synthetic_preview_boundary import SyntheticPreviewAuthorization


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run-id',type=UUID,required=True);p.add_argument('--session-id',type=UUID,required=True)
    p.add_argument('--developer',type=UUID,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--slot',default='Q05');a=p.parse_args()
    admin_url,runtime_url=configured_urls()
    runtime=create_engine(runtime_url,hide_parameters=True)
    current=SyntheticExecutionService(runtime).execute(a.developer,a.run_id,a.session_id,'read')
    if current.get('lifecycle_status')!='COMPLETED' or current.get('status')!='SUBMITTED':
        raise ValueError('A genuine saved completion of this nonhuman case is required')
    admin=create_engine(admin_url,hide_parameters=True,connect_args={'options':'-c default_transaction_read_only=on'})
    with admin.connect() as c:
        campaign=c.execute(text('SELECT c.* FROM cq_campaigns c JOIN cq_sessions s ON s.campaign_id=c.id JOIN cq_synthetic_cases x ON x.session_id=s.id '
            'WHERE s.id=:sid AND x.run_id=:run AND x.scenario=\'NORMAL\''),{'sid':a.session_id,'run':a.run_id}).mappings().one()
        role=c.execute(text("SELECT rolsuper,rolbypassrls FROM pg_roles WHERE rolname='p1_ee01_runtime'")).one()
        if tuple(role)!=(False,False):raise ValueError('Restricted diagnostic runtime required')
    cutoff=datetime.now(timezone.utc);calc=Ee01Service(runtime,SyntheticPreviewAuthorization(a.run_id));result=[]
    for rule in sorted(Ee01Service.RULES):
        row=calc.build_diagnostic(campaign['owner_user_id'],campaign['assessment_id'],campaign['id'],a.slot,cutoff,rule)
        if row['scope']!='ISOLATED_TEST' or any(v['percentage'] is not None for v in row['cells']):raise ValueError('Diagnostic withholding failed')
        # Read the persisted rows through the real developer grant as well.
        read=Ee01Service(runtime,SyntheticPreviewAuthorization(a.run_id,developer_user_id=a.developer))
        assert read.read(a.developer,campaign['assessment_id'],campaign['id'],UUID(row['id']))['fingerprint']==row['fingerprint']
        with admin.connect() as c:
            query=Path(__file__).resolve().parents[1]/'tests/cq_runtime/VERIFY_EE01_FROM_CQ.sql'
            sql=query.read_text();sql=sql[sql.index('WITH bound AS'):sql.index('COMMIT;')]
            sql=sql.replace("'CUSTOMER_DEMAND_SURVEY'","'DEVELOPER_PREVIEW'")
            for k,v in {'actor_id':campaign['owner_user_id'],'assessment_id':campaign['assessment_id'],'campaign_id':campaign['id'],'snapshot_id':row['id']}.items():
                sql=sql.replace(":"+"'"+k+"'", "'"+str(v)+"'")
            oracle=c.execute(text(sql)).scalar_one()
            assert oracle['matches_saved_counts']
        result.append({'measurement':row,'independent_raw_CQ_oracle':oracle})
    a.output.mkdir(parents=True,exist_ok=True)
    (a.output/'actual_phone_case_EE01.json').write_text(json.dumps({'source':'actual Dss persisted synthetic case; no seeded case answers','session_id':str(a.session_id),
        'run_id':str(a.run_id),'cutoff':cutoff.isoformat(),'measurements':result,'real_report_admitted':False},indent=2),encoding='utf-8')
    print(json.dumps([{'id':x['measurement']['id'],'Q':x['measurement']['q'],'S':x['measurement']['s'],'A':x['measurement']['a'],'V':x['measurement']['v'],
        'independent_SQL_matches':x['independent_raw_CQ_oracle']['matches_saved_counts']} for x in result]))
    admin.dispose();runtime.dispose()


if __name__=='__main__':main()
