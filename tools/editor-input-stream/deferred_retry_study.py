"""같은 대상 예산 후보에서 거절 후 재시도 연결 여부만 교대한다."""
import argparse
import json
from pathlib import Path
import shutil
import parse_stage_study as base
import parse_stage_report
import run
import verify
import deferred_retry_report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--repetitions',type=int,default=3)
    args = parser.parse_args()
    output = args.output.resolve()
    build = args.build.resolve()
    if output.exists() or output == base.ROOT or base.ROOT in output.parents or not 1 <= args.repetitions <= 3:
        parser.error('new external output and 1..3 repetitions required')
    source = json.loads((build/'source.json').read_text())
    verify.require(all(source.get(name) is True for name in ('deferred_retry_control','observer_cpu','target_frame_control','frame_wake_control','display_stages','parse_stages','fold_reuse_control')), 'frame wake controlled build required')
    output.mkdir(mode=0o700)
    tools = list(base.HERE.glob('*.py'))+[base.HERE.parent/'editor-input-attribution/observer.py']
    if source.get('target_frame_control'):tools.append(base.HERE/'target_frame_budget.c.inc')
    hashes = {str(p.relative_to(base.ROOT)):verify.sha(p) for p in tools}
    manifests = {}
    for mode in ('without_retry','with_retry'):
        folder = output/mode
        folder.mkdir(mode=0o700)
        for path in tools:
            target = folder/'tools'/path.relative_to(base.ROOT)
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(path,target)
        manifests[mode] = dict(kind='parse-stage-diagnostic',complete=False,build=str(build),source=source,repetitions=args.repetitions,tools=hashes,runs=[])
        base.write(folder/'study.json',manifests[mode])
    study = dict(kind='deferred-frame-comparison',complete=False,source=source,pairs=[])
    base.write(output/'study.json',study)
    for rep in range(args.repetitions):
        for flow in ('typing','shared'):
            order = ('without_retry','with_retry') if rep%2 == 0 else ('with_retry','without_retry')
            name = f'{flow}-{rep}'
            for mode in order:
                print(mode,name,flush=True)
                target = output/mode/name
                meta = run.trial(build,target,50000,'async',flow,50,30,'normal',rep,
                                 observer=base.Marker(),fixture_kind='multiline',fold_reuse_control='prepared',frame_wake_control='immediate',deferred_retry_control=mode)
                manifests[mode]['runs'].append(dict(path=name,record_sha256=verify.sha(target/'record.json')))
                base.write(output/mode/'study.json',manifests[mode])
                verify.require(meta['error'] is None,'invalid frame wake run: '+str(meta['error']))
                app = json.loads((target/'app.json').read_text())
                posts = json.loads((target/'posts.json').read_text())
                base.write(target/'stages.json',parse_stage_report.analyze(app,posts,meta))
            study['pairs'].append(dict(path=name,order=order))
            base.write(output/'study.json',study)
    verify.require(all(verify.sha(base.ROOT/name) == digest for name,digest in hashes.items()),'frame wake tools changed')
    reports = {}
    for mode in ('without_retry','with_retry'):
        manifests[mode]['complete'] = True
        base.write(output/mode/'study.json',manifests[mode])
        reports[mode] = parse_stage_report.read(output/mode)
        base.write(output/mode/'report.json',reports[mode])
    study['complete'] = True
    base.write(output/'study.json',study)
    base.write(output/'comparison.json',deferred_retry_report.read(output))
    print(output,flush=True)


if __name__ == '__main__':
    main()
