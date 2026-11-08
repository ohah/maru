"""실제 캐시 자료의 작업 수·재사용 신원·CPU 귀속 손상을 정상 대조와 검증한다."""
import argparse,base64,copy,json
from pathlib import Path
import observer_posts_report as report
import parse_stage_report
import verify


def review(root,output):
    repo=Path(__file__).resolve().parents[2]
    verify.require(not output.exists() and output!=repo and repo not in output.parents,'new external output required')
    proof=report.read(root);folder=root/'cached_posts-with_retry/typing-0'
    original=[json.loads((folder/n).read_text()) for n in ('app.json','posts.json','record.json')]
    normal=parse_stage_report.analyze(*copy.deepcopy(original))
    def at(name,i,value):return lambda a,p,m:a[name].__setitem__(i,value)
    def idle_reload(a,p,m):
        for i in (2,3,4):a['posts_idle_end'][i]+=1
        a['posts_idle_end'][5]-=1
    faults=[
        ('mode-metadata',lambda a,p,m:m.update(observer_posts_control='repeated_posts')),
        ('mode-runtime',lambda a,p,m:a.update(observer_posts_mode='repeated_posts')),
        ('missing-snapshot',lambda a,p,m:a.update(posts_input_start=[])),
        ('boolean-clock',at('posts_input_start',0,True)),('zero-clock',at('posts_input_start',0,0)),
        ('backwards-clock',at('posts_idle_start',0,original[0]['posts_input_start'][0])),
        ('backwards-checks',at('posts_idle_end',1,0)),('snapshot-error',at('posts_idle_end',7,1)),
        ('final-source-replaced',lambda a,p,m:a.update(posts_errors=1)),
        ('boolean-final-error',lambda a,p,m:a.update(posts_errors=True)),
        ('bytes-not-text',lambda a,p,m:a.update(posts_accepted_base64=[])),
        ('invalid-base64',lambda a,p,m:a.update(posts_accepted_base64='!')),
        ('missing-accepted-bytes',lambda a,p,m:a.update(posts_accepted_base64='')),
        ('other-producer-bytes',lambda a,p,m:a.update(posts_accepted_base64=base64.b64encode(b'{"error":null}').decode())),
        ('invented-check',at('posts_idle_end',1,original[0]['posts_idle_end'][1]+1)),
        ('unaccounted-attempt',at('posts_idle_end',2,original[0]['posts_idle_end'][2]+1)),
        ('reads-exceed-attempts',at('posts_idle_end',3,2**63)),
        ('parses-exceed-reads',at('posts_idle_end',4,2**63)),
        ('lost-cache-hit',at('posts_idle_end',5,original[0]['posts_idle_end'][5]-1)),
        ('silent-idle-reload',idle_reload),
        ('cpu-overflow',at('posts_idle_end',6,2**64)),
        ('negative-cpu',at('posts_idle_end',6,-1)),('fractional-cpu',at('posts_idle_end',6,.5)),
        ('subcpu-exceeds-driver',at('posts_idle_end',6,10**15)),
        ('extra-handler-call',lambda a,p,m:a['observer_idle_end'].__setitem__(2,a['observer_idle_end'][2]+1)),
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
