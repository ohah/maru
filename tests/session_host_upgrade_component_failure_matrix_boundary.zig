const std = @import("std");

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn testCount(source: []const u8) usize {
    return std.mem.count(u8, source, "test \"");
}

test "U5 second failure matrix keeps the exact component inventory" {
    const paths = [_][]const u8{
        "src/platform/macos/session_host/handoff_store.zig",
        "src/platform/macos/session_host/exec_fd_set.zig",
        "src/platform/macos/session_host/host_authority.zig",
        "src/platform/macos/session_host/upgrade_target.zig",
    };
    var sources: [paths.len][]u8 = undefined;
    var loaded: usize = 0;
    defer for (sources[0..loaded]) |source| std.testing.allocator.free(source);
    for (paths, 0..) |path, index| {
        sources[index] = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            std.testing.allocator,
            .limited(128 * 1024),
        );
        loaded += 1;
    }

    try std.testing.expectEqual(@as(usize, 9), testCount(sources[0]));
    try std.testing.expectEqual(@as(usize, 6), testCount(sources[1]));
    try std.testing.expectEqual(@as(usize, 3), testCount(sources[2]));
    try std.testing.expectEqual(@as(usize, 5), testCount(sources[3]));

    const required = [_]struct { source: usize, title: []const u8 }{
        .{ .source = 0, .title = "handoff store commits identical primary backup and unlinks secret paths before exec" },
        .{ .source = 0, .title = "reserved handoff commits into pre-quiesce files and cleans the private attempt" },
        .{ .source = 0, .title = "partial reservation failure removes the first copy and private attempt" },
        .{ .source = 0, .title = "handoff store rejects malformed or divergent state and removes attempt residue" },
        .{ .source = 0, .title = "handoff store directory fd stays on the approved generation after path replacement" },
        .{ .source = 0, .title = "handoff store exact cleanup preserves a swapped replacement leaf" },
        .{ .source = 0, .title = "reserved handoff syscall failures publish no pair and leave no attempt residue" },
        .{ .source = 0, .title = "reservation cleanup identity failure closes descriptors and preserves replacement" },
        .{ .source = 0, .title = "reservation cleanup observes consecutive kernel permission and nonempty failures" },
        .{ .source = 1, .title = "exec fd set exposes only reserved duplicate and rollback preserves CLOEXEC source" },
        .{ .source = 1, .title = "exec fd set rejects occupied and duplicate reserved slots without changing source" },
        .{ .source = 1, .title = "restore inherited close token consumes the exact non-cloexec set" },
        .{ .source = 1, .title = "exec fd set capacity includes maximum runtime graph and fixed upgrade roles" },
        .{ .source = 1, .title = "slot reservation pins the full namespace before exact replacement and rolls back all slots" },
        .{ .source = 1, .title = "slot reservation handles the product maximum of 256 PTYs plus state and owner roles" },
        .{ .source = 2, .title = "host authority owns wire build and endpoint strings" },
        .{ .source = 2, .title = "host authority adapter CASes restoring and rollback through one disk and wire SSOT" },
        .{ .source = 2, .title = "prepared host authority activates a stable restoring manifest after all allocation" },
        .{ .source = 3, .title = "upgrade target stages an exact executable inode and cancellation removes it" },
        .{ .source = 3, .title = "upgrade target rejects hash build reader and executable mismatches without residue" },
        .{ .source = 3, .title = "real target stager and upgrade owner release cancel and terminal artifacts" },
        .{ .source = 3, .title = "real target restore reopens a CLOEXEC pin and terminal finish closes it exactly once" },
        .{ .source = 3, .title = "pinned target fd keeps the approved inode while path replacement is rejected and preserved" },
    };
    for (required) |entry| try std.testing.expect(contains(sources[entry.source], entry.title));

    const build = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(build);
    const coordinator = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/upgrade_product_coordinator.zig",
        std.testing.allocator,
        .limited(256 * 1024),
    );
    defer std.testing.allocator.free(coordinator);
    try std.testing.expect(contains(build, "test-session-host-upgrade-component-failure-matrix"));
    try std.testing.expect(contains(build, "component_failure_matrix_step.dependOn(&run_handoff_store_tests.step)"));
    try std.testing.expect(contains(build, "component_failure_matrix_step.dependOn(&run_exec_fd_set_tests.step)"));
    try std.testing.expect(contains(build, "component_failure_matrix_step.dependOn(&run_host_authority_tests.step)"));
    try std.testing.expect(contains(build, "component_failure_matrix_step.dependOn(&run_upgrade_target_tests.step)"));
    try std.testing.expect(contains(build, "test-session-host-upgrade-reserved-handoff-failures"));
    try std.testing.expect(contains(build, "run_reserved_handoff_failure_tests.addArg(\"--maru-expect-tests=1\")"));
    try std.testing.expect(contains(build, "test-session-host-upgrade-reservation-cleanup-failure"));
    try std.testing.expect(contains(build, "run_reservation_cleanup_failure_tests.addArg(\"--maru-expect-tests=1\")"));
    try std.testing.expect(contains(
        coordinator,
        "budget_reservation.cancel() catch return .invariant_violation",
    ));
}
