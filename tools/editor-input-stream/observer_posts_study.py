"""같은 바이너리의 재읽기/재사용과 재시도 없음/연결 네 조건을 교대로 수집한다."""
import argparse,json,shutil
from pathlib import Path
import parse_stage_study as base
import parse_stage_report
import observer_posts_report as report
import run,verify


def main():
    p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    build=a.build.resolve();out=a.output.resolve()
    verify.require(not out.exists() and out!=base.ROOT and base.ROOT not in out.parents,'new external output required')
    source=json.loads((build/'source.json').read_text())
    verify.require(all(source.get(n) is True for n in ('observer_posts_control','deferred_retry_control','target_frame_control','observer_cpu','frame_wake_control','display_stages','parse_stages','fold_reuse_control')),'observer posts build required')
    out.mkdir(mode=0o700)
    tools=list(base.HERE.glob('*.py'))+[base.HERE/'target_frame_budget.c.inc',base.HERE/'observer_posts.swift.inc',base.HERE.parent/'editor-input-attribution/observer.py']
    hashes={str(p.relative_to(base.ROOT)):verify.sha(p) for p in tools};manifests={}
    for mode in report.MODES:
        folder=out/mode;folder.mkdir(mode=0o700)
        for path in tools:
            target=folder/'tools'/path.relative_to(base.ROOT);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,target)
        manifests[mode]=dict(kind='parse-stage-diagnostic',complete=False,build=str(build),source=source,repetitions=3,tools=hashes,runs=[])
        base.write(folder/'study.json',manifests[mode])
    study=dict(kind='observer-posts-comparison',complete=False,source=source,pairs=[]);base.write(out/'study.json',study)
    for rep in range(3):
        for flow in ('typing','shared'):
            name=f'{flow}-{rep}';order=report.order_for(flow,rep)
            for mode in order:
                print(mode,name,flush=True);posts,retry=mode.split('-');target=out/mode/name
                meta=run.trial(build,target,50000,'async',flow,50,30,'normal',rep,observer=base.Marker(),fixture_kind='multiline',fold_reuse_control='prepared',frame_wake_control='immediate',deferred_retry_control=retry,observer_posts_control=posts)
                manifests[mode]['runs'].append(dict(path=name,record_sha256=verify.sha(target/'record.json')));base.write(out/mode/'study.json',manifests[mode])
                verify.require(meta['error'] is None,'invalid observer posts run: '+str(meta['error']))
                base.write(target/'stages.json',parse_stage_report.analyze(json.loads((target/'app.json').read_text()),json.loads((target/'posts.json').read_text()),meta))
            study['pairs'].append(dict(path=name,order=order));base.write(out/'study.json',study)
    verify.require(all(verify.sha(base.ROOT/n)==h for n,h in hashes.items()),'observer posts tools changed')
    for mode in report.MODES:
        manifests[mode]['complete']=True;base.write(out/mode/'study.json',manifests[mode]);base.write(out/mode/'report.json',parse_stage_report.read(out/mode))
    study['complete']=True;base.write(out/'study.json',study);base.write(out/'comparison.json',report.read(out));print(out,flush=True)


if __name__=='__main__':main()
