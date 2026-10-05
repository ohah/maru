#!/usr/bin/env python3
"""Unicode 17.0.0 공식 데이터에서 검색용 C/S 표를 생성한다. 네트워크는 사용하지 않는다."""
import argparse
import hashlib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('--output', type=Path, default=Path('src/search_case_fold.zig'))
args = parser.parse_args()
source = args.source.read_bytes()
expected = 'ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183'
if hashlib.sha256(source).hexdigest() != expected:
    parser.error('Unicode 17.0.0 CaseFolding.txt SHA-256이 다릅니다')
pairs = []
for raw in source.decode().splitlines():
    entry = raw.split('#', 1)[0].strip()
    if not entry:
        continue
    code, status, mapping, _ = [part.strip() for part in entry.split(';')]
    if status in ('C', 'S'):
        points = mapping.split()
        assert len(points) == 1
        pairs.append((int(code, 16), int(points[0], 16)))
assert pairs == sorted(set(pairs))
text = '''//! 검색용 Unicode 17.0.0 simple case folding(C/S). 편집용 소문자 변환과 분리한다.
//! 출처: https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt
//! 생성: python3 tools/generate-search-case-fold.py references/unicode/17.0.0/CaseFolding.txt
//! SHA-256: ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183
//! Unicode 데이터의 이용 조건은 assets/unicode/LICENSE.txt에 있다.
const std = @import("std");

/// 검색은 원문을 바꾸지 않는다. 접힌 문자의 UTF-8 길이 대신 원문의 매치 길이를 사용한다.
pub fn fold(cp: u21) u21 {
    if (cp < 0x80) return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
    var lo: usize = 0;
    var hi: usize = mappings.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (mappings[mid][0] < cp) lo = mid + 1 else hi = mid;
    }
    return if (lo < mappings.len and mappings[lo][0] == cp) mappings[lo][1] else cp;
}

const mappings = [_][2]u21{
'''
text += ''.join(f'    .{{ 0x{a:X}, 0x{b:X} }},\n' for a, b in pairs)
text += '''};

test "SCF1 Unicode 표의 검색은 정렬·멱등·비매핑 보존을 만족한다" {
    // 모든 scalar를 선형 오라클과 대조하여 이진 탐색의 양끝 누락도 탐지한다.
    var cursor: usize = 0;
    var cp: u21 = 0;
    while (cp <= 0x10ffff) : (cp += 1) {
        const expected: u21 = if (cursor < mappings.len and mappings[cursor][0] == cp) value: {
            const value = mappings[cursor][1];
            cursor += 1;
            break :value value;
        } else cp;
        try std.testing.expectEqual(expected, fold(cp));
        try std.testing.expectEqual(expected, fold(expected));
    }
    try std.testing.expectEqual(mappings.len, cursor);
    try std.testing.expectEqual(@as(u21, 'k'), fold(0x212a));
    try std.testing.expectEqual(@as(u21, 's'), fold(0x17f));
    try std.testing.expectEqual(@as(u21, 0x3c3), fold(0x3c2));
    try std.testing.expectEqual(@as(u21, 0xdf), fold(0x1e9e));
    // Full folding과 Turkic folding은 선택하지 않는다.
    try std.testing.expectEqual(@as(u21, 0x130), fold(0x130));
    try std.testing.expectEqual(@as(u21, 0xdf), fold(0xdf));
}
'''
args.output.write_text(text)
print(f'{len(pairs)} C/S 매핑 생성: {args.output}')
