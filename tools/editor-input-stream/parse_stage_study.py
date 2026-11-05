"""계측 부하가 있는 진단 모집단만 수집한다. 일반 성능 집계로 넘기지 않는다."""
import argparse
import json
from pathlib import Path
import shutil
import sys
import run
import verify
import parse_stage_report

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE.parent/'editor-input-attribution'))
from observer import diagnostic_environment


class Marker:
    environment = staticmethod(diagnostic_environment)

    def start(self, pid, target):
        return {'kind': 'parse-stage-diagnostic', 'pid': pid}

    def stop(self):
        return {'kind': 'parse-stage-diagnostic'}


def write(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    output = args.output.resolve()
    build = args.build.resolve()
    if output.exists() or output == ROOT or ROOT in output.parents or not 1 <= args.repetitions <= 3:
        parser.error('new external output and 1..3 repetitions required')
    source = json.loads((build/'source.json').read_text())
    verify.require(source.get('parse_stages') is True and source.get('fold_reuse_control') is True, 'stage build required')
    verify.require(source.get('frame_wake_control',False) is False, 'use frame wake study for controlled builds')
    output.mkdir(mode=0o700)
    tools = list(HERE.glob('*.py')) + [HERE.parent/'editor-input-attribution/observer.py']
    hashes = {str(p.relative_to(ROOT)): verify.sha(p) for p in tools}
    for path in tools:
        target = output/'tools'/path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    manifest = dict(kind='parse-stage-diagnostic', complete=False, build=str(build), source=source, repetitions=args.repetitions, tools=hashes, runs=[])
    write(output/'study.json', manifest)
    for rep in range(args.repetitions):
        for flow in ('typing', 'shared'):
            name = f'{flow}-{rep}'
            print(name, flush=True)
            target = output/name
            record = run.trial(build, target, 50000, 'async', flow, 50, 30, 'normal', rep,
                               observer=Marker(), fixture_kind='multiline', fold_reuse_control='prepared')
            manifest['runs'].append(dict(path=name, record_sha256=verify.sha(target/'record.json')))
            write(output/'study.json', manifest)
            verify.require(record['error'] is None, 'invalid diagnostic run: '+str(record['error']))
            app = json.loads((target/'app.json').read_text())
            posts = json.loads((target/'posts.json').read_text())
            write(target/'stages.json', parse_stage_report.analyze(app, posts, record))
    verify.require(all(verify.sha(ROOT/name) == digest for name, digest in hashes.items()), 'diagnostic tools changed')
    manifest['complete'] = True
    write(output/'study.json', manifest)
    write(output/'report.json', parse_stage_report.read(output))
    print(output, flush=True)


if __name__ == '__main__':
    main()
