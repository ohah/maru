//! Explicit mixed transport; process-pinned v1/v2 profiles remain unchanged.
const std = @import("std");
const protocol = @import("agent_stream_protocol.zig");
const codec = @import("agent_log_generation.zig");
pub const hello_line = "{\"hello\":\"maru-agent-events-mixed\",\"v\":3}";
// Generated pane identities start with a GUI PID or host_, so this control log
// cannot collide with an existing provider writer or splice its partial record.
pub const capability_log_name = "maru_native_transport_v3";
pub const announcement_line = "maru-control\t{\"transport\":3}\n";
pub const resume_spec_max = protocol.resume_spec_max + 2 * protocol.cursor_max;
pub const Entry = struct { profile: protocol.Profile, entry: codec.ResumeEntry };
pub fn isHello(line: []const u8) bool {
    if (line.len > 256) return false;
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), line, .{ .parse_numbers = false }) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const h = parsed.value.object.get("hello") orelse return false;
    const v = parsed.value.object.get("v") orelse return false;
    return h == .string and std.mem.eql(u8, h.string, "maru-agent-events-mixed") and v == .number_string and std.mem.eql(u8, v.number_string, "3");
}
pub fn decodeEntry(text: []const u8) ?Entry {
    if (text.len < 3 or text[1] != ':') return null;
    const profile: protocol.Profile = switch (text[0]) {
        '1' => .v1,
        '2' => .v2,
        else => return null,
    };
    const entry = codec.decodeResumeEntry(text[2..]) catch return null;
    if ((profile == .v2) != (entry.cursor.generation != null)) return null;
    return .{ .profile = profile, .entry = entry };
}
pub fn validResume(spec: []const u8) bool {
    if (spec.len > resume_spec_max) return false;
    if (spec.len == 0) return true;
    var entries: [protocol.cursor_max]Entry = undefined;
    var count: usize = 0;
    var fields = std.mem.splitScalar(u8, spec, ',');
    while (fields.next()) |field| {
        if (count == entries.len) return false;
        const entry = decodeEntry(field) orelse return false;
        for (entries[0..count]) |before| if (before.profile == entry.profile and std.mem.eql(u8, before.entry.name, entry.entry.name)) return false;
        entries[count] = entry;
        count += 1;
    }
    return true;
}
pub fn appendResume(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, name: []const u8, cursor: codec.Cursor, profile: protocol.Profile) !void {
    if ((profile == .v2) != (cursor.generation != null)) return error.ProfileMismatch;
    var buffer: [codec.max_resume_entry_bytes + 2]u8 = undefined;
    buffer[0] = if (profile == .v1) '1' else '2';
    buffer[1] = ':';
    const inner = try codec.encodeResumeEntry(buffer[2..], .{ .name = name, .cursor = cursor });
    const count = inner.len + 2;
    const sep: usize = if (out.items.len == 0) 0 else 1;
    if (out.items.len + sep + count > resume_spec_max) return error.ResumeTooLong;
    try out.ensureUnusedCapacity(a, sep + count);
    if (sep != 0) out.appendAssumeCapacity(',');
    out.appendSliceAssumeCapacity(buffer[0..count]);
}
pub const Envelope = struct { profile: protocol.Profile, frame: []const u8 };
pub fn unwrap(line: []const u8) ?Envelope {
    const p1 = "{\"format\":1,\"frame\":";
    const p2 = "{\"format\":2,\"frame\":";
    if (line.len <= p1.len + 2 or line[line.len - 1] != '}') return null;
    const profile: protocol.Profile = if (std.mem.startsWith(u8, line, p1)) .v1 else if (std.mem.startsWith(u8, line, p2)) .v2 else return null;
    const frame = line[p1.len .. line.len - 1];
    if (frame[0] != '{' or frame[frame.len - 1] != '}') return null;
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    if (!(std.json.validate(fba.allocator(), frame) catch false)) return null;
    return .{ .profile = profile, .frame = frame };
}
/// Flush each complete frame before acknowledging a buffered native batch.
/// stdout backpressure occurs after the native read lease has been released.
pub const Writer = struct {
    writer: std.Io.Writer,
    output: *std.Io.Writer,
    profile: protocol.Profile = .v1,
    pending: [128 * 1024]u8 = undefined,
    used: usize = 0,
    pub fn init(output: *std.Io.Writer) Writer {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} }, .output = output };
    }
    fn put(self: *Writer, bytes: []const u8) std.Io.Writer.Error!void {
        for (bytes) |byte| {
            if (byte == '\n') {
                if (self.used == 0) return error.WriteFailed;
                try self.output.writeAll(if (self.profile == .v1) "{\"format\":1,\"frame\":" else "{\"format\":2,\"frame\":");
                try self.output.writeAll(self.pending[0..self.used]);
                try self.output.writeAll("}\n");
                try self.output.flush();
                self.used = 0;
            } else {
                if (self.used == self.pending.len) return error.WriteFailed;
                self.pending[self.used] = byte;
                self.used += 1;
            }
        }
    }
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("writer", w));
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.put(bytes);
            written += bytes.len;
        }
        for (0..splat) |_| {
            try self.put(data[data.len - 1]);
            written += data[data.len - 1].len;
        }
        return written;
    }
};
test "mixed resume isolates same-name profiles and rejects duplicate and mismatched generations" {
    const t = std.testing;
    const spec = "1:a:7,2:a:9:00112233445566778899aabbccddeeff";
    try t.expect(validResume(spec));
    for ([_][]const u8{ "1:a:7,1:a:8", "2:a:9", "1:a:7:00112233445566778899aabbccddeeff", "3:a:7", "1:a:7," }) |bad| try t.expect(!validResume(bad));
    try t.expect(isHello(hello_line));
    try t.expect(!isHello(protocol.hello(.v2)));
    try t.expect(!isHello("{\"hello\":\"maru-agent-events-mixed\",\"v\":3,\"v\":2}"));
}
test "mixed envelope validates outer identity without decoding opaque payload" {
    const t = std.testing;
    const frame = "{\"nonce\":\"a\",\"line\":\"claude\\t{}\"}";
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer);
    writer.profile = .v2;
    try writer.writer.writeAll(frame ++ "\n");
    const envelope = unwrap(std.mem.trimEnd(u8, out.written(), "\n")).?;
    try t.expectEqual(protocol.Profile.v2, envelope.profile);
    try t.expectEqualStrings(frame, envelope.frame);
    try t.expect(unwrap("{\"format\":1,\"frame\":{},\"format\":2}") == null);
    try t.expect(unwrap("{\"format\":1,\"frame\":{broken}}") == null);
}
