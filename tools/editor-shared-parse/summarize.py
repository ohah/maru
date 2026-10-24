#!/usr/bin/env python3
"""전후 실행 순서와 원본 증거를 검증하고 개별 분포를 보존한다."""
import argparse
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('provider_summary', ROOT/'tools/editor-provider-measure/summarize.py')
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)


def summarize(root, repetitions):
    result = {}
    inputs = None
    for variant, execution in (('baseline', 'per-view-native'), ('cursor', 'revision-snapshots')):
        folder = root/variant
        info = provider.load(folder/'setup-1.json')
        if info.get('provider_schema') != 2 or info.get('provider_execution') != execution:
            raise ValueError('Wrong execution model: '+variant)
        if info.get('shared_parse_variant') != ('predecessor' if variant == 'baseline' else execution):
            raise ValueError('Wrong comparison variant')
        current = provider.load(folder/'inputs.json')
        if inputs is not None and inputs != current:
            raise ValueError('Different comparison fixtures')
        inputs = current
        if variant == 'baseline':
            legacy = info.get('legacy_sha256', {})
            if not info.get('legacy_commit') or len(legacy) != 6:
                raise ValueError('Missing predecessor provenance')
            if any(info['original_sha256'].get(name) != value for name, value in legacy.items()):
                raise ValueError('Predecessor originals disagree')
        result[variant] = provider.summarize(folder, repetitions)
    for prefix, count, oracle in (('run', repetitions, 0), ('verify', 1, 1)):
        expected = []
        for rep in range(count):
            for file_index, file in enumerate(sorted(inputs)):
                for work_index, work in enumerate(('typing', 'shared')):
                    variants = ['baseline', 'cursor']
                    if (rep+file_index+work_index) % 2:
                        variants.reverse()
                    expected.extend((rep, file, work, variant) for variant in variants)
        rows = provider.load(root/(prefix+'-order.json'))
        actual = [(x['repetition'], x['file'], x['workload'], x['variant']) for x in rows]
        if actual != expected:
            raise ValueError('Wrong alternating execution order')
        for x in rows:
            log = root/x['variant']/f"{prefix}-{x['repetition']}-1-{x['file']}-{x['workload']}.log"
            if Path(x['log']).resolve() != log.resolve() or x['verify_each_edit'] != oracle:
                raise ValueError('Wrong execution receipt')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    result = summarize(args.root.resolve(), args.repetitions)
    (args.root/'summary.json').write_text(json.dumps(result, indent=2)+'\n')
    for variant, values in result.items():
        print(variant)
        print(provider.render(values))


if __name__ == '__main__':
    main()
