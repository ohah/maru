#!/usr/bin/env python3
"""포함 시간을 합산하지 않고 부모 구간과 키 대응을 검증해 집계한다."""
import argparse
import importlib.util
import math
from pathlib import Path
import re
import statistics
import json

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('storage_summary', ROOT / 'tools/editor-storage-measure/summarize.py')
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)
spec = importlib.util.spec_from_file_location('frame_contract', Path(__file__).with_name('contract.py'))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
STAGES = contract.STAGES
SYNTAX_STAGES = contract.LEGACY_SYNTAX_STAGES
FIELDS = ('edit_ns',) + STAGES + SYNTAX_STAGES
PATTERN = re.compile('FRAME key=(\\d+) ' + ' '.join(name + r'=(\d+)' for name in FIELDS) + r'(?=\r?$)', re.MULTILINE)


def validate(text, workload, initial_bytes, initial_lines, schema=1):
    syntax_stages = contract.syntax_stages(schema)
    fields = ('edit_ns',) + STAGES + syntax_stages
    pattern = re.compile('FRAME key=(\\d+) ' + ' '.join(name + r'=(\d+)' for name in fields) + r'(?=\r?$)', re.MULTILINE)
    original = storage.validate(text, workload, initial_bytes, initial_lines)
    expected_views = 2 if workload == 'shared' else 1
    if text.count(f'FRAME_WARM bracket_ready=1 views={expected_views}\n') != 1:
        raise ValueError('Missing complete bracket warm-up')
    records = [dict(zip(('key',) + fields, map(int, m))) for m in pattern.findall(text)]
    if text.count('FRAME ') != len(records):
        raise ValueError('Malformed or mixed frame records')
    if [r['key'] for r in records] != list(range(len(original))):
        raise ValueError('Missing or mismatched frame key')
    if schema == 1 and 'FRAME_CALLS ' in text:
        raise ValueError('Current frame call records in legacy schema')
    if schema == 2:
        pattern_calls = re.compile(r'FRAME_CALLS key=(\d+) providerEdit_calls=(\d+) bracketUpdate_calls=(\d+)(?=\r?$)', re.MULTILINE)
        calls = [dict(zip(('key', 'providerEdit_calls', 'bracketUpdate_calls'), map(int, match))) for match in pattern_calls.findall(text)]
        if text.count('FRAME_CALLS ') != len(calls) or [row['key'] for row in calls] != list(range(len(original))):
            raise ValueError('Missing or malformed frame call coverage')
        for record, count in zip(records, calls):
            if count['providerEdit_calls'] != expected_views or count['bracketUpdate_calls'] != expected_views:
                raise ValueError('Frame call coverage misses an active view')
            record.update(providerEdit_calls=count['providerEdit_calls'], bracketUpdate_calls=count['bracketUpdate_calls'])
    for record, outer in zip(records, original):
        total = outer['total_ns']
        if any(record[name] > total for name in fields):
            raise ValueError('Inclusive stage exceeds whole input')
        if record['edit_ns'] + record['appendPaneFrame'] > total:
            raise ValueError('Edit and frame intervals overlap')
        if record['refreshViewAfterEditImpl'] > record['edit_ns']:
            raise ValueError('Refresh exceeds edit interval')
        if any(record[name] > record['appendPaneFrame'] for name in ('advanceSyntax', 'syntaxColors', 'minimapSide', 'buildPaneOps')):
            raise ValueError('Frame child exceeds frame interval')
        if sum(record[name] for name in syntax_stages[:4]) > record['syntaxEdit']:
            raise ValueError('Disjoint syntax components exceed syntax edit')
    return [dict(**outer, **{k: v for k, v in inner.items() if k != 'key'}) for outer, inner in zip(original, records)]


def summarize(root, repetitions=3):
    # 원문·바이너리·계측 소스의 검증은 저장소 집계기의 같은 계약을 재사용한다.
    storage.summarize(root, repetitions)
    setup = json.loads((root / 'setup-1.json').read_text())
    schema = contract.manifest_schema(setup)
    fields = ('edit_ns',) + STAGES + contract.syntax_stages(schema)
    inputs = json.loads((root / 'inputs.json').read_text())
    groups = []
    for name, info in sorted(inputs.items()):
        for work in storage.COUNTS:
            rows = []
            for rep in range(repetitions):
                rows.extend(validate((root / f'run-{rep}-1-{name}-{work}.log').read_text(), work, info['bytes'], (root / 'fixtures' / name).read_bytes().count(b'\n') + 1, schema))
            groups.append(dict(file=name, workload=work, events=len(rows), ms={key: dict(p50=statistics.median(r[key] for r in rows)/1e6, p95=sorted(r[key] for r in rows)[math.ceil(len(rows)*.95)-1]/1e6) for key in ('total_ns',) + fields}))
    return groups


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    groups = summarize(args.root, args.repetitions)
    (args.root / 'frame-summary.json').write_text(json.dumps(groups, indent=2) + '\n')
    columns = ('total_ns', 'edit_ns', 'appendPaneFrame', 'refreshViewAfterEditImpl', 'advanceSyntax', 'promoteFoldRangesToSyntax', 'ensureLineCols', 'syntaxColors', 'buildPaneOps')
    lines = ['| 파일 / 입력 | 전체 | 편집 | 프레임 | 편집 뷰 갱신 | 구문 단계 | 접힘 승격 | 줄 폭 | 구문 색 | draw ops |', '| --- | ' + ' | '.join('---:' for _ in columns) + ' |']
    for group in groups:
        lines.append('| ' + group['file'] + ' / ' + group['workload'] + ' | ' + ' | '.join(f"{group['ms'][key]['p50']:.3f}" for key in columns) + ' |')
    bracket_field = 'bracketUpdate' if 'bracketUpdate' in groups[0]['ms'] else 'bracketRefresh'
    details = ('syntaxEdit', 'providerEdit', 'nativeParse', 'bracketShift', bracket_field, 'foldCacheEdit', 'foldSpansCached', 'ensureFoldRanges', 'installFoldRanges', 'rebuildVisible')
    lines.extend(['', '| 파일 / 입력 | 구문 편집 | provider 편집 | C 파싱 | 괄호 이동 | 괄호 갱신 | 접힘 캐시 이동 | 접힘 캐시 조회 | 들여쓰기 범위 | 범위 설치 | 표시 재구축 |', '| --- | ' + ' | '.join('---:' for _ in details) + ' |'])
    for group in groups:
        lines.append('| ' + group['file'] + ' / ' + group['workload'] + ' | ' + ' | '.join(f"{group['ms'][key]['p50']:.3f}" for key in details) + ' |')
    (args.root / 'frame-summary.md').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
