#!/usr/bin/env python3
"""예산 0/4ms를 독립 프로세스로 비교한다. 제품과 GUI의 정책은 바꾸지 않는다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

import prepare

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ('flat-3000.zig', 'flat-15000.zig', 'flat-50000.zig', 'real-build.zig', 'real-host.swift')
FOLDERS = ('editor-parse-budget', 'editor-provider-measure', 'editor-frame-measure',
           'editor-storage-measure', 'editor-fold-product', 'editor-fold-points')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root):
    return {str(p.relative_to(root)): sha(p) for p in (root / 'src').rglob('*') if p.is_file()} | {
        name: sha(root / name) for name in ('build.zig', 'build.zig.zon')}


def tools():
    return {str(p.relative_to(ROOT)): sha(p) for folder in FOLDERS for p in (ROOT / 'tools' / folder).rglob('*')
            if p.is_file() and p.suffix in ('.py', '.inc')}


def write(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--deps', required=True, type=Path)
    parser.add_argument('--fixtures', required=True, type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    deps = args.deps.resolve()
    if out.exists() or out == ROOT or ROOT in out.parents or not deps.is_dir():
        parser.error('Use a new external output and existing dependency directory')
    if subprocess.check_output(['git', 'status', '--porcelain', '--', 'src', 'build.zig', 'build.zig.zon'], cwd=ROOT, text=True).strip():
        parser.error('Product source must match the recorded commit')
    original, producer = inventory(ROOT), tools()
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    out.mkdir(parents=True)
    for name in producer:
        target = out / 'tool-snapshot' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
    (out / 'fixtures').mkdir()
    inputs = {}
    for name in FIXTURES:
        target = out / 'fixtures' / name
        shutil.copy2(args.fixtures / name, target)
        inputs[name] = dict(sha256=sha(target), bytes=target.stat().st_size)
    write(out / 'producer.json', dict(head=head, tools_sha256=producer, inputs=inputs))
    source = prepare.setup(out, deps)
    instrumented = inventory(source)
    write(out / 'source.json', dict(head=head, original=original, instrumented=instrumented))
    cache = source / '.zig-cache'
    cache.mkdir(exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('MARU_')}
    env.update(MARU_BUDGET_FILE=str(out / 'fixtures' / FIXTURES[0]), MARU_BUDGET_NS='0', MARU_BUDGET_ACCURACY='1')
    commands = {}
    with (cache / 'measurement-active.lock').open('ab'):
        binaries = {}
        for kind, target, count in [('measure', 'test-native-budget-measure', 4), ('state', 'test-native-budget-state', 2)]:
            log = out / f'build-{kind}.log'
            command = ['mise', 'exec', '--', 'zig', 'build', target, '-Doptimize=ReleaseFast', '-j2', '--verbose']
            with log.open('xb') as stream:
                done = subprocess.run(command, cwd=source, env=env, stdout=stream, stderr=subprocess.STDOUT)
            if done.returncode:
                raise RuntimeError('Build/control failed; preserved log: ' + str(log))
            text = log.read_text()
            if f'All {count} tests passed.' not in text:
                raise ValueError('Missing actual build control result')
            found = re.findall(r'(\./\.zig-cache/o/[0-9a-f]+/test) --maru-expect-tests=' + str(count), text)
            if not found:
                raise ValueError('Missing executed binary')
            binary = out / ('archived-' + kind)
            shutil.copy2(source / found[-1], binary)
            binaries[kind] = dict(sha256=sha(binary), tests=count)
            commands[kind] = command
        runs = {}
        for accuracy, reps in [(0, 3), (1, 1)]:
            for rep in range(reps):
                for name in FIXTURES:
                    for budget in (0, 4000000):
                        key = f'run-{accuracy}-{rep}-{name}-{budget}'
                        environment = dict(env, MARU_BUDGET_FILE=str(out / 'fixtures' / name),
                                           MARU_BUDGET_NS=str(budget), MARU_BUDGET_ACCURACY=str(accuracy))
                        command = [str(out / 'archived-measure'), '--maru-expect-tests=4', '--maru-expect-passed=4']
                        log = out / (key + '.log')
                        with log.open('xb') as stream:
                            done = subprocess.run(command, cwd=source, env=environment, stdout=stream, stderr=subprocess.STDOUT)
                        if done.returncode:
                            raise RuntimeError('Actual diagnostic failed; preserved log: ' + str(log))
                        runs[key] = dict(fixture=name, budget_ns=budget, accuracy=accuracy, repetition=rep,
                                         command=command, exit=done.returncode, log_sha256=sha(log),
                                         environment={k: environment[k] for k in ('MARU_BUDGET_FILE','MARU_BUDGET_NS','MARU_BUDGET_ACCURACY')})
                        print('BUDGET_RUN_PASS', key, flush=True)
        assert inventory(ROOT) == original and inventory(source) == instrumented and tools() == producer
        write(out / 'result.json', dict(schema=1, kind='native-edit-budget', complete=True, head=head,
              processes=40, performance_inputs=600, accuracy_inputs=200, runs=runs, binaries=binaries,
              build_commands=commands, build_logs_sha256={k:sha(out / f'build-{k}.log') for k in binaries},
              producer_sha256=sha(out / 'producer.json'), source_sha256=sha(out / 'source.json'),
              scope='Isolated Provider comparison and existing syntax-state guards; no product budget policy, AppSession GUI or HID result'))
        print('BUDGET_COLLECTION_COMPLETE_40_PROCESSES', flush=True)


if __name__ == '__main__':
    main()
