//! CR6e-a2 repeated actual-AppKit recovery baseline artifact validator.

const std = @import("std");

const iteration_count: usize = 5;

const Iteration = struct {
    index: u32,
    swift_iteration: u32,
    harness_launch_ns: u64,
    swift_launch_ns: u64,
    row_ns: u64,
    click_ns: u64,
    remote_visible_ns: u64,
    summary_ns: u64,
    harness_exit_ns: u64,
    stage: u32,
    marker_present: bool,
    before_capture: bool,
    after_capture: bool,
    runtime_survived: bool,
    controller_zero: bool,
    observer_zero: bool,
};

const Artifact = struct {
    schema: []const u8,
    build_mode: []const u8,
    iteration_count: u32,
    host_id_hex: []const u8,
    iterations: []const Iteration,
    fd_before: u32,
    fd_after: u32,
    child_processes_remaining: u32,
    daemon_reaped: bool,
    socket_removed: bool,
    host_artifacts_removed: bool,
};

fn validateArtifact(artifact: Artifact) !void {
    if (!std.mem.eql(u8, artifact.schema, "maru.session-host-cr6e-recovery-baseline-macos.v1") or
        !std.mem.eql(u8, artifact.build_mode, "ReleaseFast") or
        artifact.iteration_count != iteration_count or artifact.iterations.len != iteration_count or
        artifact.host_id_hex.len != 32)
        return error.InvalidIdentity;
    var previous_exit: u64 = 0;
    for (artifact.iterations, 0..) |row, index| {
        if (row.index != index or row.swift_iteration != index or row.stage != 2 or !row.marker_present or
            !row.before_capture or !row.after_capture or
            !row.runtime_survived or !row.controller_zero or !row.observer_zero)
            return error.InvalidIteration;
        if (!(row.harness_launch_ns <= row.swift_launch_ns and
            row.swift_launch_ns < row.row_ns and row.row_ns < row.click_ns and
            row.click_ns < row.remote_visible_ns and row.remote_visible_ns <= row.summary_ns and
            row.summary_ns <= row.harness_exit_ns))
            return error.TimestampOrder;
        if (previous_exit != 0 and row.harness_launch_ns <= previous_exit)
            return error.TimestampOrder;
        previous_exit = row.harness_exit_ns;
    }
    if (artifact.fd_before != artifact.fd_after or artifact.child_processes_remaining != 0 or
        !artifact.daemon_reaped or !artifact.socket_removed or !artifact.host_artifacts_removed)
        return error.CleanupIncomplete;
}

fn validateBytes(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(Artifact, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch return error.InvalidJsonSchema;
    defer parsed.deinit();
    try validateArtifact(parsed.value);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingArtifactPath;
    if (args.next() != null) return error.TooManyArguments;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    try validateBytes(allocator, bytes);
}

test "CR6e-a2 validator rejects marker duplication projection and cleanup residue" {
    var rows = fixtureRows();
    var artifact = validFixture(&rows);
    try validateArtifact(artifact);
    rows[2].marker_present = false;
    try std.testing.expectError(error.InvalidIteration, validateArtifact(artifact));
    rows = fixtureRows();
    artifact = validFixture(&rows);
    rows[2].swift_iteration = 3;
    try std.testing.expectError(error.InvalidIteration, validateArtifact(artifact));
    rows = fixtureRows();
    artifact = validFixture(&rows);
    artifact.fd_after += 1;
    try std.testing.expectError(error.CleanupIncomplete, validateArtifact(artifact));
    rows = fixtureRows();
    artifact = validFixture(&rows);
    artifact.daemon_reaped = false;
    try std.testing.expectError(error.CleanupIncomplete, validateArtifact(artifact));
}

fn fixtureRows() [iteration_count]Iteration {
    var rows: [iteration_count]Iteration = undefined;
    for (&rows, 0..) |*row, index| {
        const start = 1 + index * 100;
        row.* = .{
            .index = @intCast(index),
            .swift_iteration = @intCast(index),
            .harness_launch_ns = start,
            .swift_launch_ns = start + 1,
            .row_ns = start + 2,
            .click_ns = start + 3,
            .remote_visible_ns = start + 4,
            .summary_ns = start + 5,
            .harness_exit_ns = start + 6,
            .stage = 2,
            .marker_present = true,
            .before_capture = true,
            .after_capture = true,
            .runtime_survived = true,
            .controller_zero = true,
            .observer_zero = true,
        };
    }
    return rows;
}

fn validFixture(rows: []const Iteration) Artifact {
    return .{
        .schema = "maru.session-host-cr6e-recovery-baseline-macos.v1",
        .build_mode = "ReleaseFast",
        .iteration_count = iteration_count,
        .host_id_hex = "00000000000000000000000000000001",
        .iterations = rows,
        .fd_before = 5,
        .fd_after = 5,
        .child_processes_remaining = 0,
        .daemon_reaped = true,
        .socket_removed = true,
        .host_artifacts_removed = true,
    };
}
