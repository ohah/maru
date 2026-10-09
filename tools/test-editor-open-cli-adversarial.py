#!/usr/bin/env python3
"""Run CLI policy mutations in isolated source copies and reject assertion failures."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        p.error('output must be empty')
    zig = subprocess.check_output(['mise', 'which', 'zig'], text=True).strip()
    source = (root/'src/cli/editor/open.zig').read_text()
    namespace = (root/'src/cli/editor.zig').read_text()
    variants = [
        ('control-debug', None, None, True, 'Debug'),
        ('control-release', None, None, True, 'ReleaseFast'),
        ('literal-percent', "b == '~'", "b == '~' or b == '%'", False, 'Debug'),
        ('accept-zero', 'if (n == 0)', 'if (n == 0 and false)', False, 'ReleaseFast'),
        ('duplicate-option', 'field.* != null or', '(field.* != null and false) or', False, 'Debug'),
        ('ignore-cwd', '.{ cwd, request.path }', '.{ if (cwd.len > 0) "/wrong" else "/wrong", request.path }', False, 'ReleaseFast'),
        ('skip-receiver-validation', 'var validated = try app_url.parse(allocator, bytes.items);', 'var validated = try app_url.parse(allocator, "maru://open?path=%2Fsafe");', False, 'Debug'),
        ('short-line-misroute', 'std.mem.eql(u8, arg, "--line") or std.mem.eql(u8, arg, "-l")) &result.line', 'std.mem.eql(u8, arg, "--line")) &result.line', False, 'ReleaseFast'),
        ('lsp-topic-forward', '.lsp = args[1..]', '.lsp = args', False, 'Debug'),
        ('unknown-namespace', 'if (!std.mem.eql(u8, args[0], "open"))', 'if (!std.mem.eql(u8, args[0], "open") and false)', False, 'ReleaseFast'),
        ('equivalent-zero', 'if (n == 0)', 'if (0 == n)', True, 'ReleaseFast'),
    ]
    results = []
    for name, old, new, expected, mode in variants:
        case = out/name
        (case/'src/cli/editor').mkdir(parents=True)
        (case/'src/session').mkdir()
        (case/'src/cli/editor.zig').write_bytes((root/'src/cli/editor.zig').read_bytes())
        namespace_case = name in ('lsp-topic-forward', 'unknown-namespace')
        original = namespace if namespace_case else source
        variant = original
        if old is not None:
            assert original.count(old) == 1, name
            variant = original.replace(old, new)
        if namespace_case:
            (case/'src/cli/editor.zig').write_text(variant)
        (case/'src/cli/editor/open.zig').write_text(source if namespace_case else variant)
        (case/'src/session/editor_app_url.zig').write_bytes((root/'src/session/editor_app_url.zig').read_bytes())
        (case/'src/editor_open_cli_test.zig').write_bytes((root/'src/editor_open_cli_test.zig').read_bytes())
        result = subprocess.run([zig, 'test', str(case/'src/editor_open_cli_test.zig'), '-O', mode, '--cache-dir', str(case/'cache'), '--global-cache-dir', str(out/'global')], capture_output=True, text=True, timeout=90)
        log = result.stdout+result.stderr
        (case/'test.log').write_text(log)
        assert (result.returncode == 0) == expected, (name, log)
        if not expected:
            assert 'FAIL' in log, (name, 'must fail an assertion, not compilation', log)
        results.append(dict(name=name, expected_pass=expected, exit_code=result.returncode))
        print(name, 'verified', flush=True)
    (out/'results.json').write_text(json.dumps(dict(passed=True, source_sha256=hashlib.sha256(source.encode()).hexdigest(), namespace_sha256=hashlib.sha256(namespace.encode()).hexdigest(), results=results), indent=2)+'\n')


if __name__ == '__main__':
    main()
