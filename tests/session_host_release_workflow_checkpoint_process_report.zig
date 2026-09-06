const std = @import("std");
const report = @import("release_workflow_checkpoint_process_report");

fn valid() report.Report {
    return .{
        .schema = report.schema,
        .iterations = 20,
        .successful_runs = 20,
        .distinct_pid_runs = 20,
        .init_ns = .{ .median = 1, .p95 = 2, .max = 3 },
        .stages_ns = .{ .median = 4, .p95 = 5, .max = 6 },
        .total_ns = .{ .median = 7, .p95 = 8, .max = 9 },
        .failures = 0,
        .parent_fd_delta = 0,
        .leaf_residue = 0,
        .root_residue = 0,
    };
}

test "checkpoint process report round trips canonical key order" {
    var storage: [2048]u8 = undefined;
    const bytes = try report.render(&storage, valid());
    var parsed = try report.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 20), parsed.value.successful_runs);
    const reordered = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "\"iterations\":20,\"successful_runs\":20", "\"successful_runs\":20,\"iterations\":20");
    defer std.testing.allocator.free(reordered);
    try std.testing.expectError(error.NonCanonical, report.parseCanonical(std.testing.allocator, reordered));
}

test "checkpoint process report rejects structural drift" {
    var storage: [2048]u8 = undefined;
    const bytes = try report.render(&storage, valid());
    const duplicate = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "\"iterations\":20", "\"iterations\":20,\"iterations\":20");
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, duplicate));
    const unknown = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "\"iterations\":20", "\"unknown\":0,\"iterations\":20");
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, unknown));
    const trailing = try std.mem.concat(std.testing.allocator, u8, &.{ bytes, "\n" });
    defer std.testing.allocator.free(trailing);
    try std.testing.expectError(error.NonCanonical, report.parseCanonical(std.testing.allocator, trailing));
}

test "checkpoint process report rejects count schema and percentile drift" {
    var storage: [2048]u8 = undefined;
    var value = valid();
    value.failures = 1;
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, try report.render(&storage, value)));
    value = valid();
    value.schema = "foreign";
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, try report.render(&storage, value)));
    value = valid();
    value.stages_ns = .{ .median = 3, .p95 = 2, .max = 1 };
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, try report.render(&storage, value)));
    value = valid();
    value.init_ns = .{ .median = 0, .p95 = 2, .max = 3 };
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, try report.render(&storage, value)));
    value = valid();
    value.total_ns = .{ .median = 3, .p95 = 4, .max = 5 };
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, try report.render(&storage, value)));
}

test "checkpoint process report rejects negative unsigned fields" {
    var storage: [2048]u8 = undefined;
    const bytes = try report.render(&storage, valid());
    const negative = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "\"parent_fd_delta\":0", "\"parent_fd_delta\":-1");
    defer std.testing.allocator.free(negative);
    try std.testing.expectError(error.InvalidReport, report.parseCanonical(std.testing.allocator, negative));
}
