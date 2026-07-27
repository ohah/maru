//! Primitive runtime metadata wire vocabulary shared by borrowed and owning decoders.
//!
//! Keep this leaf free of JSON, allocators, platform state, and product ownership so neither
//! decoder needs to import the other.

pub const max_metadata_fields: usize = 64;
pub const max_process_entries: usize = 64;
pub const max_process_fields: usize = 8;

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
    try testing.expectEqual(@as(u8, 0), @intFromEnum(SemanticPrompt.unknown));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(SemanticPrompt.command));
}
