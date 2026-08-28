//! P4 E3b product ownership boundary.

const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

test "P4 E3b runtime sampler is the sole metadata producer gate and owns actual scale evidence" {
    const allocator = std.testing.allocator;
    const manager = try read(allocator, "src/platform/macos/session_host/runtime_manager.zig", 512 * 1024);
    defer allocator.free(manager);
    const server = try read(allocator, "src/platform/macos/session_host/server.zig", 512 * 1024);
    defer allocator.free(server);
    const poll_owner = try read(allocator, "src/platform/macos/session_host/poll_owner.zig", 256 * 1024);
    defer allocator.free(poll_owner);
    const handoff = try read(allocator, "src/platform/macos/session_host/handoff_inventory.zig", 128 * 1024);
    defer allocator.free(handoff);
    const e2e = try read(allocator, "tests/session_host_slow_observer_e2e.zig", 256 * 1024);
    defer allocator.free(e2e);
    const validator = try read(allocator, "tools/perf/session_host_slow_observer_validator.zig", 256 * 1024);
    defer allocator.free(validator);

    try std.testing.expectEqual(@as(usize, 1), count(manager, ".metadata_change_token = metadataChangeTokenOp"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, ".sample_metadata_sources = sampleMetadataSourcesOp"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "metadata_samplers: std.AutoHashMapUnmanaged"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "const metadata_token_changed"));
    // Attach publication and periodic event publication each stage the same delivery token.
    try std.testing.expectEqual(@as(usize, 2), count(server, "output.next_metadata_change_token = source_token"));
    try std.testing.expectEqual(@as(usize, 1), count(poll_owner, "self.server.sampleMetadataSources(now_ns);"));
    try std.testing.expectEqual(@as(usize, 1), count(handoff, "\"metadata_samplers\""));

    try std.testing.expectEqual(@as(usize, 1), count(e2e, ".metadata_change_runtime_count = 100"));
    try std.testing.expectEqual(@as(usize, 1), count(e2e, ".metadata_change_target_stream_count = 3"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "artifact.metadata_change_producer_visit_delta != 3"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "sample.metadata_producer_visit_delta != 0"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "artifact.metadata_sampler_failures != 0"));
}
