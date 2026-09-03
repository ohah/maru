//! CR6c actual-AppKit recovery harness.
//!
//! The harness owns one unique current daemon and, for CR6e-c3c, two runtimes, then execs the real Swift app bundle.
//! The app itself performs discovery and the NSEvent row action; this process never calls the
//! AppSession recovery action or constructs its projection.

const std = @import("std");
const builtin = @import("builtin");
const client_mod = @import("client.zig");
const discovery = @import("discovery.zig");
const host_manifest = @import("host_manifest.zig");
const short_endpoint = @import("short_endpoint.zig");
const daemon = @import("daemon.zig");
const poll_owner = @import("poll_owner.zig");
const runtime_manager = @import("runtime_manager.zig");
const code_signature = @import("code_signature.zig");
const upgrade_limits = @import("upgrade_limits.zig");

extern "c" fn usleep(useconds: c_uint) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

const recovery_baseline_iterations: usize = 5;
const signed_app_quit_iteration_count: usize = 2;
const max_candidate_bytes: u64 = 2 * 1024 * 1024 * 1024 - 1;

const ReleaseEvidenceConfig = struct {
    test_uuid: []u8,
    candidate_dmg: [:0]u8,
    frozen_executable: [:0]u8,
    output: [:0]u8,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.test_uuid);
        allocator.free(self.candidate_dmg);
        allocator.free(self.frozen_executable);
        allocator.free(self.output);
        self.* = undefined;
    }
};
const SignedAppQuitConfig = ReleaseEvidenceConfig;
const DefaultFalseConfig = ReleaseEvidenceConfig;

const ReleaseEvidenceEnv = struct {
    uuid: [*:0]const u8,
    dmg: [*:0]const u8,
    frozen: [*:0]const u8,
    output: [*:0]const u8,
};

const CandidateIdentity = struct {
    dev: i64,
    ino: u64,
    size: u64,
    mode: u32,
    modified_sec: i64,
    modified_nsec: i64,
    changed_sec: i64,
    changed_nsec: i64,
    sha256: [32]u8,
};

const SignedCandidateSet = struct {
    dmg: CandidateIdentity,
    frozen: CandidateIdentity,
    app: CandidateIdentity,
};

const AutoReconnectArtifact = struct {
    schema: []const u8 = "maru.session-host-cr6e-c3c-appkit.v1",
    build_mode: []const u8,
    identity: struct {
        host_id_before: []const u8,
        host_id_after: []const u8,
        runtime_id_before: []const u8,
        runtime_id_after: []const u8,
        host_pid_before: i32,
        host_pid_after: i32,
        child_pid_before: i32,
        child_pid_after: i32,
    },
    continuity: struct {
        historical_before_count: u32,
        historical_after_count: u32,
        disconnect_after_count: u32,
        input_count: u32,
        copy_count: u32,
        resize_count: u32,
    },
    sibling: struct {
        runtime_id: []const u8,
        live_before: bool,
        live_after: bool,
        controller_before: bool,
        controller_after: bool,
    },
    frame: struct {
        blocking_operations: u32,
        max_stall_ns: u64,
    },
    cleanup: struct {
        worker: u32,
        jobs: u32,
        completion: u32,
        cr5_jobs: u32,
        admissions: u32,
        resident_leases: u32,
        backend_runtimes: u32,
        clients: u32,
        fds: u32,
        fd_before: u32,
        fd_after: u32,
        child_processes_remaining: u32,
        daemon_reaped: bool,
        socket_removed: bool,
        host_artifacts_removed: bool,
    },
};

const RuntimeProcessIdentity = struct {
    host_pid: i32,
    child_pid: i32,
};

const AutoReconnectFault = struct {
    trigger_path: [:0]const u8,
    output_path: [:0]const u8,
    fired: bool = false,
    output_armed: bool = false,

    fn afterTurn(
        context: *anyopaque,
        _: poll_owner.TelemetrySnapshot,
        _: u64,
        _: runtime_manager.RuntimeManager.OutputWakeEvidence,
        _: runtime_manager.RuntimeManager.ChildExitEvidence,
        _: runtime_manager.RuntimeManager.ObservationPerformanceEvidence,
        _: runtime_manager.RuntimeManager.MetadataSamplerEvidence,
        _: runtime_manager.RuntimeManager.ScreenPerformanceEvidence,
    ) daemon.FixtureAction {
        const self: *AutoReconnectFault = @ptrCast(@alignCast(context));
        if (!self.fired) {
            if (access(self.trigger_path.ptr, 0) != 0) return .continue_serving;
            if (std.c.unlink(self.trigger_path.ptr) != 0) return .continue_serving;
            self.fired = true;
            return .disconnect_clients;
        }
        // The action above is applied only after this callback returns. Arm PTY output on the
        // following owner turn so no byte can escape through the connection being invalidated.
        if (self.output_armed) return .continue_serving;
        const fd = std.c.open(self.output_path.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return .continue_serving;
        _ = std.c.close(fd);
        self.output_armed = true;
        return .continue_serving;
    }

    fn probe(self: *AutoReconnectFault) daemon.FixtureProbe {
        return .{ .ctx = self, .after_turn = afterTurn };
    }
};

/// **비동기 wake 적용 지연의 상한**(handler 진입 → 화면 반영). 이 축의 단일 출처다 — 예전에는 같은
/// `60ms` 가 여기·`build.zig` 의 awk 검증·`tools/perf/session_host_cr6e_recovery_validator.zig` 세 곳에
/// 각자 적혀 있었고, 셋이 갈리면 "어느 게이트는 통과하고 어느 게이트는 죽는" 상태가 된다.
///
/// **60ms → 200ms 로 올린다(2026-09-01). 코드가 느려진 것이 아니라 선이 러너를 재고 있었다.**
/// 실측:
///
/// | 환경 | 값 |
/// |---|---|
/// | 로컬(M 시리즈, 3 회) | 24.10 · 24.04 · 24.14 ms — 흔들림이 0.1ms 안쪽이다 |
/// | CI 러너 정상(2 건) | 36.1 · 42.0 ms |
/// | CI 러너 부하(4 건) | 60.4 · 61.8 · 63.3 · 71.6 ms ← **전부 옛 선 60ms 를 아슬아슬하게 넘겼다** |
///
/// 옛 선은 CI 정상값의 **1.4 배**였다. [성능 예산](../../../../docs/performance-budget.md)이 정한
/// 실무 기준은 **실측의 4~5 배**이고, *"너무 빡빡하면 감지선이 아니라 동전 던지기"* 라는 경고가 같은
/// 문서에 있다(실측 373ms 에 선을 500 으로 두었다가 CI 가 501ms 를 내며 main 을 반반으로 흔든 사건).
/// 이 자리가 그 형태를 그대로 반복했다 — 무관한 PR 다섯이 이 게이트 하나에 막혔다(2026-08-31).
///
/// **새 선의 두 값**(그 문서가 요구하는 "지금 값과 잡겠다는 회귀의 값"):
/// - 지금 값: CI 정상 36~42ms → 200ms 는 그 **4.8 배**이고 관측된 최악(71.6ms)의 **2.8 배**다.
/// - 잡겠다는 회귀: 비동기 wake 가 안 걸려 **폴링으로 떨어지는** 것. 그 경우 지연이 cadence 주기에
///   묶여 **수백 ms** 가 되므로 200ms 위로 확실히 나온다. 즉 두 값이 겹치지 않아 벽시계가 여전히
///   유효한 판정자다(겹쳤다면 호출 수 같은 기계-무관 값으로 갈아탔어야 한다).
pub const wake_apply_latency_budget_ns: u64 = 200 * std.time.ns_per_ms;

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
    var signed_app_quit = try readSignedAppQuitConfig(allocator);
    defer if (signed_app_quit) |*config| config.deinit(allocator);
    var default_false = try readDefaultFalseConfig(allocator);
    defer if (default_false) |*config| config.deinit(allocator);
    if (signed_app_quit != null and default_false != null) return error.ConflictingReleaseEvidenceModes;
    const fd_before = try countOpenFds(io);
    const app_raw = std.c.getenv("MARU_SESSION_HOST_CR6C_APP_EXE") orelse
        return error.MissingAppExecutable;
    const app_path = std.mem.span(app_raw);
    if (app_path.len == 0 or app_path[0] != '/') return error.InvalidAppExecutable;
    const app_path_z = try allocator.dupeZ(u8, app_path);
    defer allocator.free(app_path_z);
    if (signed_app_quit) |config| {
        if (std.mem.eql(u8, config.output, app_path_z)) return error.InvalidSignedAppQuitPath;
        try validateReleaseWorkspace(config.output, .signed_app_quit);
    }
    if (default_false) |config| {
        if (std.mem.eql(u8, config.output, app_path_z)) return error.InvalidDefaultFalsePath;
        try validateReleaseWorkspace(config.output, .default_false);
    }
    if (default_false) |config| {
        if (!upgrade_limits.canonicalReleaseTestUuid(config.test_uuid)) return error.InvalidTestUuid;
        const before = try inspectDefaultFalseCandidate(io, config, app_path_z);
        if (setenv("MARU_SESSION_DEFAULT_FALSE_EVIDENCE_SMOKE", "1", 1) != 0)
            return error.EnvironmentFailed;
        defer _ = unsetenv("MARU_SESSION_DEFAULT_FALSE_EVIDENCE_SMOKE");
        const app_pid = std.c.fork();
        if (app_pid < 0) return error.ForkFailed;
        if (app_pid == 0) {
            const argv = [_:null]?[*:0]const u8{app_path_z.ptr};
            _ = std.c.execve(app_path_z.ptr, &argv, @ptrCast(std.c.environ));
            std.c._exit(127);
        }
        try waitForExactExit(app_pid, 30_000);
        try validateDefaultFalseCandidate(io, config, app_path_z, before);
        if (try remainingChildProcesses() != 0 or try countOpenFds(io) != fd_before)
            return error.ProcessCleanupIncomplete;
        try writeDefaultFalseArtifact(io, config, before.dmg.sha256, before.frozen.sha256);
        return;
    }
    const product_raw = std.c.getenv("MARU_SESSION_HOST_CR6C_PRODUCT_EXE") orelse
        return error.MissingProductExecutable;
    const product_path = std.mem.span(product_raw);
    if (product_path.len == 0 or product_path[0] != '/') return error.InvalidProductExecutable;
    const product_path_z = try allocator.dupeZ(u8, product_path);
    defer allocator.free(product_path_z);
    const signed_candidate_before = if (signed_app_quit) |config| blk: {
        if (!upgrade_limits.canonicalReleaseTestUuid(config.test_uuid))
            return error.InvalidTestUuid;
        break :blk try inspectSignedCandidate(
            io,
            config.candidate_dmg,
            config.frozen_executable,
            app_path_z,
        );
    } else null;
    const input_continuity = std.c.getenv("MARU_SESSION_HOST_CR6D_INPUT_CONTINUITY_SMOKE") != null;
    const recovery_baseline_raw = std.c.getenv("MARU_SESSION_HOST_CR6E_RECOVERY_BASELINE_ARTIFACT");
    const recovery_baseline_path = if (recovery_baseline_raw) |raw| std.mem.span(raw) else null;
    if (recovery_baseline_path) |path| if (path.len == 0) return error.InvalidRecoveryBaselineArtifact;
    const auto_reconnect_raw = std.c.getenv("MARU_SESSION_HOST_CR6E_C3C_AUTO_RECONNECT_ARTIFACT");
    const auto_reconnect_path = if (auto_reconnect_raw) |raw| std.mem.span(raw) else null;
    if (auto_reconnect_path) |path| if (path.len == 0) return error.InvalidAutoReconnectArtifact;
    const auto_reconnect = auto_reconnect_path != null;
    const artifact_root_raw = std.c.getenv("MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT") orelse
        return error.MissingArtifactRoot;
    const artifact_root = std.mem.span(artifact_root_raw);
    if (artifact_root.len == 0 or artifact_root[0] != '/') return error.InvalidArtifactRoot;
    const disconnect_trigger = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/c3c-disconnect-ready",
        .{artifact_root},
        0,
    );
    defer allocator.free(disconnect_trigger);
    const after_disconnect_output = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/c3c-after-disconnect-output",
        .{artifact_root},
        0,
    );
    defer allocator.free(after_disconnect_output);
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
        restore_record_path_z = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/input-source-restore.json",
            .{artifact_root},
            0,
        );
    }

    // Release evidence paths are already sealed by validateReleaseWorkspace. Other product smokes
    // still receive their isolated root from build.zig; never replace either with an ambient path.
    const isolated_root_raw = std.c.getenv(short_endpoint.root_override_env) orelse
        return error.MissingSessionHostRoot;
    const isolated_root: ?[:0]const u8 = std.mem.span(isolated_root_raw);
    try short_endpoint.prepareCurrentUserNamespace();
    // 바로 위 `prepareCurrentUserNamespace` 가 준비한 **그 뿌리**를 쓴다. uid 로 다시 계산하면 준비한 자리와
    // 갈려, 격리를 켠 실행에서 사용자의 공용 registry 를 건드리게 된다.
    var base_buf: [256]u8 = undefined;
    const base = try short_endpoint.currentUserRootPathIn(&base_buf);
    var dir_buf: [192]u8 = undefined;
    const session_dir = try discovery.sessionHostDirPath(&dir_buf, base);
    defer if (isolated_root) |root| {
        var socket_dir_buf: [96]u8 = undefined;
        const socket_dir = short_endpoint.socketDirPathUnder(&socket_dir_buf, root) catch null;
        _ = std.c.rmdir(session_dir.ptr);
        if (socket_dir) |path| _ = std.c.rmdir(path.ptr);
        _ = std.c.rmdir(root.ptr);
    };
    const host_id = (@as(u128, @intCast(std.c.getpid())) << 64) | 0xC6C0_A77C_17A0_0001;
    var socket_buf: [160]u8 = undefined;
    const socket = if (isolated_root) |root|
        try short_endpoint.socketPathUnder(&socket_buf, root, host_id)
    else
        try short_endpoint.currentSocketPathIn(&socket_buf, host_id);
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
        if (auto_reconnect) {
            var fault = AutoReconnectFault{
                .trigger_path = disconnect_trigger,
                .output_path = after_disconnect_output,
            };
            daemon.runSessionHostWithIdentityForFixture(
                std.heap.page_allocator,
                io,
                dir_z,
                socket_z,
                host_id,
                fault.probe(),
            ) catch std.c._exit(126);
            std.c._exit(0);
        }
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
    var sibling_runtime_id: [32]u8 = [_]u8{'0'} ** 32;
    if (auto_reconnect) {
        const sibling_spawn = try admin.?.call(
            "runtime.spawn",
            "{\"argv\":[\"/bin/sh\",\"-c\",\"printf 'CR6C-RECOVERED-MARKER\\nCR6E-C3C-SIBLING-LIVE\\n'; exec /bin/cat\"],\"cols\":80,\"rows\":24}",
        );
        defer allocator.free(sibling_spawn);
        sibling_runtime_id = client_mod.extractRuntimeId(sibling_spawn) orelse
            return error.RuntimeIdMissing;
    }
    const spawn_params = if (auto_reconnect)
        "{\"argv\":[\"/bin/sh\",\"-c\",\"(while [ ! -f \\\"$MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT/c3c-after-disconnect-output\\\" ]; do sleep 0.05; done; rm -f \\\"$MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT/c3c-after-disconnect-output\\\"; printf 'E3C-APPKIT-ASYNC-WAKE\\nCR6E-C3C-AUTO-RECONNECTED\\n') & printf 'CR6C-RECOVERED-MARKER\\nCR6E-C3C-HISTORICAL-ONCE\\n'; exec /bin/cat\"],\"cols\":80,\"rows\":24}"
    else if (input_continuity)
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
    var runtime_id_z: [33]u8 = undefined;
    @memcpy(runtime_id_z[0..32], &runtime_id);
    runtime_id_z[32] = 0;
    if (auto_reconnect) {
        var sibling_runtime_id_z: [33]u8 = undefined;
        @memcpy(sibling_runtime_id_z[0..32], &sibling_runtime_id);
        sibling_runtime_id_z[32] = 0;
        if (setenv("MARU_SESSION_HOST_CR6E_C3C_PRIMARY_RUNTIME_ID", @ptrCast(&runtime_id_z), 1) != 0 or
            setenv("MARU_SESSION_HOST_CR6E_C3C_SIBLING_RUNTIME_ID", @ptrCast(&sibling_runtime_id_z), 1) != 0 or
            setenv("MARU_SESSION_HOST_CR6C_RUNTIME_ID", @ptrCast(&sibling_runtime_id_z), 1) != 0)
            return error.EnvironmentFailed;
    } else if (setenv("MARU_SESSION_HOST_CR6C_RUNTIME_ID", @ptrCast(&runtime_id_z), 1) != 0) {
        return error.EnvironmentFailed;
    }

    var params_buf: [80]u8 = undefined;
    const params = try std.fmt.bufPrint(&params_buf, "{{\"runtime_id\":\"{s}\"}}", .{&runtime_id});
    var sibling_params_buf: [80]u8 = undefined;
    const sibling_params = if (auto_reconnect)
        try std.fmt.bufPrint(&sibling_params_buf, "{{\"runtime_id\":\"{s}\"}}", .{&sibling_runtime_id})
    else
        "";
    const process_identity_before = if (auto_reconnect or signed_app_quit != null)
        try queryRuntimeProcessIdentity(allocator, socket, &runtime_id)
    else
        RuntimeProcessIdentity{ .host_pid = 0, .child_pid = 0 };
    // Recovery discovery is a launch-time snapshot. A fixed sleep made this fixture depend on the
    // daemon scheduler: if the provisioning disconnect had not reached the poll owner yet, the
    // correctly still-attached runtime was omitted and the AppKit test never entered recovery.
    // Observe the exact runtime's detached authority before launching instead.
    var detach_observed = false;
    for (0..250) |_| {
        var observer = client_mod.Client.connect(allocator, socket, .gui) catch {
            _ = usleep(20 * 1000);
            continue;
        };
        const state = observer.call("runtime.get", params) catch {
            observer.deinit();
            _ = usleep(20 * 1000);
            continue;
        };
        detach_observed = std.mem.indexOf(u8, state, "\"has_controller\":false") != null and
            std.mem.indexOf(u8, state, "\"observer_count\":0") != null;
        allocator.free(state);
        if (detach_observed and auto_reconnect) {
            const sibling_state = observer.call("runtime.get", sibling_params) catch {
                observer.deinit();
                _ = usleep(20 * 1000);
                continue;
            };
            detach_observed = std.mem.indexOf(u8, sibling_state, "\"has_controller\":false") != null and
                std.mem.indexOf(u8, sibling_state, "\"observer_count\":0") != null;
            allocator.free(sibling_state);
        }
        observer.deinit();
        if (detach_observed) break;
        _ = usleep(20 * 1000);
    }
    if (!detach_observed) return error.ProvisioningAuthorityDidNotDetach;

    var baseline_rows: [recovery_baseline_iterations]RecoveryBaselineIteration = undefined;
    var auto_process_identity_after: RuntimeProcessIdentity = .{ .host_pid = 0, .child_pid = 0 };
    var signed_rows: [signed_app_quit_iteration_count]RecoveryBaselineIteration = undefined;
    const iteration_count: usize = if (recovery_baseline_path != null)
        recovery_baseline_iterations
    else if (signed_app_quit != null)
        signed_app_quit_iteration_count
    else
        1;
    for (0..iteration_count) |iteration| {
        if (signed_app_quit) |config|
            try validateSignedCandidate(io, config, app_path_z, signed_candidate_before.?);
        _ = std.c.unlink(appSummaryPath().ptr);
        if (recovery_baseline_path != null or signed_app_quit != null) {
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
        waitForExactExit(app_pid, if (auto_reconnect) 45_000 else 30_000) catch |err| {
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
        var sibling_runtime_survived = true;
        var sibling_controller_zero = true;
        var sibling_observer_zero = true;
        if (auto_reconnect) {
            const sibling_live = try verification_client.call("runtime.get", sibling_params);
            sibling_runtime_survived = std.mem.indexOf(u8, sibling_live, &sibling_runtime_id) != null;
            sibling_controller_zero = std.mem.indexOf(u8, sibling_live, "\"has_controller\":false") != null;
            sibling_observer_zero = std.mem.indexOf(u8, sibling_live, "\"observer_count\":0") != null;
            allocator.free(sibling_live);
        }
        verification_client.deinit();
        const process_identity_after = if (auto_reconnect or signed_app_quit != null)
            try queryRuntimeProcessIdentity(allocator, socket, &runtime_id)
        else
            RuntimeProcessIdentity{ .host_pid = 0, .child_pid = 0 };
        if (auto_reconnect) auto_process_identity_after = process_identity_after;
        if ((auto_reconnect or signed_app_quit != null) and
            (process_identity_before.host_pid != process_identity_after.host_pid or
                process_identity_before.child_pid != process_identity_after.child_pid))
            return error.RuntimeProcessIdentityDrift;
        if (!runtime_survived) return error.RuntimeDidNotSurviveAppExit;
        if (!controller_zero) return error.ControllerAuthoritySurvivedAppExit;
        if (!observer_zero) return error.ObserverAuthoritySurvivedAppExit;
        if (!sibling_runtime_survived) return error.SiblingRuntimeDidNotSurviveAppExit;
        if (!sibling_controller_zero) return error.SiblingControllerAuthoritySurvivedAppExit;
        if (!sibling_observer_zero) return error.SiblingObserverAuthoritySurvivedAppExit;

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
        if (signed_app_quit != null) {
            signed_rows[iteration] = try readRecoveryBaselineIteration(
                allocator,
                io,
                @intCast(iteration),
                harness_launch_ns,
                harness_exit_ns,
                runtime_survived,
                controller_zero,
                observer_zero,
            );
            const row = signed_rows[iteration];
            if (row.stage != 2 or !row.marker_present or !row.async_wake_marker_present or
                !row.before_capture or !row.after_capture)
                return error.SignedAppQuitObservationIncomplete;
        }
        if (iteration + 1 < iteration_count) _ = usleep(250 * 1000);
    }
    if ((recovery_baseline_path != null or signed_app_quit != null) and
        unsetenv("MARU_SESSION_HOST_CR6E_RECOVERY_ITERATION") != 0)
        return error.EnvironmentFailed;

    terminateAndReap(daemon_pid);
    daemon_owned = false;
    const host_artifacts_removed = cleanupExactHostArtifacts(io, session_dir, socket, host_id);
    if (!host_artifacts_removed) return error.ArtifactCleanupFailed;
    artifacts_owned = false;
    if (signed_app_quit) |config| {
        const before = signed_candidate_before.?;
        try validateSignedCandidate(io, config, app_path_z, before);
        if (!host_artifacts_removed or access(socket_z.ptr, 0) == 0)
            return error.ArtifactCleanupFailed;
        if (try remainingChildProcesses() != 0 or try countOpenFds(io) != fd_before)
            return error.ProcessCleanupIncomplete;
        try writeSignedAppQuitArtifact(io, config, before.dmg.sha256, before.frozen.sha256);
    }
    if (recovery_baseline_path) |path| {
        const fd_after = try countOpenFds(io);
        const child_processes_remaining = try remainingChildProcesses();
        try writeStrictArtifact(allocator, io, path, .{
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
    if (auto_reconnect_path) |path| {
        const summary = try std.Io.Dir.cwd().readFileAlloc(
            io,
            appSummaryPath(),
            allocator,
            .limited(4 * 1024 * 1024),
        );
        defer allocator.free(summary);
        const failure = summaryValue(summary, "session_host_recovery_smoke_failure") orelse
            return error.InvalidRecoverySummary;
        if (failure.len != 0) return error.InvalidRecoverySummary;
        const fd_after = try countOpenFds(io);
        const child_processes_remaining = try remainingChildProcesses();
        try writeStrictArtifact(allocator, io, path, AutoReconnectArtifact{
            .build_mode = @tagName(builtin.mode),
            .identity = .{
                .host_id_before = host_text,
                .host_id_after = host_text,
                .runtime_id_before = &runtime_id,
                .runtime_id_after = &runtime_id,
                .host_pid_before = process_identity_before.host_pid,
                .host_pid_after = auto_process_identity_after.host_pid,
                .child_pid_before = process_identity_before.child_pid,
                .child_pid_after = auto_process_identity_after.child_pid,
            },
            .continuity = .{
                .historical_before_count = try summaryU32(summary, "session_host_auto_reconnect_historical_before_count"),
                .historical_after_count = try summaryU32(summary, "session_host_auto_reconnect_historical_count"),
                .disconnect_after_count = try summaryU32(summary, "session_host_auto_reconnect_disconnect_after_count"),
                .input_count = try summaryU32(summary, "session_host_auto_reconnect_input_count"),
                .copy_count = try summaryU32(summary, "session_host_auto_reconnect_copy_count"),
                .resize_count = try summaryU32(summary, "session_host_auto_reconnect_resize_count"),
            },
            .sibling = .{
                .runtime_id = &sibling_runtime_id,
                .live_before = try summaryBool(summary, "session_host_auto_reconnect_sibling_live_before"),
                .live_after = try summaryBool(summary, "session_host_auto_reconnect_sibling_live_after"),
                .controller_before = try summaryBool(summary, "session_host_auto_reconnect_sibling_controller_before"),
                .controller_after = try summaryBool(summary, "session_host_auto_reconnect_sibling_controller_after"),
            },
            .frame = .{
                .blocking_operations = try summaryU32(summary, "session_host_reconnect_blocking_operations"),
                .max_stall_ns = try summaryU64(summary, "session_host_reconnect_tick_max_elapsed_ns"),
            },
            .cleanup = .{
                .worker = try summaryU32(summary, "session_host_reconnect_final_worker"),
                .jobs = try summaryU32(summary, "session_host_reconnect_final_jobs"),
                .completion = try summaryU32(summary, "session_host_reconnect_final_completion"),
                .cr5_jobs = try summaryU32(summary, "session_host_reconnect_final_cr5_jobs"),
                .admissions = try summaryU32(summary, "session_host_reconnect_final_admissions"),
                .resident_leases = try summaryU32(summary, "session_host_reconnect_final_resident_leases"),
                .backend_runtimes = try summaryU32(summary, "session_host_reconnect_final_backend_runtimes"),
                .clients = 0,
                .fds = 0,
                .fd_before = fd_before,
                .fd_after = fd_after,
                .child_processes_remaining = child_processes_remaining,
                .daemon_reaped = true,
                .socket_removed = access(socket_z.ptr, 0) != 0,
                .host_artifacts_removed = host_artifacts_removed,
            },
        });
    }
}

fn queryRuntimeProcessIdentity(
    allocator: std.mem.Allocator,
    socket: [:0]const u8,
    runtime_id: *const [32]u8,
) !RuntimeProcessIdentity {
    var client = try client_mod.Client.connect(allocator, socket, .gui);
    defer client.deinit();
    var attach_buf: [128]u8 = undefined;
    const attach_params = try std.fmt.bufPrint(
        &attach_buf,
        "{{\"runtime_id\":\"{s}\",\"mode\":\"observer\"}}",
        .{runtime_id},
    );
    const attach = try client.call("runtime.attach", attach_params);
    defer allocator.free(attach);
    var parsed_attach = std.json.parseFromSlice(std.json.Value, allocator, attach, .{}) catch
        return error.InvalidAttachIdentity;
    defer parsed_attach.deinit();
    const attach_result = switch (parsed_attach.value) {
        .object => |object| object.get("result") orelse return error.InvalidAttachIdentity,
        else => return error.InvalidAttachIdentity,
    };
    const stream_value = switch (attach_result) {
        .object => |object| object.get("stream_id") orelse return error.InvalidAttachIdentity,
        else => return error.InvalidAttachIdentity,
    };
    const stream_id: u64 = switch (stream_value) {
        .integer => |value| std.math.cast(u64, value) orelse return error.InvalidAttachIdentity,
        else => return error.InvalidAttachIdentity,
    };
    const snapshot = try client.readSnapshot(stream_id);
    allocator.free(snapshot);
    var observation_buf: [64]u8 = undefined;
    const observation_params = try std.fmt.bufPrint(
        &observation_buf,
        "{{\"stream_id\":{d}}}",
        .{stream_id},
    );
    const observation = try client.call("runtime.observation", observation_params);
    defer allocator.free(observation);
    var parsed_observation = std.json.parseFromSlice(std.json.Value, allocator, observation, .{}) catch
        return error.InvalidRuntimeObservation;
    defer parsed_observation.deinit();
    const result = switch (parsed_observation.value) {
        .object => |object| object.get("result") orelse return error.InvalidRuntimeObservation,
        else => return error.InvalidRuntimeObservation,
    };
    const metadata = switch (result) {
        .object => |value| value.get("metadata") orelse return error.InvalidRuntimeObservation,
        else => return error.InvalidRuntimeObservation,
    };
    const object = switch (metadata) {
        .object => |value| value,
        else => return error.InvalidRuntimeObservation,
    };
    const host_pid = switch (object.get("host_pid") orelse return error.InvalidRuntimeObservation) {
        .integer => |value| std.math.cast(i32, value) orelse return error.InvalidRuntimeObservation,
        else => return error.InvalidRuntimeObservation,
    };
    const child_pid = switch (object.get("child_pid") orelse return error.InvalidRuntimeObservation) {
        .integer => |value| std.math.cast(i32, value) orelse return error.InvalidRuntimeObservation,
        else => return error.InvalidRuntimeObservation,
    };
    if (host_pid <= 0 or child_pid <= 0) return error.InvalidRuntimeObservation;
    return .{ .host_pid = host_pid, .child_pid = child_pid };
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
        appSummaryPath(),
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
        row.wake_apply_latency_ns > wake_apply_latency_budget_ns or !before_capture or !after_capture or
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

fn writeStrictArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    artifact: anytype,
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

fn readSignedAppQuitConfig(allocator: std.mem.Allocator) !?SignedAppQuitConfig {
    return readReleaseEvidenceConfig(allocator, .{
        .uuid = "MARU_SESSION_HOST_SIGNED_APP_QUIT_TEST_UUID",
        .dmg = "MARU_SESSION_HOST_SIGNED_APP_QUIT_CANDIDATE_DMG",
        .frozen = "MARU_SESSION_HOST_SIGNED_APP_QUIT_FROZEN_EXE",
        .output = "MARU_SESSION_HOST_SIGNED_APP_QUIT_OUTPUT",
    });
}

fn readDefaultFalseConfig(allocator: std.mem.Allocator) !?DefaultFalseConfig {
    return readReleaseEvidenceConfig(allocator, .{
        .uuid = "MARU_SESSION_HOST_DEFAULT_FALSE_TEST_UUID",
        .dmg = "MARU_SESSION_HOST_DEFAULT_FALSE_CANDIDATE_DMG",
        .frozen = "MARU_SESSION_HOST_DEFAULT_FALSE_FROZEN_EXE",
        .output = "MARU_SESSION_HOST_DEFAULT_FALSE_OUTPUT",
    });
}

fn readReleaseEvidenceConfig(allocator: std.mem.Allocator, env: ReleaseEvidenceEnv) !?ReleaseEvidenceConfig {
    const uuid_raw = std.c.getenv(env.uuid);
    const dmg_raw = std.c.getenv(env.dmg);
    const frozen_raw = std.c.getenv(env.frozen);
    const output_raw = std.c.getenv(env.output);
    if (uuid_raw == null and dmg_raw == null and frozen_raw == null and output_raw == null) return null;
    if (uuid_raw == null or dmg_raw == null or frozen_raw == null or output_raw == null)
        return error.IncompleteReleaseEvidenceConfig;
    const uuid = std.mem.span(uuid_raw.?);
    const dmg = std.mem.span(dmg_raw.?);
    const frozen = std.mem.span(frozen_raw.?);
    const output = std.mem.span(output_raw.?);
    if (!std.fs.path.isAbsolute(dmg) or !std.fs.path.isAbsolute(frozen) or
        !std.fs.path.isAbsolute(output) or dmg.len == 0 or frozen.len == 0 or output.len == 0 or
        std.mem.eql(u8, dmg, frozen) or std.mem.eql(u8, dmg, output) or std.mem.eql(u8, frozen, output))
        return error.InvalidReleaseEvidencePath;
    const owned_uuid = try allocator.dupe(u8, uuid);
    errdefer allocator.free(owned_uuid);
    const owned_dmg = try allocator.dupeZ(u8, dmg);
    errdefer allocator.free(owned_dmg);
    const owned_frozen = try allocator.dupeZ(u8, frozen);
    errdefer allocator.free(owned_frozen);
    const owned_output = try allocator.dupeZ(u8, output);
    return .{
        .test_uuid = owned_uuid,
        .candidate_dmg = owned_dmg,
        .frozen_executable = owned_frozen,
        .output = owned_output,
    };
}

const ReleaseWorkspaceKind = enum { default_false, signed_app_quit };

fn validateReleaseWorkspace(output: [:0]const u8, kind: ReleaseWorkspaceKind) !void {
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.MissingReleaseWorkspace);
    const fixed_home = std.mem.span(std.c.getenv("CFFIXED_USER_HOME") orelse return error.MissingReleaseWorkspace);
    const config = std.mem.span(std.c.getenv("MARU_CONFIG") orelse return error.MissingReleaseWorkspace);
    const artifact_root = std.mem.span(std.c.getenv("MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT") orelse
        return error.MissingReleaseWorkspace);
    const session_root = std.mem.span(std.c.getenv(short_endpoint.root_override_env) orelse
        return error.MissingReleaseWorkspace);
    const summary = appSummaryPath();
    if (!validAbsolutePath(home) or !validAbsolutePath(output) or !std.mem.eql(u8, home, fixed_home) or
        !std.mem.eql(u8, home, artifact_root))
        return error.InvalidReleaseWorkspace;
    const parent = std.fs.path.dirname(home) orelse return error.InvalidReleaseWorkspace;
    if (!std.mem.eql(u8, parent, std.fs.path.dirname(output) orelse return error.InvalidReleaseWorkspace))
        return error.InvalidReleaseWorkspace;
    const expected_home = switch (kind) {
        .default_false => "default-false",
        .signed_app_quit => "signed-app-quit",
    };
    const expected_output = switch (kind) {
        .default_false => "default-false.json",
        .signed_app_quit => "signed-app-quit.json",
    };
    if (!std.mem.eql(u8, std.fs.path.basename(home), expected_home) or
        !std.mem.eql(u8, std.fs.path.basename(output), expected_output))
        return error.InvalidReleaseWorkspace;
    var expected_config_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected_config = std.fmt.bufPrint(&expected_config_buf, "{s}/.config/maru/config", .{home}) catch
        return error.InvalidReleaseWorkspace;
    var expected_session_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected_session = std.fmt.bufPrint(&expected_session_buf, "{s}/session-host", .{home}) catch
        return error.InvalidReleaseWorkspace;
    var expected_summary_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected_summary = std.fmt.bufPrint(&expected_summary_buf, "{s}/app.summary.txt", .{home}) catch
        return error.InvalidReleaseWorkspace;
    if (!std.mem.eql(u8, config, expected_config) or !std.mem.eql(u8, session_root, expected_session) or
        !std.mem.eql(u8, summary, expected_summary))
        return error.InvalidReleaseWorkspace;
    try validatePrivateDirectory(parent);
    try validatePrivateDirectory(home);
    var stat: std.posix.Stat = undefined;
    const output_stat_rc = std.c.fstatat(std.posix.AT.FDCWD, output.ptr, &stat, std.posix.AT.SYMLINK_NOFOLLOW);
    if (output_stat_rc == 0 or std.posix.errno(output_stat_rc) != .NOENT)
        return error.ReleaseOutputExists;
}

fn appSummaryPath() [:0]const u8 {
    return if (std.c.getenv("MARU_APP_SUMMARY_PATH")) |raw|
        std.mem.span(raw)
    else
        "zig-out/maru-macos-app/app.summary.txt";
}

fn validAbsolutePath(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or path.len <= 1 or path.len >= std.fs.max_path_bytes or
        std.mem.endsWith(u8, path, "/") or std.mem.indexOfScalar(u8, path, 0) != null)
        return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, ".."))
            return false;
    }
    return true;
}

fn validatePrivateDirectory(path: []const u8) !void {
    var storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&storage, "{s}", .{path}) catch return error.InvalidReleaseWorkspace;
    var stat: std.posix.Stat = undefined;
    if (std.c.fstatat(std.posix.AT.FDCWD, path_z.ptr, &stat, std.posix.AT.SYMLINK_NOFOLLOW) != 0 or !std.posix.S.ISDIR(stat.mode) or
        stat.uid != std.c.getuid() or stat.mode & 0o777 != 0o700)
        return error.InvalidReleaseWorkspace;
}

fn inspectCandidate(path: [:0]const u8, executable: bool) !CandidateIdentity {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.CandidateOpenFailed;
    defer _ = std.c.close(fd);
    var before: std.posix.Stat = undefined;
    if (std.c.fstat(fd, &before) != 0 or !std.posix.S.ISREG(before.mode) or
        before.uid != std.c.getuid() or before.nlink != 1 or before.mode & 0o022 != 0 or
        (executable and before.mode & 0o111 == 0) or before.size <= 0 or
        @as(u64, @intCast(before.size)) > max_candidate_bytes)
        return error.InvalidCandidateFile;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = std.c.pread(fd, &buffer, buffer.len, @intCast(total));
        if (count < 0) {
            if (std.posix.errno(count) == .INTR) continue;
            return error.CandidateReadFailed;
        }
        if (count == 0) break;
        const chunk = buffer[0..@intCast(count)];
        hasher.update(chunk);
        total = std.math.add(u64, total, chunk.len) catch return error.InvalidCandidateFile;
        if (total > max_candidate_bytes) return error.InvalidCandidateFile;
    }
    var after: std.posix.Stat = undefined;
    if (std.c.fstat(fd, &after) != 0 or !sameStat(before, after) or
        total != @as(u64, @intCast(before.size)))
        return error.CandidateChanged;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{
        .dev = before.dev,
        .ino = @intCast(before.ino),
        .size = total,
        .mode = @intCast(before.mode),
        .modified_sec = before.mtimespec.sec,
        .modified_nsec = before.mtimespec.nsec,
        .changed_sec = before.ctimespec.sec,
        .changed_nsec = before.ctimespec.nsec,
        .sha256 = digest,
    };
}

fn sameStat(left: std.posix.Stat, right: std.posix.Stat) bool {
    return left.dev == right.dev and left.ino == right.ino and left.mode == right.mode and
        left.nlink == right.nlink and left.uid == right.uid and left.size == right.size and
        left.mtimespec.sec == right.mtimespec.sec and left.mtimespec.nsec == right.mtimespec.nsec and
        left.ctimespec.sec == right.ctimespec.sec and left.ctimespec.nsec == right.ctimespec.nsec;
}

fn sameCandidateIdentity(left: CandidateIdentity, right: CandidateIdentity) bool {
    return left.dev == right.dev and left.ino == right.ino and left.size == right.size and
        left.mode == right.mode and left.modified_sec == right.modified_sec and
        left.modified_nsec == right.modified_nsec and left.changed_sec == right.changed_sec and
        left.changed_nsec == right.changed_nsec and std.mem.eql(u8, &left.sha256, &right.sha256);
}

fn validateSignedCandidate(
    io: std.Io,
    config: SignedAppQuitConfig,
    app_path: [:0]const u8,
    before: SignedCandidateSet,
) !void {
    const after = try inspectSignedCandidate(io, config.candidate_dmg, config.frozen_executable, app_path);
    if (!sameCandidateIdentity(before.dmg, after.dmg) or
        !sameCandidateIdentity(before.frozen, after.frozen) or
        !sameCandidateIdentity(before.app, after.app))
        return error.SignedCandidateChanged;
}

fn inspectSignedCandidate(
    io: std.Io,
    candidate_dmg: [:0]const u8,
    frozen_executable: [:0]const u8,
    app_path: [:0]const u8,
) !SignedCandidateSet {
    const result: SignedCandidateSet = .{
        .dmg = try inspectCandidate(candidate_dmg, false),
        .frozen = try inspectCandidate(frozen_executable, true),
        .app = try inspectCandidate(app_path, true),
    };
    if (!std.mem.eql(u8, &result.app.sha256, &result.frozen.sha256) or
        !code_signature.sameReleaseSigner(io, app_path, frozen_executable))
        return error.InvalidSignedCandidate;
    return result;
}

fn inspectDefaultFalseCandidate(
    io: std.Io,
    config: DefaultFalseConfig,
    app_path: [:0]const u8,
) !SignedCandidateSet {
    return inspectSignedCandidate(io, config.candidate_dmg, config.frozen_executable, app_path);
}

fn validateDefaultFalseCandidate(
    io: std.Io,
    config: DefaultFalseConfig,
    app_path: [:0]const u8,
    before: SignedCandidateSet,
) !void {
    const after = try inspectDefaultFalseCandidate(io, config, app_path);
    if (!sameCandidateIdentity(before.dmg, after.dmg) or
        !sameCandidateIdentity(before.frozen, after.frozen) or
        !sameCandidateIdentity(before.app, after.app))
        return error.SignedCandidateChanged;
}

fn writeDefaultFalseArtifact(
    io: std.Io,
    config: DefaultFalseConfig,
    dmg_sha256: [32]u8,
    executable_sha256: [32]u8,
) !void {
    var storage: [1024]u8 = undefined;
    const bytes = try encodeDefaultFalseArtifact(&storage, config.test_uuid, dmg_sha256, executable_sha256);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = config.output,
        .data = bytes,
        .flags = .{
            .truncate = false,
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        },
    });
}

fn encodeDefaultFalseArtifact(
    storage: *[1024]u8,
    test_uuid: []const u8,
    dmg_sha256: [32]u8,
    executable_sha256: [32]u8,
) ![]const u8 {
    if (!upgrade_limits.canonicalReleaseTestUuid(test_uuid)) return error.InvalidTestUuid;
    var writer: std.Io.Writer = .fixed(storage);
    var json: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    const dmg_hex = std.fmt.bytesToHex(dmg_sha256, .lower);
    const executable_hex = std.fmt.bytesToHex(executable_sha256, .lower);
    try json.write(.{
        .schema = upgrade_limits.default_false_leaf_schema,
        .test_uuid = test_uuid,
        .result = "passed",
        .candidate_dmg_sha256 = &dmg_hex,
        .candidate_executable_sha256 = &executable_hex,
        .resolved_default = false,
        .explicit_override_present = false,
        .signed_product = true,
    });
    try writer.writeByte('\n');
    return writer.buffered();
}

fn writeSignedAppQuitArtifact(
    io: std.Io,
    config: SignedAppQuitConfig,
    dmg_sha256: [32]u8,
    executable_sha256: [32]u8,
) !void {
    var storage: [2048]u8 = undefined;
    const bytes = try encodeSignedAppQuitArtifact(&storage, config.test_uuid, dmg_sha256, executable_sha256);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = config.output,
        .data = bytes,
        .flags = .{
            .truncate = false,
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        },
    });
}

fn encodeSignedAppQuitArtifact(
    storage: *[2048]u8,
    test_uuid: []const u8,
    dmg_sha256: [32]u8,
    executable_sha256: [32]u8,
) ![]const u8 {
    if (!upgrade_limits.canonicalReleaseTestUuid(test_uuid)) return error.InvalidTestUuid;
    var writer: std.Io.Writer = .fixed(storage);
    var json: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    const dmg_hex = std.fmt.bytesToHex(dmg_sha256, .lower);
    const executable_hex = std.fmt.bytesToHex(executable_sha256, .lower);
    try json.write(.{
        .schema = upgrade_limits.signed_app_quit_leaf_schema,
        .test_uuid = test_uuid,
        .result = "passed",
        .candidate_dmg_sha256 = &dmg_hex,
        .candidate_executable_sha256 = &executable_hex,
        .runtime_count = 1,
        .same_host_pid = true,
        .all_runtime_pids_preserved = true,
        .gui_exact_reattach = true,
        .runtime_screen_before_preserved = true,
        .runtime_screen_after_writable = true,
        .cleanup_complete = true,
    });
    try writer.writeByte('\n');
    return writer.buffered();
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

test "signed app Quit evidence is canonical and contains only durable observations" {
    var storage: [2048]u8 = undefined;
    const bytes = try encodeSignedAppQuitArtifact(
        &storage,
        "123e4567-e89b-42d3-a456-426614174000",
        [_]u8{0xaa} ** 32,
        [_]u8{0xbb} ** 32,
    );
    try std.testing.expectEqualStrings(
        "{\"schema\":\"maru.session-host-signed-app-quit-reattach.v1\",\"test_uuid\":\"123e4567-e89b-42d3-a456-426614174000\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"candidate_executable_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"runtime_count\":1,\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"gui_exact_reattach\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"cleanup_complete\":true}\n",
        bytes,
    );
}

test "signed app Quit evidence rejects noncanonical trusted UUID" {
    var storage: [2048]u8 = undefined;
    try std.testing.expectError(error.InvalidTestUuid, encodeSignedAppQuitArtifact(
        &storage,
        "123E4567-E89B-42D3-A456-426614174000",
        [_]u8{0xaa} ** 32,
        [_]u8{0xbb} ** 32,
    ));
}

test "signed app Quit evidence never accepts caller result booleans" {
    var storage: [2048]u8 = undefined;
    const bytes = try encodeSignedAppQuitArtifact(
        &storage,
        "123e4567-e89b-42d3-a456-426614174000",
        [_]u8{0x11} ** 32,
        [_]u8{0x22} ** 32,
    );
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"result\":\"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "duration") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "runtime_id") == null);
}

test "default false evidence is canonical and contains only derived observations" {
    var storage: [1024]u8 = undefined;
    const bytes = try encodeDefaultFalseArtifact(
        &storage,
        "123e4567-e89b-42d3-a456-426614174000",
        [_]u8{0xaa} ** 32,
        [_]u8{0xbb} ** 32,
    );
    try std.testing.expectEqualStrings(
        "{\"schema\":\"maru.session-host-default-false-baseline.v1\",\"test_uuid\":\"123e4567-e89b-42d3-a456-426614174000\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"candidate_executable_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"resolved_default\":false,\"explicit_override_present\":false,\"signed_product\":true}\n",
        bytes,
    );
}

test "default false evidence rejects noncanonical trusted UUID" {
    var storage: [1024]u8 = undefined;
    try std.testing.expectError(error.InvalidTestUuid, encodeDefaultFalseArtifact(
        &storage,
        "123E4567-E89B-42D3-A456-426614174000",
        [_]u8{0xaa} ** 32,
        [_]u8{0xbb} ** 32,
    ));
}

test "default false evidence has no caller-controlled result surface" {
    var storage: [1024]u8 = undefined;
    const bytes = try encodeDefaultFalseArtifact(
        &storage,
        "123e4567-e89b-42d3-a456-426614174000",
        [_]u8{0x11} ** 32,
        [_]u8{0x22} ** 32,
    );
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"result\":\"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "config_path") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "signer_path") == null);
}
