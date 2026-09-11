//! CR6f 장시간 idle soak strict artifact validator.

const std = @import("std");

const schema_name = "maru.session-host-cr6f-idle-soak.v1";
pub const idle_soak_window_ns: u64 = 10 * std.time.ns_per_s;
pub const idle_soak_window_count: usize = 60;

const Cpu = struct { user_ns: u64, system_ns: u64 };
const Window = struct {
    index: u32,
    started_ns: u64,
    ended_ns: u64,
    host_pid: u32,
    host_start_abstime: u64,
    child_pid: u32,
    child_start_tvsec: u64,
    child_start_tvusec: u32,
    wake_notify_delta: u64,
    wake_published_delta: u64,
    wake_coalesced_delta: u64,
    wake_drain_delta: u64,
    observation_materialization_delta: u64,
    observation_core_lock_delta: u64,
    metadata_producer_visit_delta: u64,
    screen_snapshot_delta: u64,
    screen_delta_delta: u64,
    screen_allocation_delta: u64,
    screen_core_lock_delta: u64,
    cpu_before: Cpu,
    cpu_after: Cpu,
    cpu_total_delta_ns: u64,
    fd_count: u32,
    resident_bytes: u64,
    footprint_bytes: u64,
};
const Artifact = struct {
    schema: []const u8,
    scenario: []const u8,
    build_mode: []const u8,
    sample_api: []const u8,
    run_nonce_hex: []const u8,
    session_root_kind: []const u8,
    session_root_mode: u16,
    host_pid: u32,
    host_start_abstime: u64,
    child_pid: u32,
    child_start_tvsec: u64,
    child_start_tvusec: u32,
    baseline_fd_count: u32,
    windows: []const Window,
    final_marker_exact_count: u32,
    final_marker_visible: bool,
    final_wake_notify_delta: u64,
    final_wake_published_delta: u64,
    final_wake_drain_delta: u64,
    final_active_clients: u32,
    child_reaped: bool,
    host_graceful_stop: bool,
    host_reaped: bool,
    socket_removed: bool,
    directory_removed: bool,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingArtifactPath;
    if (args.next() != null) return error.TooManyArguments;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Artifact, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    try validateArtifact(parsed.value);
}

fn validateArtifact(a: Artifact) !void {
    if (!std.mem.eql(u8, a.schema, schema_name) or
        !std.mem.eql(u8, a.scenario, "output-wake-continuous-idle") or
        !std.mem.eql(u8, a.build_mode, "ReleaseFast") or
        !std.mem.eql(u8, a.sample_api, "proc_pid_rusage:RUSAGE_INFO_V4"))
        return error.InvalidEnvironment;
    if (!isLowerHex128(a.run_nonce_hex) or
        !std.mem.eql(u8, a.session_root_kind, "fixture_nonce_0700") or
        a.session_root_mode != 0o700)
        return error.InvalidIsolation;
    if (a.host_pid == 0 or a.host_start_abstime == 0 or a.child_pid == 0 or
        a.child_pid == a.host_pid or a.child_start_tvsec == 0 or
        a.child_start_tvusec >= std.time.us_per_s or a.baseline_fd_count == 0)
        return error.InvalidIdentity;
    if (a.windows.len != idle_soak_window_count) return error.InvalidWindowCount;
    var previous_end: u64 = 0;
    for (a.windows, 0..) |w, index| {
        if (w.index != index or w.started_ns < previous_end or w.ended_ns <= w.started_ns or
            w.ended_ns - w.started_ns < idle_soak_window_ns) return error.InvalidWindowOrder;
        if (w.host_pid != a.host_pid or w.host_start_abstime != a.host_start_abstime or
            w.child_pid != a.child_pid or w.child_start_tvsec != a.child_start_tvsec or
            w.child_start_tvusec != a.child_start_tvusec) return error.IdentityChanged;
        if (w.wake_notify_delta != 0 or w.wake_published_delta != 0 or
            w.wake_coalesced_delta != 0 or w.wake_drain_delta != 0 or
            w.observation_materialization_delta != 0 or w.observation_core_lock_delta != 0 or
            w.metadata_producer_visit_delta != 0 or w.screen_snapshot_delta != 0 or
            w.screen_delta_delta != 0 or w.screen_allocation_delta != 0 or
            w.screen_core_lock_delta != 0) return error.IdleWorkObserved;
        if (w.cpu_after.user_ns < w.cpu_before.user_ns or w.cpu_after.system_ns < w.cpu_before.system_ns)
            return error.InvalidCpuSample;
        const cpu = std.math.add(u64, w.cpu_after.user_ns - w.cpu_before.user_ns, w.cpu_after.system_ns - w.cpu_before.system_ns) catch return error.InvalidCpuSample;
        if (w.cpu_total_delta_ns != cpu or cpu > (w.ended_ns - w.started_ns) / 40)
            return error.CpuBudgetExceeded;
        if (w.fd_count != a.baseline_fd_count or w.resident_bytes == 0 or w.footprint_bytes == 0)
            return error.ResourceDrift;
        previous_end = w.ended_ns;
    }
    if (a.final_marker_exact_count != 1 or !a.final_marker_visible or
        a.final_wake_notify_delta == 0 or a.final_wake_published_delta == 0 or
        a.final_wake_drain_delta == 0) return error.MissingFinalWake;
    if (a.final_active_clients != 0 or !a.child_reaped or !a.host_graceful_stop or
        !a.host_reaped or !a.socket_removed or !a.directory_removed)
        return error.IncompleteCleanup;
}

fn isLowerHex128(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |b| if (!std.ascii.isDigit(b) and !(b >= 'a' and b <= 'f')) return false;
    return true;
}

const good_windows = blk: {
    var out: [idle_soak_window_count]Window = undefined;
    for (&out, 0..) |*w, index| {
        const start = 1_000_000_000 + index * idle_soak_window_ns;
        w.* = .{
            .index = @intCast(index),
            .started_ns = start,
            .ended_ns = start + idle_soak_window_ns,
            .host_pid = 100,
            .host_start_abstime = 900,
            .child_pid = 101,
            .child_start_tvsec = 1234,
            .child_start_tvusec = 5678,
            .wake_notify_delta = 0,
            .wake_published_delta = 0,
            .wake_coalesced_delta = 0,
            .wake_drain_delta = 0,
            .observation_materialization_delta = 0,
            .observation_core_lock_delta = 0,
            .metadata_producer_visit_delta = 0,
            .screen_snapshot_delta = 0,
            .screen_delta_delta = 0,
            .screen_allocation_delta = 0,
            .screen_core_lock_delta = 0,
            .cpu_before = .{ .user_ns = index * 1_000_000, .system_ns = 0 },
            .cpu_after = .{ .user_ns = index * 1_000_000 + 1_000_000, .system_ns = 0 },
            .cpu_total_delta_ns = 1_000_000,
            .fd_count = 12,
            .resident_bytes = 20 * 1024 * 1024,
            .footprint_bytes = 18 * 1024 * 1024,
        };
    }
    break :blk out;
};
fn goodArtifact() Artifact {
    return .{
        .schema = schema_name,
        .scenario = "output-wake-continuous-idle",
        .build_mode = "ReleaseFast",
        .sample_api = "proc_pid_rusage:RUSAGE_INFO_V4",
        .run_nonce_hex = "0123456789abcdef0123456789abcdef",
        .session_root_kind = "fixture_nonce_0700",
        .session_root_mode = 0o700,
        .host_pid = 100,
        .host_start_abstime = 900,
        .child_pid = 101,
        .child_start_tvsec = 1234,
        .child_start_tvusec = 5678,
        .baseline_fd_count = 12,
        .windows = &good_windows,
        .final_marker_exact_count = 1,
        .final_marker_visible = true,
        .final_wake_notify_delta = 1,
        .final_wake_published_delta = 1,
        .final_wake_drain_delta = 1,
        .final_active_clients = 0,
        .child_reaped = true,
        .host_graceful_stop = true,
        .host_reaped = true,
        .socket_removed = true,
        .directory_removed = true,
    };
}

test "CR6f idle soak contract pins sixty non-overlapping ten-second windows" {
    const a = goodArtifact();
    try validateArtifact(a);
    try std.testing.expectEqual(@as(usize, 60), a.windows.len);
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_s), idle_soak_window_ns);
}
test "CR6f idle soak rejects isolation identity and cleanup drift" {
    var a = goodArtifact();
    a.session_root_kind = "default";
    try std.testing.expectError(error.InvalidIsolation, validateArtifact(a));
    a = goodArtifact();
    a.host_pid += 2;
    try std.testing.expectError(error.IdentityChanged, validateArtifact(a));
    a = goodArtifact();
    a.socket_removed = false;
    try std.testing.expectError(error.IncompleteCleanup, validateArtifact(a));
}
test "CR6f idle soak rejects one bad window and missing final wake" {
    var windows = good_windows;
    windows[37].wake_notify_delta = 1;
    var a = goodArtifact();
    a.windows = &windows;
    try std.testing.expectError(error.IdleWorkObserved, validateArtifact(a));
    windows = good_windows;
    windows[37].cpu_after.user_ns = windows[37].cpu_before.user_ns + idle_soak_window_ns;
    windows[37].cpu_total_delta_ns = idle_soak_window_ns;
    a.windows = &windows;
    try std.testing.expectError(error.CpuBudgetExceeded, validateArtifact(a));
    a = goodArtifact();
    a.final_marker_exact_count = 0;
    try std.testing.expectError(error.MissingFinalWake, validateArtifact(a));
}

test "CR6f idle soak JSON rejects unknown duplicate and missing fields" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{
        "{\"unknown\":1}",
        "{\"schema\":\"a\",\"schema\":\"b\"}",
        "{}",
    }) |bytes| {
        const parsed = std.json.parseFromSlice(Artifact, allocator, bytes, .{
            .ignore_unknown_fields = false,
            .duplicate_field_behavior = .@"error",
        });
        if (parsed) |value| {
            value.deinit();
            return error.ExpectedStrictSchemaRejection;
        } else |_| {}
    }
}
