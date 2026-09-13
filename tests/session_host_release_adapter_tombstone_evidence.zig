//! Pins the signed durable-tombstone leaf before the product runner and workflow may publish it.

const std = @import("std");
const evidence = @import("release_adapter_tombstone_evidence");

const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn valid() evidence.Record {
    return .{
        .schema = evidence.schema,
        .test_uuid = "123e4567-e89b-42d3-a456-426614174000",
        .result = .passed,
        .candidate_dmg_sha256 = digest,
        .candidate_executable_sha256 = digest,
        .designated_requirement_sha256 = digest,
        .runtime_handle = "1234567890abcdef1234567890abcdef:fedcba0987654321fedcba0987654321",
        .runtime_state = .ended,
        .relaunch_count = 2,
        .normal_quit_count = 2,
        .final_checkpoint_count = 2,
        .checkpoint_first_sha256 = digest,
        .checkpoint_second_sha256 = digest,
        .probe_count = 0,
        .attach_count = 0,
        .spawn_count = 0,
        .output_event_count = 0,
        .terminal_input_event_count = 0,
        .cleanup_complete = true,
    };
}

test "two ordinary Quit cycles produce one canonical ended-runtime leaf" {
    const bytes = try evidence.encode(std.testing.allocator, valid());
    defer std.testing.allocator.free(bytes);
    var parsed = try evidence.parse(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 2), parsed.value.final_checkpoint_count);
    try std.testing.expectEqualStrings(parsed.value.checkpoint_first_sha256, parsed.value.checkpoint_second_sha256);
}

test "missing Quit checkpoint or zero-activity invariant cannot pass" {
    var value = valid();
    value.normal_quit_count = 1;
    try std.testing.expectError(error.InvalidEvidence, evidence.encode(std.testing.allocator, value));
    value = valid();
    value.spawn_count = 1;
    try std.testing.expectError(error.InvalidEvidence, evidence.encode(std.testing.allocator, value));
    value = valid();
    value.checkpoint_second_sha256 = "1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expectError(error.InvalidEvidence, evidence.encode(std.testing.allocator, value));
}

test "identity drift unknown fields and noncanonical bytes fail closed" {
    var value = valid();
    value.runtime_handle = "1234567890abcdef1234567890abcdeg:fedcba0987654321fedcba0987654321";
    try std.testing.expectError(error.InvalidEvidence, evidence.encode(std.testing.allocator, value));

    const bytes = try evidence.encode(std.testing.allocator, valid());
    defer std.testing.allocator.free(bytes);
    const hostile = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "{\"schema\":", "{\"unknown\":1,\"schema\":");
    defer std.testing.allocator.free(hostile);
    try std.testing.expectError(error.InvalidJson, evidence.parse(std.testing.allocator, hostile));
    try std.testing.expectError(error.NonCanonical, evidence.parse(std.testing.allocator, bytes[0 .. bytes.len - 1]));
}
