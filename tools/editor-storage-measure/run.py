#!/usr/bin/env python3
"""EW2 이후 실제 편집의 저장소·줄 갱신을 private 사본에서 분리 계측한다."""
import importlib.util
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('fold_product', ROOT / 'tools/editor-fold-product/run.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
original_setup = base.setup


def setup(repo, output, deps, mode):
    if mode != 1:
        raise ValueError('Storage attribution requires production cache mode 1')
    source = original_setup(repo, output, deps, mode)
    p = source / 'src/session/editor/edit_doc.zig'
    s = p.read_text()
    s += '''
// private 계측 전용. 각 입력 직전에 초기화하며 제품에는 추가하지 않는다.
pub var storage_ns: [3]i128 = .{0, 0, 0};
fn storageNow() i128 { return std.Io.Clock.awake.now(std.testing.io).nanoseconds; }
'''
    s = base.once(s, '        const snap = self.buf.snapshot();', '        var storage_start = storageNow();\n        const snap = self.buf.snapshot();')
    s = base.once(s, '        const next_content = self.buf.copyAll(self.allocator) catch |err| {', '        storage_ns[0] += storageNow() - storage_start;\n        storage_start = storageNow();\n        const next_content = self.buf.copyAll(self.allocator) catch |err| {')
    s = base.once(s, '        const next_lines = line_index.build(self.allocator, next_content) catch |err| {', '        storage_ns[1] += storageNow() - storage_start;\n        storage_start = storageNow();\n        const next_lines = line_index.build(self.allocator, next_content) catch |err| {')
    s = base.once(s, '        {\n            // 성공 — 옛 판을 놓는다.', '        storage_ns[2] += storageNow() - storage_start;\n        {\n            // 성공 — 옛 판을 놓는다.')
    p.write_text(s)
    p = source / 'src/platform/macos/app_session/editor/mod.zig'
    s = p.read_text()
    # 줄 배열 구간만 잰다. 구문 파싱이나 후속 접힘/폭 재구축은 포함하지 않는다.
    anchor = '    // ⑴ 줄 배열 — 줄 수가 바뀌었을 수 있으므로 다시 잡는다.'
    s = base.once(s, anchor, '    const storage_lines_start = std.Io.Clock.awake.now(self.io).nanoseconds;\n' + anchor)
    s = base.once(s, '    // **폭 캐시: 살리거나 버리거나.**', '    storage_view_ns += std.Io.Clock.awake.now(self.io).nanoseconds - storage_lines_start;\n    // **폭 캐시: 살리거나 버리거나.**')
    s += '\npub var storage_view_ns: i128 = 0;\n'
    s = base.once(s, '        const start = std.Io.Clock.awake.now(s.io).nanoseconds;\n        if (undo_case', '        maru.session.editor.edit_doc.storage_ns = .{0, 0, 0};\n        storage_view_ns = 0;\n        const start = std.Io.Clock.awake.now(s.io).nanoseconds;\n        if (undo_case')
    anchor = '        samples[i] = @intCast(std.Io.Clock.awake.now(s.io).nanoseconds - start);'
    s = base.once(s, anchor, anchor + '''
        const live_doc = term.rt.editorDocument().opened.?;
        const storage = maru.session.editor.edit_doc.storage_ns;
        std.debug.print("STORAGE key={d} total_ns={d} delta_ns={d} copy_ns={d} index_ns={d} view_lines_ns={d} bytes={d} lines={d}\\n", .{i, samples[i], storage[0], storage[1], storage[2], storage_view_ns, live_doc.file.content.len, live_doc.file.lineCount()});
''')
    s = base.once(s, '        // 두 뷰 모두 대조한다.', '        if (verify_each_edit) {\n            if (!undo_case and !bulk) try testing.expectEqual(source.len + (i + 1) * @as(usize, if (structural) 3 else 1), live_doc.file.content.len);\n            const copied = try live_doc.file.buf.copyAll(a);\n            defer a.free(copied);\n            try testing.expectEqualStrings(copied, live_doc.file.content);\n            for ([_]?*Term{term, peer}) |maybe| if (maybe) |view| {\n                try testing.expectEqual(live_doc.file.lineCount(), view.rt.editor_lines.len);\n                for (view.rt.editor_lines, 0..) |line, row| try testing.expectEqualStrings(live_doc.file.lineText(row).?, line);\n            };\n        }\n        // 두 뷰 모두 대조한다.')
    p.write_text(s)
    p = source / 'src/platform/macos/app_session/editor/shared_edit.zig'
    shared = p.read_text()
    anchor = '            for (0..self.line_count) |i| v.lines[i] = self.term.rt.editorDocument().opened.?.file.lineText(i) orelse "";'
    shared = base.once(shared, anchor, '            const storage_start = std.Io.Clock.awake.now(self.session.io).nanoseconds;\n' + anchor)
    shared = base.once(shared, '            v.term.rt.editor_lines = v.lines;', '            v.term.rt.editor_lines = v.lines;\n            editor_ops.storage_view_ns += std.Io.Clock.awake.now(self.session.io).nanoseconds - storage_start;')
    p.write_text(shared)
    # 원본/계측 해시는 기존 manifest에 저장소 계측 파일까지 포함해 기록한다.
    import hashlib, json
    manifest = output / f'setup-{mode}.json'
    info = json.loads(manifest.read_text())
    for name in ('src/session/editor/edit_doc.zig', 'src/platform/macos/app_session/editor/mod.zig', 'src/platform/macos/app_session/editor/shared_edit.zig'):
        info['original_sha256'][name] = hashlib.sha256((repo / name).read_bytes()).hexdigest()
        info['instrumented_sha256'][name] = hashlib.sha256((source / name).read_bytes()).hexdigest()
    info['scope'] = 'delta including snapshot; copyAll; line_index.build; view line array only; nested in total'
    manifest.write_text(json.dumps(info, indent=2) + '\n')
    return source


if __name__ == '__main__':
    if '--modes' not in sys.argv:
        sys.argv.extend(['--modes', '1'])
    if '--workloads' not in sys.argv:
        sys.argv.extend(['--workloads', 'typing,structure,paste,undo,shared'])
    base.setup = setup
    base.main()
