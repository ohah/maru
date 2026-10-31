// 측정 사본 전용. 매 프레임은 짧은 접두부만 검사하고 전체 꼬리는 준비·종료에만 검증한다.
pub var latency_frame: [8]u64 = @splat(0);
var stream_address: usize = 0;
var stream_bytes: usize = 0;
var stream_revision: u64 = 0;
var stream_count: usize = 0;
var stream_tail: [32]u8 = @splat(0);
const stream_text = "@STREAM_TEXT@";
pub fn streamTail(out: []u8) void { @memcpy(out[0..32], stream_tail[0..]); }

fn streamPrefix(bytes: []const u8, address: usize, revision: u64) u64 {
    if (stream_address == 0) return 0;
    if (address != stream_address or bytes.len < stream_bytes) return std.math.maxInt(u64);
    const n = bytes.len - stream_bytes;
    if (n > stream_count or revision != stream_revision + n) return std.math.maxInt(u64);
    if (bytes.len < 4 + n or !std.mem.eql(u8, bytes[0..3], "// ") or bytes[3 + n] != '\n') return std.math.maxInt(u64);
    if (!std.mem.eql(u8, bytes[3..][0..n], stream_text[0..n])) return std.math.maxInt(u64);
    return @intCast(n);
}

pub fn streamStart(self: *AppSession, count: usize) bool {
    if (!self.surface_initialized or count == 0 or count > stream_text.len or self.inputFocus() != .terminal) return false;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return false;
    const state = term.rt.editorDocument();
    const doc = state.opened orelse return false;
    const bytes = doc.file.content;
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "// \n")) return false;
    stream_address = @intFromPtr(state);
    stream_bytes = bytes.len;
    stream_revision = doc.file.revision;
    stream_count = count;
    std.crypto.hash.sha2.Sha256.hash(bytes[3..], &stream_tail, .{});
    return true;
}

pub fn streamFinalValid(self: *AppSession) bool {
    if (!self.surface_initialized or stream_count == 0) return false;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return false;
    const state = term.rt.editorDocument();
    const doc = state.opened orelse return false;
    if (streamPrefix(doc.file.content, @intFromPtr(state), doc.file.revision) != stream_count) return false;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(doc.file.content[3 + stream_count ..], &hash, .{});
    return std.mem.eql(u8, &hash, &stream_tail);
}

pub fn latencyState(self: *AppSession) [8]u64 {
    if (!self.surface_initialized) return @splat(0);
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return @splat(0);
    const state = term.rt.editorDocument();
    const doc = state.opened orelse return @splat(0);
    var ready = true;
    var views: u64 = 0;
    var brackets = true;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |peer| {
        if (peer.kind != .editor or peer.rt.editorDocument() != state) continue;
        views += 1;
        brackets = brackets and @import("editor/syntax.zig").bracketSource(&peer.rt.editor_syntax) != null;
        const s = &peer.rt.editor_syntax;
        ready = ready and !s.pending and s.provider != null and s.provider.?.tree != null;
        if (s.async_view.enabled) ready = ready and s.parse_result != null and s.parse_result.?.tag().input.revision == doc.file.revision;
    };
    return .{ self.metal_buffer.generation, doc.file.revision,
        if (term.rt.editor_preedit.len == 0) 0 else std.hash.Wyhash.hash(0, term.rt.editor_preedit),
        @intFromBool(ready), views, doc.file.content.len,
        @as(u64, @intFromBool(brackets)) | (@as(u64, @intFromBool(term.rt.editor_syntax.async_view.enabled)) << 1),
        if (stream_address != 0 and self.inputFocus() != .terminal) std.math.maxInt(u64) else streamPrefix(doc.file.content, @intFromPtr(state), doc.file.revision) };
}
pub fn latencyStamp(self: *AppSession) void { latency_frame = latencyState(self); }
