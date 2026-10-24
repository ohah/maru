#!/usr/bin/env python3
"""실제 선행 제품과 공유 파싱 재사용을 동일 입력으로 교차 실행한다."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('frame_summary', ROOT / 'tools/editor-frame-measure/summarize.py')
frame = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frame)
# 숨은 줄 경로도 포함하도록 기존 호스트의 접힌 상태·명시 접기 명령을 추가한다.
frame.storage.COUNTS = dict(frame.storage.COUNTS, folded=20, command=20)


def check_source(root):
    info = json.loads((root / 'setup-1.json').read_text())
    if 'src/session/editor/fold.zig' not in info['instrumented_sha256']:
        raise ValueError('Missing fold source hash')
    for name, digest in info['instrumented_sha256'].items():
        if hashlib.sha256((root / 'source-1' / name).read_bytes()).hexdigest() != digest:
            raise ValueError('Instrumented source changed: ' + name)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('output', type=Path)
    p.add_argument('--repetitions', type=int, default=3)
    p.add_argument('--verify-each-edit', type=int, choices=(0, 1), default=0)
    p.add_argument('--prefix', choices=('run', 'verify', 'followup'), default='run')
    p.add_argument('--files', help='Comma-separated pinned fixture names')
    p.add_argument('--workloads', help='Comma-separated existing workload names')
    args = p.parse_args()
    if (args.prefix == 'verify') != bool(args.verify_each_edit):
        p.error('Use run without per-key oracle, or verify with --verify-each-edit 1')
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents or args.repetitions < 1:
        p.error('Use an external prepared output and positive repetitions')
    roots = {name: output / name for name in ('baseline', 'cursor')}
    locks = []
    inputs = None
    binaries = {}
    comparison_target = None
    for name, root in roots.items():
        lock = (root / '.lock').open('w')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        locks.append(lock)
        current = json.loads((root / 'inputs.json').read_text())
        if inputs is not None and current != inputs:
            raise ValueError('Variants use different fixtures')
        inputs = current
        check_source(root)
        info = json.loads((root / 'setup-1.json').read_text())
        if info.get('shared_parse_variant') != ('predecessor' if name == 'baseline' else 'revision-snapshots'):
            raise ValueError('Wrong product variant')
        target = 'shared-parse'
        if comparison_target is not None and target != comparison_target:
            raise ValueError('Variants target different operations')
        comparison_target = target
        binaries[name] = json.loads((root / 'binaries.json').read_text())['1']
    order = []
    files = args.files.split(',') if args.files else sorted(inputs)
    workloads = args.workloads.split(',') if args.workloads else list(frame.storage.COUNTS)
    if not files or len(set(files)) != len(files) or any(name not in inputs for name in files):
        p.error('Select distinct pinned fixtures')
    if not workloads or len(set(workloads)) != len(workloads) or any(work not in frame.storage.COUNTS for work in workloads):
        p.error('Select distinct existing workloads')
    for rep in range(args.repetitions):
        for file_index, file in enumerate(files):
            info = inputs[file]
            for work_index, work in enumerate(workloads):
                names = list(roots)
                if (rep + file_index + work_index) % 2:
                    names.reverse()
                for name in names:
                    root = roots[name]
                    binary = binaries[name]
                    before = hashlib.sha256(Path(binary['binary']).read_bytes()).hexdigest()
                    if before != binary['sha256']:
                        raise ValueError('Measurement binary changed')
                    data = (root / 'fixtures' / file).read_bytes()
                    if hashlib.sha256(data).hexdigest() != info['sha256']:
                        raise ValueError('Fixture changed')
                    env = {k: v for k, v in os.environ.items() if not k.startswith('MARU_')}
                    env.update(MARU_EW2_FILE=str(root / 'fixtures' / file), MARU_EW2_WORKLOAD=work, MARU_EW2_VERIFY_EACH_EDIT=str(args.verify_each_edit))
                    log = root / f'{args.prefix}-{rep}-1-{file}-{work}.log'
                    if log.exists():
                        raise ValueError('Refusing to overwrite measurement: ' + str(log))
                    with log.open('w') as stream:
                        result = subprocess.run([binary['binary'], '--maru-expect-tests=5', '--maru-expect-passed=5'], cwd=binary['cwd'], env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=180)
                    text = log.read_text()
                    if result.returncode or f'verified_each_edit={args.verify_each_edit} ' not in text:
                        raise ValueError('Product run failed: ' + str(log))
                    frame.validate(text, work, info['bytes'], data.count(b'\n') + 1)
                    if hashlib.sha256(Path(binary['binary']).read_bytes()).hexdigest() != before or (root / 'fixtures' / file).read_bytes() != data:
                        raise ValueError('Binary or fixture changed during run')
                    order.append(dict(repetition=rep, file=file, workload=work, variant=name, verify_each_edit=args.verify_each_edit, log=str(log), load_average=os.getloadavg()))
                    print(rep, file, work, name, 'valid', flush=True)
    for root in roots.values():
        check_source(root)
    (output / (args.prefix + '-order.json')).write_text(json.dumps(order, indent=2) + '\n')


if __name__ == '__main__':
    main()
