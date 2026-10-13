//! Explicit mixed transport; process-pinned v1/v2 profiles remain unchanged.
const std = @import("std");
const protocol = @import("agent_stream_protocol.zig");
const codec = @import("agent_log_generation.zig");
pub const replay_hello_line = "{\"hello\":\"maru-agent-events-mixed-replay\",\"v\":4}";
pub const hello_line = "{\"hello\":\"maru-agent-events-mixed\",\"v\":3}";
// Generated pane identities start with a GUI PID or host_, so this control log
// cannot collide with an existing provider writer or splice its partial record.
pub const capability_log_name = "maru_native_transport_v3";
pub const announcement_line = "maru-control\t{\"transport\":3}\n";
pub const resume_spec_max = protocol.resume_spec_max + 2 * protocol.cursor_max;
/// Complete records that cross the frozen byte boundary are live; a new v2
/// generation never inherits the old generation's replay range.
pub fn isReplayRecord(end: u64, watermark: u64, current: ?codec.Generation, initial: ?codec.Generation) bool {
    const same = if (initial) |generation| if (current) |now| std.mem.eql(u8, &generation, &now) else false else current == null;
    return same and end <= watermark;
}

pub const replay_state_max = resume_spec_max + 21 * protocol.cursor_max;
pub const ReplayState = struct { entry: Entry, inode: u64 };
pub fn decodeReplayState(text: []const u8) ?ReplayState {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const entry = decodeEntry(text[0..colon]) orelse return null;
    const digits = text[colon + 1 ..];
    if (digits.len == 0) return null;
    for (digits) |d| if (d < '0' or d > '9') return null;
    const inode = std.fmt.parseInt(u64, digits, 10) catch return null;
    return .{ .entry = entry, .inode = inode };
}
pub fn validReplayState(text: []const u8) bool {
    if (text.len > replay_state_max) return false;
    if (text.len == 0) return true;
    var seen: [protocol.cursor_max]Entry = undefined;
    var count: usize = 0;
    var fields = std.mem.splitScalar(u8, text, ',');
    while (fields.next()) |field| {
        if (count == seen.len) return false;
        const decoded = decodeReplayState(field) orelse return false;
        for (seen[0..count]) |entry| if (entry.profile == decoded.entry.profile and std.mem.eql(u8, entry.entry.name, decoded.entry.entry.name)) return false;
        seen[count] = decoded.entry;
        count += 1;
    }
    return true;
}
pub fn appendReplayState(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, name: []const u8, cursor: codec.Cursor, profile: protocol.Profile, inode: u64) !void {
    var entry: std.ArrayListUnmanaged(u8) = .empty;
    defer entry.deinit(a);
    try appendResume(&entry, a, name, cursor, profile);
    var suffix_buf: [21]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&suffix_buf, ":{d}", .{inode});
    const separator: usize = if (out.items.len == 0) 0 else 1;
    if (out.items.len + entry.items.len + suffix.len + separator > replay_state_max) return error.ResumeTooLong;
    try out.ensureUnusedCapacity(a, entry.items.len + suffix.len + separator);
    if (separator != 0) out.appendAssumeCapacity(',');
    out.appendSliceAssumeCapacity(entry.items);
    out.appendSliceAssumeCapacity(suffix);
}
pub const Entry = struct { profile: protocol.Profile, entry: codec.ResumeEntry };
pub fn isReplayHello(line: []const u8) bool {
    return std.mem.eql(u8, line, replay_hello_line);
}
pub fn isHello(line: []const u8) bool {
    if (isReplayHello(line)) return true;
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
pub const Envelope = struct { profile: protocol.Profile, frame: []const u8, replay: bool = false, explicit_replay: bool = false };
pub fn unwrap(line: []const u8) ?Envelope {
    if (line.len < 2 or line[0] != '{') return null;
    const replay = std.mem.startsWith(u8, line, "{\"replay\":true,");
    const live = std.mem.startsWith(u8, line, "{\"replay\":false,");
    const skip: usize = if (replay) 15 else if (live) 16 else 1;
    if (line.len < skip + 1 or line[line.len - 1] != '}') return null;
    const body = line[skip..];
    const p1 = "\"format\":1,\"frame\":";
    const p2 = "\"format\":2,\"frame\":";
    const profile: protocol.Profile = if (std.mem.startsWith(u8, body, p1)) .v1 else if (std.mem.startsWith(u8, body, p2)) .v2 else return null;
    const frame = line[skip + p1.len .. line.len - 1];
    if (frame.len < 2) return null;
    if (frame[0] != '{' or frame[frame.len - 1] != '}') return null;
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    if (!(std.json.validate(fba.allocator(), frame) catch false)) return null;
    return .{ .profile = profile, .frame = frame, .replay = replay, .explicit_replay = replay or live };
}
/// Flush each complete frame before acknowledging a buffered native batch.
/// stdout backpressure occurs after the native read lease has been released.
pub const Writer = struct {
    writer: std.Io.Writer,
    output: *std.Io.Writer,
    profile: protocol.Profile = .v1,
    replay_mode: bool = false,
    replay: bool = false,
    replay_at: u64 = 0,
    replay_inode: u64 = 0,
    replay_generation: ?codec.Generation = null,
    pending: [128 * 1024]u8 = undefined,
    used: usize = 0,
    pub fn init(output: *std.Io.Writer) Writer {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} }, .output = output };
    }
    fn put(self: *Writer, bytes: []const u8) std.Io.Writer.Error!void {
        for (bytes) |byte| {
            if (byte == '\n') {
                if (self.used == 0) return error.WriteFailed;
                if (self.replay_mode) try self.output.writeAll(if (self.replay) "{\"replay\":true," else "{\"replay\":false,");
                const prefix = if (self.profile == .v1) "{\"format\":1,\"frame\":" else "{\"format\":2,\"frame\":";
                try self.output.writeAll(if (self.replay_mode) prefix[1..] else prefix);
                const cursor = self.replay_mode and std.mem.startsWith(u8, self.pending[0..self.used], "{\"cur\":");
                try self.output.writeAll(self.pending[0 .. self.used - @as(usize, if (cursor) 1 else 0)]);
                if (cursor) {
                    try self.output.print(",\"replay_at\":{d},\"replay_inode\":{d}", .{ self.replay_at, self.replay_inode });
                    if (self.replay_generation) |g| try self.output.print(",\"replay_gen\":\"{s}\"", .{codec.encodeGeneration(g)});
                    try self.output.writeByte('}');
                }
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

// An independent round trip checks wire spelling, borrowed lifetimes and both profiles.
test "mixed replay envelopes preserve old wire and explicit live classification" {
    const t = std.testing;
    const frame = "{\"nonce\":\"a\",\"line\":\"claude\\t{}\"}";
    for ([_]protocol.Profile{ .v1, .v2 }) |profile| {
        for ([_]bool{ false, true }) |replay| {
            var out: std.Io.Writer.Allocating = .init(t.allocator);
            defer out.deinit();
            var writer = Writer.init(&out.writer);
            writer.profile = profile;
            writer.replay_mode = true;
            writer.replay = replay;
            try writer.writer.writeAll(frame ++ "\n");
            const line = std.mem.trimEnd(u8, out.written(), "\n");
            const decoded = unwrap(line).?;
            try t.expectEqual(replay, decoded.replay);
            try t.expectEqual(profile, decoded.profile);
            try t.expectEqualStrings(frame, decoded.frame);
            try t.expect(@intFromPtr(decoded.frame.ptr) >= @intFromPtr(line.ptr));
        }
    }
    for ([_][]const u8{
        "{\"replay\":1,\"format\":1,\"frame\":{}}",
        "{\"replay\":true,\"format\":1,\"frame\":{},\"replay\":false}",
        "{\"replay\":true,\"format\":1,\"frame\":}",
    }) |bad| try t.expect(unwrap(bad) == null);
    try t.expect(isReplayHello(replay_hello_line));
    try t.expect(!isReplayHello(hello_line));
}

test "mixed replay state survives interrupted startup and remains bounded and unique" {
    const t = std.testing;
    const gen = try codec.decodeGeneration("00112233445566778899aabbccddeeff");
    var state: std.ArrayListUnmanaged(u8) = .empty;
    defer state.deinit(t.allocator);
    try appendReplayState(&state, t.allocator, "same", .{ .offset = 12 }, .v1, 123);
    try appendReplayState(&state, t.allocator, "same", .{ .offset = 34, .generation = gen }, .v2, 0);
    try t.expect(validReplayState(state.items));
    try t.expectEqual(@as(u64, 123), decodeReplayState("1:same:12:123").?.inode);
    for ([_][]const u8{ "1:same:12:123,1:same:12:124", "1:same:12:-1", "2:same:34:0", "1:same:12:18446744073709551616" }) |bad| try t.expect(!validReplayState(bad));
}

test "mixed replay classification rejects generation replacement and straddling partial records" {
    const t = std.testing;
    const before = try codec.decodeGeneration("00112233445566778899aabbccddeeff");
    const after = try codec.decodeGeneration("ffeeddccbbaa99887766554433221100");
    try t.expect(isReplayRecord(100, 100, before, before));
    try t.expect(!isReplayRecord(101, 100, before, before));
    try t.expect(!isReplayRecord(1, 100, after, before));
    try t.expect(!isReplayRecord(1, 100, before, null));
    try t.expect(isReplayRecord(100, 100, null, null));
}
