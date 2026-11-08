"""재읽기와 재시도 두 축을 동일 실행 파일의 원시 기록에서 재계산한다."""
import argparse,json
from pathlib import Path
import parse_stage_report
import verify

POSTS=('repeated_posts','cached_posts')
RETRY=('without_retry','with_retry')
MODES=tuple(p+'-'+r for p in POSTS for r in RETRY)


def order_for(flow,rep):
    posts=POSTS if (rep+int(flow=='shared'))%2==0 else POSTS[::-1]
    retry=RETRY if rep%2==0 else RETRY[::-1]
    return [p+'-'+r for r in retry for p in posts]


def read(root):
    root=Path(root).resolve();study=json.loads((root/'study.json').read_text())
    verify.require(study.get('kind')=='observer-posts-comparison' and study.get('complete') is True,'incomplete observer posts comparison')
    verify.require(all(study['source'].get(n) is True for n in ('observer_posts_control','deferred_retry_control','target_frame_control','observer_cpu')),'observer posts source capabilities')
    reports={};populations=[]
    for mode in MODES:
        manifest=json.loads((root/mode/'study.json').read_text())
        verify.require(manifest['source']==study['source'],'observer posts source differs')
        report=parse_stage_report.read(root/mode)
        posts,retry=mode.split('-')
        verify.require(all(r['observer_posts']['mode']==posts and r['deferred_retry']['mode']==retry and r['frame_wake']['mode']=='immediate' for r in report['runs']),'observer posts cohort label')
        reports[mode]=report;populations.append({r['path'] for r in report['runs']})
    verify.require(all(p==populations[0] for p in populations),'observer posts pairing differs')
    pairs=study['pairs'];verify.require(len(pairs)==len(populations[0]) and {p['path'] for p in pairs}==populations[0],'observer posts comparison population')
    for pair in pairs:
        flow,rep=pair['path'].split('-')
        verify.require(pair['order']==order_for(flow,int(rep)),'observer posts comparison order')
    here=Path(__file__).resolve().parent
    readers=('observer_work_control.py','observer_posts_report.py','observer_posts_control.py','observer_posts.swift.inc','parse_stage_report.py','verify.py','protocol.py','summary_control.py','fold_control.py','bracket_control.py','fold_reuse_control.py','frame_wake_control.py','target_frame_control.py','target_frame_budget.c.inc','observer_cpu.py','deferred_retry_control.py','display_stages.py')
    return dict(kind='observer-posts-comparison',variant='target-coalesced',reader_dependencies={n:verify.sha(here/n) for n in readers},**reports)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    with a.output.open('x') as f:f.write(json.dumps(read(a.root),indent=2)+'\n')
