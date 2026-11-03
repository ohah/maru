#!/usr/bin/env python3
"""외부 사본의 같은 실행 파일에서 전체/증분 괄호 준비를 비교한다. GUI 측정이 아니다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/editor-input-stream'))
from protocol import fixture

PATTERN = re.compile(r'PARSE_MEASURE index=(\d+) mode=(incremental) accuracy=([01]) submit_ns=(\d+) complete_ns=(\d+) nodes=(\d+) bracket_rebuilds=(\d+) bracket_partials=(\d+) bracket_leaves=(\d+)')
WORKER = 'src/platform/macos/app_session/editor/parse/worker.zig'
ANCHOR = '            if (base.bracket_source) |source| {'
CONTROL = '            if (if (std.c.getenv("MARU_PARSE_FULL_BRACKETS") == null) base.bracket_source else null) |source| {'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def read_rows(text, accuracy, full):
    names = ('index', 'mode', 'accuracy', 'submit_ns', 'complete_ns', 'nodes', 'rebuilds', 'partials', 'leaves')
    rows = [dict(zip(names, [int(v) if i != 1 else v for i, v in enumerate(match)])) for match in PATTERN.findall(text)]
    if 'All 1 tests passed.' not in text or [r['index'] for r in rows] != list(range(20)):
        raise ValueError('missing successful measurement population')
    for row in rows:
        if row['accuracy'] != accuracy or row['submit_ns'] > row['complete_ns'] or row['leaves'] == 0:
            raise ValueError('invalid measurement row')
        if (row['rebuilds'], row['partials']) != ((1, 0) if full else (0, 1)):
            raise ValueError('wrong bracket preparation branch')
        if accuracy and row['nodes'] == 0:
            raise ValueError('missing independent tree comparison')
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--deps', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    deps = args.deps.resolve()
    if out.exists() or out == ROOT or ROOT in out.parents or not deps.is_dir():
        parser.error('new external output and existing dependencies required')
    out.mkdir(parents=True)
    source = out / 'source'
    source.mkdir()
    files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    inventory = {}
    for extra in ('tools/editor-parse-incremental/brackets.py', 'tools/editor-parse-incremental/test_brackets.py'):
        if extra not in files and (ROOT / extra).is_file():
            files.append(extra)
    for name in files:
        if not name or not (ROOT / name).is_file():
            continue
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
        inventory[name] = sha(target)
    (source / 'zig-pkg').symlink_to(deps, target_is_directory=True)
    worker = source / WORKER
    text = worker.read_text()
    if text.count(ANCHOR) != 1:
        raise ValueError('private control anchor changed')
    worker.write_text(text.replace(ANCHOR, CONTROL))
    env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', 'SDKROOT') if key in os.environ}
    zig = subprocess.check_output(['mise', 'which', 'zig'], cwd=ROOT, env=env, text=True).strip()
    inputs = {}
    for kind in ('flat', 'multiline'):
        for size in (3000, 50000):
            name = f'{kind}-{size}.zig'
            (out / name).write_bytes(fixture(size, kind))
            inputs[name] = dict(sha256=sha(out / name), bytes=(out / name).stat().st_size)
    env.update(ZIG_LOCAL_PKG_DIR=str(deps), MARU_PARSE_FILE=str(out / 'flat-3000.zig'), MARU_PARSE_MODE='incremental', MARU_PARSE_ACCURACY='1')
    command = [zig, 'build', 'measure-editor-parse-incremental', '-Doptimize=ReleaseFast', '--cache-dir', str(args.cache.resolve()), '-j2', '--verbose']
    write(out / 'source.json', dict(head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), original=inventory, private_worker_sha256=sha(worker), command=command, host=platform.platform(), inputs=inputs))
    with (out / 'build.log').open('xb') as log:
        subprocess.run(command, cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    build_text = (out / 'build.log').read_text()
    found = re.findall(r'info\(verbose\): (\S+/test) --maru-expect-tests=1\b', build_text)
    if not found:
        raise ValueError('missing compiled measurement')
    read_rows(build_text, 1, False)
    binary = out / 'measure-test'
    shutil.copy2(found[-1], binary)
    digest = sha(binary)
    runs = []
    for accuracy, repetitions in ((0, 3), (1, 1)):
        for name in inputs:
            for rep in range(repetitions):
                for full in ((True, False) if rep % 2 == 0 else (False, True)):
                    mode = 'full' if full else 'incremental'
                    print(name, mode, accuracy, rep, flush=True)
                    run_env = dict(env, MARU_PARSE_FILE=str(out / name), MARU_PARSE_ACCURACY=str(accuracy))
                    if full:
                        run_env['MARU_PARSE_FULL_BRACKETS'] = '1'
                    log = out / f'{name}-{mode}-{accuracy}-{rep}.log'
                    load_before = os.getloadavg()
                    with log.open('xb') as stream:
                        subprocess.run([str(binary), '--maru-expect-tests=1'], cwd=source, env=run_env, stdout=stream, stderr=subprocess.STDOUT, check=True)
                    rows = read_rows(log.read_text(), accuracy, full)
                    runs.append(dict(fixture=name, mode=mode, accuracy=accuracy, rep=rep, load_before=load_before, load_after=os.getloadavg(), log=log.name, log_sha256=sha(log), rows=rows))
                    write(out / 'runs.json', runs)
    if sha(binary) != digest or any(sha(ROOT / name) != value for name, value in inventory.items()):
        raise ValueError('source or executable drift')
    summary = {}
    for name in inputs:
        summary[name] = {}
        for mode in ('full', 'incremental'):
            rows = [row for run in runs if run['fixture'] == name and run['mode'] == mode and run['accuracy'] == 0 for row in run['rows']]
            summary[name][mode] = {key: dict(p50_ms=statistics.median(row[key] for row in rows) / 1e6, max_ms=max(row[key] for row in rows) / 1e6) for key in ('submit_ns', 'complete_ns')}
    write(out / 'result.json', dict(complete=True, binary_sha256=digest, processes=len(runs), edits=sum(len(run['rows']) for run in runs), summary=summary))
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
