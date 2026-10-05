#!/usr/bin/env python3
"""문서 전체 정규식의 원문 범위를 독립 기대값과 실제 Maru 바이너리로 대조한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--native', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
native = args.native.resolve(strict=True)
cases = [
    ('absolute-start', b'foo\nfoo', r'\Afoo', [[0, 0, 3, 0, 3]]),
    ('absolute-end', b'foo\nfoo', r'foo\z', [[1, 0, 3, 1, 3]]),
    ('line-anchors', b'foo\r\nbar\nfoo', '^foo$', [[0, 0, 3, 0, 3], [2, 0, 3, 2, 3]]),
    ('mixed-span', b'foo\r\nbar\nfoo\nbar', r'foo\r?\nbar', [[0, 0, 8, 1, 3], [2, 0, 7, 3, 3]]),
    ('cross-lookbehind', b'foo\r\nbar', r'(?<=foo\r\n)bar', [[1, 0, 3, 1, 3]]),
    ('cross-backref', b'foo\r\nfoo', r'(foo)\r?\n\1', [[0, 0, 8, 1, 3]]),
    ('reset-start', b'pad foo\r\nbar', r'foo\K\r?\nbar', [[0, 7, 5, 1, 3]]),
    ('search-start', b'foofoo', r'\Gfoo', [[0, 0, 3, 0, 3], [0, 3, 3, 0, 6]]),
    ('dotall', b'foo\nbar', '(?s)foo.bar', [[0, 0, 7, 1, 3]]),
    ('ordinary-dot', b'foo\nbar', 'foo.bar', []),
    ('end-on-next-line', b'foo\r\nbar', r'foo\r?\n', [[0, 0, 5, 1, 0]]),
    ('empty-file', b'', '^$', [[0, 0, 0, 0, 0]]),
    ('empty-final-line', b'foo\n', '^$', [[1, 0, 0, 1, 0]]),
    ('empty-alternative', b'foo', '^|foo', [[0, 0, 0, 0, 0]]),
    ('lazy-alternative', b'foo', '.*?', [[0, 0, 0, 0, 0], [0, 1, 0, 0, 1], [0, 2, 0, 0, 2], [0, 3, 0, 0, 3]]),
    ('lone-cr-boundary', b'foo\rbar', '^bar$', [[0, 4, 3, 0, 7]]),
    ('lone-cr-literal', b'foo\rbar', r'\r', [[0, 3, 1, 0, 4]]),
    ('nul', b'foo\0bar', r'foo\x00bar', [[0, 0, 7, 0, 7]]),
    ('bom-start', b'\xef\xbb\xbffoo\r\nbar', r'\Afoo', [[0, 0, 3, 0, 3]]),
    ('bom-span', b'\xef\xbb\xbffoo\r\nbar', r'foo\r?\nbar', [[0, 0, 8, 1, 3]]),
    ('unicode-span', '한글\r\n😀'.encode(), r'한글\r?\n😀', [[0, 0, 12, 1, 4]]),
    ('explicit-lf', b'foo\rbar', '(*LF)^bar$', []),
    ('no-multiline', b'foo\nfoo', '(?-m)^foo$', []),
    ('empty-query', b'foo', '', []),
]
report = {'status': 'running', 'cases': [], 'native_sha256': hashlib.sha256(native.read_bytes()).hexdigest(),
          'limits': '공식 API를 호출하는 실제 바이너리와 독립 기대 범위 대조. 모든 정규식/OS 콜백의 증명은 아님.'}
for name, body, query, expected in cases:
    path = output / (name + '.txt')
    path.write_bytes(body)
    paths = output / (name + '.paths')
    paths.write_bytes(os.fsencode(path) + b'\0')
    result = subprocess.run([str(native), str(paths), query, 'document-regex', '--ranges'], capture_output=True, timeout=15)
    assert result.returncode == 0, (name, result.stderr)
    records = [json.loads(line) for line in result.stdout.splitlines()]
    actual = records[0]['ranges']
    assert records[-1]['matches'] == len(actual)
    assert actual == expected, (name, actual, expected)
    report['cases'].append({'name': name, 'query': query, 'ranges': actual})
report['errors'] = []
for name, body, query, error in [
    ('invalid-document', b'foo\xffbar', 'foo', b'NotUtf8'),
    ('invalid-pattern', b'foo', '[', b'InvalidPattern'),
    ('bounded-backtracking', b'a' * 12000 + b'!', '^(a+)+$', b'MatchLimit'),
]:
    path = output / (name + '.txt')
    path.write_bytes(body)
    paths = output / (name + '.paths')
    paths.write_bytes(os.fsencode(path) + b'\0')
    result = subprocess.run([str(native), str(paths), query, 'document-regex', '--ranges'], capture_output=True, timeout=15)
    assert result.returncode != 0 and error in result.stderr, (name, result.stdout, result.stderr)
    report['errors'].append({'name': name, 'error': error.decode()})
# 실제 다른 경로를 실행해, 줄별 검색이나 LF 사본이 정답으로 통과하지 못함을 고정한다.
report['negative_controls'] = []
for name, body, query, mode, expected in [
    ('line-engine', b'foo\nfoo', r'\Afoo', 'regex', [[0, 0, 3]]),
    ('normalized-copy', b'foo\nbar', r'foo\r?\nbar', 'document-regex', [[0, 0, 8]]),
]:
    path = output / (name + '.txt')
    path.write_bytes(body)
    paths = output / (name + '.paths')
    paths.write_bytes(os.fsencode(path) + b'\0')
    result = subprocess.run([str(native), str(paths), query, mode, '--ranges'], capture_output=True, timeout=15)
    assert result.returncode == 0, (name, result.stderr)
    observed = [span[:3] for span in json.loads(result.stdout.splitlines()[0])['ranges']]
    assert observed != expected, (name, observed)
    report['negative_controls'].append({'name': name, 'expected_original': expected, 'observed': observed, 'detected': True})
repo = Path(__file__).resolve().parents[2]
report['source_sha256'] = {name: hashlib.sha256((repo / name).read_bytes()).hexdigest() for name in (
    'src/regex.zig', 'src/session/editor/find.zig', 'src/session/editor/line_index.zig',
    'tools/editor-project-search/native.zig', 'tools/editor-project-search/document-verify.py')}
report['status'] = 'passed'
(output / 'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'{len(cases)}개 범위와 {len(report["errors"])}개 오류 경계 통과: {output / "verification.json"}')
