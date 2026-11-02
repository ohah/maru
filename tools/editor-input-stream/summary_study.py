#!/usr/bin/env python3
"""동일 실행 파일의 워커 준비 유무를 교대로 비교한다. 프로파일러는 붙이지 않는다."""
import argparse
import json
from pathlib import Path
import shutil
import sys

import protocol
import run
import summarize
import verify
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'editor-input-attribution'))
from observer import diagnostic_environment


def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n')


def compare(root):
    study=json.loads((root/'study.json').read_text())
    verify.require(study['complete'] is True,'summary study incomplete')
    before=summarize.summarize(root/'disabled');after=summarize.summarize(root/'prepared')
    verify.require(before['app_sha256']==after['app_sha256'] and before['producer_sha256']==after['producer_sha256'] and before['head']==after['head'],'study executable/source differs')
    field=study.get('cache','summary')+'_control'
    verify.require(before[field]=='disabled' and after[field]=='prepared','study path labels')
    verify.require(before['processes']==after['processes'] and before['inputs']==after['inputs'],'study population differs')
    verify.require([r['path'] for r in verify.read(root/'disabled')['runs']]==[r['path'] for r in verify.read(root/'prepared')['runs']],'study pairing differs')
    write(root/'before.json',before);write(root/'after.json',after)
    return dict(schema=1,kind='worker-cache-study',cache=study.get('cache','summary'),app_sha256=before['app_sha256'],head=before['head'],before=before,after=after)


def main():
    p=argparse.ArgumentParser();p.add_argument('--build',required=True,type=Path);p.add_argument('--output',required=True,type=Path)
    p.add_argument('--cache',choices=['summary','fold'],default='summary');p.add_argument('--sizes',default='3000,50000');p.add_argument('--periods',default='50,100');p.add_argument('--flows',default='typing,shared');p.add_argument('--repetitions',type=int,default=3)
    args=p.parse_args();out=args.output.resolve();build=args.build.resolve();root=HERE.parents[1]
    sizes=[int(n) for n in args.sizes.split(',')];periods=[int(n) for n in args.periods.split(',')];flows=args.flows.split(',')
    if out.exists() or out==root or root in out.parents or args.repetitions<1 or any(not x or len(x)!=len(set(x)) for x in [sizes,periods,flows]) or not set(sizes)<={3000,50000} or not set(periods)<={50,100} or not set(flows)<={'typing','shared'}:p.error('new external output and fixed matrix required')
    source=json.loads((build/'source.json').read_text());verify.require(source.get(args.cache+'_control') is True,'controlled summary build required')
    out.mkdir(mode=0o700)
    tool_paths=[HERE/n for n in ['run.py','verify.py','protocol.py','summary_control.py','fold_control.py','summarize.py','summary_study.py']]+[HERE.parent/'editor-input-attribution/observer.py']
    tools={str(path.relative_to(root)):verify.sha(path) for path in tool_paths}
    for path in tool_paths:
        target=out/'tool-snapshot'/path.relative_to(root);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,target)
    study=dict(schema=1,kind='worker-cache-study',cache=args.cache,complete=False,tools=tools,pairs=[])
    manifests={}
    for label in ['disabled','prepared']:
        (out/label).mkdir(mode=0o700)
        manifests[label]=dict(schema=1,protocol=protocol.NAME,build=str(build),source=source,runner_sha256=verify.sha(HERE/'run.py'),verifier_sha256=verify.sha(HERE/'verify.py'),**{args.cache+"_control":label},sizes=sizes,periods=periods,flows=flows,modes=['async'],repetitions=args.repetitions,count=30,kind='normal',runs=[])
        write(out/label/'manifest.json',manifests[label])
    for size in sizes:
        for period in periods:
            for flow in flows:
                for rep in range(args.repetitions):
                    name=f'{size}-{period}-{flow}-{rep}-async'
                    order=['disabled','prepared'] if rep%2==0 else ['prepared','disabled']
                    for label in order:
                        print(label,name,flush=True)
                        result=run.trial(build,out/label/name,size,'async',flow,period,30,'normal',rep,**{args.cache+"_control":label},environment_filter=diagnostic_environment)
                        manifests[label]['runs'].append(dict(path=name,record_sha256=verify.sha(out/label/name/'record.json')))
                        write(out/label/'manifest.json',manifests[label])
                        if result['error'] is not None:raise RuntimeError('invalid summary study: '+str(result['error']))
                    study['pairs'].append(dict(path=name,order=order));write(out/'study.json',study)
    verify.require(all(verify.sha(root/n)==h for n,h in tools.items()),'study tools changed')
    study['complete']=True;write(out/'study.json',study)
    write(out/'comparison.json',compare(out));print(out)


if __name__=='__main__':main()
