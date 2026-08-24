//! CR6e-b hard-budget validator for one paired transport/AppKit batch on the pinned runner.

const std = @import("std");
const baseline_validator = @import("session_host_cr6e_baseline_validator.zig");
const recovery_validator = @import("session_host_cr6e_recovery_validator.zig");

const expected_os_release = "25.5.0";
const expected_machine_model = "Mac16,9";
const expected_logical_cpus: u32 = 16;
const ns_per_ms = std.time.ns_per_ms;

const Resource = struct { monotonic_ns: u64, resident_bytes: u64, footprint_bytes: u64, cpu_ns: u64 };
const TransportScenario = struct {
    name: []const u8,
    start_ns: u64,
    deadline_ns: u64,
    end_ns: u64,
    failure_reason: []const u8,
    attempt_count: u32,
    backoff_wait_count: u32,
    peer_accepted: bool,
    peer_hello_bytes: u32,
    peer_closed: bool,
};
const TransportArtifact = struct {
    schema: []const u8,
    build_mode: []const u8,
    sample_api: []const u8,
    os_release: []const u8,
    machine_model: []const u8,
    logical_cpu_count: u32,
    pid: u32,
    deadline_ms: u64,
    fd_count_before: u32,
    fd_count_after: u32,
    rss_before: Resource,
    rss_after: Resource,
    scenarios: [2]TransportScenario,
    peer_reaped: bool,
    socket_removed: bool,
    manifest_removed: bool,
    host_directory_removed: bool,
};
const RecoveryIteration = struct {
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
const RecoveryArtifact = struct {
    schema: []const u8,
    build_mode: []const u8,
    iteration_count: u32,
    host_id_hex: []const u8,
    iterations: []const RecoveryIteration,
    fd_before: u32,
    fd_after: u32,
    child_processes_remaining: u32,
    daemon_reaped: bool,
    socket_removed: bool,
    host_artifacts_removed: bool,
};

fn positiveDelta(after: u64, before: u64) u64 {
    return if (after > before) after - before else 0;
}

fn validateTransport(value: TransportArtifact) !void {
    if (!std.mem.eql(u8, value.schema, "maru.session-host-cr6e-baseline-macos.v1") or
        !std.mem.eql(u8, value.build_mode, "ReleaseFast") or
        !std.mem.eql(u8, value.sample_api, "proc_pid_rusage:RUSAGE_INFO_V4") or
        !std.mem.eql(u8, value.os_release, expected_os_release) or
        !std.mem.eql(u8, value.machine_model, expected_machine_model) or
        value.logical_cpu_count != expected_logical_cpus)
        return error.EnvironmentMismatch;
    const hello = value.scenarios[0];
    const backoff = value.scenarios[1];
    if (hello.end_ns <= hello.start_ns or hello.deadline_ns <= hello.start_ns or
        backoff.end_ns <= backoff.start_ns or backoff.deadline_ns <= backoff.start_ns)
        return error.TimestampOrder;
    if (!std.mem.eql(u8, hello.name, "hello_reply_stall") or
        !std.mem.eql(u8, hello.failure_reason, "deadline_exceeded") or
        hello.attempt_count != 1 or hello.backoff_wait_count != 0 or
        !hello.peer_accepted or hello.peer_hello_bytes == 0 or !hello.peer_closed or
        hello.end_ns < hello.deadline_ns or hello.end_ns - hello.start_ns > 260 * ns_per_ms)
        return error.TransportBudgetExceeded;
    if (!std.mem.eql(u8, backoff.name, "transient_backoff") or
        !std.mem.eql(u8, backoff.failure_reason, "host_gone") or
        backoff.attempt_count != 10 or backoff.backoff_wait_count != 9 or
        backoff.end_ns > backoff.deadline_ns or backoff.end_ns - backoff.start_ns > 225 * ns_per_ms)
        return error.TransportBudgetExceeded;
    if (value.fd_count_before != value.fd_count_after or
        positiveDelta(value.rss_after.resident_bytes, value.rss_before.resident_bytes) > 512 * 1024 or
        positiveDelta(value.rss_after.footprint_bytes, value.rss_before.footprint_bytes) > 256 * 1024 or
        positiveDelta(value.rss_after.cpu_ns, value.rss_before.cpu_ns) > 2 * ns_per_ms or
        !value.peer_reaped or !value.socket_removed or !value.manifest_removed or !value.host_directory_removed)
        return error.TransportResourceBudgetExceeded;
}

fn validateRecovery(value: RecoveryArtifact) !void {
    if (!std.mem.eql(u8, value.schema, "maru.session-host-cr6e-recovery-baseline-macos.v1") or
        !std.mem.eql(u8, value.build_mode, "ReleaseFast") or
        value.iteration_count != 5 or value.iterations.len != 5)
        return error.InvalidRecoveryIdentity;
    for (value.iterations, 0..) |row, index| {
        if (row.index != index or row.swift_iteration != index or row.stage != 2 or
            !row.marker_present or !row.before_capture or !row.after_capture or
            !row.runtime_survived or !row.controller_zero or !row.observer_zero)
            return error.InvalidRecoveryIteration;
        if (!(row.harness_launch_ns <= row.swift_launch_ns and row.swift_launch_ns < row.row_ns and
            row.row_ns < row.click_ns and row.click_ns < row.remote_visible_ns and
            row.remote_visible_ns <= row.summary_ns and row.summary_ns <= row.harness_exit_ns))
            return error.TimestampOrder;
        if (row.row_ns - row.swift_launch_ns > 750 * ns_per_ms or
            row.click_ns - row.row_ns > 250 * ns_per_ms or
            row.remote_visible_ns - row.click_ns > 250 * ns_per_ms or
            row.summary_ns - row.remote_visible_ns > 300 * ns_per_ms or
            row.harness_exit_ns - row.harness_launch_ns > 1500 * ns_per_ms)
            return error.RecoveryBudgetExceeded;
    }
    if (value.fd_before != value.fd_after or value.child_processes_remaining != 0 or
        !value.daemon_reaped or !value.socket_removed or !value.host_artifacts_removed)
        return error.RecoveryResourceBudgetExceeded;
}

fn parseStrict(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch return error.InvalidJsonSchema;
}

pub fn validatePairBytes(allocator: std.mem.Allocator, transport_bytes: []const u8, recovery_bytes: []const u8) !void {
    // The final soak pass must not become a weaker second implementation of the raw artifact
    // contracts. Re-run both standalone semantic validators before applying runner-specific caps.
    try baseline_validator.validateBytes(allocator, transport_bytes);
    try recovery_validator.validateBytes(allocator, recovery_bytes);
    var transport = try parseStrict(TransportArtifact, allocator, transport_bytes);
    defer transport.deinit();
    var recovery = try parseStrict(RecoveryArtifact, allocator, recovery_bytes);
    defer recovery.deinit();
    try validateTransport(transport.value);
    try validateRecovery(recovery.value);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const transport_path = args.next() orelse return error.MissingTransportArtifact;
    const recovery_path = args.next() orelse return error.MissingRecoveryArtifact;
    if (args.next() != null) return error.TooManyArguments;
    const transport_bytes = try std.Io.Dir.cwd().readFileAlloc(io, transport_path, allocator, .limited(1024 * 1024));
    defer allocator.free(transport_bytes);
    const recovery_bytes = try std.Io.Dir.cwd().readFileAlloc(io, recovery_path, allocator, .limited(1024 * 1024));
    defer allocator.free(recovery_bytes);
    try validatePairBytes(allocator, transport_bytes, recovery_bytes);
}

test "CR6e-b hard budgets reject environment drift and latency overshoot" {
    var transport = validTransport();
    try validateTransport(transport);
    transport.logical_cpu_count = 8;
    try std.testing.expectError(error.EnvironmentMismatch, validateTransport(transport));
    var rows = validRecoveryRows();
    const recovery = validRecovery(&rows);
    try validateRecovery(recovery);
    rows[2].click_ns = rows[2].row_ns + 251 * ns_per_ms;
    rows[2].remote_visible_ns = rows[2].click_ns + 1;
    rows[2].summary_ns = rows[2].remote_visible_ns + 1;
    rows[2].harness_exit_ns = rows[2].summary_ns + 1;
    try std.testing.expectError(error.RecoveryBudgetExceeded, validateRecovery(recovery));
}

fn validTransport() TransportArtifact {
    return .{
        .schema = "maru.session-host-cr6e-baseline-macos.v1",
        .build_mode = "ReleaseFast",
        .sample_api = "proc_pid_rusage:RUSAGE_INFO_V4",
        .os_release = expected_os_release,
        .machine_model = expected_machine_model,
        .logical_cpu_count = expected_logical_cpus,
        .pid = 1,
        .deadline_ms = 250,
        .fd_count_before = 5,
        .fd_count_after = 5,
        .rss_before = .{ .monotonic_ns = 1, .resident_bytes = 1, .footprint_bytes = 1, .cpu_ns = 1 },
        .rss_after = .{ .monotonic_ns = 2, .resident_bytes = 1, .footprint_bytes = 1, .cpu_ns = 2 },
        .scenarios = .{
            .{ .name = "hello_reply_stall", .start_ns = 1, .deadline_ns = 250 * ns_per_ms, .end_ns = 252 * ns_per_ms, .failure_reason = "deadline_exceeded", .attempt_count = 1, .backoff_wait_count = 0, .peer_accepted = true, .peer_hello_bytes = 1, .peer_closed = true },
            .{ .name = "transient_backoff", .start_ns = 300 * ns_per_ms, .deadline_ns = 550 * ns_per_ms, .end_ns = 500 * ns_per_ms, .failure_reason = "host_gone", .attempt_count = 10, .backoff_wait_count = 9, .peer_accepted = false, .peer_hello_bytes = 0, .peer_closed = true },
        },
        .peer_reaped = true,
        .socket_removed = true,
        .manifest_removed = true,
        .host_directory_removed = true,
    };
}

fn validRecoveryRows() [5]RecoveryIteration {
    var rows: [5]RecoveryIteration = undefined;
    for (&rows, 0..) |*row, index| {
        const start: u64 = @intCast(1 + index * 2_000_000_000);
        row.* = .{
            .index = @intCast(index),
            .swift_iteration = @intCast(index),
            .harness_launch_ns = start,
            .swift_launch_ns = start + 10,
            .row_ns = start + 100,
            .click_ns = start + 200,
            .remote_visible_ns = start + 300,
            .summary_ns = start + 400,
            .harness_exit_ns = start + 500,
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

fn validRecovery(rows: []const RecoveryIteration) RecoveryArtifact {
    return .{
        .schema = "maru.session-host-cr6e-recovery-baseline-macos.v1",
        .build_mode = "ReleaseFast",
        .iteration_count = 5,
        .host_id_hex = "00000000000000000000000000000001",
        .iterations = rows,
        .fd_before = 6,
        .fd_after = 6,
        .child_processes_remaining = 0,
        .daemon_reaped = true,
        .socket_removed = true,
        .host_artifacts_removed = true,
    };
}
