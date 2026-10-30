#!/usr/bin/env python3
"""원시 증거를 재검증한 두 suite만 같은 fixture·모집단으로 비교한다."""
import argparse
import json
import pathlib
import statistics
import verify


def collect(root):
    root = pathlib.Path(root).resolve()
    suite = json.loads((root / 'suite.json').read_text())
    expected = {str(size) + '-' + flow for size in [3000, 50000] for flow in ['typing', 'ime', 'shared']}
    verify.require(set(suite['accepted']) == expected, 'incomplete suite')
    groups, evidence, identities, loads, hosts = {}, [], set(), [], set()
    for case, relative in sorted(suite['accepted'].items()):
        path = (root / relative).resolve()
        verify.require(path.is_relative_to(root), 'suite path escape')
        summary = verify.verify(path)
        manifest = json.loads((path / 'manifest.json').read_text())
        size, flow = case.split('-')
        verify.require(manifest['sizes'] == [int(size)] and manifest['flows'] == [flow], 'case identity')
        verify.require(manifest['events'] == suite['events'] and manifest['repetitions'] == suite['repetitions'], 'population mismatch')
        identities.add((manifest['source']['head'], manifest['app_sha256']))
        hosts.add(json.dumps(manifest['host'], sort_keys=True))
        fingerprints = {r['fixture_sha256'] for r in manifest['runs']}
        verify.require(len(fingerprints) == 1, 'mixed fixture')
        for mode in ['sync', 'async']:
            runs = summary[str((int(size), flow, mode))]
            verify.require(len(runs) == suite['repetitions'], 'process population')
            groups[case + '-' + mode] = aggregate(runs, next(iter(fingerprints)))
        for run in manifest['runs']:
            loads.extend([run['load_before'][0], run['load_after'][0]])
        evidence.append({'case': case, 'manifest_sha256': verify.sha(path / 'manifest.json'),
                         'runs': [{'path': r['path'], 'result_sha256': r['result_sha256']} for r in manifest['runs']]})
    verify.require(len(identities) == 1, 'mixed suite build')
    verify.require(len(hosts) == 1, 'mixed suite host')
    head, binary = next(iter(identities))
    rejected = []
    for item in suite['rejected']:
        path = (root / item['path']).resolve()
        verify.require(path.is_relative_to(root), 'rejected path escape')
        manifest = json.loads((path / 'manifest.json').read_text())
        last = manifest['runs'][-1]
        receipt = (path / last['path'] / 'result.json').resolve()
        verify.require(receipt.is_relative_to(path), 'rejected receipt path escape')
        verify.require(verify.sha(receipt) == last['result_sha256'], 'rejected receipt drift')
        value = json.loads(receipt.read_text())
        rejected.append({**item, 'error': value['error'], 'result_sha256': last['result_sha256'],
                         'manifest_sha256': verify.sha(path / 'manifest.json'),
                         'failure_before': value.get('failure_before'), 'failure_state': value.get('failure_state')})
    return {'head': head, 'app_sha256': binary, 'events': suite['events'], 'repetitions': suite['repetitions'],
            'load_1m_range': [min(loads), max(loads)], 'groups': groups, 'evidence': evidence,
            'host': json.loads(next(iter(hosts))), 'rejected': rejected}


def aggregate(runs, fingerprint):
    last = [r['last_full_color_ms'] for r in runs]
    return {'fixture_sha256': fingerprint, 'processes': len(runs),
            'first_median_ms': statistics.median(r['post_to_present_ms']['median'] for r in runs),
            'first_p95_median_ms': statistics.median(r['post_to_present_ms']['p95'] for r in runs),
            'last_syntax_median_ms': statistics.median(r['last_syntax_ms'] for r in runs),
            'last_full_color_median_ms': statistics.median(last), 'last_full_color_range_ms': [min(last), max(last)],
            'peak_rss_median_mib': statistics.median(r['peak_rss_mib'] for r in runs),
            'gap_samples': sum(r['gap_samples'] for r in runs),
            'full_color_observed_in_gap': sum(r['full_color_observed_in_gap'] for r in runs)}


def matched(before, after):
    verify.require(before['host'] == after['host'], 'comparison host')
    verify.require((before['events'], before['repetitions']) == (after['events'], after['repetitions']), 'comparison population')
    verify.require(before['groups'].keys() == after['groups'].keys(), 'comparison cases')
    for case in before['groups']:
        verify.require(before['groups'][case]['fixture_sha256'] == after['groups'][case]['fixture_sha256'], 'comparison fixture')
    return {'schema': 1, 'method': 'median of process statistics; first five inputs excluded', 'before': before, 'after': after}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--before', required=True, type=pathlib.Path)
    p.add_argument('--after', required=True, type=pathlib.Path)
    p.add_argument('--output', required=True, type=pathlib.Path)
    a = p.parse_args()
    if a.output.exists():
        p.error('new output required')
    a.output.write_text(json.dumps(matched(collect(a.before), collect(a.after)), indent=2) + '\n')


if __name__ == '__main__':
    main()
