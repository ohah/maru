#!/usr/bin/env python3
"""분할 생성부터 준비·첫 입력까지의 원시 표본과 모든 후속 입력을 함께 보존한다."""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('comparison', ROOT / 'tools/editor-fold-marks/compare.py')
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


def values(line):
    pairs = re.findall(r'(\w+)=(-?\d+)', line)
    if len(dict(pairs)) != len(pairs):
        raise ValueError('Duplicate field')
    result = {key: int(value) for key, value in pairs}
    if any(value < 0 for value in result.values()):
        raise ValueError('Negative interval')
    return result


def parse(text):
    def one(prefix):
        found = [values(line) for line in text.splitlines() if line.startswith(prefix + ' ')]
        if len(found) != 1:
            raise ValueError('Missing or duplicated ' + prefix)
        return found[0]
    split, ready = one('SHARED_SPLIT'), one('SHARED_READY')
    frames, edits = {}, {}
    for line in text.splitlines():
        if line.startswith('FRAME ') or line.startswith('STORAGE '):
            row = values(line)
            dest = frames if line.startswith('FRAME ') else edits
            if row['key'] in dest:
                raise ValueError('Duplicate input')
            dest[row['key']] = row
    if set(frames) != set(range(20)) or set(edits) != set(frames):
        raise ValueError('Missing input sequence')
    if ready['ns'] < split['ns'] or ready['native_parse'] > ready['ns']:
        raise ValueError('Invalid startup intervals')
    return dict(split_ns=split['ns'], ready_ns=ready['ns'], native_parse_ns=ready['native_parse'],
                primary_cache=ready['primary_cache'], peer_cache=ready['peer_cache'],
                first_ns=edits[0]['total_ns'], first_query_ns=frames[0]['foldSpansCached'],
                ready_first_ns=ready['ns']+edits[0]['total_ns'],
                all_ns=[edits[key]['total_ns'] for key in range(20)],
                subsequent_ns=[edits[key]['total_ns'] for key in range(1,20)])


def stats(data):
    return dict(n=len(data), p50=statistics.median(data)/1e6,
                p95=sorted(data)[math.ceil(len(data)*.95)-1]/1e6, max=max(data)/1e6)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('--repetitions', type=int, default=10)
    args = parser.parse_args()
    root = args.root.resolve()
    inputs = json.loads((root/'baseline/inputs.json').read_text())
    samples = {name: {} for name in inputs}
    for variant in ('baseline','cursor'):
        folder = root/variant
        comparison.check_source(folder)
        info = json.loads((folder/'setup-1.json').read_text())
        if info.get('comparison_target')!='shared-initial-snapshot' or info.get('comparison_variant')!=('binary-search' if variant=='baseline' else 'cursor'):
            raise ValueError('Wrong comparison target/variant')
        if variant=='baseline' and (not info.get('legacy_commit') or len(info.get('legacy_sha256',{}))!=4):
            raise ValueError('Missing predecessor provenance')
        binary = json.loads((folder/'binaries.json').read_text())['1']
        if hashlib.sha256(Path(binary['binary']).read_bytes()).hexdigest()!=binary['sha256']:
            raise ValueError('Binary changed')
        if json.loads((folder/'inputs.json').read_text())!=inputs:
            raise ValueError('Different fixtures')
    for prefix,repetitions,oracle in [('run',args.repetitions,0),('verify',1,1)]:
        order = json.loads((root/(prefix+'-order.json')).read_text())
        expected = {(rep,name,variant) for rep in range(repetitions) for name in inputs for variant in ('baseline','cursor')}
        seen = set()
        for entry in order:
            key = (entry['repetition'],entry['file'],entry['variant'])
            if key not in expected or key in seen or entry['workload']!='shared' or entry['verify_each_edit']!=oracle:
                raise ValueError('Invalid or duplicated execution order')
            seen.add(key)
            rep,name,variant = key
            log = root/variant/f'{prefix}-{rep}-1-{name}-shared.log'
            if Path(entry['log']).resolve()!=log.resolve():
                raise ValueError('Unexpected log path')
            data = (root/variant/'fixtures'/name).read_bytes()
            if hashlib.sha256(data).hexdigest()!=inputs[name]['sha256']:
                raise ValueError('Fixture changed')
            text = log.read_text()
            comparison.frame.validate(text,'shared',len(data),data.count(b'\n')+1)
            if f'verified_each_edit={oracle} ' not in text or 'All 5 tests passed.' not in text:
                raise ValueError('Missing successful product control')
            row = parse(text)
            if row['primary_cache']!=1 or row['peer_cache']!=(0 if variant=='baseline' else 1):
                raise ValueError('Startup cache path differs')
            if variant=='cursor' and row['native_parse_ns']!=0:
                raise ValueError('Snapshot unexpectedly reparsed')
            if prefix=='run':samples[name].setdefault(variant,[]).append(row)
        if seen!=expected:
            raise ValueError('Incomplete executions')
    summary = {}
    for name,variants in samples.items():
        summary[name]={}
        for variant,rows in variants.items():
            metrics = {key:stats([row[key] for row in rows]) for key in ('split_ns','ready_ns','native_parse_ns','first_ns','first_query_ns','ready_first_ns')}
            metrics.update({key:stats([value for row in rows for value in row[key]]) for key in ('all_ns','subsequent_ns')})
            summary[name][variant] = metrics
    (root/'shared-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    lines=['| 파일 | 준비+첫 입력 전 p50/p95 | 후 p50/p95 | 첫 입력 전 p50/p95 | 후 p50/p95 | 분할 명령 전/후 p50 |',
           '| --- | ---: | ---: | ---: | ---: | ---: |']
    for name,variants in summary.items():
        cells=[name]
        for field in ('ready_first_ns','first_ns'):
            for variant in ('baseline','cursor'):
                metric=variants[variant][field]
                cells.append(f"{metric['p50']:.3f} / {metric['p95']:.3f}")
        cells.append(' / '.join(f"{variants[variant]['split_ns']['p50']:.3f}" for variant in ('baseline','cursor')))
        lines.append('| '+' | '.join(cells)+' |')
    (root/'shared-summary.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines))


if __name__=='__main__':main()
