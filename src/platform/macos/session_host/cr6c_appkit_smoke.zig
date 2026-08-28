//! CR6c actual-AppKit recovery harness.
//!
//! The harness owns only one unique current daemon/runtime, then execs the real Swift app bundle.
//! The app itself performs discovery and the NSEvent row action; this process never calls the
//! AppSession recovery action or constructs its projection.

const std = @import("std");
const builtin = @import("builtin");
const client_mod = @import("client.zig");
const discovery = @import("discovery.zig");
const host_manifest = @import("host_manifest.zig");
const short_endpoint = @import("short_endpoint.zig");

extern "c" fn usleep(useconds: c_uint) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

const recovery_baseline_iterations: usize = 5;

const RecoveryBaselineIteration = struct {
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

const RecoveryBaselineArtifact = struct {
    schema: []const u8,
    build_mode: []const u8,
    iteration_count: u32,
    host_id_hex: []const u8,
    iterations: []const RecoveryBaselineIteration,
    fd_before: u32,
    fd_after: u32,
    child_processes_remaining: u32,
    daemon_reaped: bool,
    socket_removed: bool,
    host_artifacts_removed: bool,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const fd_before = try countOpenFds(io);
    const app_raw = std.c.getenv("MARU_SESSION_HOST_CR6C_APP_EXE") orelse
        return error.MissingAppExecutable;
    const app_path = std.mem.span(app_raw);
    if (app_path.len == 0 or app_path[0] != '/') return error.InvalidAppExecutable;
    const app_path_z = try allocator.dupeZ(u8, app_path);
    defer allocator.free(app_path_z);
    const product_raw = std.c.getenv("MARU_SESSION_HOST_CR6C_PRODUCT_EXE") orelse
        return error.MissingProductExecutable;
    const product_path = std.mem.span(product_raw);
    if (product_path.len == 0 or product_path[0] != '/') return error.InvalidProductExecutable;
    const product_path_z = try allocator.dupeZ(u8, product_path);
    defer allocator.free(product_path_z);
    const input_continuity = std.c.getenv("MARU_SESSION_HOST_CR6D_INPUT_CONTINUITY_SMOKE") != null;
    const recovery_baseline_raw = std.c.getenv("MARU_SESSION_HOST_CR6E_RECOVERY_BASELINE_ARTIFACT");
    const recovery_baseline_path = if (recovery_baseline_raw) |raw| std.mem.span(raw) else null;
    if (recovery_baseline_path) |path| if (path.len == 0) return error.InvalidRecoveryBaselineArtifact;
    var restore_helper_path_z: ?[:0]u8 = null;
    defer if (restore_helper_path_z) |path| allocator.free(path);
    var restore_record_path_z: ?[:0]u8 = null;
    defer if (restore_record_path_z) |path| allocator.free(path);
    if (input_continuity) {
        const helper_raw = std.c.getenv("MARU_SESSION_HOST_CR6D_INPUT_SOURCE_RESTORE_EXE") orelse
            return error.MissingInputSourceRestoreExecutable;
        const helper_path = std.mem.span(helper_raw);
        if (helper_path.len == 0 or helper_path[0] != '/') return error.InvalidInputSourceRestoreExecutable;
        restore_helper_path_z = try allocator.dupeZ(u8, helper_path);
        const artifact_raw = std.c.getenv("MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT") orelse
            return error.MissingArtifactRoot;
        const artifact_root = std.mem.span(artifact_raw);
        if (artifact_root.len == 0 or artifact_root[0] != '/') return error.InvalidArtifactRoot;
        restore_record_path_z = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/input-source-restore.json",
            .{artifact_root},
            0,
        );
    }

    try short_endpoint.prepareCurrentUserNamespace();
    // 바로 위 `prepareCurrentUserNamespace` 가 준비한 **그 뿌리**를 쓴다. uid 로 다시 계산하면 준비한 자리와
    // 갈려, 격리를 켠 실행에서 사용자의 공용 registry 를 건드리게 된다.
    var base_buf: [256]u8 = undefined;
    const base = try short_endpoint.currentUserRootPathIn(&base_buf);
    var dir_buf: [192]u8 = undefined;
    const session_dir = try discovery.sessionHostDirPath(&dir_buf, base);
    const host_id = (@as(u128, @intCast(std.c.getpid())) << 64) | 0xC6C0_A77C_17A0_0001;
    var socket_buf: [160]u8 = undefined;
    const socket = try short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    const dir_z = try allocator.dupeZ(u8, session_dir);
    defer allocator.free(dir_z);
    const socket_z = try allocator.dupeZ(u8, socket);
    defer allocator.free(socket_z);
    var host_buf: [33]u8 = undefined;
    const host_text = try std.fmt.bufPrintZ(&host_buf, "{x:0>32}", .{host_id});

    // This harness owns exactly this PID-keyed host entry. Cleanup runs only after the later
    // terminateAndReap defer, so no live daemon can recreate files underneath it; sibling/user
    // hosts in the shared per-UID namespace are never enumerated or mutated here.
    var artifacts_owned = true;
    defer if (artifacts_owned) {
        _ = cleanupExactHostArtifacts(io, session_dir, socket, host_id);
    };

    const daemon_pid = std.c.fork();
    if (daemon_pid < 0) return error.ForkFailed;
    if (daemon_pid == 0) {
        _ = std.c.setsid();
        const argv = [_:null]?[*:0]const u8{
            product_path_z.ptr,
            "__session-host",
            dir_z.ptr,
            socket_z.ptr,
            host_text.ptr,
        };
        _ = std.c.execve(product_path_z.ptr, &argv, @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    var daemon_owned = true;
    defer if (daemon_owned) terminateAndReap(daemon_pid);

    var admin: ?client_mod.Client = null;
    var attempts: usize = 0;
    while (attempts < 250 and admin == null) : (attempts += 1) {
        admin = client_mod.Client.connect(allocator, socket, .gui) catch null;
        if (admin == null) _ = usleep(20 * 1000);
    }
    if (admin == null) return error.DaemonNotReady;
    defer if (admin) |*client| client.deinit();
    const spawn_params = if (input_continuity)
        "{\"argv\":[\"/bin/sh\",\"-c\",\"(while true; do while [ ! -f \\\"$MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT/e3c-wake-ready\\\" ]; do sleep 0.05; done; rm -f \\\"$MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT/e3c-wake-ready\\\"; printf 'E3C-APPKIT-ASYNC-WAKE\\n'; done) & printf 'CR6C-RECOVERED-MARKER\\nCR6D-HISTORICAL-ONCE\\n'; printf '\\\\033]52;c;Q1I2RC1ISVNUT1JJQ0FMLU9TQzUy\\\\007'; stty -echo; exec /bin/cat\"],\"cols\":80,\"rows\":24}"
    else
        "{\"argv\":[\"/bin/sh\",\"-c\",\"(while true; do while [ ! -f \\\"$MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT/e3c-wake-ready\\\" ]; do sleep 0.05; done; rm -f \\\"$MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT/e3c-wake-ready\\\"; printf 'E3C-APPKIT-ASYNC-WAKE\\n'; done) & printf 'CR6C-RECOVERED-MARKER\\n'; exec /bin/cat\"],\"cols\":80,\"rows\":24}";
    const spawn = try admin.?.call("runtime.spawn", spawn_params);
    defer allocator.free(spawn);
    const runtime_id = client_mod.extractRuntimeId(spawn) orelse return error.RuntimeIdMissing;
    const inventory = try admin.?.call(
        "runtime.inventory",
        "{\"cursor\":\"\",\"limit\":256,\"membership_generation\":0}",
    );
    defer allocator.free(inventory);
    std.debug.print("CR6c provisioning inventory: {s}\n", .{inventory});
    admin.?.deinit();
    admin = null;
    // Recovery discovery is a launch-time snapshot. Let the product poll owner observe the
    // provisioning GUI disconnect before the AppKit process takes that snapshot; otherwise the
    // still-attached runtime is correctly excluded and this fixture becomes scheduler-dependent.
    _ = usleep(250 * 1000);
    var runtime_id_z: [33]u8 = undefined;
    @memcpy(runtime_id_z[0..32], &runtime_id);
    runtime_id_z[32] = 0;
    if (setenv("MARU_SESSION_HOST_CR6C_RUNTIME_ID", @ptrCast(&runtime_id_z), 1) != 0)
        return error.EnvironmentFailed;

    var params_buf: [80]u8 = undefined;
    const params = try std.fmt.bufPrint(&params_buf, "{{\"runtime_id\":\"{s}\"}}", .{&runtime_id});
    var baseline_rows: [recovery_baseline_iterations]RecoveryBaselineIteration = undefined;
    const iteration_count: usize = if (recovery_baseline_path != null) recovery_baseline_iterations else 1;
    for (0..iteration_count) |iteration| {
        _ = std.c.unlink("zig-out/maru-macos-app/app.summary.txt");
        if (recovery_baseline_path != null) {
            var iteration_buf: [16]u8 = undefined;
            const iteration_z = try std.fmt.bufPrintZ(&iteration_buf, "{d}", .{iteration});
            if (setenv("MARU_SESSION_HOST_CR6E_RECOVERY_ITERATION", iteration_z.ptr, 1) != 0)
                return error.EnvironmentFailed;
        }
        const harness_launch_ns = monotonicNow(io);
        const app_pid = std.c.fork();
        if (app_pid < 0) return error.ForkFailed;
        if (app_pid == 0) {
            const argv = [_:null]?[*:0]const u8{app_path_z.ptr};
            _ = std.c.execve(app_path_z.ptr, &argv, @ptrCast(std.c.environ));
            std.c._exit(127);
        }
        var app_failure: ?anyerror = null;
        waitForExactExit(app_pid, 30_000) catch |err| {
            app_failure = err;
        };
        const harness_exit_ns = monotonicNow(io);
        if (input_continuity) {
            runInputSourceRestoreHelper(
                restore_helper_path_z.?.ptr,
                restore_record_path_z.?.ptr,
            ) catch |err| {
                std.debug.print("CR6d input-source restore helper failed: {s}\n", .{@errorName(err)});
                return err;
            };
            if (access(restore_record_path_z.?.ptr, 0) == 0) return error.InputSourceRestoreRecordSurvived;
        }
        if (app_failure) |err| return err;

        // AppKit teardown must detach from, not terminate, the keep-alive runtime.
        var verification_client = try client_mod.Client.connect(allocator, socket, .gui);
        const still_live = try verification_client.call("runtime.get", params);
        std.debug.print("CR6c post-AppKit runtime.get iteration {d}: {s}\n", .{ iteration, still_live });
        const runtime_survived = std.mem.indexOf(u8, still_live, &runtime_id) != null;
        const controller_zero = std.mem.indexOf(u8, still_live, "\"has_controller\":false") != null;
        const observer_zero = std.mem.indexOf(u8, still_live, "\"observer_count\":0") != null;
        allocator.free(still_live);
        verification_client.deinit();
        if (!runtime_survived) return error.RuntimeDidNotSurviveAppExit;
        if (!controller_zero) return error.ControllerAuthoritySurvivedAppExit;
        if (!observer_zero) return error.ObserverAuthoritySurvivedAppExit;

        if (recovery_baseline_path != null) {
            baseline_rows[iteration] = try readRecoveryBaselineIteration(
                allocator,
                io,
                @intCast(iteration),
                harness_launch_ns,
                harness_exit_ns,
                runtime_survived,
                controller_zero,
                observer_zero,
            );
        }
        if (iteration + 1 < iteration_count) _ = usleep(250 * 1000);
    }
    if (recovery_baseline_path != null and unsetenv("MARU_SESSION_HOST_CR6E_RECOVERY_ITERATION") != 0)
        return error.EnvironmentFailed;

    terminateAndReap(daemon_pid);
    daemon_owned = false;
    const host_artifacts_removed = cleanupExactHostArtifacts(io, session_dir, socket, host_id);
    if (!host_artifacts_removed) return error.ArtifactCleanupFailed;
    artifacts_owned = false;
    if (recovery_baseline_path) |path| {
        const fd_after = try countOpenFds(io);
        const child_processes_remaining = try remainingChildProcesses();
        try writeRecoveryBaselineArtifact(allocator, io, path, .{
            .schema = "maru.session-host-cr6e-recovery-baseline-macos.v2",
            .build_mode = @tagName(builtin.mode),
            .iteration_count = recovery_baseline_iterations,
            .host_id_hex = host_text,
            .iterations = &baseline_rows,
            .fd_before = fd_before,
            .fd_after = fd_after,
            .child_processes_remaining = child_processes_remaining,
            .daemon_reaped = true,
            .socket_removed = access(socket_z.ptr, 0) != 0,
            .host_artifacts_removed = host_artifacts_removed,
        });
    }
}

/// CR6d posts at the global HID tap, so its process must be launched through the same
fn monotonicNow(io: std.Io) u64 {
    const ns = std.Io.Clock.awake.now(io).nanoseconds;
    return if (ns <= 0) 0 else @intCast(ns);
}

fn readRecoveryBaselineIteration(
    allocator: std.mem.Allocator,
    io: std.Io,
    index: u32,
    harness_launch_ns: u64,
    harness_exit_ns: u64,
    runtime_survived: bool,
    controller_zero: bool,
    observer_zero: bool,
) !RecoveryBaselineIteration {
    const summary = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/maru-macos-app/app.summary.txt",
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(summary);
    const stage = try summaryU32(summary, "session_host_recovery_smoke_stage");
    const marker = try summaryBool(summary, "session_host_recovery_smoke_marker_present");
    const async_marker = try summaryBool(summary, "session_host_recovery_smoke_async_wake_marker_present");
    const before_capture = try summaryBool(summary, "session_host_recovery_smoke_before_capture");
    const after_capture = try summaryBool(summary, "session_host_recovery_smoke_after_capture");
    const failure = summaryValue(summary, "session_host_recovery_smoke_failure") orelse
        return error.InvalidRecoverySummary;
    const row: RecoveryBaselineIteration = .{
        .index = index,
        .swift_iteration = try summaryU32(summary, "session_host_recovery_smoke_baseline_iteration"),
        .harness_launch_ns = harness_launch_ns,
        .swift_launch_ns = try summaryU64(summary, "session_host_recovery_smoke_launch_ns"),
        .row_ns = try summaryU64(summary, "session_host_recovery_smoke_row_ns"),
        .click_ns = try summaryU64(summary, "session_host_recovery_smoke_click_ns"),
        .remote_visible_ns = try summaryU64(summary, "session_host_recovery_smoke_remote_visible_ns"),
        .summary_ns = try summaryU64(summary, "session_host_recovery_smoke_summary_ns"),
        .harness_exit_ns = harness_exit_ns,
        .stage = stage,
        .marker_present = marker,
        .async_wake_marker_present = async_marker,
        .wake_handler_count = try summaryU64(summary, "session_host_recovery_smoke_wake_handler_count"),
        .wake_apply_latency_ns = try summaryU64(summary, "session_host_recovery_smoke_async_wake_apply_latency_ns"),
        .before_capture = before_capture,
        .after_capture = after_capture,
        .runtime_survived = runtime_survived,
        .controller_zero = controller_zero,
        .observer_zero = observer_zero,
    };
    if (row.swift_iteration != index or stage != 2 or !marker or !async_marker or
        row.wake_handler_count == 0 or row.wake_apply_latency_ns == 0 or
        row.wake_apply_latency_ns > 60 * std.time.ns_per_ms or !before_capture or !after_capture or
        failure.len != 0 or
        !(row.harness_launch_ns <= row.swift_launch_ns and
            row.swift_launch_ns < row.row_ns and row.row_ns < row.click_ns and
            row.click_ns < row.remote_visible_ns and row.remote_visible_ns <= row.summary_ns and
            row.summary_ns <= row.harness_exit_ns))
        return error.InvalidRecoverySummary;
    return row;
}

fn summaryValue(summary: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, summary, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..separator], key)) return line[separator + 1 ..];
    }
    return null;
}

fn summaryU64(summary: []const u8, key: []const u8) !u64 {
    const value = summaryValue(summary, key) orelse return error.InvalidRecoverySummary;
    return std.fmt.parseInt(u64, value, 10) catch return error.InvalidRecoverySummary;
}

fn summaryU32(summary: []const u8, key: []const u8) !u32 {
    const value = summaryValue(summary, key) orelse return error.InvalidRecoverySummary;
    return std.fmt.parseInt(u32, value, 10) catch return error.InvalidRecoverySummary;
}

fn countOpenFds(io: std.Io) !u32 {
    var dir = try std.Io.Dir.openDirAbsolute(io, "/dev/fd", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: u32 = 0;
    while (try iterator.next(io)) |_| count = std.math.add(u32, count, 1) catch
        return error.FdCountOverflow;
    return count;
}

fn remainingChildProcesses() !u32 {
    var status: c_int = 0;
    const result = std.c.waitpid(-1, &status, std.c.W.NOHANG);
    if (result == 0 or result > 0) return 1;
    if (std.posix.errno(result) == .CHILD) return 0;
    return error.ChildProcessAuditFailed;
}

fn summaryBool(summary: []const u8, key: []const u8) !bool {
    const value = summaryValue(summary, key) orelse return error.InvalidRecoverySummary;
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidRecoverySummary;
}

fn writeRecoveryBaselineArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    artifact: RecoveryBaselineArtifact,
) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.write(artifact);
    try out.writer.writeByte('\n');
    const temp = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, std.c.getpid() });
    defer allocator.free(temp);
    const temp_z = try allocator.dupeZ(u8, temp);
    defer allocator.free(temp_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    defer _ = std.c.unlink(temp_z.ptr);
    const fd = std.c.open(temp_z.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.ArtifactCreateFailed;
    var fd_open = true;
    defer if (fd_open) {
        _ = std.c.close(fd);
    };
    var offset: usize = 0;
    while (offset < out.written().len) {
        const amount = std.c.write(fd, out.written()[offset..].ptr, out.written().len - offset);
        if (amount < 0 and std.posix.errno(amount) == .INTR) continue;
        if (amount <= 0) return error.ArtifactWriteFailed;
        offset += @intCast(amount);
    }
    if (std.c.close(fd) != 0) return error.ArtifactWriteFailed;
    fd_open = false;
    if (std.c.rename(temp_z.ptr, path_z.ptr) != 0) return error.ArtifactRenameFailed;
}

fn waitForExactExit(pid: c_int, timeout_ms: usize) !void {
    var status: c_int = 0;
    var elapsed: usize = 0;
    while (elapsed < timeout_ms) : (elapsed += 5) {
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) {
            const unsigned: u32 = @bitCast(status);
            if (!std.c.W.IFEXITED(unsigned) or std.c.W.EXITSTATUS(unsigned) != 0) {
                std.debug.print("CR6c AppKit child wait status=0x{x}\n", .{unsigned});
                return error.AppFailed;
            }
            return;
        }
        if (rc < 0) return error.WaitFailed;
        _ = usleep(5 * 1000);
    }
    _ = std.c.kill(pid, std.posix.SIG.KILL);
    while (std.c.waitpid(pid, &status, 0) < 0) {
        if (std.posix.errno(-1) != .INTR) break;
    }
    return error.AppTimedOut;
}

fn runInputSourceRestoreHelper(helper_path: [*:0]const u8, record_path: [*:0]const u8) !void {
    const pid = std.c.fork();
    if (pid < 0) return error.RestoreHelperForkFailed;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ helper_path, record_path };
        _ = std.c.execve(helper_path, &argv, @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    var status: c_int = 0;
    var elapsed: usize = 0;
    while (elapsed < 5_000) : (elapsed += 5) {
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) {
            const unsigned: u32 = @bitCast(status);
            if (!std.c.W.IFEXITED(unsigned) or std.c.W.EXITSTATUS(unsigned) != 0)
                return error.InputSourceRestoreFailed;
            return;
        }
        if (rc < 0) return error.RestoreHelperWaitFailed;
        _ = usleep(5 * 1000);
    }
    _ = std.c.kill(pid, std.posix.SIG.KILL);
    while (std.c.waitpid(pid, &status, 0) < 0) {
        if (std.posix.errno(-1) != .INTR) break;
    }
    return error.RestoreHelperTimedOut;
}

fn terminateAndReap(pid: c_int) void {
    _ = std.c.kill(pid, std.posix.SIG.TERM);
    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 400) : (attempts += 1) {
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) return;
        if (rc < 0) return;
        _ = usleep(5 * 1000);
    }
    _ = std.c.kill(pid, std.posix.SIG.KILL);
    while (std.c.waitpid(pid, &status, 0) < 0) {
        if (std.posix.errno(-1) != .INTR) return;
    }
}

fn cleanupExactHostArtifacts(
    io: std.Io,
    session_dir: [:0]const u8,
    socket: [:0]const u8,
    host_id: u128,
) bool {
    _ = std.c.unlink(socket.ptr);
    var host_dir_buf: [768]u8 = undefined;
    const host_dir = host_manifest.hostDirPathIn(&host_dir_buf, session_dir, host_id) catch
        return false;
    std.Io.Dir.cwd().deleteTree(io, host_dir) catch {};
    var log_buf: [768]u8 = undefined;
    const log_path = std.fmt.bufPrintZ(&log_buf, "{s}/host-{x:0>32}.log", .{ session_dir, host_id }) catch
        return false;
    _ = std.c.unlink(log_path.ptr);

    return access(socket.ptr, 0) != 0 and
        access(host_dir.ptr, 0) != 0 and
        access(log_path.ptr, 0) != 0;
}
