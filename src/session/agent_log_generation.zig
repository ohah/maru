//! Shared generation/position contract. OS writers supply random bytes; this codec
//! never invents an identity from a PID, clock, file size, or allocation failure.
const std = @import("std");
const command = @import("agent_hook_command.zig");

pub const Generation = [16]u8;
pub const generation_hex_len = 32;
pub const header_magic = "MARU_AGENT_LOG_V2\t";
const magic_family = "MARU_AGENT_LOG_";
pub const header_len = header_magic.len + generation_hex_len + 1;
pub const max_resume_entry_bytes = command.remote_log_name_max + 1 + 20 + 1 + generation_hex_len;

pub const Cursor = struct { generation: ?Generation = null, offset: u64 };
pub const Position = struct { generation: Generation, offset: u64 };
pub const ResumeEntry = struct { name: []const u8, cursor: Cursor };

pub fn encodeGeneration(generation: Generation) [generation_hex_len]u8 {
    const digits = "0123456789abcdef";
    var encoded: [generation_hex_len]u8 = undefined;
    for (generation, 0..) |byte, i| {
        encoded[2 * i] = digits[byte >> 4];
        encoded[2 * i + 1] = digits[byte & 15];
    }
    return encoded;
}

fn nibble(byte: u8) error{InvalidGeneration}!u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => error.InvalidGeneration,
    };
}

pub fn decodeGeneration(encoded: []const u8) error{InvalidGeneration}!Generation {
    if (encoded.len != generation_hex_len) return error.InvalidGeneration;
    var generation: Generation = undefined;
    for (&generation, 0..) |*byte, i| byte.* = (try nibble(encoded[2 * i])) * 16 + try nibble(encoded[2 * i + 1]);
    return generation;
}

pub fn encodeHeader(generation: Generation) [header_len]u8 {
    var header: [header_len]u8 = undefined;
    @memcpy(header[0..header_magic.len], header_magic);
    const encoded = encodeGeneration(generation);
    @memcpy(header[header_magic.len..][0..generation_hex_len], &encoded);
    header[header_len - 1] = '\n';
    return header;
}

pub fn decodeHeader(bytes: []const u8) error{ IncompleteHeader, NotGenerationLog, UnsupportedVersion, InvalidHeader, InvalidGeneration }!Generation {
    // Reserved partial headers are corruption/incompleteness, never a legacy fallback.
    if (bytes.len < magic_family.len and std.mem.startsWith(u8, magic_family, bytes)) return error.IncompleteHeader;
    if (!std.mem.startsWith(u8, bytes, magic_family)) return error.NotGenerationLog;
    if (bytes.len < header_magic.len) return error.IncompleteHeader;
    if (!std.mem.startsWith(u8, bytes, header_magic)) return error.UnsupportedVersion;
    if (bytes.len < header_len) return error.IncompleteHeader;
    if (bytes[header_len - 1] != '\n') return error.InvalidHeader;
    return decodeGeneration(bytes[header_magic.len..][0..generation_hex_len]);
}

pub fn decodeResumeEntry(bytes: []const u8) error{InvalidResume}!ResumeEntry {
    var fields = std.mem.splitScalar(u8, bytes, ':');
    const name = fields.next().?;
    if (name.len > command.remote_log_name_max or !command.instance_token_class.accepts(name)) return error.InvalidResume;
    const digits = fields.next() orelse return error.InvalidResume;
    if (digits.len == 0) return error.InvalidResume;
    for (digits) |byte| if (byte < '0' or byte > '9') return error.InvalidResume;
    const offset = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidResume;
    const generation = if (fields.next()) |encoded| decodeGeneration(encoded) catch return error.InvalidResume else null;
    if (fields.next() != null) return error.InvalidResume;
    return .{ .name = name, .cursor = .{ .generation = generation, .offset = offset } };
}

pub fn encodeResumeEntry(buffer: []u8, entry: ResumeEntry) error{ NoSpaceLeft, InvalidResume }![]const u8 {
    if (entry.name.len > command.remote_log_name_max or !command.instance_token_class.accepts(entry.name)) return error.InvalidResume;
    if (entry.cursor.generation) |generation| {
        const encoded = encodeGeneration(generation);
        return std.fmt.bufPrint(buffer, "{s}:{d}:{s}", .{ entry.name, entry.cursor.offset, encoded });
    }
    return std.fmt.bufPrint(buffer, "{s}:{d}", .{ entry.name, entry.cursor.offset });
}

/// v2 never applies a legacy or another generation's offset, even to a larger file.
pub fn reconcile(resume_cursor: ?Cursor, generation: Generation, payload_size: u64) Position {
    if (resume_cursor) |cursor| {
        if (cursor.generation) |previous| {
            if (std.mem.eql(u8, &previous, &generation) and cursor.offset <= payload_size)
                return .{ .generation = generation, .offset = cursor.offset };
        }
    }
    return .{ .generation = generation, .offset = 0 };
}

pub fn fileOffset(payload_offset: u64) error{Overflow}!u64 {
    return std.math.add(u64, header_len, payload_offset);
}

/// Only a caller holding the shared lock may act on this decision. A pipe flush
/// must have succeeded first; snapshot equality alone says nothing about delivery.
pub fn canRotate(consumed: Position, snapshot_size: u64, current_generation: Generation, current_size: u64) bool {
    return consumed.offset == snapshot_size and current_size == snapshot_size and
        std.mem.eql(u8, &consumed.generation, &current_generation);
}

pub fn resumeBytesBound(count: usize) error{Overflow}!usize {
    if (count == 0) return 0;
    return std.math.sub(usize, try std.math.mul(usize, count, max_resume_entry_bytes + 1), 1);
}

const testing = std.testing;
const first: Generation = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
const second: Generation = .{0x7e} ** 16;
const first_hex = "00112233445566778899aabbccddeeff";

test "generation header has independent golden bytes and preserves the payload" {
    const header = encodeHeader(first);
    try testing.expectEqualStrings("MARU_AGENT_LOG_V2\t" ++ first_hex ++ "\n", &header);
    try testing.expectEqualDeep(first, try decodeHeader(&header));
    try testing.expectEqualDeep(first, try decodeHeader("MARU_AGENT_LOG_V2\t" ++ first_hex ++ "\nclaude\t{}\n"));
    for (0..header_len) |length| try testing.expectError(error.IncompleteHeader, decodeHeader(header[0..length]));
    try testing.expectError(error.NotGenerationLog, decodeHeader("claude\t{}\n"));
    try testing.expectError(error.UnsupportedVersion, decodeHeader("MARU_AGENT_LOG_V3\t" ++ first_hex ++ "\n"));
    try testing.expectError(error.InvalidHeader, decodeHeader("MARU_AGENT_LOG_V2\t" ++ first_hex ++ "x"));
    try testing.expectError(error.InvalidGeneration, decodeHeader("MARU_AGENT_LOG_V2\t00112233445566778899AABBCCDDEEFF\n"));
}

test "generation hex validates every byte position and round trips all byte values" {
    for (0..256) |value| {
        const expected: Generation = .{@as(u8, @intCast(value))} ** 16;
        const encoded = encodeGeneration(expected);
        // std's formatter supplies an independent oracle, so matching encoder/decoder
        // mistakes cannot hide behind a successful round trip.
        var pair_buffer: [2]u8 = undefined;
        const pair = try std.fmt.bufPrint(&pair_buffer, "{x:0>2}", .{value});
        for (0..16) |position| try testing.expectEqualStrings(pair, encoded[2 * position ..][0..2]);
        try testing.expectEqualDeep(expected, try decodeGeneration(&encoded));
    }
    for (0..generation_hex_len) |position| {
        for ([_]u8{ 'g', 'A', ':', ',', '\n', 0, 0xff }) |invalid| {
            var encoded = encodeGeneration(first);
            encoded[position] = invalid;
            try testing.expectError(error.InvalidGeneration, decodeGeneration(&encoded));
        }
    }
    try testing.expectError(error.InvalidGeneration, decodeGeneration(first_hex[0..31]));
    try testing.expectError(error.InvalidGeneration, decodeGeneration(first_hex ++ "0"));
}

test "generation resume grammar bounds and legacy distinction" {
    const entry = try decodeResumeEntry("a:00042:" ++ first_hex);
    try testing.expectEqualStrings("a", entry.name);
    try testing.expectEqual(@as(u64, 42), entry.cursor.offset);
    try testing.expectEqualDeep(first, entry.cursor.generation.?);
    var buffer: [max_resume_entry_bytes]u8 = undefined;
    try testing.expectEqualStrings("a:42:" ++ first_hex, try encodeResumeEntry(&buffer, entry));
    const legacy = try decodeResumeEntry("aa:0");
    try testing.expect(legacy.cursor.generation == null);
    try testing.expectEqualStrings("aa:0", try encodeResumeEntry(&buffer, legacy));
    for ([_][]const u8{ "", "a", ":0", "../a:0", "a/b:0", "a:-1", "a:+1", "a:1_0", "a: 1", "a:18446744073709551616", "a:0:", "a:0:" ++ first_hex ++ ":0", "a:0:" ++ first_hex ++ ",b:0" }) |invalid|
        try testing.expectError(error.InvalidResume, decodeResumeEntry(invalid));
    const name = "a" ** command.remote_log_name_max;
    const maximum = try decodeResumeEntry(name ++ ":18446744073709551615:" ++ first_hex);
    const encoded = try encodeResumeEntry(&buffer, maximum);
    try testing.expectEqual(max_resume_entry_bytes, encoded.len);
    try testing.expectEqualDeep(maximum.cursor, (try decodeResumeEntry(encoded)).cursor);
    try testing.expectError(error.NoSpaceLeft, encodeResumeEntry(buffer[0 .. buffer.len - 1], maximum));
    try testing.expectError(error.InvalidResume, decodeResumeEntry(name ++ "a:0"));
    try testing.expectError(error.InvalidResume, encodeResumeEntry(&buffer, .{ .name = "../a", .cursor = .{ .offset = 0 } }));
}

test "generation reconciliation never skips another generation or applies a legacy cursor" {
    for ([_]u64{ 0, 23, 47, 48, std.math.maxInt(u64) }) |size| {
        for ([_]u64{ 0, 23, 47, 48, std.math.maxInt(u64) }) |offset| {
            const same = reconcile(.{ .generation = first, .offset = offset }, first, size);
            try testing.expectEqual(if (offset <= size) offset else 0, same.offset);
            try testing.expectEqualDeep(first, same.generation);
            try testing.expectEqual(@as(u64, 0), reconcile(.{ .generation = first, .offset = offset }, second, size).offset);
            try testing.expectEqual(@as(u64, 0), reconcile(.{ .offset = offset }, first, size).offset);
        }
        try testing.expectEqual(@as(u64, 0), reconcile(null, first, size).offset);
    }
    for (0..16) |position| {
        var different = first;
        different[position] ^= 1;
        try testing.expectEqual(@as(u64, 0), reconcile(.{ .generation = first, .offset = 23 }, different, 1000).offset);
    }
    try testing.expectEqual(@as(u64, header_len), try fileOffset(0));
    try testing.expectEqual(std.math.maxInt(u64), try fileOffset(std.math.maxInt(u64) - header_len));
    try testing.expectError(error.Overflow, fileOffset(std.math.maxInt(u64) - header_len + 1));
}

test "generation rotation requires both generation and snapshot EOF equality" {
    const consumed: Position = .{ .generation = first, .offset = 47 };
    try testing.expect(canRotate(consumed, 47, first, 47));
    try testing.expect(!canRotate(consumed, 48, first, 48));
    try testing.expect(!canRotate(consumed, 47, first, 48));
    try testing.expect(!canRotate(consumed, 47, first, 46));
    try testing.expect(!canRotate(consumed, 47, second, 47));
    try testing.expectEqual(@as(usize, 0), try resumeBytesBound(0));
    try testing.expectEqual(@as(usize, max_resume_entry_bytes), try resumeBytesBound(1));
    try testing.expectEqual(@as(usize, (max_resume_entry_bytes + 1) * 32 - 1), try resumeBytesBound(32));
    try testing.expectError(error.Overflow, resumeBytesBound(std.math.maxInt(usize)));
}
