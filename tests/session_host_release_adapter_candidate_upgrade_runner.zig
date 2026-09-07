//! Upgrade-B production composition owns timing, artifacts, and retryable cleanup as one unit.

const std = @import("std");
const runner = @import("release_adapter_candidate_upgrade_runner");

test "timing diagnostic accepts only positive ordered monotonic samples" {
    const valid = try runner.timingForTest(11, 17, 100, 140);
    try std.testing.expect(valid.success);
    try std.testing.expectEqual(@as(u64, 11), valid.signed_one_ns);
    try std.testing.expectEqual(@as(u64, 17), valid.signed_near_max_ns);
    try std.testing.expectEqual(@as(u64, 40), valid.phase_ns);
    try std.testing.expectError(error.InvalidTiming, runner.timingForTest(0, 17, 100, 140));
    try std.testing.expectError(error.InvalidTiming, runner.timingForTest(11, 17, 140, 100));
    try std.testing.expectError(error.InvalidTiming, runner.timingForTest(30, 20, 100, 140));
    try std.testing.expectError(error.InvalidTiming, runner.timingForTest(std.math.maxInt(u64), 1, 0, @as(i128, std.math.maxInt(u64)) + 1));
}

test "pre-owned and copied execution values fail closed before input access" {
    var execution: runner.Execution = .{};
    execution.owner = &execution;
    var inputs: runner.Inputs = undefined;
    inputs.source_directory_fd = -1;
    try std.testing.expectError(error.InvalidOwner, runner.run(std.testing.io, std.testing.allocator, inputs, 1, &execution));
    execution = .{};
    var copied = execution;
    copied.owner = &execution;
    try std.testing.expectError(error.InvalidOwner, runner.run(std.testing.io, std.testing.allocator, inputs, 1, &copied));
}

test "source composes the phase without ambient paths credentials or result booleans" {
    std.testing.refAllDecls(runner);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_upgrade_runner.zig", std.testing.allocator, .limited(128 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "phase.runWith") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "predecessor_copy.materialize") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "child.run") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "evidence_mod.publish") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "getenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "GH_TOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "success_boolean") == null);
}
