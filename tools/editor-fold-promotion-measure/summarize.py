#!/usr/bin/env python3
"""기존 대조를 유지하고 접힘 승격의 포함 시간·작업량·전체 소스 증거를 검증한다."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import re
import statistics

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('promotion_runner', HERE / 'run.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
spec = importlib.util.spec_from_file_location(
    'promotion_parent', runner.ROOT / 'tools/editor-pane-syntax-measure/summarize.py'
)
parent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parent)
FIELDS = ('key',) + tuple(value for name in runner.STAGES for value in (name, name + '_calls')) + ('spans',)
PATTERN = re.compile('FOLD_PROMOTION ' + ' '.join(name + r'=(\d+)' for name in FIELDS))


def rows(text, workload, info):
    runner.check_contract(info)
    if workload not in ('typing', 'shared'):
        raise ValueError('Unsupported promotion workload')
    parents = parent.rows(text, workload, info)
    result = []
    for line in text.splitlines():
        if line.startswith('FOLD_PROMOTION '):
            match = PATTERN.fullmatch(line)
            if match is None:
                raise ValueError('Malformed promotion row')
            result.append(dict(zip(FIELDS, map(int, match.groups()))))
    if [row['key'] for row in result] != list(range(20)):
        raise ValueError('Missing/duplicate/reordered promotion inputs')
    views = 2 if workload == 'shared' else 1
    for row, outer in zip(result, parents):
        if row['key'] != outer['key']:
            raise ValueError('Promotion parent key')
        if any(row[name + '_calls'] != views for name in runner.STAGES) or row['spans'] < views:
            raise ValueError('Promotion call scope/work count')
        if row['promote'] > outer['promoteFolds']:
            raise ValueError('Promotion exceeds original INNER parent')
        if row['query'] + row['ranges'] + row['install'] > row['promote']:
            raise ValueError('Promotion children overlap or exceed parent')
        if row['visible'] + row['finish'] > row['install']:
            raise ValueError('Installation children overlap or exceed parent')
    return result


def check_phase_proof(root, prefix, repetitions):
    proof = runner.load(root / ('promotion-' + prefix + '-proof.json'))
    if (set(proof) != {'schema', 'target', 'prefix', 'execution', 'sha256'}
            or type(proof.get('schema')) is not int or proof['schema'] != 1
            or proof.get('target') != runner.TARGET or proof.get('prefix') != prefix):
        raise ValueError('Wrong promotion execution proof model')
    execution = proof['execution']
    if (not isinstance(execution, dict) or set(execution) != {'repetitions', 'workloads', 'oracle'}
            or type(execution['repetitions']) is not int or execution['repetitions'] != repetitions
            or execution['workloads'] != ['typing', 'shared']
            or type(execution['oracle']) is not int or execution['oracle'] != int(prefix == 'verify')):
        raise ValueError('Wrong promotion execution arguments')
    names = {'setup-1.json', 'inputs.json', 'binaries.json', 'promotion-generator.py',
             prefix + '-order.json', prefix + '-order.stdout'}
    names.update(f'{prefix}-{rep}-1-{filename}-{work}.log'
                 for rep in range(repetitions) for filename in runner.NAMES for work in ('typing', 'shared'))
    hashes = proof.get('sha256')
    if not isinstance(hashes, dict) or set(hashes) != names:
        raise ValueError('Incomplete promotion execution proof')
    for name, digest in hashes.items():
        if (not isinstance(digest, str) or re.fullmatch('[0-9a-f]{64}', digest) is None
                or runner.sha(root / name) != digest):
            raise ValueError('Changed promotion execution artifact: ' + name)


def check_evidence(root, info):
    runner.check_contract(info)
    runner.check_inputs(root, info)
    if runner.sha(root / 'promotion-generator.py') != info['promotion_generator_sha256']:
        raise ValueError('Promotion generator proof changed')
    if runner.inventory(root / 'source-1') != info['promotion_instrumented_sha256']:
        raise ValueError('Prepared source inventory changed')
    if runner.archive_inventory(info['promotion_source_head']) != info['promotion_original_sha256']:
        raise ValueError('Original source inventory disagrees with recorded Git object')


def stats(values):
    ordered = sorted(values)
    return dict(n=len(values), p50_ms=statistics.median(values) / 1e6,
                p95_ms=ordered[math.ceil(len(values) * .95) - 1] / 1e6,
                max_ms=max(values) / 1e6)


def summarize(root, repetitions=3):
    root = root.resolve()
    if type(repetitions) is not int or repetitions < 1:
        raise ValueError('Positive repetitions required')
    info = runner.load(root / 'setup-1.json')
    check_evidence(root, info)
    check_phase_proof(root, 'run', repetitions)
    check_phase_proof(root, 'verify', 1)
    # 부모는 실제 실행 순서·성공 상태·전체 모집단과 제품의 독립 대조까지 검사한다.
    previous = parent.summarize(root, repetitions)
    groups = {}
    for prefix, count in (('run', repetitions), ('verify', 1)):
        for filename in runner.NAMES:
            for workload in ('typing', 'shared'):
                for rep in range(count):
                    records = rows((root / f'{prefix}-{rep}-1-{filename}-{workload}.log').read_text(),
                                   workload, info)
                    if prefix == 'run':
                        groups.setdefault(filename + '/' + workload, []).extend(records)
    return dict(parent=previous, target=runner.TARGET, source_head=info['promotion_source_head'],
                inputs=info['promotion_inputs'],
                promotion={name: {stage: stats([row[stage] for row in values]) for stage in runner.STAGES}
                           for name, values in groups.items()},
                work={name: dict(samples=len(values), min_spans=min(row['spans'] for row in values),
                                 max_spans=max(row['spans'] for row in values))
                      for name, values in groups.items()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    print(json.dumps(summarize(args.root, args.repetitions), indent=2))


if __name__ == '__main__':
    main()
