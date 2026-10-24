#!/usr/bin/env python3
"""고정 입력과 모든 키 기록을 검증한 뒤 저장소 비용을 집계한다."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics

FIELDS = ('total_ns', 'delta_ns', 'copy_ns', 'index_ns', 'view_lines_ns')
PATTERN = re.compile(r'STORAGE key=(\d+) total_ns=(\d+) delta_ns=(\d+) copy_ns=(\d+) index_ns=(\d+) view_lines_ns=(\d+) bytes=(\d+) lines=(\d+)(?=\r?$)', re.MULTILINE)
COUNTS = {'typing': 20, 'structure': 10, 'paste': 1, 'undo': 6, 'shared': 20}


def validate(text, workload, initial_bytes=None, initial_lines=None):
    rows = [dict(zip(('key',) + FIELDS + ('bytes', 'lines'), map(int, m))) for m in PATTERN.findall(text)]
    if len(rows) != COUNTS[workload] or [r['key'] for r in rows] != list(range(COUNTS[workload])):
        raise ValueError('Missing, duplicated or reordered key record')
    if 'All 5 tests passed.' not in text:
        raise ValueError('Product control did not finish')
    for r in rows:
        if r['lines'] < 1 or r['total_ns'] <= 0 or sum(r[k] for k in FIELDS[1:]) > r['total_ns']:
            raise ValueError('Invalid or overlapping clock record')
        if initial_bytes is not None:
            inserted = (len('\nconst Pasted = struct {\n fn p() void {\n _ = 1;\n }\n};\n') * 100 if workload == 'paste' else 3 if workload == 'structure' else 1)
            edits = (r['key'] + 1) % 2 if workload == 'undo' else r['key'] + 1
            if r['bytes'] != initial_bytes + edits * inserted:
                raise ValueError('Unexpected document bytes after input')
            added_lines = edits if workload == 'structure' else 600 if workload == 'paste' else 0
            if r['lines'] != initial_lines + added_lines:
                raise ValueError('Unexpected document lines after input')
    return rows


def summarize(root, repetitions=3):
    if repetitions < 1:
        raise ValueError('At least one repetition is required')
    inputs = json.loads((root / 'inputs.json').read_text())
    expected = {'flat-3000.zig', 'flat-15000.zig', 'flat-50000.zig', 'real-build.zig', 'real-host.swift'}
    if set(inputs) != expected:
        raise ValueError('Incomplete fixture manifest')
    for name, info in inputs.items():
        data = (root / 'fixtures' / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != info['sha256'] or len(data) != info['bytes']:
            raise ValueError('Fixture hash changed')
    binaries = json.loads((root / 'binaries.json').read_text())
    if set(binaries) != {'1'}:
        raise ValueError('Missing production measurement binary')
    for info in binaries.values():
        if hashlib.sha256(Path(info['binary']).read_bytes()).hexdigest() != info['sha256']:
            raise ValueError('Measurement binary changed')
    setup = json.loads((root / 'setup-1.json').read_text())
    if setup['mode'] != 1 or not setup['instrumented_sha256']:
        raise ValueError('Missing instrumented source manifest')
    for name, digest in setup['instrumented_sha256'].items():
        if hashlib.sha256((root / 'source-1' / name).read_bytes()).hexdigest() != digest:
            raise ValueError('Instrumented source changed')
    groups = []
    for name in sorted(inputs):
        for work in COUNTS:
            rows = []
            for rep in range(repetitions):
                rows.extend(validate((root / f'run-{rep}-1-{name}-{work}.log').read_text(), work, inputs[name]['bytes'], (root / 'fixtures' / name).read_bytes().count(b'\n') + 1))
            groups.append(dict(file=name, workload=work, events=len(rows), ms={k: dict(p50=statistics.median(r[k] for r in rows)/1e6, p95=sorted(r[k] for r in rows)[math.ceil(len(rows)*.95)-1]/1e6) for k in FIELDS}))
    return groups


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('root', type=Path)
    p.add_argument('--repetitions', type=int, default=3)
    args = p.parse_args()
    groups = summarize(args.root, args.repetitions)
    (args.root / 'storage-summary.json').write_text(json.dumps(groups, indent=2) + '\n')
    lines = ['| 파일 / 입력 | 전체 p50/p95 ms | delta p50 | 본문 복사 p50 | 줄 인덱스 p50 | 뷰 줄 배열 p50 |', '| --- | ---: | ---: | ---: | ---: | ---: |']
    for g in groups:
        m = g['ms']
        lines.append(f"| {g['file']} / {g['workload']} | {m['total_ns']['p50']:.2f}/{m['total_ns']['p95']:.2f} | " + ' | '.join(f"{m[k]['p50']:.3f}" for k in FIELDS[1:]) + ' |')
    (args.root / 'storage-summary.md').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
