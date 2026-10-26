"""기존 제품 사본에만 native 콜백 진단을 추가한다. 성능 바이너리에는 쓰지 않는다."""
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('native_provider', ROOT / 'tools/editor-provider-measure/run.py')
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)

spec = importlib.util.spec_from_file_location('native_parse_contract', Path(__file__).with_name('contract.py'))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
FIELDS = contract.FIELDS


def setup(repo, output, deps):
    source = provider.setup(repo, output, deps, 1)
    path = source / 'src/syntax/tree_sitter.zig'
    text = path.read_text()
    once = provider.base.once
    # 기존 native 타이머 밖의 호출 자료와 그 안의 콜백 작업량을 구분한다.
    anchor = '        const frame_native_start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;'
    text = once(text, anchor, '''        native_parse_probe.calls += 1;
        native_parse_probe.old_tree_calls += @intFromBool(old_tree != null);
        native_parse_probe.source_bytes += source.len;
        native_parse_probe.budget_ns += budget_ns;
''' + anchor)
    anchor = '        frame_parse_ns += std.Io.Clock.awake.now(std.testing.io).nanoseconds - frame_native_start;'
    text = once(text, anchor, anchor + '''
        if (next != null) native_parse_probe.done += 1 else native_parse_probe.pending += 1;''')
    anchor = '    fn readSlice(payload: ?*anyopaque, byte_index: u32, _: c.TSPoint, bytes_read: [*c]u32) callconv(.c) [*c]const u8 {'
    text = once(text, anchor, anchor + '\n        native_parse_probe.read_calls += 1;')
    text = once(text, '            bytes_read.* = 0;', '            native_parse_probe.eof_calls += 1;\n            bytes_read.* = 0;')
    anchor = '        bytes_read.* = @intCast(ctx.source.len - byte_index);'
    text = once(text, anchor, anchor + '\n        native_parse_probe.offered_bytes += bytes_read.*;')
    anchor = '    fn onProgress(state: [*c]c.TSParseState) callconv(.c) bool {'
    text = once(text, anchor, anchor + '\n        native_parse_probe.progress_calls += 1;')
    text = once(text, '        return monotonicNs() >= ctx.deadline_ns;', '''        const cancelled = monotonicNs() >= ctx.deadline_ns;
        native_parse_probe.cancel_returns += @intFromBool(cancelled);
        return cancelled;''')
    anchor = '        provider_probe_calls[5] += 1;'
    text = once(text, anchor, anchor + '''
        native_parse_probe.range_calls += 1;
        native_parse_probe.range_items += count;
        native_parse_probe.nonempty_ranges += @intFromBool(count > 0);''')
    probe = Path(__file__).with_name('probe.zig.inc').read_text()
    probe = once(probe, '__NATIVE_COUNTER_FIELDS__', ''.join('    ' + name + ': u64 = 0,\n' for name in FIELDS).rstrip())
    text += '\n' + probe
    path.write_text(text)
    host = source / 'src/platform/macos/app_session/editor/mod.zig'
    text = host.read_text()
    anchor = '        syntax_color.syntax.provider_native_calls = 0;'
    text = once(text, anchor, anchor + '\n        syntax_color.syntax.native_parse_probe = .{};')
    fields = ' '.join(name + '={d}' for name in FIELDS)
    values = ', '.join('syntax_color.syntax.native_parse_probe.' + name for name in FIELDS)
    anchor = '        const live_doc = term.rt.editorDocument().opened.?;'
    text = once(text, anchor, '        std.debug.print("NATIVE_PROBE schema=1 key={d} ' + fields + '\\n", .{i, ' + values + '});\n' + anchor)
    host.write_text(text)
    manifest = output / 'setup-1.json'
    info = json.loads(manifest.read_text())
    for name in ('src/syntax/tree_sitter.zig', 'src/platform/macos/app_session/editor/mod.zig'):
        info['instrumented_sha256'][name] = hashlib.sha256((source / name).read_bytes()).hexdigest()
    info['native_probe_schema'] = 1
    info['native_probe_fields'] = list(FIELDS)
    info['native_probe_scope'] = 'Separate diagnostic binary; callback offered bytes are not consumed bytes; do not report diagnostic timings as baseline performance'
    manifest.write_text(json.dumps(info, indent=2) + '\n')
    return source
