# -*- coding: utf-8 -*-
# 술어 정규식 대조 표(`PRD2` — src/syntax/predicate.zig 의 `oracle`)를 다시 뽑는다(계획 editor-bundled-languages BLP).
# 표의 정규식 × 표본 문자열마다 Python `re.search` 의 답을 적는다. 지금 표의 정규식·표본을 읽고, 인자로 준 것을 더해 표 전체를 다시 쓴다.
#
# 쓰는 법: python3 tools/editor/predicate_oracle.py [--pattern RE]... [--lua-pattern RE]... [--sample TEXT]...
#   RE 는 tree-sitter 가 쿼리 문자열을 해석한 **뒤** 값이다(`\n` `\r` `\t` `\0` 외 이스케이프는 그 글자 — `"[A-Z\\d_]"` 는 `[A-Z\d_]`).
#   빠진 정규식은 `PRD5`(src/syntax/tree_sitter.zig)가 이름과 함께 알려 준다.
import argparse, re, sys

PATH = 'src/syntax/predicate.zig'
LIT = r'"(?:[^"\\]|\\.)*"'


def dez(z):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t', 'r': '\r'}.get(m.group(1), m.group(1)), z[1:-1])


def enz(v):
    return '"' + v.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t') + '"'


def answer(p, lua, t):
    if lua:
        # Lua 의 `%` 는 이스케이프다. 글자 묶음(`%a` `%d` …)은 Python 과 뜻이 달라 이 생성기가 모른다 — 만나면 멈춘다.
        if re.search(r'%[a-zA-Z]', p):
            sys.exit('Lua 글자 묶음은 이 생성기가 모른다: ' + p)
        p = re.sub(r'%(.)', lambda m: re.escape(m.group(1)), p)
    return re.search(p, t) is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pattern', action='append', default=[])
    ap.add_argument('--lua-pattern', action='append', default=[])
    ap.add_argument('--sample', action='append', default=[])
    args = ap.parse_args()

    s = open(PATH, encoding='utf-8').read()
    start = s.index('pub const oracle = [_]struct')
    body = s.index('\n', start) + 1
    end = s.index('\n};', start)
    rows = re.findall(r'\.\{ \.p = (' + LIT + r'), \.lua = (true|false), \.t = (' + LIT + r'), \.want = (true|false) \}', s[start:end])
    pats, samples = [], []
    for p, lua, t, want in rows:
        if (dez(p), lua == 'true') not in pats:
            pats.append((dez(p), lua == 'true'))
        if dez(t) not in samples:
            samples.append(dez(t))
        # 지금 표가 이 생성기의 답과 같아야 다시 쓸 자격이 있다.
        if answer(dez(p), lua == 'true', dez(t)) != (want == 'true'):
            sys.exit('지금 표가 Python 의 답과 다르다: ' + p + ' ' + t)
    for p in args.pattern:
        if (p, False) not in pats:
            pats.append((p, False))
    for p in args.lua_pattern:
        if (p, True) not in pats:
            pats.append((p, True))
    for t in args.sample:
        if t not in samples:
            samples.append(t)
    pats.sort(key=lambda k: (k[1], enz(k[0])))
    out = []
    for p, lua in pats:
        for t in samples:
            out.append('    .{ .p = %s, .lua = %s, .t = %s, .want = %s },' % (enz(p), 'true' if lua else 'false', enz(t), 'true' if answer(p, lua, t) else 'false'))
    open(PATH, 'w', encoding='utf-8').write(s[:body] + '\n'.join(out) + s[end:])
    print('정규식 %d × 표본 %d = %d 칸' % (len(pats), len(samples), len(out)))


main()
