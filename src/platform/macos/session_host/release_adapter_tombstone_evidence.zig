//! Canonical evidence emitted only after the signed candidate preserves one ended runtime across
//! two ordinary AppKit Quit cycles. The leaf records observations; its filename is not authority.

const std = @import("std");
const upgrade_limits = @import("upgrade_limits.zig");

pub const schema = "maru.session-host-signed-tombstone-relaunch.v1";
pub const max_bytes: usize = 8 * 1024;

pub const Record = struct {
    schema: []const u8,
    test_uuid: []const u8,
    result: enum { passed },
    candidate_dmg_sha256: []const u8,
    candidate_executable_sha256: []const u8,
    designated_requirement_sha256: []const u8,
    runtime_handle: []const u8,
    runtime_state: enum { ended },
    relaunch_count: u32,
    normal_quit_count: u32,
    final_checkpoint_count: u32,
    checkpoint_first_sha256: []const u8,
    checkpoint_second_sha256: []const u8,
    probe_count: u32,
    attach_count: u32,
    spawn_count: u32,
    output_event_count: u32,
    terminal_input_event_count: u32,
    cleanup_complete: bool,
};

pub fn encode(allocator: std.mem.Allocator, value: Record) ![]u8 {
    try validate(value);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    try json.write(value);
    try output.writer.writeByte('\n');
    if (output.writer.end > max_bytes) return error.RecordTooLarge;
    return output.toOwnedSlice();
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Record) {
    if (bytes.len == 0 or bytes.len > max_bytes or bytes[bytes.len - 1] != '\n')
        return error.NonCanonical;
    var parsed = std.json.parseFromSlice(Record, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer parsed.deinit();
    try validate(parsed.value);
    const canonical = try encode(allocator, parsed.value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) return error.NonCanonical;
    return parsed;
}

fn validate(value: Record) !void {
    if (!std.mem.eql(u8, value.schema, schema) or
        !upgrade_limits.canonicalReleaseTestUuid(value.test_uuid) or
        !lowerHex(value.candidate_dmg_sha256, 64) or
        !lowerHex(value.candidate_executable_sha256, 64) or
        !lowerHex(value.designated_requirement_sha256, 64) or
        !runtimeHandle(value.runtime_handle) or value.relaunch_count != 2 or
        value.normal_quit_count != 2 or value.final_checkpoint_count != 2 or
        !lowerHex(value.checkpoint_first_sha256, 64) or
        !std.mem.eql(u8, value.checkpoint_first_sha256, value.checkpoint_second_sha256) or
        value.probe_count != 0 or value.attach_count != 0 or value.spawn_count != 0 or
        value.output_event_count != 0 or value.terminal_input_event_count != 0 or
        !value.cleanup_complete) return error.InvalidEvidence;
}

fn lowerHex(value: []const u8, expected: usize) bool {
    if (value.len != expected) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn runtimeHandle(value: []const u8) bool {
    return value.len == 65 and value[32] == ':' and lowerHex(value[0..32], 32) and lowerHex(value[33..], 32);
}
