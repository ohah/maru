#!/usr/bin/env python3
"""변경 범위 재사용의 소비·교체·구조·실제 편집 계약을 독립 공격한다."""
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
    paths = {name: source / ('src/syntax/' + name + '.zig') for name in ('folds', 'tree_sitter')}
    originals = {name: path.read_text() for name, path in paths.items()}
    cases = [
        ('reuse-disabled', 'tree_sitter', 'if (self.fold_changes_before) |before_gen|', 'if (@as(?u64, null)) |before_gen|'),
        ('consumer-invalidates', 'tree_sitter', 'pub fn takeChanged(self: *Provider, out: *[max_changed]ByteRange) ?[]const ByteRange {', 'pub fn takeChanged(self: *Provider, out: *[max_changed]ByteRange) ?[]const ByteRange {\n        self.fold_changes_before = null;'),
        ('replace-authority', 'tree_sitter', 'self.changed_all = true;\n        self.fold_changes_before = null;\n        if (source.len', 'self.changed_all = true;\n        if (source.len'),
        ('structural-ranges', 'tree_sitter', 'self.fold_changes[k] = .{ .lo = ranges[k].start_byte, .hi = ranges[k].end_byte }', 'self.fold_changes[k] = .{ .lo = 0, .hi = 0 }'),
        ('actual-dirty-range', 'folds', 'for (0..range_count + 1) |i|', 'for (0..range_count) |i|'),
    ]

    def run(label):
        with (output / (label + '.log')).open('w') as log:
            code = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-fold-changes', 'test-editor-fold-cache', '-j2'], cwd=source, stdout=log, stderr=subprocess.STDOUT, timeout=300).returncode
        return code, (output / (label + '.log')).read_text()

    code, log = run('control-before')
    if code or 'All 6 tests passed.' not in log or 'All 9 tests passed.' not in log:
        raise RuntimeError('Original control failed')
    results = []
    try:
        for name, module, old, new in cases:
            path = paths[module]
            original = originals[module]
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
        for module, path in paths.items():
            path.write_text(originals[module])
    code, log = run('control-after')
    if code or 'All 6 tests passed.' not in log or 'All 9 tests passed.' not in log:
        raise RuntimeError('Restored control failed')
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(output / 'results.json')


if __name__ == '__main__':
    main()
