#!/usr/bin/env python3
"""원시 로그를 토큰으로 다시 읽어 단계 합계·모집단·해시를 대조하고 통계를 계산한다."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics

NAMES = ('current_copy', 'prior_copy', 'leaf_copy', 'change', 'shift', 'native', 'refresh', 'summary', 'folds', 'brackets')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(value, message):
    if not value:
        raise ValueError(message)


def raw_stages(text):
    rows = []
    for line in text.splitlines():
        if 'WORKER_STAGE ' not in line:
            continue
        fields = line.split('WORKER_STAGE ', 1)[1].split()
        values = dict(token.split('=', 1) for token in fields)
        require(len(values) == len(fields), 'duplicate stage field')
        require(set(values) == {'revision', 'mode', 'mask', 'total_ns', 'other_ns', *(name + '_ns' for name in NAMES)}, 'stage field shape')
        row = {key: value if key == 'mode' else int(value) for key, value in values.items()}
        require(all(0 <= value < 2**64 for key, value in row.items() if key != 'mode'), 'stage integer range')
        require(row['total_ns'] > 0, 'empty worker duration')
        require(sum(row[name + '_ns'] for name in NAMES) + row['other_ns'] == row['total_ns'], 'independent stage arithmetic')
        rows.append(row)
    require([row['revision'] for row in rows] == list(range(1, 22)), 'independent stage population')
    return rows


def report(root):
    result = json.loads((root / 'result.json').read_text())
    receipt = json.loads((root / 'source.json').read_text())
    runs = json.loads((root / 'runs.json').read_text())
    require(result['complete'] is True and result['stage_diagnostics'] is True and receipt['stage_diagnostics'] is True, 'not completed stage diagnostics')
    require(sha(root / 'measure-test') == result['binary_sha256'], 'binary drift')
    for name, digest in receipt['original'].items():
        path = root / 'source' / name
        expected = receipt['private_worker_sha256'] if name.endswith('/parse/worker.zig') else digest
        require(sha(path) == expected, 'source drift: ' + name)
    for name, data in receipt['inputs'].items():
        require(sha(root / name) == data['sha256'], 'fixture drift')
    require(set(receipt['inputs']) == {f'{kind}-{size}.zig' for kind in ('flat', 'multiline') for size in (3000, 50000)}, 'fixture matrix')
    expected = {(name, mode, accuracy, rep) for name in receipt['inputs'] for mode in ('full', 'incremental') for accuracy in (0, 1) for rep in range(3 if accuracy == 0 else 1)}
    cells = []
    for run in runs:
        require(type(run['accuracy']) is int and type(run['rep']) is int, 'invalid run integer')
        cell = (run['fixture'], run['mode'], run['accuracy'], run['rep'])
        cells.append(cell)
        log = root / run['log']
        require(sha(log) == run['log_sha256'], 'log drift')
        text = log.read_text()
        require('All 1 tests passed.' in text, 'unsuccessful run')
        measured = []
        for line in text.splitlines():
            if 'PARSE_MEASURE ' not in line:
                continue
            values = dict(token.split('=', 1) for token in line.split('PARSE_MEASURE ', 1)[1].split())
            row = {(key.removeprefix('bracket_') if key.startswith('bracket_') else key): value if key == 'mode' else int(value) for key, value in values.items()}
            measured.append(row)
        require(measured == run['rows'], 'raw/JSON measure disagreement')
        rows = raw_stages(text)
        require(rows == run['stages'], 'raw/JSON stage disagreement')
        full = run['mode'] == 'full'
        for index, row in enumerate(rows):
            require(row['mode'] == ('cold' if index == 0 else 'incremental'), 'stage mode')
            require(row['mask'] == (929 if index == 0 else 1019 if full else 1023), 'stage calls')
            if index:
                require(row['total_ns'] <= run['rows'][index - 1]['complete_ns'], 'service containment')
        require([row['index'] for row in run['rows']] == list(range(20)), 'measure population')
        for row in run['rows']:
            require((row['rebuilds'], row['partials']) == ((1, 0) if full else (0, 1)), 'bracket branch')
    require(len(cells) == len(expected) and set(cells) == expected, 'missing or duplicate process cell')
    require(result['processes'] == len(cells) and result['edits'] == 20 * len(cells), 'result population')
    summary = {}
    for name in receipt['inputs']:
        summary[name] = {}
        for mode in ('full', 'incremental'):
            rows = [row for run in runs if run['fixture'] == name and run['mode'] == mode and run['accuracy'] == 0 for row in run['stages'][1:]]
            summary[name][mode] = dict(edits=len(rows), median_ms={key: statistics.median(row[key] for row in rows) / 1e6 for key in ('total_ns', *(name + '_ns' for name in NAMES), 'other_ns')}, median_fold_share=statistics.median(row['folds_ns'] / row['total_ns'] for row in rows))
    return dict(head=receipt['head'], binary_sha256=result['binary_sha256'], processes=len(runs), edits=20 * len(runs), independent_raw_stage_rows=sum(len(run['stages']) for run in runs), summary=summary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('new output required')
    result = report(args.root.resolve())
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result['summary'], indent=2))


if __name__ == '__main__':
    main()
