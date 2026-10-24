#!/usr/bin/env python3
"""동일 도구의 전후 원본·실제 교차 순서·C 호출·전체 분포를 대조한다."""
import argparse
import importlib.util
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pane_summary', ROOT/'tools/editor-pane-measure/summarize.py')
pane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pane)
REPLACED = {'src/syntax/tree_sitter.zig', 'src/syntax/folds.zig', 'src/syntax/symbols.zig', 'build.zig'}


def summarize(root, repetitions=3):
    root = root.resolve()
    results = {}
    inputs = None
    for variant, execution in (('baseline', 'own-comparison'), ('cursor', 'retained-ranges')):
        folder = root/variant
        info = pane.provider.load(folder/'setup-1.json')
        if type(info.get('pane_schema')) is not int or info['pane_schema'] != 3 or info.get('pane_summary_execution') != execution:
            raise ValueError('Wrong pane execution model')
        if info.get('sticky_changes_variant') != ('predecessor' if variant == 'baseline' else 'retained-ranges'):
            raise ValueError('Wrong sticky comparison variant')
        if variant == 'baseline':
            commit = info.get('legacy_commit')
            if not isinstance(commit, str) or re.fullmatch('[0-9a-f]{40}', commit) is None or not isinstance(info.get('legacy_sha256'), dict) or set(info['legacy_sha256']) != REPLACED:
                raise ValueError('Missing predecessor source provenance')
            if any(info['original_sha256'].get(name) != digest for name, digest in info['legacy_sha256'].items()):
                raise ValueError('Predecessor originals disagree')
        current = pane.provider.load(folder/'inputs.json')
        if inputs is not None and inputs != current:
            raise ValueError('Different comparison fixtures')
        inputs = current
        results[variant] = pane.summarize(folder, repetitions)
    for prefix, count, oracle in (('run', repetitions, 0), ('verify', 1, 1)):
        expected = []
        for rep in range(count):
            for file_index, file in enumerate(sorted(inputs)):
                for work_index, work in enumerate(('typing', 'shared')):
                    variants = ['baseline', 'cursor']
                    if (rep+file_index+work_index) % 2:
                        variants.reverse()
                    expected.extend((rep, file, work, variant) for variant in variants)
        rows = pane.provider.load(root/(prefix+'-order.json'))
        if [(x['repetition'], x['file'], x['workload'], x['variant']) for x in rows] != expected:
            raise ValueError('Wrong alternating execution order')
        for row in rows:
            log = root/row['variant']/f"{prefix}-{row['repetition']}-1-{row['file']}-{row['workload']}.log"
            if type(row['repetition']) is not int or Path(row['log']).resolve() != log or type(row.get('returncode')) is not int or row['returncode'] != 0 or type(row['verify_each_edit']) is not int or row['verify_each_edit'] != oracle:
                raise ValueError('Wrong paired execution receipt')
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    result = summarize(args.root, args.repetitions)
    (args.root/'summary.json').write_text(json.dumps(result, indent=2)+'\n')
    for name, before in result['baseline']['pane'].items():
        after = result['cursor']['pane'][name]
        print(name, 'whole_p50', result['baseline']['provider'][name]['total_ns']['p50'], result['cursor']['provider'][name]['total_ns']['p50'], 'sticky_p50', before['sticky']['p50'], after['sticky']['p50'])


if __name__ == '__main__':
    main()
