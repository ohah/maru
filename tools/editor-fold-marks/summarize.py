#!/usr/bin/env python3
"""교차 실행의 전후 상태·순서·측정 조건을 대조하고 결과를 내보낸다."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import statistics

spec = importlib.util.spec_from_file_location('comparison', Path(__file__).with_name('compare.py'))
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)
frame = comparison.frame


def followup(root, metric):
    order = json.loads((root / 'followup-order.json').read_text())
    keys = [(e['repetition'], e['file'], e['workload'], e['variant']) for e in order]
    if not keys or len(keys) != len(set(keys)):
        raise ValueError('Empty or duplicated follow-up order')
    if len({(entry['file'], entry['workload']) for entry in order}) != 1:
        raise ValueError('Follow-up must describe one condition')
    pairs = {}
    rows = {'baseline': [], 'cursor': []}
    for variant in rows:
        comparison.check_source(root / variant)
    for entry in order:
        variant = entry['variant']
        folder = root / variant
        inputs = json.loads((folder / 'inputs.json').read_text())
        file, work, rep = entry['file'], entry['workload'], entry['repetition']
        pairs.setdefault((rep, file, work), set()).add(variant)
        data = (folder / 'fixtures' / file).read_bytes()
        text = (folder / f'followup-{rep}-1-{file}-{work}.log').read_text()
        if entry['verify_each_edit'] != 0 or 'verified_each_edit=0 ' not in text:
            raise ValueError('Follow-up contains per-key oracle')
        rows[variant].extend(frame.validate(text, work, inputs[file]['bytes'], data.count(b'\n') + 1))
    if any(sides != {'baseline', 'cursor'} for sides in pairs.values()):
        raise ValueError('Unpaired follow-up')
    result = {}
    for variant, records in rows.items():
        result[variant] = dict(events=len(records), ms={key: dict(p50=statistics.median(r[key] for r in records)/1e6, p95=sorted(r[key] for r in records)[math.ceil(len(records)*.95)-1]/1e6) for key in ('total_ns', metric, 'nativeParse', 'edit_ns', 'appendPaneFrame')})
    (root / 'followup-summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('output', type=Path)
    p.add_argument('--repetitions', type=int, default=3)
    p.add_argument('--followup', action='store_true')
    p.add_argument('--metric', choices=('rebuildVisible', 'foldSpansCached'), default='rebuildVisible')
    args = p.parse_args()
    root = args.output.resolve()
    if args.followup:
        # 기본 완결 자료의 해시·실행 수 검증을 먼저 통과시킨다.
        for variant in ('baseline', 'cursor'):
            frame.summarize(root / variant, args.repetitions)
        followup(root, args.metric)
        return
    groups = {}
    inputs = None
    events = {'run': 0, 'verify': 0}
    expected_order = {'run': set(), 'verify': set()}
    for variant in ('baseline', 'cursor'):
        folder = root / variant
        comparison.check_source(folder)
        groups[variant] = frame.summarize(folder, args.repetitions)
        current = json.loads((folder / 'inputs.json').read_text())
        if inputs is not None and inputs != current:
            raise ValueError('Variants use different fixtures')
        inputs = current
        for prefix, count, oracle in (('run', args.repetitions, 0), ('verify', 1, 1)):
            for rep in range(count):
                for file, info in sorted(inputs.items()):
                    lines = (folder / 'fixtures' / file).read_bytes().count(b'\n') + 1
                    for work in frame.storage.COUNTS:
                        text = (folder / f'{prefix}-{rep}-1-{file}-{work}.log').read_text()
                        if f'verified_each_edit={oracle} ' not in text:
                            raise ValueError('Wrong per-key oracle condition')
                        events[prefix] += len(frame.validate(text, work, info['bytes'], lines))
                        expected_order[prefix].add((rep, file, work, variant))
    for prefix, expected in expected_order.items():
        order = json.loads((root / (prefix + '-order.json')).read_text())
        actual = [(entry['repetition'], entry['file'], entry['workload'], entry['variant']) for entry in order]
        if len(actual) != len(expected) or set(actual) != expected:
            raise ValueError('Incomplete or duplicated execution order')
    rows = []
    for before, after in zip(groups['baseline'], groups['cursor']):
        if (before['file'], before['workload'], before['events']) != (after['file'], after['workload'], after['events']):
            raise ValueError('Mismatched condition')
        rows.append(dict(file=before['file'], workload=before['workload'], events_per_variant=before['events'], baseline=before['ms'], cursor=after['ms']))
    summary = dict(events=events, conditions=rows)
    (root / 'comparison-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    label = '표시 재구축' if args.metric == 'rebuildVisible' else '접힘 캐시 조회'
    lines = [f'| 파일 / 입력 | 전체 전 p50/p95 | 전체 후 p50/p95 | {label} 전 p50/p95 | {label} 후 p50/p95 |', '| --- | ---: | ---: | ---: | ---: |']
    for row in rows:
        columns = []
        for field in ('total_ns', args.metric):
            for variant in ('baseline', 'cursor'):
                value = row[variant][field]
                columns.append(f"{value['p50']:.3f} / {value['p95']:.3f}")
        lines.append('| ' + row['file'] + ' / ' + row['workload'] + ' | ' + ' | '.join(columns) + ' |')
    (root / 'comparison-summary.md').write_text('\n'.join(lines) + '\n')
    print(json.dumps(events))
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
