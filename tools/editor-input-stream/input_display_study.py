"""제품 프레임 정책에서 관측자 CPU 계측 켬/끔을 교대로 수집한다."""
import argparse
import json
from pathlib import Path
import shutil
import parse_stage_study as base
import parse_stage_report
import input_display_report as report
import run
import verify


class Marker(base.Marker):
    def __init__(self, mode):
        self.mode = mode

    def environment(self, env):
        result = base.diagnostic_environment(env)
        result['MARU_INPUT_DISPLAY_TIMED'] = '1' if self.mode == 'timed' else '0'
        return result

    def start(self, pid, target):
        return dict(kind='input-display-diagnostic', pid=pid, input_display_mode=self.mode)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build, output = args.build.resolve(), args.output.resolve()
    verify.require(not output.exists() and output != base.ROOT and base.ROOT not in output.parents, 'new external output required')
    source = json.loads((build / 'source.json').read_text())
    verify.require(source.get('input_display') is True, 'input display build required')
    verify.require(not any(source.get(key, False) for key in ('frame_wake_control', 'target_frame_control', 'observer_cpu', 'deferred_retry_control', 'observer_posts_control', 'observer_work_control')), 'unchanged product scheduling required')
    output.mkdir(mode=0o700)
    tools = [p for p in base.HERE.iterdir() if p.suffix in ('.py', '.inc')] + [base.HERE.parent / 'editor-input-attribution/observer.py']
    hashes = {str(p.relative_to(base.ROOT)): verify.sha(p) for p in tools}
    manifests = {}
    for mode in report.MODES:
        folder = output / mode
        folder.mkdir(mode=0o700)
        for path in tools:
            target = folder / 'tools' / path.relative_to(base.ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        manifests[mode] = dict(kind='parse-stage-diagnostic', complete=False, build=str(build), source=source, repetitions=3, tools=hashes, runs=[])
        base.write(folder / 'study.json', manifests[mode])
    study = dict(kind='current-input-display', complete=False, source=source, pairs=[])
    base.write(output / 'study.json', study)
    for repetition in range(3):
        for flow in ('typing', 'shared'):
            name = f'{flow}-{repetition}'
            order = list(report.MODES if repetition % 2 == 0 else report.MODES[::-1])
            for mode in order:
                print(mode, name, flush=True)
                target = output / mode / name
                meta = run.trial(build, target, 50000, 'async', flow, 50, 30, 'normal', repetition, observer=Marker(mode), fixture_kind='multiline', fold_reuse_control='prepared')
                manifests[mode]['runs'].append(dict(path=name, record_sha256=verify.sha(target / 'record.json')))
                base.write(output / mode / 'study.json', manifests[mode])
                verify.require(meta['error'] is None, 'invalid input display run: ' + str(meta['error']))
                app = json.loads((target / 'app.json').read_text())
                posts = json.loads((target / 'posts.json').read_text())
                base.write(target / 'stages.json', parse_stage_report.analyze(app, posts, meta))
                base.write(target / 'input-display.json', report.analyze(app, posts, meta, mode))
            study['pairs'].append(dict(path=name, order=order))
            base.write(output / 'study.json', study)
    verify.require(all(verify.sha(base.ROOT / name) == digest for name, digest in hashes.items()), 'input display tools changed')
    for mode in report.MODES:
        manifests[mode]['complete'] = True
        base.write(output / mode / 'study.json', manifests[mode])
    study['complete'] = True
    base.write(output / 'study.json', study)
    base.write(output / 'report.json', report.read(output))
    print(output, flush=True)


if __name__ == '__main__':main()
