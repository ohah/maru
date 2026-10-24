#!/usr/bin/env python3
"""공유 뷰 스냅샷의 준비·언어·세대·결합·해제를 독립 공격한다."""
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
    paths = {
        'folds': source / 'src/syntax/folds.zig',
        'provider': source / 'src/syntax/tree_sitter.zig',
        'state': source / 'src/platform/macos/app_session/editor/syntax.zig',
        'editor': source / 'src/platform/macos/app_session/editor/mod.zig',
    }
    originals = {key: path.read_text() for key, path in paths.items()}
    cases = [
        ('pending-source', 'state', 'if (source.pending) return null;', 'if (source.pending and false) return null;'),
        ('language-source', 'provider', 'if (slot.language != self.slot.language) return null;', 'if (slot.language != self.slot.language and false) return null;'),
        ('stale-generation', 'folds', 'self.synced_gen != source_gen', '(self.synced_gen != source_gen and self.synced_gen == 0)'),
        ('target-binding', 'folds', '.parser = target_parser', '.parser = if (target_parser == source_parser) target_parser else source_parser'),
        ('prepared-cleanup', 'editor', 'if (self.syntax_seed) |state| {\n            state.deinit(allocator);', 'if (self.syntax_seed) |state| {'),
    ]

    def run(label):
        with (output / (label + '.log')).open('w') as log:
            code = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-shared-snapshot', 'test-editor-native-snapshot', '-j2'], cwd=source, stdout=log, stderr=subprocess.STDOUT, timeout=300).returncode
        return code, (output / (label + '.log')).read_text()

    code, log = run('control-before')
    if code or 'All 10 tests passed.' not in log or 'All 3 tests passed.' not in log:
        raise RuntimeError('Original control failed')
    results = []
    try:
        for name, key, old, new in cases:
            path = paths[key]
            original = originals[key]
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
        for key, path in paths.items():
            path.write_text(originals[key])
    code, log = run('control-after')
    if code or 'All 10 tests passed.' not in log or 'All 3 tests passed.' not in log:
        raise RuntimeError('Restored control failed')
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(output / 'results.json')


if __name__ == '__main__':
    main()
