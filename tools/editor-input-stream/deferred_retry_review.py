"""실제 거절·기한·요청 정산을 독립 손상시키고 원본 대조를 보존한다."""
import argparse,copy,json
from pathlib import Path
import deferred_retry_report
import parse_stage_report
import verify


def review(root,output):
    repository=Path(__file__).resolve().parents[2]
    verify.require(not output.exists() and output!=repository and repository not in output.parents,'new external output required')
    proof=deferred_retry_report.read(root)
    folder=root/'with_retry/typing-0'
    original=[json.loads((folder/name).read_text()) for name in ('app.json','posts.json','record.json')]
    normal=parse_stage_report.analyze(*copy.deepcopy(original))
    event=original[0]['retry_events'][0]
    def at(name,index,value):return lambda a,p,m:a[name].__setitem__(index,value)
    def cell(index,value):return lambda a,p,m:a['retry_events'][0].__setitem__(index,value)
    faults=[
        ('metadata-mode',lambda a,p,m:m.update(deferred_retry_control='without_retry')),
        ('actual-mode',lambda a,p,m:a.update(deferred_retry_mode='without_retry')),
        ('budget-baseline-disabled',lambda a,p,m:m.update(frame_wake_control='scheduled')),
        ('missing-start',lambda a,p,m:a.update(retry_input_start=[])),
        ('boolean-time',at('retry_input_start',0,True)),('zero-time',at('retry_input_start',0,0)),
        ('time-backwards',at('retry_idle_start',0,original[0]['retry_input_start'][0])),
        ('notices-backwards',at('retry_idle_end',1,0)),
        ('requests-backwards',at('retry_idle_end',2,0)),
        ('start-error',at('retry_input_start',3,1)),('end-error',at('retry_idle_end',3,1)),
        ('population',at('retry_header',0,0)),('overflow',at('retry_header',1,1)),
        ('event-width',lambda a,p,m:a['retry_events'][0].pop()),
        ('zero-owner',cell(0,0)),('negative-at',cell(1,-1)),('boolean-at',cell(1,True)),
        ('deadline-off-by-one',cell(2,event[2]+1)),('rate',cell(3,120)),('runtime-branch',cell(4,0)),
        ('invented-notice',at('retry_idle_start',1,original[0]['retry_idle_start'][1]+1)),
        ('lost-request',at('retry_idle_start',2,original[0]['retry_idle_start'][2]-1)),
        ('counter-overflow',at('retry_idle_end',1,2**64)),
        ('queue-extra-request',at('wake_idle_start',2,original[0]['wake_idle_start'][2]+1)),
        ('unattributed-idle-fire',at('wake_idle_end',3,original[0]['wake_idle_end'][3]+1)),
    ]
    output.mkdir(mode=0o700);rejected=[]
    for name,mutate in faults:
        values=copy.deepcopy(original);mutate(*values)
        try:parse_stage_report.analyze(*values)
        except ValueError as error:reason=str(error)
        else:raise ValueError('mutation survived: '+name)
        verify.require(parse_stage_report.analyze(*copy.deepcopy(original))==normal,'normal control changed')
        (output/(name+'.json')).write_text(json.dumps(dict(app=values[0],posts=values[1],record=values[2]),indent=2)+'\n')
        rejected.append(dict(name=name,reason=reason))
    verify.require(deferred_retry_report.read(root)==proof,'original study changed')
    result=dict(rejected=rejected,normal_controls=len(faults)+1,source_hashes={name:verify.sha(folder/name) for name in ('app.json','posts.json','record.json')})
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n');return result


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    print(json.dumps(review(a.root.resolve(),a.output.resolve()),indent=2))
