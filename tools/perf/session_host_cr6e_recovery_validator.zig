//! CR6e-a2 repeated actual-AppKit recovery baseline artifact validator.

const std = @import("std");

const iteration_count: usize = 5;

/// **비동기 wake 적용 지연의 상한.** 값의 근거와 실측표는 소유자인
/// `src/platform/macos/session_host/cr6c_appkit_smoke.zig` 의 `wake_apply_latency_budget_ns` 가 든다 —
/// 이 도구는 독립 실행 파일이라 그것을 import 하지 못하므로 값만 옮겨 적는다.
///
/// **옮겨 적은 값은 갈린다.** 그래서 `tests/boundary/wake_latency_budget.zig` 가 세 자리
/// (여기·소유자·`build.zig` 의 awk 검증)의 숫자가 같은지 센다. 하나만 고치면 그 판정자가 죽는다.
const wake_apply_latency_budget_ns: u64 = 200 * std.time.ns_per_ms;

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
    async_wake_marker_present: bool,
    wake_handler_count: u64,
    wake_apply_latency_ns: u64,
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
    if (!std.mem.eql(u8, artifact.schema, "maru.session-host-cr6e-recovery-baseline-macos.v2") or
        !std.mem.eql(u8, artifact.build_mode, "ReleaseFast") or
        artifact.iteration_count != iteration_count or artifact.iterations.len != iteration_count or
        !isCanonicalHostId(artifact.host_id_hex))
        return error.InvalidIdentity;
    var previous_exit: u64 = 0;
    for (artifact.iterations, 0..) |row, index| {
        if (row.index != index or row.swift_iteration != index or row.stage != 2 or !row.marker_present or
            !row.async_wake_marker_present or row.wake_handler_count == 0 or
            row.wake_apply_latency_ns == 0 or row.wake_apply_latency_ns > wake_apply_latency_budget_ns or
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

fn isCanonicalHostId(text: []const u8) bool {
    if (text.len != 32) return false;
    for (text) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

pub fn validateBytes(allocator: std.mem.Allocator, bytes: []const u8) !void {
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
    rows[2].async_wake_marker_present = false;
    try std.testing.expectError(error.InvalidIteration, validateArtifact(artifact));
    rows = fixtureRows();
    artifact = validFixture(&rows);
    rows[2].wake_handler_count = 0;
    try std.testing.expectError(error.InvalidIteration, validateArtifact(artifact));
    rows = fixtureRows();
    artifact = validFixture(&rows);
    rows[2].wake_apply_latency_ns = wake_apply_latency_budget_ns + 1;
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

test "CR6e-a2 validator rejects noncanonical host identity and overlapping iterations" {
    var rows = fixtureRows();
    var artifact = validFixture(&rows);
    artifact.host_id_hex = "0000000000000000000000000000000G";
    try std.testing.expectError(error.InvalidIdentity, validateArtifact(artifact));

    rows = fixtureRows();
    artifact = validFixture(&rows);
    rows[2].harness_launch_ns = rows[1].harness_exit_ns;
    rows[2].swift_launch_ns = rows[2].harness_launch_ns;
    rows[2].row_ns = rows[2].swift_launch_ns + 1;
    rows[2].click_ns = rows[2].row_ns + 1;
    rows[2].remote_visible_ns = rows[2].click_ns + 1;
    rows[2].summary_ns = rows[2].remote_visible_ns;
    rows[2].harness_exit_ns = rows[2].summary_ns;
    try std.testing.expectError(error.TimestampOrder, validateArtifact(artifact));
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
            .async_wake_marker_present = true,
            .wake_handler_count = 1,
            .wake_apply_latency_ns = std.time.ns_per_ms,
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
        .schema = "maru.session-host-cr6e-recovery-baseline-macos.v2",
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
