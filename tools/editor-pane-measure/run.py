#!/usr/bin/env python3
"""제품을 바꾸지 않고 pane 안의 준비 함수와 장식 비용을 사본에서 계측한다."""
import hashlib
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('provider_measure', ROOT/'tools/editor-provider-measure/run.py')
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)
original_setup = provider.setup
HOST = 'src/platform/macos/app_session/editor/mod.zig'
HOST_STAGES = ('clampScrollToGeometry', 'symbolPreviewFrame', 'buildLineSeeks', 'diagnosticViews', 'buildSelectionMarks', 'buildOccurrenceMarks', 'inlayWindow', 'buildCaretRows', 'conflictWidgets', 'conflictBands', 'paneDecorations')
MODULE_STAGES = (('sticky.zig', 'compute', 'sticky'), ('guides.zig', 'window', 'guides'), ('brackets.zig', 'marks', 'brackets'))
SYMBOL_STAGES = ('stickySummary', 'stickyChangedRanges', 'stickyAncestors')
STAGES = HOST_STAGES + tuple(x[2] for x in MODULE_STAGES) + SYMBOL_STAGES
EXTRA = {str(Path(HOST).parent/name) for name, _, _ in MODULE_STAGES} | {'src/syntax/symbols.zig'}


def instrument(text, name, index, prefix=''):
    matches = list(re.finditer(r'^(?:pub )?fn '+name+r'\([\s\S]*?\) [^{\n]+ \{\n', text, re.M))
    if len(matches) != 1:
        raise ValueError('Nonunique pane function: '+name)
    anchor = matches[0].group()
    return provider.base.once(text, anchor, anchor+f'    const pane_cost_start = {prefix}paneProbeStart();\n    defer {prefix}paneProbeFinish({index}, pane_cost_start);\n')


def setup(repo, output, deps, mode):
    # 사본/실행 파일의 새 해시로 이전 실행을 잘못 설명하지 않도록 측정 뒤 재준비를 막는다.
    if any(output.glob('run-*.log')) or any(output.glob('verify-*.log')):
        raise ValueError('Measured output cannot be prepared again; use a new directory')
    source = original_setup(repo, output, deps, mode)
    path = source/HOST
    text = path.read_text()
    anchor = 'pub fn appendPaneFrame(self: *AppSession, leaf_rect: maru.session.SplitRect, term: *Term) ?PaneDraw {\n'
    text = provider.base.once(text, anchor, anchor+'    pane_probe_depth += 1;\n    defer pane_probe_depth -= 1;\n')
    for index, name in enumerate(HOST_STAGES):
        text = instrument(text, name, index)
    text += f'''
var pane_probe_depth: usize = 0;
var pane_probe_ns: [{len(STAGES)}]i128 = @splat(0);
var pane_probe_calls: [{len(STAGES)}]u64 = @splat(0);
// 편집 과정의 같은 함수는 제외한다. pane 프레임 내부에서 호출한 비용만 기록한다.
pub fn paneProbeStart() ?i128 {{
    return if (pane_probe_depth != 0) frameProbeNow() else null;
}}
pub fn paneProbeFinish(index: usize, start: ?i128) void {{
    if (start) |value| {{
        pane_probe_ns[index] += frameProbeNow() - value;
        pane_probe_calls[index] += 1;
    }}
}}
'''
    anchor = '        frame_probe_ns = @splat(0);'
    text = provider.base.once(text, anchor, anchor+'\n        std.debug.assert(pane_probe_depth == 0);\n        pane_probe_ns = @splat(0);\n        pane_probe_calls = @splat(0);\n        syntax_color.syntax.pane_symbols.pane_symbol_ns = @splat(0);\n        syntax_color.syntax.pane_symbols.pane_symbol_calls = @splat(0);')
    ordinary = len(STAGES)-len(SYMBOL_STAGES)
    fields = ' '.join(name+'={d} '+name+'_calls={d}' for name in STAGES[:ordinary])
    values = ', '.join(f'pane_probe_ns[{i}], pane_probe_calls[{i}]' for i in range(ordinary))
    symbol_fields = ' '.join(name+'={d} '+name+'_calls={d}' for name in SYMBOL_STAGES)
    symbol_values = ', '.join(f'syntax_color.syntax.pane_symbols.pane_symbol_ns[{i}], syntax_color.syntax.pane_symbols.pane_symbol_calls[{i}]' for i in range(3))
    anchor = '        const live_doc = term.rt.editorDocument().opened.?;'
    # Zig의 한 format 호출 인자 한도를 넘지 않도록 같은 줄을 두 호출로 기록한다.
    text = provider.base.once(text, anchor, '        std.debug.print("PANE key={d} '+fields+'", .{i, '+values+'});\n        std.debug.print(" '+symbol_fields+'\\n", .{'+symbol_values+'});\n'+anchor)
    path.write_text(text)
    info_path = output/'setup-1.json'
    info = json.loads(info_path.read_text())
    for index, (name, function, _) in enumerate(MODULE_STAGES, len(HOST_STAGES)):
        relative = str(Path(HOST).parent/name)
        path = source/relative
        raw = path.read_bytes()
        if raw != (repo/relative).read_bytes():
            raise ValueError('Unexpected pre-instrumentation module: '+name)
        saved = output/'original-product'/relative
        saved.parent.mkdir(parents=True, exist_ok=True)
        saved.write_bytes(raw)
        info['original_sha256'][relative] = hashlib.sha256(raw).hexdigest()
        path.write_text(instrument(raw.decode(), function, index, '@import("mod.zig").'))
        info['instrumented_sha256'][relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    relative = 'src/syntax/symbols.zig'
    path = source/relative
    raw = path.read_bytes()
    if raw != (repo/relative).read_bytes():
        raise ValueError('Unexpected symbol summary source')
    saved = output/'original-product'/relative
    saved.parent.mkdir(parents=True, exist_ok=True)
    saved.write_bytes(raw)
    info['original_sha256'][relative] = hashlib.sha256(raw).hexdigest()
    symbol_text = raw.decode()
    for name, index, indent in (('hasSymbols', 0, '    '), ('ancestors', 2, '')):
        matches = re.findall(r'^'+indent+r'pub fn '+name+r'\([^\n]+\n', symbol_text, re.M)
        if len(matches) != 1:
            raise ValueError('Nonunique symbol function: '+name)
        anchor = matches[0]
        symbol_text = provider.base.once(symbol_text, anchor, anchor+indent+f'    const pane_symbol_start = paneSymbolNow();\n'+indent+f'    pane_symbol_calls[{index}] += 1;\n'+indent+f'    defer pane_symbol_ns[{index}] += paneSymbolNow() - pane_symbol_start;\n')
    anchor = '            const ranges = c.ts_tree_get_changed_ranges(previous, tree, &len);'
    symbol_text = provider.base.once(symbol_text, anchor, '            const pane_ranges_start = paneSymbolNow();\n'+anchor+'\n            pane_symbol_ns[1] += paneSymbolNow() - pane_ranges_start;\n            pane_symbol_calls[1] += 1;')
    symbol_text += '\npub var pane_symbol_ns: [3]i128 = @splat(0);\npub var pane_symbol_calls: [3]u64 = @splat(0);\nfn paneSymbolNow() i128 { return std.Io.Clock.awake.now(std.testing.io).nanoseconds; }\n'
    path.write_text(symbol_text)
    info['instrumented_sha256'][relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    relative = 'src/syntax/tree_sitter.zig'
    path = source/relative
    path.write_text(path.read_text()+'\npub const pane_symbols = symbol_windows;\n')
    info['instrumented_sha256'][relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    info['instrumented_sha256'][HOST] = hashlib.sha256((source/HOST).read_bytes()).hexdigest()
    info.update(pane_schema=2, pane_stages=STAGES, pane_scope='Inclusive pane calls; guides/brackets in paneDecorations; symbol summary/ranges/ancestors in sticky; no GUI/HID or product change')
    info_path.write_text(json.dumps(info, indent=2)+'\n')
    return source


def order_rows(output, prefix, text):
    rows = []
    for line in text.splitlines():
        match = re.fullmatch(r'(\d+) (\d+) ([^ ]+) (typing|shared) (-?\d+)', line)
        if match:
            rep, mode, file, workload, code = match.groups()
            rows.append(dict(repetition=int(rep), mode=int(mode), file=file, workload=workload, returncode=int(code), log=str(output/f'{prefix}-{rep}-{mode}-{file}-{workload}.log')))
    return rows


def record_order(output, prefix, text):
    rows = order_rows(output, prefix, text)
    if not rows:
        return
    # 실제 실행 뒤에 나온 stdout을 보관한다. 미실행 계획을 순서의 증거로 삼지 않는다.
    for suffix, value in (('stdout', text), ('json', json.dumps(rows, indent=2)+'\n')):
        with (output/f'{prefix}-order.{suffix}').open('x') as stream:
            stream.write(value)


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--prefix', default='run')
    parser.add_argument('--run-only', action='store_true')
    parser.add_argument('--refresh', action='store_true')
    args, _ = parser.parse_known_args()
    if args.output is not None and (any(args.output.glob('run-*.log')) or any(args.output.glob('verify-*.log'))):
        if args.refresh or not args.run_only:
            parser.error('Existing measurements require --resume --run-only; use a new directory to rebuild')
    capture = io.StringIO()
    class Tee:
        def write(self, value):
            capture.write(value)
            return sys.__stdout__.write(value)
        def flush(self):
            sys.__stdout__.flush()
    provider.setup = setup
    try:
        with contextlib.redirect_stdout(Tee()):
            provider.main()
    finally:
        if args.output is not None:
            record_order(args.output.resolve(), args.prefix, capture.getvalue())


if __name__ == '__main__':
    main()
