"""실제 대상 예약 대조의 예산·요청 정산·유휴 상태를 손상해 거절을 확인한다."""
import argparse
import copy
import json
from pathlib import Path
import frame_wake_report
import parse_stage_report
import verify


def review(root, output):
    repository=Path(__file__).resolve().parents[2]
    verify.require(not output.exists() and output!=repository and repository not in output.parents,'new external output required')
    proof=frame_wake_report.read(root)
    verify.require(proof['variant']=='target-coalesced','target comparison required')
    folder=root/'immediate/typing-0'
    original=[json.loads((folder/name).read_text()) for name in ('app.json','posts.json','record.json')]
    control=parse_stage_report.analyze(*copy.deepcopy(original))
    start=original[0]['target_input_start'];mid=original[0]['target_idle_start']
    def at(name,index,value):return lambda a,p,m:a[name].__setitem__(index,value)
    faults=[
        ('hidden-label',lambda a,p,m:m.update(target_frame_control=False)),
        ('actual-label',lambda a,p,m:a.update(target_frame_control=False)),
        ('missing-snapshot',lambda a,p,m:a.update(target_input_start=[])),
        ('boolean-time',at('target_input_start',0,True)),
        ('zero-time',at('target_input_start',0,0)),
        ('dropped-owner',at('target_idle_start',5,1)),
        ('pending-owner',at('target_idle_start',7,1)),
        ('budget-error',at('target_idle_end',10,1)),
        ('time-backwards',at('target_idle_start',0,start[0])),
        ('missing-header',lambda a,p,m:a.update(target_budget_header=[])),
        ('row-count',at('target_budget_header',0,0)),
        ('denial-count',at('target_budget_header',1,original[0]['target_budget_header'][1]+1)),
        ('native-overflow',at('target_budget_header',2,1)),
        ('extra-owner',at('target_budget_header',3,2)),
        ('row-width',lambda a,p,m:a['target_budget_rows'][0].pop()),
        ('zero-owner',lambda a,p,m:a['target_budget_rows'][0].__setitem__(0,0)),
        ('zero-clock',lambda a,p,m:a['target_budget_rows'][0].__setitem__(1,0)),
        ('wrong-hz',lambda a,p,m:a['target_budget_rows'][0].__setitem__(2,120)),
        ('invalid-allowed',lambda a,p,m:a['target_budget_rows'][0].__setitem__(3,2)),
        ('boolean-allowed',lambda a,p,m:a['target_budget_rows'][0].__setitem__(3,True)),
        ('wrong-extra-count',at('target_idle_start',2,mid[2]+1)),
        ('wrong-consumed-count',at('target_idle_start',3,mid[3]+1)),
        ('wrong-merged-count',at('target_idle_start',4,mid[4]+1)),
        ('interval-budget-count',at('target_idle_start',8,mid[8]+1)),
        ('idle-rearm',at('target_idle_end',6,mid[6]+1)),
        ('negative-counter',at('target_idle_end',1,-1)),
        ('overflow-counter',at('target_idle_end',1,2**64)),
        ('float-counter',at('target_idle_end',1,100.0)),
    ]
    output.mkdir(mode=0o700)
    rejected=[]
    for name,mutate in faults:
        values=copy.deepcopy(original);mutate(*values)
        try:parse_stage_report.analyze(*values)
        except ValueError as error:reason=str(error)
        else:raise ValueError('mutation survived: '+name)
        verify.require(parse_stage_report.analyze(*copy.deepcopy(original))==control,'normal control changed')
        (output/(name+'.json')).write_text(json.dumps(dict(app=values[0],posts=values[1],record=values[2]),indent=2)+'\n')
        rejected.append(dict(name=name,reason=reason))
    verify.require(frame_wake_report.read(root)==proof,'original comparison changed')
    result=dict(rejected=rejected,normal_controls=len(faults)+1,source_hashes={name:verify.sha(folder/name) for name in ('app.json','posts.json','record.json')})
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('root',type=Path);parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args();print(json.dumps(review(args.root.resolve(),args.output.resolve()),indent=2))
