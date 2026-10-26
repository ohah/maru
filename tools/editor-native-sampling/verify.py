#!/usr/bin/env python3
"""기준 모집단과 별도 30개 프로파일을 원시 스택·제품 결과·보존 파일까지 대조한다."""
import argparse
from pathlib import Path

import evidence
import stacks
import symbols
import replay
from run import write


def verify(base, profiles, head):
    base, profiles = base.resolve(), profiles.resolve()
    evidence.require(base != profiles, 'Baseline and profiles must differ')
    proof = evidence.baseline(base, head)
    result = evidence.load(profiles / 'result.json')
    evidence.strict(result.get('schema'), 1, 'profile dataset schema')
    evidence.strict(result.get('processes'), 30, 'profile population')
    evidence.strict(result.get('inputs'), 600, 'profile input population')
    evidence.require(result.get('complete') is True and result.get('kind') == 'native-sampling'
                     and result.get('head') == head, 'Incomplete or wrong profile dataset')
    evidence.require(result.get('baseline_result_sha256') == evidence.sha(base / 'result.json')
                     and result.get('binary_sha256') == proof['binary_sha256'], 'Wrong linked baseline')
    uid = stacks.macho_uuid((base / 'archived-test').read_bytes())
    evidence.require(result.get('binary_uuid') == uid, 'Dataset executable UUID differs')
    evidence.checked_tools(profiles, result.get('producer_sha256'))
    evidence.native.digest(profiles / 'producer.json', result.get('producer_receipt_sha256'))
    producer = evidence.load(profiles / 'producer.json')
    evidence.strict(producer.get('schema'), 1, 'producer schema')
    evidence.require(producer.get('head') == head and producer.get('tools_sha256') == result['producer_sha256']
                     and producer.get('baseline_result_sha256') == result['baseline_result_sha256'], 'Producer receipt differs')
    evidence.strict(result.get('symbol_exit'), 0, 'symbol archive exit code')
    evidence.require(result.get('symbol_command') == symbols.bundle_command(profiles, base / 'archived-test'), 'Wrong symbol archive command')
    evidence.native.digest(profiles / 'symbols.log', result.get('symbol_log_sha256'))
    evidence.files(profiles / 'symbols.dSYM', result.get('symbols_sha256'))
    symbols.symbol_file(profiles, uid)
    wanted = {f'profile-{rep}-{filename}-{workload}': (rep, filename, workload)
              for rep in range(3) for filename in sorted(proof['inputs']) for workload in ('typing', 'shared')}
    evidence.require(set(result.get('runs_sha256', {})) == set(wanted), 'Missing or extra profile population')
    evidence.require({p.name for p in profiles.iterdir()} == set(wanted) | {'result.json', 'tool-snapshot', 'producer.json', 'symbols.dSYM', 'symbols.log'},
                     'Missing or extra profile directories')
    reports = {}
    for name, (rep, filename, workload) in wanted.items():
        evidence.native.digest(profiles / name / 'run.json', result['runs_sha256'][name])
        reports[name] = evidence.read_run(profiles / name, base, rep, filename, workload, proof['binary_sha256'], uid)
        folder = profiles / name
        files = evidence.load(folder / 'run.json')['files_sha256']
        reports[name]['trace_replay'] = replay.check(folder, (folder / 'toc.xml').read_text(),
            (folder / 'time-profile.xml').read_text(), str(base / 'archived-test'),
            evidence.environment(base, filename, workload),
            {path[len('profile.trace/'):]: digest for path, digest in files.items() if path.startswith('profile.trace/')})
    evidence.require(sum(x['profile']['counts']['native_rows'] for x in reports.values()) > 0, 'No native parser observations')
    return dict(complete=True, head=head, baseline_processes=40, profile_processes=30, profile_inputs=600,
                binary_sha256=proof['binary_sha256'], binary_uuid=uid, reports=reports,
                reader_sha256={name: evidence.sha(Path(__file__).with_name(name))
                               for name in ('verify.py', 'evidence.py', 'stacks.py', 'symbols.py', 'replay.py')},
                scope='Sample weights and recognized edit ancestry only; missing stacks retained; no speedup or actual node-reuse count')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--profiles', type=Path, required=True)
    parser.add_argument('--expected-head', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or output == evidence.ROOT or evidence.ROOT in output.parents:
        parser.error('Use a new receipt outside the repository')
    replay.configure(output.with_name(output.name + '.sdk-replays'))
    result = verify(args.baseline, args.profiles, args.expected_head)
    write(output, result)
    print('NATIVE_SAMPLING_VERIFIED_30_PROCESSES')


if __name__ == '__main__':
    main()
