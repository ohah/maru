#!/usr/bin/env python3
"""오류 트리·왼쪽 경계·잘못된 cursor·복귀 루트·빈 범위를 실제 실행으로 검증한다."""
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
        ('error-tree', 'native', 'if (c.ts_node_has_error(node)) return c.ts_tree_cursor_goto_first_child(cursor);', 'if (c.ts_node_has_error(node) and false) return c.ts_tree_cursor_goto_first_child(cursor);', 'both'),
        ('left-boundary', 'native', 'const goal = start -| 1;', 'const goal = start +| 1;', 'native'),
        ('cursor-match', 'native', 'if (moved and c.ts_node_eq(expected, c.ts_tree_cursor_current_node(cursor))) return true;', 'if (moved and (c.ts_node_eq(expected, c.ts_tree_cursor_current_node(cursor)) or true)) return true;', 'native'),
        ('fallback-root', 'native', 'c.ts_tree_cursor_reset(cursor, node);', 'c.ts_tree_cursor_reset(cursor, if (c.ts_node_is_null(node)) node else expected);', 'native'),
        ('empty-range', 'native', 'if (c.ts_node_is_null(expected)) return false;', 'if (c.ts_node_is_null(expected)) return c.ts_tree_cursor_goto_first_child(cursor);', 'native'),
    ]
    results = []

    def run(name, expected, mode):
        targets = []
        if mode in ('native', 'both'):
            targets.append('test-editor-bracket-range-cursor')
        if mode in ('product', 'both'):
            targets.append('test-editor-bracket-range-cursor-product')
        log = output/(name+'.log')
        with log.open('x') as stream:
            code = subprocess.run(['mise', 'exec', '--', 'zig', 'build', *targets, '-j2'], cwd=source, stdout=stream, stderr=subprocess.STDOUT, timeout=900).returncode
        text = log.read_text()
        compiled = 'test.bracket range cursor' in text and 'compilation errors' not in text
        if expected == 'pass':
            assert code == 0, name
            expected_reports = 2 if mode == 'both' else 1
            assert text.count('All 7 tests passed.') == expected_reports, name
        else:
            assert code != 0 and compiled and 'FAIL (' in text, name
        results.append(dict(name=name, expected=expected, mode=mode, exit=code, compiled=compiled, log_sha256=hashlib.sha256(log.read_bytes()).hexdigest()))
        print(name+': '+expected, flush=True)

    run('normal-before', 'pass', 'both')
    try:
        for name, key, old, new, mode in cases:
            original = originals[key]
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
