// VS Code 의 Enter 동작 대조 말뭉치를 만든다(계획 editor-typing-rules TR3). VS Code 내장 언어 설정(`extensions/*/language-configuration.json`,
// 핀 고정 커밋)을 **원래 의미(JS RegExp)** 로 돌려, 말뭉치의 줄마다 VS Code 가 낼 갈래를 Zig 표로 찍는다. 규칙 원문은 출력하지 않는다(답만).
//
// 쓰는 법: node vscode_enter_oracle.mjs <설정 폴더> > src/session/editor/enter_rules_vscode.zig
//   설정 폴더 = 핀 커밋의 `extensions/<언어>/language-configuration.json` 들을 `<언어>.json` 으로 받아 둔 곳.
//
// VS Code 의 순서(동작만 — `languageConfigurationRegistry.getEnterAction` → `OnEnterSupport.onEnter` → `getIndentForEnter`):
//   ① onEnterRules(앞에서부터, beforeText·afterText·previousLineText 가 다 맞는 첫 것)
//   ② 괄호 — before 가 여는 괄호로 끝나고(뒤 공백 무시) after 가 그 닫는 괄호로 시작하면 indentOutdent
//   ③ 괄호 — before 가 여는 괄호로 끝나면 indent
//   ④ indentationRules.increaseIndentPattern 이 before 에 맞으면 indent
//   그 밖은 keep.
import fs from 'node:fs';
import path from 'node:path';

export const PIN = 'faa67179693ee79bd1ce7dca019aba0ea66cf637';

const dir = process.argv[2];
function stripJsonc(s) {
  let o = '', i = 0, inStr = false;
  while (i < s.length) {
    const c = s[i], n = s[i + 1];
    if (inStr) { o += c; if (c === '\\') { o += n; i += 2; continue; } if (c === '"') inStr = false; i++; continue; }
    if (c === '"') { inStr = true; o += c; i++; continue; }
    if (c === '/' && n === '/') { while (i < s.length && s[i] !== '\n') i++; continue; }
    if (c === '/' && n === '*') { i += 2; while (i < s.length && !(s[i] === '*' && s[i + 1] === '/')) i++; i += 2; continue; }
    o += c; i++;
  }
  return o.replace(/,(\s*[}\]])/g, '$1');
}
const load = (name) => JSON.parse(stripJsonc(fs.readFileSync(path.join(dir, name + '.json'), 'utf8')));
const rx = (p) => (typeof p === 'string' ? new RegExp(p) : new RegExp(p.pattern, p.flags || ''));
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function vscodeEnter(cfg, before, after, prev) {
  for (const r of cfg.onEnterRules || []) {
    if (!rx(r.beforeText).test(before)) continue;
    if (r.afterText && !rx(r.afterText).test(after)) continue;
    if (r.previousLineText && !rx(r.previousLineText).test(prev)) continue;
    return { indent: r.action.indent, append: r.action.appendText || '', remove: r.action.removeText || 0 };
  }
  const br = (cfg.brackets || []).filter((b) => b[0].length === 1 && b[1].length === 1);
  if (before.length > 0 && after.length > 0)
    for (const [o, c] of br) if (new RegExp(esc(o) + '\\s*$').test(before) && new RegExp('^\\s*' + esc(c)).test(after)) return { indent: 'indentOutdent', append: '', remove: 0 };
  if (before.length > 0) for (const [o] of br) if (new RegExp(esc(o) + '\\s*$').test(before)) return { indent: 'indent', append: '', remove: 0 };
  const inc = cfg.indentationRules && cfg.indentationRules.increaseIndentPattern;
  if (inc && rx(inc).test(before)) return { indent: 'indent', append: '', remove: 0 };
  return { indent: 'none', append: '', remove: 0 };
}

// 말뭉치 — 문법마다 [before, after, prev]. 규칙 갈래마다 맞는 것·안 맞는 것·경계를 둔다.
const corpus = {
  typescript: ['typescript-basics', [
    ['function f() {', '}', ''], ['if (x) {', '', ''], ['foo(a', ')', ''], ['x = [', ']', ''], ['if (x) { foo(); }', '', ''],
    ['const s = "{";', '', ''], ['// {', '', ''], ['const t = `${x} {`', '', ''], ['/**', '', ''], ['/** a', ' */', ''],
    [' * a', '', '/**'], [' * a', '', ' * b'], [' */', '', ' * a'], [' * a */', '', ''], ['// note', 'more', ''], ['// note', '', ''],
    ['x = 1; // a', 'b', ''], ['case 1:', '', ''], ['default:', '', ''], ['  return x;', '', ''], ['foo(a, ', '', ''], ['', '', ''],
  ]],
  javascript: ['typescript-basics', [['arr.map((x) => {', '})', ''], ['/**', '', ''], ['switch (x) {', '', '']]],
  java: ['java', [['class A {', '}', ''], ['/**', '', ''], [' * a', '', '/**'], ['case 1:', '', ''], ['// x', 'y', '']]],
  c: ['cpp', [['int f() {', '}', ''], ['/**', '', ''], ['// x', 'y', ''], ['case 1:', '', '']]],
  go: ['go', [['func f() {', '}', ''], ['case 1:', '', ''], ['// x', 'y', ''], ['/**', '', '']]],
  rust: ['rust', [['fn f() {', '}', ''], ['/// doc', '', ''], ['// x', 'y', ''], ['/**', '', '']]],
  python: ['python', [
    ['def f():', '', ''], ['if x:  # note', '', ''], ['match x:', '', ''], ["d = {'k':", '', ''], ['lambda x: x', '', ''],
    ['foo(', ')', ''], ['foo(a, ', '', ''], ['print("a:")', '', ''], ['    else:', '', ''], ['x = [', ']', ''],
  ]],
  ruby: ['ruby', [
    ['def foo', '', ''], ['arr.each do |x|', '', ''], ['s = "a do b"', '', ''], ['if a then b end', '', ''], ['return if a', '', ''],
    ['x = if a', '', ''], ['class A', '', ''], ['private def foo', '', ''], ['loop do', '', ''], ['puts "do"', '', ''],
  ]],
  html: ['html', [
    ['<div>', '</div>', ''], ['<div>', '', ''], ['<br>', '', ''], ['<img src="x">', '', ''], ['<li>a', '</li>', ''],
    ['<div class="a">', '</div>', ''], ['<input>', '', ''], ['</div>', '', ''], ['<!-- a -->', '', ''],
  ]],
  css: ['css', [['a {', '}', ''], ['a {', '', ''], ['a { color: red; }', '', '']]],
  json: ['json', [['{', '}', ''], ['"a": [', ']', ''], ['"a": 1,', '', '']]],
  // 번들 언어 확대 BL1(docs/plans/editor-bundled-languages.md) — VS Code 에 내장 설정이 있는 다섯.
  yaml: ['yaml', [
    ['key:', '', ''], ['  nested:', '', ''], ['- ', '', ''], ['- item', '', ''], ['key: value', '', ''], ['key: &anchor', '', ''],
    ['key: |', '', ''], ['url: http://x', '', ''], ['a: [', ']', ''], ['# key:', '', ''],
  ]],
  lua: ['lua', [
    ['function f()', '', ''], ['if x then', '', ''], ['for i = 1, 3 do', '', ''], ['while x do', '', ''], ['repeat', '', ''], ['else', '', ''],
    ['elseif y then', '', ''], ['local t = {', '}', ''], ['f(function() end)', '', ''], ['-- function f()', '', ''], ['x = 1', '', ''],
    ['local s = "then"', '', ''],
  ]],
  dockerfile: ['docker', [['FROM node', '', ''], ['RUN echo a:', '', ''], ['RUN [', ']', ''], ['# c', '', '']]],
  make: ['make', [['all: build', '', ''], ['all:', '', ''], ['$(foo', ')', ''], ['\techo $(X)', '', '']]],
  xml: ['xml', [['<a>', '</a>', ''], ['<a>', '', ''], ['<a/>', '', ''], ['<?xml version="1.0"?>', '', ''], ['<!-- c -->', '', ''], ['<a b="c">', '</a>', '']]],
  // BL2 — Swift. VS Code swift 설정엔 `indentationRules` 가 없고 `onEnterRules` 는 줄 주석 이어쓰기 하나다.
  swift: ['swift', [
    ['func f() {', '}', ''], ['if x {', '', ''], ['foo(a, ', '', ''], ['let a = [', ']', ''], ['foo(a', ')', ''], ['let s = "{"', '', ''],
    ['// note', 'more', ''], ['// note', '', ''], ['x = 1 // a', 'b', ''], ['case .a:', '', ''], ['default:', '', ''], ['/**', '', ''],
    [' * a', '', '/**'], ['guard let x = y else {', '}', ''], ['/// doc', 'more', ''], ['/// doc', '', ''],
  ]],
  // BL3 — SQL. VS Code sql 설정엔 `indentationRules` 도 `onEnterRules` 도 없다 — 괄호 기본 규칙뿐이다. Dart 는 VS Code 내장이 없어 대조하지 않는다.
  sql: ['sql', [
    ['CREATE TABLE t (', ')', ''], ['CREATE TABLE t (', '', ''], ['SELECT f(a, ', '', ''], ['WHERE id IN (', ')', ''], ['SELECT a', '', ''],
    ['-- note', 'more', ''], ['-- (', '', ''], ["SELECT '('", '', ''], ['BEGIN', '', ''], ['CASE', '', ''], ['/**', '', ''], [' * a', '', '/**'],
  ]],
};

const zs = (s) => '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\t/g, '\\t').replace(/\n/g, '\\n') + '"';
const out = [];
out.push('//! VS Code Enter 대조 말뭉치 — **생성 파일**(`tools/editor/vscode_enter_oracle.mjs`, VS Code 커밋 `' + PIN + '`).');
out.push('//! VS Code 내장 언어 설정을 원래 의미(JS RegExp)로 돌린 답만 담는다(규칙 원문은 없다). 손으로 고치지 않는다 — 말뭉치를 바꾸면 다시 만든다.');
out.push('//! 판정자 `INDR*`(`enter_rules.zig`)가 우리 `decide` 와 대조한다 — 갈리는 것은 그 판정자의 「의도한 차이」 목록에 이유와 함께 있어야 한다.');
out.push('const language = @import("language.zig");');
out.push('');
out.push('pub const Expect = struct { grammar: language.Grammar, before: []const u8, after: []const u8, prev: []const u8, indent: []const u8, append: []const u8, remove: u8 };');
out.push('');
out.push('pub const cases = [_]Expect{');
for (const [g, [cfgName, rows]] of Object.entries(corpus)) {
  const cfg = load(cfgName);
  for (const [b, a, p] of rows) {
    const r = vscodeEnter(cfg, b, a, p);
    out.push(`    .{ .grammar = .${g}, .before = ${zs(b)}, .after = ${zs(a)}, .prev = ${zs(p)}, .indent = ${zs(r.indent)}, .append = ${zs(r.append)}, .remove = ${r.remove} },`);
  }
}
out.push('};');
console.log(out.join('\n'));
