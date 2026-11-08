#!/usr/bin/env python3
"""동일 하네스의 이전/메인 앱을 교대로 실행한다. 실패 실행도 원본 그대로 보존한다."""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
STREAM = ROOT / 'tools/editor-input-stream'
sys.path.insert(0, str(STREAM))
import protocol
import run
import review
import summarize
import verify


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    verify.require(not output.exists() and output != ROOT and ROOT not in output.parents, 'new external output required')
    builds = {name: path.resolve() for name, path in [('before', args.before), ('after', args.after)]}
    sources = {name: json.loads((path / 'source.json').read_text()) for name, path in builds.items()}
    for name, source in sources.items():
        verify.require(source.get('harness') == protocol.NAME, 'independent stream harness required')
        verify.require(not any(source.get(flag, False) for flag in ('summary_control', 'fold_control', 'bracket_control', 'fold_reuse_control', 'parse_stages', 'display_stages', 'frame_wake_control', 'target_frame_control', 'observer_cpu', 'deferred_retry_control', 'observer_posts_control', 'observer_work_control')), 'uncontrolled matching harness required')
        verify.require(verify.sha(builds[name] / 'producer') == source['producer_sha256'], 'producer drift')
        verify.require(verify.sha(builds[name] / 'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app') == source['app_sha256'], 'app drift')
    verify.require(sources['before']['producer_sha256'] == sources['after']['producer_sha256'], 'identical producer required')
    for build in builds.values():
        subprocess.run([str(build / 'producer'), '--preflight'], check=True)
    output.mkdir(mode=0o700)
    tools = [Path(__file__).resolve()] + list(STREAM.glob('*.py'))
    hashes = {str(path.relative_to(ROOT)): verify.sha(path) for path in tools}
    study = dict(schema=1, complete=False, tools=hashes, pairs=[])
    manifests = {}
    for name, build in builds.items():
        folder = output / name
        folder.mkdir(mode=0o700)
        manifests[name] = dict(schema=1, protocol=protocol.NAME, build=str(build), source=sources[name], runner_sha256=verify.sha(STREAM / 'run.py'), verifier_sha256=verify.sha(STREAM / 'verify.py'), sizes=[50000], periods=[100, 50], flows=['typing', 'shared'], modes=['async'], repetitions=3, count=30, kind='normal', runs=[], host=dict(macos=platform.mac_ver()[0], logical_cpus=os.cpu_count(), architecture=platform.machine()))
        write(folder / 'manifest.json', manifests[name])
    write(output / 'study.json', study)
    for repetition in range(3):
        for period in (100, 50):
            for flow in ('typing', 'shared'):
                order = ['before', 'after'] if repetition % 2 == 0 else ['after', 'before']
                trial_name = f'50000-{period}-{flow}-{repetition}-async'
                for name in order:
                    print(name, trial_name, flush=True)
                    folder = output / name
                    target = folder / trial_name
                    result = run.trial(builds[name], target, 50000, 'async', flow, period, 30, 'normal', repetition)
                    manifests[name]['runs'].append(dict(path=trial_name, record_sha256=verify.sha(target / 'record.json')))
                    write(folder / 'manifest.json', manifests[name])
                    verify.require(result['error'] is None, name + ': ' + str(result['error']))
                study['pairs'].append(dict(path=trial_name, order=order))
                write(output / 'study.json', study)
    verify.require(all(verify.sha(ROOT / name) == digest for name, digest in hashes.items()), 'study tool drift')
    for name in builds:
        folder = output / name
        write(folder / 'verified.json', verify.read(folder))
        write(folder / 'summary.json', summarize.summarize(folder))
        review.review(folder, output / (name + '-review'))
    study['complete'] = True
    write(output / 'study.json', study)
    print(output, flush=True)


if __name__ == '__main__':
    main()
