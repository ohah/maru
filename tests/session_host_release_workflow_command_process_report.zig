const std = @import("std");
const report = @import("release_workflow_command_process_report");

fn valid() report.Report {
    return .{
        .schema = report.schema,
        .iterations = 20,
        .successful_runs = 20,
        .draft_authoring_ns = .{ .median = 3, .p95 = 5, .max = 8 },
        .aggregate_prepare_ns = .{ .median = 2, .p95 = 4, .max = 7 },
        .aggregate_finalize_ns = .{ .median = 2, .p95 = 3, .max = 6 },
        .publication_ns = .{ .median = 4, .p95 = 6, .max = 9 },
        .aggregate_cleanup_ns = .{ .median = 3, .p95 = 7, .max = 10 },
        .failures = 0,
        .child_pid_collisions = 0,
        .parent_fd_delta = 0,
        .checkpoint_residue = 0,
    };
}

test "command process report round trips canonical stage timings" {
    var storage: [4096]u8 = undefined;
    const bytes = try report.render(&storage, valid());
    var parsed = try report.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 6), parsed.value.publication_ns.p95);
}

test "command process report rejects accounting overflow and timing drift" {
    var value = valid();
    value.failures = 1;
    var storage: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, try report.render(&storage, value)));
    value = valid();
    value.aggregate_finalize_ns.p95 = 1;
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, try report.render(&storage, value)));
    value = valid();
    value.successful_runs = std.math.maxInt(u64);
    value.failures = 1;
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, try report.render(&storage, value)));
}

test "command process report rejects unknown and noncanonical framing" {
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, "{}"));
    var storage: [4096]u8 = undefined;
    const bytes = try report.render(&storage, valid());
    var framed: [4097]u8 = undefined;
    @memcpy(framed[0..bytes.len], bytes);
    framed[bytes.len] = '\n';
    try std.testing.expectError(error.NonCanonical, report.parseCanonical(std.testing.allocator, framed[0 .. bytes.len + 1]));
}
