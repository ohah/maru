"""계측 켬/끔을 대조하고 첫 입력 구간에 실제 작업의 wall과 CPU를 연결한다."""
import argparse,json
from pathlib import Path
import frame_tail_report
import observer_work_control as control
import parse_stage_report
import verify


def read(root):
    root=Path(root).resolve();study=json.loads((root/'study.json').read_text())
    verify.require(study.get('kind')=='observer-work-comparison' and study.get('complete') is True,'incomplete observer work comparison')
    verify.require(study['source'].get('observer_work_control') is True,'observer work build capability')
    reports={};populations=[]
    for mode in control.MODES:
        manifest=json.loads((root/mode/'study.json').read_text())
        verify.require(manifest['source']==study['source'],'observer work source differs')
        report=parse_stage_report.read(root/mode)
        verify.require(all(r['observer_work']['mode']==mode for r in report['runs']),'observer work cohort label')
        for row in report['runs']:
            folder=root/mode/row['path'];app=json.loads((folder/'app.json').read_text());posts=json.loads((folder/'posts.json').read_text())
            row['all_keys']=[frame_tail_report.key_trace(app,event,key,verify.require) for event,key in zip(posts['events'],app['keys'])]
            if mode=='timed':
                event,key=posts['events'][0],app['keys'][0]
                frames=[r for r in app['display_frames'] if r[0]==key[7]];verify.require(len(frames)==1,'observer first frame')
                windows={'post_to_native':(event['post_ns'],key[3]),'native_to_tick':(key[3],max(key[3],frames[0][5]))}
                row['first_input_work']={name:dict(total=control.overlap(app['work_events'],*bounds),parts={label:control.overlap([r for r in app['work_events'] if r[0]==part],*bounds) for part,label in enumerate(control.PARTS)}) for name,bounds in windows.items()}
        reports[mode]=report;populations.append({r['path'] for r in report['runs']})
    verify.require(populations[0]==populations[1],'observer work pairing differs')
    pairs=study['pairs'];verify.require(len(pairs)==len(populations[0]) and {p['path'] for p in pairs}==populations[0],'observer work comparison population')
    for pair in pairs:
        rep=int(pair['path'].rsplit('-',1)[1]);expected=list(control.MODES if rep%2==0 else control.MODES[::-1])
        verify.require(pair['order']==expected,'observer work comparison order')
    here=Path(__file__).resolve().parent
    readers=('observer_work_report.py','observer_work_control.py','observer_work.swift.inc','frame_tail_report.py','frame_wake_report.py','deferred_retry_report.py','observer_posts_report.py','parse_stage_report.py','verify.py','protocol.py','summary_control.py','fold_control.py','bracket_control.py','fold_reuse_control.py','frame_wake_control.py','target_frame_control.py','target_frame_budget.c.inc','observer_cpu.py','observer_posts_control.py','deferred_retry_control.py','display_stages.py')
    return dict(kind='observer-work-comparison',reader_dependencies={n:verify.sha(here/n) for n in readers},**reports)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    with a.output.open('x') as f:f.write(json.dumps(read(a.root),indent=2)+'\n')
