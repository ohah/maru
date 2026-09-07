const std = @import("std");
const report = @import("release_workflow_candidate_inputs_process_report");

fn valid() report.Report {
    return .{ .schema = report.schema, .iterations = 20, .successful_runs = 20, .dmg_bytes = 1048576, .executable_bytes = 262144, .stage_ns = .{ .median = 4, .p95 = 7, .max = 9 }, .failures = 0, .parent_fd_delta = 0, .checkpoint_residue = 0, .candidate_residue = 0 };
}

test "report round trips only canonical bytes" {
    var storage: [2048]u8 = undefined;
    const bytes = try report.render(&storage, valid());
    var parsed = try report.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 7), parsed.value.stage_ns.p95);
}

test "report rejects accounting and timing drift" {
    var value = valid();
    value.failures = 1;
    var storage: [2048]u8 = undefined;
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, try report.render(&storage, value)));
    value = valid();
    value.stage_ns.p95 = 2;
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, try report.render(&storage, value)));
    value = valid();
    value.successful_runs = std.math.maxInt(u64);
    value.failures = 1;
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, try report.render(&storage, value)));
}

test "report rejects unknown or noncanonical framing" {
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, "{}"));
    var storage: [2048]u8 = undefined;
    const bytes = try report.render(&storage, valid());
    var framed: [2049]u8 = undefined;
    @memcpy(framed[0..bytes.len], bytes);
    framed[bytes.len] = '\n';
    try std.testing.expectError(error.NonCanonical, report.parseCanonical(std.testing.allocator, framed[0 .. bytes.len + 1]));
}
