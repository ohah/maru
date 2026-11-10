"""실제 화면 timing 자료에 독립 오류를 넣고 정상 전후 대조를 보존한다."""
import argparse
import copy
import json
from pathlib import Path
import display_timing_report as report
import verify


def review(root,output):
    root,output=Path(root).resolve(),Path(output).resolve();proof=report.read(root)
    repository=Path(__file__).resolve().parents[2]
    verify.require(not output.exists() and repository not in output.parents and output!=repository,'new external output required')
    target=root/'enabled/typing-0';names=('app.json','posts.json','record.json')
    original=[json.loads((target/n).read_text()) for n in names]
    def field(n,v):return lambda a,p,m:a['display_timing'].__setitem__(n,v)
    def context(n,v):return lambda a,p,m:a['display_timing']['context'].__setitem__(n,v)
    def row(n,v):return lambda a,p,m:a['display_timing']['rows'][0].__setitem__(n,v)
    faults=[('mode',field('mode','disabled')),('errors',field('errors',1)),('overflow',field('overflow',1)),
        ('start',field('started',0)),('end',field('ended',1)),('observations',field('observations',1)),('missing-rows',field('rows',[])),
        ('display',context(0,0)),('screen-fps',context(1,0)),('layer',context(2,0)),('sync',context(3,2)),('transaction',context(4,2)),
        ('drawable-count',context(5,1)),('timer-hz',context(6,0)),('missing-context',field('context',[])),
        ('callback-start',row(0,0)),('timestamp',row(1,0)),('target',row(2,1)),('duration',row(3,0)),('callback-end',row(4,1)),
        ('bool-timestamp',row(1,True)),('negative-timestamp',row(1,-1)),('u64-overflow',row(2,2**64)),
        ('wrong-row-shape',lambda a,p,m:a['display_timing']['rows'][0].pop())]
    output.mkdir(mode=0o700);baseline=report.analyze(*copy.deepcopy(original),'enabled');rejected=[]
    for name,mutate in faults:
        verify.require(report.analyze(*copy.deepcopy(original),'enabled')==baseline,'normal pre-control changed')
        changed=copy.deepcopy(original);mutate(*changed)
        try:report.analyze(*changed,'enabled')
        except ValueError as error:reason=str(error)
        else:raise ValueError('display timing mutation survived: '+name)
        (output/(name+'.json')).write_text(json.dumps(dict(zip(names,changed)),indent=2)+'\n')
        rejected.append(dict(name=name,reason=reason))
        verify.require(report.analyze(*copy.deepcopy(original),'enabled')==baseline,'normal post-control changed')
    equivalent=copy.deepcopy(original);equivalent[0]['unrelated_note']='equivalent'
    verify.require(report.analyze(*equivalent,'enabled')==baseline,'equivalent control rejected')
    result=dict(source=str(target),source_hashes={n:verify.sha(target/n) for n in names},rejected=rejected,normal_controls=2*len(faults),equivalent_controls=1)
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    verify.require(report.read(root)==proof,'original display timing source changed')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('root',type=Path);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    print(json.dumps(review(args.root,args.output),indent=2))
