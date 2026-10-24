#!/usr/bin/env python3
"""완료 트리 재사용의 경로·신원·provider 판·문맥·변경 범위를 독립 공격한다."""
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
        parser.error('Use a new external output')
    source = output / 'source'
    source.mkdir(parents=True)
    subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=zig-pkg', '--exclude=references', '--exclude=.env*', str(repo) + '/', str(source) + '/'], check=True)
    (source / 'zig-pkg').symlink_to(args.deps.resolve(), target_is_directory=True)
    paths = dict(provider=source/'src/syntax/tree_sitter.zig', host=source/'src/platform/macos/app_session/editor/mod.zig', stamp=source/'src/session/editor/syntax_stamp.zig')
    originals = {key: path.read_text() for key, path in paths.items()}
    cases = [
        ('reuse-disabled', 'provider', '        const next = c.ts_tree_copy(ready) orelse return false;', '        if (self.slot.language == parsed.slot.language) return false;\n        const next = c.ts_tree_copy(ready) orelse return false;'),
        ('live-document-identity', 'host', 'if (!maru.session.editor.syntax_stamp.sameDocument(document, other.owner.identity(other))) continue;', 'if (!maru.session.editor.syntax_stamp.sameDocument(document, other.owner.identity(other)) and false) continue;'),
        ('provider-generation', 'stamp', 'self.tree_generation == tree_generation', '(self.tree_generation == tree_generation or self.tree_generation != tree_generation)'),
        ('grammar-context', 'provider', 'self.slot.language != parsed.slot.language', '(self.slot.language != parsed.slot.language and false)'),
        ('own-change-ranges', 'provider', '                self.noteChanged(previous, next);', '                self.changed = parsed.changed;\n                self.changed_len = parsed.changed_len;\n                self.changed_all = parsed.changed_all;\n                self.fold_changes = parsed.fold_changes;\n                self.fold_changes_len = parsed.fold_changes_len;\n                self.fold_changes_before = self.tree_gen;'),
    ]
    def run(label):
        path = output / (label + '.log')
        with path.open('w') as stream:
            code = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-syntax-stamp', 'test-editor-shared-parse-core', 'test-editor-shared-parse-product', '-j2'], cwd=source, stdout=stream, stderr=subprocess.STDOUT, timeout=600).returncode
        return code, path.read_text()
    def positive(label):
        code, text = run(label)
        if code or any('All ' + str(count) + ' tests passed.' not in text for count in (30, 6, 7)):
            raise RuntimeError('Original control failed: ' + label)
    positive('control-before')
    results = []
    try:
        for name, key, old, new in cases:
            original = originals[key]
            if original.count(old) != 1:
                raise RuntimeError('Nonunique mutation anchor: ' + name)
            mutated = original.replace(old, new)
            paths[key].write_text(mutated)
            code, text = run(name)
            if not code or 'FAIL (' not in text:
                raise RuntimeError('Mutation survived or did not reach runtime: ' + name)
            results.append(dict(hypothesis=name, result='runtime-detected', file=str(paths[key].relative_to(source)), original_sha256=hashlib.sha256(original.encode()).hexdigest(), mutated_sha256=hashlib.sha256(mutated.encode()).hexdigest()))
            paths[key].write_text(original)
            print(name + ': runtime-detected', flush=True)
    finally:
        for key, path in paths.items():
            path.write_text(originals[key])
    positive('control-after')
    (output/'results.json').write_text(json.dumps(results, indent=2)+'\n')
    print(output/'results.json')


if __name__ == '__main__':main()
