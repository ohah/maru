"""실제 관측기 CPU 경계·타입·오류·과대 귀속을 손상시켜 거절을 확인한다."""
import argparse,copy,json
from pathlib import Path
import frame_wake_report
import parse_stage_report
import verify


def review(root, output):
    repository=Path(__file__).resolve().parents[2]
    verify.require(not output.exists() and output!=repository and repository not in output.parents,'new external output required')
    proof=frame_wake_report.read(root)
    folder=root/'immediate/typing-0'
    original=[json.loads((folder/name).read_text()) for name in ('app.json','posts.json','record.json')]
    normal=parse_stage_report.analyze(*copy.deepcopy(original));verify.require('observer_cpu' in normal,'observer CPU study required')
    a,b=original[0]['observer_input_start'],original[0]['observer_idle_start']
    def at(name,index,value):return lambda a,p,m:a[name].__setitem__(index,value)
    faults=[
        ('metadata-label',lambda a,p,m:m.update(observer_cpu=False)),
        ('actual-label',lambda a,p,m:a.update(observer_cpu=False)),
        ('missing-start',lambda a,p,m:a.update(observer_input_start=[])),
        ('short-row',lambda a,p,m:a['observer_idle_start'].pop()),
        ('boolean-time',at('observer_input_start',0,True)),('zero-time',at('observer_input_start',0,0)),
        ('time-backwards',at('observer_idle_start',0,a[0])),
        ('cpu-backwards',at('observer_idle_start',1,a[1]-1)),
        ('calls-backwards',at('observer_idle_start',2,a[2])),
        ('outside-handler',at('observer_idle_start',3,0)),
        ('start-error',at('observer_input_start',4,1)),
        ('idle-start-error',at('observer_idle_start',4,1)),
        ('idle-end-error',at('observer_idle_end',4,1)),
        ('negative-time',at('observer_idle_end',0,-1)),
        ('negative-cpu',at('observer_idle_end',1,-1)),
        ('overflow-cpu',at('observer_idle_end',1,2**64)),
        ('float-cpu',at('observer_idle_end',1,100.0)),
        ('boolean-cpu',at('observer_idle_end',1,True)),
        ('negative-calls',at('observer_idle_end',2,-1)),
        ('boolean-depth',at('observer_idle_end',3,True)),
        ('over-attributed-idle',at('observer_idle_end',1,b[1]+10**15)),
    ]
    output.mkdir(mode=0o700);rejected=[]
    for name,mutate in faults:
        values=copy.deepcopy(original);mutate(*values)
        try:parse_stage_report.analyze(*values)
        except ValueError as error:reason=str(error)
        else:raise ValueError('mutation survived: '+name)
        verify.require(parse_stage_report.analyze(*copy.deepcopy(original))==normal,'normal control changed')
        (output/(name+'.json')).write_text(json.dumps(dict(app=values[0],posts=values[1],record=values[2]),indent=2)+'\n');rejected.append(dict(name=name,reason=reason))
    verify.require(frame_wake_report.read(root)==proof,'original study changed')
    result=dict(rejected=rejected,normal_controls=len(faults)+1,source_hashes={name:verify.sha(folder/name) for name in ('app.json','posts.json','record.json')})
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n');return result


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('root',type=Path);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();print(json.dumps(review(args.root.resolve(),args.output.resolve()),indent=2))
