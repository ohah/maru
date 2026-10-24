#!/usr/bin/env python3
"""순차 머리 조회의 경계·고아 상태·건너뛰기 결함을 사본에서 주입한다."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output.exists() or output == repo or repo in output.parents:
        parser.error('Use a new directory outside the repository')
    output.mkdir(parents=True)
    original = (repo / 'src/session/editor/fold.zig').read_text()
    cases = [
        ('range-boundary', 'self.ranges[self.range_index].head < line', 'self.ranges[self.range_index].head <= line'),
        ('folded-boundary', 'self.folded[self.folded_index] < line', 'self.folded[self.folded_index] <= line'),
        ('orphan-head', 'if (self.range_index == self.ranges.len or self.ranges[self.range_index].head != line) return .none;', 'if (false) return .none;'),
        ('skipped-rows', 'while (self.range_index < self.ranges.len and self.ranges[self.range_index].head < line)', 'if (self.range_index < self.ranges.len and self.ranges[self.range_index].head < line)'),
        ('open-head', 'return if (self.folded_index < self.folded.len and self.folded[self.folded_index] == line) .collapsed else .open;', 'return if (self.folded_index < self.folded.len and self.folded[self.folded_index] == line) .collapsed else .none;'),
    ]

    def run(name, text):
        source = output / (name + '.zig')
        source.write_text(text)
        result = subprocess.run(['mise', 'exec', '--', 'zig', 'test', str(source), '--test-filter', 'fold marks cursor'], cwd=repo, capture_output=True, text=True, timeout=120)
        log = result.stdout + result.stderr
        (output / (name + '.log')).write_text(log)
        return result.returncode, log

    code, log = run('control-before', original)
    if code or 'All 5 tests passed.' not in log:
        raise RuntimeError('Original control failed')
    results = []
    for name, old, new in cases:
        if original.count(old) != 1:
            raise RuntimeError('Nonunique mutation anchor: ' + name)
        mutated = original.replace(old, new)
        code, log = run(name, mutated)
        if not code or 'FAIL (' not in log:
            raise RuntimeError('Mutation survived or failed before runtime: ' + name)
        results.append(dict(hypothesis=name, result='runtime-detected', original_sha256=hashlib.sha256(original.encode()).hexdigest(), mutated_sha256=hashlib.sha256(mutated.encode()).hexdigest()))
    code, log = run('control-after', original)
    if code or 'All 5 tests passed.' not in log:
        raise RuntimeError('Final control failed')
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(output / 'results.json')


if __name__ == '__main__':
    main()
