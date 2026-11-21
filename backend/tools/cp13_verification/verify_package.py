"""Reproduce the delivered command demonstrations; never enables live writes."""
import json
import subprocess
import sys
from datetime import datetime,timezone
from pathlib import Path
import bootstrap

def main():
    out=bootstrap.ROOT/'artifacts/cp13_20261119/independent'/('delivery_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S'))
    out.mkdir(parents=True,exist_ok=True)
    script=str(bootstrap.PACKAGE/'cp13_manual_verify.py')
    cases=[('inspect',['--mode','inspect','--database-readback','--quiet'],0,None),
        ('bdj',['--mode','controlled','--module','bdj','--case','conflicting','--quiet'],0,None),
        ('bcb',['--mode','controlled','--module','bcb','--case','complete','--quiet'],0,None),
        ('direct_qg',['--mode','controlled','--module','direct-qg','--case','invalid-question','--quiet'],0,None),
        ('all_cases',['--mode','controlled','--all-cases','--database-readback','--quiet'],0,None),
        ('live_blocked',['--mode','live','--module','all','--case','complete','--quiet'],2,None),
        ('interactive_bdj',['--menu','--quiet'],0,'2\ncontrolled\ncomplete\n')]
    evidence=[]
    for name,args,expected,stdin in cases:
        cmd=[sys.executable,'-B',script,*args,'--output',str(out/name)]
        run=subprocess.run(cmd,cwd=bootstrap.ROOT,input=stdin,text=True,capture_output=True,encoding='utf-8',timeout=90)
        (out/(name+'.log')).write_text(run.stdout+run.stderr,encoding='utf-8')
        evidence.append(dict(name=name,command=cmd,expected_exit_code=expected,actual_exit_code=run.returncode,
            status='PASS' if run.returncode==expected else 'FAIL',stdin=stdin))
        print(name+': '+evidence[-1]['status'],flush=True)
    cmd=[sys.executable,'-B','-m','pytest',str(bootstrap.PACKAGE),'--confcutdir='+str(bootstrap.PACKAGE),'-q','--junitxml='+str(out/'pytest.xml')]
    run=subprocess.run(cmd,cwd=bootstrap.ROOT,text=True,capture_output=True,encoding='utf-8',timeout=90)
    (out/'pytest.log').write_text(run.stdout+run.stderr,encoding='utf-8')
    evidence.append(dict(name='pytest',command=cmd,expected_exit_code=0,actual_exit_code=run.returncode,
        status='PASS' if run.returncode==0 else 'FAIL'))
    (out/'executed_commands.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
    print(run.stdout)
    print('Evidence: '+str(out))
    return 0 if all(x['status']=='PASS' for x in evidence) else 1

if __name__=='__main__':raise SystemExit(main())
