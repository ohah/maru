#!/usr/bin/env python3
"""입력/색 표시 시각을 분해한다. worker CPU 시간으로 이름을 바꾸지 않는다."""
import argparse
import json
import pathlib
import statistics
import compare
import verify

FIELDS = ('post_to_native_ms', 'native_to_first_ms', 'first_to_syntax_ms', 'syntax_to_full_ms', 'post_to_full_ms')


def run_stages(value, run, events):
    verify.require(type(events) is int and events > 5, 'not enough post-warmup events')
    verify.validate(value, run, events)
    t = value['rows'][-1]['timing']
    verify.require((t[7] != t[8] or t[5] == t[6]) and (t[8] != t[10] or t[6] == t[9]), 'one frame contradictory presentation times')
    parts = [t[3]-t[1], t[5]-t[3], t[6]-t[5], t[9]-t[6]]
    verify.require(sum(parts) == t[9]-t[1], 'stage conservation')
    rows = value['rows'][5:]
    intervals = [(rows[i+1]['timing'][1]-rows[i]['timing'][1])/1e6 for i in range(len(rows)-1)]
    return {'run': run['path'], **dict(zip(FIELDS, [x/1e6 for x in parts]+[(t[9]-t[1])/1e6])),
            'syntax_to_full_generations': t[10]-t[8], 'gap_samples': len(rows)-1,
            'syntax_observed_in_gap': sum(r['timing'][6] > 0 for r in rows[:-1]),
            'full_observed_in_gap': sum(r['timing'][9] > 0 for r in rows[:-1]),
            'post_spacing_ms': {'median': statistics.median(intervals), 'min': min(intervals), 'max': max(intervals)} if intervals else None}


def aggregate(runs):
    return {'per_process': runs, 'median': {k: statistics.median(r[k] for r in runs) for k in FIELDS},
            'syntax_to_full_generations': [r['syntax_to_full_generations'] for r in runs],
            'gap_samples': sum(r['gap_samples'] for r in runs),
            'syntax_observed_in_gap': sum(r['syntax_observed_in_gap'] for r in runs),
            'full_observed_in_gap': sum(r['full_observed_in_gap'] for r in runs),
            'median_process_post_spacing_ms': statistics.median(r['post_spacing_ms']['median'] for r in runs) if all(r['post_spacing_ms'] is not None for r in runs) else None}


def suite_stages(root):
    source = compare.collect(root)
    suite = json.loads((root/'suite.json').read_text())
    groups = {}
    for case, folder in sorted(suite['accepted'].items()):
        path = root/folder
        manifest = json.loads((path/'manifest.json').read_text())
        for r in manifest['runs']:
            value = json.loads((path/r['path']/'result.json').read_text())
            groups.setdefault(case+'-'+r['mode'], []).append(run_stages(value, r, manifest['events']))
    return {'schema': 1, 'method': 'last-input display envelopes; CPU attribution unavailable',
            'analyzers': {name: verify.sha(pathlib.Path(__file__).parent/name) for name in ['stages.py', 'verify.py', 'compare.py']},
            'source': {k: source[k] for k in ['head', 'app_sha256', 'host', 'events', 'repetitions', 'evidence', 'rejected', 'load_1m_range']},
            'groups': {k: aggregate(rs) for k, rs in groups.items()}}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('root', type=pathlib.Path)
    p.add_argument('--output', required=True, type=pathlib.Path)
    a = p.parse_args()
    if a.output.exists():
        p.error('new output required')
    a.output.write_text(json.dumps(suite_stages(a.root.resolve()), indent=2)+'\n')


if __name__ == '__main__':
    main()
