#!/usr/bin/env python3
"""완전한 A/B 묶음만 수락한다. 실패한 묶음은 보존하며 명시적 resume에서 다시 실행한다."""
import argparse, json, pathlib, subprocess, sys
import verify
HERE=pathlib.Path(__file__).resolve().parent

def main():
 p=argparse.ArgumentParser();p.add_argument('--build',required=True,type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path);p.add_argument('--resume',action='store_true');p.add_argument('--events',type=int,default=30);p.add_argument('--repetitions',type=int,default=3);a=p.parse_args();out=a.output.resolve()
 if (out.exists() and not a.resume) or out==HERE.parents[1] or HERE.parents[1] in out.parents:p.error('external output required')
 out.mkdir(exist_ok=a.resume);state=json.loads((out/'suite.json').read_text()) if a.resume else {'events':a.events,'repetitions':a.repetitions,'build':str(a.build.resolve()),'accepted':{},'rejected':[]}
 if state['events']!=a.events or state['repetitions']!=a.repetitions or state['build']!=str(a.build.resolve()):p.error('suite configuration changed')
 (out/'suite.json').write_text(json.dumps(state,indent=2))
 for size in [3000,50000]:
  for flow in ['typing','ime','shared']:
   case=str(size)+'-'+flow
   if case in state['accepted']:verify.verify(out/state['accepted'][case]);continue
   folder=case+'-attempt-'+str(len(list(out.glob(case+'-attempt-*'))));target=out/folder
   command=[sys.executable,str(HERE/'run.py'),'--build',str(a.build),'--output',str(target),'--sizes',str(size),'--flows',flow,'--events',str(a.events),'--repetitions',str(a.repetitions)]
   result=subprocess.run(command)
   if result.returncode:
    state['rejected'].append({'path':folder,'exit':result.returncode});(out/'suite.json').write_text(json.dumps(state,indent=2));raise SystemExit(result.returncode)
   summary=verify.verify(target);(target/'summary.json').write_text(json.dumps(summary,indent=2));state['accepted'][case]=folder;(out/'suite.json').write_text(json.dumps(state,indent=2))
 if len(state['accepted'])!=6:raise ValueError('incomplete suite')
 print(out)
if __name__=='__main__':main()
