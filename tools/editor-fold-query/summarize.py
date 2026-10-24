#!/usr/bin/env python3
"""접힘 세부 구간과 상위 시간을 키별로 대조하며 누락·중복·겹침을 거절한다."""
import argparse
import json
from pathlib import Path
import re
import statistics

STAGES = ('changed_ranges', 'records_update', 'sort', 'dedup', 'coordinates_output', 'snapshot')


def parse(text):
    frame, query = {}, {}
    for line in text.splitlines():
        match = re.match(r'(FRAME|FOLD_QUERY) key=(\d+) (.*)', line)
        if not match:
            continue
        kind, key, fields = match.groups()
        target = frame if kind == 'FRAME' else query
        if int(key) in target:
            raise ValueError('Duplicate key: ' + kind + key)
        pairs = re.findall(r'(\w+)=(-?\d+)', fields)
        if len({name for name, _ in pairs}) != len(pairs):
            raise ValueError('Duplicate interval field')
        values = {name: int(value) for name, value in pairs}
        required = ('foldSpansCached',) if kind == 'FRAME' else STAGES
        if not all(name in values for name in required) or any(values[name] < 0 for name in required):
            raise ValueError('Missing or negative interval')
        target[int(key)] = values
    if not frame or frame.keys() != query.keys():
        raise ValueError('Missing frame/query pair')
    if sorted(frame) != list(range(len(frame))):
        raise ValueError('Missing input sequence')
    result = []
    for key in sorted(frame):
        parent = frame[key]['foldSpansCached']
        total = sum(query[key][name] for name in STAGES)
        if total > parent:
            raise ValueError('Exclusive intervals exceed parent')
        result.append(dict(key=key, total_ns=parent, remainder_ns=parent-total, **query[key]))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('--prefix', default='run')
    args = parser.parse_args()
    groups = {}
    for path in sorted(args.root.glob(args.prefix + '-*.log')):
        match = re.fullmatch(re.escape(args.prefix) + r'-(\d+)-1-(.*)-(typing|structure|paste|undo|shared|folded|command)\.log', path.name)
        if not match:
            continue
        if 'All 5 tests passed.' not in path.read_text():
            raise ValueError('Missing successful control: ' + str(path))
        rows = parse(path.read_text())
        group = groups.setdefault(match[2] + '/' + match[3], [])
        group.extend(rows)
    if not groups:
        raise ValueError('No measurements')
    summary = {}
    for name, rows in groups.items():
        summary[name] = dict(events=len(rows), **{field: statistics.median(row[field] for row in rows) / 1e6 for field in ('total_ns', 'remainder_ns') + STAGES})
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
