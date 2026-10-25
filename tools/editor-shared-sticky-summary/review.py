#!/usr/bin/env python3
"""요약 복사의 세대·편집·독립 소유·선택적 실패를 서로 다른 결함으로 검증한다."""
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
    paths = dict(summary=source/'src/syntax/symbols.zig', provider=source/'src/syntax/tree_sitter.zig')
    originals = {key: path.read_text() for key, path in paths.items()}
    cases = [
        ('generation', 'summary', 'self.generation != generation or ', ''),
        ('pending-count', 'summary', 'self.edits != 0 or ', ''),
        ('pending-range', 'summary', ' or self.edited != null', ''),
        ('independent-reference', 'summary', 'const tree = c.ts_tree_copy(current) orelse return null;', 'const tree = current;'),
        ('optional-summary', 'provider', 'const summary: symbol_windows.Summary = self.sticky_summary.copyReady(copy, self.tree_gen) orelse .{};', 'const summary: symbol_windows.Summary = self.sticky_summary.copyReady(copy, self.tree_gen) orelse return null;'),
    ]
    results = []

    def run(name, expected):
        log = output/(name+'.log')
        with log.open('x') as stream:
            code = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-sticky-snapshot', '-j2'], cwd=source, stdout=stream, stderr=subprocess.STDOUT, timeout=600).returncode
        text = log.read_text()
        compiled = 'tree_sitter.test.sticky snapshot' in text and 'compilation errors' not in text
        if expected == 'pass':
            assert code == 0 and text.count('All 4 tests passed.') == 1, name
        else:
            assert code != 0 and compiled and 'FAIL (' in text, name
        results.append(dict(name=name, expected=expected, exit=code, compiled=compiled, log_sha256=hashlib.sha256(log.read_bytes()).hexdigest()))
        print(name+': '+expected, flush=True)

    run('normal-before', 'pass')
    try:
        for name, key, old, new in cases:
            original = originals[key]
            assert original.count(old) == 1, name
            paths[key].write_text(original.replace(old, new))
            run(name, 'reject')
            paths[key].write_text(original)
            run(name+'-normal-after', 'pass')
    finally:
        for key, path in paths.items():
            path.write_text(originals[key])
    product = {name: hashlib.sha256((source/name).read_bytes()).hexdigest() for name in ('src/syntax/symbols.zig', 'src/syntax/tree_sitter.zig', 'build.zig')}
    (output/'receipt.json').write_text(json.dumps(dict(complete=True, runs=results, source_sha256=product), indent=2)+'\n')


if __name__ == '__main__':
    main()
