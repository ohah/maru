"""실제 작업별 계측 자료를 손상해 누락·중첩·CPU 과대 귀속을 거절한다."""
import argparse,copy,json
from pathlib import Path
import observer_work_report as report
import parse_stage_report
import verify


def review(root,output):
    repo=Path(__file__).resolve().parents[2]
    verify.require(not output.exists() and output!=repo and repo not in output.parents,'new external output required')
    proof=report.read(root);folder=root/'timed/typing-0'
    original=[json.loads((folder/n).read_text()) for n in ('app.json','posts.json','record.json')]
    normal=parse_stage_report.analyze(*copy.deepcopy(original))
    def at(name,i,value):return lambda a,p,m:a[name].__setitem__(i,value)
    def event(i,value):return lambda a,p,m:a['work_events'][0].__setitem__(i,value)
    faults=[
        ('metadata-mode',lambda a,p,m:m.update(observer_work_control='untimed')),
        ('actual-mode',lambda a,p,m:a.update(observer_work_mode='untimed')),
        ('fixed-posts-mode',lambda a,p,m:m.update(observer_posts_control='repeated_posts')),
        ('fixed-retry-mode',lambda a,p,m:m.update(deferred_retry_control='without_retry')),
        ('missing-start',lambda a,p,m:a.update(work_input_start=[])),
        ('boolean-time',at('work_input_start',0,True)),('zero-time',at('work_input_start',0,0)),
        ('backwards-time',at('work_idle_start',0,original[0]['work_input_start'][0])),
        ('snapshot-error',at('work_idle_end',1,1)),('final-error',lambda a,p,m:a.update(work_errors=1)),
        ('boolean-final-error',lambda a,p,m:a.update(work_errors=True)),
        ('event-width',lambda a,p,m:a['work_events'][0].pop()),('unknown-part',event(0,6)),
        ('boolean-part',event(0,True)),('zero-begin',event(1,0)),
        ('reversed-event',event(2,original[0]['work_events'][0][1])),
        ('cpu-exceeds-wall',event(3,original[0]['work_events'][0][2]-original[0]['work_events'][0][1]+1)),
        ('zero-ordinal',event(4,0)),('skipped-ordinal',event(4,2)),
        ('overlapping-events',lambda a,p,m:a['work_events'][1].__setitem__(1,a['work_events'][0][2]-1)),
        ('cpu-sum-differs',event(3,original[0]['work_events'][0][3]+1)),
        ('lost-coverage',at('work_idle_end',3,original[0]['work_idle_end'][3]-1)),
        ('wrong-event-count',at('work_idle_end',2,original[0]['work_idle_end'][2]-1)),
        ('cpu-overflow',at('work_idle_end',4,2**64)),('negative-cpu',at('work_idle_end',4,-1)),
        ('fractional-cpu',at('work_idle_end',4,.5)),
    ]
    output.mkdir(mode=0o700);rejected=[]
    for name,mutate in faults:
        values=copy.deepcopy(original);mutate(*values)
        try:parse_stage_report.analyze(*values)
        except ValueError as error:reason=str(error)
        else:raise ValueError('mutation survived: '+name)
        verify.require(parse_stage_report.analyze(*copy.deepcopy(original))==normal,'normal control changed')
        (output/(name+'.json')).write_text(json.dumps(dict(app=values[0],posts=values[1],record=values[2]),indent=2)+'\n')
        rejected.append(dict(name=name,expected='rejected',actual='rejected',reason=reason))
    verify.require(report.read(root)==proof,'original study changed')
    result=dict(rejected=rejected,normal_controls=len(faults)+1,source_hashes={n:verify.sha(folder/n) for n in ('app.json','posts.json','record.json')})
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n');return result


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    print(json.dumps(review(a.root.resolve(),a.output.resolve()),indent=2))
