#!/usr/bin/env python3
"""경로 점유를 실제 worker로 대조한다. 0=계약 충족, 1=결함, 2=검증 불완전.

알려진 별칭 결함 때문에 기본 CI에 넣지 않은 opt-in 진단이다. inode만 같은
독립 hardlink나 서로 다른 symlink 논리 경로를 합치는 오수정도 대조군으로 잡는다.
"""
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--rg', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=args.output)).resolve()
    worker, rg = args.worker.resolve(), args.rg.resolve()
    cases, skipped = [], []
    report = {
        'status': 'running', 'cases': cases, 'skipped': skipped,
        'worker_sha256': hashlib.sha256(worker.read_bytes()).hexdigest(),
        'rg_sha256': hashlib.sha256(rg.read_bytes()).hexdigest(),
    }

    def root(name):
        directory = output / name
        directory.mkdir()
        return directory

    def same_file(left, right):
        left_stat, right_stat = left.stat(), right.stat()
        return (left_stat.st_dev, left_stat.st_ino) == (right_stat.st_dev, right_stat.st_ino)

    def run(name, directory, model, desired, flags=(), same_inode=None, query="foo", content="unsaved-body", expected_failure=None):
        result = subprocess.run(
            [str(worker), str(rg), str(directory), query, '-1', '4096',
             '--model', model, content, *flags],
            capture_output=True, timeout=15,
        )
        (output / (name + '.stdout')).write_bytes(result.stdout)
        (output / (name + '.stderr')).write_bytes(result.stderr)
        if result.returncode != 0:
            raise RuntimeError((name, 'worker execution failed', result.returncode))
        lines = [json.loads(line) for line in result.stdout.splitlines()]
        summary, rows = lines[-1], lines[:-1]
        if expected_failure is not None:
            if summary['failure'] != expected_failure or summary['status'] != 'failed' or summary['stats']['child_pid'] is not None:
                raise RuntimeError((name, 'lookup failure did not stop search', summary))
        elif summary['failure'] is not None or summary['status'] not in ('complete', 'partial'):
            raise RuntimeError((name, 'unexpected worker failure', summary))
        if sum(len(row['ranges']) for row in rows) != summary['matches']:
            raise RuntimeError((name, 'row/count mismatch'))
        if '--snapshot-bytes' in flags:
            if summary['status'] != 'partial' or summary['excluded'] != 1:
                raise RuntimeError((name, 'snapshot exclusion not exercised'))
        elif expected_failure is None and (summary['status'] != 'complete' or summary['excluded'] != 0):
            raise RuntimeError((name, 'unexpected partial result'))
        pid = summary['stats']['child_pid']
        if pid is not None:
            if not summary['stats']['reaped']:
                raise RuntimeError((name, 'helper not reaped'))
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise RuntimeError((name, 'helper still alive'))
        cases.append({
            'name': name, 'desired_matches': desired,
            'observed_matches': summary['matches'],
            'contract_pass': summary['matches'] == desired,
            'status': summary['status'], 'excluded': summary['excluded'],
            'paths': [row['path'] for row in rows], 'same_inode': same_inode,
        })

    def alias_exists(name, actual, alias):
        if not alias.exists() or not same_file(actual, alias):
            skipped.append({'name': name, 'reason': 'filesystem distinguishes these paths'})
            return False
        return True

    try:
        directory = root('exact')
        (directory / 'file.txt').write_text('foo\n')
        run('exact-path-control', directory, 'file.txt', 0)
        run('exact-budget-control', directory, 'file.txt', 0, ('--snapshot-bytes', '0'))
        for label, actual, alias in [('case-parent', 'Folder', 'folder'),
                                     ('unicode-parent', '\u00e9', 'e\u0301')]:
            directory = root(label)
            (directory / actual).mkdir()
            (directory / actual / 'file.txt').write_text('foo\n')
            if not alias_exists(label, directory / actual / 'file.txt', directory / alias / 'file.txt'):
                continue
            run(label, directory, alias + '/file.txt', 0, same_inode=True)
            run(label + '-budget', directory, alias + '/file.txt', 0, ('--snapshot-bytes', '0'), True)
            run(label + '-glob', directory, alias + '/file.txt', 0, ('--include', actual + '/**'), True)
            run(label + '-model-glob', directory, alias + '/file.txt', 1,
                ('--include', actual + '/**'), True, query="editor-only", content="editor-only")
            run(label + '-missing-leaf', directory, alias + '/new.txt', 1,
                ('--include', actual + '/**'), query="editor-only", content="editor-only")

        directory = root('link')
        (directory / 'target.txt').write_text('foo\n')
        (directory / 'Link.txt').symlink_to(directory / 'target.txt')
        run('logical-symlink-control', directory, 'Link.txt', 1)
        if alias_exists('symlink-case-alias', directory / 'Link.txt', directory / 'link.txt'):
            run('symlink-case-alias', directory, 'link.txt', 1, same_inode=True)

        directory, external = root('outside-link'), root('external')
        (external / 'target.txt').write_text('foo\n')
        (directory / 'Outside.txt').symlink_to(external / 'target.txt')
        run('outside-symlink-control', directory, 'Outside.txt', 0)
        if alias_exists('outside-symlink-case-alias', directory / 'Outside.txt', directory / 'outside.txt'):
            run('outside-symlink-case-alias', directory, 'outside.txt', 0, same_inode=True)

        directory = root('outside-dir-link')
        (directory / 'LinkDir').symlink_to(external, target_is_directory=True)
        run('outside-directory-control', directory, 'LinkDir/target.txt', 0)
        if alias_exists('outside-directory-case-alias', directory / 'LinkDir/target.txt', directory / 'linkdir/target.txt'):
            run('outside-directory-case-alias', directory, 'linkdir/target.txt', 0, same_inode=True)

        directory = root('hardlink')
        (directory / 'Original.txt').write_text('foo\n')
        os.link(directory / 'Original.txt', directory / 'Other.txt')
        run('independent-hardlink-control', directory, 'Other.txt', 1,
            same_inode=same_file(directory / 'Original.txt', directory / 'Other.txt'))
        (directory / 'Other.txt').unlink()
        (directory / 'Other.txt').write_text('foo\n')
        run('hardlink-after-replacement-control', directory, 'Other.txt', 1,
            same_inode=same_file(directory / 'Original.txt', directory / 'Other.txt'))
        directory = root('lookup-denied')
        denied = directory / 'Denied'
        denied.mkdir()
        (denied / 'file.txt').write_text('foo\n')
        if os.geteuid() == 0:
            skipped.append({'name': 'lookup-denied', 'reason': 'root bypasses directory mode bits'})
        else:
            denied.chmod(0)
            try:
                run('lookup-denied', directory, 'Denied/file.txt', 0,
                    expected_failure='PathSpellingUnavailable')
            finally:
                denied.chmod(0o700)
        report['defects'] = [case['name'] for case in cases if not case['contract_pass']]
        report['status'] = 'contract-defects' if report['defects'] else 'incomplete' if skipped else 'passed'
    except Exception as error:
        report['status'], report['error'] = 'incomplete', str(error)
    finally:
        encoded = json.dumps(report, ensure_ascii=False, indent=2)
        (output / 'report.json').write_text(encoded)
        (args.output / 'latest.json').write_text(encoded)
        print(output / 'report.json')
    return 1 if report['status'] == 'contract-defects' else 0 if report['status'] == 'passed' else 2


if __name__ == '__main__':
    raise SystemExit(main())
