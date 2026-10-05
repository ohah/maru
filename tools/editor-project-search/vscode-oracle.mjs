#!/usr/bin/env node
// reference는 제품에 복사하지 않고 읽기 전용 경로의 실제 Searcher를 opt-in으로 실행한다.
// 공통 문법·단일 줄 subject의 기본 단어/빈 일치 계약만 검증하며 전체 엔진 동등성을 주장하지 않는다.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { stripTypeScriptTypes } from 'node:module';
import { spawnSync } from 'node:child_process';
const [nativeArg, sourceArg, outputArg] = process.argv.slice(2);
if (!nativeArg || !sourceArg || !outputArg) throw new Error('native source output 인자가 필요합니다');
const native = path.resolve(nativeArg), source = path.resolve(sourceArg), output = path.resolve(outputArg);
fs.mkdirSync(output, {recursive: false});
const original = fs.readFileSync(source, 'utf8');
const start = original.indexOf('function leftIsWordBounday(');
if (start < 0 || !original.includes('export class Searcher')) throw new Error('reference 진입점을 찾지 못했습니다');
const setup = `const CharCode = {CarriageReturn: 13, LineFeed: 10};
const WordCharacterClass = {Regular: 0};
const strings = {getNextCodePoint: (text, length, index) => text.codePointAt(index) ?? 0};\n`;
const {Searcher} = await import('data:text/javascript,' + encodeURIComponent(setup + stripTypeScriptTypes(original.slice(start), {mode: 'transform'})));
// 공개 기본 구분자 데이터. 구현은 위 reference에서 실행하고 Maru 코드를 oracle로 호출하지 않는다.
const separators = new Set(Array.from(' \t$#@!%^&*()-=+[]{}\\|;:\'",.<>/?`~', c => c.charCodeAt(0)));
const classifier = {get: unit => separators.has(unit) ? 1 : 0};
const texts = ['', 'foo', 'foo$bar', 'foo😀bar', 'foo_bar', '한foo글', 'foo bar', '--', 'foo\tbar', 'foo\u00a0bar', '😀가', 'afoo ', 'foo foo', 'FOO foo', '가가é é'];
const queries = ['foo', 'FOO', '-', '--', 'foo bar', '^|foo', 'foo|^', '(?=foo)|foo', 'foo|(?=foo)', '^$', '^', '$', '.*', '.*?', 'a*', 'a??', 'foo|$', 'foo |$', '(foo)?', 'foo(?=bar)', '(?<=foo)bar', '가|$', 'é'];
const cases = [];
for (const text of texts) for (const query of queries) for (const whole of [false, true]) for (const fold of [false, true]) {
    const regex = new RegExp(query, 'gmu' + (fold ? 'i' : ''));
    const searcher = new Searcher(whole ? classifier : null, regex);
    const expected = [];
    let match;
    while ((match = searcher.next(text))) {
        const lo = Buffer.byteLength(text.slice(0, match.index));
        expected.push([lo, lo + Buffer.byteLength(match[0])]);
        if (expected.length > 1000) throw new Error('oracle 순회 상한 초과');
    }
    const body = path.join(output, 'body');
    fs.writeFileSync(body, text);
    const paths = path.join(output, 'paths');
    fs.writeFileSync(paths, body + '\0');
    const mode = 'document-regex' + (whole ? '-word' : '') + (fold ? '-fold' : '');
    const result = spawnSync(native, [paths, query, mode, '--offsets'], {encoding: 'utf8', timeout: 20000});
    if (result.status !== 0) throw new Error(result.stderr || String(result.error));
    const found = JSON.parse(result.stdout.split('\n')[0]).offsets;
    const equal = JSON.stringify(expected) === JSON.stringify(found);
    cases.push({text, query, whole, fold, expected, found, equal});
}
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const report = {status: cases.every(c => c.equal) ? 'passed' : 'failed', cases: cases.length,
    source_sha256: hash(source), script_sha256: hash(import.meta.filename), native_sha256: hash(native),
    scope: 'actual VS Code Searcher, default separators, single-line subjects, shared regex syntax; no full engine/newline/UI equivalence claim',
    differences: cases.filter(c => !c.equal)};
fs.writeFileSync(path.join(output, 'oracle.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report));
if (report.status !== 'passed') process.exitCode = 1;
