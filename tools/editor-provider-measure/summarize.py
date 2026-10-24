#!/usr/bin/env python3
"""소스·바이너리·전수 대조·호출 수와 시간 포함 관계를 확인한 구문 비용 집계."""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('frame_summary', ROOT / 'tools/editor-frame-measure/summarize.py')
frame = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frame)
STAGES = ('on_edit', 'reset', 'sticky_edit', 'tree_edit', 'note_changed', 'changed_ranges', 'tree_release')
FIELDS = ('key',) + tuple(value for stage in STAGES for value in (stage, stage + '_calls')) + ('native_calls',)
PATTERN = re.compile('PROVIDER ' + ' '.join(field + r'=(\d+)' for field in FIELDS))
FIXTURES = {'flat-3000.zig', 'flat-15000.zig', 'flat-50000.zig', 'real-build.zig', 'real-host.swift'}
SOURCES = {'src/syntax/tree_sitter.zig', 'src/syntax/folds.zig', 'src/platform/macos/app_session/editor/mod.zig', 'src/platform/macos/app_session/editor/syntax.zig', 'build.zig', 'src/session/editor/edit_doc.zig', 'src/platform/macos/app_session/editor/shared_edit.zig', 'src/session/editor/fold.zig'}


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON field: ' + key)
        result[key] = value
    return result


def load(path):
    return json.loads(path.read_text(), object_pairs_hook=unique)


def digest(path, expected):
    if not isinstance(expected, str) or re.fullmatch('[0-9a-f]{64}', expected) is None:
        raise ValueError('Invalid SHA256 receipt')
    actual = hashlib.sha256()
    # 큰 제품 실행 파일을 한 번에 메모리에 올리지 않는다.
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            actual.update(chunk)
    if actual.hexdigest() != expected:
        raise ValueError('Changed artifact: ' + str(path))


def validate(text, workload, data, filename, oracle):
    if workload not in ('typing', 'shared') or oracle not in (0, 1):
        raise ValueError('Unsupported workload/oracle')
    frames = frame.validate(text, workload, len(data), data.count(b'\n') + 1)
    rows = []
    for line in text.splitlines():
        if not line.startswith('PROVIDER '):
            continue
        match = PATTERN.fullmatch(line)
        if match is None:
            raise ValueError('Malformed provider row')
        rows.append(dict(zip(FIELDS, map(int, match.groups()))))
    if [row['key'] for row in rows] != list(range(20)):
        raise ValueError('Missing/duplicate/reordered provider key')
    controls = [line for line in text.splitlines() if line.startswith('EW2 ')]
    if len(controls) != 1 or text.count('All 5 tests passed.') != 1:
        raise ValueError('Missing/duplicate successful product control')
    control = unique(token.split('=', 1) for token in controls[0].split()[1:])
    wanted = dict(mode='1', file=filename, work=workload, verified_each_edit=str(oracle), edits='20', deferred='0', mismatch='0')
    if any(control.get(key) != value for key, value in wanted.items()):
        raise ValueError('Wrong product control/fixture/oracle')
    samples = control.get('samples_ns', '').split(',')
    if samples[-1:] != [''] or len(samples) != 21 or any(re.fullmatch(r'\d+', value) is None for value in samples[:-1]):
        raise ValueError('Invalid product sample list')
    if list(map(int, samples[:-1])) != [value['total_ns'] for value in frames]:
        raise ValueError('Product samples disagree with frame/storage clocks')
    views = 2 if workload == 'shared' else 1
    for row, outer in zip(rows, frames):
        if row['native_calls'] != views or any(row[stage + '_calls'] != views for stage in STAGES):
            raise ValueError('Unexpected per-view native/observer calls')
        if row['changed_ranges'] > row['note_changed'] or row['note_changed'] > row['on_edit'] or row['on_edit'] > outer['providerEdit']:
            raise ValueError('Nested provider interval exceeds parent')
        # note_changed 안의 changed_ranges는 다시 더하지 않는다. 이 합은 개별 입력마다 검사한다.
        exclusive = sum(row[stage] for stage in ('reset', 'sticky_edit', 'tree_edit', 'note_changed', 'tree_release')) + outer['nativeParse']
        if exclusive > row['on_edit']:
            raise ValueError('Exclusive provider components overlap')
        row.update(native_parse=outer['nativeParse'], total_ns=outer['total_ns'])
    return rows


def summarize(root, repetitions=3):
    root = root.resolve()
    if type(repetitions) is not int or repetitions < 1:
        raise ValueError('Positive repetitions required')
    info = load(root / 'setup-1.json')
    if info.get('comparison_target') != 'provider-edit-attribution' or 'comparison_variant' in info or type(info.get('mode')) is not int or info['mode'] != 1:
        raise ValueError('Wrong attribution target/mode')
    if info.get('provider_stages') != list(STAGES) or info.get('frame_stages') != list(frame.STAGES + frame.SYNTAX_STAGES):
        raise ValueError('Wrong stage schema')
    for field in ('original_sha256', 'instrumented_sha256'):
        if set(info.get(field, {})) != SOURCES:
            raise ValueError('Incomplete source provenance')
        if any(not isinstance(value, str) or re.fullmatch('[0-9a-f]{64}', value) is None for value in info[field].values()):
            raise ValueError('Invalid source provenance')
    for name, value in info['original_sha256'].items():
        digest(root / 'original-product' / name, value)
    for name, value in info['instrumented_sha256'].items():
        digest(root / 'source-1' / name, value)
    binaries = load(root / 'binaries.json')
    if set(binaries) != {'1'}:
        raise ValueError('Wrong binary modes')
    binary = binaries['1']
    if Path(binary['cwd']).resolve() != (root / 'source-1').resolve():
        raise ValueError('Unexpected binary working directory')
    binary_path = Path(binary['binary']).resolve()
    if not binary_path.is_relative_to((root / 'source-1' / '.zig-cache').resolve()):
        raise ValueError('Binary outside captured source cache')
    digest(binary_path, binary['sha256'])
    inputs = load(root / 'inputs.json')
    if set(inputs) != FIXTURES:
        raise ValueError('Incomplete pinned fixtures')
    data = {}
    for name, value in inputs.items():
        data[name] = (root / 'fixtures' / name).read_bytes()
        digest(root / 'fixtures' / name, value['sha256'])
        if type(value['bytes']) is not int or value['bytes'] != len(data[name]):
            raise ValueError('Wrong fixture byte count')
    groups = {}
    # 정확성 표본을 성능 표본과 합치지 않으며, 추가·누락 실행도 묵인하지 않는다.
    for prefix, count, oracle in (('run', repetitions, 0), ('verify', 1, 1)):
        expected = {f'{prefix}-{rep}-1-{name}-{work}.log' for rep in range(count) for name in inputs for work in ('typing', 'shared')}
        if {path.name for path in root.glob(prefix + '-*.log')} != expected:
            raise ValueError('Missing/extra execution logs: ' + prefix)
        for name in sorted(inputs):
            for work in ('typing', 'shared'):
                for rep in range(count):
                    rows = validate((root / f'{prefix}-{rep}-1-{name}-{work}.log').read_text(), work, data[name], name, oracle)
                    if prefix == 'run':
                        groups.setdefault(name + '/' + work, []).extend(rows)
    def stats(values):
        return dict(n=len(values), p50=statistics.median(values) / 1e6, p95=sorted(values)[math.ceil(len(values) * .95) - 1] / 1e6, max=max(values) / 1e6)
    return {name: {stage: stats([row[stage] for row in rows]) for stage in STAGES + ('native_parse', 'total_ns')} for name, rows in groups.items()}


def render(summary):
    columns = ('total_ns', 'on_edit', 'native_parse', 'note_changed', 'changed_ranges', 'tree_edit')
    lines = ['| 파일/입력 | 전체 | Provider | C 파싱 | 변경 통지 | C 범위 계산 | 트리 편집 |', '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for name, values in summary.items():
        lines.append('| ' + name + ' | ' + ' | '.join(f'{values[key]["p50"]:.3f}' for key in columns) + ' |')
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    result = summarize(args.root, args.repetitions)
    (args.root / 'provider-summary.json').write_text(json.dumps(result, indent=2) + '\n')
    (args.root / 'provider-summary.md').write_text(render(result))
    print(render(result), end='')


if __name__ == '__main__':
    main()
