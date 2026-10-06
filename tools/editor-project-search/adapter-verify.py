#!/usr/bin/env python3
"""고정 공식 helper와 실제 Zig 어댑터를 합성 디스크 파일·독립 범위 기대값으로 검사한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--adapter', type=Path, required=True)
parser.add_argument('--rg', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--repeatable', action='store_true', help='CI 반복 실행은 고유 하위 디렉터리와 latest.json을 남긴다')
args = parser.parse_args()
adapter = args.adapter.resolve(strict=True)
rg = args.rg.resolve(strict=True)
base = args.output.resolve()
if args.repeatable:
    base.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=base))
else:
    output = base
    output.mkdir(parents=True, exist_ok=False)
report = {'status': 'running', 'cases': [], 'adapter_sha256': hashlib.sha256(adapter.read_bytes()).hexdigest(),
          'rg_sha256': hashlib.sha256(rg.read_bytes()).hexdigest(), 'scope': 'actual offline helper, argv, JSON fragments and disk ranges; not app worker/IME/UI/cancel evidence'}
environment = {**os.environ, 'RIPGREP_CONFIG_PATH': str(output / 'evil-config')}
(output / 'evil-config').write_text('--files-with-matches\n--glob\n!*\n')
cases = [
    ('query-flags', {'a.txt': b'pre--post\n'}, '--', 'literal', [], {'a.txt': [(0, 3, 0, 5)]}),
    ('case-fold', {'a.txt': b'foo FOO Foo\n'}, 'FOO', 'literal-fold', [], {'a.txt': [(0, 0, 0, 3), (0, 4, 0, 7), (0, 8, 0, 11)]}),
    ('word', {'a.txt': 'foo$bar foo😀bar foo_bar foo\n'.encode()}, 'foo', 'word', [], {'a.txt': [(0, 0, 0, 3), (0, 8, 0, 11), (0, 27, 0, 30)]}),
    ('pcre-fallback', {'a.txt': b'foobar foo bar\n'}, '(?<=foo)bar', 'regex', [], {'a.txt': [(0, 3, 0, 6)]}),
    ('multiline', {'a.txt': b'foo\r\nbar\n'}, r'foo\r?\nbar', 'regex', ['--multiline'], {'a.txt': [(0, 0, 1, 3)]}),
    ('bom', {'a.txt': b'\xef\xbb\xbffoo\n'}, 'foo', 'literal', [], {'a.txt': [(0, 0, 0, 3)]}),
    ('local-ignore', {'.gitignore': b'a.txt\n', 'a.txt': b'foo\n', 'b.txt': b'foo\n'}, 'foo', 'literal', [], {'b.txt': [(0, 0, 0, 3)]}),
    ('include', {'src/a.zig': b'foo\n', 'src/b.txt': b'foo\n', 'other/a.zig': b'foo\n'}, 'foo', 'literal', ['--include', 'src/*.zig'], {'src/a.zig': [(0, 0, 0, 3)]}),
    ('include-directory', {'src/a.zig': b'foo\n', 'src/deep/a.txt': b'foo\n', 'other/a.zig': b'foo\n'}, 'foo', 'literal', ['--include', 'src'], {'src/a.zig': [(0, 0, 0, 3)], 'src/deep/a.txt': [(0, 0, 0, 3)]}),
    ('case-insensitive-glob', {'src/a.zig': b'foo\n'}, 'foo', 'literal', ['--include', 'SRC/*.ZIG', '--ignore-glob-case'], {'src/a.zig': [(0, 0, 0, 3)]}),
    ('exclude', {'a.txt': b'foo\n', 'skip/a.txt': b'foo\n'}, 'foo', 'literal', ['--exclude', 'skip/**'], {'a.txt': [(0, 0, 0, 3)]}),
    ('defaults', {'.git/a': b'foo\n', 'node_modules/a': b'foo\n', 'bower_components/a': b'foo\n', '.visible': b'foo\n', 'a.code-search': b'foo\n'}, 'foo', 'literal', [], {'.visible': [(0, 0, 0, 3)]}),
    ('brace-include', {'src/a/one.txt': b'foo\n', 'src/b/two.txt': b'foo\n', 'src/c/three.txt': b'foo\n'}, 'foo', 'literal', ['--include', 'src/{a,b}'], {'src/a/one.txt': [(0, 0, 0, 3)], 'src/b/two.txt': [(0, 0, 0, 3)]}),
    ('literal-metacharacters', {'a.txt': b'a[0].* a0zzz\n'}, 'a[0].*', 'literal', [], {'a.txt': [(0, 0, 0, 6)]}),
    ('include-exclude-priority', {'src/a.zig': b'foo\n', 'src/b.zig': b'foo\n'}, 'foo', 'literal', ['--include', 'src/*.zig', '--exclude', 'src/b.zig'], {'src/a.zig': [(0, 0, 0, 3)]}),
    ('ignore-disabled', {'.gitignore': b'a.txt\n', 'a.txt': b'foo\n'}, 'foo', 'literal', ['--no-ignore'], {'a.txt': [(0, 0, 0, 3)]}),
    ('filename-newline', {'a\nb.txt': b'foo\n'}, 'foo', 'literal', [], {'a\nb.txt': [(0, 0, 0, 3)]}),
    ('unicode-ranges', {'a.txt': '😀가foo\nfoo'.encode()}, 'foo', 'literal', [], {'a.txt': [(0, 7, 0, 10), (1, 0, 1, 3)]}),
    ('empty-results', {'a.txt': b'foo\n'}, 'absent', 'literal', [], {}),
]
try:
    for name, files, query, mode, flags, expected in cases:
        root = output / name
        root.mkdir()
        for relative, content in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        # 상위 ignore를 읽지 않는 VS Code 기본값도 독립 fixture로 확인한다.
        (output / '.gitignore').write_text('b.txt\n')
        result = subprocess.run([str(adapter), str(rg), str(root), query, mode, *flags], env=environment,
                                capture_output=True, timeout=20)
        (output / (name + '.stdout')).write_bytes(result.stdout)
        (output / (name + '.stderr')).write_bytes(result.stderr)
        assert result.returncode == 0, (name, result.stderr.decode(errors='replace'))
        events = [json.loads(line) for line in result.stdout.splitlines()]
        found = {}
        for event in events[:-1]:
            spans = [(r['start']['line'], r['start']['byte'], r['end']['line'], r['end']['byte']) for r in event['ranges']]
            found.setdefault(event['path'].removeprefix('./'), []).extend(spans)
        assert found == expected, (name, found, expected)
        assert events[-1]['matches'] == sum(map(len, expected.values()))
        report['cases'].append({'name': name, 'expected': expected, 'exit': result.returncode})
    root = output / 'link-case'
    root.mkdir()
    target = output / 'link-target'
    target.mkdir()
    (target / 'file.txt').write_text('foo\n')
    (root / 'linked').symlink_to(target, target_is_directory=True)
    result = subprocess.run([str(adapter), str(rg), str(root), 'foo', 'literal'], env=environment, capture_output=True, timeout=20)
    assert result.returncode == 0 and json.loads(result.stdout.splitlines()[-1])['matches'] == 1
    report['cases'].append({'name': 'symlink-follows-outside-logical-root', 'exit': result.returncode})
    bad = subprocess.run([str(adapter), str(rg), str(root), '[', 'regex'], env=environment, capture_output=True, timeout=20)
    assert bad.returncode != 0
    report['cases'].append({'name': 'invalid-regex-rejected', 'exit': bad.returncode})
    report['status'] = 'passed' 
except Exception as error:
    report['status'] = 'failed'
    report['error'] = repr(error)
    raise
finally:
    (output / 'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    if args.repeatable:
        (base / 'latest.json').write_text(json.dumps({'status': report['status'], 'report': str((output / 'verification.json').relative_to(base))}) + '\n')
    print(output / 'verification.json')
