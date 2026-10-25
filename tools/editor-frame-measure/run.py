#!/usr/bin/env python3
"""제품 소스 사본의 편집·프레임 책임별 시간을 중첩을 보존해 기록한다."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('storage_measure', ROOT / 'tools/editor-storage-measure/run.py')
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)
base = storage.base
spec = importlib.util.spec_from_file_location('frame_contract', Path(__file__).with_name('contract.py'))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
STAGES = contract.STAGES
SYNTAX_STAGES = contract.LEGACY_SYNTAX_STAGES

def setup(repo, output, deps, mode):
    source = storage.setup(repo, output, deps, mode)
    p = source / 'src/platform/macos/app_session/editor/mod.zig'
    text = p.read_text()
    for index, name in enumerate(STAGES):
        if name in ('foldSpansCached', 'syntaxEdit'):
            continue
        if name == 'buildPaneOps':
            anchor = re.search(r'^pub fn buildPaneOps\([\s\S]*?\n\) PaneFrame \{\n', text, re.MULTILINE).group(0)
        else:
            matches = re.findall(r'^(?:pub )?fn ' + name + r'\([^\n]*\) [^\n]+\{\n', text, re.MULTILINE)
            if len(matches) != 1:
                raise RuntimeError('Ambiguous function boundary: ' + name)
            anchor = matches[0]
        text = base.once(text, anchor, anchor + f'    const frame_probe_start = frameProbeNow();\n    defer frame_probe_ns[{index}] += frameProbeNow() - frame_probe_start;\n')
    call = '    prov.foldSpansCached(self.allocator, &st.folds, doc.file.lines.lines, &spans) catch return;'
    query_slot = STAGES.index('foldSpansCached')
    text = base.once(text, call, '    {\n        const frame_inner_start = frameProbeNow();\n' + f'        defer frame_probe_ns[{query_slot}] += frameProbeNow() - frame_inner_start;\n' + call + '\n    }')
    parse_slot = STAGES.index('syntaxEdit')
    if '    refreshSyntaxForInput(self, term, edit);' in text:
        call = '    refreshSyntaxForInput(self, term, edit);'
        text = base.once(text, call, '    {\n        const frame_inner_start = frameProbeNow();\n' + f'        defer frame_probe_ns[{parse_slot}] += frameProbeNow() - frame_inner_start;\n' + call + '\n    }')
    else:
        begin_anchor = '    if (edit) |e|\n        syntax_color.onEditSpan'
        end_anchor = '        syntax_color.reparse(&term.rt.editor_syntax, doc.file.content);'
        if text.count(begin_anchor) != 1 or text.count(end_anchor) != 1:
            raise RuntimeError('Ambiguous syntax edit interval')
        begin = text.index(begin_anchor)
        end = text.index(end_anchor, begin) + len(end_anchor)
        text = text[:begin] + '    {\n        const frame_inner_start = frameProbeNow();\n' + f'        defer frame_probe_ns[{parse_slot}] += frameProbeNow() - frame_inner_start;\n' + text[begin:end] + '\n    }' + text[end:]
    text += f'\nvar frame_probe_ns: [{len(STAGES)}]i128 = @splat(0);\nfn frameProbeNow() i128 {{ return std.Io.Clock.awake.now(std.testing.io).nanoseconds; }}\n'
    text = base.once(text, '        storage_view_ns = 0;\n        const start =', f'        storage_view_ns = 0;\n        frame_probe_ns = @splat(0);\n        syntax_color.frame_syntax_ns = @splat(0);\n        syntax_color.frame_syntax_calls = @splat(0);\n        syntax_color.syntax.frame_parse_ns = 0;\n        const start =')
    anchor = '''        if (std.mem.eql(u8, kind, "command")) {
            promoteFoldRangesToSyntax(s,term);
            _ = foldAll(s);
        }
        var frame ='''
    text = base.once(text, anchor, anchor.replace('        var frame =', '        const frame_edit_ns = frameProbeNow() - start;\n        var frame ='))
    warm = '    if (std.mem.eql(u8, kind, "folded")) try testing.expect(foldAll(s));'
    warm_code = '''    for ([_]?*Term{term, peer}) |maybe| if (maybe) |view| {
        const current = view.rt.editorDocument().opened.?;
        try syntax_color.finishBrackets(&view.rt.editor_syntax, a, current.file.content);
        _ = syntax_color.advanceBrackets(&view.rt.editor_syntax, a, current.file.content, s.loaded_config.config.editor.bracket_pair_colorization_independent_pools);
        try testing.expect(view.rt.editor_syntax.brackets.ready);
        try testing.expect(view.rt.editor_syntax.bracket_resolved != null);
    };
    std.debug.print("FRAME_WARM bracket_ready=1 views={d}\\n", .{@as(usize, if (peer != null) 2 else 1)});
'''
    text = base.once(text, warm, warm_code + warm)
    schema = 2 if '    var copied_brackets = false;' in (source / 'src/platform/macos/app_session/editor/syntax.zig').read_text() else 1
    syntax_stages = contract.syntax_stages(schema)
    anchor = '        const live_doc = term.rt.editorDocument().opened.?;'
    fields = ' '.join(f'{name}={{d}}' for name in STAGES + syntax_stages)
    values = ', '.join(f'frame_probe_ns[{i}]' for i in range(len(STAGES)))
    values += ', ' + ', '.join(f'syntax_color.frame_syntax_ns[{i}]' for i in range(4)) + ', syntax_color.syntax.frame_parse_ns'
    calls_marker = ('        std.debug.print("FRAME_CALLS key={d} providerEdit_calls={d} bracketUpdate_calls={d}\\n", .{i, syntax_color.frame_syntax_calls[1], syntax_color.frame_syntax_calls[3]});\n' if schema == 2 else '')
    text = base.once(text, anchor, f'        std.debug.print("FRAME key={{d}} edit_ns={{d}} {fields}\\n", .{{i, frame_edit_ns, {values}}});\n' + calls_marker + anchor)
    p.write_text(text)
    p = source / 'src/platform/macos/app_session/editor/syntax.zig'
    syn = p.read_text()
    syn += '\npub var frame_syntax_ns: [4]i128 = @splat(0);\npub var frame_syntax_calls: [4]u64 = @splat(0);\nfn frameSyntaxNow() i128 { return std.Io.Clock.awake.now(std.testing.io).nanoseconds; }\n'
    calls = [
        '    self.brackets.shift(allocator, start, old_end, new_end);',
        '    p.onEdit(source, edit);',
        '    if (p.tree != null) self.folds.edit(edit) else self.folds.invalidate();',
        '    self.brackets.refresh(allocator, p, source, .{ .start = start, .end = new_end }) catch self.brackets.invalidate();',
    ]
    # helper 안의 native fallback만 감싸면 성공한 복사 시간을 빠뜨린다.
    if '    editProvider(p, source, edit, parsed, trace);' in syn:
        calls[1] = '    editProvider(p, source, edit, parsed, trace);'
    elif '    editProvider(p, source, edit, ready, trace);' in syn:
        calls[1] = '    editProvider(p, source, edit, ready, trace);'
    elif '    editProvider(p, source, edit, ready);' in syn:
        calls[1] = '    editProvider(p, source, edit, ready);'
    elif 'fn editProvider(' in syn:
        raise RuntimeError('Unknown common provider edit invocation')
    if schema == 2:
        # 복사 성공과 기존 refresh 복귀를 같은 비중첩 구간으로 잰다.
        begin = '    var copied_brackets = false;'
        end = '    } else self.brackets.refresh(allocator, p, source, .{ .start = start, .end = new_end }) catch self.brackets.invalidate();'
        if syn.count(begin) != 1 or syn.count(end) != 1:
            raise RuntimeError('Ambiguous shared bracket update interval')
        first = syn.index(begin)
        last = syn.index(end, first) + len(end)
        calls[3] = syn[first:last]
    for index, call in enumerate(calls):
        syn = base.once(syn, call, f'    const frame_syntax_start_{index} = frameSyntaxNow();\n' + call + f'\n    frame_syntax_ns[{index}] += frameSyntaxNow() - frame_syntax_start_{index};\n    frame_syntax_calls[{index}] += 1;')
    p.write_text(syn)
    p = source / 'src/syntax/tree_sitter.zig'
    syn = p.read_text()
    call = '        const next = c.ts_parser_parse_with_options(self.parser, old_tree, input, opts);'
    syn = base.once(syn, call, '        const frame_native_start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;\n' + call + '\n        frame_parse_ns += std.Io.Clock.awake.now(std.testing.io).nanoseconds - frame_native_start;')
    syn += '\npub var frame_parse_ns: i128 = 0;\n'
    p.write_text(syn)
    manifest = output / 'setup-1.json'
    info = json.loads(manifest.read_text())
    for name in ('src/platform/macos/app_session/editor/mod.zig', 'src/platform/macos/app_session/editor/syntax.zig', 'src/syntax/tree_sitter.zig'):
        info['instrumented_sha256'][name] = hashlib.sha256((source / name).read_bytes()).hexdigest()
    info['frame_schema'] = schema
    info['frame_stages'] = STAGES + syntax_stages
    info['frame_bracket_operation'] = 'copy-or-refresh' if schema == 2 else 'refresh'
    info['frame_call_stages'] = ['providerEdit', 'bracketUpdate'] if schema == 2 else []
    info['frame_scope'] = 'Inclusive function times; nested stages must not be added'
    manifest.write_text(json.dumps(info, indent=2) + '\n')
    return source


if __name__ == '__main__':
    if '--modes' not in sys.argv:
        sys.argv.extend(['--modes', '1'])
    if '--workloads' not in sys.argv:
        sys.argv.extend(['--workloads', 'typing,structure,paste,undo,shared'])
    base.setup = setup
    base.main()
