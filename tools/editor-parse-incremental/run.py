#!/usr/bin/env python3
"""같은 입력의 cold/명시적 증분을 독립 프로세스로 실측한다."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ('flat-3000.zig', 'flat-15000.zig', 'flat-50000.zig', 'real-build.zig', 'real-host.swift')
PATTERN = re.compile(r'PARSE_MEASURE index=(\d+) mode=(cold|incremental) accuracy=([01]) submit_ns=(\d+) complete_ns=(\d+) nodes=(\d+)')
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--deps', type=Path, required=True)
    p.add_argument('--cache', type=Path, required=True)
    p.add_argument('--fixtures', type=Path, required=True)
    args = p.parse_args()
    out = args.output.resolve()
    if out.exists() or out == ROOT or ROOT in out.parents:
        p.error('new external output required')
    out.mkdir(parents=True)
    inputs = {}
    for name in FIXTURES:
        shutil.copy2(args.fixtures / name, out / name)
        inputs[name] = {'sha256': sha(out / name), 'bytes': (out / name).stat().st_size}
    files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    inventory = {name: sha(ROOT / name) for name in files if name and (ROOT / name).is_file() and (name.startswith('src/') or (name.startswith('tools/editor-parse-incremental/') and name.endswith(('.py', '.zig'))) or name in ('build.zig', 'build.zig.zon'))}
    env = dict(os.environ, ZIG_LOCAL_PKG_DIR=str(args.deps.resolve()), MARU_PARSE_FILE=str(out / FIXTURES[0]), MARU_PARSE_MODE='incremental', MARU_PARSE_ACCURACY='1')
    command = ['mise', 'exec', '--', 'zig', 'build', 'measure-editor-parse-incremental', '-Doptimize=ReleaseFast', '--cache-dir', str(args.cache.resolve()), '-j2', '--verbose']
    with (out / 'build.log').open('xb') as log:
        subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    text = (out / 'build.log').read_text()
    found = re.findall(r'info\(verbose\): (\S+/test) --maru-expect-tests=1\b', text)
    if not found or 'All 1 tests passed.' not in text:
        raise RuntimeError('missing compiled control')
    binary = out / 'measure-test'
    shutil.copy2(found[-1], binary)
    runs = []
    for accuracy, reps in [(0, 3), (1, 1)]:
        for rep in range(reps):
            for name in FIXTURES:
                # 순서에 따른 편향을 줄인다. 서로 다른 모드는 같은 프로세스에 섞지 않는다.
                for mode in (('cold', 'incremental') if rep % 2 == 0 else ('incremental', 'cold')):
                    env.update(MARU_PARSE_FILE=str(out / name), MARU_PARSE_MODE=mode, MARU_PARSE_ACCURACY=str(accuracy))
                    log = out / f'{name}-{mode}-{accuracy}-{rep}.log'
                    load_before = os.getloadavg()
                    with log.open('xb') as stream:
                        subprocess.run([str(binary), '--maru-expect-tests=1'], cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)
                    rows = [dict(index=int(i), mode=m, accuracy=int(a), submit_ns=int(s), complete_ns=int(c), nodes=int(n)) for i,m,a,s,c,n in PATTERN.findall(log.read_text())]
                    if [r['index'] for r in rows] != list(range(20)) or any(r['mode'] != mode or r['accuracy'] != accuracy or r['submit_ns'] > r['complete_ns'] or (accuracy and r['nodes'] == 0) for r in rows):
                        raise RuntimeError('invalid samples: ' + str(log))
                    runs.append(dict(fixture=name, mode=mode, accuracy=accuracy, rep=rep, load_before=load_before, load_after=os.getloadavg(), log=log.name, sha256=sha(log), rows=rows))
    if any(sha(ROOT / name) != digest for name,digest in inventory.items()):
        raise RuntimeError('source changed during measurement')
    result = dict(host=platform.platform(), zig=subprocess.check_output(['mise','exec','--','zig','version'], cwd=ROOT, text=True).strip(), head=subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip(), source_sha256=inventory, binary_sha256=sha(binary), inputs=inputs, command=command, runs=runs)
    (out / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
    summary = {}
    for name in FIXTURES:
        summary[name] = {}
        for mode in ('cold', 'incremental'):
            rows = [row for run in runs if run['fixture']==name and run['mode']==mode and not run['accuracy'] for row in run['rows']]
            summary[name][mode] = {key:dict(p50_ms=statistics.median(r[key] for r in rows)/1e6, max_ms=max(r[key] for r in rows)/1e6) for key in ('submit_ns','complete_ns')}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps(summary, indent=2))
if __name__ == '__main__':
    main()
