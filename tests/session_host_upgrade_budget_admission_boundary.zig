//! U5 pre-quiesce handoff-size, disk, and I/O budget product boundary.

const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}

test "U5 budget admission precedes quiesce and owns reserved handoff cleanup" {
    const allocator = std.testing.allocator;
    const coordinator = try read(
        allocator,
        "src/platform/macos/session_host/upgrade_product_coordinator.zig",
        256 * 1024,
    );
    defer allocator.free(coordinator);
    const admission = try read(
        allocator,
        "src/platform/macos/session_host/upgrade_budget_admission.zig",
        256 * 1024,
    );
    defer allocator.free(admission);
    const manager = try read(
        allocator,
        "src/platform/macos/session_host/runtime_manager.zig",
        512 * 1024,
    );
    defer allocator.free(manager);
    const store = try read(
        allocator,
        "src/platform/macos/session_host/handoff_store.zig",
        256 * 1024,
    );
    defer allocator.free(store);
    const outer_loop = try read(
        allocator,
        "src/platform/macos/session_host/upgrade_loop.zig",
        128 * 1024,
    );
    defer allocator.free(outer_loop);
    const build = try read(allocator, "build.zig", 2 * 1024 * 1024);
    defer allocator.free(build);
    const barrel = try read(
        allocator,
        "src/platform/macos/session_host.zig",
        256 * 1024,
    );
    defer allocator.free(barrel);
    const contract = try read(allocator, "docs/session-host-upgrade.md", 512 * 1024);
    defer allocator.free(contract);

    const process_start = std.mem.indexOf(u8, coordinator, "fn processArmedWithDeadline") orelse
        return error.MissingProductCoordinator;
    const process_tail = coordinator[process_start..];
    const process_end = std.mem.indexOf(u8, process_tail, "\n/// The readiness owner") orelse
        return error.MissingProductCoordinatorEnd;
    const process = process_tail[0..process_end];
    const context_start = std.mem.indexOf(u8, coordinator, "pub const Context = struct {") orelse
        return error.MissingProductContext;
    const context_tail = coordinator[context_start..];
    const context_end = std.mem.indexOf(u8, context_tail, "\n};") orelse
        return error.MissingProductContextEnd;
    const public_context = context_tail[0..context_end];
    const prepare = std.mem.indexOf(u8, process, "budget_admission.prepare(") orelse
        return error.MissingBudgetAdmission;
    const freeze = std.mem.indexOf(u8, process, "upgrade_attempt.freeze") orelse
        return error.MissingFreeze;
    try std.testing.expect(prepare < freeze);

    try std.testing.expectEqual(@as(usize, 1), count(
        manager,
        "pub fn previewUpgradeHandoff(",
    ));
    try std.testing.expect(std.mem.indexOf(u8, admission, "pub const Reservation") != null);
    try std.testing.expect(std.mem.indexOf(u8, admission, "pub fn prepare(") != null);
    try std.testing.expect(std.mem.indexOf(u8, admission, "pub fn commit(") != null);
    try std.testing.expect(std.mem.indexOf(u8, admission, "pub fn cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, admission, "pub fn deinit(") != null);
    try std.testing.expect(std.mem.indexOf(u8, admission, "safety_factor") != null);
    try std.testing.expect(std.mem.indexOf(u8, admission, "probe") != null);
    try std.testing.expect(std.mem.indexOf(u8, store, "pub fn commitReserved(") != null);
    try std.testing.expect(std.mem.indexOf(u8, store, "pub fn cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, coordinator, "budget_reservation.cancel() catch return .invariant_violation") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        coordinator,
        "product coordinator cleanup identity failure overrides resumed report with invariant violation",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, coordinator, "fn processArmedWithDeadlineHooks(") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_context, "before_budget_prepare") == null);
    try std.testing.expect(std.mem.indexOf(u8, public_context, "after_budget_prepare") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        outer_loop,
        "outer loop fail-stops every nonretryable coordinator terminal",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        build,
        "test-session-host-upgrade-coordinator-cleanup-fail-stop",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        build,
        "run_upgrade_coordinator_cleanup_failure_tests.addArg(\"--maru-expect-tests=1\")",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        build,
        "run_upgrade_loop_cleanup_fail_stop_tests.addArg(\"--maru-expect-tests=1\")",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, coordinator, "handoff_store.commit(") == null);
    try std.testing.expect(std.mem.indexOf(u8, barrel, "upgrade_budget_admission") == null);
    try std.testing.expect(std.mem.indexOf(u8, contract, "accepted reply를 flush하고 reader를 멈추기 **전**") != null);
    try std.testing.expect(std.mem.indexOf(u8, contract, "임의의 낙관적 기본 처리율은 두지 않는다") != null);
}
