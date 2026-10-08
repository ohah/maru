#!/usr/bin/env python3
"""실제 여러-root worker의 후보 합집합·전역 예산·수명을 독립 판정한다."""
import argparse
import json
import hashlib
import resource
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
    out = Path(tempfile.mkdtemp(prefix='run-', dir=args.output)).resolve()
    worker, rg = args.worker.resolve(), args.rg.resolve()
    records = []
    report = {'status': 'running', 'cases': records, 'worker_sha256': hashlib.sha256(worker.read_bytes()).hexdigest(), 'rg_sha256': hashlib.sha256(rg.read_bytes()).hexdigest()}

    def run(name, roots, query='foo', flags=(), cancel=-1, helper=None, fd_limit=None):
        command = [str(helper or rg), str(roots[0]), query, str(cancel), '1048576']
        for root in roots[1:]:
            command += ['--workspace-root', str(root)]
        def limit():
            resource.setrlimit(resource.RLIMIT_NOFILE, (fd_limit, fd_limit))
        result = subprocess.run([str(worker), *command, *flags], capture_output=True, timeout=15, preexec_fn=limit if fd_limit else None)
        (out / (name + '.stdout')).write_bytes(result.stdout)
        (out / (name + '.stderr')).write_bytes(result.stderr)
        if result.returncode:
            raise RuntimeError((name, result.returncode, result.stderr.decode(errors='replace')))
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        summary = rows.pop()
        if summary['matches'] != sum(len(row['ranges']) for row in rows):
            raise RuntimeError((name, 'count mismatch', summary, rows))
        pid = summary['stats']['child_pid']
        if pid is not None:
            if not summary['stats']['reaped']:
                raise RuntimeError((name, 'helper not reaped'))
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise RuntimeError((name, 'helper remains'))
        records.append({'name': name, 'summary': summary, 'rows': rows})
        return rows, summary

    try:
        parent, other = out / 'parent', out / 'other'
        parent.mkdir(); other.mkdir()
        child = parent / 'sub'; child.mkdir()
        (parent / 'top.txt').write_text('foo')
        (child / 'child.txt').write_text('foo')
        (other / 'other.txt').write_text('foo')
        (parent / '.ignore').write_text('sub/\n')
        rows, summary = run('ignore-union', [parent, child])
        assert summary['status'] == 'complete' and summary['matches'] == 2
        assert [(r['path'], r['root_index']) for r in rows] == [('top.txt', 0), ('child.txt', 1)]
        (parent / '.ignore').unlink()
        rows, summary = run('overlap-first-root', [parent, child, parent])
        assert summary['matches'] == 2 and all(r['root_index'] == 0 for r in rows)
        rows, summary = run('reverse-root-order', [child, parent])
        assert summary['matches'] == 2
        assert any(r['path'] == 'child.txt' and r['root_index'] == 0 for r in rows)
        rows, summary = run('root-relative-glob-union', [parent, child], flags=['--include', '*.txt'])
        assert summary['matches'] == 2 and any(r['root_index'] == 1 for r in rows)
        rows, summary = run('global-match-limit', [parent, other], flags=['--matches', '1'])
        assert summary['status'] == 'partial' and summary['matches'] <= 1 and summary['failure'] is None
        rows, summary = run('global-zero-match-limit', [parent, other], flags=['--matches', '0'])
        assert summary['status'] == 'partial' and not rows
        rows, summary = run('candidate-budget', [parent, other], flags=['--selection-bytes', '1'])
        assert summary['status'] == 'partial' and not rows and summary['failure'] is None
        model = str(child / 'child.txt')[1:]
        rows, summary = run('zero-model-overrides-all-roots', [parent, child], flags=['--model', model, 'absent'])
        assert summary['matches'] == 1 and all(not r['path'].endswith('child.txt') for r in rows)
        rows, summary = run('excluded-model-overrides-all-roots', [parent, child], flags=['--snapshot-bytes', '0', '--model', model, 'foo'])
        assert summary['matches'] == 1 and summary['excluded'] == 1 and summary['status'] == 'partial'
        rows, summary = run('independent-models', [parent, child], flags=['--model', model, 'foo', '--model', model, 'foo'])
        assert summary['matches'] == 3 and sum('model' in r['source'] for r in rows) == 2
        rows, summary = run('pre-cancel', [parent, child], cancel=0)
        assert summary['status'] == 'cancelled' and not rows and summary['stats']['child_pid'] is None
        name = '한글😀\n--.txt'; (child / name).write_text('foo')
        rows, summary = run('newline-unicode-filename', [child, other])
        assert summary['matches'] == 3 and any(r['path'] == name for r in rows)

        (child / 'regex.txt').write_bytes(b'foo\r\nbar')
        (other / 'regex.txt').write_text('foo\nbar')
        rows, summary = run('multiline-regex-roots', [child, other], query=r'foo\r?\nbar', flags=['--regex'])
        assert summary['status'] == 'complete' and summary['matches'] == 2
        assert all(r['ranges'][0]['end'] == {'line': 1, 'byte': 3} for r in rows)
        regex_model = str(child / 'regex.txt')[1:]
        rows, summary = run('multiline-regex-model-priority', [child, other], query=r'foo\r?\nbar', flags=['--regex', '--model', regex_model, 'foo\nbar'])
        assert summary['matches'] == 2 and sum('model' in r['source'] for r in rows) == 1
        (child / 'regex.txt').unlink(); (other / 'regex.txt').unlink()
        # hardlink·symlink는 inode가 같아도 별도 논리 경로다.
        os.link(other / 'other.txt', other / 'hard.txt')
        (other / 'link.txt').symlink_to(other / 'other.txt')
        rows, summary = run('distinct-link-paths', [parent, other])
        assert summary['matches'] == 6 and {'other.txt', 'hard.txt', 'link.txt'} <= {r['path'] for r in rows}
        # helper가 받은 명시적 파일 인수로 0건 파일도 한 번만 읽도록 선정했는지 확인한다.
        trace = out / 'helper-argv.jsonl'
        wrapper = out / 'trace-helper'
        wrapper.write_text('#!/usr/bin/python3\nimport os,sys,json\nwith open(' + repr(str(trace)) + ',"a") as f: f.write(json.dumps({"cwd":os.getcwd(),"args":sys.argv[1:]})+"\\n")\nos.execv(' + repr(str(rg)) + ',[' + repr(str(rg)) + ']+sys.argv[1:])\n')
        wrapper.chmod(0o755)
        rows, summary = run('zero-hit-searched-once', [parent, child, parent], query='absent-query', helper=wrapper)
        assert summary['status'] == 'complete' and not rows
        searched = []
        for entry in map(json.loads, trace.read_text().splitlines()):
            argv = entry['args']
            if '--files' not in argv:
                searched += [str(Path(entry['cwd']) / p) for p in argv[argv.index('--') + 1:]]
        assert len(searched) == 3 and len(set(searched)) == 3, searched
        # 실행 시간 예산은 root/helper마다 다시 시작하지 않는다.
        slow = out / 'slow-helper'
        slow.write_text('#!/usr/bin/python3\nimport time\ntime.sleep(5)\n'); slow.chmod(0o755)
        # 20ms는 CI의 root 메타데이터 검증만으로 소진될 수 있다. 시작된 helper 수거는 별도로 검증한다.
        rows, summary = run('deadline-reaps-first-helper', [parent, other], flags=['--execution-ms', '1000'], helper=slow)
        assert summary['status'] == 'partial' and not rows and summary['stats']['children_started'] == 1

        rogue = out / 'rogue-helper'
        event = {'type': 'match', 'data': {'path': {'text': 'unselected.txt'}, 'lines': {'text': 'foo'}, 'line_number': 1, 'submatches': [{'start': 0, 'end': 3, 'match': {'text': 'foo'}}]}}
        rogue.write_text('#!/usr/bin/python3\nimport sys,json,time\nif "--files" in sys.argv: sys.stdout.buffer.write(b"top.txt\\0")\nelse:\n print(' + repr(json.dumps(event)) + ',flush=True)\n time.sleep(5)\n')
        rogue.chmod(0o755)
        rows, summary = run('unselected-result-rejected', [parent, other], helper=rogue)
        assert summary['status'] == 'failed' and summary['failure'] == 'UnselectedPath' and not rows

        many = []
        for i in range(64):
            directory = out / ('fd-root-' + str(i)); directory.mkdir()
            (directory / 'a.txt').write_text('foo')
            many.append(directory)
        rows, summary = run('root-count-exceeds-fd-limit', many, fd_limit=64)
        assert summary['status'] == 'complete' and summary['matches'] == 64 and {r['root_index'] for r in rows} == set(range(64))
        rows, summary = run('deadline-before-helper-start', many, flags=['--execution-ms', '1'])
        assert summary['status'] == 'partial' and not rows and summary['stats']['children_started'] == 0 and summary['stats']['child_pid'] is None
        report['status'] = 'passed'
    except Exception as error:
        report['status'], report['error'] = 'failed', repr(error)
        raise
    finally:
        (out / 'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        (args.output / 'latest.json').write_text(json.dumps({'status': report['status'], 'report': str(out / 'verification.json')}))
        print(out / 'verification.json')


if __name__ == '__main__':
    main()
