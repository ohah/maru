#!/usr/bin/env python3
"""기존 제품/pane 대조와 새 변환 구간·호출 수·원본 증거를 함께 검증한다."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('lowering_runner', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
spec = importlib.util.spec_from_file_location('pane_summary', ROOT/'tools/editor-pane-measure/summarize.py')
pane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pane)
parent_sources = pane.source_names


def source_names(info):
    runner.check_contract(info)
    return parent_sources(info) | runner.EXTRA


pane.provider.source_names = source_names


def validate(text, workload, data, filename, oracle, info):
    parents = pane.validate(text, workload, data, filename, oracle, info)
    stages = runner.stage_names(info)
    fields = ('key',) + tuple(field for name in stages for field in (name, name+'_calls'))
    pattern = re.compile('LOWERING '+' '.join(field+r'=(\d+)' for field in fields))
    rows = []
    for line in text.splitlines():
        if not line.startswith('LOWERING '):
            continue
        match = pattern.fullmatch(line)
        if match is None:
            raise ValueError('Malformed lowering record')
        rows.append(dict(zip(fields, map(int, match.groups()))))
    if [row['key'] for row in rows] != list(range(20)):
        raise ValueError('Missing/duplicate/reordered lowering input')
    views = 2 if workload == 'shared' else 1
    for row, parent in zip(rows, parents):
        if any(row[name+'_calls'] != views for name in stages):
            raise ValueError('Wrong lowering call count')
        # 이 fixture에서는 모두 순차 구간이다. 일반 장식의 중첩 자식은 다시 더하지 않는다.
        roots = pane.runner.HOST_STAGES + ('sticky',)
        if any(row[name] > parent['appendPaneFrame'] for name in stages):
            raise ValueError('Lowering child exceeds pane frame')
        if sum(row[name] for name in stages) + sum(parent[name] for name in roots) > parent['appendPaneFrame']:
            raise ValueError('Lowering and pane root intervals overlap')
        row.update(appendPaneFrame=parent['appendPaneFrame'], total_ns=parent['total_ns'])
    return rows


def summarize(root, repetitions=3):
    root = root.resolve()
    info = pane.provider.load(root/'setup-1.json')
    source_names(info)
    stages = runner.stage_names(info)
    base = pane.summarize(root, repetitions)
    inputs = pane.provider.load(root/'inputs.json')
    groups = {}
    for prefix, count, oracle in (('run', repetitions, 0), ('verify', 1, 1)):
        for filename in sorted(inputs):
            data = (root/'fixtures'/filename).read_bytes()
            for workload in ('typing', 'shared'):
                for rep in range(count):
                    text = (root/f'{prefix}-{rep}-1-{filename}-{workload}.log').read_text()
                    rows = validate(text, workload, data, filename, oracle, info)
                    if prefix == 'run':
                        groups.setdefault(filename+'/'+workload, []).extend(rows)
    def stats(values):
        return dict(n=len(values), p50=statistics.median(values)/1e6, p95=sorted(values)[math.ceil(len(values)*.95)-1]/1e6, max=max(values)/1e6)
    return dict(parent=base, lowering={key: {name: stats([row[name] for row in rows]) for name in stages+('appendPaneFrame', 'total_ns')} for key, rows in groups.items()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    result = summarize(args.root, args.repetitions)
    (args.root/'lowering-summary.json').write_text(json.dumps(result, indent=2)+'\n')
    stages = runner.stage_names(pane.provider.load(args.root/'setup-1.json'))
    for key, values in result['lowering'].items():
        print(key, ' '.join(name+'='+f'{values[name]["p50"]:.3f}' for name in stages))


if __name__ == '__main__':
    main()
