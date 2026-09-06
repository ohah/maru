//! Closed process outcomes for live-workflow aggregate stages 5 and 6.

const std = @import("std");
const aggregate = @import("release_adapter_candidate_aggregate_process");

test "stage 5 and 6 share one closed redacted outcome vocabulary" {
    try std.testing.expectEqual(@as(u8, 0), aggregate.exitCode(.success));
    try std.testing.expectEqual(@as(u8, 21), aggregate.exitCode(.audit_required));
    try std.testing.expectEqual(@as(u8, 22), aggregate.exitCode(.cleanup_failed));
    try std.testing.expectEqualStrings("success\n", aggregate.stderrLine(.success));
    try std.testing.expectEqualStrings("audit_required\n", aggregate.stderrLine(.audit_required));
    try std.testing.expectEqualStrings("cleanup_failed\n", aggregate.stderrLine(.cleanup_failed));
}

test "failure with pristine process storage is audit required after draft mutation" {
    var storage: aggregate.Storage = .{};
    try std.testing.expectEqual(aggregate.Outcome.audit_required, aggregate.settleFailure(&storage));
    try std.testing.expect(aggregate.storagePristine(&storage));
}

test "unclassifiable durable aggregate owner fails cleanup closed" {
    var storage: aggregate.Storage = .{};
    storage.aggregate.owner = &storage.aggregate;
    storage.aggregate.phase = .retained_closed;
    try std.testing.expectEqual(aggregate.Outcome.cleanup_failed, aggregate.settleFailure(&storage));
}

test "unclassifiable reopened aggregate owner fails cleanup closed" {
    var storage: aggregate.Storage = .{};
    storage.reopened.owner = &storage.reopened;
    storage.reopened.phase = .closed;
    try std.testing.expectEqual(aggregate.Outcome.cleanup_failed, aggregate.settleFailure(&storage));
}

test "foreign pinned source owner cannot be reported as audit-only" {
    var storage: aggregate.Storage = .{};
    var foreign = storage.sources[0];
    storage.sources[0].owner = &foreign;
    try std.testing.expectEqual(aggregate.Outcome.cleanup_failed, aggregate.settleFailure(&storage));
}

test "ownerless metadata residue cannot be reported as pristine audit-only" {
    var source: aggregate.Storage = .{};
    source.sources[0].path_len = 1;
    try std.testing.expectEqual(aggregate.Outcome.cleanup_failed, aggregate.settleFailure(&source));

    var durable: aggregate.Storage = .{};
    durable.aggregate.destination_len = 1;
    try std.testing.expectEqual(aggregate.Outcome.cleanup_failed, aggregate.settleFailure(&durable));

    var reopened: aggregate.Storage = .{};
    reopened.reopened.directory_len = 1;
    try std.testing.expectEqual(aggregate.Outcome.cleanup_failed, aggregate.settleFailure(&reopened));

    var nested: aggregate.Storage = .{};
    nested.reopened.artifacts[0].path_len = 1;
    try std.testing.expectEqual(aggregate.Outcome.cleanup_failed, aggregate.settleFailure(&nested));

    var context: aggregate.Storage = .{};
    context.reopened.context.run_id = 1;
    try std.testing.expectEqual(aggregate.Outcome.cleanup_failed, aggregate.settleFailure(&context));
}

test "validator main closes both aggregate command failures without leaking Zig errors" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tools/session-host/validate_release_manifest.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);

    inline for (.{ "prepare-candidate-aggregate", "finalize-candidate-aggregate" }) |command|
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, command));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "fn isAggregateCommand("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "finishAggregateCommand(.success)"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "finishAggregateCommand(candidate_aggregate_process.settleFailure"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "fn finishAggregateCommand("));
}

test "validator identifies aggregate commands before allocating process storage" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tools/session-host/validate_release_manifest.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);

    const collect_end = std.mem.indexOf(u8, source, "    const storage = init.gpa.create(Storage) catch {") orelse return error.MissingStorageAllocation;
    const closed_allocation_failure = std.mem.indexOfPos(u8, source, collect_end, "            finishAggregateCommand(.audit_required);") orelse return error.MissingClosedAllocationFailure;
    const run_start = std.mem.indexOfPos(u8, source, closed_allocation_failure, "    runCurrentWithStorage(") orelse return error.MissingCommandRun;

    try std.testing.expect(std.mem.indexOf(u8, source[0..collect_end], "    while (args.next()) |value| {") != null);
    try std.testing.expect(closed_allocation_failure < run_start);
}
