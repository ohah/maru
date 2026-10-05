#!/usr/bin/env python3
"""현재 문서 검색과 ripgrep의 파일별 원문 byte 범위를 대조한다. 제품 worker 검증은 아니다."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess


def raw_field(value):
    return value['text'].encode() if 'text' in value else base64.b64decode(value['bytes'], validate=True)


def rg_pattern(query):
    # rg는 패턴을 감싸므로 시작 위치 전용 PCRE2 verb를 덧붙일 수 없다.
    # 실제 CLI의 --crlf를 쓰고, 원문 directive의 지원 여부도 비교 결과에 남긴다.
    return query if query.startswith('(*') else '(?m)' + query


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', type=Path, required=True)
    parser.add_argument('--rg', default=shutil.which('rg'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--unicode-data', type=Path)
    args = parser.parse_args()
    native = args.native.resolve(strict=True)
    binary = Path(args.rg).resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    disk = output / 'disk'
    opened = output / 'document-bytes'
    home = output / 'home'
    for directory in [disk, opened, home]:
        directory.mkdir()
    environment = {**os.environ, 'HOME': str(home), 'XDG_CONFIG_HOME': str(home), 'LC_ALL': 'C'}
    environment.pop('RIPGREP_CONFIG_PATH', None)
    bodies = {
        'empty': b'', 'lf': b'foo\n\n', 'crlf': b'foo\r\n\r\n', 'cr': b'foo\r',
        'mixed': b'foo\r\nbar\nfoo\rbar', 'doublecr': b'foo\r\r\n',
        'bom': b'\xef\xbb\xbffoo\r\n', 'bomonly': b'\xef\xbb\xbf', 'nul': b'\0foo\n',
        'word': 'foo foo😀bar foo$bar foo_bar 한foo글 foo-foo\n'.encode(),
        'case': 'é É Ÿ ÿ Σ σ ς Α α А а Ё ё k K K s S ſ I i İ ı ß ẞ ffi ﬃ\n'.encode(),
        'punctuation': b'a- b -- c \t . .* $ _ /foo/ foofoo aaaaa abababa\n',
        'unicode': '가 가 é é 한글 😀\u2028foo\u2029bar\n'.encode(),
    }
    randomizer = random.Random(4145)
    alphabet = ['foo', 'bar', 'aa', 'NEEDLE', 'needle', 'é', 'É', 'K', 'k', '😀', '한글', '$', '_', ' ', '-', '\t', '\0', '\r', '\n']
    for index in range(48):
        bodies[f'random-{index:02}'] = ''.join(randomizer.choice(alphabet) for _ in range(80)).encode()
    for name, body in bodies.items():
        (disk / name).write_bytes(body)
        # document.open에서 제거하는 유효한 UTF-8 BOM만 제거한다. 줄바꿈·EOF는 그대로다.
        (opened / name).write_bytes(body[3:] if body.startswith(b'\xef\xbb\xbf') else body)
    names = sorted(bodies)
    paths = output / 'paths'
    paths.write_bytes(b''.join(os.fsencode(disk / name) + b'\0' for name in names))
    queries = []
    for mode in ['literal', 'literal-fold', 'word', 'word-fold']:
        for query in ['foo', 'bar', 'aa', 'needle', 'NEEDLE', 'é', 'É', 'k', 's', 'I', 'Σ', 'ς', 'А', 'Ё', 'ß',
                      'ffi', '한글', '가', '가', '😀', '-', '--', '- ', ' ', '\t', '$', '_', '.*', 'absent', '']:
            queries.append((mode, query))
    regexes = ['foo', '^foo$', '^', '$', '^$', '^|foo', 'foo|^', '(?=foo)', '(?=foo)|foo', 'foo|(?=foo)',
               '.*', '.*?', '.+?', 'a*', 'a+', 'a??', '(?:foo)?', 'foo|foobar', r'\bfoo\b', r'\w+', r'\W+',
               r'\s+', r'\S+', r'\r$', r'\x00', r'\p{L}+', r'\p{Greek}+', r'(?<=foo)bar', r'foo(?=bar)',
               r'(foo)\1', r'(a+)\1', '(?i)k', '(?i)é', '(?i)Σ', '(?i)ß', '(?m)^foo$', r'foo\r?\nbar',
               r'\Afoo', r'foo\z', r'foo\Kbar', r'\Gfoo', '(?s)foo.bar', '(*LF)^bar$', '[', '(?<=a+)b']
    queries.extend(('document-regex', query) for query in regexes)
    queries.extend((mode, query) for mode in ['document-regex-fold', 'document-regex-word', 'document-regex-word-fold']
                   for query in ['foo', 'FOO', 'k', 'Σ', r'foo\r?\nbar', '^|foo'])
    report = {'status': 'running', 'seed': 4145, 'files': len(names), 'queries': len(queries), 'cases': [],
              'native_sha256': hashlib.sha256(native.read_bytes()).hexdigest(),
              'rg_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'rg_version': subprocess.check_output([str(binary), '--version'], text=True),
              'script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'scope': '동일 document.open bytes의 모든 절대 byte 범위. BOM만 제거하고 원문 줄바꿈/EOF를 보존한다. 유한 자료의 대조이며 모든 정규식 동등성·제품 worker·IME·파일 선정의 검증은 아니다.'}

    repository = Path(__file__).resolve().parents[2]
    report['product_source_sha256'] = {
        path: hashlib.sha256((repository / path).read_bytes()).hexdigest()
        for path in ['src/session/editor/find.zig', 'src/session/editor/document.zig',
                     'src/session/editor/line_index.zig', 'src/session/editor/selection.zig',
                     'src/search_case_fold.zig', 'src/regex.zig']}

    def execute(command, directory):
        return subprocess.run(command, cwd=directory, env=environment, capture_output=True, timeout=20)

    def native_ranges(query, mode, file_list=paths, file_names=names):
        result = execute([str(native), str(file_list), query, mode, '--offsets'], disk)
        if result.returncode:
            return result, {}
        records = [json.loads(row) for row in result.stdout.splitlines()]
        assert len(records) == len(file_names) + 1 and records[-1]['files'] == len(file_names)
        assert [row['file_index'] for row in records[:-1]] == list(range(len(file_names)))
        return result, {file_names[index]: row['offsets'] for index, row in enumerate(records[:-1]) if row['offsets']}

    def rg_ranges(query, mode, pcre2, directory=opened):
        regex = mode.startswith('document-regex')
        command = [str(binary), '--no-config', '--no-ignore', '--hidden', '--text', '--encoding', 'none', '--json']
        if regex:
            command += ['--multiline', '--crlf', '--pcre2' if pcre2 else '--engine=auto']
            query = rg_pattern(query)
        else:
            command += ['--fixed-strings']
            if pcre2:
                command += ['--pcre2']
        command += ['--ignore-case' if mode.endswith('-fold') else '--case-sensitive']
        if mode.startswith('word') or '-word' in mode:
            command += ['--word-regexp']
        result = execute(command + ['--regexp', query, '--', '.'], directory)
        ranges = {}
        if result.returncode not in (0, 1):
            return result, ranges
        for raw in result.stdout.splitlines():
            event = json.loads(raw)
            if event.get('type') == 'match':
                data = event['data']
                name = os.fsdecode(raw_field(data['path'])).removeprefix('./')
                for span in data['submatches']:
                    ranges.setdefault(name, []).append([data['absolute_offset'] + span['start'],
                                                        data['absolute_offset'] + span['end']])
        return result, ranges

    # 서로 같은 오류를 공유해도 반드시 실패하도록 제품 계약의 고정 기대값을 먼저 확인한다.
    oracles = [('lf', '^$', 'document-regex', [[4, 4], [5, 5]]),
               ('empty', '^$', 'document-regex', [[0, 0]]),
               ('bom', r'\Afoo', 'document-regex', [[0, 3]]),
               ('cr', '^foo$', 'document-regex', [[0, 3]]),
               ('mixed', r'foo\r?\nbar', 'document-regex', [[0, 8]]),
               ('case', 'k', 'literal-fold', [])]
    # Unicode 위치는 가변 byte 길이와 무관한 문자열 파티션으로 별도로 고정한다.
    case_content = bodies['case']
    oracles[-1] = ('case', 'k', 'literal-fold', [[case_content.index(token), case_content.index(token) + len(token)]
                                               for token in [b'k', b'K', 'K'.encode()]])
    report['oracles'] = []
    for index, (name, query, mode, expected) in enumerate(oracles):
        single = output / f'oracle-{index}.paths'
        single.write_bytes(os.fsencode(disk / name) + b'\0')
        result, actual = native_ranges(query, mode, single, [name])
        assert result.returncode == 0 and actual.get(name, []) == expected, (name, query, actual, expected)
        report['oracles'].append({'file': name, 'query': query, 'mode': mode, 'expected': expected})
    for mode, query in queries:
        result, reference = native_ranges(query, mode)
        row = {'mode': mode, 'query': query, 'native_exit': result.returncode,
               'native_error': result.stderr.decode(errors='replace') if result.returncode else '', 'variants': {}}
        for label, pcre2 in [('rg-auto', False), ('rg-pcre2', True)]:
            other, found = rg_ranges(query, mode, pcre2)
            valid = result.returncode == 0 and other.returncode in (0, 1)
            differences = [{'file': name, 'native': reference.get(name, []), 'rg': found.get(name, [])}
                           for name in names if reference.get(name, []) != found.get(name, [])] if valid else []
            row['variants'][label] = {'rg_exit': other.returncode, 'both_valid': valid,
                                      'equal': valid and not differences, 'differences': differences,
                                      'error': other.stderr.decode(errors='replace')}
        report['cases'].append(row)
    report['summary'] = {label: {'equal': sum(c['variants'][label]['equal'] for c in report['cases']),
                                'different': sum(c['variants'][label]['both_valid'] and not c['variants'][label]['equal'] for c in report['cases']),
                                'errors': sum(not c['variants'][label]['both_valid'] for c in report['cases'])}
                         for label in ['rg-auto', 'rg-pcre2']}
    (output / 'contract.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    # 확인했던 반례가 사라져도 비교 결과를 무조건 통과시키지 않는다.
    for mode, query in [('word', 'foo'), ('document-regex', '^$')]:
        item = next(c for c in report['cases'] if c['mode'] == mode and c['query'] == query)
        assert item['variants']['rg-pcre2']['both_valid'] and not item['variants']['rg-pcre2']['equal'], (mode, query, item)
    if args.unicode_data:
        data = args.unicode_data.read_bytes()
        pairs = []
        for line in data.decode().splitlines():
            fields = line.split('#', 1)[0].strip().split(';')
            if len(fields) >= 3 and fields[1].strip() in ['C', 'S']:
                pairs.append((int(fields[0], 16), int(fields[2].strip(), 16)))
        assert len(pairs) == 1512
        (disk / 'all-unicode-pairs').write_text(''.join(chr(a) + ' ' + chr(b) + '\n' for a, b in pairs))
        unicode_dir = output / 'unicode-pairs'
        unicode_dir.mkdir()
        (unicode_dir / 'all-unicode-pairs').write_bytes((disk / 'all-unicode-pairs').read_bytes())
        single = output / 'unicode.paths'
        single.write_bytes(os.fsencode(disk / 'all-unicode-pairs') + b'\0')
        mismatches = []
        folding = dict(pairs)
        expected_by_fold = {}
        offset = 0
        for character in (disk / 'all-unicode-pairs').read_text():
            size = len(character.encode())
            expected_by_fold.setdefault(folding.get(ord(character), ord(character)), []).append([offset, offset + size])
            offset += size
        for codepoint in sorted({value for pair in pairs for value in pair}):
            query = chr(codepoint)
            n, reference = native_ranges(query, 'literal-fold', single, ['all-unicode-pairs'])
            r, found = rg_ranges(query, 'literal-fold', False, unicode_dir)
            assert n.returncode == 0 and r.returncode in (0, 1)
            expected = {'all-unicode-pairs': expected_by_fold[folding.get(codepoint, codepoint)]}
            assert reference == expected, ('Unicode 17 oracle', codepoint, reference, expected)
            if reference != found:
                mismatches.append({'query_codepoint': codepoint, 'native': reference, 'rg': found})
        report['unicode'] = {'mapping_count': len(pairs), 'data_sha256': hashlib.sha256(data).hexdigest(),
                             'queries': len({value for pair in pairs for value in pair}), 'native_oracle': 'all queries passed Unicode 17 C/S byte ranges', 'differences': mismatches}
    report['status'] = 'completed'
    (output / 'contract.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report['summary']), flush=True)
    if 'unicode' in report:
        print('Unicode differing queries:', len(report['unicode']['differences']), flush=True)
    print(output / 'contract.json', flush=True)


if __name__ == '__main__':
    main()
