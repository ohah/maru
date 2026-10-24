#!/usr/bin/env python3
"""근처 행 조회의 경계·fallback·열·작업 상한·힌트 갱신을 독립 공격한다."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--deps', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output.exists() or output == repo or repo in output.parents:
        parser.error('Use a new external directory')
    source = output / 'source'
    source.mkdir(parents=True)
    subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=zig-pkg', '--exclude=references', '--exclude=.env*', str(repo) + '/', str(source) + '/'], check=True)
    (source / 'zig-pkg').symlink_to(args.deps.resolve(), target_is_directory=True)
    path = source / 'src/syntax/folds.zig'
    original = path.read_text()
    cases = [
        ('line-boundary', 'lines[row + 1].start > offset', 'lines[row + 1].start >= offset'),
        ('fallback-coordinate', 'const value = point(lines, offset);', 'const value = pointAtRow(lines, offset, 0);'),
        ('column-coordinate', '.column = @intCast(offset - lines[row].start)', '.column = @intCast(offset - lines[0].start)'),
        ('bounded-forward-search', 'steps < 8', 'steps < 128'),
        ('hint-refresh', 'hint.* = row;', 'hint.* = 0;'),
    ]

    def run(label):
        with (output / (label + '.log')).open('w') as log:
            code = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-fold-points', '-j2'], cwd=source, stdout=log, stderr=subprocess.STDOUT, timeout=300).returncode
        return code, (output / (label + '.log')).read_text()

    code, log = run('control-before')
    if code or 'All 6 tests passed.' not in log:
        raise RuntimeError('Original control failed')
    results = []
    try:
        for name, old, new in cases:
            if original.count(old) != 1:
                raise RuntimeError('Nonunique mutation anchor: ' + name)
            mutated = original.replace(old, new)
            path.write_text(mutated)
            code, log = run(name)
            if not code or 'FAIL (' not in log:
                raise RuntimeError('Mutation survived or did not reach runtime: ' + name)
            results.append(dict(hypothesis=name, result='runtime-detected', original_sha256=hashlib.sha256(original.encode()).hexdigest(), mutated_sha256=hashlib.sha256(mutated.encode()).hexdigest()))
            path.write_text(original)
    finally:
        path.write_text(original)
    code, log = run('control-after')
    if code or 'All 6 tests passed.' not in log:
        raise RuntimeError('Restored control failed')
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(output / 'results.json')


if __name__ == '__main__':
    main()
