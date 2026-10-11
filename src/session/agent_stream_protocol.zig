//! Negotiated log profile and bounded metadata. Payload events remain opaque.
const std = @import("std");
const codec = @import("agent_log_generation.zig");
const command = @import("agent_hook_command.zig");
pub const Profile = @import("agent_log_profile.zig").Profile;
pub const cursor_max = 32;
pub const resume_spec_max = codec.resumeBytesBound(cursor_max) catch @compileError("resume budget overflow");

pub fn hello(profile: Profile) []const u8 {
    return switch (profile) {
        .v1 => "{\"hello\":\"maru-agent-events\",\"v\":1}",
        .v2 => "{\"hello\":\"maru-agent-events-v2\",\"v\":2}",
    };
}

pub fn parseHello(line: []const u8, required: ?Profile) ?Profile {
    if (line.len > 256) return null;
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), line, .{ .parse_numbers = false }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const marker = parsed.value.object.get("hello") orelse return null;
    const version = parsed.value.object.get("v") orelse return null;
    if (marker != .string or version != .number_string) return null;
    const profile: Profile = if (std.mem.eql(u8, marker.string, "maru-agent-events") and std.mem.eql(u8, version.number_string, "1")) .v1 else if (std.mem.eql(u8, marker.string, "maru-agent-events-v2") and std.mem.eql(u8, version.number_string, "2")) .v2 else return null;
    if (required) |expected| if (expected != profile) return null;
    return profile;
}

pub const Cursor = struct { name: []const u8, offset: u64, generation: ?codec.Generation = null };
pub fn parseCursor(line: []const u8, profile: Profile) ?Cursor {
    if (line.len > 512) return null;
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), line, .{ .parse_numbers = false }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const name = parsed.value.object.get("cur") orelse return null;
    const at = parsed.value.object.get("at") orelse return null;
    if (name != .string or at != .number_string) return null;
    // Only canonical, unescaped filename strings are emitted. Return a slice of
    // the input, never a decoded string allocated in this function's scratch.
    const key = "\"cur\":\"";
    const start = (std.mem.indexOf(u8, line, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    const borrowed = line[start..end];
    if (!std.mem.eql(u8, borrowed, name.string) or borrowed.len > command.remote_log_name_max or !command.instance_token_class.accepts(borrowed)) return null;
    for (at.number_string) |byte| if (byte < '0' or byte > '9') return null;
    const offset = std.fmt.parseInt(u64, at.number_string, 10) catch return null;
    const field_gen = parsed.value.object.get("gen");
    const generation = switch (profile) {
        .v1 => if (field_gen == null) null else return null,
        .v2 => if (field_gen) |value| if (value == .string) codec.decodeGeneration(value.string) catch return null else return null else return null,
    };
    return .{ .name = borrowed, .offset = offset, .generation = generation };
}

pub fn appendResume(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, name: []const u8, cursor: codec.Cursor, profile: Profile) !void {
    if ((profile == .v2) != (cursor.generation != null)) return error.ProfileMismatch;
    var buffer: [codec.max_resume_entry_bytes]u8 = undefined;
    const encoded = try codec.encodeResumeEntry(&buffer, .{ .name = name, .cursor = cursor });
    const separator: usize = if (out.items.len == 0) 0 else 1;
    if (out.items.len + encoded.len + separator > resume_spec_max) return error.ResumeTooLong;
    try out.ensureUnusedCapacity(allocator, encoded.len + separator);
    if (separator != 0) out.appendAssumeCapacity(',');
    out.appendSliceAssumeCapacity(encoded);
}

pub fn resumeIsValid(spec: []const u8, profile: Profile) bool {
    if (spec.len > resume_spec_max) return false;
    if (spec.len == 0) return true;
    var names: [cursor_max][]const u8 = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, spec, ',');
    while (parts.next()) |part| {
        if (count == names.len) return false;
        const entry = codec.decodeResumeEntry(part) catch return false;
        for (names[0..count]) |name| if (std.mem.eql(u8, name, entry.name)) return false;
        names[count] = entry.name;
        count += 1;
        if ((profile == .v2) != (entry.cursor.generation != null)) return false;
    }
    return true;
}

const testing = std.testing;
const gen = "00112233445566778899aabbccddeeff";
test "hello negotiates one exact marker/version and never downgrades a required profile" {
    try testing.expectEqual(Profile.v1, parseHello(hello(.v1), null).?);
    try testing.expectEqual(Profile.v2, parseHello(hello(.v2), null).?);
    try testing.expect(parseHello(hello(.v1), .v2) == null);
    for ([_][]const u8{ "{\"hello\":\"maru-agent-events\",\"v\":2}", "{\"hello\":\"maru-agent-events-v2\",\"v\":1}", "{\"hello\":\"maru-agent-events-v2\",\"v\":2,\"v\":1}", "{\"hello\":\"maru-agent-events\"}", "{\"hello\":\"maru-agent-events\",\"v\":1}x" }) |bad| try testing.expect(parseHello(bad, null) == null);
}
test "generation cursor keeps full u64 and rejects absent invalid duplicate and legacy gen" {
    const line = "{\"cur\":\"a\",\"at\":18446744073709551615,\"gen\":\"" ++ gen ++ "\"}";
    const cur = parseCursor(line, .v2).?;
    try testing.expectEqual(std.math.maxInt(u64), cur.offset);
    try testing.expectEqualStrings("a", cur.name);
    try testing.expect(@intFromPtr(cur.name.ptr) >= @intFromPtr(line.ptr) and @intFromPtr(cur.name.ptr) < @intFromPtr(line.ptr) + line.len);
    try testing.expect(parseCursor(line, .v1) == null);
    try testing.expect(parseCursor("{\"cur\":\"a\",\"at\":0,\"g\\u0065n\":null}", .v1) == null);
    try testing.expect(parseCursor("{\"cur\":\"a\",\"at\":18446744073709551616,\"gen\":\"" ++ gen ++ "\"}", .v2) == null);
    try testing.expect(parseCursor("{\"cur\":\"a\",\"at\":1e3,\"gen\":\"" ++ gen ++ "\"}", .v2) == null);
    for ([_][]const u8{ "{\"cur\":\"a\",\"at\":0}", "{\"cur\":\"a\",\"at\":0,\"gen\":null}", "{\"cur\":\"a\",\"at\":0,\"gen\":\"BAD\"}", "{\"cur\":\"a\",\"at\":0,\"gen\":\"" ++ gen ++ "\",\"gen\":\"" ++ gen ++ "\"}", "{\"cur\":\"a\",\"at\":1.0,\"gen\":\"" ++ gen ++ "\"}", "{\"cur\":\"a\",\"at\":0,\"meta\":{\"gen\":\"" ++ gen ++ "\"}}" }) |bad| try testing.expect(parseCursor(bad, .v2) == null);
}
test "32 maximum generation cursors fit the shared budget without stripping ids" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    var name = ("a" ** command.remote_log_name_max).*;
    for (0..cursor_max) |i| {
        name[0] = "abcdefghijklmnopqrstuvwxyz012345"[i];
        try appendResume(&out, testing.allocator, &name, .{ .offset = std.math.maxInt(u64), .generation = try codec.decodeGeneration(gen) }, .v2);
    }
    try testing.expectEqual(resume_spec_max, out.items.len);
    try testing.expect(resumeIsValid(out.items, .v2));
    try testing.expect(!resumeIsValid(out.items, .v1));
    try testing.expectError(error.ProfileMismatch, appendResume(&out, testing.allocator, "a", .{ .offset = 0, .generation = null }, .v2));
}

test "resume construction failure leaves existing complete entries unchanged" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendResume(&out, testing.allocator, "a", .{ .offset = 1, .generation = try codec.decodeGeneration(gen) }, .v2);
    const before = try testing.allocator.dupe(u8, out.items);
    defer testing.allocator.free(before);
    // One spare byte is the dangerous case: a separator could succeed before
    // the complete entry allocation fails. Test it as well as zero spare bytes.
    for ([_]usize{ 0, 1 }) |spare| {
        out.shrinkAndFree(testing.allocator, out.items.len);
        try out.ensureTotalCapacityPrecise(testing.allocator, out.items.len + spare);
        try testing.expectEqual(out.items.len + spare, out.capacity);
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        try testing.expectError(error.OutOfMemory, appendResume(&out, failing.allocator(), "b", .{ .offset = 2, .generation = try codec.decodeGeneration(gen) }, .v2));
        try testing.expectEqualStrings(before, out.items);
    }
    try testing.expect(!resumeIsValid("a:1,a:2", .v1));
}
