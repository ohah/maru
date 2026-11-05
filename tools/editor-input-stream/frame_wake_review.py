"""실제 예약 대조의 라벨·CPU/큐 계수·유휴 상태를 손상시키고 다시 판정한다."""
import argparse
import copy
import json
from pathlib import Path
import frame_wake_report
import parse_stage_report
import verify


def review(root, output):
    repository = Path(__file__).resolve().parents[2]
    verify.require(not output.exists() and output != repository and repository not in output.parents, 'new external output required')
    proof = frame_wake_report.read(root)
    folder = root/'immediate/typing-0'
    original = [json.loads((folder/name).read_text()) for name in ('app.json','posts.json','record.json')]
    normal = parse_stage_report.analyze(*copy.deepcopy(original))
    start = original[0]['wake_input_start']
    mid = original[0]['wake_idle_start']
    def at(name,index,value):return lambda a,p,m:a[name].__setitem__(index,value)
    faults = [
        ('label-hidden',lambda a,p,m:m.update(frame_wake_control=None)),
        ('label-wrong',lambda a,p,m:m.update(frame_wake_control='scheduled')),
        ('actual-mode-wrong',lambda a,p,m:a.update(frame_wake_mode='scheduled')),
        ('missing-start',lambda a,p,m:a.update(wake_input_start=[])),
        ('short-snapshot',lambda a,p,m:a['wake_idle_start'].pop()),
        ('boolean-time',at('wake_input_start',0,True)),
        ('zero-time',at('wake_input_start',0,0)),
        ('cpu-failure',at('wake_idle_start',9,1)),
        ('queued-request',at('wake_idle_start',10,1)),
        ('idle-cpu-failure',at('wake_idle_end',9,1)),
        ('idle-pending-request',at('wake_idle_end',10,1)),
        ('time-backwards',at('wake_idle_start',0,start[0])),
        ('cpu-user-backwards',at('wake_idle_start',7,start[7]-1)),
        ('cpu-system-backwards',at('wake_idle_start',8,start[8]-1)),
        ('no-install-notice',at('wake_idle_start',1,start[1])),
        ('no-active-ticks',at('wake_idle_start',5,start[5])),
        ('no-active-draws',at('wake_idle_start',6,start[6])),
        ('queue-not-balanced',at('wake_idle_start',2,mid[2]+1)),
        ('wake-not-executed',at('wake_idle_start',3,start[3])),
        ('short-idle',at('wake_idle_end',0,mid[0]+1000000000)),
        ('long-idle',at('wake_idle_end',0,mid[0]+6000000000)),
        ('idle-new-notice',at('wake_idle_end',1,mid[1]+1)),
        ('idle-new-request',at('wake_idle_end',2,mid[2]+1)),
        ('idle-fired-request',at('wake_idle_end',3,mid[3]+1)),
        ('idle-coalesced-request',at('wake_idle_end',4,mid[4]+1)),
        ('negative-cpu',at('wake_idle_end',7,-1)),
        ('overflow-cpu',at('wake_idle_end',8,2**64)),
        ('float-cpu',at('wake_idle_end',7,100.0)),
        ('boolean-cpu',at('wake_idle_end',7,True)),
    ]
    output.mkdir(mode=0o700)
    rejected = []
    for name, mutate in faults:
        values = copy.deepcopy(original)
        mutate(*values)
        try:
            parse_stage_report.analyze(*values)
        except ValueError as error:
            reason = str(error)
        else:
            raise ValueError('mutation survived: '+name)
        verify.require(parse_stage_report.analyze(*copy.deepcopy(original)) == normal, 'normal control changed')
        (output/(name+'.json')).write_text(json.dumps(dict(app=values[0],posts=values[1],record=values[2]),indent=2)+'\n')
        rejected.append(dict(name=name,reason=reason))
    verify.require(frame_wake_report.read(root) == proof, 'original comparison changed')
    result = dict(rejected=rejected,normal_controls=len(faults)+1,source_hashes={name:verify.sha(folder/name) for name in ('app.json','posts.json','record.json')})
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    print(json.dumps(review(args.root.resolve(),args.output.resolve()),indent=2))
