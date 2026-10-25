#!/usr/bin/env python3
"""기존 제품 대조와 pane 구간·호출·중첩·원본 증거를 함께 검증한다."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pane_runner', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
spec = importlib.util.spec_from_file_location('provider_summary', ROOT/'tools/editor-provider-measure/summarize.py')
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)
original_names = provider.source_names
STAGES = runner.STAGES


def stage_names(info):
    schema = info.get('pane_schema')
    if type(schema) is not int or schema not in (1, 2, 3):
        raise ValueError('Unknown pane schema/stages')
    if schema == 3 and info.get('pane_summary_execution') not in ('retained-ranges', 'own-comparison'):
        raise ValueError('Unknown summary execution model')
    if schema == 3 and (type(info.get('pane_sticky_oracle')) is not int or info['pane_sticky_oracle'] != 1):
        raise ValueError('Missing full sticky reference contract')
    stages = STAGES[:-3] if schema == 1 else STAGES
    if info.get('pane_stages') != list(stages):
        raise ValueError('Mismatched pane schema/stages')
    return stages


def source_names(info):
    stage_names(info)
    extra = runner.EXTRA - {'src/syntax/symbols.zig'} if info['pane_schema'] == 1 else runner.EXTRA
    if info['pane_schema'] == 3 and info['pane_summary_execution'] == 'retained-ranges':
        extra = extra | {'src/syntax/changes.zig'}
    return original_names(info) | extra


provider.source_names = source_names


def validate(text, workload, data, filename, oracle, info):
    # 아래 판정은 기존 제품·Provider 시간/표본/호출 대조를 약화하지 않는다.
    provider.validate(text, workload, data, filename, oracle, info['provider_schema'], info['provider_execution'], info.get('frame_schema', 1))
    frames = provider.frame.validate(text, workload, len(data), data.count(b'\n')+1, info.get('frame_schema', 1))
    stages = stage_names(info)
    fields = ('key',) + tuple(field for stage in stages for field in (stage, stage+'_calls'))
    if info['pane_schema'] == 3:
        fields += ('stickyReusedChanges',)
    pattern = re.compile('PANE '+' '.join(field+r'=(\d+)' for field in fields))
    rows = []
    for line in text.splitlines():
        if not line.startswith('PANE '):
            continue
        match = pattern.fullmatch(line)
        if match is None:
            raise ValueError('Malformed pane record')
        rows.append(dict(zip(fields, map(int, match.groups()))))
    if [row['key'] for row in rows] != list(range(20)):
        raise ValueError('Missing/duplicate/reordered pane input')
    views = 2 if workload == 'shared' else 1
    if info['pane_schema'] == 3:
        markers = [line for line in text.splitlines() if line.startswith('PANE_ORACLE ')]
        expected = [f'PANE_ORACLE key={key} views={views} full=1' for key in range(20)] if oracle else []
        if markers != expected:
            raise ValueError('Missing/extra/reordered full sticky oracle')
    for row, frame in zip(rows, frames):
        retained = info['pane_schema'] == 3 and info['pane_summary_execution'] == 'retained-ranges'
        if any(row[name+'_calls'] != (0 if retained and name == 'stickyChangedRanges' else views) for name in stages):
            raise ValueError('Unexpected pane call count')
        if info['pane_schema'] == 3 and row['stickyReusedChanges'] != (views if retained else 0):
            raise ValueError('Unexpected retained summary updates')
        if retained and row['stickyChangedRanges'] != 0:
            raise ValueError('C comparison time without a C call')
        if any(row[name] > frame['appendPaneFrame'] for name in stages):
            raise ValueError('Pane child exceeds frame')
        if row['guides']+row['brackets'] > row['paneDecorations']:
            raise ValueError('Decoration children exceed parent')
        if info['pane_schema'] >= 2 and (row['stickyChangedRanges'] > row['stickySummary'] or row['stickySummary']+row['stickyAncestors'] > row['sticky']):
            raise ValueError('Sticky children exceed parent')
        # 들여쓰기·괄호는 장식 안에 포함되므로 이 합에서는 제외한다.
        roots = runner.HOST_STAGES + ('sticky',)
        if sum(row[name] for name in roots) > frame['appendPaneFrame']:
            raise ValueError('Pane root intervals overlap')
        row.update(appendPaneFrame=frame['appendPaneFrame'], total_ns=frame['total_ns'])
    return rows


def summarize(root, repetitions=3):
    root = root.resolve()
    base = provider.summarize(root, repetitions)
    info = provider.load(root/'setup-1.json')
    inputs = provider.load(root/'inputs.json')
    groups = {}
    for prefix, count, oracle in (('run', repetitions, 0), ('verify', 1, 1)):
        rows = provider.load(root/f'{prefix}-order.json')
        if not isinstance(rows, list) or any(not isinstance(row, dict) or any(type(row.get(name)) is not int for name in ('repetition', 'mode', 'returncode')) for row in rows):
            raise ValueError('Invalid execution receipt types')
        if rows != runner.order_rows(root, prefix, (root/f'{prefix}-order.stdout').read_text()):
            raise ValueError('Execution stdout and order receipt disagree')
        expected = [(rep, filename, workload) for rep in range(count) for filename in sorted(inputs) for workload in ('typing', 'shared')]
        if [(x['repetition'], x['file'], x['workload']) for x in rows] != expected:
            raise ValueError('Missing/extra/reordered executions')
        for row in rows:
            expected_log = root/f"{prefix}-{row['repetition']}-1-{row['file']}-{row['workload']}.log"
            if row['mode'] != 1 or row['returncode'] != 0 or Path(row['log']).resolve() != expected_log:
                raise ValueError('Invalid execution status/mode/log')
        for filename in sorted(inputs):
            data = (root/'fixtures'/filename).read_bytes()
            for workload in ('typing', 'shared'):
                for rep in range(count):
                    rows = validate((root/f'{prefix}-{rep}-1-{filename}-{workload}.log').read_text(), workload, data, filename, oracle, info)
                    if prefix == 'run':
                        groups.setdefault(filename+'/'+workload, []).extend(rows)
    def stats(values):
        return dict(n=len(values), p50=statistics.median(values)/1e6, p95=sorted(values)[math.ceil(len(values)*.95)-1]/1e6, max=max(values)/1e6)
    return dict(provider=base, pane={key: {name: stats([row[name] for row in rows]) for name in stage_names(info)+('appendPaneFrame', 'total_ns')} for key, rows in groups.items()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    result = summarize(args.root, args.repetitions)
    (args.root/'pane-summary.json').write_text(json.dumps(result, indent=2)+'\n')
    for key, values in result['pane'].items():
        print(key, ' '.join(name+'='+f'{values[name]["p50"]:.3f}' for name in values if name != 'total_ns'))


if __name__ == '__main__':
    main()
