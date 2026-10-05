#!/usr/bin/env python3
"""실제 독립 WKWebView와 대상 뷰 보유 대조군으로 자원 귀속·회수 gate를 검증한다."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def execute(command, environment, timeout=120):
    process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    return process.returncode, stdout, stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--assets', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    assets = args.assets.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run-', dir=output))
    environment = {**os.environ, 'MARU_WEB_APP_ROOT': str(assets), 'MARU_EDITOR_SMOKE_DISPLAY': '0'}
    environment.pop('MARU_EDITOR_RESOURCE_SCENARIO', None)
    environment.pop('MARU_EDITOR_RESOURCE_READY', None)
    report = {'status': 'running', 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'cases': [], 'limits': '실제 합성 WKWebView의 귀속·회수 검사. 과거 CI 잔존 PID의 소유자를 소급 증명하지 않는다.'}

    def save():
        (run / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        (output / 'latest.json').write_text(json.dumps({'run': run.name, **report}, indent=2) + '\n')

    save()
    try:
        code, stdout, stderr = execute([str(binary), '--resource-unit-test'], environment)
        (run / 'unit.stdout').write_bytes(stdout)
        (run / 'unit.stderr').write_bytes(stderr)
        assert code == 0 and b'PID reuse excluded' in stdout, (code, stderr)
        report['unit'] = 'foreign identity, reused PID, unavailable getter and invalid CPU tested'

        for scenario in ['none', 'before', 'during', 'late', 'transient', 'own-retained']:
            root = run / scenario
            root.mkdir()
            home = root / 'home'
            home.mkdir()
            env = {**environment, 'HOME': str(home), 'MARU_EDITOR_SMOKE_OUT': str(root),
                   'MARU_EDITOR_RESOURCE_SCENARIO': scenario}
            code, stdout, stderr = execute([str(binary)], env)
            (root / 'stdout').write_bytes(stdout)
            (root / 'stderr').write_bytes(stderr)
            summary = dict(line.split('=', 1) for line in (root / 'editor.summary.txt').read_text().splitlines())
            assert 'resource_measure_error' not in summary, (scenario, summary)
            expected_exit = 1 if scenario == 'own-retained' else 0
            assert code == expected_exit, (scenario, code, stderr)
            identities = set()
            for count in [1, 2, 4]:
                own = summary[f'owned_processes_{count}_view'].split(',')
                assert len(own) == int(summary[f'webcontent_processes_{count}_view']) > 0
                assert int(summary[f'rss_{count}_view_kb']) > 0
                identities.update(own)
            if scenario == 'own-retained':
                assert summary['webcontent_processes_after_close'] == '1'
                assert summary['reclaim_seconds_1_view'] == 'timeout'
                assert b'owned web content reclaim timed out' in stderr
                assert summary['remaining_owned_processes'] in identities
            else:
                assert summary['webcontent_processes_after_close'] == '0'
                assert summary['remaining_owned_processes'] == ''
                assert all(summary[f'reclaim_seconds_{count}_view'] != 'timeout' for count in [1, 2, 4])
            if scenario not in ['none', 'own-retained']:
                assert summary['foreign_in_owned'] == 'false'
                assert summary['foreign_process'] not in identities
                if scenario != 'transient':
                    assert summary['foreign_alive_before_cleanup'] == 'true'
                # helper 자체가 끝났다는 사실만으로 WebContent까지 회수됐다고 주장하지 않는다.
                deadline = time.monotonic() + 5
                while True:
                    probe, alive, error = execute([str(binary), '--resource-identity-check', summary['foreign_process']], env, 10)
                    assert probe == 0, error
                    if alive.strip() == b'gone':
                        break
                    assert alive.strip() == b'alive' and time.monotonic() < deadline, (scenario, alive)
                    time.sleep(0.1)
            report['cases'].append({'scenario': scenario, 'exit': code, 'summary': summary,
                                    'foreign_excluded': scenario not in ['none', 'own-retained']})
            save()
            print(f'webcontent attribution: {scenario} verified', flush=True)
        report['status'] = 'passed'
        save()
        print(f'webcontent attribution ok: {run}', flush=True)
    except BaseException as error:
        report['status'] = 'failed'
        report['error'] = repr(error)
        save()
        raise


if __name__ == '__main__':
    main()
