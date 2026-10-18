//! Primitive runtime metadata wire vocabulary shared by borrowed and owning decoders.
//!
//! Keep this leaf free of JSON, allocators, platform state, and product ownership so neither
//! decoder needs to import the other.

/// Wire numbers are independent of the domain Profile ordinal (0/1).
pub const AgentLogFormat = enum(u8) { v1 = 1, v2 = 2 };
pub const agent_log_capability = "runtime_agent_log_format_v1";

pub const max_metadata_fields: usize = 64;
pub const max_process_entries: usize = 64;
pub const max_process_fields: usize = 8;
pub const max_process_name_bytes: usize = 128;

pub const ProcessValue = struct {
    pid: i32 = 0,
    len: u8 = 0,
    bytes: [max_process_name_bytes]u8 = @as([max_process_name_bytes]u8, @splat(0)),

    pub fn slice(self: *const ProcessValue) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const SemanticPrompt = enum(u8) {
    unknown,
    prompt,
    input,
    command,
};

test "runtime metadata primitive caps and semantic tags stay wire-stable" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(usize, 64), max_metadata_fields);
    try testing.expectEqual(@as(usize, 64), max_process_entries);
    try testing.expectEqual(@as(usize, 8), max_process_fields);
    try testing.expectEqual(@as(usize, 128), max_process_name_bytes);
    try testing.expectEqual(@as(usize, 136), @sizeOf(ProcessValue));
    try testing.expectEqual(@as(u8, 0), @backingInt(SemanticPrompt.unknown));
    try testing.expectEqual(@as(u8, 3), @backingInt(SemanticPrompt.command));
}
