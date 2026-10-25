#!/usr/bin/env python3
"""파서·수신 판·순회 수명·실제 트리 인계·실패 복귀를 실제 실행으로 검증한다."""
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
    source = output/'source'
    source.mkdir(parents=True)
    subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=zig-pkg', '--exclude=references', '--exclude=.env*', str(repo)+'/', str(source)+'/'], check=True)
    (source/'zig-pkg').symlink_to(args.deps.resolve(), target_is_directory=True)
    paths = dict(native=source/'src/syntax/tree_sitter.zig', state=source/'src/platform/macos/app_session/editor/syntax.zig')
    originals = {key: path.read_text() for key, path in paths.items()}
    cases = [
        ('parser', 'native', 'source.synced_parser != source_parser', '(source.synced_parser != source_parser and false)', 'native'),
        ('version', 'native', None, None, 'native'),
        ('walk-lifetime', 'native', '        try self.leaves.ensureTotalCapacity(allocator, source.leaves.items.len);\n        self.stopWalk();', '        self.stopWalk();\n        try self.leaves.ensureTotalCapacity(allocator, source.leaves.items.len);', 'native'),
        ('actual-tree-copy', 'state', 'if (out.copied) if (ready)', 'if (out.copied or true) if (ready)', 'product'),
        ('failure-fallback', 'state', '} else self.brackets.refresh(allocator, p, source, .{ .start = start, .end = new_end }) catch self.brackets.invalidate();', '} else self.brackets.invalidate();', 'product'),
    ]
    results = []

    def run(name, expected, mode):
        targets = []
        if mode in ('native', 'both'):
            targets.append('test-editor-shared-bracket-edit')
        if mode in ('product', 'both'):
            targets.append('test-editor-shared-bracket-edit-product')
        log = output/(name+'.log')
        with log.open('x') as stream:
            code = subprocess.run(['mise', 'exec', '--', 'zig', 'build', *targets, '-j2'], cwd=source, stdout=stream, stderr=subprocess.STDOUT, timeout=900).returncode
        text = log.read_text()
        compiled = 'test.shared bracket edit' in text and 'compilation errors' not in text
        if expected == 'pass':
            assert code == 0, name
            for count, included in ((4, mode in ('native', 'both')), (8, mode in ('product', 'both'))):
                if included:
                    assert text.count(f'All {count} tests passed.') == 1, name
        else:
            assert code != 0 and compiled and 'FAIL (' in text, name
        results.append(dict(name=name, expected=expected, mode=mode, exit=code, compiled=compiled, log_sha256=hashlib.sha256(log.read_bytes()).hexdigest()))
        print(name+': '+expected, flush=True)

    run('normal-before', 'pass', 'both')
    try:
        for name, key, old, new, mode in cases:
            original = originals[key]
            if name == 'version':
                start = original.index('    pub fn replaceMatched(')
                at = original.index('        self.version += 1;', start)
                assert at < original.index('    pub fn deinit(self: *BracketIndex', start)
                mutated = original[:at]+original[at:].replace('        self.version += 1;', '', 1)
            else:
                assert original.count(old) == 1, name
                mutated = original.replace(old, new)
            paths[key].write_text(mutated)
            run(name, 'reject', mode)
            paths[key].write_text(original)
            run(name+'-normal-after', 'pass', mode)
    finally:
        for key, path in paths.items():
            path.write_text(originals[key])
    product = {name: hashlib.sha256((source/name).read_bytes()).hexdigest() for name in ('src/syntax/tree_sitter.zig', 'src/platform/macos/app_session/editor/syntax.zig', 'src/platform/macos/app_session/editor/mod.zig', 'build.zig')}
    (output/'receipt.json').write_text(json.dumps(dict(complete=True, runs=results, source_sha256=product), indent=2)+'\n')


if __name__ == '__main__':
    main()
