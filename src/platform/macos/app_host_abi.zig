const std = @import("std");
const diag_gate = @import("diag.zig"); // MARU_DEBUG 게이트(진단 로그 단일 출처)
const builtin = @import("builtin");
const maru = @import("maru");
const session_mod = @import("app_session.zig");
const session_host = @import("session_host.zig");
const keycode = @import("keycode.zig");
const keyhint_hold = maru.session.keyhint_hold; // OS-중립 홀드 gesture 정책(session L2 — session/keyhint_hold.zig)
const command_catalog = @import("command_catalog.zig");
const abi_term_ops = @import("app_session/term.zig"); // 활성 Term 종류 질의(선-가로채기 게이트)
const app_instance_lease_mod = if (builtin.os.tag == .macos)
    @import("app_instance_lease.zig")
else
    struct {};
const file_tree_mutation_backend = @import("file_tree_mutation_backend.zig");
const workspace_checkpoint_file = @import("workspace_checkpoint_file.zig");
const control_server_mod = @import("control_server.zig"); // Track C A2b: 라이브 컨트롤 서버(소켓+accept 스레드+marshal)
const control_socket = @import("control_socket.zig"); // 1b: formatInstanceKey(인스턴스 키)
const control_dispatch = maru.session.control_dispatch; // 1d: read-only 바이트→바이트 디스패치 라우터 + 1e dispatchAuthenticated
const control_plane = maru.session.control_plane; // 1a: hello capability method namespace 파싱
const control_browser = maru.session.control_browser; // 5e: browser.* op·응답 직렬화(dispatchAuthenticated가 산출한 op을 marshal)
const control_result = maru.session.control_result; // 5f-5b: executeScript process-global result-byte 예약
const control_surface = maru.session.control_surface; // 1c: Surface DTO/CollectorSnapshot
const control_capability = maru.session.control_capability; // 1e: capability fd resolve(라이브 auth 배선)
const control_pane_grant = maru.session.control_pane_grant; // 1e-confirm: pane-bound confirm-grant store(Model B, §9.2)
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("app_host_abi.h");
});

/// Zig 0.16 의 `std.c` 에는 `atexit` 바인딩이 없어 직접 선언한다.
extern fn atexit(handler: *const fn () callconv(.c) void) c_int;

pub const abi_version: u32 = session_mod.abi_version;
const allocator = std.heap.smp_allocator;
const terminal = maru.terminal;

pub const Status = enum(c_int) {
    ok = 0,
    null_out = 1,
    unsupported_abi = 2,
    invalid_config = 3,
    create_failed = 4,
    tick_failed = 5,
    close_failed = 6,
    key_failed = 7,
    resize_failed = 8,
    // tick이 PTY 세션 종료를 관측했다(shell exit/read_error). fault가 아니라 정상 종료
    // 신호이므로 host는 frame loop를 멈추고 우아하게 내려간다.
    session_ended = 9,
    // cross-window 이동(M3d-2a) 실패 — 잘못된 워크스페이스 인덱스(InvalidCoordinate)·dst 용량 확보 실패(OOM)·범위 밖
    // 워크스페이스(UnsupportedMove: pinned·그룹은 M3d-2a-ii). Swift 미소비(M3d-2b가 배선하며 app_host_abi.h에 미러). 이
    // 한 event만 거부이고 세션은 유지(fault 아님).
    move_failed = 10,
};

pub const AppInstanceLeaseResult = enum(u32) {
    acquired = c.MARU_APP_INSTANCE_LEASE_ACQUIRED,
    held = c.MARU_APP_INSTANCE_LEASE_HELD,
    unsafe = c.MARU_APP_INSTANCE_LEASE_UNSAFE,
    io_failure = c.MARU_APP_INSTANCE_LEASE_IO_FAILURE,
    invalid_path = c.MARU_APP_INSTANCE_LEASE_INVALID_PATH,
};

pub const SessionConfigBootstrapResult = enum(u32) {
    ready = c.MARU_SESSION_CONFIG_BOOTSTRAP_READY,
    no_lease = c.MARU_SESSION_CONFIG_BOOTSTRAP_NO_LEASE,
    already_initialized = c.MARU_SESSION_CONFIG_BOOTSTRAP_ALREADY_INITIALIZED,
    load_failure = c.MARU_SESSION_CONFIG_BOOTSTRAP_LOAD_FAILURE,
};

pub const SessionDefaultFalseObservation = enum(u32) {
    not_bootstrapped = c.MARU_SESSION_DEFAULT_FALSE_OBSERVATION_NOT_BOOTSTRAPPED,
    matched = c.MARU_SESSION_DEFAULT_FALSE_OBSERVATION_MATCHED,
    resolved_true = c.MARU_SESSION_DEFAULT_FALSE_OBSERVATION_RESOLVED_TRUE,
    explicit_override = c.MARU_SESSION_DEFAULT_FALSE_OBSERVATION_EXPLICIT_OVERRIDE,
    config_present = c.MARU_SESSION_DEFAULT_FALSE_OBSERVATION_CONFIG_PRESENT,
};

const LeaseSlot = if (builtin.os.tag == .macos)
    struct {
        held: ?app_instance_lease_mod.AppInstanceLease = null,

        fn acquire(self: *@This(), path: [:0]const u8) AppInstanceLeaseResult {
            if (self.held != null) return .held;
            self.held = app_instance_lease_mod.AppInstanceLease.acquire(path) catch |err| return switch (err) {
                error.AlreadyOwned => .held,
                error.UnsafeLock => .unsafe,
                error.IoFailure => .io_failure,
            };
            return .acquired;
        }

        fn deinitForTest(self: *@This()) void {
            if (self.held) |*lease| lease.deinit();
            self.held = null;
        }

        fn isHeld(self: *const @This()) bool {
            return self.held != null;
        }
    }
else
    struct {
        fn acquire(_: *@This(), _: [:0]const u8) AppInstanceLeaseResult {
            // 이 ABI의 제품 consumer는 macOS Swift host뿐이다. Linux check는 header/export
            // shape만 컴파일하며 Darwin owner-lease primitive를 분석하지 않는다.
            return .io_failure;
        }

        fn deinitForTest(_: *@This()) void {}

        fn isHeld(_: *const @This()) bool {
            return false;
        }
    };

// AppSession보다 먼저 생기고 모든 Window보다 오래 사는 process-global owner다. 제품에는 release/reset ABI를
// 노출하지 않는다. 정상/비정상 process exit에서 kernel이 CLOEXEC fd와 flock을 함께 회수한다.
var app_instance_lease_slot: LeaseSlot = .{};

// EventKind는 app_session.zig가 소유한다(FrameSummary.last_event_kind에 실린다).
// 여기서는 ABI 표면으로 re-export만 한다.
pub const EventKind = session_mod.EventKind;

/// Fixed-width, read-only projection for the AS4-c AppKit fixture. Coordinates are backing
/// pixels in the window's Metal view coordinate system; `present=0` makes every other field
/// unusable. It deliberately contains no source-derived strings or action payload.
pub const AgentSessionArchiveSmokeProbe = extern struct {
    request_id: u64 = 0,
    generation: u64 = 0,
    x_px: f32 = 0,
    y_px: f32 = 0,
    width_px: f32 = 0,
    height_px: f32 = 0,
    state: u32 = 0,
    present: u32 = 0,
    enabled: u32 = 0,
};

test "ABI v181 session config bootstrap observation and notification cold route values match the C header" {
    try std.testing.expectEqual(@as(u32, 181), abi_version);
    try std.testing.expectEqual(@as(u32, c.MARU_APP_INSTANCE_LEASE_ACQUIRED), @intFromEnum(AppInstanceLeaseResult.acquired));
    try std.testing.expectEqual(@as(u32, c.MARU_APP_INSTANCE_LEASE_HELD), @intFromEnum(AppInstanceLeaseResult.held));
    try std.testing.expectEqual(@as(u32, c.MARU_APP_INSTANCE_LEASE_UNSAFE), @intFromEnum(AppInstanceLeaseResult.unsafe));
    try std.testing.expectEqual(@as(u32, c.MARU_APP_INSTANCE_LEASE_IO_FAILURE), @intFromEnum(AppInstanceLeaseResult.io_failure));
    try std.testing.expectEqual(@as(u32, c.MARU_APP_INSTANCE_LEASE_INVALID_PATH), @intFromEnum(AppInstanceLeaseResult.invalid_path));
    try std.testing.expectEqual(@as(u32, c.MARU_SESSION_CONFIG_BOOTSTRAP_READY), @intFromEnum(SessionConfigBootstrapResult.ready));
    try std.testing.expectEqual(@as(u32, c.MARU_SESSION_CONFIG_BOOTSTRAP_NO_LEASE), @intFromEnum(SessionConfigBootstrapResult.no_lease));
    try std.testing.expectEqual(@as(u32, c.MARU_SESSION_CONFIG_BOOTSTRAP_ALREADY_INITIALIZED), @intFromEnum(SessionConfigBootstrapResult.already_initialized));
    try std.testing.expectEqual(@as(u32, c.MARU_SESSION_CONFIG_BOOTSTRAP_LOAD_FAILURE), @intFromEnum(SessionConfigBootstrapResult.load_failure));
    try std.testing.expectEqual(@as(u32, c.MARU_SESSION_DEFAULT_FALSE_OBSERVATION_MATCHED), @intFromEnum(SessionDefaultFalseObservation.matched));
}

test "app instance LeaseSlot acquires exactly once and preserves typed failure" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/private/tmp/maru-app-abi-lease-{d}", .{std.c.getpid()}) catch
        return error.SkipZigTest;
    _ = std.c.unlink(path.ptr);
    defer _ = std.c.unlink(path.ptr);

    var first: LeaseSlot = .{};
    defer first.deinitForTest();
    try std.testing.expectEqual(AppInstanceLeaseResult.acquired, first.acquire(path));
    try std.testing.expectEqual(AppInstanceLeaseResult.held, first.acquire(path));

    var competitor: LeaseSlot = .{};
    defer competitor.deinitForTest();
    try std.testing.expectEqual(AppInstanceLeaseResult.held, competitor.acquire(path));
}

test "app instance lease ABI rejects invalid paths without mutating the global slot" {
    try std.testing.expectEqual(
        @intFromEnum(AppInstanceLeaseResult.invalid_path),
        maru_macos_app_instance_lease_acquire(null, 1),
    );
    const embedded_nul = [_]u8{ 'a', 0, 'b' };
    try std.testing.expectEqual(
        @intFromEnum(AppInstanceLeaseResult.invalid_path),
        maru_macos_app_instance_lease_acquire(&embedded_nul, embedded_nul.len),
    );
}

test "Swift startup acquires the writer lease before AppKit and mutable app bootstrap" {
    const source = @embedFile("MaruAppHost.swift");
    const main_start = std.mem.indexOf(u8, source, "static func main()") orelse
        return error.MissingMain;
    const main_end = std.mem.indexOfPos(u8, source, main_start, "\n    func applicationDidFinishLaunching") orelse
        return error.MissingLaunchCallback;
    const main_body = source[main_start..main_end];
    const lease = std.mem.indexOf(u8, main_body, "acquireAppInstanceWriterLeaseBeforeAppKit()") orelse
        return error.MissingLeaseAcquire;
    const failure_exit = std.mem.indexOf(u8, main_body, "Darwin.exit(failure.code)") orelse
        return error.MissingLeaseFailureExit;
    const config_bootstrap = std.mem.indexOf(u8, main_body, "maru_macos_session_config_bootstrap()") orelse
        return error.MissingConfigBootstrap;
    try std.testing.expect(lease < failure_exit);
    try std.testing.expect(failure_exit < config_bootstrap);
    const prelease_forbidden = [_][]const u8{
        "NSApplication.shared",
        "MaruAppHostController()",
        "setActivationPolicy",
        "app.run()",
    };
    for (prelease_forbidden) |needle| {
        const position = std.mem.indexOf(u8, main_body, needle) orelse
            return error.MissingAppKitBootstrap;
        try std.testing.expect(config_bootstrap < position);
        try std.testing.expect(failure_exit < position);
    }

    const launch_start = main_end;
    const launch_end = std.mem.indexOfPos(u8, source, launch_start, "\n    func applicationWillTerminate") orelse
        return error.MissingTerminateCallback;
    const launch_body = source[launch_start..launch_end];
    const mutable_bootstrap = [_][]const u8{
        "cleanupPasteImages",
        "makeTerminalSurface",
        "makePlaceholderWindow",
        "loadWorkspaceText",
        "startAppSession",
        "restoreWorkspace",
        "registerGlobalHotkeys",
        "maru_macos_control_server_start",
    };
    for (mutable_bootstrap) |needle| {
        _ = std.mem.indexOf(u8, launch_body, needle) orelse
            return error.MissingBootstrapOperation;
    }
}

test "CR0b AppHost termination transcript는 session settlement 뒤 incident ABI를 exact 한 번 호출한다" {
    const source = @embedFile("MaruAppHost.swift");
    const termination_start = std.mem.indexOf(u8, source, "func applicationWillTerminate(_ notification: Notification) {") orelse
        return error.MissingTerminateCallback;
    const termination_end = std.mem.indexOfPos(u8, source, termination_start, "\n    func applicationShouldTerminateAfterLastWindowClosed(") orelse
        return error.MissingTerminateCallback;
    const termination = source[termination_start..termination_end];
    const session_shutdown = std.mem.indexOf(u8, termination, "shutdownAppSession(preserveWebPanelsFor: mainSurface)") orelse
        return error.MissingSessionShutdown;
    const backend_settlement = std.mem.indexOf(u8, termination, "maru_macos_remote_backend_settle()") orelse
        return error.MissingSessionShutdown;
    const incident_shutdown = std.mem.indexOf(u8, termination, "maru_macos_incident_owner_shutdown()") orelse
        return error.MissingIncidentShutdown;
    try std.testing.expect(session_shutdown < backend_settlement and backend_settlement < incident_shutdown);
    try expectExecutableSwiftStatement(termination, session_shutdown, "shutdownAppSession(");
    try expectExecutableSwiftStatement(termination, backend_settlement, "_ = maru_macos_remote_backend_settle()");
    try expectExecutableSwiftStatement(termination, incident_shutdown, "_ = maru_macos_incident_owner_shutdown()");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, termination, "shutdownAppSession(preserveWebPanelsFor: mainSurface)"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, termination, "maru_macos_remote_backend_settle()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, termination, "maru_macos_incident_owner_shutdown()"));

    const ordinary_start = std.mem.indexOf(u8, source, "func windowWillClose(_ notification: Notification) {") orelse
        return error.MissingWindowClose;
    const ordinary_end = std.mem.indexOfPos(u8, source, ordinary_start, "\n    func windowDidResize(") orelse
        return error.MissingWindowClose;
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source[ordinary_start..ordinary_end], "maru_macos_incident_owner_shutdown()"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source[ordinary_start..ordinary_end], "maru_macos_remote_backend_settle()"));

    const shutdown_start = std.mem.indexOf(u8, source, "private func shutdownAppSession(preserveWebPanelsFor summarySurface: TerminalSurface? = nil) {") orelse
        return error.MissingSessionShutdown;
    const shutdown_end = std.mem.indexOfPos(u8, source, shutdown_start, "\n    private func smokeDurationMs(") orelse
        return error.MissingSessionShutdown;
    const shutdown = source[shutdown_start..shutdown_end];
    inline for (.{ "tearDownQuickTerminalAfterGlobalPreflight()", "let snapshot = windows", "for surface in snapshot", "teardownWindowSurface(surface," }) |needle|
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shutdown, needle));
    const quick = std.mem.indexOf(u8, shutdown, "tearDownQuickTerminalAfterGlobalPreflight()") orelse return error.MissingSessionShutdown;
    const snapshot = std.mem.indexOf(u8, shutdown, "let snapshot = windows") orelse return error.MissingSessionShutdown;
    const loop = std.mem.indexOf(u8, shutdown, "for surface in snapshot") orelse return error.MissingSessionShutdown;
    const teardown = std.mem.indexOf(u8, shutdown, "teardownWindowSurface(surface,") orelse return error.MissingSessionShutdown;
    try std.testing.expect(quick < snapshot and snapshot < loop and loop < teardown);
    try expectExecutableSwiftStatement(shutdown, quick, "tearDownQuickTerminalAfterGlobalPreflight()");
    try expectExecutableSwiftStatement(shutdown, snapshot, "let snapshot = windows");
    try expectExecutableSwiftStatement(shutdown, loop, "for surface in snapshot");
    try expectExecutableSwiftStatement(shutdown, teardown, "teardownWindowSurface(surface,");
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, shutdown, "maru_macos_incident_owner_shutdown()"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, shutdown, "maru_macos_remote_backend_settle()"));
}

fn expectExecutableSwiftStatement(source: []const u8, position: usize, expected: []const u8) !void {
    if (!swiftCodeAt(source, position)) return error.CommentedSwiftEvidence;
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..position], '\n')) |at| at + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, source, position, '\n') orelse source.len;
    const line = std.mem.trim(u8, source[line_start..line_end], " \t\r");
    if (!std.mem.startsWith(u8, line, expected)) return error.CommentedSwiftEvidence;
}

fn swiftCodeAt(source: []const u8, position: usize) bool {
    const State = enum { code, line_comment, block_comment, string, multiline_string };
    var state: State = .code;
    var block_depth: usize = 0;
    var escaped = false;
    var i: usize = 0;
    while (i < position) {
        switch (state) {
            .code => {
                // 이 좁은 source oracle은 extended/raw Swift string을 허용하지 않는다. 새 문법이 callback slice에
                // 들어오면 parser를 확장하기 전까지 fail-closed한다.
                if (source[i] == '#' and i + 1 < position and source[i + 1] == '"') return false;
                if (i + 1 < position and source[i] == '/' and source[i + 1] == '/') {
                    state = .line_comment;
                    i += 2;
                    continue;
                }
                if (i + 1 < position and source[i] == '/' and source[i + 1] == '*') {
                    state = .block_comment;
                    block_depth = 1;
                    i += 2;
                    continue;
                }
                if (i + 2 < position and std.mem.eql(u8, source[i .. i + 3], "\"\"\"")) {
                    state = .multiline_string;
                    i += 3;
                    continue;
                }
                if (source[i] == '"') {
                    state = .string;
                    escaped = false;
                    i += 1;
                    continue;
                }
                i += 1;
            },
            .line_comment => {
                if (source[i] == '\n') state = .code;
                i += 1;
            },
            .block_comment => {
                if (i + 1 < position and source[i] == '/' and source[i + 1] == '*') {
                    block_depth += 1;
                    i += 2;
                    continue;
                }
                if (i + 1 < position and source[i] == '*' and source[i + 1] == '/') {
                    block_depth -= 1;
                    i += 2;
                    if (block_depth == 0) state = .code;
                    continue;
                }
                i += 1;
            },
            .string => {
                if (escaped) {
                    escaped = false;
                    i += 1;
                    continue;
                }
                if (source[i] == '\\') {
                    escaped = true;
                    i += 1;
                    continue;
                }
                if (source[i] == '"') state = .code;
                i += 1;
            },
            .multiline_string => {
                if (i + 2 < position and std.mem.eql(u8, source[i .. i + 3], "\"\"\"") and !swiftDelimiterEscaped(source, i)) {
                    state = .code;
                    i += 3;
                    continue;
                }
                i += 1;
            },
        }
    }
    return state == .code;
}

fn swiftDelimiterEscaped(source: []const u8, position: usize) bool {
    var slash_count: usize = 0;
    var i = position;
    while (i > 0 and source[i - 1] == '\\') : (i -= 1) slash_count += 1;
    return slash_count % 2 == 1;
}

test "CR0b Swift transcript lexer는 escaped multiline delimiter와 raw string evidence를 거부한다" {
    const escaped = "\"\"\"fixture\\\"\"\"\n_ = maru_macos_incident_owner_shutdown()\n\"\"\"";
    const fake = std.mem.indexOf(u8, escaped, "_ = maru_macos_incident_owner_shutdown()") orelse unreachable;
    try std.testing.expect(!swiftCodeAt(escaped, fake));
    const raw = "#\"fake _ = maru_macos_incident_owner_shutdown()\"#\n_ = maru_macos_incident_owner_shutdown()";
    const after_raw = std.mem.lastIndexOf(u8, raw, "_ = maru_macos_incident_owner_shutdown()") orelse unreachable;
    try std.testing.expect(!swiftCodeAt(raw, after_raw));
}

test "P4 C4 Swift final Quit validates before secure publish and never legacy-saves in willTerminate" {
    const source = @embedFile("MaruAppHost.swift");
    const capture_start = std.mem.indexOf(u8, source, "private func captureWorkspaceSnapshot(useTerminationKeyWindow: Bool, publishedOnly: Bool)") orelse
        return error.MissingWorkspaceCapture;
    const capture_end = std.mem.indexOfPos(u8, source, capture_start, "\n    private func shutdownAppSession") orelse
        return error.MissingWorkspaceCaptureEnd;
    const capture = source[capture_start..capture_end];
    const assemble = std.mem.indexOf(u8, capture, "let snapshot = MARU_WORKSPACE_HEADER") orelse
        return error.MissingWorkspaceAssembly;
    const validate = std.mem.indexOf(u8, capture, "maru_macos_app_session_workspace_window_count(nil") orelse
        return error.MissingWorkspaceValidation;
    const count_gate = std.mem.indexOf(u8, capture, "guard validatedWindowCount == blockCount else { return nil }") orelse
        return error.MissingWorkspaceValidationGate;
    try std.testing.expect(assemble < validate);
    try std.testing.expect(validate < count_gate);

    try std.testing.expect(std.mem.indexOf(u8, source, "private func saveWorkspace()") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "backupWorkspaceCheckpoint") == null);
    const will_start = std.mem.indexOf(u8, source, "func applicationWillTerminate(_ notification: Notification)") orelse
        return error.MissingApplicationWillTerminate;
    const will_end = std.mem.indexOfPos(u8, source, will_start, "\n    func applicationShouldTerminateAfterLastWindowClosed") orelse
        return error.MissingApplicationWillTerminateEnd;
    const will_terminate = source[will_start..will_end];
    try std.testing.expect(std.mem.indexOf(u8, will_terminate, "workspaceCheckpointWriter.sync") == null);
    try std.testing.expect(std.mem.indexOf(u8, will_terminate, "saveWorkspace") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "maru_macos_workspace_checkpoint_publish_final") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "MARU_WORKSPACE_CHECKPOINT_EFFECT_REPLY_AND_DETACH") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "MARU_WORKSPACE_CHECKPOINT_EFFECT_CANCEL_QUIT") != null);
}

test "P4 C3c checkpoint ABI drives one app-global capture and write generation" {
    const saved = session_mod.app_runtime.workspace_checkpoint;
    session_mod.app_runtime.workspace_checkpoint = .{};
    defer session_mod.app_runtime.workspace_checkpoint = saved;

    try std.testing.expectEqual(@as(c_int, 0), maru_macos_workspace_checkpoint_arm(1));
    var effect: c.MaruWorkspaceCheckpointEffect = undefined;
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_workspace_checkpoint_tick(0, &effect));
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_workspace_checkpoint_tick(499 * std.time.ns_per_ms, &effect));
    try std.testing.expectEqual(@as(u32, c.MARU_WORKSPACE_CHECKPOINT_EFFECT_NONE), effect.kind);
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_workspace_checkpoint_tick(500 * std.time.ns_per_ms, &effect));
    try std.testing.expectEqual(@as(u32, c.MARU_WORKSPACE_CHECKPOINT_EFFECT_CAPTURE), effect.kind);
    try std.testing.expectEqual(@as(u64, 1), effect.generation);

    try std.testing.expectEqual(@as(c_int, 0), maru_macos_workspace_checkpoint_capture_completed(
        effect.generation,
        1,
        500 * std.time.ns_per_ms,
        &effect,
    ));
    try std.testing.expectEqual(@as(u32, c.MARU_WORKSPACE_CHECKPOINT_EFFECT_WRITE), effect.kind);
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_workspace_checkpoint_write_completed(
        effect.generation,
        1,
        500 * std.time.ns_per_ms,
        &effect,
    ));
    try std.testing.expectEqual(@as(u32, c.MARU_WORKSPACE_CHECKPOINT_EFFECT_NONE), effect.kind);
    try std.testing.expect(!session_mod.app_runtime.workspace_checkpoint.isDirty());
}

test "P4 C4 checkpoint ABI exposes final capture cancel and detach effects" {
    const saved = session_mod.app_runtime.workspace_checkpoint;
    session_mod.app_runtime.workspace_checkpoint = .{};
    defer session_mod.app_runtime.workspace_checkpoint = saved;

    try std.testing.expectEqual(@as(c_int, 0), maru_macos_workspace_checkpoint_arm(1));
    var effect: c.MaruWorkspaceCheckpointEffect = undefined;
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_workspace_checkpoint_quit_requested(1, &effect));
    try std.testing.expectEqual(@as(u32, c.MARU_WORKSPACE_CHECKPOINT_EFFECT_CAPTURE), effect.kind);
    try std.testing.expectEqual(@as(u32, c.MARU_WORKSPACE_CHECKPOINT_REASON_FINAL_QUIT), effect.reason);
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_workspace_checkpoint_capture_completed(effect.generation, 0, 2, &effect));
    try std.testing.expectEqual(@as(u32, c.MARU_WORKSPACE_CHECKPOINT_EFFECT_CANCEL_QUIT), effect.kind);

    try std.testing.expectEqual(@as(c_int, 0), maru_macos_workspace_checkpoint_quit_requested(3, &effect));
    const generation = effect.generation;
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_workspace_checkpoint_capture_completed(generation, 1, 3, &effect));
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_workspace_checkpoint_write_completed(generation, 1, 3, &effect));
    try std.testing.expectEqual(@as(u32, c.MARU_WORKSPACE_CHECKPOINT_EFFECT_REPLY_AND_DETACH), effect.kind);
}

test "ABI file panel mode, key route, and asset role values match the C header" {
    try std.testing.expectEqual(@as(u32, c.MARU_FILE_PANEL_MODE_READ), @intFromEnum(maru.session.dock_panel.Mode.read));
    try std.testing.expectEqual(@as(u32, c.MARU_FILE_PANEL_MODE_SOURCE_EDIT), @intFromEnum(maru.session.dock_panel.Mode.source_edit));
    try std.testing.expectEqual(@as(u32, c.MARU_FILE_PANEL_MODE_RICH), @intFromEnum(maru.session.dock_panel.Mode.rich));
    try std.testing.expectEqual(@as(u32, c.MARU_WEB_KEY_ROUTE_PASS_THROUGH), @intFromEnum(maru.config.keybinding.WebKeyRoute.pass_through));
    try std.testing.expectEqual(@as(u32, c.MARU_WEB_KEY_ROUTE_APP_ACTION), @intFromEnum(maru.config.keybinding.WebKeyRoute.app_action));
    try std.testing.expectEqual(@as(u32, c.MARU_WEB_KEY_ROUTE_CONSUME_UNBOUND), @intFromEnum(maru.config.keybinding.WebKeyRoute.consume_unbound));
    try std.testing.expectEqual(@as(u32, c.MARU_WEB_KEY_ROUTE_WEB_EDITOR), @intFromEnum(maru.config.keybinding.WebKeyRoute.web_editor));
    try std.testing.expectEqual(@as(u32, c.MARU_APP_ASSET_ROLE_APP), @intFromEnum(maru.session.app_scheme.AppAssetRole.app));
    try std.testing.expectEqual(@as(u32, c.MARU_APP_ASSET_ROLE_RENDER), @intFromEnum(maru.session.app_scheme.AppAssetRole.render));
}

pub const KeyCode = enum(u32) {
    unknown = 0,
    enter = 1,
    escape = 2,
    tab = 3,
    backspace = 4,
    arrow_up = 5,
    arrow_down = 6,
    arrow_left = 7,
    arrow_right = 8,
    // PC-style 기능키. Swift normalizedKeyEvent가 NSEvent.keyCode를 이 값으로 매핑하고,
    // keyEventFromAbi가 terminal.Key로 바꿔 input.encodeKey가 xterm legacy 시퀀스를 낸다.
    home = 9,
    end = 10,
    insert = 11,
    delete = 12,
    page_up = 13,
    page_down = 14,
    f1 = 15,
    f2 = 16,
    f3 = 17,
    f4 = 18,
    f5 = 19,
    f6 = 20,
    f7 = 21,
    f8 = 22,
    f9 = 23,
    f10 = 24,
    f11 = 25,
    f12 = 26,
};

pub const Capabilities = extern struct {
    abi_version: u32,
    swift_owns_ns_application: u32,
    swift_owns_window_lifecycle: u32,
    swift_owns_focus_and_input: u32,
    zig_owns_live_pty_sessions: u32,
    zig_owns_frame_loop: u32,
    objective_c_smokes_remain: u32,
};

pub const KeyEvent = extern struct {
    codepoint: u32,
    // codepoint의 unshifted base-layout 값(shift 미반영). kitty CSI u의 key code가 base-layout
    // key여야 해서 Swift가 characters(byApplyingModifiers:[])로 따로 싣는다. char가 아니거나
    // 단일 codepoint가 아니면 0(keyEventFromAbi가 codepoint로 폴백).
    base_codepoint: u32,
    key_code: u32,
    modifier_shift: u32,
    modifier_control: u32,
    modifier_option: u32,
    modifier_command: u32,
    is_repeat: u32,
    // macOS 물리 키코드(NSEvent.keyCode). Ctrl/Cmd 단축키를 레이아웃과 무관하게(한글 입력
    // 모드에서도) 매칭하기 위해 Swift가 그대로 싣는다 — 변환은 Zig(keycode.zig)가 소유한다.
    raw_key_code: u32,
};

pub const ResizeEvent = extern struct {
    width_px: u32,
    height_px: u32,
    scale_milli: u32,
    cols: u32,
    rows: u32,
    reserved: u32,
};

pub const AppCommandKind = session_mod.CommandKind;
pub const AppSession = session_mod.AppSession;
pub const AppSessionConfig = session_mod.SessionConfig;
pub const AppFrameSummary = session_mod.FrameSummary;
pub const AppMetalCell = session_mod.MetalCell;
pub const AppMetalRasterUpload = session_mod.MetalRasterUpload;
pub const AppMetalFrame = session_mod.MetalFrame;
pub const AppGpuQuad = session_mod.MetalGpuQuad;
pub const AppGpuShadow = session_mod.MetalGpuShadow;
pub const AppGpuGlyph = session_mod.MetalGpuGlyph;
pub const AppGpuImage = session_mod.MetalGpuImage;
pub const AppGpuImageUpload = session_mod.MetalGpuImageUpload;

pub fn defaultCapabilities() Capabilities {
    // Swift host는 macOS 앱 생명주기와 focus/input만 소유한다. PTY와 frame loop는
    // Zig에 남겨야 smoke, headless test, future Swift host가 같은 터미널 동작을 공유한다.
    return .{
        .abi_version = abi_version,
        .swift_owns_ns_application = 1,
        .swift_owns_window_lifecycle = 1,
        .swift_owns_focus_and_input = 1,
        .zig_owns_live_pty_sessions = 1,
        .zig_owns_frame_loop = 1,
        .objective_c_smokes_remain = 1,
    };
}

pub export fn maru_macos_app_host_abi_version() u32 {
    return abi_version;
}

pub export fn maru_macos_app_host_capabilities(out_capabilities: ?*Capabilities) c_int {
    const out = out_capabilities orelse return @intFromEnum(Status.null_out);
    out.* = defaultCapabilities();
    return @intFromEnum(Status.ok);
}

/// OS 로케일 식별자를 중립 층에 넘긴다 — **platform 은 읽어서 전달만 하고 해석하지 않는다**
/// (i18n 계약 §5.1). `ko-KR` 류의 짧은 ASCII 태그이고, 판정(`ko-KR`·`ko_KR`·`ko` 정규화, 미지원은
/// `en`)은 `src/i18n.zig` 가 소유한다. 그래야 규칙이 플랫폼 수만큼 복제되지 않고 OS 없이 테스트된다.
///
/// 세션마다가 아니라 **프로세스 전역**이다(§5.2 — 현재 언어는 전역 하나, 창마다 다를 이유가 없다).
/// Swift 가 세션을 만들기 전마다 메인 스레드에서 부른다(같은 값이면 무해). 빈 값·null 은 무동작이라 로케일을 못 읽는
/// 환경에서도 안전하고, 그때는 `auto` 가 `en` 으로 떨어진다.
/// **ABI 버전을 올리지 않는다.** 이 저장소의 관행은 기존 시그니처·struct layout 이 바뀔 때만 올리는
/// 것이고(v169 = draw 계약 변경), export **추가**는 하위호환이라 올리지 않는다(`take_web_find_query`·
/// `remote_backend_settle` 선례). 옛 Swift 가 이 함수를 안 불러도 `auto` 가 영어로 떨어질 뿐이다.
/// 작업공간 복원이 불완전했음을 사용자에게 알린다.
///
/// **Swift 가 문장을 만들지 않는다**(i18n 계약 §7.2). 예전에는 Swift 가 한국어 문장을 조립해
/// `show_notice` 로 넘겼는데, 그것이 계약 §7.3 이 남겨 둔 "ABI 가 Swift 저작 UI 문자열을 받는" 마지막
/// 구멍이었다. Swift 는 **상태만** 알리고 문장은 여기서 고른다 — 그래서 이 안내가 `ui.language` 를
/// 따르고, 번역 대상이 두 언어에 흩어지지 않는다.
pub export fn maru_macos_app_session_notice_workspace_restore_incomplete(session: ?*AppSession) void {
    const s = session orelse return;
    s.showNoticeKey(.ws_restore_incomplete);
}

/// 파일 선택 패널의 안내 문구를 **현재 UI 언어로** 돌려준다.
///
/// **Swift 는 UI 문자열을 만들지 않는다**(i18n 계약 §7.2). 예전에는 이 네 문장이 Swift 에 한국어로
/// 박혀 있어 `ui.language` 를 따르지 않았고, 번역 대상이 두 언어(Zig·Swift)에 흩어졌다.
///
/// 반환은 **정적 문자열**이라 host 가 해제하지 않는다(테이블이 소유한다 — 널 종단이므로 Swift 가
/// `String(cString:)` 으로 그대로 읽는다). 알 수 없는 종류는 빈 문자열이고, 그때 패널은 안내 없이 뜬다
/// — 크래시보다 낫고, 종류가 늘면 여기와 아래 enum 을 함께 고치라는 신호가 된다.
pub export fn maru_macos_file_pick_message(kind: u32) [*:0]const u8 {
    const key: maru.i18n.Key = switch (kind) {
        MARU_FILE_PICK_MESSAGE_BACKGROUND_PNG => .pick_background_png,
        MARU_FILE_PICK_MESSAGE_DOCK_FILE => .pick_dock_file,
        MARU_FILE_PICK_MESSAGE_EXPLORER_FOLDER => .pick_explorer_folder,
        MARU_FILE_PICK_MESSAGE_WORKSPACE_FOLDER => .pick_workspace_folder,
        else => return "",
    };
    return maru.i18n.t(key).ptr;
}

const MARU_FILE_PICK_MESSAGE_BACKGROUND_PNG: u32 = 0;
const MARU_FILE_PICK_MESSAGE_DOCK_FILE: u32 = 1;
const MARU_FILE_PICK_MESSAGE_EXPLORER_FOLDER: u32 = 2;
const MARU_FILE_PICK_MESSAGE_WORKSPACE_FOLDER: u32 = 3;

pub export fn maru_macos_app_set_ui_locale(tag_ptr: ?[*]const u8, tag_len: usize) void {
    const ptr = tag_ptr orelse return;
    if (tag_len == 0 or tag_len > 128) return;
    maru.i18n.setOsLocale(ptr[0..tag_len]);
}

pub export fn maru_macos_app_instance_lease_acquire(path_ptr: ?[*]const u8, path_len: usize) u32 {
    const ptr = path_ptr orelse return @intFromEnum(AppInstanceLeaseResult.invalid_path);
    if (path_len == 0 or path_len > 4095) return @intFromEnum(AppInstanceLeaseResult.invalid_path);
    const path = ptr[0..path_len];
    if (std.mem.indexOfScalar(u8, path, 0) != null)
        return @intFromEnum(AppInstanceLeaseResult.invalid_path);

    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [:0]const u8 = path_buf[0..path.len :0];
    return @intFromEnum(app_instance_lease_slot.acquire(path_z));
}

pub export fn maru_macos_session_config_bootstrap() u32 {
    if (!app_instance_lease_slot.isHeld()) return @intFromEnum(SessionConfigBootstrapResult.no_lease);
    session_mod.bootstrapSessionKeepAliveConfig(
        std.Io.Threaded.global_single_threaded.io(),
        std.heap.page_allocator,
    ) catch |err| return @intFromEnum(switch (err) {
        error.AlreadyInitialized => SessionConfigBootstrapResult.already_initialized,
        else => SessionConfigBootstrapResult.load_failure,
    });
    return @intFromEnum(SessionConfigBootstrapResult.ready);
}

pub export fn maru_macos_session_default_false_observation() u32 {
    if (!app_instance_lease_slot.isHeld())
        return @intFromEnum(SessionDefaultFalseObservation.not_bootstrapped);
    return @intFromEnum(classifyDefaultFalseSnapshot(session_mod.appKeepAliveSnapshotIfBootstrapped()));
}

fn classifyDefaultFalseSnapshot(snapshot_optional: ?session_mod.config_mod.SessionKeepAliveSnapshot) SessionDefaultFalseObservation {
    const snapshot = snapshot_optional orelse return .not_bootstrapped;
    if (snapshot.value) return .resolved_true;
    switch (snapshot.provenance) {
        .absent => {},
        .explicit_valid, .explicit_invalid => return .explicit_override,
    }
    if (snapshot.file_provenance != .missing) return .config_present;
    return .matched;
}

test "default false observation classifies every bootstrap state without caller booleans" {
    const Snapshot = session_mod.config_mod.SessionKeepAliveSnapshot;
    try std.testing.expectEqual(SessionDefaultFalseObservation.not_bootstrapped, classifyDefaultFalseSnapshot(null));
    try std.testing.expectEqual(SessionDefaultFalseObservation.matched, classifyDefaultFalseSnapshot(Snapshot{
        .value = false,
        .provenance = .absent,
        .file_provenance = .missing,
    }));
    try std.testing.expectEqual(SessionDefaultFalseObservation.resolved_true, classifyDefaultFalseSnapshot(Snapshot{
        .value = true,
        .provenance = .absent,
        .file_provenance = .missing,
    }));
    try std.testing.expectEqual(SessionDefaultFalseObservation.explicit_override, classifyDefaultFalseSnapshot(Snapshot{
        .value = false,
        .provenance = .{ .explicit_valid = false },
        .file_provenance = .readable,
    }));
    try std.testing.expectEqual(SessionDefaultFalseObservation.explicit_override, classifyDefaultFalseSnapshot(Snapshot{
        .value = false,
        .provenance = .explicit_invalid,
        .file_provenance = .readable,
    }));
    try std.testing.expectEqual(SessionDefaultFalseObservation.config_present, classifyDefaultFalseSnapshot(Snapshot{
        .value = false,
        .provenance = .absent,
        .file_provenance = .unreadable,
    }));
}

pub export fn maru_macos_incident_owner_shutdown() u32 {
    return @intFromEnum(session_mod.shutdownProcessIncidentOwner());
}

pub export fn maru_macos_remote_backend_settle() u32 {
    return @intFromEnum(session_mod.settleProcessRemoteBackendForTermination());
}

pub export fn maru_macos_reconnect_product_tick() u32 {
    return @intFromEnum(session_mod.tickReconnectProductCoordinator());
}

pub export fn maru_macos_reconnect_product_shutdown() u32 {
    return @intFromEnum(session_mod.shutdownReconnectProductCoordinator());
}

pub const ReconnectProductSmokeProbe = extern struct {
    coordinator_ready: u32,
    worker_state_raw: u32,
    active_jobs: u32,
    job_receipt_present: u32,
    completion_receipt_present: u32,
    cr5_job_present: u32,
    cr5_preparing: u32,
    cr5_state_raw: u32,
    runtime_count: u32,
    admission_count: u32,
    resident_entries: u32,
};

pub export fn maru_macos_reconnect_product_smoke_probe(out_probe: ?*ReconnectProductSmokeProbe) c_int {
    const out = out_probe orelse return @intFromEnum(Status.null_out);
    const probe = session_mod.reconnectProductSmokeProbe();
    out.* = .{
        .coordinator_ready = @intFromBool(probe.coordinator_ready),
        .worker_state_raw = probe.worker_state_raw,
        .active_jobs = probe.active_jobs,
        .job_receipt_present = @intFromBool(probe.job_receipt_present),
        .completion_receipt_present = @intFromBool(probe.completion_receipt_present),
        .cr5_job_present = @intFromBool(probe.cr5_job_present),
        .cr5_preparing = @intFromBool(probe.cr5_preparing),
        .cr5_state_raw = probe.cr5_state_raw,
        .runtime_count = probe.runtime_count,
        .admission_count = probe.admission_count,
        .resident_entries = probe.resident_entries,
    };
    return @intFromEnum(Status.ok);
}

pub const SessionHostWakeSource = extern struct {
    fd: i32,
    reserved: u32 = 0,
    host_id_low: u64,
    host_id_high: u64,
    connection_generation: u64,
};

/// Returns borrowed descriptor identities only. AppKit read sources wake the main actor and call
/// the ordinary tick; descriptor ownership and all reads remain in Client/RemoteTermBackend.
pub export fn maru_macos_remote_backend_wake_sources(
    out_sources: ?[*]SessionHostWakeSource,
    capacity: usize,
) usize {
    const backend = if (session_mod.app_remote_backend) |*value| value else return 0;
    var scratch: [session_host.remote_term_backend.max_remote_backend_runtimes]session_host.remote_term_backend.RemoteTermBackend.WakeSource = undefined;
    const count = backend.wakeSources(&scratch);
    if (out_sources) |out| {
        const copied = @min(count, capacity);
        for (scratch[0..copied], out[0..copied]) |source, *destination| {
            destination.* = .{
                .fd = source.fd,
                .host_id_low = @truncate(source.host_id),
                .host_id_high = @truncate(source.host_id >> 64),
                .connection_generation = source.connection_generation,
            };
        }
    }
    return count;
}

/// 앱 로그 상한. 넘으면 새로 시작한다 — 진단은 **최근 실행**이 중요하고, 회전 정책을 따로 두면
/// 그 정책 자체가 관리 대상이 된다. host 로그와 달리 앱은 한 파일에 계속 쌓이므로 상한이 없으면
/// 무한히 자란다.
const app_log_max_bytes: i64 = 4 * 1024 * 1024;

/// `<base>/app.log` 를 append 로 열고 상한을 넘었으면 비운다. 실패하면 `-1`.
///
/// 부작용을 이 함수 하나로 좁혀 테스트가 실제 파일로 계약을 잴 수 있게 한다 — `dup2` 로 프로세스
/// stderr 를 바꾸는 쪽은 테스트가 건드릴 수 없기 때문이다.
fn openAppLogFd(base: [:0]const u8) c_int {
    _ = std.c.mkdir(base.ptr, @as(std.c.mode_t, 0o700));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/app.log", .{base}) catch return -1;

    const fd = std.c.open(
        path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .NOFOLLOW = true },
        @as(std.c.mode_t, 0o600),
    );
    if (fd < 0) return -1;
    // 크기 확인에 별도 stat 을 쓰지 않는다 — 이미 연 fd 의 끝 오프셋이 곧 크기다.
    if (std.c.lseek(fd, 0, std.c.SEEK.END) > app_log_max_bytes) _ = std.c.ftruncate(fd, 0);
    return fd;
}

/// GUI 실행(Dock·Finder)의 stderr 는 `/dev/null` 이라 진단이 통째로 사라진다. host 는 이미
/// `redirectStderrToHostLog`(daemon.zig)로 같은 문제를 풀었고 앱만 사각지대로 남아 있었다 —
/// 2026-08-26 에 앱이 host 연결을 잃은 원인(`stage=runtime_death error=ConnectionClosed`)을 찾을 때,
/// 터미널에서 앱을 손으로 다시 띄우는 것 말고는 그 한 줄을 볼 방법이 없었다. 그때는 이미 재현이
/// 끝난 뒤라 **사후 진단이 불가능**했다.
///
/// **stderr 가 tty 면 건드리지 않는다.** 터미널에서 직접 띄웠다면 콘솔이 이미 진단을 받고 있고,
/// 그것을 파일로 가로채면 개발 중 출력을 빼앗는다.
///
/// 이 파일의 `c` 는 `@cImport(app_host_abi.h)` 라 daemon.zig 의 `c = std.c` 와 다르다. syscall 은
/// `std.c` 로 명시해 부른다 — 섞으면 플래그가 조용히 깨진다.
/// 실행 중에도 캡을 지킨다.
///
/// `openAppLogFd` 는 **열 때 한 번만** 크기를 재므로, 앱이 며칠 떠 있으면 그 캡이 아무 의미가 없다.
/// 2026-08-27 실측: 4MB 캡을 둔 `app.log` 가 **28MB** 까지 자랐다(원인은 tick 마다 찍히던 정상 로그).
/// 그 소음은 따로 없앴지만, 캡은 소음이 다시 생겨도 파일이 무한히 자라지 않게 하는 마지막 방어선이라
/// 주기적으로도 재야 한다.
///
/// redirect 이후 fd 2 가 곧 app.log 이므로 별도 fd 를 들고 다니지 않는다. `O_APPEND` 라 오프셋을 끝으로
/// 옮겨도 다음 write 는 그대로 끝에 붙고, truncate 뒤에는 0 부터 다시 쌓인다.
/// **우리가 실제로 fd 2 를 app.log 로 바꿨을 때만** 참이다. 이 플래그 없이 `isatty` 만 보면
/// `maru-macos-app 2> mylog.txt` 처럼 사용자가 자기 파일로 리다이렉트한 실행에서 — `isatty` 는 0 이고
/// `openAppLogFd` 가 실패해 리다이렉트는 일어나지 않은 상태에서 — 캡이 **사용자 파일을 잘라버린다**.
/// 로그를 줄이려다 남의 데이터를 파괴하는 교환은 성립하지 않는다.
var app_log_redirected: bool = false;

fn enforceAppLogCap() void {
    if (builtin.is_test) return;
    if (!app_log_redirected) return;
    if (std.c.lseek(2, 0, std.c.SEEK.END) > app_log_max_bytes) _ = std.c.ftruncate(2, 0);
}

fn redirectStderrToAppLog() void {
    if (builtin.is_test) return;
    if (std.c.isatty(2) != 0) return;

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = controlBaseDir(&base_buf) orelse return;
    const fd = openAppLogFd(base);
    if (fd < 0) return;
    defer if (fd > 2) {
        _ = std.c.close(fd);
    };
    if (std.c.dup2(fd, 2) < 0) return;
    app_log_redirected = true;

    // 여러 실행이 한 파일에 쌓이므로 어디부터가 이번 실행인지 보이게 한다.
    var header_buf: [96]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "=== maru app start pid={d} ===\n", .{std.c.getpid()}) catch return;
    _ = std.c.write(2, header.ptr, header.len);
}

/// 비정상 종료의 **흔적**을 남긴다 — 시작 마커와 짝이 되는 종료 마커다.
///
/// 2026-08-29 실측: 앱 업데이트 직후 여섯 번(44227·44753·44784·44833·44906·44915) 연속으로 앱이
/// 조용히 사라졌는데, `app.log` 에는 `workspace checkpoint: final-quit` 이 **한 줄도 없고**
/// `~/Library/Logs/DiagnosticReports` 에도 그 시각 리포트가 **하나도 없었다**. 정상 종료도 크래시도
/// 아니라는 것까지는 알아도 거기서 끝이다 — 시그널로 죽었는지, 종료 경로 앞에서 빠져나갔는지를
/// 가를 재료가 **하나도 없었다**. 원인을 못 좁혀 코드 수정이 전부 추측이 되는 상태였다.
///
/// 그래서 고칠 것은 개별 종료 사유가 아니라 **진단 불가 자체**다. `redirectStderrToAppLog` 이
/// "GUI 의 stderr 가 /dev/null 이라 진단이 사라진다"를 푼 것과 같은 축의 사각지대다.
///
/// 세 가지가 구분된다:
///   - `signal=N`  — 잡을 수 있는 시그널로 죽었다(크래시·TERM·HUP…).
///   - `via=exit`  — `exit()` 로 정상 종료했다(정상 quit 경로든 조기 반환이든).
///   - **아무 종료 줄도 없음** — `SIGKILL`·전원 차단처럼 잡을 수 없는 경로다. 시작 마커만 남으므로
///     그 부재 자체가 증거가 된다.
var exit_diagnostics_installed: bool = false;

/// 시그널 핸들러 안에서는 async-signal-safe 한 것만 부를 수 있다. `std.fmt` 는 그 보장이 없으므로
/// 십진 변환을 직접 한다 — 진단을 남기려다 핸들러 안에서 죽으면 아무것도 못 남긴다.
fn appendDecimal(buf: []u8, offset: *usize, value: u64) void {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var rest = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    while (count > 0) {
        count -= 1;
        if (offset.* >= buf.len) return;
        buf[offset.*] = digits[count];
        offset.* += 1;
    }
}

fn appendBytes(buf: []u8, offset: *usize, text: []const u8) void {
    for (text) |ch| {
        if (offset.* >= buf.len) return;
        buf[offset.*] = ch;
        offset.* += 1;
    }
}

/// 음수도 그대로 보인다. `si_code` 는 음수 값(`SI_QUEUE` 등)을 쓰므로, 부호를 버리고 u32 로
/// 접으면 `-1` 이 `4294967295` 로 보여 읽는 사람이 커널 상수와 대조를 못 한다.
///
/// 크기는 `@abs` 로 얻는다. `-value` 로 뒤집으면 **i64 최솟값에서 오버플로 패닉**이 난다 — 실측으로
/// `thread panic: integer overflow` 를 확인했다. 지금 들어오는 값은 `si_code`·`si_pid` 라 i32 범위이니
/// 도달하지 않지만, 여기는 **시그널 핸들러 안**이라 도달 불가에 기대면 안 되는 자리다.
fn appendSigned(buf: []u8, offset: *usize, value: i64) void {
    if (value < 0) {
        appendBytes(buf, offset, "-");
        appendDecimal(buf, offset, @abs(value));
        return;
    }
    appendDecimal(buf, offset, @intCast(value));
}

/// 시그널로 죽은 경우의 마커. `pid` 를 인자로 받는 이유는 테스트 때문이다 — `getpid` 를 안에서
/// 부르면 결과가 실행마다 달라져 **무엇을 쓰는지**를 잴 수 없다.
///
/// `from` 이 핵심이다. `signal=15` 만으로는 "SIGTERM 을 받았다"까지고 **누가 보냈는지**를 모른다 —
/// 조용한 종료를 추적할 때 정작 알아야 하는 것이 그것이다. `SA_SIGINFO` 로 받은 `siginfo_t.pid` 가
/// 그 답이고, 실측으로 다른 프로세스의 `kill` 이 그 PID 로 정확히 찍히는 것을 확인했다.
/// 하드웨어 폴트(SEGV·BUS)에는 보낸 쪽이 없으므로 그때 `from` 은 의미가 없다 — 커널이 준
/// `si_code` 를 함께 남겨 둘을 구분할 수 있게 한다.
///
/// 버퍼가 모자라면 **자르고 끝낸다**. 진단 한 줄이 짧아지는 것과 핸들러 안에서 죽는 것 중
/// 후자가 비교할 수 없이 나쁘다.
fn formatSignalExitMarker(buf: []u8, pid: u64, signal: u64, code: i64, sender: i64) []const u8 {
    var offset: usize = 0;
    appendBytes(buf, &offset, "=== maru app exit pid=");
    appendDecimal(buf, &offset, pid);
    appendBytes(buf, &offset, " signal=");
    appendDecimal(buf, &offset, signal);
    appendBytes(buf, &offset, " code=");
    appendSigned(buf, &offset, code);
    appendBytes(buf, &offset, " from=");
    appendSigned(buf, &offset, sender);
    appendBytes(buf, &offset, " ===\n");
    return buf[0..offset];
}

/// `exit()` 로 끝난 경우의 마커. 붙일 숫자가 없다.
fn formatCleanExitMarker(buf: []u8, pid: u64) []const u8 {
    var offset: usize = 0;
    appendBytes(buf, &offset, "=== maru app exit pid=");
    appendDecimal(buf, &offset, pid);
    appendBytes(buf, &offset, " via=exit ===\n");
    return buf[0..offset];
}

/// `write(2, …)` 한 번으로 끝낸다. redirect 뒤 fd 2 가 곧 `app.log` 이고, tty 실행이면 콘솔이다 —
/// 어느 쪽이든 시작 마커가 간 곳과 같은 자리라 짝이 맞는다.
fn writeMarker(line: []const u8) void {
    _ = std.c.write(2, line.ptr, line.len);
}

/// `SA_SIGINFO` 로 받는다. 세 번째 인자(`ucontext`)는 쓰지 않는다 — 레지스터 덤프는 macOS 크래시
/// 리포트가 이미 훨씬 잘 남기고, 우리가 필요한 것은 **누가 언제 끝냈는지** 한 줄이다.
fn exitSignalHandler(
    sig: std.posix.SIG,
    info: *const std.c.siginfo_t,
    _: ?*anyopaque,
) callconv(.c) void {
    // 최악의 경우(20자리 pid·signal·code·from)가 127바이트다. 128 로 두면 축을 하나만 더해도
    // 조용히 잘리므로 여유를 준다 — 잘림은 안전하지만 진단이 말없이 짧아지는 것은 이 기능의 목적을 깎는다.
    var buf: [192]u8 = undefined;
    writeMarker(formatSignalExitMarker(
        &buf,
        @intCast(std.c.getpid()),
        @intFromEnum(sig),
        info.code,
        info.pid,
    ));

    // 기본 처분으로 되돌린 뒤 **다시 올린다**. 이 단계를 빼면 우리가 시그널을 삼켜 버려서 macOS 가
    // 크래시 리포트를 못 쓴다 — 진단을 늘리려다 원래 있던 진단을 없애는 교환이 된다.
    const restore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &restore, null);
    _ = std.c.raise(sig);
}

fn exitAtexitHandler() callconv(.c) void {
    var buf: [64]u8 = undefined;
    writeMarker(formatCleanExitMarker(&buf, @intCast(std.c.getpid())));
}

/// 시작 마커를 찍는 자리에서 함께 건다. 앱 세션은 한 프로세스에서 여러 번 만들어질 수 있으므로
/// 한 번만 설치한다.
fn installExitDiagnostics() void {
    if (builtin.is_test) return;
    if (exit_diagnostics_installed) return;
    exit_diagnostics_installed = true;

    const action: std.posix.Sigaction = .{
        .handler = .{ .sigaction = exitSignalHandler },
        .mask = std.posix.sigemptyset(),
        // `SA_SIGINFO` 가 없으면 `siginfo_t` 를 못 받아 **보낸 쪽 PID 가 통째로 사라진다**.
        .flags = std.c.SA.SIGINFO,
    };
    // 크래시 계열과 종료 요청 계열을 함께 건다. `PIPE` 는 **뺀다** — 이 저장소는 곳곳에서 그 처분을
    // 의도적으로 관리하고 있어(`control_relay.zig`·`external_attach_cli.zig`) 여기서 덮으면 그 결정을
    // 조용히 뒤집는다.
    const watched = [_]std.posix.SIG{
        .SEGV, .BUS, .ILL, .FPE,  .ABRT, .TRAP, .SYS,
        .TERM, .HUP, .INT, .QUIT, .XCPU, .XFSZ,
    };
    for (watched) |sig| std.posix.sigaction(sig, &action, null);

    _ = atexit(exitAtexitHandler);
}

pub export fn maru_macos_app_session_create(
    config: ?*const AppSessionConfig,
    out_session: ?*?*AppSession,
) c_int {
    // 앱의 가장 이른 Zig 진입점이다. 여기서 걸어야 config 경고를 포함한 시작 단계 진단이 전부 남는다.
    redirectStderrToAppLog();
    // 종료 마커는 시작 마커와 짝이어야 의미가 있으므로 같은 자리에서 건다.
    installExitDiagnostics();
    const raw_config = (config orelse return @intFromEnum(Status.null_out)).*;
    const out = out_session orelse return @intFromEnum(Status.null_out);
    out.* = null;

    _ = session_mod.normalizeConfig(raw_config) catch |err| switch (err) {
        error.UnsupportedAbi => return @intFromEnum(Status.unsupported_abi),
        error.InvalidConfig => return @intFromEnum(Status.invalid_config),
    };

    const session = allocator.create(AppSession) catch return @intFromEnum(Status.create_failed);
    // 이 함수는 c_int를 반환해 정상 return(@intFromEnum)으로 끝나므로 errdefer가 발화하지 않는다 — init 실패 시
    // 바깥 struct를 catch 안에서 직접 해제해야 누수가 안 난다. (init 내부 errdefer self.deinit()는 내부 할당만
    // 정리하지 이 create로 잡은 struct 자체는 못 푼다. 호스트는 실패 시 핸들이 없어 destroy도 못 한다.)
    session.init(std.Io.Threaded.global_single_threaded.io(), allocator, raw_config) catch {
        allocator.destroy(session);
        return @intFromEnum(Status.create_failed);
    };
    // AppSession의 terminal/web Term teardown 단일 훅을 컨트롤 수명에 연결한다. terminal pane이 닫힐 때도 그 pane이
    // 발급한 grant-origin wait를 즉시 unauthorized로 끝내야 하므로 WKWebView destroy 전이만 관찰해서는 부족하다.
    session.setSurfaceClosedCallback(null, onAppSessionSurfaceClosed);

    out.* = session;
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_tick(
    session: ?*AppSession,
    frame_loop_rate_hz: u32,
    out_summary: ?*AppFrameSummary,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    app_session.setFrameLoopRateHz(frame_loop_rate_hz);
    app_session.maybeDebugOpenSettings(); // MARU_OPEN_SETTINGS 시각 확인 훅 — tick(렌더) 전에 열어야 이 frame에 모달이 든다(env 미설정이면 무동작)
    app_session.maybeDebugOpenWebPanel(); // MARU_WEB_PANEL 시각 확인 훅 — 활성 pane에 web Term을 열고 활성화(4e-2, 본문 blank·크래시 0; env 미설정이면 무동작)
    app_session.maybeDebugOpenFilePanel(); // FP3: MARU_FILE_PANEL=<path> 창-로컬 도크 시각 픽스처.
    app_session.maybeDebugOpenSymbolPicker(); // §7.5 심볼 피커 캡처 훅 — 파일이 이미 열려 있어도 뜬다
    app_session.maybeDebugOpenPalette(); // 커맨드 팔레트 캡처 훅 — 행에 붙는 chord 표시를 잰다
    app_session.maybeDebugOpenFind(); // 찾기 캡처 훅 — 카운터 앞의 규칙 표시를 잰다
    app_session.maybeDebugEditOp(); // 편집 연산 캡처 훅 — 화면에 남는 결과를 잰다(§3.9a·§3.9b)
    out.* = app_session.tick() catch return @intFromEnum(Status.tick_failed);
    // PTY 세션이 종료되면 ok가 아니라 session_ended를 올려, host가 죽은 세션을 무한 tick하지
    // 않고 frame loop를 멈춰 우아하게 내려가게 한다. ended는 latch라 이후 tick도 동일 신호다.
    if (out.ended != 0) return @intFromEnum(Status.session_ended);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_key_down(
    session: ?*AppSession,
    event: ?*const KeyEvent,
    out_summary: ?*AppFrameSummary,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const raw_event = (event orelse return @intFromEnum(Status.null_out)).*;
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    const key_event = keyEventFromAbi(raw_event) catch return @intFromEnum(Status.invalid_config);
    // 이 export는 MaruMetalTerminalView 전용이다. WebView app shortcut은 surface-aware
    // dispatch_web_app_action을 쓰므로, Metal provenance를 잃지 않는 별도 funnel로 보낸다.
    out.* = app_session.handleMetalKeyEvent(key_event) catch return @intFromEnum(Status.key_failed);
    return @intFromEnum(Status.ok);
}

/// AS4-c fixture-only synchronization.  This never opens a tab, reads a
/// provider source, or resolves an archive action; it merely releases the
/// detail worker after the AppKit host has observed the loading frame.
pub export fn maru_macos_app_session_set_agent_session_archive_detail_smoke_gate(
    session: ?*AppSession,
    blocked: u32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    if (blocked > 1) return @intFromEnum(Status.invalid_config);
    app_session.setAgentSessionArchiveDetailSmokeGate(blocked != 0);
    return @intFromEnum(Status.ok);
}

/// Read-only companion for the fixture's bounded wait.  A false result means
/// either an unarmed gate or that the worker has not reached it yet.
pub export fn maru_macos_app_session_agent_session_archive_detail_smoke_gate_reached(
    session: ?*const AppSession,
) u32 {
    const app_session = session orelse return 0;
    return @intFromBool(app_session.agentSessionArchiveDetailSmokeGateReached());
}

/// AS4 snapshot-replace fixture-only synchronization. This has no archive/action mutation
/// capability: it can only hold/release a detached scan before discovery.
pub export fn maru_macos_app_session_set_agent_session_archive_smoke_gate(
    session: ?*AppSession,
    blocked: u32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    if (blocked > 1) return @intFromEnum(Status.invalid_config);
    app_session.setAgentSessionArchiveSmokeGate(blocked != 0);
    return @intFromEnum(Status.ok);
}

/// Read-only companion for the fixture's bounded wait. A false result means an unarmed gate or
/// a worker that has not reached it yet.
pub export fn maru_macos_app_session_agent_session_archive_smoke_gate_reached(
    session: ?*const AppSession,
) u32 {
    const app_session = session orelse return 0;
    return @intFromBool(app_session.agentSessionArchiveSmokeGateReached());
}

/// Closed-fixture evidence only. The host can read this after dispatching a real pointer event,
/// but cannot use it to mutate archive state or invoke an action.
pub export fn maru_macos_app_session_agent_session_archive_smoke_stale_reveal_count(
    session: ?*const AppSession,
) u32 {
    const app_session = session orelse return 0;
    return app_session.agentSessionArchiveSmokeStaleRevealCount();
}

/// Closed-fixture evidence only. This exposes no archive data, only whether the ready active
/// detail is a Claude record with a parsed model.
pub export fn maru_macos_app_session_agent_session_archive_smoke_claude_model_present(
    session: ?*const AppSession,
) u32 {
    const app_session = session orelse return 0;
    return @intFromBool(app_session.agentSessionArchiveSmokeClaudeModelPresent());
}

/// Closed-fixture-only ownership observer. It exposes no text, path, action, or mutable
/// archive state; it lets the AppKit smoke prove that a dock disclosure retained focus.
pub export fn maru_macos_app_session_agent_session_archive_smoke_active_surface_id(
    session: ?*const AppSession,
) u64 {
    const app_session = session orelse return 0;
    return app_session.agentSessionArchiveSmokeActiveSurfaceId();
}

/// Closed-fixture-only ownership observer paired with `...active_surface_id`. The AppKit
/// smoke compares this before card activation and while loading/ready; it is not automation.
pub export fn maru_macos_app_session_agent_session_archive_smoke_term_count(
    session: ?*const AppSession,
) u32 {
    const app_session = session orelse return 0;
    return app_session.agentSessionArchiveSmokeTermCount();
}

pub const DividerSmokeProbe = extern struct {
    x_px: i32,
    y_px: i32,
    width_px: u32,
    height_px: u32,
    ratio_milli: u32,
    present: u32,
    capture_active: u32,
    move_events: u64,
    resize_applications: u64,
    padding_left_px: u32,
    padding_right_px: u32,
    web_covered_dividers: u32,
    scrollbar_present: u32,
    scrollbar_thumb_x_px: i32,
    scrollbar_thumb_y_px: i32,
    scrollbar_thumb_w_px: u32,
    scrollbar_thumb_h_px: u32,
    scrollbar_capture_active: u32,
    scrollbar_offset_px: u64,
    scrollbar_move_events: u64,
    scrollbar_scroll_applications: u64,
    // CIM4b: 탭 바 발행 기하 + provisional preview 관측치. 끝에 덧붙여 기존 필드 offset을 그대로 둔다.
    tab_bar_present: u32,
    tab_count: u32,
    tab_first_x_px: i32,
    tab_slot_w_px: u32,
    tab_bar_y_px: i32,
    tab_drag_active: u32,
    tab_visible_first_id: u64,
    tab_model_first_id: u64,
};

pub const RecoveredSessionSmokeProbe = extern struct {
    row_present: u32,
    row_x_px: i32,
    row_y_px: i32,
    row_width_px: u32,
    row_height_px: u32,
    recovered_count: u32,
    tab_count: u32,
    surface_initialized: u32,
    active_remote: u32,
    marker_present: u32,
    async_wake_marker_present: u32,
    c3c_historical_count: u32,
    c3c_disconnect_after_count: u32,
    c3c_input_count: u32,
    c3c_sibling_live: u32,
    c3c_sibling_controller: u32,
    cols: u32,
    rows: u32,
    keep_alive_enabled: u32,
    discovered_candidates: u32,
    ready_adapters: u32,
    inventory_runtimes: u32,
    configured_keep_alive: u32,
    live_session_count: u32,
    target_activation_dispatched: u32,
};

pub const SessionHostInputSmokeProbe = extern struct {
    active_remote: u32,
    historical_count: u32,
    ime_count: u32,
    clipboard_count: u32,
};

/// CR6c 전용 read-only AppKit smoke projection. 이미 발행된 row rect와 aggregate
/// 상태만 내보내며 adopt/action identity는 의도적으로 노출하지 않는다.
pub export fn maru_macos_app_session_recovered_session_smoke_probe(
    session: ?*AppSession,
    out_probe: ?*RecoveredSessionSmokeProbe,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_probe orelse return @intFromEnum(Status.null_out);
    const probe = app_session.recoveredSessionAppKitSmokeProbe();
    out.* = .{
        .row_present = @intFromBool(probe.row_present),
        .row_x_px = probe.row_x_px,
        .row_y_px = probe.row_y_px,
        .row_width_px = probe.row_width_px,
        .row_height_px = probe.row_height_px,
        .recovered_count = probe.recovered_count,
        .tab_count = probe.tab_count,
        .surface_initialized = @intFromBool(probe.surface_initialized),
        .active_remote = @intFromBool(probe.active_remote),
        .marker_present = @intFromBool(probe.marker_present),
        .async_wake_marker_present = @intFromBool(probe.async_wake_marker_present),
        .c3c_historical_count = probe.c3c_historical_count,
        .c3c_disconnect_after_count = probe.c3c_disconnect_after_count,
        .c3c_input_count = probe.c3c_input_count,
        .c3c_sibling_live = @intFromBool(probe.c3c_sibling_live),
        .c3c_sibling_controller = @intFromBool(probe.c3c_sibling_controller),
        .cols = probe.cols,
        .rows = probe.rows,
        .keep_alive_enabled = @intFromBool(probe.keep_alive_enabled),
        .discovered_candidates = probe.discovered_candidates,
        .ready_adapters = probe.ready_adapters,
        .inventory_runtimes = probe.inventory_runtimes,
        .configured_keep_alive = @intFromBool(probe.configured_keep_alive),
        .live_session_count = probe.live_session_count,
        .target_activation_dispatched = @intFromBool(probe.target_activation_dispatched),
    };
    return @intFromEnum(Status.ok);
}

/// CR6d actual-AppKit smoke의 exact recovered-runtime screen counter projection.
/// 입력/action authority는 없고 이미 발행된 화면 텍스트만 센다.
pub export fn maru_macos_app_session_input_smoke_probe(
    session: ?*AppSession,
    out_probe: ?*SessionHostInputSmokeProbe,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_probe orelse return @intFromEnum(Status.null_out);
    const probe = app_session.sessionHostInputSmokeProbe();
    out.* = .{
        .active_remote = @intFromBool(probe.active_remote),
        .historical_count = probe.historical_count,
        .ime_count = probe.ime_count,
        .clipboard_count = probe.clipboard_count,
    };
    return @intFromEnum(Status.ok);
}

/// Reads the published divider grab band and this drag's coalescing instrumentation for the
/// dedicated AppKit smoke. Like the archive probe this is deliberately not a general automation
/// API: it carries no split pointer, no tree structure, and nothing the fixture could act on.
pub export fn maru_macos_app_session_divider_smoke_probe(
    session: ?*AppSession,
    out_probe: ?*DividerSmokeProbe,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_probe orelse return @intFromEnum(Status.null_out);
    const probe = app_session.dividerSmokeProbe();
    out.* = .{
        .x_px = probe.x_px,
        .y_px = probe.y_px,
        .width_px = probe.width_px,
        .height_px = probe.height_px,
        .ratio_milli = probe.ratio_milli,
        .present = @intFromBool(probe.present),
        .capture_active = @intFromBool(probe.capture_active),
        .move_events = probe.move_events,
        .resize_applications = probe.resize_applications,
        .padding_left_px = probe.padding_left_px,
        .padding_right_px = probe.padding_right_px,
        .web_covered_dividers = probe.web_covered_dividers,
        .scrollbar_present = @intFromBool(probe.scrollbar_present),
        .scrollbar_thumb_x_px = probe.scrollbar_thumb_x_px,
        .scrollbar_thumb_y_px = probe.scrollbar_thumb_y_px,
        .scrollbar_thumb_w_px = probe.scrollbar_thumb_w_px,
        .scrollbar_thumb_h_px = probe.scrollbar_thumb_h_px,
        .scrollbar_capture_active = @intFromBool(probe.scrollbar_capture_active),
        .scrollbar_offset_px = probe.scrollbar_offset_px,
        .scrollbar_move_events = probe.scrollbar_move_events,
        .scrollbar_scroll_applications = probe.scrollbar_scroll_applications,
        .tab_bar_present = @intFromBool(probe.tab_bar_present),
        .tab_count = probe.tab_count,
        .tab_first_x_px = probe.tab_first_x_px,
        .tab_slot_w_px = probe.tab_slot_w_px,
        .tab_bar_y_px = probe.tab_bar_y_px,
        .tab_drag_active = @intFromBool(probe.tab_drag_active),
        .tab_visible_first_id = probe.tab_visible_first_id,
        .tab_model_first_id = probe.tab_model_first_id,
    };
    return @intFromEnum(Status.ok);
}

/// Reads one already-published archive capability for the dedicated AppKit smoke fixture.
/// This is intentionally not a general automation API: target is a closed enum and the result
/// carries neither user/provider content nor a callable action identity.
pub export fn maru_macos_app_session_agent_session_archive_smoke_probe(
    session: ?*const AppSession,
    target: u32,
    out_probe: ?*AgentSessionArchiveSmokeProbe,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_probe orelse return @intFromEnum(Status.null_out);
    const typed_target: session_mod.AgentSessionArchiveSmokeProbeTarget = switch (target) {
        c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_CARD => .session_dock_card,
        c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME => .archive_resume,
        c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REVEAL_LOG => .archive_reveal_log,
        c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_FOCUS_LIVE => .archive_focus_live,
        c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_AGENT_SESSIONS => .dock_agent_sessions,
        c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_LAUNCHER => .dock_launcher,
        c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REFRESH => .archive_refresh,
        c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_EXPANDED_SCROLL_ANCHOR => .archive_expanded_scroll_anchor,
        c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SCOPE_ROW => .archive_scope_row,
        c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SEARCH => .archive_search,
        c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_EXPANDED_CARD => .archive_expanded_card,
        else => return @intFromEnum(Status.invalid_config),
    };
    const probe = app_session.agentSessionArchiveSmokeProbe(typed_target);
    out.* = .{
        .request_id = probe.request_id,
        .generation = probe.generation,
        .x_px = probe.x_px,
        .y_px = probe.y_px,
        .width_px = probe.width_px,
        .height_px = probe.height_px,
        .state = probe.state,
        .present = @intFromBool(probe.present),
        .enabled = @intFromBool(probe.enabled),
    };
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_resize(
    session: ?*AppSession,
    event: ?*const ResizeEvent,
    out_summary: ?*AppFrameSummary,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const raw_event = (event orelse return @intFromEnum(Status.null_out)).*;
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    if (raw_event.width_px == 0 or raw_event.height_px == 0) return @intFromEnum(Status.invalid_config);
    // grid(cols/rows)는 app session이 backing 픽셀 + 자기 cell 메트릭으로 직접 계산한다. Swift는
    // 창의 backing 픽셀과 scale만 넘기고 cols/rows를 계산하지 않는다(event.cols/rows는 무시).
    // app session이 분수 scale로 cell 메트릭을 device 해상도에 맞춘 뒤 grid를 잡으므로, Swift가
    // 메트릭 준비 전 placeholder로 grid를 잘못 잡던(창과 grid가 어긋나던) 문제가 사라진다.
    out.* = app_session.resize(raw_event.width_px, raw_event.height_px, raw_event.scale_milli) catch return @intFromEnum(Status.resize_failed);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_close(
    session: ?*AppSession,
    out_summary: ?*AppFrameSummary,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    out.* = app_session.close();
    return @intFromEnum(Status.ok);
}

/// 빨간 닫기 버튼/창 단위 닫기 요청(windowShouldClose). 닫힐 창(세션)에 실행 중인 명령이 있으면 Zig가 확인 모달을
/// 열고 1(deferred)을 돌려준다 — Swift는 false를 반환해 닫기를 보류하고, 모달 확정 시 tick의 session-ended가 실제로
/// 창을 닫는다(closeWindowOrQuit — 프로그래밍적 close라 windowShouldClose 재호출/재확인 루프가 없다). 실행 중 명령이
/// 없으면 0 — Swift가 평소대로 닫는다(windowWillClose → terminate/teardown). null session이면 0(평소 닫기).
pub export fn maru_macos_app_session_request_window_close(session: ?*AppSession) c_int {
    const app_session = session orelse return 0;
    return if (app_session.requestWindowClose()) 1 else 0;
}

/// Cmd+Q/메뉴 "Quit maru"/Dock·로그아웃에 의한 앱 전체 종료 확인 요청(applicationShouldTerminate). 창 닫기와 달리
/// **항상**(실행 중 명령 무관) "maru를 종료할까요?" 확인 모달을 띄운다(앱 종료=모든 창·탭 동시 소멸이라 더 파괴적, 사용자
/// 결정 2026-06). Swift는 이 호출 뒤 .terminateLater를 돌려주고, 모달 확정/취소가 다음 tick FrameSummary.quit_decision
/// (1=accepted·2=cancelled)에 실리면 NSApp.reply(toApplicationShouldTerminate:)로 종료를 진행/취소한다.
pub export fn maru_macos_app_session_request_app_quit(session: ?*AppSession) void {
    const app_session = session orelse return;
    app_session.requestAppQuit();
}

/// host의 late protected-file preflight가 이미 수락한 Quit을 취소할 때 app-global lifecycle latch를 되돌린다.
pub export fn maru_macos_app_session_cancel_app_quit(session: ?*AppSession) void {
    const app_session = session orelse return;
    app_session.cancelAcceptedAppQuit();
}

/// Cmd+Q가 모든 창을 함께 종료하기 전 각 세션의 dirty/pending/source-edit 파일 도크 상태를 검사하는 read-only
/// getter. Swift는 종료 요청 시점과 사용자가 일반 종료 confirm을 확정한 시점에 모두 순회해, 그 사이 다른 창에서
/// 편집이 시작된 경우도 fail-closed한다.
pub export fn maru_macos_app_session_has_protected_file_panels(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return @intFromBool(app_session.hasProtectedFilePanelsForExit());
}

/// 호스트가 매 tick 주입하는 "이 세션이 앱의 마지막(유일) 일반 창인가"(1=마지막·0=아님). Zig 리프 세션은 형제
/// NSWindow를 알 수 없으므로 platform(Swift)이 windows.count로 알려준다. 마지막 창일 때 ⌘W/사이드바·탭바 ✕로 세션을
/// 닫으면 requestClose가 창 하나 닫기 대신 Cmd+Q와 동일한 "maru를 종료할까요?" 종료 확인을 띄운다(마지막 창 닫기=앱
/// 종료). quick 스크래치·멀티 창의 비-마지막 창은 0. 순수 setter라 구조체 offset 불변. 단일 출처: docs/macos-app-host-boundary.md.
pub export fn maru_macos_app_session_set_last_window(session: ?*AppSession, is_last: u32) void {
    const app_session = session orelse return;
    app_session.is_last_window = is_last != 0;
}

/// CR6a-2 primary-only virtual recovery projection identity. Swift의 `windows.first`가 단일 출처이며 quick은
/// AppSession에서 항상 false로 닫힌다.
pub export fn maru_macos_app_session_set_primary_window(session: ?*AppSession, is_primary: u32) void {
    const app_session = session orelse return;
    app_session.setPrimaryWindow(is_primary != 0);
}

/// CR6a-2 launch recovery coordinator. `has_workspace=0`이면 ptr/len을 읽지 않고 빈 trusted binding set으로
/// discovery한다. 반환값은 AppSession.RecoveredSessionsLaunchOutcome raw 값이다.
pub export fn maru_macos_app_session_prepare_recovered_sessions(
    session: ?*AppSession,
    text_ptr: ?[*]const u8,
    text_len: usize,
    has_workspace: u32,
) u32 {
    const app_session = session orelse return @intFromEnum(AppSession.RecoveredSessionsLaunchOutcome.unavailable);
    const text: ?[]const u8 = if (has_workspace != 0) blk: {
        const ptr = text_ptr orelse return @intFromEnum(AppSession.RecoveredSessionsLaunchOutcome.unavailable);
        break :blk ptr[0..text_len];
    } else null;
    return @intFromEnum(app_session.prepareRecoveredSessionsAtLaunch(text));
}

pub export fn maru_macos_app_session_finish_deferred_initial_surface(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.finishDeferredInitialSurface() catch return @intFromEnum(Status.create_failed);
    return @intFromEnum(Status.ok);
}

test "CR6a-2 ABI는 recovery launch 인자의 null 경계를 fail closed한다" {
    try std.testing.expectEqual(
        @intFromEnum(AppSession.RecoveredSessionsLaunchOutcome.unavailable),
        maru_macos_app_session_prepare_recovered_sessions(null, @ptrFromInt(1), std.math.maxInt(usize), 1),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_finish_deferred_initial_surface(null),
    );
    maru_macos_app_session_set_primary_window(null, 1);

    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const config: AppSessionConfig = .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(AppCommandKind.controlled_smoke),
        .defer_initial_surface = 1,
    };
    var session: ?*AppSession = null;
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.ok)),
        maru_macos_app_session_create(&config, &session),
    );
    defer maru_macos_app_session_destroy(session);
    try std.testing.expect(session.?.tabs.items.len == 0);

    try std.testing.expectEqual(
        @intFromEnum(AppSession.RecoveredSessionsLaunchOutcome.unavailable),
        maru_macos_app_session_prepare_recovered_sessions(session, null, 1, 1),
    );
    try std.testing.expect(session.?.tabs.items.len == 0);
}

/// cross-window 이동(M3d-2a) 결과 — status(ok/move_failed/null_out) + 소스 창이 비어 닫아야 하는지(§8A.2) + 이동한
/// surface 수(§8A.3). 라이브 배선(M3d-2b Swift)이 source_window_closed=1일 때 NSWindow를 닫는다(판정은 Zig, close는 platform).
pub const MoveResult = extern struct {
    status: c_int,
    source_window_closed: u32,
    moved_count: u32,
};

// 이동 에러(InvalidCoordinate/OutOfMemory/UnsupportedMove)를 MoveResult로 접는다 — 셋 다 move_failed(세션 유지, 이 event만 거부).
fn moveResultError(out: *MoveResult) c_int {
    out.* = .{ .status = @intFromEnum(Status.move_failed), .source_window_closed = 0, .moved_count = 0 };
    return @intFromEnum(Status.move_failed);
}

// moved_count는 **참 이동 개수**(code-review [6]) — caller가 넘긴다. outcome.moved_surfaces는 아래 export의 [256]u64
// 버퍼에 절단될 수 있어(>256=비현실적) len으로 세면 under-report하므로, 수술 전에 센 참값(workspaceSurfaceCount/
// totalSurfaceCount)을 쓴다.
fn moveResultOk(out: *MoveResult, outcome: maru.session.MoveOutcome, moved_count: usize) c_int {
    out.* = .{
        .status = @intFromEnum(Status.ok),
        .source_window_closed = @intFromBool(outcome.source_window_closed),
        .moved_count = @intCast(moved_count),
    };
    return @intFromEnum(Status.ok);
}

/// M3d-2a-i cross-window workspace 이동(docs/window-surface-mobility.md §8A.8) — src 세션의 src_index 워크스페이스를 dst
/// 세션으로 옮긴다. registry/routing을 안 건드리므로 surface가 재시작하지 않는다(§9). out.source_window_closed=1이면 소스
/// 창이 비어 Swift가 닫아야 한다(실제 NSWindow close·목적지 focus는 **M3d-2b**가 배선 — 현재 Swift 미호출, plan-link 주석).
/// src/dst/out null이면 null_out, 잘못된 인덱스나 OOM이면 move_failed.
pub export fn maru_macos_app_session_move_workspace_to(
    src: ?*AppSession,
    dst: ?*AppSession,
    src_index: usize,
    out: ?*MoveResult,
) c_int {
    const s = src orelse return @intFromEnum(Status.null_out);
    const d = dst orelse return @intFromEnum(Status.null_out);
    const o = out orelse return @intFromEnum(Status.null_out);
    // 참 이동 개수를 수술 **전에** 센다(버퍼 절단과 무관, code-review [6]). idx 범위 밖이면 0 — 이동 자체도 아래서 실패.
    const moved_count = s.workspaceSurfaceCount(src_index);
    var buf: [256]u64 = undefined; // moved surface_id 버퍼(초과분은 조용히 절단 — MoveOutcome 계약, moved_count는 참값 별도 보고)
    if (moved_count > buf.len) std.log.warn("move_workspace_to: moved surface_id buffer truncated ({d} > {d}) — moved_count is exact", .{ moved_count, buf.len });
    const outcome = s.moveWorkspaceToSession(d, src_index, &buf) catch return moveResultError(o);
    return moveResultOk(o, outcome, moved_count);
}

/// M3d-2a-i 전체 window merge(§1·§4) — src 세션의 **모든** 워크스페이스를 dst로 옮기고 src를 비운다(source_window_closed
/// 항상 1). surface 무재시작(§9). Swift 미호출(M3d-2b가 배선 — plan-link). src/dst/out null이면 null_out, OOM이면 move_failed.
pub export fn maru_macos_app_session_merge_window(
    src: ?*AppSession,
    dst: ?*AppSession,
    out: ?*MoveResult,
) c_int {
    const s = src orelse return @intFromEnum(Status.null_out);
    const d = dst orelse return @intFromEnum(Status.null_out);
    const o = out orelse return @intFromEnum(Status.null_out);
    // 참 이동 개수(버퍼 절단과 무관, [6]): self-merge(s==d)는 no-op이라 0, 아니면 src 전체 surface. 수술 전에 센다.
    const moved_count: usize = if (s == d) 0 else s.totalSurfaceCount();
    var buf: [256]u64 = undefined;
    if (moved_count > buf.len) std.log.warn("merge_window: moved surface_id buffer truncated ({d} > {d}) — moved_count is exact", .{ moved_count, buf.len });
    const outcome = s.mergeSessionInto(d, &buf) catch return moveResultError(o);
    return moveResultOk(o, outcome, moved_count);
}

// M3d-2b 단일 카드 이동 배선 — src 세션의 **활성** 워크스페이스(탭) 인덱스를 Swift에 준다. Swift 메뉴 "Move Workspace
// to Window ▸ <창>"이 이 인덱스를 move_workspace_to(src,dst,idx)에 넘겨 활성 카드 하나만 옮긴다(merge_window은 전체라
// 인덱스 불요). read-only(take_bell류 u32 반환 — 상태 코드가 아니라 값). session null·surface 미초기화·탭 전무면
// sentinel(maxInt u32)을 돌려주고 Swift가 무동작한다(이동 로직은 늘리지 않음 — 이미 있는 move_workspace_to 재사용).
pub export fn maru_macos_app_session_active_workspace_index(session: ?*AppSession) u32 {
    const app_session = session orelse return std.math.maxInt(u32);
    const idx = app_session.activeWorkspaceIndex() orelse return std.math.maxInt(u32);
    return @intCast(idx);
}

// 휠 스크롤: Swift는 raw 델타(포인트)·정밀 델타 여부·마우스 위치(backing px)만 넘기고, 줄 수 환산(매직
// 상수·clamp·NaN 가드)과 어느 panel로 보낼지(커서 아래 pane)는 app session이 한다. 스크롤 자체는
// TerminalCore가 소유한다. x/y는 split에서 비활성 panel 위 휠을 그 panel로 라우팅하는 데 쓴다(단일 panel
// 이면 활성과 같음, 사이드바/밖이면 활성 fallback).
pub export fn maru_macos_app_session_scroll_wheel(
    session: ?*AppSession,
    delta_y: f64,
    delta_x: f64,
    precise: i32,
    x_px: f64,
    y_px: f64,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.scrollWheel(delta_y, delta_x, precise != 0, x_px, y_px);
    return @intFromEnum(Status.ok);
}

// 마우스 선택(kind 1=down/2=drag/3=up/4=더블클릭 단어/5=트리플클릭 줄, backing px). 셀 변환·선택 모델은 Zig가 소유한다.
pub export fn maru_macos_app_session_mouse(
    session: ?*AppSession,
    kind: i32,
    x_px: f64,
    y_px: f64,
    button: i32,
    mods: i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.mouse(kind, x_px, y_px, button, mods);
    return @intFromEnum(Status.ok);
}

// 버튼 없는 마우스 이동(hover, backing px). Zig가 트래킹 모드를 확인해 any-event(DECSET 1003)일 때만 mouse
// reporting한다(아니면 no-op). mouseMoved마다 호출되지만 Zig가 같은 셀 반복은 스킵한다. handleHover(Cmd+링크 밑줄)와 병행.
pub export fn maru_macos_app_session_mouse_moved(
    session: ?*AppSession,
    x_px: f64,
    y_px: f64,
    mods: i32,
) void {
    const app_session = session orelse return;
    app_session.mouseMoved(x_px, y_px, mods);
}

// 클립보드 붙여넣기(Cmd+V)·드래그앤드롭. 개행 정규화(\n->\r)와 bracketed paste(DECSET 2004) 감싸기는
// Zig가 한다. escape_each!=0이면 bytes를 NUL('\0') 구분 토큰으로 보고 각 토큰을 셸 이스케이프한 뒤 공백
// 으로 join한다(드래그된 파일 경로·URL — 셸이 공백 등 메타문자에서 단어를 쪼개지 않게). 평문·Cmd+V 웹
// URL은 0(raw)으로 보낸다(이스케이프하면 ?,&,= 등이 깨진다). 무엇을 이스케이프할지는 pasteboard 타입에
// 묶여 Swift host가 정하고, 이스케이프 '메커니즘'은 Zig(app_session.shellEscapeJoin)가 단일 출처다. (v67)
pub export fn maru_macos_app_session_paste_text(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
    escape_each: u32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    if (len == 0) return @intFromEnum(Status.ok);
    const ptr = bytes orelse return @intFromEnum(Status.null_out);
    app_session.pasteText(ptr[0..len], escape_each != 0);
    return @intFromEnum(Status.ok);
}

// 드래그앤드롭 지점(backing px)의 pane/Term으로 포커스를 옮긴다 — 드롭이 **활성 pane이 아니라 떨어뜨린 pane**으로
// 들어가게 하는 라우팅. Swift handleDrop이 내용 삽입(드래그 경로는 paste_text 또는 drop_files — drop_image는 Cmd+V
// 클립보드 이미지 전용이라 여기 안 온다) **전에** 부른다.
//
// 반환은 **3-상태**다(호스트가 반드시 구분해야 한다 — 거부를 0으로 접으면 호스트가 그냥 활성 pane에 삽입해
// 애초에 막으려던 오삽입이 그대로 일어난다):
//   **1  routed**         = 그 pane(+Term)으로 포커스를 옮겼다 → 뒤이은 삽입이 거기로 간다.
//   **0  not_applicable** = 라우팅 대상 아님(사이드바·pane 밖) → 호스트는 기존대로 활성 pane에 삽입한다.
//   **-1 refused**        = 드롭 거부 → 호스트는 **내용을 삽입하면 안 된다**(chrome 오버레이/모달 열림, 또는 대상이
//                           web pane이라 붙일 PTY가 없음). 포커스도 안 옮겼다.
// 근거·가드는 app_session.routeDropAtPoint 주석. (v115)
pub export fn maru_macos_app_session_route_drop(
    session: ?*AppSession,
    x_px: f64,
    y_px: f64,
) c_int {
    const app_session = session orelse return 0;
    return @intFromEnum(app_session.routeDropAtPoint(x_px, y_px));
}

// 드래그앤드롭한 파일 경로들(NUL '\0' 구분). maru ssh 원격 세션이면 각 파일을 control socket으로 백그라운드
// 업로드한 뒤 원격 절대경로를 paste하고, 로컬 세션이면 경로를 셸 이스케이프해 paste한다 — 분기는
// Zig(app_session.handleDroppedFiles). Swift는 fileURL 드롭일 때만 부른다(웹 URL·텍스트는 paste_text). (v68)
pub export fn maru_macos_app_session_drop_files(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    if (len == 0) return @intFromEnum(Status.ok);
    const ptr = bytes orelse return @intFromEnum(Status.null_out);
    app_session.handleDroppedFiles(ptr[0..len]);
    return @intFromEnum(Status.ok);
}

// 클립보드 이미지(Cmd+V): Swift가 먼저 만든 임시 PNG 경로와 같은 PNG 바이트를 넘긴다.
// host-backed이면 비동기 freshness 판정이 둘을 소유하고, in-process 로컬이면 0을 돌려 Swift가 경로를 paste한다. (v177)
pub export fn maru_macos_app_session_drop_image(
    session: ?*AppSession,
    temp_path: ?[*]const u8,
    temp_path_len: usize,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const app_session = session orelse return 0;
    if (temp_path_len == 0 or len == 0) return 0;
    const path_ptr = temp_path orelse return 0;
    const ptr = bytes orelse return 0;
    return if (app_session.handleDroppedImage(path_ptr[0..temp_path_len], ptr[0..len])) 1 else 0;
}

// chrome Notice 모달(부분 복원 실패 등)을 연다. 세션이 복사 소유하므로 호출 뒤 버퍼는 free해도 된다.
// len==0이면 무동작. (v40)
//
// **Swift 소비처가 0이다(i18n I3f).** 유일한 호출자였던 workspace 부분 복원 안내는 문장을 Swift 가
// 조립했는데, 그것이 계약 §7.3 이 남겨 둔 "ABI 가 Swift 저작 UI 문자열을 받는" 구멍이었다. 지금은
// `…notice_workspace_restore_incomplete` 처럼 **상태만 받는 진입점**이 그 자리를 대신한다.
//
// **새 호출을 여기로 붙이지 않는다.** 표시 문장이 필요한 host 경로가 생기면 그 상태를 받는 export 를
// 따로 열고 문장은 Zig 가 고른다 — 이 함수를 쓰면 그 문장이 `ui.language` 를 안 따르고 번역 대상이
// 다시 두 언어로 흩어진다. 지우지 않고 남긴 것은 ABI 호환(v40 이후 host 가 부를 수 있다) 때문이다.
pub export fn maru_macos_app_session_show_notice(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    if (len == 0) return @intFromEnum(Status.ok);
    const ptr = bytes orelse return @intFromEnum(Status.null_out);
    app_session.showNotice(ptr[0..len]);
    return @intFromEnum(Status.ok);
}

// IME 키 트랜잭션(v20). Swift keyDown은 begin -> interpretKeyEvents -> end 순서로 부르고,
// 입력기 콜백은 insert/marked로 쌓는다. 판정(전송/무시/인코딩)은 전부 Zig가 한다 — Swift엔
// IME 분기 로직이 없다(unit 테스트 가능).
pub export fn maru_macos_app_session_ime_begin(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.imeBegin();
    return @intFromEnum(Status.ok);
}

// 입력기가 확정한 텍스트(insertText, UTF-8). 누적만 — 전송 판정은 ime_end가 한다.
pub export fn maru_macos_app_session_ime_insert(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const slice: []const u8 = if (bytes) |ptr| ptr[0..len] else &.{};
    app_session.imeInsert(slice);
    return @intFromEnum(Status.ok);
}

// 입력기의 조합 중(marked) 텍스트(UTF-8). len 0 = 조합 해제. 커서 위치에 반전 합성 표시된다.
pub export fn maru_macos_app_session_ime_marked(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const slice: []const u8 = if (bytes) |ptr| ptr[0..len] else &.{};
    app_session.imeMarked(slice);
    return @intFromEnum(Status.ok);
}

// IME 키 트랜잭션 종료 — 일괄 판정(확정 텍스트 전송 / 조합 조작 무시 / 일반 키 인코딩).
pub export fn maru_macos_app_session_ime_end(
    session: ?*AppSession,
    event: ?*const KeyEvent,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    // event가 null이면 정규화 불가 키 — 트랜잭션은 닫되 일반 키 인코딩은 생략한다(imeEnd가 처리).
    const key_event: ?terminal.KeyEvent = if (event) |e|
        (keyEventFromAbi(e.*) catch return @intFromEnum(Status.invalid_config))
    else
        null;
    app_session.imeEnd(key_event);
    return @intFromEnum(Status.ok);
}

// IME 후보창 배치용 커서 셀 사각형(backing px, 좌상단 원점). Swift가 화면 좌표로 변환해
// 후보창을 커서 위치에 띄운다(firstRect).
pub export fn maru_macos_app_session_ime_cursor_rect(
    session: ?*AppSession,
    out_x: ?*f64,
    out_y: ?*f64,
    out_w: ?*f64,
    out_h: ?*f64,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const rx = out_x orelse return @intFromEnum(Status.null_out);
    const ry = out_y orelse return @intFromEnum(Status.null_out);
    const rw = out_w orelse return @intFromEnum(Status.null_out);
    const rh = out_h orelse return @intFromEnum(Status.null_out);
    const rect = app_session.imeCursorRect();
    rx.* = rect.x;
    ry.* = rect.y;
    rw.* = rect.w;
    rh.* = rect.h;
    return @intFromEnum(Status.ok);
}

// IME deleteBackward 편집 명령(doCommand). 트랜잭션에 기록만 — 한글 마지막 자모 백스페이스의
// insertText+deleteBackward 상쇄 판정에 쓴다.
pub export fn maru_macos_app_session_ime_delete_backward(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.imeDeleteBackward();
    return @intFromEnum(Status.ok);
}

// 포커스 변화. 잃으면 조합 중 텍스트를 확정(커밋)한다 — Terminal.app/Ghostty 의미론.
pub export fn maru_macos_app_session_set_focus(session: ?*AppSession, focused: i32) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.setFocused(focused != 0);
    return @intFromEnum(Status.ok);
}

// 세팅 등 chrome 오버레이가 열렸는지(keybind 녹음 중이면 settings.open=true라 포함). Swift performKeyEquivalent가 1이면
// 메뉴바 keyEquivalent(⌘T 등)를 양보해 키를 keyDown(→ handleKeyEvent 모달/녹음 가드)으로 보낸다 — ⌘조합 단축키 누수·
// chord 녹음 누락 방지(예전엔 ⌘조합이 메뉴바 keyEquivalent에 먹혀 handleKeyEvent를 통째로 우회했다).
pub export fn maru_macos_app_session_any_overlay_open(session: ?*AppSession) c_int {
    const app_session = session orelse return 0;
    return if (app_session.anyOverlayOpen()) 1 else 0;
}

// **활성 Term 이 터미널인가**(v-terminal-gate). Swift 의 **터미널 전용 선-가로채기**(프롬프트 점프
// `⌘↑`/`⌘↓`, 스크롤백 페이지 `⇧PageUp`/`⇧PageDown`)가 이것으로 게이트한다 — 그 넷은 OSC 133 블록과
// 스크롤백을 움직이는데 편집기·웹 Term 에는 **둘 다 없다**. 게이트가 없으면 그 키들이 편집기에
// 오지도 못한다(docs/key-input-and-shortcuts.md 「선-가로채기는 터미널 것일 때만 먹는다」).
//
// **`⌘C`·`⌘V` 는 이것으로 막으면 안 된다** — 클립보드는 Term 종류와 무관한 의도이고 Zig 쪽
// `copyText`·`pasteText` 가 이미 갈래를 갖고 있다. 여기서 막으면 편집기 복사·붙여넣기가 죽는다.
//
// **fail-open 이다** — surface 가 아직 없거나 탭이 없으면 **1**을 낸다(시작 중에는 선-가로채기가
// 그대로 돈다). 부작용 없음.
pub export fn maru_macos_app_session_active_term_is_terminal(session: ?*AppSession) c_int {
    const app_session = session orelse return 1;
    return if (abi_term_ops.activeTermIsTerminal(app_session)) 1 else 0;
}

// **이 chord 를 편집기 컨텍스트가 소유하는가**(v-editor-chord). Swift performKeyEquivalent가 1이면
// 메뉴바 keyEquivalent(⌘D=Split Right 등)를 양보해 키를 keyDown으로 보낸다 — `any_overlay_open`과 같은
// 부류의 **부작용 없는** 질의다. 그 층이 없으면 `⌘D`·`⌥⌘↑`·`⌥⌘↓`가 메뉴에 먹혀 편집기에 안 온다
// (docs/key-input-and-shortcuts.md 「메뉴 keyEquivalent 층」). null/변환 실패는 0(양보 안 함).
pub export fn maru_macos_app_session_editor_owns_chord(session: ?*AppSession, event: ?*const KeyEvent) c_int {
    const app_session = session orelse return 0;
    const raw_event = (event orelse return 0).*;
    const key_event = keyEventFromAbi(raw_event) catch return 0;
    return if (app_session.editorOwnsChord(key_event)) 1 else 0;
}

// WKWebView typed route를 side-effect·PTY write 없이 조회한다. 같은 Zig resolver가 app-action/consume-unbound/
// web-editor/pass-through provenance를 보존하며, v132가 옛 v100 Bool 조회를 대체한다. null/event 변환 실패는
// pass-through. 실제 app-action은 아래 전용 export가 resolver를 다시 평가한 뒤 terminal 전처리 없이 dispatch한다.
pub export fn maru_macos_app_session_web_key_route(session: ?*AppSession, surface_id: u64, event: ?*const KeyEvent) u32 {
    const app_session = session orelse return @intFromEnum(maru.config.keybinding.WebKeyRoute.pass_through);
    const raw_event = (event orelse return @intFromEnum(maru.config.keybinding.WebKeyRoute.pass_through)).*;
    const key_event = keyEventFromAbi(raw_event) catch return @intFromEnum(maru.config.keybinding.WebKeyRoute.pass_through);
    return @intFromEnum(app_session.webKeyRoute(surface_id, key_event));
}

// route가 app-action이던 이벤트를 같은 resolver로 다시 검증해 현재 Action만 직접 실행한다. Swift의 범용 terminal
// copy/paste·scroll·macro 전처리와 PTY write를 거치지 않으며 route 뒤 config/mode가 바뀌었으면 0으로 fail-close한다.
pub export fn maru_macos_app_session_dispatch_web_app_action(session: ?*AppSession, surface_id: u64, event: ?*const KeyEvent) u32 {
    const app_session = session orelse return 0;
    const raw_event = (event orelse return 0).*;
    const key_event = keyEventFromAbi(raw_event) catch return 0;
    return if (app_session.dispatchWebAppAction(surface_id, key_event)) 1 else 0;
}

// 진행 중 IME 조합을 확정(커밋)한다. Swift가 IME를 우회하는 특수키/단축키 직전에 호출해
// marked text와 Surface preedit가 어긋나지 않게 한다(조합 없으면 무동작).
pub export fn maru_macos_app_session_commit_composition(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.commitComposition();
    return @intFromEnum(Status.ok);
}

// 마우스 호버 갱신(backing px). *out_cursor_kind에 위치별 커서 종류를 돌려준다(CursorKind: 0=arrow/사이드바·탭
// 바, 1=iBeam/터미널, 2=pointingHand/Cmd+hover URL, 3=resizeLeftRight/세로 divider, 4=resizeUpDown/가로 divider,
// 5=openHand/pane grip 호버).
// Swift가 이 값으로 NSCursor를 세운다. Zig는 부수적으로 사이드바 슬롯·pane 탭 호버·URL 밑줄을 갱신한다.
// cmd_held=0이면 URL 호버 해제. 창 밖이면 Swift가 음수 sentinel(-1,-1)을 보내 호버를 해제한다.
pub export fn maru_macos_app_session_hover(
    session: ?*AppSession,
    x_px: f64,
    y_px: f64,
    mods: i32, // 마우스 수식키 비트(xterm: shift=4, alt=8, ctrl=16, cmd=32) — Zig가 url-click-modifier와 비교(v71)
    out_cursor_kind: ?*i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_cursor_kind orelse return @intFromEnum(Status.null_out);
    out.* = @intFromEnum(app_session.hoverCursor(x_px, y_px, mods));
    return @intFromEnum(Status.ok);
}

// (config 수식키)+클릭 위치의 링크(backing px). mods가 url-click-modifier와 안 맞으면 len 0(일반 클릭). 버퍼는
// Zig 소유로 다음 url_at/destroy까지 유효. out_kind=링크 종류(0=url, 1=file_path; len>0일 때만 유효, NULL 허용)로
// Swift가 URL(string:) vs URL(fileURLWithPath:)를 가른다. v71: mods 인자. v89: out_kind 인자(docs/link-detection.md).
pub export fn maru_macos_app_session_url_at(
    session: ?*AppSession,
    x_px: f64,
    y_px: f64,
    mods: i32,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
    out_kind: ?*i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const url = app_session.urlAt(x_px, y_px, mods);
    ptr_out.* = if (url.len > 0) url.ptr else null;
    len_out.* = url.len;
    // 링크 종류(0=url, 1=file_path) — url.len>0일 때만 의미. LinkKind 태그 순서(url=0, file_path=1)에 묶인다.
    if (out_kind) |k| k.* = @intFromEnum(app_session.url_kind);
    return @intFromEnum(Status.ok);
}

// v147: 터미널에서 클릭한 **웹 링크(http/https)** 를 `input.link-open-target` 정책대로 연다. 1이면 Zig가 인앱
// browser 패널로 열기로 하고 pending action을 세웠으므로(Swift가 다음 tick `take_external_link_action`으로 drain)
// 호출자는 클릭을 소비하고 아무것도 더 하지 않는다. 0이면 정책이 시스템 브라우저이거나 대상이 아니므로
// 호출자가 그 자리에서 `NSWorkspace.open`으로 연다. url_at의 out_kind가 url(0)일 때만 부른다 — 파일 경로는
// 브라우저 대상이 아니다(Zig도 isExplicitHttpLink로 다시 좁힌다). docs/link-detection.md §링크를 어디에 여는가.
pub export fn maru_macos_app_session_open_terminal_web_link(
    session: ?*AppSession,
    url: ?[*]const u8,
    url_len: usize,
) u32 {
    const app_session = session orelse return 0;
    const ptr = url orelse return 0;
    // 상한은 URL 정책 단일 출처(file_panel_bridge.max_http_link_bytes) — 파일 경로 상한(PATH_MAX=1024)을 쓰면
    // OAuth 콜백·pre-signed URL 같은 긴 링크가 여기서 조용히 잘린다.
    if (url_len == 0 or url_len > maru.session.file_panel_bridge.max_http_link_bytes) return 0;
    return if (app_session.openTerminalWebLink(ptr[0..url_len])) 1 else 0;
}

// 선택 텍스트 추출. 반환 버퍼는 Zig 소유로 다음 copy_text/destroy까지 유효하다. 비어 있으면 len 0.
pub export fn maru_macos_app_session_copy_text(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const text = app_session.copyText();
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

// OSC 52 클립보드 쓰기 데이터. 반환 버퍼는 Zig 소유로 다음 pending_clipboard/destroy까지 유효하다. write는
// 정책상 기본 allow(terminal-compatibility-policy.md §OSC52). 데이터 없으면 len 0. Swift가 tick마다 호출해 NSPasteboard에 쓴다.
pub export fn maru_macos_app_session_pending_clipboard(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const data = app_session.pendingClipboard();
    ptr_out.* = if (data.len > 0) data.ptr else null;
    len_out.* = data.len;
    return @intFromEnum(Status.ok);
}

// OSC 9/777 데스크톱 알림 데이터(title, body, surface_id, foreground). has_out=1이면 알림 있음
// (title/body 채움 — title은 빈 문자열일 수 있어 len으로 판단), 0이면 없음. surface_id_out=발신 Term의 surface.id로,
// Swift가 알림 userInfo에 (창 토큰, surface_id)로 실어 클릭 시 발신 터미널로 점프한다(activate_surface).
// foreground_out=앱이 전면일 때도 배너로 띄울지(1=background surface / 0=현재 보고 있는 surface라 목록만)이며,
// Swift willPresent가 읽어 표시 스타일을 정한다. 반환 버퍼는 Zig 소유로
// 다음 pending_notification/destroy까지 유효. Swift가 tick마다 호출해 UNUserNotificationCenter로 띄운다(알림은 OS
// 소유 — 코어/Zig는 데이터만 넘긴다). 네 값을 같은 drain 한 번으로 원자적으로 돌려준다(race 없음).
pub export fn maru_macos_app_session_pending_notification(
    session: ?*AppSession,
    has_out: ?*u32,
    title_ptr: ?*?[*]const u8,
    title_len: ?*usize,
    body_ptr: ?*?[*]const u8,
    body_len: ?*usize,
    surface_id_out: ?*u64,
    foreground_out: ?*u32,
    route_present_out: ?*u32,
    host_id_hi_out: ?*u64,
    host_id_lo_out: ?*u64,
    runtime_id_hi_out: ?*u64,
    runtime_id_lo_out: ?*u64,
    event_id_out: ?*u64,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const has = has_out orelse return @intFromEnum(Status.null_out);
    const tp = title_ptr orelse return @intFromEnum(Status.null_out);
    const tl = title_len orelse return @intFromEnum(Status.null_out);
    const bp = body_ptr orelse return @intFromEnum(Status.null_out);
    const bl = body_len orelse return @intFromEnum(Status.null_out);
    const sid = surface_id_out orelse return @intFromEnum(Status.null_out);
    const fg = foreground_out orelse return @intFromEnum(Status.null_out);
    const route_present = route_present_out orelse return @intFromEnum(Status.null_out);
    const hid_hi = host_id_hi_out orelse return @intFromEnum(Status.null_out);
    const hid_lo = host_id_lo_out orelse return @intFromEnum(Status.null_out);
    const rid_hi = runtime_id_hi_out orelse return @intFromEnum(Status.null_out);
    const rid_lo = runtime_id_lo_out orelse return @intFromEnum(Status.null_out);
    const eid = event_id_out orelse return @intFromEnum(Status.null_out);
    const n = app_session.pendingNotification() orelse {
        has.* = 0;
        tp.* = null;
        tl.* = 0;
        bp.* = null;
        bl.* = 0;
        sid.* = 0;
        fg.* = 0;
        route_present.* = 0;
        hid_hi.* = 0;
        hid_lo.* = 0;
        rid_hi.* = 0;
        rid_lo.* = 0;
        eid.* = 0;
        return @intFromEnum(Status.ok);
    };
    has.* = 1;
    tp.* = if (n.title.len > 0) n.title.ptr else null;
    tl.* = n.title.len;
    bp.* = if (n.body.len > 0) n.body.ptr else null;
    bl.* = n.body.len;
    sid.* = n.surface_id;
    fg.* = if (n.foreground_banner) 1 else 0;
    writeNotificationRoute(n.route, route_present, hid_hi, hid_lo, rid_hi, rid_lo, eid);
    return @intFromEnum(Status.ok);
}

fn writeNotificationRoute(
    route: ?session_mod.StableNotificationRoute,
    present: *u32,
    host_hi: *u64,
    host_lo: *u64,
    runtime_hi: *u64,
    runtime_lo: *u64,
    event_id: *u64,
) void {
    if (route) |stable| {
        present.* = 1;
        host_hi.* = @intCast(stable.host_id >> 64);
        host_lo.* = @truncate(stable.host_id);
        runtime_hi.* = @intCast(stable.runtime_id >> 64);
        runtime_lo.* = @truncate(stable.runtime_id);
        event_id.* = stable.event_id;
    } else {
        present.* = 0;
        host_hi.* = 0;
        host_lo.* = 0;
        runtime_hi.* = 0;
        runtime_lo.* = 0;
        event_id.* = 0;
    }
}

test "P4 N2b3 notification ABI projects the complete stable route and zeroes route-less output" {
    var present: u32 = 99;
    var host_hi: u64 = 99;
    var host_lo: u64 = 99;
    var runtime_hi: u64 = 99;
    var runtime_lo: u64 = 99;
    var event_id: u64 = 99;

    writeNotificationRoute(.{
        .host_id = 0x00112233445566778899aabbccddeeff,
        .runtime_id = 0xffeeddccbbaa99887766554433221100,
        .event_id = 0x0123456789abcdef,
    }, &present, &host_hi, &host_lo, &runtime_hi, &runtime_lo, &event_id);
    try std.testing.expectEqual(@as(u32, 1), present);
    try std.testing.expectEqual(@as(u64, 0x0011223344556677), host_hi);
    try std.testing.expectEqual(@as(u64, 0x8899aabbccddeeff), host_lo);
    try std.testing.expectEqual(@as(u64, 0xffeeddccbbaa9988), runtime_hi);
    try std.testing.expectEqual(@as(u64, 0x7766554433221100), runtime_lo);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), event_id);

    writeNotificationRoute(null, &present, &host_hi, &host_lo, &runtime_hi, &runtime_lo, &event_id);
    try std.testing.expectEqual(@as(u32, 0), present);
    try std.testing.expectEqual(@as(u64, 0), host_hi);
    try std.testing.expectEqual(@as(u64, 0), host_lo);
    try std.testing.expectEqual(@as(u64, 0), runtime_hi);
    try std.testing.expectEqual(@as(u64, 0), runtime_lo);
    try std.testing.expectEqual(@as(u64, 0), event_id);
}

// 데스크톱 알림 클릭 → 발신 surface로 활성화. Swift가 알림 userInfo의 (창 토큰, surface_id)에서 토큰으로 올바른
// 창/세션을 고른 뒤(창 키 활성화 makeKeyAndOrderFront도 Swift), 이 세션에 surface_id를 넘긴다. Zig가 (탭/panel/
// Term)을 역조회해 그 자리로 포커스한다(activateSurfaceById — switchTab→focusPaneByPtr→focusTerm 순서 단일 출처).
// 찾아서 활성화했으면 1, 그 surface가 이미 닫혔으면 0(무동작 — 창 활성화까지만). session null이면 0. take_bell과
// 같은 u32 반환 패턴(상태 코드가 아니라 found 여부). 배너 클릭으로 그 surface를 봤으니 인앱 센터의 같은 surface
// 알림도 읽음 처리한다(배너↔센터 동기화 — 닫힌 surface여도 읽음은 한다).
pub export fn maru_macos_app_session_activate_surface(session: ?*AppSession, surface_id: u64) u32 {
    const app_session = session orelse return 0;
    // 진단: web 패널 클릭(webPanelPrimaryDown)이 이 경로로 활성 Term을 바꾼다. 탭 바에서 다른 Term을 고른 **직후**
    // 여기가 다시 불리면 사용자가 고른 탭이 즉시 되돌아간다 — 그 인과를 실행 중에 확인하려고 남긴다.
    if (diag_gate.maruDebugEnabled()) std.log.scoped(.websurface).info(
        "activate_surface id={d}",
        .{surface_id},
    );
    const found = app_session.activateSurfaceById(surface_id);
    app_session.markNotificationsReadBySurface(surface_id);
    return if (found) 1 else 0;
}

// N3 stable notification response. Swift first calls every live normal Window with
// action=0 to probe every Window without mutation, then action=1 on the exact single match. With no
// match it calls only the primary session with action=2. The latter can consume the current recovered
// projection and therefore reuses its fresh host.info/runtime.get authority checks. No-match probe
// returns 0; malformed, unknown, duplicate, stale, or failed routes return 2 and never fall back to
// a fresh shell.
/// 복구 세션 adopt 가 **왜** 실패했는지 남긴다.
///
/// 지금까지 이 경로는 사용자에게 "이 세션을 복구하지 못했습니다" 한 문장만 보여주고 사유를 통째로 버렸다
/// (`catch {}` 가 error 값을 버렸고, `!handled` 분기는 아무것도 남기지 않았다). 2026-08-27 에 사용자가
/// 목록의 host 를 눌렀을 때 실패했는데 `app.log`·unified log·crash report 어디에도 단서가 없어, host_id 가
/// 레지스트리에 없다는 **정황**까지밖에 좁히지 못했다. 사유를 버리지 않는 것이 진단의 출발점이다.
fn logRecoveredAdoptFailed(host_id: u128, runtime_id: u128, reason: []const u8) void {
    if (builtin.is_test) return;
    std.log.err(
        "recovered session adopt failed: host={x:0>32} runtime={x:0>32} reason={s}",
        .{ host_id, runtime_id, reason },
    );
}

pub export fn maru_macos_app_session_activate_notification_runtime(
    session: ?*AppSession,
    host_id_hi: u64,
    host_id_lo: u64,
    runtime_id_hi: u64,
    runtime_id_lo: u64,
    action_raw: u32,
) u32 {
    const app_session = session orelse return 0;
    const host_id = (@as(u128, host_id_hi) << 64) | host_id_lo;
    const runtime_id = (@as(u128, runtime_id_hi) << 64) | runtime_id_lo;
    const action: AppSession.NotificationRuntimeAction = switch (action_raw) {
        0 => .probe_bound,
        1 => .activate_bound,
        2 => .adopt_recovered,
        else => return 2,
    };
    const handled = app_session.activateNotificationRuntime(
        host_id,
        runtime_id,
        action,
    ) catch |err| {
        if (action == .adopt_recovered) {
            logRecoveredAdoptFailed(host_id, runtime_id, @errorName(err));
            app_session.showNoticeKey(.app_recovered_session_failed);
        }
        return 2;
    };
    if (!handled and action == .adopt_recovered) {
        // `handled=false` 는 error 가 아니다 — 붙을 대상을 못 찾았다는 뜻이라 사유가 더더욱 필요하다.
        logRecoveredAdoptFailed(host_id, runtime_id, "not_handled");
        app_session.showNoticeKey(.app_recovered_session_failed);
        return 2;
    }
    return if (handled) 1 else 0;
}

// G12 BEL: 활성 세션에 pending 벨이 있으면 1(코어 플래그 비움), 없으면 0. Swift가 tick마다 호출해 시스템 벨
// (NSSound.beep)을 울린다(벨은 OS 소유). session이 null이면 0.
pub export fn maru_macos_app_session_take_bell(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeBell()) 1 else 0;
}

// Dock 배지 1회성 신호(config bell.dock-badge). BEL이 창 포커스 없을 때 울리면 1, 아니면 0. Swift가 매 tick 호출해
// 1이면 NSApp.dockTile.badgeLabel을 ●로 세운다(포커스 복귀 시 Swift가 지움). take_bell과 같은 1회성 패턴. session null=0. (v76)
pub export fn maru_macos_app_session_take_bell_badge(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeBellBadge()) 1 else 0;
}

// 세팅 GUI에서 notifications.osc를 켠 경우 macOS 알림 권한 요청을 Swift에 맡기는 1회성 신호.
// 권한 UI/API는 OS 소유라 Swift가 처리하고, Zig는 "사용자가 데스크톱 알림을 켰다"는 의도만 latch한다. (ABI v92)
pub export fn maru_macos_app_session_take_notification_authorization_request(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeNotificationAuthorizationRequest()) 1 else 0;
}

// macOS 시스템 외관(NSAppearance)이 다크(is_dark!=0)/라이트(0)인지 Swift가 알려준다(생성 직후·외관 변경마다). config
// theme.follow-system이 켜져 있으면 Zig가 theme.preset-light/dark 색 세트로 라이브 교체한다(꺼져 있으면 무시, write-back
// 없음). 외관 판정·관찰은 OS(Swift), 색 정책은 Zig. session null=무동작. (v77)
pub export fn maru_macos_app_session_set_system_appearance(session: ?*AppSession, is_dark: i32) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.setSystemAppearance(is_dark != 0);
    return @intFromEnum(Status.ok);
}

// 창 뒤(데스크톱) 배경 블러의 유효 반경(px) — config window.blur, 단 window.opacity>=1이면 0(불투명 창=블러 안 보임).
// 블러는 GPU가 아니라 OS 창 속성이라(Metal은 backdrop을 못 읽음) host가 이 값을 OS API에 싣는다: macOS=CGSSetWindow-
// BackgroundBlurRadius(Ghostty·Terminal.app과 동일 비공개 CGS), Win=DwmSetWindowAttribute·Linux=컴포지터 속성(추후).
// 게이트 정책은 Zig 단일 출처(windowBlurRadius). 라이브 read(reload로 갱신) — Swift가 창 생성·config 반영 시 호출.
// session null=0(블러 끔). (ABI v79)
pub export fn maru_macos_app_session_window_blur_radius(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return app_session.windowBlurRadius();
}

// macOS app host frame-loop cadence(config render.frame-rate). Swift가 NSTimer 간격을 정할 때 읽는 config 희망값이다.
// 실제 tick 시간 환산은 maru_macos_app_session_tick의 frame_loop_rate_hz 인자로 받은 host 전역 cadence를 쓴다. (ABI v91/v93)
pub export fn maru_macos_app_session_frame_rate_hz(session: ?*AppSession) u32 {
    const app_session = session orelse return maru.config.theme.render_frame_rate_default;
    return app_session.configuredFrameRateHz();
}

test "frame_rate_hz ABI getter: null default and session config clamp" {
    try std.testing.expectEqual(maru.config.theme.render_frame_rate_default, maru_macos_app_session_frame_rate_hz(null));
    var session: AppSession = undefined;
    session.loaded_config.config = .{};
    session.frame_loop_rate_hz = maru.config.theme.render_frame_rate_default;
    try std.testing.expectEqual(@as(u32, 60), maru_macos_app_session_frame_rate_hz(&session));
    session.loaded_config.config.render_frame_rate = 120;
    try std.testing.expectEqual(@as(u32, 120), maru_macos_app_session_frame_rate_hz(&session));
    session.loaded_config.config.render_frame_rate = 999;
    try std.testing.expectEqual(@as(u32, 120), maru_macos_app_session_frame_rate_hz(&session));

    session.setFrameLoopRateHz(30);
    try std.testing.expectEqual(@as(u32, 120), maru_macos_app_session_frame_rate_hz(&session)); // getter는 config 희망값
    try std.testing.expectEqual(@as(u32, 30), session.frameRateHz()); // 내부 시간 환산은 host cadence
}

// 타이핑(글자 입력) 중 마우스 숨김 1회성 신호(config input.mouse-hide-while-typing). pending이면 1(플래그 비움),
// 없으면 0. Swift가 tick마다 호출해 1이면 NSCursor.setHiddenUntilMouseMoves(true)(다음 마우스 이동에서 자동 복원).
// take_bell과 같은 1회성 패턴 — 한 tick에 여러 글자를 쳐도 hide 호출은 한 번. session null=0. (ABI v72)
pub export fn maru_macos_app_session_take_mouse_hide(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeMouseHide()) 1 else 0;
}

// macOS Option을 Meta(Alt)로 쓰는지(config input.option-as-meta). 1=meta(현행 — Option+키 ESC-prefix 인코딩),
// 0=조합(입력기에 맡겨 Option+키가 특수문자 조합). Swift keyDown이 호출해 Option-단독 키를 입력기 경로로 보낼지
// (0) meta 인코딩 경로로 보낼지(1) 가른다. take_*와 달리 1회성 신호가 아니라 라이브 config 값 read(reload로 갱신).
// session null=1(현행 meta 폴백). (ABI v73)
pub export fn maru_macos_app_session_option_as_meta(session: ?*AppSession) u32 {
    const app_session = session orelse return 1;
    return if (app_session.optionAsMeta()) 1 else 0;
}

// 단축키 힌트 홀드 상태머신(keyhint_hold.zig)에 이벤트를 흘리고 Action을 돌려준다 — gesture 정책은 Zig, OS 타이머
// clock만 Swift(native 최소). 반환 Action(0=none·1=arm_timer·2=cancel·3=show·4=hide): Swift가 1=타이머 시작·2/4=타이머
// 무효화·3/4=markMetalNeedsRedraw로 매핑하고, visible 토글 자체는 머신이 chrome_host에 적용한다. mods_bits =
// 현재 눌린 modifier 비트(shift=1·control=2·option=4·command=8 — command_catalog.mod_*와 동일 인코딩). session null=0(none).
//
// **루트커즈(간헐 미표시)**: 옛 set_key_hints 경로는 Swift가 타이머 만료 콜백에서 NSEvent.modifierFlags(2번째 출처)를
// 다시 읽어 트리거 단독을 재확인했는데, 그 정적 읽기가 stale/빈 값이면 트리거를 쥐고 있어도 미표시였다. 이제 단일
// 출처(flagsChanged 이벤트 스트림)로 머신이 판정하고 만료는 글로벌을 안 읽는다(armed로 살아남음 = 유지됨). (ABI v88)
pub export fn maru_macos_app_session_key_hint_on_flags(session: ?*AppSession, mods_bits: u32) c_int {
    const app_session = session orelse return @intFromEnum(keyhint_hold.Action.none);
    const mods: keyhint_hold.Mods = .{
        .command = (mods_bits & command_catalog.mod_command) != 0,
        .control = (mods_bits & command_catalog.mod_control) != 0,
        .option = (mods_bits & command_catalog.mod_option) != 0,
        .shift = (mods_bits & command_catalog.mod_shift) != 0,
    };
    return @intCast(@intFromEnum(app_session.keyHintOnFlags(mods)));
}
// 타이머 만료 → 머신. armed면 show(글로벌 재읽기 없음 — 루트커즈 수정). session null=0(none). (ABI v88)
pub export fn maru_macos_app_session_key_hint_on_timer(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(keyhint_hold.Action.none);
    return @intCast(@intFromEnum(app_session.keyHintOnTimer()));
}
// keyDown(실제 단축키)·포커스 상실 → 머신 취소(표시 중이면 hide). session null=0(none). (ABI v88)
pub export fn maru_macos_app_session_key_hint_cancel(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(keyhint_hold.Action.none);
    return @intCast(@intFromEnum(app_session.keyHintCancel()));
}

// 단축키 힌트 config(Swift 홀드 감지가 읽어 동작 결정) — out_enabled(1/0)·out_delay_ms·out_modifier(0=command·
// 1=control·2=option)에 채운다. gesture 정책은 Zig(config) 단일 출처, 타이머 clock만 Swift. 라이브 값 read
// (reload로 갱신, 1회성 신호 아님). out 포인터는 null이면 건너뛴다. session null=null_out. (ABI v87)
pub export fn maru_macos_app_session_key_hints_config(session: ?*AppSession, out_enabled: ?*u32, out_delay_ms: ?*u32, out_modifier: ?*u32) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const cfg = app_session.keyHintConfig();
    if (out_enabled) |p| p.* = if (cfg.enabled) 1 else 0;
    if (out_delay_ms) |p| p.* = cfg.delay_ms;
    if (out_modifier) |p| p.* = cfg.modifier;
    return @intFromEnum(Status.ok);
}

// OS 클립보드 1회성 동작(input.right-click=paste·menu). 0=무동작, 1=copy, 2=paste. Zig가 우클릭/터미널 메뉴에서
// pending_clipboard_action을 세우고, Swift가 매 tick 호출해 1이면 copySelectionToPasteboard·2이면 pastePasteboardText를
// 부른다(클립보드는 OS 소유). take_bell과 같은 1회성 패턴 — drain하면 비워진다. session null=0. (ABI v74)
pub export fn maru_macos_app_session_take_clipboard_action(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return @intFromEnum(app_session.takeClipboardAction());
}

// OSC 52 읽기(`?` 쿼리)가 대기 중이고 osc52.read=allow면 1(Swift가 시스템 클립보드를 읽어 provide_clipboard_read로
// 돌려줘야 함), 아니면 0. 정책 게이트가 여기다(deny면 클립보드 안 읽음 — 탈취 방지). pending은 1회성 소비. session null=0. (v75)
pub export fn maru_macos_app_session_take_clipboard_read_request(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeClipboardReadRequest()) 1 else 0;
}

// take_clipboard_read_request가 1을 준 뒤, Swift가 읽은 시스템 클립보드 바이트를 넘긴다 — Zig가 base64 OSC 52 응답을
// 요청 surface PTY로 비차단 전송한다(`ESC ] 52 ; <Pc> ; <base64> ST`). bytes/len 0이면 빈 클립보드 응답. (v75)
pub export fn maru_macos_app_session_provide_clipboard_read(session: ?*AppSession, bytes: ?[*]const u8, len: usize) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const slice: []const u8 = if (bytes) |p| p[0..len] else &.{};
    app_session.provideClipboardRead(slice);
    return @intFromEnum(Status.ok);
}

// 세팅 window.background-image 행 활성으로 파일 선택창 요청이 대기 중이면 1(플래그 비움), 없으면 0. Swift가 tick마다
// 호출해 1이면 NSOpenPanel(PNG)을 열고 고른 경로를 provide_picked_file로 되돌린다. take_bell과 같은 1회성 신호. session null=0. (v81)
pub export fn maru_macos_app_session_take_file_pick_request(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeFilePickRequest()) 1 else 0;
}

// take_file_pick_request가 1을 준 뒤, Swift가 NSOpenPanel에서 고른 파일의 절대경로를 넘긴다 — Zig가 window.background-image에
// setText + 라이브 반영(다음 frame 디코드) + dirty(영속). bytes/len 0(취소 등)이면 무동작. 지우기는 행 Backspace가 담당. (v81)
pub export fn maru_macos_app_session_provide_picked_file(session: ?*AppSession, bytes: ?[*]const u8, len: usize) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const slice: []const u8 = if (bytes) |p| p[0..len] else &.{};
    app_session.providePickedFile(slice);
    return @intFromEnum(Status.ok);
}

// open_file_panel(Cmd+O/팔릿/메뉴) 또는 완전히 빈 도크의 우상단 launcher가 요청한 Markdown/HTML
// NSOpenPanel one-shot. 어느 producer든 AppSession.requestFilePanelPick의 같은 boolean latch로 합류한다. (v121)
pub export fn maru_macos_app_session_take_file_panel_pick_request(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeFilePanelPickRequest()) 1 else 0;
}

pub export fn maru_macos_app_session_take_file_tree_root_pick_request(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return @intFromEnum(app_session.takeFileTreeRootPickRequest());
}

pub export fn maru_macos_app_session_provide_file_tree_root_pick(session: ?*AppSession, bytes: ?[*]const u8, len: usize) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const slice: []const u8 = if (bytes) |ptr| ptr[0..len] else &.{};
    app_session.provideFileTreeRootPick(slice);
    return @intFromEnum(Status.ok);
}

// 절대경로를 현재 창 도크에 연다. 0=지원하지 않는 확장자, 1=열림/기존 탭 활성화, 2=지원 확장자지만 실패. (v121)
pub export fn maru_macos_app_session_open_file_panel_path(session: ?*AppSession, bytes: ?[*]const u8, len: usize) u32 {
    const app_session = session orelse return @intFromEnum(AppSession.FilePanelOpenPathResult.failed);
    const ptr = bytes orelse return @intFromEnum(AppSession.FilePanelOpenPathResult.failed);
    return @intFromEnum(app_session.openFilePanelPath(ptr[0..len]));
}

// surface가 도크 entry면 borrowed path와 kind(1=markdown, 2=html)를 돌려준다. 0=도크 아님. (v121)
pub export fn maru_macos_app_session_file_panel_entry(
    session: ?*AppSession,
    surface_id: u64,
    out_path: ?*?[*]const u8,
    out_len: ?*usize,
) u32 {
    if (out_path) |p| p.* = null;
    if (out_len) |p| p.* = 0;
    const app_session = session orelse return 0;
    const info = app_session.filePanelEntryInfo(surface_id) orelse return 0;
    if (out_path) |p| p.* = info.path.ptr;
    if (out_len) |p| p.* = info.path.len;
    // text·svg는 markdown과 같은 신뢰 config(1)로 태우고, 소스 CM6 언어·svg 프리뷰 선택은 file_panel_language의
    // `?lang=`과 file_panel_shell_kind의 `?kind=svg` 힌트가 맡는다(§2.2·§2.3).
    return switch (info.kind) {
        // diff(E1)는 신뢰 shell에 CM6 MergeView를 마운트한다 — 내용은 diff.open이 주므로 파일 URL을 로드하지 않는다.
        .markdown, .text, .svg, .diff => 1,
        // html·image·media·pdf는 격리 loadFileURL(2). Swift가 filePanelPath를 loadFileURL(_:allowingReadAccessTo:)로
        // 로드하고 WebKit이 HTML/PDF/이미지/미디어를 네이티브 렌더한다(§2.2) — image(FP14b)·media(FP15)는 WebKit이
        // 만드는 image/media document이고 커스텀 UX(줌·팬·체커)는 주입 스크립트가 얹는다. 신뢰 shell URL·bridge를 안 쓴다.
        .html, .image, .media, .pdf => 2,
    };
}

/// 신뢰 shell surface의 shell-kind 힌트(§2.3). svg면 "svg"를 out에 쓰고 1을 반환한다(Swift가 shell URL에
/// `?kind=svg`를 추가 → bootShell이 read 프리뷰 + xml 소스 두 모드로 동작). 그 밖의 kind이거나 도크가 아니면
/// 0(out 비움) — image는 FP14b에서 격리 문서로 옮겨가 신뢰 shell 힌트가 없다.
pub export fn maru_macos_app_session_file_panel_shell_kind(
    session: ?*AppSession,
    surface_id: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) u32 {
    if (out_ptr) |p| p.* = null;
    if (out_len) |p| p.* = 0;
    const app_session = session orelse return 0;
    const info = app_session.filePanelEntryInfo(surface_id) orelse return 0;
    const token = switch (info.kind) {
        .svg => "svg",
        // E1: diff는 같은 신뢰 shell을 쓰지만 편집 배관을 타지 않는다 — 웹이 이 힌트로 비교 화면을 띄운다.
        .diff => "diff",
        else => return 0, // FP14b: image는 격리 문서라 신뢰 shell 힌트가 없다.
    };
    if (out_ptr) |p| p.* = token.ptr;
    if (out_len) |p| p.* = token.len;
    return 1;
}

/// text kind surface의 CM6 하이라이트 언어 wire 이름을 반환한다(§2.2). markdown/html이거나 도크 파일이 아니면
/// 0을 반환하고 out을 비운다(→ Swift는 기존 markdown shell URL을 그대로 쓴다). 반환 문자열은 static이라 borrow다.
pub export fn maru_macos_app_session_file_panel_language(
    session: ?*AppSession,
    surface_id: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) u32 {
    if (out_ptr) |p| p.* = null;
    if (out_len) |p| p.* = 0;
    const app_session = session orelse return 0;
    const language = app_session.filePanelLanguage(surface_id) orelse return 0;
    const name = language.wireName();
    if (out_ptr) |p| p.* = name.ptr;
    if (out_len) |p| p.* = name.len;
    return 1;
}

/// 현재 터미널 색상 테마에서 파생한 text 소스 편집기 syntax 색(§2.3)을 `--maru-syntax-*` CSS 변수로 설정하는
/// JS 스니펫을 out에 쓴다. 신뢰 shell webview가 로드된 뒤·테마 변경 시 Swift가 evaluateJavaScript로 실행한다.
/// 반환=쓴 바이트 수(0=세션 없음/버퍼 부족). 색은 검증된 #RRGGBB라 주입 위험이 없다.
pub export fn maru_macos_app_session_syntax_style_js(
    session: ?*AppSession,
    out_ptr: ?[*]u8,
    out_cap: usize,
) usize {
    const app_session = session orelse return 0;
    const op = out_ptr orelse return 0;
    const app = app_session.appearance;
    const colors = maru.session.syntax_theme.fromTheme(app.theme);
    // 폰트 크기는 ⌘+/− 런타임 값(pt, f32)을 반올림·클램프해 넘긴다 — 편집기가 같은 pt로 스케일된다. ⌘+/− 시
    // 재주입 트리거는 file_panel_zoom_dirty drain(§2.3, drainFilePanelZoom)이라 실시간 반영된다(테마 변경 경로도 공유).
    const font_size_pt: u16 = @intFromFloat(@round(std.math.clamp(app.font.size, 1, 512)));
    const js = maru.session.syntax_theme.writeCssVarsJs(
        colors,
        maru.session.syntax_theme.diffFromTheme(app.theme),
        app.theme.selection,
        app.font.family,
        font_size_pt,
        op[0..out_cap],
    ) orelse return 0;
    return js.len;
}

pub export fn maru_macos_app_session_file_panel_mode(session: ?*AppSession, surface_id: u64) i32 {
    const app_session = session orelse return -1;
    const mode = app_session.filePanelMode(surface_id) orelse return -1;
    return @intCast(@intFromEnum(mode));
}

/// 파일 패널 mode를 설정한다(헤더 mode 선택기 클릭과 같은 경로). 1=적용/이미 그 mode, 0=없는 surface이거나
/// 그 kind가 허용하지 않는 mode. v149.
pub export fn maru_macos_app_session_set_file_panel_mode(session: ?*AppSession, surface_id: u64, raw_mode: u32) u32 {
    const app_session = session orelse return 0;
    if (raw_mode > @intFromEnum(maru.session.dock_panel.Mode.rich)) return 0;
    const mode: maru.session.dock_panel.Mode = @enumFromInt(raw_mode);
    return if (app_session.setFilePanelModeBySurface(surface_id, mode)) 1 else 0;
}

// explicit file WKWebView primary-down을 FP8 DockPanel.focused_group/FocusOwner에 반영한다. 1=승인, 0=stale/아님. (v124)
pub export fn maru_macos_app_session_focus_file_panel_surface(session: ?*AppSession, surface_id: u64) u32 {
    const app_session = session orelse return 0;
    return if (app_session.focusFilePanelSurface(surface_id)) 1 else 0;
}

pub export fn maru_macos_app_session_complete_pending_dock_focus(session: ?*AppSession, surface_id: u64) u32 {
    const app_session = session orelse return 0;
    return if (app_session.completePendingDockFocus(surface_id)) 1 else 0;
}

pub export fn maru_macos_app_session_pending_dock_focus_surface(session: ?*AppSession) u64 {
    const app_session = session orelse return 0;
    return app_session.pendingDockFocusSurface() orelse 0;
}

pub export fn maru_macos_app_session_focused_dock_surface(session: ?*AppSession) u64 {
    const s = session orelse return 0;
    return s.focusedDockSurface() orelse 0;
}

pub export fn maru_macos_app_session_take_pending_dock_focus_action(session: ?*AppSession) u64 {
    const s = session orelse return 0;
    return s.takePendingDockFocusAction() orelse 0;
}

pub export fn maru_macos_app_session_open_file_panel_link(
    session: ?*AppSession,
    surface_id: u64,
    url: ?[*]const u8,
    url_len: usize,
    force_system: u32,
) u32 {
    const app_session = session orelse return 0;
    const ptr = url orelse return 0;
    // http(s) 링크와 로컬 문서 링크가 같이 오는 경로라 둘 중 넉넉한 쪽(URL 상한)으로 재는다 — 파일 경로는
    // 이어지는 resolve/존재 검증이 다시 거른다.
    if (url_len == 0 or url_len > maru.session.file_panel_bridge.max_http_link_bytes) return 0;
    app_session.openFilePanelLink(surface_id, ptr[0..url_len], force_system != 0) catch return 0;
    return 1;
}

pub export fn maru_macos_app_session_take_external_link_action(
    session: ?*AppSession,
    url_out: ?[*]u8,
    url_cap: usize,
    surface_id_out: ?*u64,
    kind_out: ?*u32,
) usize {
    const app_session = session orelse return 0;
    const out = url_out orelse return 0;
    const sid = surface_id_out orelse return 0;
    const kind = kind_out orelse return 0;
    const action = app_session.takeExternalLinkAction(out[0..url_cap]) orelse return 0;
    sid.* = action.surface_id;
    kind.* = @intFromEnum(action.kind);
    return action.url.len;
}

pub export fn maru_macos_app_session_focus_workspace_input(session: ?*AppSession) void {
    const app_session = session orelse return;
    app_session.focusWorkspaceInput();
}

pub export fn maru_macos_app_session_take_workspace_focus_action(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeWorkspaceFocusAction()) 1 else 0;
}

pub export fn maru_macos_app_session_take_file_tree_focus_action(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeFileTreeFocusAction()) 1 else 0;
}

pub export fn maru_macos_app_session_take_file_tree_restore_surface_action(session: ?*AppSession) u64 {
    const app_session = session orelse return 0;
    return app_session.takeFileTreeRestoreSurfaceAction() orelse 0;
}

/// 마지막 `apply_workspace_window`가 조용히 버린 항목 수를 소비한다(읽고 0으로 리셋). 0이 아니면 복원된 모델이 저장
/// 파일을 표현하지 못한다는 뜻이라 Swift가 이번 실행의 checkpoint를 막아 마지막 완전본을 보존한다. null 세션은 0.
pub export fn maru_macos_app_session_take_workspace_restore_dropped(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return app_session.takeWorkspaceRestoreDropped();
}

pub export fn maru_macos_app_session_take_file_panel_mode_action(session: ?*AppSession, surface_id_out: ?*u64) i32 {
    const app_session = session orelse return -1;
    const out = surface_id_out orelse return -1;
    const action = app_session.takeFilePanelModeAction() orelse return -1;
    out.* = action.surface_id;
    return @intCast(@intFromEnum(action.mode));
}

/// 파일 본문 우클릭 메뉴에서 고른 항목 중 **web이 실행할 것**을 drain한다(docs/file-panel-kinds.md §2.6).
/// 반환은 동작 코드(0=없음·1=복사·2=잘라내기·3=붙여넣기·4=전체 선택)이고 대상 surface는 out으로 준다.
/// 선택 범위는 문서 안에 있어 native가 모르므로, Swift가 그 web에 이벤트로 되돌려 보낸다.
pub export fn maru_macos_app_session_take_file_menu_action(session: ?*AppSession, surface_id_out: ?*u64) u32 {
    const app_session = session orelse return 0;
    const out = surface_id_out orelse return 0;
    const action = app_session.takeFileMenuAction() orelse return 0;
    out.* = action.surface_id;
    return switch (action.item) {
        .copy => 1,
        .cut => 2,
        .paste => 3,
        .select_all => 4,
        // native가 실행하는 항목은 여기 오지 않는다(owner가 갈라 담는다).
        .open_link, .copy_link, .save_image, .copy_path, .open_source => 0,
    };
}

pub export fn maru_macos_app_session_take_file_panel_dirty_sync_action(session: ?*AppSession) u64 {
    const app_session = session orelse return 0;
    return app_session.takeFilePanelDirtySyncAction() orelse 0;
}

pub export fn maru_macos_app_session_take_file_panel_dirty_sync_action_v2(session: ?*AppSession, request_id_out: ?*u64) u64 {
    const app_session = session orelse return 0;
    const out = request_id_out orelse return 0;
    const action = app_session.takeFilePanelDirtySyncActionV2() orelse return 0;
    out.* = action.request_id;
    return action.surface_id;
}

pub export fn maru_macos_app_session_fail_file_panel_dirty_sync(session: ?*AppSession, surface_id: u64, request_id: u64) void {
    const app_session = session orelse return;
    app_session.failFilePanelDirtySync(surface_id, request_id);
}

pub export fn maru_macos_app_session_take_file_panel_save_close_action(session: ?*AppSession, request_id_out: ?*u64) u64 {
    const app_session = session orelse return 0;
    const out = request_id_out orelse return 0;
    const action = app_session.takeFilePanelSaveCloseAction() orelse return 0;
    out.* = action.request_id;
    return action.surface_id;
}

pub export fn maru_macos_app_session_complete_file_panel_save_close(session: ?*AppSession, surface_id: u64, request_id: u64, revision: u64, success: u32) void {
    const app_session = session orelse return;
    app_session.completeFilePanelSaveClose(surface_id, request_id, revision, success != 0);
}

pub export fn maru_macos_app_session_take_file_panel_close_unlock_action(session: ?*AppSession, request_id_out: ?*u64) u64 {
    const app_session = session orelse return 0;
    const out = request_id_out orelse return 0;
    const action = app_session.takeFilePanelCloseUnlockAction() orelse return 0;
    out.* = action.request_id;
    return action.surface_id;
}

pub export fn maru_macos_app_session_fail_file_panel_close_unlock(session: ?*AppSession, surface_id: u64, request_id: u64) void {
    const app_session = session orelse return;
    app_session.failFilePanelCloseUnlock(surface_id, request_id);
}

// FP7 FSEvents adapter: restore가 root set을 교체했으면 1회 reset. 새 root는 아래 take_root로 drain한다. (v123)
pub export fn maru_macos_app_session_take_file_tree_watch_reset(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeFileTreeWatchReset()) 1 else 0;
}

pub export fn maru_macos_app_session_take_file_tree_watch_root(
    session: ?*AppSession,
    out: ?[*]u8,
    cap: usize,
) usize {
    const app_session = session orelse return 0;
    const pending = app_session.peekFileTreeWatchRoot() orelse return 0;
    if (out == null or pending.len > cap) return pending.len;
    const root = app_session.takeFileTreeWatchRoot() orelse return 0;
    defer app_session.allocator.free(root);
    const ptr = out.?;
    @memcpy(ptr[0..root.len], root);
    return root.len;
}

/// 파일 탐색기 행의 접근성 줄 수. 스크린 리더가 자기 리듬으로 묻는 **읽기 전용** 창구다.
///
/// 이 값과 아래 두 함수는 발행 시점에 굳힌 스냅숏만 본다 — 발행된 tree 를 그대로 읽으면 라벨이
/// 해제된 메모리다(`app_session/accessibility.zig` 머리말).
pub export fn maru_macos_app_session_accessibility_count(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return @intCast(app_session.file_tree_accessibility.elements.items.len);
}

/// 줄 하나를 읽는다. 라벨·값은 **뒤이은 두 함수**로 따로 가져간다 — extern struct 에 포인터를 담으면
/// 그 포인터의 수명이 struct 를 받은 쪽에서 불분명해진다.
///
/// 범위를 벗어나면 `invalid_config` 다. host 가 세었던 수와 지금 수가 다를 수 있고(그 사이 발행이
/// 일어난다), 그때 조용히 0 번째를 주면 **다른 줄을 읽은 줄 모르고 읽는다**.
pub export fn maru_macos_app_session_accessibility_element(
    session: ?*AppSession,
    index: u32,
    out_element: ?*session_mod.accessibility.Element,
) c_int {
    const out = out_element orelse return @intFromEnum(Status.null_out);
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const elements = app_session.file_tree_accessibility.elements.items;
    if (index >= elements.len) return @intFromEnum(Status.invalid_config);
    out.* = elements[index];
    return @intFromEnum(Status.ok);
}

/// 줄의 라벨을 host 버퍼로 복사하고 **필요한 바이트 수**를 돌려준다(0 = 없거나 범위 밖).
///
/// 버퍼가 모자라면 아무것도 안 쓰고 필요한 길이만 돌려준다 — 잘라 쓰면 UTF-8 경계 가운데가 잘려
/// 스크린 리더가 깨진 글자를 읽는다.
pub export fn maru_macos_app_session_accessibility_label(
    session: ?*AppSession,
    index: u32,
    out: ?[*]u8,
    capacity: usize,
) usize {
    const app_session = session orelse return 0;
    if (index >= app_session.file_tree_accessibility.elements.items.len) return 0;
    const label = app_session.file_tree_accessibility.label(index);
    if (label.len == 0) return 0;
    const ptr = out orelse return label.len;
    if (capacity < label.len) return label.len;
    @memcpy(ptr[0..label.len], label);
    return label.len;
}

/// 같은 규약의 값(배지 숫자 등). 이름과 값을 **따로** 두는 이유는 `chrome/ui/semantics.zig` 가 소유한다.
pub export fn maru_macos_app_session_accessibility_value(
    session: ?*AppSession,
    index: u32,
    out: ?[*]u8,
    capacity: usize,
) usize {
    const app_session = session orelse return 0;
    if (index >= app_session.file_tree_accessibility.elements.items.len) return 0;
    const value = app_session.file_tree_accessibility.value(index);
    if (value.len == 0) return 0;
    const ptr = out orelse return value.len;
    if (capacity < value.len) return value.len;
    @memcpy(ptr[0..value.len], value);
    return value.len;
}

pub export fn maru_macos_app_session_file_tree_changed(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
) void {
    const app_session = session orelse return;
    const ptr = bytes orelse return;
    app_session.fileTreeChanged(ptr[0..len]);
}

pub export fn maru_macos_app_session_take_file_tree_reload_action(session: ?*AppSession, conflict_out: ?*u32) u64 {
    const out = conflict_out orelse return 0;
    out.* = 0;
    const app_session = session orelse return 0;
    const action = app_session.takeFileTreeReloadAction() orelse return 0;
    out.* = if (action.conflict) 1 else 0;
    return action.surface_id;
}

pub export fn maru_macos_app_session_take_file_tree_external_open(
    session: ?*AppSession,
    out: ?[*]u8,
    cap: usize,
) usize {
    const app_session = session orelse return 0;
    const pending = app_session.peekFileTreeExternalOpen() orelse return 0;
    if (out == null or pending.len > cap) return pending.len;
    const path = app_session.takeFileTreeExternalOpen() orelse return 0;
    defer app_session.allocator.free(path);
    const ptr = out.?;
    @memcpy(ptr[0..path.len], path);
    return path.len;
}

pub export fn maru_macos_app_session_take_file_tree_trash_action(
    session: ?*AppSession,
    out: ?[*]u8,
    cap: usize,
    request_id_out: ?*u64,
    device_out: ?*u64,
    inode_out: ?*u64,
    kind_out: ?*u32,
) usize {
    const app_session = session orelse return 0;
    const pending = app_session.peekFileTreeTrashAction() orelse return 0;
    if (out == null or request_id_out == null or device_out == null or inode_out == null or kind_out == null or pending.path.len > cap)
        return pending.path.len;
    const action = app_session.takeFileTreeTrashAction() orelse return 0;
    @memcpy(out.?[0..action.path.len], action.path);
    request_id_out.?.* = action.id;
    device_out.?.* = action.identity.device;
    inode_out.?.* = action.identity.inode;
    kind_out.?.* = action.identity.kind;
    return action.path.len;
}

pub export fn maru_macos_app_session_complete_file_tree_trash(
    session: ?*AppSession,
    request_id: u64,
    outcome_raw: u32,
    recovery_path_ptr: ?[*]const u8,
    recovery_path_len: usize,
) void {
    const app_session = session orelse return;
    const outcome: session_mod.FileTreeTrashOutcome = switch (outcome_raw) {
        @intFromEnum(session_mod.FileTreeTrashOutcome.not_moved) => .not_moved,
        @intFromEnum(session_mod.FileTreeTrashOutcome.moved_verified) => .moved_verified,
        @intFromEnum(session_mod.FileTreeTrashOutcome.moved_unverified) => .moved_unverified,
        else => return,
    };
    const recovery_path: ?[]const u8 = if (recovery_path_len == 0)
        null
    else if (recovery_path_ptr != null and recovery_path_len <= file_tree_mutation_backend.trash_path_capacity)
        recovery_path_ptr.?[0..recovery_path_len]
    else
        null;
    const validated_recovery = if (recovery_path) |path|
        if (std.fs.path.isAbsolute(path) and std.unicode.utf8ValidateSlice(path)) path else null
    else
        null;
    app_session.completeFileTreeTrash(request_id, outcome, validated_recovery);
}

// HSV picker `i`(스포이드)로 화면 색 추출 요청이 대기 중이면 1(플래그 비움), 없으면 0. Swift가 tick마다 호출해 1이면
// NSColorSampler(OS 화면 색 추출기)를 열고 고른 색을 provide_sampled_color로 되돌린다. take_bell과 같은 1회성. session null=0. (v83)
pub export fn maru_macos_app_session_take_color_sample_request(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeColorSampleRequest()) 1 else 0;
}

// take_color_sample_request가 1을 준 뒤, Swift NSColorSampler 콜백이 고른 화면 픽셀 RGB를 넘긴다(비동기) — Zig가 picker
// 선택값(pick h/s/v)에 반영한다. r/g/b는 0~255(상위 비트는 무시 — u8로 truncate). picker가 닫혔으면 무시. (v83)
pub export fn maru_macos_app_session_provide_sampled_color(session: ?*AppSession, r: u32, g: u32, b: u32) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.provideSampledColor(.{ .r = @truncate(r), .g = @truncate(g), .b = @truncate(b) });
    return @intFromEnum(Status.ok);
}

// view options(⚙) 사이드바 토글이 바뀌어 config 파일 반영이 필요하면 1(플래그 비움), 없으면 0. Swift가 tick마다
// 호출해 1이면 serialize_sidebar_config로 받은 텍스트를 config 경로에 atomic write한다(앱→config). session null=0.
pub export fn maru_macos_app_session_take_sidebar_config_dirty(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeConfigDirty()) 1 else 0;
}

// (x,y backing px)가 사이드바 헤더의 빈 영역(아이콘·검색 아님)이면 1 — Swift가 창 이동(performDrag)·더블클릭 확대(zoom)를
// 한다(네이티브 타이틀바 대체). 사이드바 접힘/헤더 없음/세션 null이면 0.
pub export fn maru_macos_app_session_is_window_drag_region(session: ?*AppSession, x_px: f64, y_px: f64) u32 {
    const app_session = session orelse return 0;
    return if (app_session.isWindowDragRegion(x_px, y_px)) 1 else 0;
}

// OSC 7로 셸이 보고한 현재 작업 디렉터리(percent-decode된 경로). 반환 버퍼는 Zig(core) 소유로
// 다음 OSC 7/RIS/destroy까지 유효하다. 한 번도 안 받았으면 len 0. Swift가 창 제목에 쓴다.
pub export fn maru_macos_app_session_cwd(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const text = app_session.currentCwd();
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

// config 파일 경로(Open Config 메뉴 — MARU_CONFIG override·$HOME/.config/maru/config, 규칙은 Zig loader가
// 단일 출처). 버퍼는 Zig 소유로 destroy까지 유효, HOME 없음/OOM이면 *out_ptr=NULL/*out_len=0(Swift 무동작).
pub export fn maru_macos_app_session_config_path(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const text = app_session.configPath();
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

// Reload Config 메뉴 — config 파일을 재로드해 재시작 없이 반영한다(폰트·여백·테마·palette·scrollback·bell·
// page-keys). 파싱은 forgiving, 로드 실패(OOM 등)면 무동작(기존 config 유지)이라 항상 Status.ok. 규칙(경로·
// 파싱)은 Zig loader가 단일 출처. Swift는 메뉴 클릭에서 호출만 한다.
pub export fn maru_macos_app_session_reload_config(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.reloadConfig();
    return @intFromEnum(Status.ok);
}

// Reset to Defaults 메뉴 — requestResetAll로 **확인 모달**을 연다(커맨드 팝업 "Reset All Settings to Defaults"와 같은
// 경로). 확정 시 모든 config를 내장 기본값으로 되돌리고 config 파일을 기본 상태(빈+주석)로 덮어쓴다(파괴적이라 무확인 즉시 실행 안 함 —
// 확정/취소는 다음 tick confirm 모달 입력으로). 항상 Status.ok. Swift는 메뉴 클릭에서 호출만 한다.
pub export fn maru_macos_app_session_reset_defaults(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.requestResetAll();
    return @intFromEnum(Status.ok);
}

// Reset 메뉴(⌘⇧R) — 활성 터미널의 잔류 입력 모드(focus 1004·mouse·kitty keyboard)만 끈다. ssh 너머 TUI가
// SIGKILL로 죽어 정리 못 한 모드가 raw 셸 입력을 오염시키는 증상(포커스마다 CSI I·비프)의 수동 회복 경로다.
// 화면·스크롤백은 보존한다(fullReset/RIS와 다름). 항상 Status.ok. Swift는 메뉴 클릭에서 호출만 한다.
pub export fn maru_macos_app_session_reset_input_modes(session: ?*AppSession) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.resetInputModes();
    return @intFromEnum(Status.ok);
}

// 창 제목으로 보여줄 문자열(OSC 0/2 제목 우선, 없으면 OSC 7 cwd basename). 우선순위는 core가
// 정한다(native 최소). 반환 버퍼는 Zig(core) 소유로 다음 OSC 0/2/7·RIS·destroy까지 유효, 없으면
// len 0(Swift가 앱 이름으로 폴백). Swift가 window.title에 쓴다.
pub export fn maru_macos_app_session_window_title(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const text = app_session.windowTitle();
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

// 이 창(세션)의 workspace restore 블록(헤더 없는 `window …` 라인)을 직렬화해 돌려준다. Swift가 멀티 창
// 저장에서 `maru.workspace.v1` 헤더 하나 아래로 각 세션 블록을 모은다. 버퍼는 Zig 소유(다음 호출/destroy까지
// 유효). 캡처/직렬화 실패(OOM 등)면 *out_len=0(Swift가 그 창을 건너뜀) — best-effort 저장이라 한 창 실패가
// 전체 저장을 막지 않는다.
pub export fn maru_macos_app_session_serialize_workspace(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
    is_active: u32,
    has_frame: u32,
    frame_x: i32,
    frame_y: i32,
    frame_w: i32,
    frame_h: i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    // is_active(!=0) = 이 창이 저장 시점 key 창(Swift window.isKeyWindow). 활성 창만 workspace.v1 옵션-키
    // active-window=1을 내고, 재시작 복원이 그 창을 다시 focus한다(M3e). false면 키 생략(옛 파일 flat 동일).
    // has_frame(!=0) = Swift window.frame(전역 스크린 좌표 점)을 저장. win-x/y/w/h 옵션-키를 내고 재시작 복원이
    // 그 위치·크기·모니터로 setFrame한다(M3f). 0이면 키 생략(옛 파일 flat 동일 → cascade). x/y는 음수 가능(보조 모니터).
    const frame: ?maru.session.workspace.Frame = if (has_frame != 0)
        .{ .x = frame_x, .y = frame_y, .w = frame_w, .h = frame_h }
    else
        null;
    const text = app_session.serializeWorkspaceWindow(is_active != 0, frame) catch {
        ptr_out.* = null;
        len_out.* = 0;
        return @intFromEnum(Status.ok);
    };
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

fn clearWorkspaceCheckpointEffect(out: *c.MaruWorkspaceCheckpointEffect) void {
    out.* = .{
        .generation = 0,
        .kind = c.MARU_WORKSPACE_CHECKPOINT_EFFECT_NONE,
        .reason = c.MARU_WORKSPACE_CHECKPOINT_REASON_BACKGROUND,
        .notice = c.MARU_WORKSPACE_CHECKPOINT_NOTICE_NONE,
    };
}

fn writeWorkspaceCheckpointEffect(
    effect: maru.session.workspace_checkpoint.Effect,
    notice: ?maru.session.workspace_checkpoint.Failure,
    out: *c.MaruWorkspaceCheckpointEffect,
) void {
    clearWorkspaceCheckpointEffect(out);
    out.notice = if (notice) |failure| switch (failure) {
        .capture_failed => c.MARU_WORKSPACE_CHECKPOINT_NOTICE_CAPTURE_FAILED,
        .write_failed => c.MARU_WORKSPACE_CHECKPOINT_NOTICE_WRITE_FAILED,
    } else c.MARU_WORKSPACE_CHECKPOINT_NOTICE_NONE;
    const request = switch (effect) {
        .capture => |request| request,
        .write => |request| request,
        .cancel_quit => {
            out.kind = c.MARU_WORKSPACE_CHECKPOINT_EFFECT_CANCEL_QUIT;
            return;
        },
        .reply_and_detach => {
            out.kind = c.MARU_WORKSPACE_CHECKPOINT_EFFECT_REPLY_AND_DETACH;
            return;
        },
        .none => return,
    };
    out.generation = request.generation;
    out.kind = switch (effect) {
        .capture => c.MARU_WORKSPACE_CHECKPOINT_EFFECT_CAPTURE,
        .write => c.MARU_WORKSPACE_CHECKPOINT_EFFECT_WRITE,
        else => unreachable,
    };
    out.reason = switch (request.reason) {
        .background => c.MARU_WORKSPACE_CHECKPOINT_REASON_BACKGROUND,
        .final_quit => c.MARU_WORKSPACE_CHECKPOINT_REASON_FINAL_QUIT,
    };
}

pub export fn maru_macos_workspace_checkpoint_arm(initial_dirty: u32) c_int {
    session_mod.app_runtime.workspace_checkpoint.arm(.{
        .debounce_ns = 500 * std.time.ns_per_ms,
        .retry_initial_ns = std.time.ns_per_s,
        .retry_max_ns = 30 * std.time.ns_per_s,
    }, initial_dirty != 0) catch return @intFromEnum(Status.invalid_config);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_set_workspace_checkpoint_failure(session: ?*AppSession, failure: u32) void {
    const app_session = session orelse return;
    app_session.setWorkspaceCheckpointFailure(failure);
}

pub export fn maru_macos_app_session_enable_workspace_checkpoint_mutations(session: ?*AppSession) void {
    const app_session = session orelse return;
    app_session.workspace_checkpoint_mutations_enabled = true;
}

pub export fn maru_macos_app_session_disable_workspace_checkpoint_mutations(session: ?*AppSession) void {
    const app_session = session orelse return;
    app_session.workspace_checkpoint_mutations_enabled = false;
}

pub export fn maru_macos_app_quit_end_all() u32 {
    return @intFromBool(session_mod.appQuitEndAll());
}

pub export fn maru_macos_workspace_checkpoint_mark_cross_window_commit() void {
    session_mod.app_runtime.workspace_checkpoint.markChanged(.topology) catch {};
}

pub export fn maru_macos_workspace_checkpoint_mark_window_inventory() void {
    session_mod.app_runtime.workspace_checkpoint.markChanged(.topology) catch {};
}

pub export fn maru_macos_workspace_checkpoint_mark_window_frame() void {
    session_mod.app_runtime.workspace_checkpoint.markChanged(.window_frame) catch {};
}

pub export fn maru_macos_workspace_checkpoint_mark_active_window() void {
    session_mod.app_runtime.workspace_checkpoint.markChanged(.active_window) catch {};
}

pub export fn maru_macos_workspace_checkpoint_tick(
    now_ns: u64,
    out_effect: ?*c.MaruWorkspaceCheckpointEffect,
) c_int {
    enforceAppLogCap();
    const out = out_effect orelse return @intFromEnum(Status.null_out);
    clearWorkspaceCheckpointEffect(out);
    if (!session_mod.app_runtime.workspace_checkpoint.armed) return @intFromEnum(Status.invalid_config);
    const effect = session_mod.app_runtime.workspace_checkpoint.tick(now_ns) catch return @intFromEnum(Status.tick_failed);
    writeWorkspaceCheckpointEffect(effect, null, out);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_workspace_checkpoint_quit_requested(
    now_ns: u64,
    out_effect: ?*c.MaruWorkspaceCheckpointEffect,
) c_int {
    const out = out_effect orelse return @intFromEnum(Status.null_out);
    clearWorkspaceCheckpointEffect(out);
    if (!session_mod.app_runtime.workspace_checkpoint.armed) return @intFromEnum(Status.invalid_config);
    const effect = session_mod.app_runtime.workspace_checkpoint.quitRequested(now_ns) catch
        return @intFromEnum(Status.tick_failed);
    writeWorkspaceCheckpointEffect(effect, null, out);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_workspace_checkpoint_capture_completed(
    generation: u64,
    succeeded: u32,
    now_ns: u64,
    out_effect: ?*c.MaruWorkspaceCheckpointEffect,
) c_int {
    const out = out_effect orelse return @intFromEnum(Status.null_out);
    clearWorkspaceCheckpointEffect(out);
    if (!session_mod.app_runtime.workspace_checkpoint.armed) return @intFromEnum(Status.invalid_config);
    const completion = session_mod.app_runtime.workspace_checkpoint.captureCompleted(generation, succeeded != 0, now_ns) catch
        return @intFromEnum(Status.tick_failed);
    writeWorkspaceCheckpointEffect(completion.effect, completion.notice, out);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_workspace_checkpoint_write_completed(
    generation: u64,
    succeeded: u32,
    now_ns: u64,
    out_effect: ?*c.MaruWorkspaceCheckpointEffect,
) c_int {
    const out = out_effect orelse return @intFromEnum(Status.null_out);
    clearWorkspaceCheckpointEffect(out);
    if (!session_mod.app_runtime.workspace_checkpoint.armed) return @intFromEnum(Status.invalid_config);
    const completion = session_mod.app_runtime.workspace_checkpoint.writeCompleted(generation, succeeded != 0, now_ns) catch
        return @intFromEnum(Status.tick_failed);
    writeWorkspaceCheckpointEffect(completion.effect, completion.notice, out);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_workspace_checkpoint_publish(
    parent_path: ?[*]const u8,
    parent_path_len: usize,
    snapshot: ?[*]const u8,
    snapshot_len: usize,
) u32 {
    const path_ptr = parent_path orelse return @intFromEnum(workspace_checkpoint_file.Result.open_parent_failed);
    const bytes_ptr = snapshot orelse return @intFromEnum(workspace_checkpoint_file.Result.invalid_snapshot);
    if (parent_path_len == 0 or parent_path_len > std.fs.max_path_bytes or
        std.mem.indexOfScalar(u8, path_ptr[0..parent_path_len], 0) != null)
        return @intFromEnum(workspace_checkpoint_file.Result.open_parent_failed);
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_buf[0..parent_path_len], path_ptr[0..parent_path_len]);
    path_buf[parent_path_len] = 0;
    const path: [:0]const u8 = path_buf[0..parent_path_len :0];
    return @intFromEnum(workspace_checkpoint_file.publish(path, bytes_ptr[0..snapshot_len]));
}

pub export fn maru_macos_workspace_checkpoint_publish_final(
    parent_path: ?[*]const u8,
    parent_path_len: usize,
    snapshot: ?[*]const u8,
    snapshot_len: usize,
    preserve_previous: u32,
) u32 {
    const path_ptr = parent_path orelse return @intFromEnum(workspace_checkpoint_file.Result.open_parent_failed);
    const bytes_ptr = snapshot orelse return @intFromEnum(workspace_checkpoint_file.Result.invalid_snapshot);
    if (parent_path_len == 0 or parent_path_len > std.fs.max_path_bytes or
        std.mem.indexOfScalar(u8, path_ptr[0..parent_path_len], 0) != null)
        return @intFromEnum(workspace_checkpoint_file.Result.open_parent_failed);
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_buf[0..parent_path_len], path_ptr[0..parent_path_len]);
    path_buf[parent_path_len] = 0;
    const path: [:0]const u8 = path_buf[0..parent_path_len :0];
    return @intFromEnum(workspace_checkpoint_file.publishFinal(
        path,
        bytes_ptr[0..snapshot_len],
        preserve_previous != 0,
    ));
}

// 현재 sidebar 토글(show-branch/show-folder)을 반영한 갱신 config 텍스트를 직렬화해 돌려준다 — Swift가
// config 경로(maru_macos_app_session_config_path)에 atomic write한다(앱 view options 토글 → config 파일
// 양방향). 원본 config를 부분 갱신하므로 주석·미파싱 키를 보존한다. 버퍼는 Zig 소유(다음 호출/destroy까지
// 유효). 직렬화 실패(OOM 등)면 *out_len=0(Swift가 write를 건너뜀) — best-effort.
pub export fn maru_macos_app_session_serialize_sidebar_config(
    session: ?*AppSession,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const len_out = out_len orelse return @intFromEnum(Status.null_out);
    const text = app_session.serializeConfig() catch {
        ptr_out.* = null;
        len_out.* = 0;
        return @intFromEnum(Status.ok);
    };
    ptr_out.* = if (text.len > 0) text.ptr else null;
    len_out.* = text.len;
    return @intFromEnum(Status.ok);
}

// 시작 시 저장된 workspace 텍스트(헤더 + N개 창 블록)에서 window_index번째 창을 parse해 이 세션에 복원 적용한다
// (R4b). **포맷 파싱은 전부 Zig가 소유한다** — Swift는 전체 텍스트와 인덱스만 넘기고 'window ' 경계를 직접 안
// 나눈다(파싱 권위가 Zig·Swift로 갈려 silent divergence 나는 걸 막음). parse 실패=invalid_config, 인덱스 범위
// 밖=invalid_config, apply 실패=create_failed, ok=적용됨. 일반 live 세션은 실패 시 기존 모델을 보존하고, v142 시작
// restore용 deferred 세션은 빈 상태를 보존한다. Swift가 primary fallback 또는 additional Window teardown을 결정한다.
pub export fn maru_macos_app_session_apply_workspace_window(
    session: ?*AppSession,
    text_ptr: ?[*]const u8,
    text_len: usize,
    window_index: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const tp = text_ptr orelse return @intFromEnum(Status.null_out);
    var parsed = maru.session.workspace.parse(app_session.allocator, tp[0..text_len]) catch return @intFromEnum(Status.invalid_config);
    defer parsed.deinit(); // apply가 cwd 슬라이스를 spawn에 다 쓴 뒤 arena 해제(안전)
    if (window_index >= parsed.workspace.windows.len) return @intFromEnum(Status.invalid_config);
    app_session.applyWorkspaceWindow(parsed.workspace.windows[window_index]) catch return @intFromEnum(Status.create_failed);
    return @intFromEnum(Status.ok);
}

// 저장된 workspace 텍스트의 창 개수를 센다(Swift가 창마다 NSWindow를 만들기 위해). 헤더·포맷뿐 아니라 manifest-wide
// runtime binding semantic validation도 겸한다. parse/semantic 실패(중복 owner 포함)면 -1을 돌려 restore 또는
// checkpoint publish를 건너뛰게 한다(0이면 빈 workspace). Swift는 window 경계나 binding을 직접 해석하지 않는다.
pub export fn maru_macos_app_session_workspace_window_count(
    session: ?*AppSession,
    text_ptr: ?[*]const u8,
    text_len: usize,
) i64 {
    const tp = text_ptr orelse return -1;
    // launch preflight는 throwaway shell 없는 deferred session을 만들지 결정해야 하므로 session 생성 **전**에도 호출한다.
    const parse_allocator = if (session) |app_session| app_session.allocator else std.heap.smp_allocator;
    var parsed = maru.session.workspace.parse(parse_allocator, tp[0..text_len]) catch return -1;
    defer parsed.deinit();
    return @intCast(parsed.workspace.windows.len);
}

// 저장된 workspace 텍스트에서 활성(key) 창의 인덱스를 준다(M3e — docs/window-surface-mobility.md §8A.8). Swift가 복원
// loop 뒤 이 인덱스의 창을 makeKeyAndOrderFront해 재시작 후 활성 창을 되살린다. active-window=1 마커가 있는 첫 창의
// 인덱스, 없으면(옛 파일·무마커) -1 → Swift 무동작(현행 동작 = 마지막 생성 창 key). parse 실패도 -1(count와 같은
// 조용한 폴백). 포맷 파싱은 Zig 단일 권위 — Swift는 창 경계를 안 나눈다. 세션 allocator로 parse(임시 arena, 즉시 해제).
pub export fn maru_macos_app_session_workspace_active_window(
    session: ?*AppSession,
    text_ptr: ?[*]const u8,
    text_len: usize,
) i64 {
    const app_session = session orelse return -1;
    const tp = text_ptr orelse return -1;
    var parsed = maru.session.workspace.parse(app_session.allocator, tp[0..text_len]) catch return -1;
    defer parsed.deinit();
    const idx = maru.session.workspace.activeWindowIndex(parsed.workspace) orelse return -1;
    return @intCast(idx);
}

// 저장된 workspace 텍스트에서 window_index 창의 픽셀(점) frame(전역 스크린 좌표)을 out_x/y/w/h로 준다(M3f —
// docs/window-surface-mobility.md §8A.8). Swift 복원 loop가 창마다 이 값을 받아 clamp 후 setFrame해 재시작 후
// 위치·크기·모니터를 되살린다. 반환: 1=frame 있음(out_* 채움), 0=없음(옛 파일·부분 필드 → Swift가 현행 기본 cascade
// 유지), -1=parse 실패·null 인자(count와 같은 조용한 폴백). 포맷 파싱은 Zig 단일 권위. 세션 allocator로 parse(임시
// arena, 즉시 해제). workspace_active_window와 동형의 read-only getter다.
pub export fn maru_macos_app_session_workspace_window_frame(
    session: ?*AppSession,
    text_ptr: ?[*]const u8,
    text_len: usize,
    window_index: usize,
    out_x: ?*i32,
    out_y: ?*i32,
    out_w: ?*i32,
    out_h: ?*i32,
) c_int {
    const app_session = session orelse return -1;
    const tp = text_ptr orelse return -1;
    const px = out_x orelse return -1;
    const py = out_y orelse return -1;
    const pw = out_w orelse return -1;
    const ph = out_h orelse return -1;
    var parsed = maru.session.workspace.parse(app_session.allocator, tp[0..text_len]) catch return -1;
    defer parsed.deinit();
    const fr = maru.session.workspace.windowFrame(parsed.workspace, window_index) orelse return 0; // 없음/부분/범위밖
    px.* = fr.x;
    py.* = fr.y;
    pw.* = fr.w;
    ph.* = fr.h;
    return 1;
}

// 전역(OS) 단축키 등록 기술자 목록. config에서 한 번 만들어 세션 동안 불변이라, Swift가 시작 시 한 번
// 읽어 Carbon RegisterEventHotKey로 등록한다. 배열은 app session 소유(destroy까지 유효). 비어 있으면
// out_ptr=null/out_count=0. 매핑 가능한 chord(가상 키코드 있음)만 담긴다.
pub export fn maru_macos_app_session_global_hotkeys(
    session: ?*AppSession,
    out_ptr: ?*?[*]const session_mod.GlobalHotkey,
    out_count: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const count_out = out_count orelse return @intFromEnum(Status.null_out);
    const hotkeys = app_session.globalHotkeys();
    ptr_out.* = if (hotkeys.len > 0) hotkeys.ptr else null;
    count_out.* = hotkeys.len;
    return @intFromEnum(Status.ok);
}

// quick terminal 표시 옵션(config에서 파싱). Swift가 매 토글마다 읽어 auto_hide·화면 모드·chrome 재생성 판정에
// 쓴다(세션의 현재 config 라이브 스냅샷 — 세션-불변 아님, 설정 변경 반영). 패널 사각형은 quick_terminal_frames가
// 따로 계산한다. POD 복사라 소유권 문제 없음.
pub export fn maru_macos_app_session_quick_terminal_config(
    session: ?*AppSession,
    out_config: ?*session_mod.QuickTerminalConfig,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const config_out = out_config orelse return @intFromEnum(Status.null_out);
    config_out.* = app_session.quickTerminalConfig();
    return @intFromEnum(Status.ok);
}

// quick 패널 보임/숨김 사각형 — Swift가 대상 화면 visibleFrame(vf_*, macOS 좌표 minX/minY/width/height)을 넘기면
// 세션의 **현재** config(위치·두께·center 폭)로 계산해 돌려준다. quick_terminal_config와 달리 세션-불변 스냅샷이
// 아니라 매 호출 라이브라 설정 GUI 변경이 다음 토글에서 바로 반영된다. 순수 계산 + POD 복사.
pub export fn maru_macos_app_session_quick_terminal_frames(
    session: ?*AppSession,
    vf_x: f64,
    vf_y: f64,
    vf_w: f64,
    vf_h: f64,
    out_frames: ?*session_mod.QuickTerminalFrames,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const frames_out = out_frames orelse return @intFromEnum(Status.null_out);
    frames_out.* = app_session.quickTerminalFrames(vf_x, vf_y, vf_w, vf_h);
    return @intFromEnum(Status.ok);
}

// 커맨드 카탈로그(메뉴바·커맨드 팝업이 그릴 액션 목록). config/액션에서 만들고, keybind 변경(GUI rebind/unbind·config
// reload·reset)마다 Zig가 rebuildCommandCatalog로 재빌드한다 — 더는 세션-불변이 아니다. 재빌드 시 command_catalog_dirty를
// 세우고 Swift가 tick마다 take_command_catalog_dirty(v85)로 drain해 buildMainMenu로 메뉴바 keyEquivalent를 다시 깐다(reset은
// 모달-확정 후 tick에서 갱신). Zig-side 커맨드 팔레트는 command_key_displays를 매 빌드 라이브로 읽어 즉시 갱신된다. 배열·
// 문자열 전부 app session 소유(destroy까지 유효). 비어 있으면 out_ptr=null/out_count=0. global_hotkeys와 같은 패턴.
pub export fn maru_macos_app_session_command_catalog(
    session: ?*AppSession,
    out_ptr: ?*?[*]const session_mod.CommandEntry,
    out_count: ?*usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr_out = out_ptr orelse return @intFromEnum(Status.null_out);
    const count_out = out_count orelse return @intFromEnum(Status.null_out);
    const items = app_session.commandCatalog();
    ptr_out.* = if (items.len > 0) items.ptr else null;
    count_out.* = items.len;
    return @intFromEnum(Status.ok);
}

// 메뉴/팝업이 고른 액션 한 개를 실행한다 — action_key(카탈로그가 준 식별자) 바이트를 받아 Zig가
// parseAction → dispatchAppAction. 모르는 키면 invalid_config(무동작). 판정·실행은 Zig가 소유하고
// Swift는 문자열만 왕복한다(native 최소 — keybind 디스패치와 같은 규율).
pub export fn maru_macos_app_session_run_action(
    session: ?*AppSession,
    bytes: ?[*]const u8,
    len: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const ptr = bytes orelse return @intFromEnum(Status.null_out);
    if (!app_session.runAction(ptr[0..len])) return @intFromEnum(Status.invalid_config);
    return @intFromEnum(Status.ok);
}

// 한 화면씩 스크롤(Shift+PageUp/Down). delta_pages>0=위(과거). 한 화면(rows-1) 계산은 app session이
// 권위 있는 rows로 한다(Swift가 stale frame summary로 계산하지 않게).
pub export fn maru_macos_app_session_scroll_page(
    session: ?*AppSession,
    delta_pages: i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.scrollPage(delta_pages);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_focus_changed(
    session: ?*AppSession,
    gained: i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.focusChanged(gained != 0);
    return @intFromEnum(Status.ok);
}

// 이전(dir<0)/다음(dir>0) 프롬프트 블록으로 뷰포트 점프(OSC 133 semantic prompt — Cmd+↑/↓).
// 분류·이동은 app session/core가 권위 있게 하고 Swift는 방향만 넘긴다(native 최소).
pub export fn maru_macos_app_session_jump_prompt(
    session: ?*AppSession,
    dir: i32,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    app_session.jumpToPrompt(if (dir < 0) -1 else 1);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_session_destroy(session: ?*AppSession) void {
    // 수명 계약: destroy는 단발성이다. null은 안전하게 무시하지만, 이미 해제된 handle은
    // 감지할 수 없으므로(메모리가 freed) 같은 non-null handle로 두 번 호출하면 use-after-free /
    // double-free다. caller(Swift host)는 destroy 직후 handle을 nil로 비워 재호출을 막아야
    // 한다. 반복 호출이 안전한 idempotent 종료가 필요하면 close()를 쓴다.
    const app_session = session orelse return;
    app_session.deinit();
    allocator.destroy(app_session);
}

pub export fn maru_macos_app_session_metal_frame(
    session: ?*AppSession,
    out_frame: ?*AppMetalFrame,
) c_int {
    // 가장 최근 tick의 RenderFrame을 Metal DTO(cells/atlas uploads/raster pixels)로 노출한다.
    // 포인터는 app session이 소유한 retained 배열을 가리키며 다음 tick까지 유효하다. caller는
    // 같은 main thread에서 tick 직후 동기적으로 읽는다.
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_frame orelse return @intFromEnum(Status.null_out);
    out.* = app_session.metalFrame();
    return @intFromEnum(Status.ok);
}

// Phase 4e-3: 웹 Term(WKWebView) surface 전이 ABI DTO. app_host_abi.h의 MaruAppHostWebSurfaceTransition과 layout 정합
// (아래 계약 테스트가 size/offset 강제). op·panel_kind·visible은 u32로 marshaling(session_mod.WebSurfaceOp/PanelKind ↔
// 값 정합). `visible`은 op 뒤 pad 자리에 들어가 struct size가 v99와 같다(op·visible이 8B, 이어서 surface_id 8B 정렬).
pub const WebSurfaceTransitionAbi = extern struct {
    op: u32,
    visible: u32, // create: 1=즉시 show, 0=hidden 생성. show/reframe=함의상 1, hide/destroy 무의미.
    surface_id: u64,
    panel_kind: u32,
    seam_edges: u32, // divider 맞닿는 가장자리 비트마스크(L=1·R=2·B=4). panel_kind 뒤 f64 정렬 pad 자리 → struct size 불변(ABI v103).
    divider_grab_left_pt: f64,
    divider_grab_right_pt: f64,
    divider_grab_bottom_pt: f64,
    frame_pt_x: f64,
    frame_pt_y: f64,
    frame_pt_w: f64,
    frame_pt_h: f64,
};

// Phase 4e-3: 이번 tick의 web surface 전이 batch 개수. Zig가 활성 워크스페이스 탭 pane 트리를 walk해 web Term 집합을
// 직전 tick 집합과 4a surfaceDiff한 batch를 **계산·보관**하고 개수를 돌려준다(command_catalog식 count+at). Swift가 tick당
// 정확히 한 번 호출해(계산·prev 전진이 여기서 일어난다) count를 받은 뒤 web_surface_transition_at으로 각 전이를 읽어
// dict[surface_id]의 WKWebView에 create/destroy/reframe/hide/show를 적용한다. session null=0.
pub export fn maru_macos_app_session_web_surface_transitions_count(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return @intCast(app_session.webSurfaceTransitionsCount());
}

// index번째 web surface 전이를 out에 marshaling한다(위 count 이후, 같은 tick·스레드). Zig가 4a 순수 계산으로 diff한
// 결과를 marshaling만 한다 — NSView 연산은 Swift(op 적용). session/out null이면 null_out, 범위 밖이면 op=none으로 ok.
pub export fn maru_macos_app_session_web_surface_transition_at(
    session: ?*AppSession,
    index: u32,
    out: ?*WebSurfaceTransitionAbi,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const o = out orelse return @intFromEnum(Status.null_out);
    const t = app_session.webSurfaceTransitionAt(index);
    o.* = .{
        .op = @intFromEnum(t.op),
        .visible = if (t.visible) 1 else 0,
        .surface_id = t.surface_id,
        .panel_kind = switch (t.panel_kind) {
            .markdown => 0,
            .browser => 1,
        },
        .seam_edges = t.seam_edges,
        .divider_grab_left_pt = t.divider_grab_bands_pt.left,
        .divider_grab_right_pt = t.divider_grab_bands_pt.right,
        .divider_grab_bottom_pt = t.divider_grab_bands_pt.bottom,
        .frame_pt_x = t.frame_pt.x,
        .frame_pt_y = t.frame_pt.y,
        .frame_pt_w = t.frame_pt.w,
        .frame_pt_h = t.frame_pt.h,
    };
    return @intFromEnum(Status.ok);
}

// Phase 7e-1a: browser(비신뢰) 웹 패널의 WKWebView nav 상태(현재 url·canGoBack·canGoForward)를 per-surface로 저장한다.
// Swift KVO(MaruWebPanelView)가 url/canGoBack/canGoForward 변화를 관측해 dirty면 tick drain에서 이걸 호출한다 —
// 관측·marshaling은 Swift(L4 어댑터), 저장·정책은 Zig(setWebNavState). can_go_back/forward는 i32 bool(0/1), url_ptr가
// null이면 빈 url. session null=null_out. 소비(주소창 렌더)는 7e-1b. provide_picked_file과 같은 Swift→Zig setter 스타일.
pub export fn maru_macos_app_session_set_web_nav_state(
    session: ?*AppSession,
    surface_id: u64,
    can_go_back: i32,
    can_go_forward: i32,
    url_ptr: ?[*]const u8,
    url_len: usize,
) c_int {
    const app_session = session orelse return @intFromEnum(Status.null_out);
    const url: []const u8 = if (url_ptr) |p| p[0..url_len] else &.{};
    app_session.setWebNavState(surface_id, can_go_back != 0, can_go_forward != 0, url);
    return @intFromEnum(Status.ok);
}

// surface_id에 저장된 nav url을 out에 복사하고 그 길이를 돌려준다(스모크가 Swift KVO → set_web_nav_state → 저장 →
// getter 왕복을 값으로 검증). 엔트리 없으면 0(빈 url 저장도 0), session/out이 null이면 -1, out_cap 부족이면 -2.
// url_at/notification_title_out과 같은 per-surface borrowed-string out-ptr 패턴(단 값 복사 — 여기선 out 버퍼로).
pub export fn maru_macos_app_session_web_nav_url_at(
    session: ?*AppSession,
    surface_id: u64,
    out_ptr: ?[*]u8,
    out_cap: usize,
) i64 {
    const app_session = session orelse return -1;
    const out = out_ptr orelse return -1;
    const state = app_session.webNavState(surface_id) orelse return 0;
    if (state.url.len > out_cap) return -2;
    @memcpy(out[0..state.url.len], state.url);
    return @intCast(state.url.len);
}

// Phase 7e-2b: 주소창 편집 신호 drain(7e-2a Zig 코어의 1회성 pending을 Swift가 tick마다 뺀다 — take_bell 패턴).
// (1) focus-pull: 밴드 클릭으로 편집 진입 시 세워지는 "키보드 포커스를 터미널 뷰로" 신호(편집 keyDown이 Zig로
//     흐르게). Swift가 1이면 focusTerminalView. surface_id는 활성 surface라 값 불요 → bool(1=있음).
pub export fn maru_macos_app_session_take_web_addr_focus_pull(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeWebAddrFocusPull() != null) 1 else 0;
}

// (2) navigate: Enter(commit)가 세운 로드 요청 — resolved url을 out에 쓰고 surface_id를 out-ptr에 실어 url 길이를
//     돌려준다(없으면 -1). Swift가 webPanels[surface_id].webView에 BrowserControl.navigate(url). null 인자/용량 부족은
//     pending을 소비하기 전에 -1(신호 유실 방지 — Swift는 늘 유효 인자).
pub export fn maru_macos_app_session_take_web_addr_navigate(
    session: ?*AppSession,
    url_out: ?[*]u8,
    url_cap: usize,
    surface_id_out: ?*u64,
) i64 {
    const app_session = session orelse return -1;
    const uo = url_out orelse return -1;
    const so = surface_id_out orelse return -1;
    const nav = app_session.takeWebAddrNavigate() orelse return -1;
    if (nav.url.len > url_cap) return -1; // 방어(resolveNavUrl이 이미 세션 버퍼 cap 제한)
    @memcpy(uo[0..nav.url.len], nav.url);
    so.* = nav.surface_id;
    return @intCast(nav.url.len);
}

// (3) focus-restore: commit/cancel 후 키보드 포커스를 그 web 패널 WKWebView로 복원할 대상 surface_id(out-ptr).
//     Swift가 1이면 makeFirstResponder(webPanels[surface_id].webView). 없으면 0. surface_id 0은 미발급이라 out-ptr로 실어 구분.
pub export fn maru_macos_app_session_take_web_addr_focus_restore(session: ?*AppSession, surface_id_out: ?*u64) c_int {
    const app_session = session orelse return 0;
    const so = surface_id_out orelse return 0;
    if (app_session.takeWebAddrFocusRestore()) |sid| {
        so.* = sid;
        return 1;
    }
    return 0;
}

// Phase 7e-3: 주소창 nav 버튼 클릭 신호 drain(tick마다). 밴드 좌측 버튼 존(back/forward/reload) 클릭이 **활성 버튼**일 때
// Zig 코어가 세운 1회성 pending을 뺀다(take_web_addr_focus_restore 패턴). 반환: action code(-1=없음, 0=back·1=forward·
// 2=reload), surface_id는 out-ptr. Swift가 code에 따라 BrowserControl.goBack/goForward/reload(webPanels[surface_id].webView).
// session/out null이면 -1(pending 미소비 — Swift는 늘 유효 인자).
pub export fn maru_macos_app_session_take_web_nav_action(session: ?*AppSession, surface_id_out: ?*u64) i32 {
    const app_session = session orelse return -1;
    const so = surface_id_out orelse return -1;
    if (app_session.takeWebNavAction()) |act| {
        so.* = act.surface_id;
        return @intCast(act.code); // 0=back·1=forward·2=reload
    }
    return -1;
}

// Phase 7e-4: 주소창 nav 버튼 키보드 단축키(browser 웹 패널 포커스 한정 Cmd+←/→/R)를 Zig 코어로 전달한다. Swift
// performKeyEquivalent가 panelKind==browser일 때만 code(0=back·1=forward·2=reload)로 마샬링해 부른다. Zig는
// setBrowserNavAction(밴드 클릭 ①b와 공유하는 활성 판정 단일 정책)으로 web_nav_action_pending을 세우고, 같은 tick의
// take_web_nav_action drain이 BrowserControl.goBack/goForward/reload를 실행한다(클릭 경로 재사용 — 키보드는 pending을
// 세우는 진입점만 다르다). 반환: 1=전달함(활성 무관 — 활성 게이트는 코어), 0=session null/알 수 없는 code(무동작).
pub export fn maru_macos_app_session_browser_nav(session: ?*AppSession, surface_id: u64, code: u32) c_int {
    const app_session = session orelse return 0;
    const btn: session_mod.NavButton = switch (code) {
        0 => .back,
        1 => .forward,
        2 => .reload,
        else => return 0, // 알 수 없는 code — 무동작
    };
    app_session.setBrowserNavAction(surface_id, btn);
    return 1;
}

// §8 슬라이스 ②: 웹 탭 페이지 찾기(⌘F). 두 방향 배관이다.
//
// (1) take: Zig가 세운 1회성 질의를 걷어 간다 — query를 out에 쓰고 surface_id·backwards를 out-ptr에 실어 **seq**를
//     돌려준다(0=없음). Swift가 webPanels[surface_id].webView에 WKWebView.find(query)를 걸고, completion에서 seq를
//     그대로 (2)로 돌려준다. null 인자/용량 부족은 pending을 **소비하기 전에** 0으로 빠진다(신호 유실 방지 —
//     take_web_addr_navigate와 같은 계약). query 길이는 out-ptr로 준다(seq는 반환값이라 자리가 없다).
pub export fn maru_macos_app_session_take_web_find_query(
    session: ?*AppSession,
    query_out: ?[*]u8,
    query_cap: usize,
    query_len_out: ?*usize,
    surface_id_out: ?*u64,
    backwards_out: ?*u32,
) u64 {
    const app_session = session orelse return 0;
    const qo = query_out orelse return 0;
    const qlo = query_len_out orelse return 0;
    const so = surface_id_out orelse return 0;
    const bo = backwards_out orelse return 0;
    // 용량 검사는 소비 전에 — 못 담을 질의를 삼켜 버리면 검색이 조용히 죽는다.
    if (app_session.peekWebFindQueryLen()) |len| {
        if (len > query_cap) return 0;
    } else return 0;
    const req = app_session.takeWebFindQuery() orelse return 0;
    @memcpy(qo[0..req.query.len], req.query);
    qlo.* = req.query.len;
    so.* = req.surface_id;
    bo.* = if (req.backwards) 1 else 0;
    return req.seq;
}

// (2) provide: WKWebView.find completion 결과를 seq와 함께 되돌린다. 늦은 회신(그 사이 새 질의·오버레이 닫힘·
//     활성 탭 변경)은 Zig가 버린다 — Swift는 판단하지 않고 그대로 넘긴다.
pub export fn maru_macos_app_session_provide_web_find_result(session: ?*AppSession, seq: u64, found: u32) void {
    const app_session = session orelse return;
    app_session.provideWebFindResult(seq, found != 0);
}

// (3) undeliverable: 그 surface의 WKWebView가 아직 없어 find를 걸지 못했다고 신고한다. Zig가 제출 마커를 지워
//     다음 tick이 재시도한다(신고하지 않으면 그 검색은 영영 나가지 않는다).
pub export fn maru_macos_app_session_web_find_undeliverable(session: ?*AppSession, seq: u64) void {
    const app_session = session orelse return;
    app_session.reportWebFindUndeliverable(seq);
}

// Phase 7e-4 후속: 활성 pane의 활성 term이 browser web이면 그 surface_id, 아니면 0(browser 아님/null session). Swift
// performKeyEquivalent가 browser nav 단축키(⌘←/→/R)를 이 값 == 이 패널 surface_id일 때만 처리해, WKWebView 키보드
// 포커스 유무와 무관하게 "지금 활성 탭이 browser면" 동작하게 한다(탭만 열어 봐도 되게). split의 비활성 pane 브라우저는
// 0으로 걸러진다. 순수 read getter — 구조체 offset 불변.
pub export fn maru_macos_app_session_active_web_surface_id(session: ?*AppSession) u64 {
    const app_session = session orelse return 0;
    return app_session.activeWebSurfaceId();
}

// Phase 4g-0: 활성 pane 활성 term이 web(browser·markdown 무관)이면 surface_id, 아니면 0. focus-sync 불변식(§4.1)
// Direction 1(Zig 활성 pane → firstResponder)이 "활성이 web이면 그 webview 포커스, 아니면 터미널 뷰"를 정하는 데 쓴다
// (activeWebSurfaceId는 browser 전용이라 markdown 활성 시 0을 줘 터미널로 오포커스). 순수 read getter — 구조체 offset 불변.
pub export fn maru_macos_app_session_active_web_surface_id_any_kind(session: ?*AppSession) u64 {
    const app_session = session orelse return 0;
    return app_session.activeWebSurfaceIdAnyKind();
}

// Phase 4g-1 후속(14차 리뷰 [0][3]): 입력이 터미널 뷰→Zig 경로로 가야 하는가(모달[notice 제외] 또는 주소창 편집·
// rename·사이드바 검색 활성). focus-sync 불변식(reconcileWebFocus)의 **override 단일 출처** — 1이면 웹뷰가 아니라
// 터미널 뷰가 firstResponder여야 한다. 옛 addr_edit_surface getter를 대체(그건 rename·사이드바 검색을 빠뜨려 web pane
// 활성 중 그 편집이 웹뷰로 새고 notice까지 세는 버그였다). 순수 read — 구조체 offset 불변.
pub export fn maru_macos_app_session_terminal_owns_input(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.terminalOwnsInput()) 1 else 0;
}

// Phase 7f-0: 새 창/팝업 adopt — Swift `WKUIDelegate.createWebViewWith`가 WebKit config로 만든 WKWebView를 붙일
// browser web Term을 활성 pane에 새 탭으로 만들고 그 surface_id를 반환한다(Swift-first 동기 생성 — 소유·시점 역전).
// Swift는 이 id로 pre-created webview를 webPanels에 키잉하고, drain은 존재 시 중복 생성을 스킵한다(7f-1). 반환:
// 새 surface_id(>=1), 또는 0(null session·생성 실패 sentinel). 신규 export만 — 구조체 offset 불변.
pub export fn maru_macos_app_session_create_adopted_web_term(session: ?*AppSession) u64 {
    const app_session = session orelse return 0;
    return app_session.createAdoptedWebTermInActivePane() catch 0;
}

/// 4e-4(web-panel §10): 이 세션 트리에 그 web surface_id가 존재하면 1, 아니면 0. Swift `drainWebSurfaceTransition`이 원본 창
/// web surface destroy 전이 시 **다른 창** 세션들에 이걸 물어 "이동(다른 창에 live)↔닫힘(어디에도 없음)"을 구분한다 —
/// live면 WKWebView를 파괴하지 않고 대상 창 create가 재부모화하도록 살려두고 `browser.closed`를 억제한다. additive export(버전 불변).
pub export fn maru_macos_app_session_has_web_surface(session: ?*AppSession, surface_id: u64) u32 {
    const app_session = session orelse return 0;
    return if (app_session.hasWebSurface(surface_id)) 1 else 0;
}

// ── Phase 5c-2: maru-app:// asset resolve (경로 샌드박스 5c-1 + realpath symlink 탈출 방어, platform I/O) ──────
//
// 신뢰 패널의 WKURLSchemeHandler(5c-2b Swift)가 `maru-app://<host>/<path>` 요청을 받으면 이 함수로 **번들 asset root
// 아래 안전한 절대 경로**를 얻어 그 파일을 CSP와 함께 서빙한다. 5c-1 `validateAppPath`(문자열: `..`·whitelist)로 못 잡는
// **symlink 탈출**을 realpath로 막는다 — candidate와 root를 각각 realpath해 canonical candidate가 canonical root **아래**인지
// 확인(심링크가 root 밖을 가리키면 realpath가 밖을 반환 → 거부). I/O라 L2가 아니라 여기(platform).
pub const AppAssetError = error{
    /// 5c-1 문자열 검증 실패(traversal `..`·whitelist 밖·너무 긺) — 요청 자체가 부적격.
    Reject,
    /// candidate가 존재하지 않거나 일반 파일이 아님(디렉터리 등) → 404.
    NotFound,
    /// realpath 결과가 asset root 밖 — symlink 탈출 등. 거부(정보 노출 방지).
    OutsideRoot,
};

fn pathIsUnder(p: []const u8, root: []const u8) bool {
    // p == root/... : root로 시작하고 그 다음 문자가 경로 구분자('/')여야 root의 **하위**다(root 자신·형제 접두 배제).
    if (p.len <= root.len) return false;
    if (!std.mem.startsWith(u8, p, root)) return false;
    return p[root.len] == '/';
}

/// `maru-app://` 요청 경로를 asset root 아래 안전한 **절대 경로**로 resolve한다(5c-1 문자열 + realpath symlink 방어).
/// 성공 시 canonical 절대 경로를 `out`에 쓰고 슬라이스를 돌려준다(Swift가 그 파일을 읽어 CSP와 서빙). `root_abs`는 절대
/// 경로(Swift가 Bundle asset root 전달). 빈 경로(`/`)는 `index.html`로 매핑한다. `io`는 platform I/O(Swift C-ABI 래퍼는
/// 5c-2b에서 host io를 전달; 여기 테스트는 std.testing.io).
pub fn resolveAppAsset(io: std.Io, role: maru.session.app_scheme.AppAssetRole, root_abs: []const u8, request_path: []const u8, out: []u8) AppAssetError![]const u8 {
    var clean_buf: [std.fs.max_path_bytes]u8 = undefined;
    const clean = maru.session.app_scheme.validateAppPath(request_path, &clean_buf) catch |e| switch (e) {
        error.Empty => "index.html", // 루트 요청(`/`·`""`) → index 문서
        else => return AppAssetError.Reject, // Traversal·InvalidChar·TooLong
    };
    if (!role.pathAllowed(clean)) return AppAssetError.Reject;
    var join_buf: [std.fs.max_path_bytes]u8 = undefined;
    const candidate = std.fmt.bufPrint(&join_buf, "{s}/{s}", .{ root_abs, clean }) catch return AppAssetError.Reject;
    const dir = std.Io.Dir.cwd();
    var cand_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cn = dir.realPathFile(io, candidate, &cand_buf) catch return AppAssetError.NotFound; // symlink 따라감·부재면 실패
    const cand_real = cand_buf[0..cn];
    // root를 요청마다 canonicalize한다(리뷰11 [7]): 상수 root라 잉여 realpath지만, 이 함수는 **stateless**(호출 간
    // 상태 없음)라는 정책 계약을 지키려는 의도적 선택이다. 캐싱하려면 Zig에 상태를 두거나 canonical-root 전용 export를
    // 추가해 어댑터가 1회 canonicalize+캐시해야 하는데, 현재 asset 수(placeholder 3개, Phase 7도 modest)에선 realpath
    // 비용이 무시가능이라 그 API 복잡도/보안 계약 약화 리스크를 지지 않는다. Phase 7이 서브리소스 다량 서빙으로 실측
    // 지연이 생기면 그때 canonical-root 캐시 export로 분리한다.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rn = dir.realPathFile(io, root_abs, &root_buf) catch return AppAssetError.Reject;
    const root_real = root_buf[0..rn];
    if (!pathIsUnder(cand_real, root_real)) return AppAssetError.OutsideRoot; // symlink 탈출 방어(canonical 비교)
    const st = dir.statFile(io, cand_real, .{}) catch return AppAssetError.NotFound;
    if (st.kind != .file) return AppAssetError.NotFound; // 디렉터리·특수 파일은 서빙 안 함
    // render role은 요청 manifest뿐 아니라 canonical 상대 경로도 정확히 같아야 한다. 그러면 허용 이름을 worker로
    // 향하게 한 in-root symlink/case alias가 `script-src 'self'`로 worker bytes를 읽는 우회를 만들지 못한다.
    if (role == .render) {
        var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "{s}/{s}", .{ root_real, clean }) catch return AppAssetError.Reject;
        if (!std.mem.eql(u8, cand_real, expected)) return AppAssetError.Reject;
    }
    if (cand_real.len > out.len) return AppAssetError.Reject;
    @memcpy(out[0..cand_real.len], cand_real);
    return out[0..cand_real.len];
}

// maru-app:// asset resolve C-ABI(5c-2b): Swift WKURLSchemeHandler(5c-2c)가 요청 경로를 안전한 절대 경로로 resolve한다.
// 정책(경로 샌드박스·realpath 탈출 방어)은 여기 Zig가 소유하고, Swift는 반환 경로의 바이트를 읽어 CSP와 서빙만 한다
// (docs/plans/web-panel.md §10 "정책은 테스트 가능한 Zig, Swift는 WebKit 어댑터"). 반환: **>=0** = `out`에 쓴 canonical 절대
// 경로 길이. **음수** = 에러 코드(-1 Reject=문자열 거부, -2 NotFound=부재/디렉터리, -3 OutsideRoot=symlink 탈출,
// -4 null 포인터). AppSession I/O singleton과 분리된 이 인스턴스는 export mutex 아래에서만 사용한다.
var app_asset_io: std.Io.Threaded = .init_single_threaded;
var app_asset_io_mutex: std.Io.Mutex = .init;

pub export fn maru_macos_app_resolve_app_asset(
    role_raw: u32,
    root_ptr: ?[*]const u8,
    root_len: usize,
    req_ptr: ?[*]const u8,
    req_len: usize,
    out_ptr: ?[*]u8,
    out_cap: usize,
) i64 {
    const role: maru.session.app_scheme.AppAssetRole = switch (role_raw) {
        0 => .app,
        1 => .render,
        else => return -1,
    };
    const rp = root_ptr orelse return -4;
    const qp = req_ptr orelse return -4;
    const op = out_ptr orelse return -4;
    const io = app_asset_io.io();
    app_asset_io_mutex.lockUncancelable(io);
    defer app_asset_io_mutex.unlock(io);
    const resolved = resolveAppAsset(io, role, rp[0..root_len], qp[0..req_len], op[0..out_cap]) catch |e| return switch (e) {
        error.Reject => -1,
        error.NotFound => -2,
        error.OutsideRoot => -3,
    };
    return @intCast(resolved.len);
}

/// Scheme asset bytes를 root-relative no-follow open과 같은 fd의 fstat/read로 반환한다. 제품 web bundle은
/// flat allowlist라 중간 path component를 허용하지 않아 ancestor symlink 교체도 없다. 4 MiB보다 큰 asset은
/// build 오류/404로 접고, render role이 worker inode의 hardlink를 읽는 것도 fd identity로 거부한다.
pub export fn maru_macos_app_read_app_asset(
    role_raw: u32,
    root_ptr: ?[*]const u8,
    root_len: usize,
    req_ptr: ?[*]const u8,
    req_len: usize,
    out_ptr: ?[*]u8,
    out_cap: usize,
) i64 {
    const role: maru.session.app_scheme.AppAssetRole = switch (role_raw) {
        0 => .app,
        1 => .render,
        else => return -1,
    };
    const rp = root_ptr orelse return -4;
    const qp = req_ptr orelse return -4;
    const op = out_ptr orelse return -4;
    var clean_buf: [std.fs.max_path_bytes]u8 = undefined;
    const clean = maru.session.app_scheme.validateAppPath(qp[0..req_len], &clean_buf) catch |err| switch (err) {
        error.Empty => "index.html",
        else => return -1,
    };
    if (!role.pathAllowed(clean) or std.mem.indexOfScalar(u8, clean, '/') != null) return -1;

    const io = app_asset_io.io();
    app_asset_io_mutex.lockUncancelable(io);
    defer app_asset_io_mutex.unlock(io);
    const root = std.Io.Dir.openDirAbsolute(io, rp[0..root_len], .{ .follow_symlinks = false }) catch return -2;
    defer root.close(io);
    const file = root.openFile(io, clean, .{ .follow_symlinks = false }) catch return -2;
    defer file.close(io);
    const stat = file.stat(io) catch return -2;
    if (stat.kind != .file or stat.size > out_cap) return -2;

    const len: usize = @intCast(stat.size);
    const read = file.readPositionalAll(io, op[0..len], 0) catch return -2;
    if (read != len) return -2;
    return @intCast(len);
}

// maru-app:// 응답 CSP 헤더 문자열(5c-2c). **단일 출처 = app_scheme.AppAssetRole.csp** — Swift 핸들러가 문자열을
// 중복해 들지 않고 1회 읽어 캐시한다(doc↔code drift 방지, docs/web-panel.md §7.1 ③). out에 복사하고 길이를 돌려준다.
// cap 부족이면 -1, out null이면 -2.
pub export fn maru_macos_app_csp_header(role_raw: u32, out_ptr: ?[*]u8, out_cap: usize) i64 {
    const op = out_ptr orelse return -2;
    const role: maru.session.app_scheme.AppAssetRole = switch (role_raw) {
        0 => .app,
        1 => .render,
        else => return -3,
    };
    const csp = role.csp();
    if (csp.len > out_cap) return -1;
    @memcpy(op[0..csp.len], csp);
    return @intCast(csp.len);
}

/// 요청 URL의 exact origin을 asset role로 바꾼다. 반환 0=app, 1=render, -1=거부/NULL.
pub export fn maru_macos_app_asset_role_for_origin(
    scheme_ptr: ?[*]const u8,
    scheme_len: usize,
    host_ptr: ?[*]const u8,
    host_len: usize,
    has_explicit_port: c_int,
) i32 {
    const sp = scheme_ptr orelse return -1;
    const hp = host_ptr orelse return -1;
    const role = maru.session.app_scheme.appAssetRoleForOrigin(sp[0..scheme_len], hp[0..host_len], has_explicit_port != 0) orelse return -1;
    return @intCast(@intFromEnum(role));
}

/// Swift의 WKSecurityOrigin/URL 구성요소를 L2 exact-origin 정책으로 판정한다. role은
/// app_scheme.AppOriginRole(shell=0, renderer=1, asset=2), has_explicit_port는 0/1이다.
pub export fn maru_macos_app_origin_allowed(
    scheme_ptr: ?[*]const u8,
    scheme_len: usize,
    host_ptr: ?[*]const u8,
    host_len: usize,
    has_explicit_port: c_int,
    role_raw: u32,
) c_int {
    const sp = scheme_ptr orelse return 0;
    const hp = host_ptr orelse return 0;
    const role: maru.session.app_scheme.AppOriginRole = switch (role_raw) {
        0 => .shell,
        1 => .renderer,
        2 => .asset,
        else => return 0,
    };
    return if (maru.session.app_scheme.appOriginAllowed(
        sp[0..scheme_len],
        hp[0..host_len],
        has_explicit_port != 0,
        role,
    )) 1 else 0;
}

// Phase 7f-2: 새 창/팝업(WKUIDelegate.createWebViewWith) 대상 URL 정책 게이트. Swift가 navigationAction.request.url을
// 넘기면 app_scheme.popupTargetAllowed(허용 = about·http·https·빈만, javascript·file·data·blob·maru-app 등 거부)로
// 판정한다 — 정책 단일 출처=Zig, 어댑터=Swift(url 추출·차단). 반환: 1=허용, 0=거부, -1=url_ptr null. 세션리스 순수
// 정책(csp_header 동형).
pub export fn maru_macos_app_popup_target_allowed(url_ptr: ?[*]const u8, url_len: usize) c_int {
    const up = url_ptr orelse return -1;
    return if (maru.session.app_scheme.popupTargetAllowed(up[0..url_len])) 1 else 0;
}

// Track C 5b: 신뢰 웹 브리지(window.maru.*) 요청 디스패치(5b-1 코어). Swift가 신뢰(markdown) 패널의 isolated
// WKContentWorld 메시지 핸들러 진입에서 **frameInfo.isMainFrame + securityOrigin(maru-app://app) exact-pin을 먼저
// 검증**(신뢰 게이트)한 뒤, 통과한 요청 JSON 한 줄을 넘기면 control_bridge.dispatchBridge로 응답 JSON을 만들어 out에
// 쓴다. 정책=Zig(디스패치·wire), 어댑터=Swift(world·핸들러·origin 검증). server_version은 소켓 hello와 같은 단일
// 출처(control_hello_version). 반환: >=0 = out에 쓴 응답 길이. -1=out 용량 부족, -2=NULL 포인터, -3=OOM.
pub export fn maru_macos_app_bridge_dispatch(
    req_ptr: ?[*]const u8,
    req_len: usize,
    out_ptr: ?[*]u8,
    out_cap: usize,
) i64 {
    const rp = req_ptr orelse return -2;
    const op = out_ptr orelse return -2;
    const reply = maru.session.control_bridge.dispatchBridge(allocator, rp[0..req_len], control_hello_version) catch return -3;
    defer allocator.free(reply);
    if (reply.len > out_cap) return -1;
    @memcpy(op[0..reply.len], reply);
    return @intCast(reply.len);
}

const FileBridgeContext = struct {
    session: *AppSession,
    surface_id: u64,

    fn beginDocument(raw: *anyopaque, document_id: u64) anyerror!u64 {
        const self: *FileBridgeContext = @ptrCast(@alignCast(raw));
        return self.session.beginFilePanelDocument(self.surface_id, document_id);
    }

    fn read(raw: *anyopaque, gpa: std.mem.Allocator, editor_epoch: u64) anyerror![]u8 {
        const self: *FileBridgeContext = @ptrCast(@alignCast(raw));
        return self.session.readFilePanel(gpa, self.surface_id, editor_epoch);
    }

    /// E1 `diff.open`. null이면 아직 읽는 중이다(브리지가 pending으로 답한다).
    fn diffOpen(raw: *anyopaque, gpa: std.mem.Allocator) anyerror!?maru.session.control_bridge.DiffSides {
        const self: *FileBridgeContext = @ptrCast(@alignCast(raw));
        return self.session.diffSidesForSurface(gpa, self.surface_id);
    }

    fn readAsset(raw: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *FileBridgeContext = @ptrCast(@alignCast(raw));
        return self.session.readFilePanelAsset(gpa, self.surface_id, path);
    }

    fn write(raw: *anyopaque, editor_epoch: u64, content: []const u8) anyerror!void {
        const self: *FileBridgeContext = @ptrCast(@alignCast(raw));
        self.session.writeFilePanel(self.surface_id, editor_epoch, content) catch |err| {
            // 저장 실패를 chrome native notice로 알린다(웹뷰 sticky 텍스트 대신). 에러는 그대로 web에 돌려준다.
            self.session.noticeFilePanelWriteFailure(self.surface_id, err);
            return err;
        };
    }

    fn setDirty(raw: *anyopaque, report: maru.session.control_bridge.DirtyReport) anyerror!void {
        const self: *FileBridgeContext = @ptrCast(@alignCast(raw));
        return self.session.reportFilePanelDirty(self.surface_id, report);
    }

    fn resolveExternalChange(raw: *anyopaque, editor_epoch: u64, success: bool) anyerror!void {
        const self: *FileBridgeContext = @ptrCast(@alignCast(raw));
        return self.session.completeFileConflictReloadForDocument(self.surface_id, editor_epoch, success);
    }

    fn openLink(raw: *anyopaque, editor_epoch: u64, href: []const u8, force_system: bool) anyerror!void {
        const self: *FileBridgeContext = @ptrCast(@alignCast(raw));
        return self.session.openFilePanelDocumentLink(self.surface_id, editor_epoch, href, force_system);
    }

    fn openMenu(raw: *anyopaque, request: maru.session.control_bridge.MenuRequest) anyerror!void {
        const self: *FileBridgeContext = @ptrCast(@alignCast(raw));
        return self.session.openFileContentMenu(self.surface_id, request);
    }

    fn renderMermaid(
        raw: *anyopaque,
        request: maru.session.control_bridge.MermaidRenderRequest,
    ) anyerror!u64 {
        const self: *FileBridgeContext = @ptrCast(@alignCast(raw));
        if (!self.session.filePanelMermaidDocumentActive(self.surface_id, request.renderer.editor_epoch))
            return error.StaleDocument;
        return session_mod.mermaidCoordinator().admitHashed(.{
            .window_id = self.surface_id,
            .renderer = request.renderer,
            .fence_id = request.fence_id,
            .source = request.source,
            // 이 세션의 터미널 테마에서 파생한 팔레트를 job에 실어 helper가 mermaid 색을 맞춘다(per-render).
            .palette = maru.session.mermaid_theme.fromTheme(self.session.appearance.theme),
        }, request.source_hash);
    }

    fn revokeMermaid(
        raw: *anyopaque,
        renderer: mermaid_protocol.RendererCapability,
    ) anyerror!void {
        const self: *FileBridgeContext = @ptrCast(@alignCast(raw));
        session_mod.mermaidCoordinator().revokeRenderer(self.surface_id, renderer);
    }

    fn rendererReady(raw: *anyopaque, editor_epoch: u64) anyerror!void {
        const self: *FileBridgeContext = @ptrCast(@alignCast(raw));
        if (!self.session.filePanelMermaidDocumentActive(self.surface_id, editor_epoch))
            return error.StaleDocument;
    }
};

// FP4: surface-pinned file provider를 넣는 session-scoped bridge. query/fill 모두 같은 정책을 다시 계산하므로 파일이
// 그 사이 바뀌어 fill cap을 넘으면 필요한 새 길이를 양수로 돌려 Swift가 한 번 더 query/fill할 수 있다.
pub export fn maru_macos_app_session_bridge_dispatch(
    session: ?*AppSession,
    surface_id: u64,
    req_ptr: ?[*]const u8,
    req_len: usize,
    out_ptr: ?[*]u8,
    out_cap: usize,
) i64 {
    const app_session = session orelse return -2;
    const rp = req_ptr orelse return -2;
    if (out_ptr == null and out_cap != 0) return -2;
    var context: FileBridgeContext = .{ .session = app_session, .surface_id = surface_id };
    const access: maru.session.control_bridge.FileAccess = .{
        .context = &context,
        .begin_document_fn = FileBridgeContext.beginDocument,
        .read_fn = FileBridgeContext.read,
        .diff_open_fn = FileBridgeContext.diffOpen,
        .read_asset_fn = FileBridgeContext.readAsset,
        .write_fn = FileBridgeContext.write,
        .set_dirty_fn = FileBridgeContext.setDirty,
        .resolve_external_change_fn = FileBridgeContext.resolveExternalChange,
        .open_link_fn = FileBridgeContext.openLink,
        .render_mermaid_fn = FileBridgeContext.renderMermaid,
        .revoke_mermaid_fn = FileBridgeContext.revokeMermaid,
        .renderer_ready_fn = FileBridgeContext.rendererReady,
        .open_menu_fn = FileBridgeContext.openMenu,
    };
    const reply = maru.session.control_bridge.dispatchBridgeWithFileAccess(
        allocator,
        rp[0..req_len],
        control_hello_version,
        access,
    ) catch return -3;
    defer allocator.free(reply);
    const op = out_ptr orelse return @intCast(reply.len);
    if (reply.len > out_cap) return @intCast(reply.len);
    @memcpy(op[0..reply.len], reply);
    return @intCast(reply.len);
}

/// WebKit process termination is a document-lifetime event, not a renderer-worker event. Swift calls this only
/// after confirming that the callback panel is still the exact surface owner; Zig owns the conservative dirty latch.
pub export fn maru_macos_app_session_file_panel_document_terminated(session: ?*AppSession, surface_id: u64) u32 {
    const app_session = session orelse return 0;
    return app_session.filePanelDocumentTerminated(surface_id);
}

const mermaid_protocol = maru.session.mermaid_protocol;
const mermaid_coordinator = maru.session.mermaid_coordinator;

pub const MermaidRendererCapabilityAbi = extern struct {
    editor_epoch: u64,
    document_revision: u64,
    projection_generation: u64,
    widget_id: u64,
    widget_generation: u64,
    renderer_instance: u64,
};

pub const MermaidJobCapabilityAbi = extern struct {
    helper_instance: u64,
    job_id: u64,
    renderer: MermaidRendererCapabilityAbi,
    fence_id: u64,
    source_hash: [32]u8,
};

pub const MermaidDecodedFrameAbi = extern struct {
    tag: u32,
    status: u32,
    helper_instance: u64,
    nonce: u64,
    capability: MermaidJobCapabilityAbi,
    body_ptr: ?[*]const u8,
    body_len: usize,
    palette: mermaid_protocol.Palette, // v3 request 전용(다른 tag는 zeroed) — helper가 mermaid themeVariables 구성
};

pub const MermaidCoordinatorActionAbi = extern struct {
    kind: u32,
    spawn_helper: u32,
    deadline_ms: u64,
    hello_nonce: u64,
    capability: MermaidJobCapabilityAbi,
    request_frame_ptr: ?[*]const u8,
    request_frame_len: usize,
};

pub const MermaidCoordinatorSnapshotAbi = extern struct {
    pending_jobs: usize,
    pending_source_bytes: usize,
    accepted_results: usize,
    accepted_svg_bytes: usize,
    terminal_results: usize,
    helper_instance: u64,
    helper_starts: u64,
    deadline_expirations: u64,
    admission_copies: u64,
    in_flight: u32,
    disabled: u32,
    action_handoff_pending: u32,
    termination_in_progress: u32,
};

pub const MermaidAcceptedResultAbi = extern struct {
    window_id: u64,
    capability: MermaidJobCapabilityAbi,
    svg_len: usize,
};

pub const MermaidTerminalResultAbi = extern struct {
    window_id: u64,
    job_id: u64,
    renderer: MermaidRendererCapabilityAbi,
    reason: u32,
};

const MermaidDecoder = mermaid_protocol.StreamingDecoder;

pub export fn maru_mermaid_protocol_decoder_create() ?*MermaidDecoder {
    const decoder = allocator.create(MermaidDecoder) catch return null;
    decoder.* = .{};
    return decoder;
}

pub export fn maru_mermaid_protocol_decoder_destroy(decoder: ?*MermaidDecoder) void {
    allocator.destroy(decoder orelse return);
}

pub export fn maru_mermaid_protocol_decoder_feed(decoder: ?*MermaidDecoder, bytes: ?[*]const u8, len: usize) i32 {
    const value = decoder orelse return -1;
    if (len > 0 and bytes == null) return -1;
    value.feed(if (bytes) |ptr| ptr[0..len] else &.{}) catch return -2;
    return 0;
}

pub export fn maru_mermaid_protocol_decoder_next(decoder: ?*MermaidDecoder, out_frame: ?*MermaidDecodedFrameAbi) i32 {
    const value = decoder orelse return -1;
    const out = out_frame orelse return -1;
    const message = value.next() catch return -2;
    const frame = message orelse return 0;
    out.* = decodedFrameAbi(frame);
    return 1;
}

pub export fn maru_mermaid_protocol_decoder_finish(decoder: ?*MermaidDecoder) i32 {
    const value = decoder orelse return -1;
    value.finish() catch return -2;
    return 0;
}

pub export fn maru_mermaid_protocol_matches_hello_ack(
    frame: ?*const MermaidDecodedFrameAbi,
    helper_instance: u64,
    nonce: u64,
) u32 {
    const value = frame orelse return 0;
    return @intFromBool(value.tag == @intFromEnum(mermaid_protocol.Tag.hello_ack) and
        value.helper_instance == helper_instance and value.nonce == nonce);
}

pub export fn maru_mermaid_protocol_encode_hello(
    ack: u32,
    helper_instance: u64,
    nonce: u64,
    out: ?[*]u8,
    out_cap: usize,
) i64 {
    const dest = out orelse return -1;
    const hello: mermaid_protocol.Hello = .{ .helper_instance = helper_instance, .nonce = nonce };
    const message: mermaid_protocol.Message = if (ack == 0) .{ .hello = hello } else if (ack == 1) .{ .hello_ack = hello } else return -1;
    const len = mermaid_protocol.encode(message, dest[0..out_cap]) catch |err| return encodeErrorCode(err);
    return @intCast(len);
}

pub export fn maru_mermaid_protocol_encode_request(
    capability: ?*const MermaidJobCapabilityAbi,
    source: ?[*]const u8,
    source_len: usize,
    palette: ?*const mermaid_protocol.Palette,
    out: ?[*]u8,
    out_cap: usize,
) i64 {
    const cap = capability orelse return -1;
    const pal = palette orelse return -1;
    if (source_len > 0 and source == null) return -1;
    const dest = out orelse return -1;
    const len = mermaid_protocol.encode(.{ .request = .{
        .capability = capabilityFromAbi(cap.*),
        .source = if (source) |ptr| ptr[0..source_len] else &.{},
        .palette = pal.*,
    } }, dest[0..out_cap]) catch |err| return encodeErrorCode(err);
    return @intCast(len);
}

pub export fn maru_mermaid_protocol_encode_result(
    capability: ?*const MermaidJobCapabilityAbi,
    status: u32,
    body: ?[*]const u8,
    body_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) i64 {
    const cap = capability orelse return -1;
    if (body_len > 0 and body == null) return -1;
    const dest = out orelse return -1;
    const result_status = std.enums.fromInt(mermaid_protocol.ResultStatus, status) orelse return -1;
    const len = mermaid_protocol.encode(.{ .result = .{
        .capability = capabilityFromAbi(cap.*),
        .status = result_status,
        .body = if (body) |ptr| ptr[0..body_len] else &.{},
    } }, dest[0..out_cap]) catch |err| return encodeErrorCode(err);
    return @intCast(len);
}

pub export fn maru_macos_mermaid_admit(
    window_id: u64,
    renderer: ?*const MermaidRendererCapabilityAbi,
    fence_id: u64,
    source: ?[*]const u8,
    source_len: usize,
) i32 {
    const renderer_value = renderer orelse return -1;
    if (source_len > 0 and source == null) return -1;
    _ = session_mod.mermaidCoordinator().admit(.{
        .window_id = window_id,
        .renderer = rendererFromAbi(renderer_value.*),
        .fence_id = fence_id,
        .source = if (source) |ptr| ptr[0..source_len] else &.{},
    }) catch return -2;
    return 0;
}

pub export fn maru_macos_mermaid_drain_action(now_ms: u64, out_action: ?*MermaidCoordinatorActionAbi) i32 {
    const out = out_action orelse return -1;
    const action = session_mod.mermaidCoordinator().drainAction(now_ms) orelse return 0;
    out.* = std.mem.zeroes(MermaidCoordinatorActionAbi);
    switch (action) {
        .terminate_helper => |helper_instance| {
            out.kind = 1;
            out.capability.helper_instance = helper_instance;
        },
        .start_job => |start| {
            out.kind = 2;
            out.spawn_helper = @intFromBool(start.spawn_helper);
            out.deadline_ms = start.deadline_ms;
            out.hello_nonce = start.hello_nonce;
            out.capability = capabilityToAbi(start.capability);
            out.request_frame_ptr = start.request_frame.ptr;
            out.request_frame_len = start.request_frame.len;
        },
    }
    return 1;
}

pub export fn maru_macos_mermaid_complete_action_handoff(helper_instance: u64, job_id: u64) u32 {
    return @intFromBool(session_mod.mermaidCoordinator().completeActionHandoff(helper_instance, job_id));
}

pub export fn maru_macos_mermaid_complete_decoded(frame: ?*const MermaidDecodedFrameAbi, arrival_ms: u64) i32 {
    const decoded = frame orelse return -1;
    if (decoded.tag != @intFromEnum(mermaid_protocol.Tag.result)) return -1;
    if (decoded.body_len > 0 and decoded.body_ptr == null) return -1;
    const status = std.enums.fromInt(mermaid_protocol.ResultStatus, decoded.status) orelse return -1;
    return switch (session_mod.mermaidCoordinator().completeResult(
        capabilityFromAbi(decoded.capability),
        status,
        if (decoded.body_ptr) |ptr| ptr[0..decoded.body_len] else &.{},
        arrival_ms,
    )) {
        .accepted => 1,
        .render_error => 2,
        .stale => 0,
        .invalid_body => -2,
        .accepted_capacity_exceeded => -3,
        .deadline_expired => -4,
    };
}

pub export fn maru_macos_mermaid_report_failure(helper_instance: u64, now_ms: u64, integrity: u32) u32 {
    const handled = if (integrity == 0)
        session_mod.mermaidCoordinator().transientFailure(helper_instance, now_ms)
    else if (integrity == 1)
        session_mod.mermaidCoordinator().integrityFailure(helper_instance)
    else
        false;
    return @intFromBool(handled);
}

pub export fn maru_macos_mermaid_expire_deadline(now_ms: u64) u32 {
    return @intFromBool(session_mod.mermaidCoordinator().expireDeadline(now_ms));
}

pub export fn maru_macos_mermaid_complete_termination(helper_instance: u64) u32 {
    return @intFromBool(session_mod.mermaidCoordinator().completeTermination(helper_instance));
}

pub export fn maru_macos_mermaid_shutdown() void {
    session_mod.mermaidCoordinator().shutdown();
}

pub export fn maru_macos_mermaid_snapshot(out_snapshot: ?*MermaidCoordinatorSnapshotAbi) void {
    const out = out_snapshot orelse return;
    const snap = session_mod.mermaidCoordinator().snapshot();
    out.* = .{
        .pending_jobs = snap.pending_jobs,
        .pending_source_bytes = snap.pending_source_bytes,
        .accepted_results = snap.accepted_results,
        .accepted_svg_bytes = snap.accepted_svg_bytes,
        .terminal_results = snap.terminal_results,
        .helper_instance = snap.helper_instance,
        .helper_starts = snap.helper_starts,
        .deadline_expirations = snap.deadline_expirations,
        .admission_copies = snap.admission_copies,
        .in_flight = @intFromBool(snap.in_flight),
        .disabled = @intFromBool(snap.disabled),
        .action_handoff_pending = @intFromBool(snap.action_handoff_pending),
        .termination_in_progress = @intFromBool(snap.termination_in_progress),
    };
}

pub export fn maru_macos_mermaid_has_work() u32 {
    return @intFromBool(session_mod.mermaidCoordinator().hasWork());
}

pub export fn maru_macos_mermaid_revoke_renderer(window_id: u64, renderer: ?*const MermaidRendererCapabilityAbi) void {
    if (window_id == 0) return;
    const value = renderer orelse return;
    session_mod.mermaidCoordinator().revokeRenderer(window_id, rendererFromAbi(value.*));
}

pub export fn maru_macos_mermaid_revoke_job(window_id: u64, job_id: u64, renderer: ?*const MermaidRendererCapabilityAbi) void {
    if (window_id == 0 or job_id == 0) return;
    const value = renderer orelse return;
    session_mod.mermaidCoordinator().revokeJob(window_id, job_id, rendererFromAbi(value.*));
}

pub export fn maru_macos_mermaid_take_accepted(
    out_result: ?*MermaidAcceptedResultAbi,
    out_svg: ?[*]u8,
    out_cap: usize,
) i32 {
    const result = out_result orelse return -1;
    if (out_cap > 0 and out_svg == null) return -1;
    const accepted = session_mod.mermaidCoordinator().takeAccepted(
        if (out_svg) |bytes| bytes[0..out_cap] else &.{},
    ) catch return -2;
    const value = accepted orelse return 0;
    result.* = .{
        .window_id = value.window_id,
        .capability = capabilityToAbi(value.capability),
        .svg_len = value.svg_len,
    };
    return 1;
}

pub export fn maru_macos_mermaid_take_terminal(out_result: ?*MermaidTerminalResultAbi) i32 {
    const result = out_result orelse return -1;
    const value = session_mod.mermaidCoordinator().takeTerminal() orelse return 0;
    result.* = .{
        .window_id = value.window_id,
        .job_id = value.job_id,
        .renderer = rendererToAbi(value.renderer),
        .reason = @intFromEnum(value.reason),
    };
    return 1;
}

fn maruMacosMermaidTestReset() callconv(.c) void {
    session_mod.resetMermaidCoordinatorForTesting();
}

comptime {
    if (build_options.mermaid_test_api) {
        @export(&maruMacosMermaidTestReset, .{ .name = "maru_macos_mermaid_test_reset" });
    }
}

fn decodedFrameAbi(message: mermaid_protocol.Message) MermaidDecodedFrameAbi {
    var out = std.mem.zeroes(MermaidDecodedFrameAbi);
    out.tag = @intFromEnum(message);
    switch (message) {
        .hello, .hello_ack => |hello| {
            out.helper_instance = hello.helper_instance;
            out.nonce = hello.nonce;
        },
        .request => |request| {
            out.capability = capabilityToAbi(request.capability);
            out.helper_instance = request.capability.helper_instance;
            out.body_ptr = request.source.ptr;
            out.body_len = request.source.len;
            out.palette = request.palette;
        },
        .result => |result| {
            out.status = @intFromEnum(result.status);
            out.capability = capabilityToAbi(result.capability);
            out.helper_instance = result.capability.helper_instance;
            out.body_ptr = if (result.body.len == 0) null else result.body.ptr;
            out.body_len = result.body.len;
        },
    }
    return out;
}

fn rendererFromAbi(value: MermaidRendererCapabilityAbi) mermaid_protocol.RendererCapability {
    return .{
        .editor_epoch = value.editor_epoch,
        .document_revision = value.document_revision,
        .projection_generation = value.projection_generation,
        .widget_id = value.widget_id,
        .widget_generation = value.widget_generation,
        .renderer_instance = value.renderer_instance,
    };
}

fn rendererToAbi(value: mermaid_protocol.RendererCapability) MermaidRendererCapabilityAbi {
    return .{
        .editor_epoch = value.editor_epoch,
        .document_revision = value.document_revision,
        .projection_generation = value.projection_generation,
        .widget_id = value.widget_id,
        .widget_generation = value.widget_generation,
        .renderer_instance = value.renderer_instance,
    };
}

fn capabilityFromAbi(value: MermaidJobCapabilityAbi) mermaid_protocol.JobCapability {
    return .{
        .helper_instance = value.helper_instance,
        .job_id = value.job_id,
        .renderer = rendererFromAbi(value.renderer),
        .fence_id = value.fence_id,
        .source_hash = value.source_hash,
    };
}

fn capabilityToAbi(value: mermaid_protocol.JobCapability) MermaidJobCapabilityAbi {
    return .{
        .helper_instance = value.helper_instance,
        .job_id = value.job_id,
        .renderer = rendererToAbi(value.renderer),
        .fence_id = value.fence_id,
        .source_hash = value.source_hash,
    };
}

fn encodeErrorCode(err: anyerror) i64 {
    return if (err == error.OutputTooSmall) -2 else -1;
}

test "Mermaid codec ABI keeps header constants and opaque frame behavior aligned" {
    try std.testing.expectEqual(@as(usize, c.MARU_MERMAID_PROTOCOL_MAX_SOURCE_BYTES), mermaid_protocol.max_source_bytes);
    try std.testing.expectEqual(@as(usize, c.MARU_MERMAID_PROTOCOL_MAX_SVG_BYTES), mermaid_protocol.max_svg_bytes);
    try std.testing.expectEqual(@as(usize, c.MARU_MERMAID_PROTOCOL_MAX_REQUEST_FRAME_BYTES), mermaid_protocol.max_request_frame_bytes);
    try std.testing.expectEqual(@as(usize, c.MARU_MERMAID_PROTOCOL_MAX_RESULT_FRAME_BYTES), mermaid_protocol.max_result_frame_bytes);
    try std.testing.expectEqual(@as(usize, c.MARU_MERMAID_MAX_PENDING_JOBS), mermaid_coordinator.max_pending_jobs);
    try std.testing.expectEqual(@as(usize, c.MARU_MERMAID_MAX_PENDING_SOURCE_BYTES), mermaid_coordinator.max_pending_source_bytes);
    try std.testing.expectEqual(@as(usize, c.MARU_MERMAID_MAX_ACCEPTED_SVG_BYTES), mermaid_coordinator.max_accepted_svg_bytes);
    try std.testing.expectEqual(@as(usize, c.MARU_MERMAID_MAX_TERMINAL_RESULTS), mermaid_coordinator.max_terminal_results);
    try std.testing.expectEqual(@as(usize, c.MARU_MERMAID_MAX_COMPLETIONS_PER_TICK), mermaid_coordinator.max_completion_drain_per_tick);
    try std.testing.expectEqual(@as(u64, c.MARU_MERMAID_COLD_RESPONSE_DEADLINE_MS), mermaid_coordinator.cold_response_deadline_ms);
    try std.testing.expectEqual(@as(u64, c.MARU_MERMAID_WARM_RESPONSE_DEADLINE_MS), mermaid_coordinator.warm_response_deadline_ms);
    try std.testing.expectEqual(@as(u64, c.MARU_MERMAID_REPLY_FALLBACK_GRACE_MS), mermaid_coordinator.reply_fallback_grace_ms);
    try std.testing.expectEqual(@as(u64, c.MARU_MERMAID_REPLY_FALLBACK_MS), mermaid_coordinator.reply_fallback_ms);
    try std.testing.expectEqual(@as(u32, c.MARU_MERMAID_TERMINAL_SUPERSEDED), @intFromEnum(mermaid_coordinator.TerminalReason.superseded));
    try std.testing.expectEqual(@as(u32, c.MARU_MERMAID_TERMINAL_DEADLINE), @intFromEnum(mermaid_coordinator.TerminalReason.deadline));
    try std.testing.expectEqual(@as(u32, c.MARU_MERMAID_TERMINAL_TRANSIENT_FAILURE), @intFromEnum(mermaid_coordinator.TerminalReason.transient_failure));
    try std.testing.expectEqual(@as(u32, c.MARU_MERMAID_TERMINAL_INTEGRITY_FAILURE), @intFromEnum(mermaid_coordinator.TerminalReason.integrity_failure));
    try std.testing.expectEqual(@as(u32, c.MARU_MERMAID_TERMINAL_INVALID_RESULT), @intFromEnum(mermaid_coordinator.TerminalReason.invalid_result));
    try std.testing.expectEqual(@as(u32, c.MARU_MERMAID_TERMINAL_CAPACITY_EXCEEDED), @intFromEnum(mermaid_coordinator.TerminalReason.capacity_exceeded));
    try std.testing.expectEqual(@as(u32, c.MARU_MERMAID_TERMINAL_FAILURE_LATCHED), @intFromEnum(mermaid_coordinator.TerminalReason.failure_latched));
    try std.testing.expectEqual(@sizeOf(c.MaruMermaidRendererCapability), @sizeOf(MermaidRendererCapabilityAbi));
    try std.testing.expectEqual(@sizeOf(c.MaruMermaidJobCapability), @sizeOf(MermaidJobCapabilityAbi));
    try std.testing.expectEqual(@sizeOf(c.MaruMermaidDecodedFrame), @sizeOf(MermaidDecodedFrameAbi));
    try std.testing.expectEqual(@sizeOf(c.MaruMermaidCoordinatorAction), @sizeOf(MermaidCoordinatorActionAbi));
    try std.testing.expectEqual(@sizeOf(c.MaruMermaidCoordinatorSnapshot), @sizeOf(MermaidCoordinatorSnapshotAbi));
    try std.testing.expectEqual(@sizeOf(c.MaruMermaidAcceptedResult), @sizeOf(MermaidAcceptedResultAbi));
    try std.testing.expectEqual(@sizeOf(c.MaruMermaidTerminalResult), @sizeOf(MermaidTerminalResultAbi));

    var bytes: [64]u8 = undefined;
    const len = maru_mermaid_protocol_encode_hello(0, 7, 9, &bytes, bytes.len);
    try std.testing.expect(len > 0);
    const decoder = maru_mermaid_protocol_decoder_create() orelse return error.OutOfMemory;
    defer maru_mermaid_protocol_decoder_destroy(decoder);
    try std.testing.expectEqual(@as(i32, 0), maru_mermaid_protocol_decoder_feed(decoder, &bytes, @intCast(len)));
    var frame: MermaidDecodedFrameAbi = undefined;
    try std.testing.expectEqual(@as(i32, 1), maru_mermaid_protocol_decoder_next(decoder, &frame));
    try std.testing.expectEqual(@as(u32, c.MARU_MERMAID_TAG_HELLO), frame.tag);
    try std.testing.expectEqual(@as(u64, 7), frame.helper_instance);
    try std.testing.expectEqual(@as(u64, 9), frame.nonce);

    var ack_bytes: [64]u8 = undefined;
    const ack_len = maru_mermaid_protocol_encode_hello(1, 7, 9, &ack_bytes, ack_bytes.len);
    try std.testing.expect(ack_len > 0);
    try std.testing.expectEqual(@as(i32, 0), maru_mermaid_protocol_decoder_feed(decoder, &ack_bytes, @intCast(ack_len)));
    try std.testing.expectEqual(@as(i32, 1), maru_mermaid_protocol_decoder_next(decoder, &frame));
    try std.testing.expectEqual(@as(u32, 1), maru_mermaid_protocol_matches_hello_ack(&frame, 7, 9));
    try std.testing.expectEqual(@as(u32, 0), maru_mermaid_protocol_matches_hello_ack(&frame, 7, 10));
}

test "Mermaid coordinator ABI uses the AppRuntime singleton and rejects stale completion" {
    maruMacosMermaidTestReset();
    defer maruMacosMermaidTestReset();
    const renderer: MermaidRendererCapabilityAbi = .{
        .editor_epoch = 9,
        .document_revision = 1,
        .projection_generation = 2,
        .widget_id = 3,
        .widget_generation = 4,
        .renderer_instance = 5,
    };
    try std.testing.expectEqual(@as(i32, 0), maru_macos_mermaid_admit(1, &renderer, 6, "graph TD".ptr, "graph TD".len));
    var action: MermaidCoordinatorActionAbi = undefined;
    try std.testing.expectEqual(@as(i32, 1), maru_macos_mermaid_drain_action(10, &action));
    try std.testing.expectEqual(@as(u32, c.MARU_MERMAID_ACTION_START_JOB), action.kind);
    try std.testing.expectEqual(@as(u32, 1), action.spawn_helper);
    const request = try mermaid_protocol.decodeExact(action.request_frame_ptr.?[0..action.request_frame_len]);
    try std.testing.expectEqualStrings("graph TD", request.request.source);
    try std.testing.expectEqual(@as(u32, 1), maru_macos_mermaid_complete_action_handoff(action.capability.helper_instance, action.capability.job_id));

    var stale = std.mem.zeroes(MermaidDecodedFrameAbi);
    stale.tag = c.MARU_MERMAID_TAG_RESULT;
    stale.status = c.MARU_MERMAID_RESULT_RENDER_ERROR;
    stale.capability = action.capability;
    stale.capability.job_id += 1;
    try std.testing.expectEqual(@as(i32, 0), maru_macos_mermaid_complete_decoded(&stale, 11));
    var snap: MermaidCoordinatorSnapshotAbi = undefined;
    maru_macos_mermaid_snapshot(&snap);
    try std.testing.expectEqual(@as(u32, 1), snap.in_flight);
    maru_macos_mermaid_shutdown();
    maru_macos_mermaid_snapshot(&snap);
    try std.testing.expectEqual(@as(u32, 1), snap.disabled);
    try std.testing.expectEqual(@as(usize, 0), snap.pending_jobs);
    try std.testing.expectEqual(@as(usize, 0), snap.accepted_results);
    try std.testing.expectEqual(@as(u64, 0), snap.helper_instance);
    try std.testing.expectEqual(@as(u32, 0), snap.in_flight);
    try std.testing.expectEqual(@as(u32, 0), snap.action_handoff_pending);
    try std.testing.expectEqual(@as(u32, 0), snap.termination_in_progress);
}

test "Mermaid coordinator ABI drains exact terminals and exact old job revoke preserves replacement" {
    maruMacosMermaidTestReset();
    defer maruMacosMermaidTestReset();
    const renderer: MermaidRendererCapabilityAbi = .{
        .editor_epoch = 1,
        .document_revision = 1,
        .projection_generation = 1,
        .widget_id = 7,
        .widget_generation = 1,
        .renderer_instance = 9,
    };
    try std.testing.expectEqual(@as(i32, 0), maru_macos_mermaid_admit(3, &renderer, 11, "first".ptr, "first".len));
    try std.testing.expectEqual(@as(i32, 0), maru_macos_mermaid_admit(3, &renderer, 12, "second".ptr, "second".len));
    var snap: MermaidCoordinatorSnapshotAbi = undefined;
    maru_macos_mermaid_snapshot(&snap);
    try std.testing.expectEqual(@as(usize, 1), snap.pending_jobs);
    try std.testing.expectEqual(@as(usize, 1), snap.terminal_results);

    var terminal_result: MermaidTerminalResultAbi = undefined;
    try std.testing.expectEqual(@as(i32, 1), maru_macos_mermaid_take_terminal(&terminal_result));
    try std.testing.expectEqual(@as(u64, 3), terminal_result.window_id);
    try std.testing.expectEqual(@as(u64, 1), terminal_result.job_id);
    try std.testing.expectEqual(renderer.widget_id, terminal_result.renderer.widget_id);
    try std.testing.expectEqual(@as(u32, @intFromEnum(mermaid_coordinator.TerminalReason.superseded)), terminal_result.reason);
    try std.testing.expectEqual(@as(i32, 0), maru_macos_mermaid_take_terminal(&terminal_result));

    maru_macos_mermaid_revoke_job(3, 1, &renderer);
    maru_macos_mermaid_snapshot(&snap);
    try std.testing.expectEqual(@as(usize, 1), snap.pending_jobs);
    var action: MermaidCoordinatorActionAbi = undefined;
    try std.testing.expectEqual(@as(i32, 1), maru_macos_mermaid_drain_action(0, &action));
    try std.testing.expectEqual(@as(u64, 2), action.capability.job_id);
}

test "maru_macos_app_bridge_dispatch export: hello=len>0, 미지원=method_not_found 응답, null=-2" {
    var out: [512]u8 = undefined;
    const hello = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"hello\"}";
    const n = maru_macos_app_bridge_dispatch(hello.ptr, hello.len, &out, out.len);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, out[0..@intCast(n)], "server_version") != null);
    // 미지원 method도 **응답 바이트**(method_not_found 에러)를 돌려준다(음수 아님 — dispatch가 정상 처리).
    const bad = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"nope\"}";
    const m = maru_macos_app_bridge_dispatch(bad.ptr, bad.len, &out, out.len);
    try std.testing.expect(m > 0);
    try std.testing.expect(std.mem.indexOf(u8, out[0..@intCast(m)], "-32601") != null);
    // NULL 포인터 → -2.
    try std.testing.expectEqual(@as(i64, -2), maru_macos_app_bridge_dispatch(null, 0, &out, out.len));
}

test "maru_macos_app_session_bridge_dispatch export: size query + fill and insufficient cap" {
    var session: AppSession = undefined;
    const hello = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"hello\"}";
    const needed = maru_macos_app_session_bridge_dispatch(&session, 7, hello.ptr, hello.len, null, 0);
    try std.testing.expect(needed > 0);
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqual(needed, maru_macos_app_session_bridge_dispatch(&session, 7, hello.ptr, hello.len, &tiny, tiny.len));
    const out = try std.testing.allocator.alloc(u8, @intCast(needed));
    defer std.testing.allocator.free(out);
    const written = maru_macos_app_session_bridge_dispatch(&session, 7, hello.ptr, hello.len, out.ptr, out.len);
    try std.testing.expectEqual(needed, written);
    try std.testing.expect(std.mem.indexOf(u8, out, "server_version") != null);
    try std.testing.expectEqual(@as(i64, -2), maru_macos_app_session_bridge_dispatch(null, 7, hello.ptr, hello.len, null, 0));
    try std.testing.expectEqual(@as(i64, -2), maru_macos_app_session_bridge_dispatch(&session, 7, hello.ptr, hello.len, null, 1));
}

test "file panel document termination ABI rejects a null session" {
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_file_panel_document_terminated(null, 1));
}

test "maru_macos_app_csp_header export: 단일출처 복사 + cap 부족 -1 + null -2" {
    var buf: [512]u8 = undefined;
    const n = maru_macos_app_csp_header(0, &buf, buf.len);
    try std.testing.expect(n > 0);
    try std.testing.expectEqualStrings(maru.session.app_scheme.app_csp_header, buf[0..@intCast(n)]);
    var tiny: [4]u8 = undefined; // csp_header보다 작음 → -1
    try std.testing.expectEqual(@as(i64, -1), maru_macos_app_csp_header(1, &tiny, tiny.len));
    try std.testing.expectEqual(@as(i64, -2), maru_macos_app_csp_header(0, null, 512));
    try std.testing.expectEqual(@as(i64, -3), maru_macos_app_csp_header(9, &buf, buf.len));
}

test "maru_macos_app_asset_role_for_origin export pins app and render" {
    try std.testing.expectEqual(@as(i32, 0), maru_macos_app_asset_role_for_origin("maru-app", 8, "app", 3, 0));
    try std.testing.expectEqual(@as(i32, 1), maru_macos_app_asset_role_for_origin("maru-app", 8, "render", 6, 0));
    try std.testing.expectEqual(@as(i32, -1), maru_macos_app_asset_role_for_origin("maru-app", 8, "app", 3, 1));
}

test "maru_macos_app_origin_allowed export: role and explicit port are exact" {
    try std.testing.expectEqual(@as(c_int, 1), maru_macos_app_origin_allowed("maru-app", 8, "app", 3, 0, 0));
    try std.testing.expectEqual(@as(c_int, 1), maru_macos_app_origin_allowed("maru-app", 8, "render", 6, 0, 1));
    try std.testing.expectEqual(@as(c_int, 1), maru_macos_app_origin_allowed("maru-app", 8, "render", 6, 0, 2));
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_app_origin_allowed("maru-app", 8, "app", 3, 1, 0));
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_app_origin_allowed("maru-app", 8, "render", 6, 0, 0));
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_app_origin_allowed(null, 0, "app", 3, 0, 0));
}

test "maru_macos_app_resolve_app_asset export: 정상=len>0, traversal=-1, 부재=-2, null=-4" {
    const io = std.testing.io;
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "x" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];

    var out: [std.fs.max_path_bytes]u8 = undefined;
    // 정상: resolved 절대 경로 길이(양수)를 돌려주고 out에 canonical 경로를 씀.
    const n = maru_macos_app_resolve_app_asset(0, root_abs.ptr, root_abs.len, "index.html", 10, &out, out.len);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.endsWith(u8, out[0..@intCast(n)], "/index.html"));
    // traversal → -1(Reject), 부재 → -2(NotFound), null root → -4.
    try std.testing.expectEqual(@as(i64, -1), maru_macos_app_resolve_app_asset(0, root_abs.ptr, root_abs.len, "../x", 4, &out, out.len));
    try std.testing.expectEqual(@as(i64, -2), maru_macos_app_resolve_app_asset(0, root_abs.ptr, root_abs.len, "nope.html", 9, &out, out.len));
    try std.testing.expectEqual(@as(i64, -4), maru_macos_app_resolve_app_asset(0, null, 0, "index.html", 10, &out, out.len));
}

test "maru_macos_app_read_app_asset reads one no-follow fd and rejects path escapes" {
    const io = std.testing.io;
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "safe" });
    try root_tmp.dir.writeFile(io, .{ .sub_path = "bundle.js", .data = "shell" });
    try root_tmp.dir.symLink(io, "index.html", "app.css", .{});
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];
    var out: [64]u8 = undefined;

    const len = maru_macos_app_read_app_asset(0, root_abs.ptr, root_abs.len, "index.html", 10, &out, out.len);
    try std.testing.expectEqual(@as(i64, 4), len);
    try std.testing.expectEqualStrings("safe", out[0..@intCast(len)]);
    try std.testing.expectEqual(@as(i64, -1), maru_macos_app_read_app_asset(0, root_abs.ptr, root_abs.len, "sub/page.html", 13, &out, out.len));
    try std.testing.expectEqual(@as(i64, -2), maru_macos_app_read_app_asset(1, root_abs.ptr, root_abs.len, "app.css", 7, &out, out.len));
}

test "resolveAppAsset: 정상 파일 서빙 + 빈 경로 → index" {
    const io = std.testing.io;
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "<html>root</html>" });
    try root_tmp.dir.createDirPath(io, "sub");
    try root_tmp.dir.writeFile(io, .{ .sub_path = "sub/page.html", .data = "<html>sub</html>" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];

    var out: [std.fs.max_path_bytes]u8 = undefined;
    const idx = try resolveAppAsset(io, .app, root_abs, "index.html", &out);
    try std.testing.expect(pathIsUnder(idx, root_abs));
    try std.testing.expect(std.mem.endsWith(u8, idx, "/index.html"));

    var out2: [std.fs.max_path_bytes]u8 = undefined;
    const root_req = try resolveAppAsset(io, .app, root_abs, "/", &out2); // 빈→index
    try std.testing.expect(std.mem.endsWith(u8, root_req, "/index.html"));

    var out3: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(AppAssetError.Reject, resolveAppAsset(io, .app, root_abs, "sub/page.html", &out3));
}

test "resolveAppAsset: render role rejects in-root aliases of its closed asset set" {
    const io = std.testing.io;
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "shell-only" });
    try root_tmp.dir.symLink(io, "index.html", "bundle.js", .{});
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];
    var out: [std.fs.max_path_bytes]u8 = undefined;
    // render origin은 canonical 상대 경로까지 정확히 같아야 한다. 허용 이름(bundle.js)을 다른 파일로 향하게 한
    // in-root symlink가 통과하면 `script-src 'self'`인 renderer가 shell 전용 자산 bytes를 읽을 수 있다.
    try std.testing.expectError(AppAssetError.Reject, resolveAppAsset(io, .render, root_abs, "bundle.js", &out));
}

test "resolveAppAsset: Mermaid runtime is helper-only even when present under the app root" {
    const io = std.testing.io;
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "mermaid-helper.js", .data = "helper-only" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];
    var out: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(AppAssetError.Reject, resolveAppAsset(io, .app, root_abs, "mermaid-helper.js", &out));
    try std.testing.expectError(AppAssetError.Reject, resolveAppAsset(io, .app, root_abs, "MERMAID-HELPER.JS", &out));
    try std.testing.expectError(AppAssetError.Reject, resolveAppAsset(io, .render, root_abs, "mermaid-helper.js", &out));
}

test "resolveAppAsset: traversal(`..`)·whitelist 밖 → Reject(5c-1 문자열 단계)" {
    const io = std.testing.io;
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "x" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];
    var out: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(AppAssetError.Reject, resolveAppAsset(io, .app, root_abs, "../index.html", &out));
    try std.testing.expectError(AppAssetError.Reject, resolveAppAsset(io, .app, root_abs, "a/../../etc/passwd", &out));
    try std.testing.expectError(AppAssetError.Reject, resolveAppAsset(io, .app, root_abs, "%2e%2e/x", &out)); // `%` whitelist 밖
}

test "resolveAppAsset: symlink 탈출 → OutsideRoot(realpath canonical 방어)" {
    const io = std.testing.io;
    // out_tmp/secret.txt(root 밖) + root/evil → 그 절대 경로 symlink. resolve는 canonical이 root 밖이라 거부.
    var out_tmp = std.testing.tmpDir(.{});
    defer out_tmp.cleanup();
    try out_tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "SECRET" });
    var sec_buf: [std.fs.max_path_bytes]u8 = undefined;
    const secret_abs = sec_buf[0..try out_tmp.dir.realPathFile(io, "secret.txt", &sec_buf)];

    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "x" });
    root_tmp.dir.symLink(io, secret_abs, "evil", .{}) catch |e| switch (e) {
        error.AccessDenied => return error.SkipZigTest, // 일부 FS는 symlink 불가
        else => return e,
    };
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];
    var out: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(AppAssetError.OutsideRoot, resolveAppAsset(io, .app, root_abs, "evil", &out));
}

test "resolveAppAsset: 부재 파일·디렉터리 → NotFound" {
    const io = std.testing.io;
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    try root_tmp.dir.createDirPath(io, "adir");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try root_tmp.dir.realPath(io, &root_buf)];
    var out: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(AppAssetError.NotFound, resolveAppAsset(io, .app, root_abs, "nonexistent.html", &out));
    try std.testing.expectError(AppAssetError.NotFound, resolveAppAsset(io, .app, root_abs, "adir", &out)); // 디렉터리는 서빙 안 함
}

// 전역(OS) 단축키가 라이브로 바뀌어(세팅 GUI 녹음/해제·reload·reset) OS 재등록이 필요하면 1(플래그 비움), 없으면 0.
// Swift가 tick마다 호출해 1이면 unregisterGlobalHotkeys 후 registerGlobalHotkeys로 새 global_hotkeys를 OS에 다시 깐다.
// take_bell과 같은 1회성 신호 — drain하면 비워진다. session null=0. (v82)
pub export fn maru_macos_app_session_take_global_hotkeys_dirty(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeGlobalHotkeysDirty()) 1 else 0;
}

// 커맨드 카탈로그가 런타임에 재빌드돼(keybind rebind/unbind·reload·reset → rebuildCommandCatalog) 메뉴바 재빌드가
// 필요하면 1(플래그 비움), 없으면 0. Swift가 tick마다 호출해 1이면 buildMainMenu로 NSMenu keyEquivalent를 새 카탈로그로
// 다시 깐다. reset은 확인 모달 확정 후 다음 tick에 갱신되므로 동기 호출이 아니라 이 신호가 단일 경로다(인앱 rebind·멀티창
// 활성 세션도 같이 커버). take_global_hotkeys_dirty와 같은 1회성 신호. session null=0. (v85)
pub export fn maru_macos_app_session_take_command_catalog_dirty(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeCommandCatalogDirty()) 1 else 0;
}

// 폰트 크기(⌘+/−·config)가 바뀌어 열린 파일 패널 webview의 크기 재적용이 필요하면 1(플래그 비움), 없으면 0.
// Swift가 tick마다 호출해 1이면 편집기 폰트 pt를 재주입하고 프리뷰 iframe·HTML/PDF에 현재 줌 배율을 적용한다(§2.3).
// take_command_catalog_dirty와 같은 1회성 신호. session null=0. (v140)
pub export fn maru_macos_app_session_take_file_panel_zoom_dirty(session: ?*AppSession) u32 {
    const app_session = session orelse return 0;
    return if (app_session.takeFilePanelZoomDirty()) 1 else 0;
}

// 파일 패널 webview 줌 배율을 milli(1000=1.0)로 반환한다 — 현재 폰트 크기 / base_font_size(⌘0 기준). 프리뷰
// iframe CSS `zoom`·HTML/PDF `pageZoom`이 이 값을 쓴다. base 비정상이면 1000(=1.0), 극단 배율은 [100,10000]으로
// 클램프된다(filePanelZoomMilli). 신규 파일 패널은 로드 didFinish에서 이 값을 읽어 즉시 현재 줌으로 착지한다. session null=1000. (v140)
pub export fn maru_macos_app_session_file_panel_zoom_milli(session: ?*AppSession) u32 {
    const app_session = session orelse return 1000;
    return app_session.filePanelZoomMilli();
}

fn keyEventFromAbi(event: KeyEvent) !terminal.KeyEvent {
    // 레이아웃 독립 단축키: Ctrl/Cmd 조합인데 현재 입력 소스의 글자가 라틴이 아니면(한글 'ㅂ'
    // 등 >= 0x80) 물리 키코드를 US 배열 라틴으로 되돌린다 — 한글 모드에서도 Ctrl+B가 0x02로
    // 인코딩된다(멀티플렉서 prefix 등). 라틴 레이아웃(영어/Dvorak)의 결과는 존중해 건드리지 않는다.
    var codepoint = event.codepoint;
    if ((event.modifier_control != 0 or event.modifier_command != 0) and codepoint >= 0x80) {
        if (keycode.usAsciiForKeyCode(event.raw_key_code)) |latin| codepoint = latin;
    }

    // base codepoint(kitty CSI u의 key code용 — shift 미반영 base-layout)도 codepoint와 같은
    // 레이아웃 독립 처리를 받는다(한글 모드 Ctrl+Shift도 US 라틴 base로 매칭). 유효 Unicode scalar가
    // 아니면 null로 두어 encodeKitty가 Key.char codepoint로 폴백한다.
    var base_codepoint = event.base_codepoint;
    if ((event.modifier_control != 0 or event.modifier_command != 0) and base_codepoint >= 0x80) {
        if (keycode.usAsciiForKeyCode(event.raw_key_code)) |latin| base_codepoint = latin;
    }

    // codepoint -> char 변환과 surrogate/범위 거부는 terminal.input이 단일 출처로 소유한다.
    // native keyDown smoke(keyEventFromNativeKeyDown)와 같은 변환을 공유해, 한쪽만 고치면
    // 두 입력 경계가 키 의미를 다르게 해석하는 일을 막는다. 잘못된 codepoint/key_code는 ABI
    // 계약대로 InvalidConfig로 닫는다.
    const key: terminal.Key = if (codepoint != 0)
        (terminal.input.charKeyFromCodepoint(codepoint) catch return error.InvalidConfig)
    else switch (std.enums.fromInt(KeyCode, event.key_code) orelse return error.InvalidConfig) {
        .unknown => return error.InvalidConfig,
        .enter => .enter,
        .escape => .escape,
        .tab => .tab,
        .backspace => .backspace,
        .arrow_up => .arrow_up,
        .arrow_down => .arrow_down,
        .arrow_left => .arrow_left,
        .arrow_right => .arrow_right,
        .home => .home,
        .end => .end,
        .insert => .insert,
        .delete => .delete,
        .page_up => .page_up,
        .page_down => .page_down,
        .f1 => .{ .function = 1 },
        .f2 => .{ .function = 2 },
        .f3 => .{ .function = 3 },
        .f4 => .{ .function = 4 },
        .f5 => .{ .function = 5 },
        .f6 => .{ .function = 6 },
        .f7 => .{ .function = 7 },
        .f8 => .{ .function = 8 },
        .f9 => .{ .function = 9 },
        .f10 => .{ .function = 10 },
        .f11 => .{ .function = 11 },
        .f12 => .{ .function = 12 },
    };

    return .{
        .key = key,
        .modifiers = .{
            .shift = event.modifier_shift != 0,
            .control = event.modifier_control != 0,
            .option = event.modifier_option != 0,
            .command = event.modifier_command != 0,
        },
        .base_codepoint = if (base_codepoint != 0 and base_codepoint <= 0x10ffff and (base_codepoint < 0xd800 or base_codepoint > 0xdfff))
            @intCast(base_codepoint)
        else
            null,
        // G10: numpad 키 판정은 macOS 물리 키코드로(platform). application keypad 모드면 encodeKey가 SS3로.
        .keypad = keycode.isKeypad(event.raw_key_code),
    };
}
// ══ 세션 컨트롤 플레인 라이브 서버(Track C A2b) ══════════════════════════════════════════════════════════════
// 단일 출처: docs/control-plane.md §2(collector 2층)·§5(메인 marshal)·§8.4(auth 한계)·§16.
//  - 소켓 bind·accept 스레드·marshal 큐는 control_server.zig(generic L4)가 소유.
//  - 실 collector 조립(창마다 collectSessionInto)·auth 판정(A2b metadata:self)·dispatch(1d)는 여기서 — AppSession을
//    아는 유일한 L4 층이라(§16 코드배치 gate: app_session.zig 인접 L4 허용).
//  - Swift는 (1) start 1회, (2) 매 tick drain(살아있는 세션 목록), (3) stop만 부른다(§2 열거만).

/// 세션(창) collector 참조 — Swift가 창마다 채운다. app_host_abi.h `MaruControlSessionRef`와 layout 일치.
pub const ControlSessionRef = extern struct {
    app_session: ?*AppSession,
    window_id: u64,
    window_kind: u32,
    reserved: u32 = 0,
};

/// 앱 인스턴스 전역 라이브 서버(주소 안정 필요 — accept 스레드가 &storage를 잡는다). 메인 스레드만 active 토글/drain을
/// 만진다(server 내부 필드는 자체 동기화). 서버 미시작(bind 실패 등)이면 컨트롤 플레인만 꺼지고 앱은 계속 산다.
var control_server_storage: control_server_mod.ControlServer = undefined;
var control_server_active: bool = false;

/// 라이브 capability store(§8.5 1e). **메인 스레드 전용**(handleControlRequest가 메인 drain에서만 read — accept
/// 스레드는 절대 안 만진다, §8.8 lock-order). 지금은 **비어 있다**: 실 fd 발급/상속(§8.5, 1e-confirm/후속)이 아직
/// 없어 nonce를 실은 요청은 전부 default-deny(unauthorized)다. nonce 없는 요청은 기존 metadata:self 경로(회귀 없음).
/// dispatchAuthenticated가 이 store로 nonce→scope를 resolve한다. 발급 경로가 붙으면 여기 issueForFd로 채운다.
var control_cap_store: control_capability.CapabilityStore = .{};

/// **1e-confirm(§9.2 Model B)**: pane-bound confirm-grant 라이브 store. 사용자가 확인 모달로 승인한 (pane, target,
/// scope) grant를 저장하고, dispatchAuthenticated가 browser.* authz서 세션 cap과 **가법** 조회한다. 빈=grant 없음=
/// (cap도 없으면) default-deny. grant 생성(확인 모달)·surface-close removeSurface 배선은 1e-confirm-1c/2. **메인 스레드 전용**(§8.8).
var control_pane_grant_store: control_pane_grant.PaneGrantStore = .{};

/// 5e-2b: browser op 큐 엔트리. `arg`는 cross_gpa 소유(method별 인자 — navigate=url·executeScript=backend JSON·getUrl=빈).
const BrowserOpEntry = struct { async_id: u64, surface_id: u64, op_kind: u8, arg: []const u8 };

/// 5e-2b: browser op FIFO 큐(**메인 스레드 전용** — handleControlRequest가 push, take_browser_op가 pop해 Swift가
/// 실행). accept가 serial이라 실질 ≤1이나 bounded(`max`)로 견고성 유지. push 성공 시 `arg` 소유권을 큐가 인수한다.
const BrowserOpQueue = struct {
    items: std.ArrayList(BrowserOpEntry) = .empty,
    max: usize = 8,

    /// bounded push. 초과면 `error.Full`(호출자가 arg free + 요청 에러 resolve). 성공 시 arg 소유권 인수.
    fn push(self: *BrowserOpQueue, gpa: std.mem.Allocator, e: BrowserOpEntry) error{ Full, OutOfMemory }!void {
        if (self.items.items.len >= self.max) return error.Full;
        try self.items.append(gpa, e);
    }
    /// FIFO pop(없으면 null). 반환 엔트리의 arg 소유권은 호출자로 이전(호출자가 free).
    fn take(self: *BrowserOpQueue) ?BrowserOpEntry {
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }
    /// queued client terminal(close/revoke/timeout)이 먼저 확정되면 물리 엔트리도 즉시 제거해 다른 surface의 다음 push가
    /// stale capacity 때문에 거짓 Full이 되지 않게 한다. running op은 이미 take됐으므로 no-op이다.
    fn remove(self: *BrowserOpQueue, arg_gpa: std.mem.Allocator, async_id: u64) bool {
        for (self.items.items, 0..) |e, i| if (e.async_id == async_id) {
            const removed = self.items.orderedRemove(i);
            arg_gpa.free(removed.arg);
            return true;
        };
        return false;
    }
    /// 남은 op의 arg 해제 + 리스트 해제(서버 종료 시).
    fn deinit(self: *BrowserOpQueue, gpa: std.mem.Allocator, arg_gpa: std.mem.Allocator) void {
        for (self.items.items) |e| arg_gpa.free(e.arg);
        self.items.deinit(gpa);
    }
};
var browser_op_queue: BrowserOpQueue = .{};

const execution_result_budget_bytes: usize = 256 * 1024 * 1024;

/// queue에 들어간 browser op은 Swift가 take하기 전에도 target surface close·grant revoke·timeout과 경합한다.
/// 자체 polling registry를 쓰는 wait와 queue를 쓰지 않는 동기 subscribe만 제외하고 공통 수명주기로 추적한다.
fn browserMethodHasTrackedLifecycle(method: control_browser.BrowserMethod) bool {
    return switch (method) {
        .navigate,
        .get_url,
        .execute_script,
        .get_cookies,
        .screenshot,
        .set_cookie,
        .delete_cookie,
        .get_local_storage,
        .set_local_storage,
        .remove_local_storage,
        .clear_storage,
        .click,
        .type_text,
        .scroll,
        .snapshot,
        .console,
        => true,
        .subscribe, .wait => false,
    };
}

fn browserMethodReservedBytes(method: control_browser.BrowserMethod, declared: usize) usize {
    return switch (method) {
        .execute_script => declared,
        .screenshot => control_browser.screenshot_max_result_bytes,
        .snapshot => control_browser.snapshot_max_result_bytes, // §9.5.10 통일-1: transfer 경로 예약(inline/chunk 자동)
        .console => control_browser.console_max_result_bytes, // §9.5.10 통일-2: 동일 transfer 예약(512 KiB 절단 제거)
        else => 0,
    };
}

fn browserMethodWireName(method: control_browser.BrowserMethod) []const u8 {
    return switch (method) {
        .navigate => "browser.navigate",
        .get_url => "browser.getUrl",
        .execute_script => "browser.executeScript",
        .subscribe => "browser.subscribe",
        .get_cookies => "browser.getCookies",
        .screenshot => "browser.screenshot",
        .set_cookie => "browser.setCookie",
        .delete_cookie => "browser.deleteCookie",
        .get_local_storage => "browser.getLocalStorage",
        .set_local_storage => "browser.setLocalStorage",
        .remove_local_storage => "browser.removeLocalStorage",
        .clear_storage => "browser.clearStorage",
        .click => "browser.click",
        .type_text => "browser.type",
        .scroll => "browser.scroll",
        .wait => "browser.wait",
        .snapshot => "browser.snapshot",
        .console => "browser.console",
    };
}

const ExecutionProvenance = union(enum) {
    capability: struct { nonce: control_capability.Nonce, generation: u64 },
    pane_grant: control_browser.GrantProvenance,
};

const ExecutionPhase = enum { queued, running, transferring, release_pending, abandoned };

const ActiveBrowserExecution = struct {
    async_id: u64,
    surface_id: u64,
    method: control_browser.BrowserMethod = .execute_script,
    reserved_bytes: usize,
    provenance: ExecutionProvenance,
    phase: ExecutionPhase = .queued,
    transfer_id: u64 = 0,
    transfer_total_bytes: usize = 0,
};

/// async browser backend와 client terminal을 분리해 추적한다. queued 취소는 즉시 반환하고, running 취소는 WebKit
/// callback(backend terminal)까지 슬롯(대용량 결과면 예약도)을 유지한다. 메인 스레드 전용이며 budget 주소가 안정되도록
/// 전역에서 이동하지 않는다.
const ActiveBrowserExecutions = struct {
    budget: control_result.ByteBudget,
    items: std.ArrayList(ActiveBrowserExecution) = .empty,
    max: usize,

    fn init(limit: usize, max: usize) ActiveBrowserExecutions {
        return .{ .budget = .init(limit), .max = max };
    }

    fn admit(self: *ActiveBrowserExecutions, gpa: std.mem.Allocator, e: ActiveBrowserExecution) !void {
        if (self.items.items.len >= self.max) return error.ExecutionSlotsFull;
        try self.budget.reserve(e.reserved_bytes);
        errdefer self.budget.release(e.reserved_bytes) catch unreachable;
        try self.items.append(gpa, e);
    }

    fn indexOf(self: *const ActiveBrowserExecutions, async_id: u64) ?usize {
        for (self.items.items, 0..) |e, i| if (e.async_id == async_id) return i;
        return null;
    }

    fn get(self: *ActiveBrowserExecutions, async_id: u64) ?*ActiveBrowserExecution {
        const i = self.indexOf(async_id) orelse return null;
        return &self.items.items[i];
    }

    fn markRunning(self: *ActiveBrowserExecutions, async_id: u64) bool {
        const e = self.get(async_id) orelse return false;
        if (e.phase != .queued) return false;
        e.phase = .running;
        return true;
    }

    /// client terminal. queued는 backend 미시작이라 즉시 finish, running은 abandoned로 남긴다.
    fn abandon(self: *ActiveBrowserExecutions, async_id: u64) void {
        const i = self.indexOf(async_id) orelse return;
        if (self.items.items[i].phase == .queued) return self.finishAt(i);
        self.items.items[i].phase = .abandoned;
    }

    /// running execution의 같은 슬롯·예약을 transfer로 원자 전환한다. 실제 길이 차액만 반환하며 예약을 0으로
    /// 내렸다가 다시 잡는 창은 없다.
    fn beginTransfer(self: *ActiveBrowserExecutions, async_id: u64, transfer_id: u64, actual: usize) bool {
        const e = self.get(async_id) orelse return false;
        if (e.phase != .running or transfer_id == 0 or actual > e.reserved_bytes) return false;
        self.budget.release(e.reserved_bytes - actual) catch return false;
        e.reserved_bytes = actual;
        e.transfer_id = transfer_id;
        e.transfer_total_bytes = actual;
        e.phase = .transferring;
        return true;
    }

    fn finish(self: *ActiveBrowserExecutions, async_id: u64) bool {
        const i = self.indexOf(async_id) orelse return false;
        self.finishAt(i);
        return true;
    }

    fn finishAt(self: *ActiveBrowserExecutions, i: usize) void {
        const bytes = self.items.items[i].reserved_bytes;
        self.budget.release(bytes) catch unreachable;
        _ = self.items.swapRemove(i);
    }

    fn deinit(self: *ActiveBrowserExecutions, gpa: std.mem.Allocator) void {
        while (self.items.items.len > 0) self.finishAt(self.items.items.len - 1);
        self.items.deinit(gpa);
    }

    /// server stop은 client terminal일 뿐 running WebKit의 backend terminal이 아니다. queued만 반환하고 running은
    /// callback/realm teardown까지 tombstone+예약을 유지한다.
    fn stop(self: *ActiveBrowserExecutions) void {
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            if (self.items.items[i].phase == .queued)
                self.finishAt(i)
            else
                self.items.items[i].phase = .abandoned;
        }
    }
};

var active_browser_executions = ActiveBrowserExecutions.init(execution_result_budget_bytes, 8);

const ActiveBrowserTransfer = struct {
    async_id: u64,
    connection_id: u64,
    result_id: i64,
    source_id: u64,
    context: ?*anyopaque,
    copy_result: BrowserResultCopyFn,
    release_result: BrowserResultReleaseFn,
    progress: control_result.BrowserResultTransfer,
    terminal: []u8,
    kind: union(enum) {
        execute_script,
        screenshot: struct { capture_id: u64 },
        snapshot, // §9.5.10 통일-1: raw 값(tree JSON) chunk-stream, pump가 browser.snapshotChunk로 직렬화
        console, // §9.5.10 통일-2: raw 값(`[{level,text}]` 배열) chunk-stream, pump가 browser.consoleChunk로 직렬화
    } = .execute_script,
};

const ActiveBrowserTransfers = struct {
    items: std.ArrayList(ActiveBrowserTransfer) = .empty,
    cursor: control_result.RoundRobinCursor = .{},
    max: usize = 8,
    next_result_id: i64 = 1,

    fn admit(self: *ActiveBrowserTransfers, gpa: std.mem.Allocator, entry: ActiveBrowserTransfer) !void {
        if (self.items.items.len >= self.max) return error.TransferSlotsFull;
        try self.items.append(gpa, entry);
    }

    fn issueResultId(self: *ActiveBrowserTransfers) ?i64 {
        if (self.next_result_id <= 0 or self.next_result_id == std.math.maxInt(i64)) return null;
        const id = self.next_result_id;
        self.next_result_id += 1;
        return id;
    }

    fn indexOf(self: *ActiveBrowserTransfers, async_id: u64) ?usize {
        for (self.items.items, 0..) |entry, i| if (entry.async_id == async_id) return i;
        return null;
    }
};

var active_browser_transfers: ActiveBrowserTransfers = .{};
var browser_transfer_scratch: std.ArrayList(u8) = .empty;
/// 5f-1: screenshot chunk 스트림의 `capture_id`(§9.5.7) 발급기 — 세션-로컬 단조(재사용 무관, client는 seq로 재조립).
/// completeScreenshotOp이 각 스크린샷마다 하나 발급. `+%=`로 wrap(현실적 도달 불가, 단조성만 필요).
var screenshot_capture_id_next: u64 = 1;
/// take_browser_op이 pop한 op의 arg를 **다음 take까지** 살려 Swift가 이 호출 중 동기 복사하게 하는 안정 슬롯(app allocator).
var browser_op_take_buf: std.ArrayList(u8) = .empty;
/// hung WKWebView op 마감(reap) — evaluateJavaScript/navigation이 영영 안 끝나는 op가 accept 스레드를 영구 붙잡는 것 방어.
const browser_op_timeout_ns: i128 = 30 * std.time.ns_per_s;

/// 5f-2 wait는 최대 25초짜리 장기 op라 surface close·pane grant revoke에 즉시 취소한다. capability-origin wait를
/// pane grant revoke가 잘못 끊지 않도록 dispatch가 보존한 provenance를 같이 둔다. 메인 스레드 전용, max_in_flight(8)로 bounded.
const ActiveBrowserWait = struct {
    async_id: u64,
    surface_id: u64,
    pane_grant: ?control_browser.GrantProvenance,
};
var active_browser_waits: std.ArrayList(ActiveBrowserWait) = .empty;

fn removeActiveBrowserWait(async_id: u64) bool {
    for (active_browser_waits.items, 0..) |e, i| {
        if (e.async_id == async_id) {
            _ = active_browser_waits.swapRemove(i);
            return true;
        }
    }
    return false;
}

fn activeBrowserWait(async_id: u64) bool {
    for (active_browser_waits.items) |e| if (e.async_id == async_id) return true;
    return false;
}

fn cancelActiveBrowserWait(server: *control_server_mod.ControlServer, async_id: u64, status: control_browser.BrowserCompletionStatus) void {
    const pending = server.inFlightPending(async_id) orelse {
        _ = removeActiveBrowserWait(async_id);
        return;
    };
    _ = removeActiveBrowserWait(async_id);
    const resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, status, "") catch null;
    _ = server.completeInFlight(async_id, resp);
}

fn waitStatusForClosedSurface(e: ActiveBrowserWait, surface_id: u64) ?control_browser.BrowserCompletionStatus {
    if (e.surface_id == surface_id) return .process_exited;
    const grant = e.pane_grant orelse return null;
    if (grant.pane == surface_id) return .unauthorized;
    return null;
}

fn cancelBrowserWaitsForClosedSurface(server: *control_server_mod.ControlServer, surface_id: u64) void {
    var matches: [8]struct { id: u64, status: control_browser.BrowserCompletionStatus } = undefined; // active≤8
    var count: usize = 0;
    for (active_browser_waits.items) |e| if (waitStatusForClosedSurface(e, surface_id)) |status| {
        matches[count] = .{ .id = e.async_id, .status = status };
        count += 1;
    };
    for (matches[0..count]) |match| cancelActiveBrowserWait(server, match.id, match.status);
}

fn cancelActiveBrowserExecution(server: *control_server_mod.ControlServer, async_id: u64, status: control_browser.BrowserCompletionStatus) void {
    if (active_browser_transfers.indexOf(async_id)) |index| {
        cancelBrowserTransfer(server, index, status);
        return;
    }
    const queued = if (active_browser_executions.get(async_id)) |execution| execution.phase == .queued else false;
    if (server.inFlightPending(async_id)) |pending| {
        const resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, status, "") catch null;
        _ = server.completeInFlight(async_id, resp);
    }
    if (queued) _ = browser_op_queue.remove(server.cross_gpa, async_id);
    active_browser_executions.abandon(async_id);
}

fn executionStatusForClosedSurface(e: ActiveBrowserExecution, surface_id: u64) ?control_browser.BrowserCompletionStatus {
    if (e.surface_id == surface_id) return .process_exited;
    return switch (e.provenance) {
        .capability => null,
        .pane_grant => |g| if (g.pane == surface_id) .unauthorized else null,
    };
}

fn cancelBrowserExecutionsForClosedSurface(server: *control_server_mod.ControlServer, surface_id: u64) void {
    var matches: [8]struct { id: u64, status: control_browser.BrowserCompletionStatus } = undefined;
    var count: usize = 0;
    for (active_browser_executions.items.items) |e| if (executionStatusForClosedSurface(e, surface_id)) |status| {
        matches[count] = .{ .id = e.async_id, .status = status };
        count += 1;
    };
    for (matches[0..count]) |match| cancelActiveBrowserExecution(server, match.id, match.status);
}

fn cancelBrowserOpsForCrashedSurface(server: *control_server_mod.ControlServer, surface_id: u64) void {
    var wait_ids: [8]u64 = undefined;
    var wait_count: usize = 0;
    for (active_browser_waits.items) |e| if (e.surface_id == surface_id) {
        wait_ids[wait_count] = e.async_id;
        wait_count += 1;
    };
    for (wait_ids[0..wait_count]) |id| cancelActiveBrowserWait(server, id, .process_exited);

    var execution_ids: [8]u64 = undefined;
    var execution_count: usize = 0;
    for (active_browser_executions.items.items) |e| if (e.surface_id == surface_id) {
        execution_ids[execution_count] = e.async_id;
        execution_count += 1;
    };
    for (execution_ids[0..execution_count]) |id| cancelActiveBrowserExecution(server, id, .process_exited);
}

/// AppSession teardown 훅: target surface close는 process_exited, pane-grant origin close는 unauthorized로 진행 중 wait를
/// 끝낸 뒤 그 surface가 pane/target으로 걸린 grant를 모두 제거한다. capability-origin wait는 origin pane 수명과 무관하다.
fn onAppSessionSurfaceClosed(_: ?*anyopaque, surface_id: u64) void {
    if (control_server_active) {
        cancelBrowserWaitsForClosedSurface(&control_server_storage, surface_id);
        cancelBrowserExecutionsForClosedSurface(&control_server_storage, surface_id);
    }
    _ = control_cap_store.revokeSurface(surface_id);
    control_pane_grant_store.removeSurface(surface_id);
}

fn cancelBrowserWaitsForGrant(server: *control_server_mod.ControlServer, pane: u64, target: u64, scope: control_capability.ScopeClass) void {
    var ids: [8]u64 = undefined;
    var count: usize = 0;
    for (active_browser_waits.items) |e| if (waitOriginMatchesGrant(e, pane, target, scope)) {
        ids[count] = e.async_id;
        count += 1;
    };
    for (ids[0..count]) |id| cancelActiveBrowserWait(server, id, .unauthorized);
}

fn cancelBrowserExecutionsForGrant(server: *control_server_mod.ControlServer, pane: u64, target: u64, scope: control_capability.ScopeClass) void {
    var ids: [8]u64 = undefined;
    var count: usize = 0;
    for (active_browser_executions.items.items) |e| switch (e.provenance) {
        .capability => {},
        .pane_grant => |g| if (g.pane == pane and g.target == target and g.scope == scope) {
            ids[count] = e.async_id;
            count += 1;
        },
    };
    for (ids[0..count]) |id| cancelActiveBrowserExecution(server, id, .unauthorized);
}

fn cancelAllPaneGrantBrowserExecutions(server: *control_server_mod.ControlServer) void {
    var ids: [8]u64 = undefined;
    var count: usize = 0;
    for (active_browser_executions.items.items) |e| switch (e.provenance) {
        .capability => {},
        .pane_grant => {
            ids[count] = e.async_id;
            count += 1;
        },
    };
    for (ids[0..count]) |id| cancelActiveBrowserExecution(server, id, .unauthorized);
}

fn waitOriginMatchesGrant(e: ActiveBrowserWait, pane: u64, target: u64, scope: control_capability.ScopeClass) bool {
    const g = e.pane_grant orelse return false;
    return g.pane == pane and g.target == target and g.scope == scope;
}

fn cancelAllPaneGrantBrowserWaits(server: *control_server_mod.ControlServer) void {
    var ids: [8]u64 = undefined;
    var count: usize = 0;
    for (active_browser_waits.items) |e| if (e.pane_grant != null) {
        ids[count] = e.async_id;
        count += 1;
    };
    for (ids[0..count]) |id| cancelActiveBrowserWait(server, id, .unauthorized);
}

fn pruneInactiveBrowserWaits(server: *control_server_mod.ControlServer) void {
    var i: usize = 0;
    while (i < active_browser_waits.items.len) {
        if (server.inFlightPending(active_browser_waits.items[i].async_id) == null) {
            _ = active_browser_waits.swapRemove(i);
        } else i += 1;
    }
}

// ── 1e-confirm-2a: held-request grant 확인 흐름(§9.2 Model B) ──────────────────────────────────────────────
/// needs_grant 요청을 **틱 넘어 붙잡고**(§5-async deferRequest) 확인 결정(2a=env 스텁·2b=모달)을 기다리는 대기 항목.
/// `async_id`로 in-flight pending을 조회하고, 결정 시 grant 기록+재-dispatch(승인) or unauthorized(거부)한다.
const GrantPromptEntry = struct { async_id: u64, pane: u64, target: u64, scope: control_capability.ScopeClass };
/// 대기 중 grant 확인 FIFO(**메인 스레드 전용**). bounded — max_in_flight와 정렬(연결당 held ≤1). deferRequest가
/// in-flight를 bound하므로 이 큐는 그 미러(항목=held 요청). 서버 drain이 매 tick 결정+resolve.
const GrantPromptQueue = struct {
    items: std.ArrayList(GrantPromptEntry) = .empty,
    max: usize = 8,
    fn push(self: *GrantPromptQueue, gpa: std.mem.Allocator, e: GrantPromptEntry) error{ Full, OutOfMemory }!void {
        if (self.items.items.len >= self.max) return error.Full;
        try self.items.append(gpa, e);
    }
    fn take(self: *GrantPromptQueue) ?GrantPromptEntry {
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }
    fn deinit(self: *GrantPromptQueue, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
    }
};
var grant_prompt_queue: GrantPromptQueue = .{};
/// 확인 응답 마감 — 사용자가 모달에 응답할 시간(2b). 2a 스텁은 즉시 결정하나, 이 마감이 reap 안전망(무응답 시 연결 닫힘).
const grant_prompt_timeout_ns: i128 = 120 * std.time.ns_per_s;

/// hello가 광고하는 현재 라이브 메서드(§4.1). browser method가 추가될 때 parseBrowserMethod와 함께 갱신하며, 아래
/// 테스트가 모든 browser 항목이 실제 parser에 존재하는지와 `browser.wait` 발견성을 고정한다.
const control_hello_caps = [_][]const u8{
    "sessions.list",
    "session.get",
    "browser.navigate",
    "browser.getUrl",
    "browser.executeScript",
    "browser.subscribe",
    "browser.getCookies",
    "browser.screenshot",
    "browser.setCookie",
    "browser.deleteCookie",
    "browser.getLocalStorage",
    "browser.setLocalStorage",
    "browser.removeLocalStorage",
    "browser.clearStorage",
    "browser.click",
    "browser.type",
    "browser.scroll",
    "browser.wait",
};
const control_hello_version = "0.1.0";
/// 한 drain(tick)에서 처리할 요청 상한(§5 per-tick 예산). accept 스레드 1개·in-flight ≤1이라 실질 여유.
const control_drain_budget: usize = 32;

fn appHostIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// 결정론 컨트롤 base dir `<cache>/maru`(§4.2)를 buf에 NUL 종단으로 만든다. XDG_CACHE_HOME 우선, 없으면 HOME/.cache.
/// 못 정하면 null. Server.bind가 `<base>/control`을 mkdir하므로 caller(start)가 `<base>`까지 존재를 보장한다.
fn controlBaseDir(buf: []u8) ?[:0]u8 {
    if (std.c.getenv("XDG_CACHE_HOME")) |x| {
        const xs = std.mem.span(x);
        if (xs.len > 0) return std.fmt.bufPrintZ(buf, "{s}/maru", .{std.mem.trimEnd(u8, xs, "/")}) catch null;
    }
    const home = std.c.getenv("HOME") orelse return null;
    const hs = std.mem.span(home);
    if (hs.len == 0) return null;
    return std.fmt.bufPrintZ(buf, "{s}/.cache/maru", .{std.mem.trimEnd(u8, hs, "/")}) catch null;
}

/// 인스턴스 nonce(§4.2 "부팅 nonce") — 파일명 유일성용(암호 비밀 아님). macOS arc4random_buf로 8바이트 채운다.
fn instanceNonce() u64 {
    var bytes: [8]u8 = undefined;
    std.c.arc4random_buf(&bytes, bytes.len);
    return std.mem.readInt(u64, &bytes, .little);
}

/// 살아있는 세션들(refs)을 창마다 `collectSessionInto`로 평탄화해 하나의 CollectorSnapshot으로 조립한다(§2). 스냅샷은
/// `arena` 메모리를 빌린다(caller가 arena 수명 관리). app_session=NULL 항목은 건너뛴다. 순수 조립 — 테스트가 실 AppSession으로 커버.
fn collectSessionsInto(refs: []const ControlSessionRef, arena: std.mem.Allocator) std.mem.Allocator.Error!control_surface.CollectorSnapshot {
    var surfaces: std.ArrayList(control_surface.SurfaceDto) = .empty;
    var windows: std.ArrayList(maru.session.WindowMembershipSnapshot) = .empty;
    for (refs) |ref| {
        const app = ref.app_session orelse continue;
        const kind = std.enums.fromInt(maru.session.WindowKind, ref.window_kind) orelse .normal;
        try app.collectSessionInto(arena, ref.window_id, kind, &surfaces, &windows);
    }
    return .{ .surfaces = surfaces.items, .windows = windows.items };
}

/// 한 요청을 실 collector + auth(1e capability) + dispatch(1d)로 처리해 응답 바이트(server.cross_gpa 소유)를 만든다.
/// **1e**: `dispatchAuthenticated`가 auth 프레임의 `{selector, cap_nonce}`(pending)와 라이브 `control_cap_store`로
/// `(caller, scope)`를 발급한다 — cap_nonce 없으면 기존 metadata:self(§8.4 A2b, 회귀 없음), 있으면 resolve(빈 store라
/// 지금은 default-deny). **§8.4 self 경로 한계 유지**: nonce 없는 same-uid peer는 임의 surface를 self로 주장할 수 있고
/// tty/pgrp 검증(1g)은 없다 → 그 한 surface의 metadata만(§8.3 self 필터). `now`=**모노토닉 awake 초**(TTL 판정용, 순수
/// 코어에 주입 — 미래 fd 발급도 같은 시계로 expires_at 계산해야 정합; wall-clock 아님, 아래 impl 참조 — 리뷰 [2]).
fn handleControlRequest(
    server: *control_server_mod.ControlServer,
    refs: []const ControlSessionRef,
    pending: *control_server_mod.PendingRequest,
) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit(); // 스냅샷은 dispatch 동안만 필요 — 응답(cross_gpa)은 arena와 독립
    const snapshot = collectSessionsInto(refs, arena.allocator()) catch {
        server.resolveRequest(pending, null); // collect OOM — 응답 없이 종료(accept 무한 대기 방지)
        return;
    };
    // now = 모노토닉 awake 초(TTL 판정 단위). wall-clock보다 clock 변경에 안전하고, 미래 fd 발급도 같은 시계로
    // expires_at을 계산하면 정합한다(코드베이스가 이미 std.Io.Clock.awake를 uptime에 씀). store가 빈 지금은 TTL 미사용.
    const now_ns: i128 = std.Io.Clock.awake.now(appHostIo()).nanoseconds;
    const now: u64 = @intCast(@max(@as(i128, 0), @divFloor(now_ns, std.time.ns_per_s)));
    // 5f-4a-2: 세션 누적 cap 집합(serveConnection이 auth.self+auth.grant로 채운 슬라이스, 연결 스레드 스택 소유·대기 동안 유효).
    const disp = control_dispatch.dispatchAuthenticated(server.cross_gpa, pending.request_bytes, snapshot, pending.selector, pending.cap_nonces, &control_cap_store, &control_pane_grant_store, now) catch {
        server.resolveRequest(pending, null);
        return;
    };
    switch (disp) {
        .immediate => |resp| server.resolveRequest(pending, resp),
        // 5e-2b: 인가·유효한 browser op — §5-async로 defer(즉시 resolve 안 함) + browser op 큐에 enqueue(Swift가 실행).
        .browser => |op| enqueueBrowserOp(server, pending, op, now_ns),
        // 5f-0b-3b: 인가·유효한 browser.subscribe — 메인에서 SubscriberRegistry에 **동기 등록** + `{subscriber_id}` 응답.
        .subscribe => |s| handleSubscribe(server, pending, s),
        // 1e-confirm-2a: 미grant valid 요청 — 확인 수단 있으면 **틱 넘어 붙잡고**(deferRequest) 결정 대기(GrantPrompt 큐),
        //     drainGrantPrompts가 결정 시 grant+재구동 or unauthorized(§9.2 Model B). 수단 없으면 즉시 unauthorized(1c-1).
        .needs_grant => |g| handleNeedsGrant(server, pending, g, now_ns),
    }
}

/// 1e-confirm: grant 확인 **결정 소스**. 2a=env 스텁(`MARU_TEST_GRANT_DECISION=approve|deny`)으로 held 흐름을 스모크
/// 검증. 2b=실 확인 모달이 이 자리를 대체(latch). **env 미설정=`.none`**(확인 수단 없음 → needs_grant를 unauthorized로
/// 접음 = 1c-1 behavior-preserving·프로덕션 무영향 — grant 안 남·요청 안 붙잡음).
const GrantDecision = enum { none, approve, deny };
fn grantDecisionSource() GrantDecision {
    const v = std.c.getenv("MARU_TEST_GRANT_DECISION") orelse return .none;
    const s = std.mem.span(v);
    if (std.mem.eql(u8, s, "approve")) return .approve;
    if (std.mem.eql(u8, s, "deny")) return .deny;
    return .none;
}

/// 1e-confirm-2a/2b: 미grant valid 요청(§9.2 Model B) — **항상 붙잡고**(deferRequest → in-flight, 마감
/// grant_prompt_timeout) GrantPrompt 큐에 넣어 `drainGrantPrompts`가 결정하게 한다(틱 넘어 대기 = 모달이 사용자 응답을
/// 기다림). 결정: env 스텁(스모크)·실 확인 모달(프로덕션)·창 없으면 deny. deferRequest 실패(붙잡기 불가)=unauthorized. **메인 전용**.
fn handleNeedsGrant(
    server: *control_server_mod.ControlServer,
    pending: *control_server_mod.PendingRequest,
    g: control_browser.GrantRequest,
    now_ns: i128,
) void {
    // **항상 붙잡는다**(2b): 결정은 drainGrantPrompts가 한다 — env 스텁(스모크) or 실 확인 모달(프로덕션) or 창 없으면
    // deny. 붙잡고 큐에 넣어 in-flight로 대기(마감 grant_prompt_timeout — 무응답 시 reap=연결 닫힘). deferRequest 실패
    // (TooManyInFlight)=붙잡기 불가 → unauthorized. (1c-1의 "env 없으면 즉시 unauthorized"는 2b서 모달 경로로 대체됨.)
    const async_id = server.deferRequest(pending, now_ns + grant_prompt_timeout_ns) catch {
        const resp = control_browser.serializeUnauthorized(server.cross_gpa, pending.request_bytes) catch null;
        return server.resolveRequest(pending, resp);
    };
    grant_prompt_queue.push(allocator, .{ .async_id = async_id, .pane = g.pane, .target = g.target, .scope = g.scope }) catch {
        // 큐 full(도달 어려움 — max=in-flight 상한) → 붙잡은 in-flight 취소(unauthorized).
        const resp = control_browser.serializeUnauthorized(server.cross_gpa, pending.request_bytes) catch null;
        _ = server.completeInFlight(async_id, resp);
    };
}

/// 1e-confirm-2a: 한 GrantPrompt를 결정에 따라 resolve. **승인** → grant 기록 + 요청 **재-dispatch**(이제 인가) → 라우팅
/// (op=`pushBrowserOp`[**grant async_id 재사용** — 이미 in-flight라 재-defer 금지]·subscribe·immediate=completeInFlight).
/// **거부** → unauthorized. reap된 async_id(마감·무응답)는 `inFlightPending` null → skip(이미 정리됨). **메인 전용**.
fn resolveGrantPrompt(
    server: *control_server_mod.ControlServer,
    e: GrantPromptEntry,
    approved: bool,
    snapshot: control_surface.CollectorSnapshot,
    now: u64,
) void {
    const pending = server.inFlightPending(e.async_id) orelse return; // reaped(마감) — 이미 정리됨
    if (!approved) {
        const resp = control_browser.serializeUnauthorized(server.cross_gpa, pending.request_bytes) catch null;
        _ = server.completeInFlight(e.async_id, resp);
        return;
    }
    control_pane_grant_store.grant(.{ .pane = e.pane, .target = e.target, .scope = e.scope }) catch {
        const resp = control_browser.serializeUnauthorized(server.cross_gpa, pending.request_bytes) catch null;
        _ = server.completeInFlight(e.async_id, resp);
        return;
    };
    // 재-dispatch: grant가 인가 → .browser/.subscribe/.immediate. grant async_id를 그대로 완료 상관자로 재사용.
    const disp2 = control_dispatch.dispatchAuthenticated(server.cross_gpa, pending.request_bytes, snapshot, pending.selector, pending.cap_nonces, &control_cap_store, &control_pane_grant_store, now) catch {
        _ = server.completeInFlight(e.async_id, null);
        return;
    };
    switch (disp2) {
        .immediate => |resp| {
            _ = server.completeInFlight(e.async_id, resp);
        },
        // op은 grant in-flight(e.async_id)를 재사용해 push(재-defer 금지) — op 완료가 이 in-flight를 resolve.
        .browser => |op| {
            const now_ns = std.Io.Clock.awake.now(appHostIo()).nanoseconds;
            if (!server.updateInFlightDeadline(e.async_id, now_ns + browser_op_timeout_ns)) {
                server.cross_gpa.free(op.arg);
                return;
            }
            pushBrowserOp(server, e.async_id, op);
        },
        .subscribe => |s| resolveHeldSubscribe(server, e.async_id, pending, s),
        .needs_grant => {
            // 방어(grant 막 남겨 도달 안 함): grant 루프 방지로 unauthorized.
            const resp = control_browser.serializeUnauthorized(server.cross_gpa, pending.request_bytes) catch null;
            _ = server.completeInFlight(e.async_id, resp);
        },
    }
}

/// 1e-confirm-2a: held 요청의 subscribe 완료 — `handleSubscribe`(resolveRequest)와 달리 **completeInFlight**로 마쳐야
/// in-flight 레지스트리서 제거된다(그냥 resolveRequest면 stale in-flight가 남아 이중 resolve). outbound/registry 실패=null 종료.
fn resolveHeldSubscribe(
    server: *control_server_mod.ControlServer,
    async_id: u64,
    pending: *control_server_mod.PendingRequest,
    s: control_browser.BrowserSubscribe,
) void {
    const outbound = pending.outbound orelse {
        _ = server.completeInFlight(async_id, null);
        return;
    };
    const subscriber_id = server.subscriber_reg.subscribe(s.surface_id, s.filter, outbound) catch {
        _ = server.completeInFlight(async_id, null);
        return;
    };
    const resp = control_browser.serializeSubscribeResponse(server.cross_gpa, pending.request_bytes, subscriber_id) catch null;
    _ = server.completeInFlight(async_id, resp);
}

/// 1e-confirm-2a/2b: 매 tick 대기 grant 확인을 처리(재-dispatch에 collector snapshot 필요라 server_drain이 refs와 호출).
/// **env 스텁 설정 시(스모크·헤드리스)**=모달 없이 즉시 결정(전부). **env 미설정(프로덕션·2b)**=실 확인 모달: 큐 head만
/// 처리(한 번에 한 모달), AppSession에 모달 띄우고 사용자 결정을 폴한다. 큐 비면 snapshot 조립 안 함(핫패스 0-할당).
fn drainGrantPrompts(server: *control_server_mod.ControlServer, refs: []const ControlSessionRef, now: u64) void {
    if (grant_prompt_queue.items.items.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const snapshot = collectSessionsInto(refs, arena.allocator()) catch return; // collect OOM → 다음 tick 재시도(항목 유지)

    // env 스텁(스모크·헤드리스): 설정됐으면 모달 우회 즉시 결정(전부).
    const env = grantDecisionSource();
    if (env != .none) {
        while (grant_prompt_queue.take()) |e| resolveGrantPrompt(server, e, env == .approve, snapshot, now);
        return;
    }

    // 2b 실 모달: head 하나만(한 번에 한 모달). 모달 띄울 AppSession + 사용자 결정 폴.
    const head = grant_prompt_queue.items.items[0];
    // **dedup**(grant UX 경화): 이 (pane, target, scope)가 이미 grant됐으면(중복 요청·직전 결정) **모달 없이 승인 resolve**.
    //   같은 triple 두 요청이 연달아 held되면, 첫 모달 승인이 grant를 남기고 → 둘째는 여기서 짧게 접혀 두 번째 모달이 안 뜬다.
    if (control_pane_grant_store.isGranted(head.pane, head.target, head.scope)) {
        _ = grant_prompt_queue.take();
        return resolveGrantPrompt(server, head, true, snapshot, now);
    }
    // **target-window 모달**(grant UX 경화): 모달을 **대상 web surface를 소유한 창**에 띄운다(멀티창서 엉뚱한 창에
    //   안 뜨게). 대상 surface가 어느 창에도 없으면(닫힘 등) firstAppSession 폴백. 둘 다 없으면(헤드리스) deny.
    const app = (appSessionOwningSurface(refs, head.target) orelse firstAppSession(refs)) orelse {
        // 모달 띄울 창 없음(헤드리스·프로덕션 아님) → deny(hang 방지, reap 대기 없이 즉시).
        _ = grant_prompt_queue.take();
        return resolveGrantPrompt(server, head, false, snapshot, now);
    };
    // (1) 이전 tick에 띄운 모달의 사용자 결정을 폴(있으면 head를 resolve).
    if (app.takeGrantDecision()) |d| {
        if (d.async_id == head.async_id) {
            _ = grant_prompt_queue.take();
            return resolveGrantPrompt(server, head, d.approved, snapshot, now);
        }
        // stale 결정(다른 async_id — 도달 어려움): 무시.
    }
    // (2) 미결정: 모달 표시(idempotent — 이미 이 grant 보여주면 no-op·다른 모달 점유면 false로 다음 tick 재시도).
    var msg_buf: [256]u8 = undefined;
    _ = app.showGrantConfirm(grantPromptMessage(&msg_buf, head, snapshot), head.async_id);
}

/// grant 확인 모달을 띄울 폴백 AppSession — refs 중 첫 non-null 창. `appSessionOwningSurface`가 대상 창을 못 찾을 때
/// (surface 닫힘 등)만 쓰인다. 창 없으면 null(헤드리스).
fn firstAppSession(refs: []const ControlSessionRef) ?*AppSession {
    for (refs) |ref| if (ref.app_session) |app| return app;
    return null;
}

/// grant UX 경화(target-window 모달): `surface_id`(대상 web surface)를 소유한 창의 AppSession. 멀티창에서 모달을
/// **대상이 있는 창**에 띄우려는 것 — 엉뚱한 창에 뜨면 사용자가 어느 브라우저인지 헷갈린다. 없으면 null(호출자가 폴백).
fn appSessionOwningSurface(refs: []const ControlSessionRef, surface_id: u64) ?*AppSession {
    for (refs) |ref| if (ref.app_session) |app| {
        if (app.ownsSurface(surface_id)) return app;
    };
    return null;
}

/// 1e-confirm-2b: 확인 모달 메시지(scope별 + target URL). 세션 소유 버퍼로 복사되므로(showGrantConfirm→copyOverlayMessage)
/// 여기선 transient 스택 버퍼. browser=제어·browser_storage=쿠키/스토리지 읽기(로그인 토큰) 구분. URL은 snapshot서 조회.
fn grantPromptMessage(buf: []u8, e: GrantPromptEntry, snapshot: control_surface.CollectorSnapshot) []const u8 {
    const url: []const u8 = if (snapshot.find(e.target)) |dto| (switch (dto.detail) {
        .web => |w| w.url orelse "", // WebMeta.url은 ?[]const u8(로드 전 null)
        else => "",
    }) else "";
    // **표시 문자열이라 키로 든다.** 이 문장은 로그인 토큰 접근을 묻는 동의문인데, 버튼은 이미
    // 번역돼 있어(`btn_allow`/`btn_deny`) 여기만 한국어면 영어 UI 아래에서 무엇을 허용하는지 못 읽는다.
    const action = maru.i18n.t(switch (e.scope) {
        .browser_storage => .grant_scope_storage,
        else => .grant_scope_control,
    });
    return maru.i18n.format(buf, maru.i18n.t(.grant_prompt), &.{ .{ .s = action }, .{ .s = url } });
}

/// 5f-0b-3b: 인가·유효한 `browser.subscribe`를 메인에서 즉시 처리한다(async 아님). 연결 outbound(pending에 실림)를
/// SubscriberRegistry에 등록하고 subscriber_id를 응답한다. outbound null(직접 구성 등 비정상)·registry OOM은 응답 없이
/// resolve(null)로 연결 종료(§5-async null 계약과 동형 — accept 무한 대기 방지). **메인 스레드 전용**(registry=leaf-mutex).
fn handleSubscribe(
    server: *control_server_mod.ControlServer,
    pending: *control_server_mod.PendingRequest,
    s: control_browser.BrowserSubscribe,
) void {
    const outbound = pending.outbound orelse return server.resolveRequest(pending, null); // 라이브는 serveConnection이 항상 세팅
    const subscriber_id = server.subscriber_reg.subscribe(s.surface_id, s.filter, outbound) catch
        return server.resolveRequest(pending, null); // registry OOM → null(연결 닫힘, 기존 관례)
    const resp = control_browser.serializeSubscribeResponse(server.cross_gpa, pending.request_bytes, subscriber_id) catch null;
    server.resolveRequest(pending, resp);
}

/// 5e-2b: 인가·유효한 browser op을 §5-async `deferRequest`(pending 붙잡음) + browser op 큐에 enqueue(Swift가 매 tick
/// take_browser_op으로 drain해 `BrowserControl` 실행 → complete_browser_op). deferRequest/큐 실패는 op.arg 해제 +
/// 에러 응답으로 즉시 resolve(누수·accept 무한 대기 방지). 성공 시 op.arg 소유권은 큐가 인수(take/deinit이 free).
fn enqueueBrowserOp(
    server: *control_server_mod.ControlServer,
    pending: *control_server_mod.PendingRequest,
    op: control_browser.BrowserOp,
    now_ns: i128,
) void {
    const async_id = server.deferRequest(pending, now_ns + browser_op_timeout_ns) catch {
        server.cross_gpa.free(op.arg);
        const resp = control_browser.serializeBrowserResponse(server.cross_gpa, pending.request_bytes, false, "browser op queue full") catch null;
        server.resolveRequest(pending, resp);
        return;
    };
    pushBrowserOp(server, async_id, op);
}

/// 5e-2b/1e-confirm-2a: **이미 defer된** in-flight `async_id`로 op을 큐에 push한다(deferRequest 없이 — grant held 요청은
/// 이미 in-flight라 재-defer하면 이중 등록). enqueueBrowserOp(신규 defer) + resolveGrantPrompt(grant async_id 재사용)
/// 공용. 큐 실패=op.arg 해제 + completeInFlight(async_id, null)(그 in-flight 취소·연결 닫힘). op.arg 소유권은 큐가 인수.
fn pushBrowserOp(
    server: *control_server_mod.ControlServer,
    async_id: u64,
    op: control_browser.BrowserOp,
) void {
    const backend_arg = op.arg;
    if (browserMethodHasTrackedLifecycle(op.method)) {
        const provenance: ExecutionProvenance = if (op.pane_grant) |g|
            .{ .pane_grant = g }
        else if (op.capability_nonce) |nonce|
            if (op.capability_generation) |generation|
                .{ .capability = .{ .nonce = nonce, .generation = generation } }
            else {
                server.cross_gpa.free(op.arg);
                const pending = server.inFlightPending(async_id) orelse return;
                const resp = control_browser.serializeUnauthorized(server.cross_gpa, pending.request_bytes) catch null;
                _ = server.completeInFlight(async_id, resp);
                return;
            }
        else {
            server.cross_gpa.free(op.arg);
            const pending = server.inFlightPending(async_id) orelse return;
            const resp = control_browser.serializeUnauthorized(server.cross_gpa, pending.request_bytes) catch null;
            _ = server.completeInFlight(async_id, resp);
            return;
        };
        active_browser_executions.admit(allocator, .{
            .async_id = async_id,
            .surface_id = op.surface_id,
            .method = op.method,
            .reserved_bytes = browserMethodReservedBytes(op.method, op.max_result_bytes),
            .provenance = provenance,
        }) catch |err| {
            server.cross_gpa.free(op.arg);
            const pending = server.inFlightPending(async_id) orelse return;
            const resp = if (err == error.ResourceBusy or err == error.ExecutionSlotsFull)
                control_browser.serializeResourceBusy(server.cross_gpa, pending.request_bytes, if (err == error.ExecutionSlotsFull) "browser-execution-slots" else "browser-result-bytes") catch null
            else
                null;
            _ = server.completeInFlight(async_id, resp);
            return;
        };
        // executeScript arg는 L2가 이미 `{script,args,max_result_bytes}` owned JSON으로 직렬화했다. 여기서 다시
        // 감싸면 args를 잃거나 사용자 script를 이중 escape하므로 ABI queue가 그대로 인수한다.
    }
    if (op.method == .wait) {
        active_browser_waits.append(allocator, .{
            .async_id = async_id,
            .surface_id = op.surface_id,
            .pane_grant = op.pane_grant,
        }) catch {
            server.cross_gpa.free(op.arg);
            _ = server.completeInFlight(async_id, null);
            return;
        };
    }
    browser_op_queue.push(allocator, .{ .async_id = async_id, .surface_id = op.surface_id, .op_kind = @intFromEnum(op.method), .arg = backend_arg }) catch {
        if (op.method == .wait) _ = removeActiveBrowserWait(async_id);
        if (browserMethodHasTrackedLifecycle(op.method)) _ = active_browser_executions.finish(async_id);
        server.cross_gpa.free(backend_arg);
        _ = server.completeInFlight(async_id, null); // deferred pending 취소(응답 없이 연결 닫힘)
    };
}

pub export fn maru_macos_control_server_start() c_int {
    // 비-macOS: 라이브 서버 없음(1b/A2b는 macOS 전용 — 소켓 부트스트랩이 fstatat/arc4random_buf 등 macOS syscall에
    // 의존). comptime-true 조기 반환이 뒤 macOS 바디(Server.bind·instanceNonce)를 linux 컴파일에서 prune한다
    // (live_pty.zig:298 선례). Linux/Win 이식 시 OS-중립 부트스트랩으로 대체.
    if (builtin.os.tag != .macos) return @intFromEnum(Status.create_failed);
    if (control_server_active) return @intFromEnum(Status.ok); // idempotent
    var base_buf: [1024]u8 = undefined;
    const base = controlBaseDir(&base_buf) orelse return @intFromEnum(Status.create_failed);
    // <base>(<cache>/maru) 존재 보장(Server.bind는 <base>/control만 mkdir). 부모(<cache>)도 best-effort mkdir.
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |slash| {
        if (slash > 0) {
            base_buf[slash] = 0; // 부모 경로로 임시 절단
            _ = std.c.mkdir(@ptrCast(base_buf[0..slash].ptr), 0o700);
            base_buf[slash] = '/'; // 복원
        }
    }
    _ = std.c.mkdir(base.ptr, 0o700);

    var key_buf: [64]u8 = undefined;
    const key = control_socket.formatInstanceKey(&key_buf, std.c.getpid(), instanceNonce()) catch return @intFromEnum(Status.create_failed);

    control_server_storage.start(
        appHostIo(),
        allocator, // cross_gpa: smp_allocator는 thread-safe(요청/응답 cross-thread)
        allocator, // items/socket alloc
        base,
        key,
        control_hello_version,
        &control_hello_caps,
        16, // max_pending(5f-0b-2a 연결당 스레드로 최대 max_connections=16개 동시 push 가능 → queue 용량 = 그 이상)
    ) catch |e| {
        if (std.c.getenv("MARU_DEBUG") != null) std.debug.print("[maru control] start failed base={s} key={s} err={s}\n", .{ base, key, @errorName(e) });
        return @intFromEnum(Status.create_failed);
    };
    control_server_active = true;
    return @intFromEnum(Status.ok);
}

/// #4 값싼 per-tick 게이트: 대기 중인 컨트롤 요청 **또는 held grant 확인**이 있으면 1, 없으면 0. Swift가 매 tick `drain`
/// 전에 이걸 봐 없으면 refs 배열(힙 할당 + 창별 copy)을 **아예 짓지 않고** early return한다(렌더 핫패스 0-할당). 서버
/// 미시작이면 0. `take_bell` 등 predicate와 같은 u32(1/0) 패턴 — bool은 .h에 stdbool을 끌어들이고 codebase 관례와도
/// 어긋난다. (ABI 신규 export — 버전 bump 없음, drain과 동일 no-handle. 짧은 큐 락만 잡는다.)
///
/// **1e-confirm-2b**: 요청이 needs_grant로 held(in-flight)되면 요청 큐에서 빠지지만, `drainGrantPrompts`가 매 tick
/// 모달 결정을 폴해야 하므로 **grant_prompt_queue 비어있지 않으면 계속 1** — 안 그러면 요청 held 후 server_drain이 안 불려
/// 모달 클릭 결과를 영영 못 읽는다(승인해도 무반응 버그). grant는 메인 스레드 전용이라 락 불요(요청 큐만 락).
pub export fn maru_macos_control_server_has_pending() u32 {
    if (!control_server_active) return 0;
    if (grant_prompt_queue.items.items.len > 0) return 1; // held grant 확인 대기 — server_drain(drainGrantPrompts) 계속 돌게
    return if (control_server_storage.hasPendingRequest()) 1 else 0;
}

pub export fn maru_macos_control_server_drain(refs_ptr: ?[*]const ControlSessionRef, count: usize) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    const refs: []const ControlSessionRef = if (refs_ptr) |p| p[0..count] else &.{};
    var handled: usize = 0;
    while (handled < control_drain_budget) : (handled += 1) {
        const pending = server.tryPopRequest() orelse break;
        // 팝한 pending은 **반드시** resolve 또는 defer(browser op·grant 확인)해야 accept 스레드가 무한 대기하지 않는다.
        handleControlRequest(server, refs, pending);
    }
    // 1e-confirm-2a: 위 요청 처리가 큐에 넣은 held grant 확인을 결정+resolve(재-dispatch snapshot=refs). 큐 비면 0-할당.
    const now_ns = std.Io.Clock.awake.now(appHostIo()).nanoseconds;
    const now: u64 = @intCast(@max(@as(i128, 0), @divFloor(now_ns, std.time.ns_per_s)));
    drainGrantPrompts(server, refs, now);
}

fn expireActiveBrowserExecutions(server: *control_server_mod.ControlServer, now_ns: i128) void {
    var expired_ids: [8]u64 = undefined;
    const expired = server.expiredInFlightIds(now_ns, &expired_ids);
    for (expired_ids[0..expired]) |id| {
        if (active_browser_executions.get(id) == null) continue;
        // queued timeout도 close/revoke와 같은 공통 취소 경로를 써서 client terminal뿐 아니라 물리 queue entry와 arg를
        // 같은 tick에 회수한다. running/transfer는 기존대로 backend terminal까지 tombstone/예약을 유지한다.
        cancelActiveBrowserExecution(server, id, .timeout);
    }
}

fn queuedExecutionReady(server: *control_server_mod.ControlServer, async_id: u64, now: u64) bool {
    const execution = active_browser_executions.get(async_id) orelse return false;
    return execution.phase == .queued and server.inFlightPending(async_id) != null and browserExecutionAuthorized(execution, now);
}

fn rejectUnreadyBrowserExecution(server: *control_server_mod.ControlServer, async_id: u64, now: u64) void {
    const execution = active_browser_executions.get(async_id) orelse return;
    // pending은 살아 있지만 authority만 사라진 queued op이면 timeout까지 매달지 않고 즉시 typed unauthorized로 끝낸다.
    // close/revoke가 이미 client terminal을 commit했거나 pending reap가 먼저면 abandon은 queued slot만 정리한다.
    if (execution.phase == .queued and server.inFlightPending(async_id) != null and !browserExecutionAuthorized(execution, now)) {
        cancelActiveBrowserExecution(server, async_id, .unauthorized);
    } else {
        active_browser_executions.abandon(async_id);
    }
}

fn browserExecutionAuthorized(execution: *const ActiveBrowserExecution, now: u64) bool {
    const method = browserMethodWireName(execution.method);
    return switch (execution.provenance) {
        .capability => |identity| if (control_cap_store.lookupByNonce(identity.nonce)) |cap|
            control_capability.authorize(cap, execution.surface_id, identity.generation, method, now) == .granted
        else
            false,
        .pane_grant => |g| control_capability.methodRequiredScope(method) == g.scope and
            control_pane_grant_store.isGranted(g.pane, g.target, g.scope),
    };
}

/// 5e-2b: Swift가 매 tick 호출 — (1) `reapExpiredInFlight`(hung browser op timeout), (2) browser op 큐에서 하나 pop해
/// out으로 넘긴다. 반환 1=op 있음(Swift가 surface_id로 webView 찾아 `BrowserControl`[op_kind] 실행 → 완료 시
/// `complete_browser_op`)·0=없음. `op_kind`: 0=navigate·1=getUrl·2=executeScript·4=getCookies(5f-4c)·5=screenshot(5f-1)·6=setCookie·7=deleteCookie·8=getLocalStorage·9=setLocalStorage·10=removeLocalStorage·11=clearStorage·12=click·13=type·14=scroll·15=wait·16=snapshot(§9.5.4)·17=console(§9.5.9). `arg_ptr`는 안정 슬롯
/// (`browser_op_take_buf`)을 가리켜 **이 호출 중 동기 읽기**만 유효(다음 take가 덮어씀 — Swift가 즉시 복사). 서버
/// 미시작이면 0. **메인 스레드 전용**(reap·pop·in-flight 레지스트리는 메인).
pub export fn maru_macos_control_take_browser_op(
    out_async_id: ?*u64,
    out_surface_id: ?*u64,
    out_op_kind: ?*u8,
    out_arg_ptr: ?*?[*]const u8,
    out_arg_len: ?*usize,
) u32 {
    if (!control_server_active) return 0;
    const server = &control_server_storage;
    // §5-async reap: 매 tick hung op timeout(evaluateJavaScript/navigation/wait가 안 끝나는 op가 accept를 영구 붙잡는 것 방어).
    const now_ns = std.Io.Clock.awake.now(appHostIo()).nanoseconds;
    const now: u64 = @intCast(@max(@as(i128, 0), @divFloor(now_ns, std.time.ns_per_s)));
    expireActiveBrowserExecutions(server, now_ns);
    var reaped_ids: [8]u64 = undefined;
    const reaped = server.reapExpiredInFlightIds(now_ns, &reaped_ids);
    for (reaped_ids[0..@min(reaped, reaped_ids.len)]) |id| active_browser_executions.abandon(id);
    pruneInactiveBrowserWaits(server);
    const e: BrowserOpEntry = while (browser_op_queue.take()) |candidate| {
        // revoke/close/reap가 Swift drain 전에 wait를 끝냈다면 큐의 늦은 엔트리를 실행하지 않는다.
        if (candidate.op_kind == @intFromEnum(control_browser.BrowserMethod.wait) and !activeBrowserWait(candidate.async_id)) {
            server.cross_gpa.free(candidate.arg);
            continue;
        }
        const method: control_browser.BrowserMethod = @enumFromInt(candidate.op_kind);
        if (browserMethodHasTrackedLifecycle(method)) {
            if (!queuedExecutionReady(server, candidate.async_id, now)) {
                rejectUnreadyBrowserExecution(server, candidate.async_id, now);
                server.cross_gpa.free(candidate.arg);
                continue;
            }
        }
        break candidate;
    } else return 0;
    // arg를 안정 슬롯에 복사(Swift가 이 호출 중 동기 읽음), 엔트리 arg(cross_gpa) 해제.
    browser_op_take_buf.clearRetainingCapacity();
    browser_op_take_buf.appendSlice(allocator, e.arg) catch {
        server.cross_gpa.free(e.arg);
        const method: control_browser.BrowserMethod = @enumFromInt(e.op_kind);
        if (browserMethodHasTrackedLifecycle(method)) {
            _ = active_browser_executions.finish(e.async_id);
            _ = server.completeInFlight(e.async_id, null);
        }
        return 0;
    };
    server.cross_gpa.free(e.arg);
    const method: control_browser.BrowserMethod = @enumFromInt(e.op_kind);
    if (browserMethodHasTrackedLifecycle(method) and !active_browser_executions.markRunning(e.async_id)) return 0;
    if (out_async_id) |p| p.* = e.async_id;
    if (out_surface_id) |p| p.* = e.surface_id;
    if (out_op_kind) |p| p.* = e.op_kind;
    if (out_arg_ptr) |p| p.* = if (browser_op_take_buf.items.len > 0) browser_op_take_buf.items.ptr else null;
    if (out_arg_len) |p| p.* = browser_op_take_buf.items.len;
    return 1;
}

/// 5e-2b: Swift `BrowserControl` async 완료 콜백이 호출 — `async_id`의 in-flight 요청을 결과로 응답한다. `status`:
/// status는 `control_browser.BrowserCompletionStatus` 숫자 계약. `result`: method별(getUrl=url·executeScript=반환값
/// 문자열·navigate=무시; error면 message). 미지/reap된 async_id는 무시(늦은 콜백 — inFlightPending null). **메인 스레드
/// 전용**(WKWebView 콜백이 메인). serializeBrowserResponse가 pending.request_bytes 재파싱해 id·method로 응답 직렬화.
pub export fn maru_macos_control_complete_browser_op(async_id: u64, status: u32, result_ptr: ?[*]const u8, result_len: usize) void {
    if (active_browser_executions.get(async_id)) |execution| {
        // stop은 queued만 비우고 running은 server와 독립된 abandoned tombstone으로 남긴다. inactive callback은
        // deinit된 server를 만지지 않고 backend terminal로 예약만 반환한다.
        if (!control_server_active) {
            _ = active_browser_executions.finish(async_id);
            return;
        }
        const server = &control_server_storage;
        if (execution.phase == .abandoned) {
            _ = active_browser_executions.finish(async_id);
            return;
        }
        // result registry가 소유권을 인수한 뒤 도착한 상호 배타 generic callback은 기존 stream을 끝낼 수 없다.
        if (execution.phase == .transferring) return;
        const pending = server.inFlightPending(async_id) orelse {
            _ = active_browser_executions.finish(async_id);
            return;
        };
        const now_ns = std.Io.Clock.awake.now(appHostIo()).nanoseconds;
        const now: u64 = @intCast(@max(@as(i128, 0), @divFloor(now_ns, std.time.ns_per_s)));
        const authorized = browserExecutionAuthorized(execution, now);
        const completion = if (authorized)
            (std.enums.fromInt(control_browser.BrowserCompletionStatus, status) orelse .failed)
        else
            .unauthorized;
        const result: []const u8 = if (result_ptr) |p| p[0..result_len] else &.{};
        const resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, completion, if (authorized) result else "") catch null;
        _ = active_browser_executions.finish(async_id);
        _ = server.completeInFlight(async_id, resp);
        return;
    }
    if (!control_server_active) return;
    const server = &control_server_storage;
    const result: []const u8 = if (result_ptr) |p| p[0..result_len] else &.{};
    const pending = server.inFlightPending(async_id) orelse return; // 늦은/미지 콜백 — 무시
    _ = removeActiveBrowserWait(async_id); // wait 아니면 no-op. 늦은 timer는 is_active=0을 보고 멈춘다.
    // 5f-1: screenshot 완료는 단일 응답이 아니라 **chunk-streaming**(§9.5.7) — `result`=raw PNG 바이트. 감지해 chunk 경로로.
    if (control_browser.isScreenshotRequest(server.cross_gpa, pending.request_bytes)) {
        completeScreenshotOp(server, async_id, pending, status, result);
        return;
    }
    const completion = std.enums.fromInt(control_browser.BrowserCompletionStatus, status) orelse .failed;
    const resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, completion, result) catch null;
    _ = server.completeInFlight(async_id, resp); // found → resolve(resp)(accept 스레드가 write 후 free)
}

const BrowserResultCopyFn = *const fn (?*anyopaque, u64, u64, ?[*]u8, usize) callconv(.c) i64;
const BrowserResultReleaseFn = *const fn (?*anyopaque, u64) callconv(.c) u32;

/// 이미 active transfer가 있는 async_id로 중복 callback이 오면 기존 stream 소유권을 보존한다. 같은 source는 이미
/// 인수한 것이므로 consumed=1, 다른 source는 그 새 Data만 release하고 기존 execution/pending을 건드리지 않는다.
fn consumeDuplicateBrowserResult(
    async_id: u64,
    transfer_id: u64,
    context: ?*anyopaque,
    copy_result: BrowserResultCopyFn,
    release_result: BrowserResultReleaseFn,
) ?u32 {
    const index = active_browser_transfers.indexOf(async_id) orelse return null;
    const active = active_browser_transfers.items.items[index];
    if (active.source_id == transfer_id and active.context == context and active.copy_result == copy_result and active.release_result == release_result) return 1;
    const status = release_result(context, transfer_id);
    return if (status == 1 or status == 2) 1 else 0;
}

fn releaseBrowserResultAndFinishExecution(
    async_id: u64,
    transfer_id: u64,
    context: ?*anyopaque,
    release_result: BrowserResultReleaseFn,
) bool {
    const status = release_result(context, transfer_id);
    if (status == 1 or status == 2) {
        _ = active_browser_executions.finish(async_id);
        return true;
    }
    // Provider가 Data 제거를 확인하지 못하면 caller의 동기 fallback까지 예약 tombstone을 유지한다.
    if (active_browser_executions.get(async_id)) |execution| execution.phase = .release_pending;
    return false;
}

fn copyBrowserResultExact(
    context: ?*anyopaque,
    transfer_id: u64,
    copy_result: BrowserResultCopyFn,
    source_offset: usize,
    destination: []u8,
) bool {
    var offset: usize = 0;
    while (offset < destination.len) {
        const copied = copy_result(
            context,
            transfer_id,
            source_offset + offset,
            destination[offset..].ptr,
            destination.len - offset,
        );
        if (copied <= 0) return false;
        const copied_len: usize = @intCast(copied);
        if (copied_len > destination.len - offset) return false;
        offset += copied_len;
    }
    return true;
}

/// Swift가 registry per-entry cap 초과 Data를 먼저 폐기한 뒤 실제 길이만 알린다. result bytes를 Zig로 복사하지 않고
/// request별 논리 상한 오류를 만든다.
pub export fn maru_macos_control_complete_browser_result_too_large(async_id: u64, observed_len: usize) void {
    const execution = active_browser_executions.get(async_id) orelse return;
    if (execution.phase == .transferring) return;
    if (!control_server_active or execution.phase == .abandoned) {
        _ = active_browser_executions.finish(async_id);
        return;
    }
    const server = &control_server_storage;
    const pending = server.inFlightPending(async_id) orelse {
        _ = active_browser_executions.finish(async_id);
        return;
    };
    const now_ns = std.Io.Clock.awake.now(appHostIo()).nanoseconds;
    const now: u64 = @intCast(@max(@as(i128, 0), @divFloor(now_ns, std.time.ns_per_s)));
    const resp = if (browserExecutionAuthorized(execution, now))
        control_browser.serializeExecuteScriptObservedTooLarge(server.cross_gpa, pending.request_bytes, observed_len) catch null
    else
        control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .unauthorized, "") catch null;
    _ = active_browser_executions.finish(async_id);
    _ = server.completeInFlight(async_id, resp);
}

/// executeScript page/native 진단 terminal. payload는 page/Swift에서 bounded되지만 Zig가 schema·24 KiB payload·32 KiB
/// 최종 frame을 다시 검증한 뒤 stable `script-error(-32006)`로 직렬화한다.
pub export fn maru_macos_control_complete_browser_script_error(async_id: u64, error_json_ptr: ?[*]const u8, error_json_len: usize) void {
    const execution = active_browser_executions.get(async_id) orelse return;
    if (execution.phase == .transferring) return;
    if (!control_server_active or execution.phase == .abandoned) {
        _ = active_browser_executions.finish(async_id);
        return;
    }
    const server = &control_server_storage;
    const pending = server.inFlightPending(async_id) orelse {
        _ = active_browser_executions.finish(async_id);
        return;
    };
    const now_ns = std.Io.Clock.awake.now(appHostIo()).nanoseconds;
    const now: u64 = @intCast(@max(@as(i128, 0), @divFloor(now_ns, std.time.ns_per_s)));
    const payload: []const u8 = if (error_json_ptr) |p| p[0..error_json_len] else &.{};
    const resp = if (browserExecutionAuthorized(execution, now))
        control_browser.serializeExecuteScriptScriptError(server.cross_gpa, pending.request_bytes, payload) catch null
    else
        control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .unauthorized, "") catch null;
    _ = active_browser_executions.finish(async_id);
    _ = server.completeInFlight(async_id, resp);
}

/// executeScript success 전용 Swift-owned Data 등록. inline은 이 호출에서 pull/release하고, 512 KiB 초과는
/// progressive registry가 source ID를 인수해 이후 tick pump가 release한다. 반환 1은 "인수 또는 release 완료"다.
pub export fn maru_macos_control_complete_browser_result(
    async_id: u64,
    transfer_id: u64,
    total_len: usize,
    context: ?*anyopaque,
    copy_result: BrowserResultCopyFn,
    release_result: BrowserResultReleaseFn,
) u32 {
    if (transfer_id == 0) return 0;
    if (consumeDuplicateBrowserResult(async_id, transfer_id, context, copy_result, release_result)) |consumed| return consumed;

    const execution = active_browser_executions.get(async_id) orelse {
        const status = release_result(context, transfer_id);
        return if (status == 1 or status == 2) 1 else 0;
    };
    if (!control_server_active or execution.phase == .abandoned) {
        return if (releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result)) 1 else 0;
    }
    const server = &control_server_storage;
    const pending = server.inFlightPending(async_id) orelse {
        return if (releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result)) 1 else 0;
    };
    const now_ns = std.Io.Clock.awake.now(appHostIo()).nanoseconds;
    const now: u64 = @intCast(@max(@as(i128, 0), @divFloor(now_ns, std.time.ns_per_s)));
    if (!browserExecutionAuthorized(execution, now)) {
        const resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .unauthorized, "") catch null;
        const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
        _ = server.completeInFlight(async_id, resp);
        return if (released) 1 else 0;
    }
    if (total_len > execution.reserved_bytes) {
        // §9.5.10: executeScript는 자기 max_result_bytes를 싣는 기존 serializer 유지(byte-identical), snapshot/console은
        // method-generic too-large(limit=reserved). error envelope는 필드 없어 method-중립.
        const resp = (if (execution.method == .execute_script)
            control_browser.serializeExecuteScriptObservedTooLarge(server.cross_gpa, pending.request_bytes, total_len)
        else
            control_browser.serializeBrowserResultTooLarge(server.cross_gpa, pending.request_bytes, execution.reserved_bytes, total_len)) catch null;
        const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
        _ = server.completeInFlight(async_id, resp);
        return if (released) 1 else 0;
    }
    if (!active_browser_executions.beginTransfer(async_id, transfer_id, total_len)) {
        const resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .failed, "browser result transfer state invalid") catch null;
        const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
        _ = server.completeInFlight(async_id, resp);
        return if (released) 1 else 0;
    }
    if (total_len > control_browser.execute_script_inline_max_result_bytes) {
        const result_id = active_browser_transfers.issueResultId() orelse {
            const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
            _ = server.completeInFlight(async_id, null);
            return if (released) 1 else 0;
        };
        const seq_total = std.math.divCeil(usize, total_len, control_browser.execute_script_chunk_bytes) catch unreachable;
        const terminal_frame = control_browser.serializeExecuteScriptChunkedComplete(server.cross_gpa, pending.request_bytes, result_id, seq_total, total_len) catch {
            const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
            _ = server.completeInFlight(async_id, null);
            return if (released) 1 else 0;
        };
        const deadline = std.Io.Clock.awake.now(appHostIo()).nanoseconds + browser_op_timeout_ns;
        const progress = control_result.BrowserResultTransfer.init(result_id, total_len, deadline) catch unreachable;
        active_browser_transfers.admit(allocator, .{
            .async_id = async_id,
            .connection_id = pending.connection_id,
            .result_id = result_id,
            .source_id = transfer_id,
            .context = context,
            .copy_result = copy_result,
            .release_result = release_result,
            .progress = progress,
            .terminal = terminal_frame,
            // §9.5.10: kind가 pump의 chunk 메서드를 정한다(executeScript↔snapshot↔console). screenshot은 별도 complete 경로라 여기 안 옴.
            .kind = switch (execution.method) {
                .snapshot => .snapshot,
                .console => .console,
                else => .execute_script,
            },
        }) catch {
            server.cross_gpa.free(terminal_frame);
            const resp = control_browser.serializeResourceBusy(server.cross_gpa, pending.request_bytes, "browser-transfer-slots") catch null;
            const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
            _ = server.completeInFlight(async_id, resp);
            return if (released) 1 else 0;
        };
        _ = server.updateInFlightDeadline(async_id, deadline);
        return 1;
    }

    const result = server.cross_gpa.alloc(u8, total_len) catch {
        const resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .failed, "browser result allocation failed") catch null;
        const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
        _ = server.completeInFlight(async_id, resp);
        return if (released) 1 else 0;
    };
    defer server.cross_gpa.free(result);
    @memset(result, 0);
    const copy_failed = !copyBrowserResultExact(context, transfer_id, copy_result, 0, result);
    var resp = if (copy_failed)
        control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .failed, "browser result copy failed") catch null
    else
        control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .success, result) catch null;
    // live enqueue 직전 auth를 다시 판정한다. 메인 스레드 전용이라 이 판정과 direct outbound push 사이에 revoke가
    // 끼어들 수 없고, typed terminal은 같은 queue의 byte accounting을 거친다.
    const enqueue_now_ns = std.Io.Clock.awake.now(appHostIo()).nanoseconds;
    const enqueue_now: u64 = @intCast(@max(@as(i128, 0), @divFloor(enqueue_now_ns, std.time.ns_per_s)));
    if (!browserExecutionAuthorized(execution, enqueue_now)) {
        if (resp) |wire| server.cross_gpa.free(wire);
        resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .unauthorized, "") catch null;
    }
    const release_status = release_result(context, transfer_id);
    if (release_status != 1 and release_status != 2) {
        if (resp) |wire| server.cross_gpa.free(wire);
        execution.phase = .release_pending;
        return 0;
    }
    _ = active_browser_executions.finish(async_id);
    const outbound = pending.outbound orelse {
        _ = server.completeInFlight(async_id, resp);
        return 1;
    };
    const wire = resp orelse {
        _ = server.completeInFlight(async_id, null);
        return 1;
    };
    // inline payload는 최대 512 KiB라 64 KiB terminal carve-out을 쓰지 않고 일반 byte budget에 넣는다.
    outbound.push(server.cross_gpa, .{ .bytes = wire, .purge_key = .{ .browser_request = async_id } }) catch {
        server.cross_gpa.free(wire);
        _ = server.abortInFlightConnection(async_id);
        _ = server.completeInFlight(async_id, null);
        return 1;
    };
    _ = server.completeInFlightEnqueued(async_id);
    return 1;
}

/// screenshot PNG Data를 executeScript와 같은 Swift registry/pump로 넘긴다. 12 MiB 논리 상한과 PNG IHDR을
/// registration 시 확인하고, callback 반환 뒤에는 raw pointer를 보존하지 않는다.
pub export fn maru_macos_control_complete_browser_screenshot_result(
    async_id: u64,
    transfer_id: u64,
    total_len: usize,
    context: ?*anyopaque,
    copy_result: BrowserResultCopyFn,
    release_result: BrowserResultReleaseFn,
) u32 {
    if (transfer_id == 0) return 0;
    if (consumeDuplicateBrowserResult(async_id, transfer_id, context, copy_result, release_result)) |consumed| return consumed;
    const execution = active_browser_executions.get(async_id) orelse {
        const status = release_result(context, transfer_id);
        return if (status == 1 or status == 2) 1 else 0;
    };
    if (!control_server_active or execution.phase == .abandoned) {
        return if (releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result)) 1 else 0;
    }
    const server = &control_server_storage;
    const pending = server.inFlightPending(async_id) orelse
        return if (releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result)) 1 else 0;
    if (total_len > control_browser.screenshot_max_result_bytes or total_len < 24 or total_len > execution.reserved_bytes) {
        const resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .failed, "screenshot too large or invalid") catch null;
        const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
        _ = server.completeInFlight(async_id, resp);
        return if (released) 1 else 0;
    }
    var header: [24]u8 = undefined;
    if (!copyBrowserResultExact(context, transfer_id, copy_result, 0, &header)) {
        const resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .failed, "screenshot copy failed") catch null;
        const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
        _ = server.completeInFlight(async_id, resp);
        return if (released) 1 else 0;
    }
    const dims = control_browser.pngDimensions(&header) orelse {
        const resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .failed, "screenshot not png") catch null;
        const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
        _ = server.completeInFlight(async_id, resp);
        return if (released) 1 else 0;
    };
    if (!active_browser_executions.beginTransfer(async_id, transfer_id, total_len)) return 0;
    const result_id = active_browser_transfers.issueResultId() orelse {
        const resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .failed, "browser result id exhausted") catch null;
        const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
        _ = server.completeInFlight(async_id, resp);
        return if (released) 1 else 0;
    };
    const capture_id = screenshot_capture_id_next;
    screenshot_capture_id_next +%= 1;
    const seq_total = std.math.divCeil(usize, total_len, control_browser.screenshot_chunk_bytes) catch unreachable;
    const terminal_frame = control_browser.serializeScreenshotComplete(server.cross_gpa, pending.request_bytes, capture_id, seq_total, total_len, dims) catch {
        const resp = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, .failed, "screenshot terminal allocation failed") catch null;
        const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
        _ = server.completeInFlight(async_id, resp);
        return if (released) 1 else 0;
    };
    const deadline = std.Io.Clock.awake.now(appHostIo()).nanoseconds + browser_op_timeout_ns;
    const progress = control_result.BrowserResultTransfer.init(result_id, total_len, deadline) catch unreachable;
    active_browser_transfers.admit(allocator, .{
        .async_id = async_id,
        .connection_id = pending.connection_id,
        .result_id = result_id,
        .source_id = transfer_id,
        .context = context,
        .copy_result = copy_result,
        .release_result = release_result,
        .progress = progress,
        .terminal = terminal_frame,
        .kind = .{ .screenshot = .{ .capture_id = capture_id } },
    }) catch {
        server.cross_gpa.free(terminal_frame);
        const resp = control_browser.serializeResourceBusy(server.cross_gpa, pending.request_bytes, "browser-transfer-slots") catch null;
        const released = releaseBrowserResultAndFinishExecution(async_id, transfer_id, context, release_result);
        _ = server.completeInFlight(async_id, resp);
        return if (released) 1 else 0;
    };
    _ = server.updateInFlightDeadline(async_id, deadline);
    return 1;
}

fn releaseAndRemoveBrowserTransfer(server: *control_server_mod.ControlServer, index: usize, terminal_enqueued: bool) bool {
    const entry = active_browser_transfers.items.items[index];
    const release_status = entry.release_result(entry.context, entry.source_id);
    if (release_status != 1 and release_status != 2) return false;
    if (!terminal_enqueued) server.cross_gpa.free(entry.terminal);
    _ = active_browser_executions.finish(entry.async_id);
    _ = active_browser_transfers.items.swapRemove(index);
    return true;
}

fn cancelBrowserTransfer(server: *control_server_mod.ControlServer, index: usize, status: control_browser.BrowserCompletionStatus) void {
    const entry = active_browser_transfers.items.items[index];
    const pending = server.inFlightPending(entry.async_id) orelse {
        _ = releaseAndRemoveBrowserTransfer(server, index, false);
        return;
    };
    const outbound = pending.outbound orelse {
        if (releaseAndRemoveBrowserTransfer(server, index, false)) _ = server.completeInFlight(entry.async_id, null);
        return;
    };
    const purge = outbound.purgeDetailed(server.cross_gpa, .{ .browser_result = entry.result_id });
    if (purge.writer_owned or outbound.isClosed()) {
        _ = server.abortInFlightConnection(entry.async_id);
        if (releaseAndRemoveBrowserTransfer(server, index, false)) _ = server.completeInFlight(entry.async_id, null);
        return;
    }
    const response = control_browser.serializeBrowserResponseStatus(server.cross_gpa, pending.request_bytes, status, "") catch null;
    // Data release가 확인되기 전에는 client terminal을 queue에 노출하지 않는다. 실패하면 response만 버리고 다음
    // tick의 같은 tombstone에서 release를 재시도하므로 terminal은 최대 한 번만 enqueue된다.
    if (!releaseAndRemoveBrowserTransfer(server, index, false)) {
        if (response) |wire| server.cross_gpa.free(wire);
        return;
    }
    if (response) |wire| {
        outbound.push(server.cross_gpa, .{ .bytes = wire, .purge_key = .{ .browser_result = entry.result_id }, .class = .terminal }) catch {
            server.cross_gpa.free(wire);
            _ = server.abortInFlightConnection(entry.async_id);
            _ = server.completeInFlight(entry.async_id, null);
            return;
        };
        _ = server.completeInFlightEnqueued(entry.async_id);
    } else {
        _ = server.completeInFlight(entry.async_id, null);
    }
}

/// 앱 전체 frame tick당 최대 한 executeScript 청크 또는 terminal 하나를 처리한다.
pub export fn maru_macos_control_pump_browser_result() u32 {
    if (!control_server_active or active_browser_transfers.items.items.len == 0) return 0;
    const server = &control_server_storage;
    var scanned: usize = 0;
    while (scanned < active_browser_transfers.items.items.len) : (scanned += 1) {
        const index = active_browser_transfers.cursor.take(active_browser_transfers.items.items.len) orelse return 0;
        const entry = &active_browser_transfers.items.items[index];
        const pending = server.inFlightPending(entry.async_id) orelse {
            _ = releaseAndRemoveBrowserTransfer(server, index, false);
            return 1;
        };
        if (pending.connection_id != entry.connection_id) {
            cancelBrowserTransfer(server, index, .failed);
            return 1;
        }
        const execution = active_browser_executions.get(entry.async_id) orelse {
            cancelBrowserTransfer(server, index, .failed);
            return 1;
        };
        const now_ns = std.Io.Clock.awake.now(appHostIo()).nanoseconds;
        const now_s: u64 = @intCast(@max(@as(i128, 0), @divFloor(now_ns, std.time.ns_per_s)));
        if (!browserExecutionAuthorized(execution, now_s)) {
            cancelBrowserTransfer(server, index, .unauthorized);
            return 1;
        }
        const outbound = pending.outbound orelse {
            cancelBrowserTransfer(server, index, .failed);
            return 1;
        };
        if (outbound.isClosed()) {
            cancelBrowserTransfer(server, index, .failed);
            return 1;
        }
        // chunk 크기는 **kind별**로 — screenshot의 seq_total은 screenshot_chunk_bytes로 계산되므로(3116) 펌프도
        // 같은 상수로 조각내야 두 상수가 갈라져도 client의 seq_total 검증이 안 깨진다(이전엔 둘 다 execute_script_chunk_bytes).
        const chunk_bytes = switch (entry.kind) {
            .screenshot => control_browser.screenshot_chunk_bytes,
            .execute_script => control_browser.execute_script_chunk_bytes,
            .snapshot => control_browser.execute_script_chunk_bytes, // §9.5.10: seq_total도 이 상수로 계산(complete_browser_result) — 일치 필수
            .console => control_browser.execute_script_chunk_bytes, // §9.5.10 통일-2: 동일
        };
        switch (entry.progress.plan(now_ns, chunk_bytes, .{
            .should_pause = outbound.shouldPause(),
            .should_resume = outbound.shouldResume(),
        })) {
            .paused => continue,
            .expired => {
                cancelBrowserTransfer(server, index, .timeout);
                return 1;
            },
            .complete => {
                const async_id = entry.async_id;
                const terminal_frame = entry.terminal;
                const release_status = entry.release_result(entry.context, entry.source_id);
                if (release_status != 1 and release_status != 2) {
                    _ = server.abortInFlightConnection(async_id);
                    return 1;
                }
                outbound.push(server.cross_gpa, .{ .bytes = terminal_frame, .purge_key = .{ .browser_result = entry.result_id }, .class = .terminal }) catch {
                    server.cross_gpa.free(terminal_frame);
                    _ = active_browser_executions.finish(async_id);
                    _ = active_browser_transfers.items.swapRemove(index);
                    _ = server.abortInFlightConnection(async_id);
                    _ = server.completeInFlight(async_id, null);
                    return 1;
                };
                _ = active_browser_executions.finish(async_id);
                _ = active_browser_transfers.items.swapRemove(index);
                _ = server.completeInFlightEnqueued(async_id);
                return 1;
            },
            .ready => |slice| {
                browser_transfer_scratch.resize(allocator, slice.len) catch return 0;
                @memset(browser_transfer_scratch.items, 0);
                if (!copyBrowserResultExact(entry.context, entry.source_id, entry.copy_result, slice.offset, browser_transfer_scratch.items)) {
                    cancelBrowserTransfer(server, index, .failed);
                    return 1;
                }
                const frame = switch (entry.kind) {
                    .execute_script => control_browser.serializeExecuteScriptChunkForRequest(server.cross_gpa, pending.request_bytes, entry.result_id, slice.seq, browser_transfer_scratch.items),
                    .screenshot => |shot| control_browser.serializeScreenshotChunk(server.cross_gpa, shot.capture_id, slice.seq, browser_transfer_scratch.items),
                    .snapshot => control_browser.serializeResultChunkForRequest(server.cross_gpa, control_plane.browser_snapshot_chunk_method, pending.request_bytes, entry.result_id, slice.seq, browser_transfer_scratch.items), // §9.5.10 통일-1
                    .console => control_browser.serializeResultChunkForRequest(server.cross_gpa, control_plane.browser_console_chunk_method, pending.request_bytes, entry.result_id, slice.seq, browser_transfer_scratch.items), // §9.5.10 통일-2
                } catch {
                    cancelBrowserTransfer(server, index, .failed);
                    return 1;
                };
                outbound.push(server.cross_gpa, .{ .bytes = frame, .purge_key = .{ .browser_result = entry.result_id } }) catch |err| {
                    server.cross_gpa.free(frame);
                    // 한 tick에는 active transfer 수와 무관하게 copy+base64 시도를 최대 한 번만 한다.
                    if (err == error.Full) return 1;
                    cancelBrowserTransfer(server, index, .failed);
                    return 1;
                };
                const next_deadline = now_ns + browser_op_timeout_ns;
                entry.progress.commit(slice, next_deadline) catch unreachable;
                // transfer와 in-flight가 같은 무진행 deadline을 소유한다. pending은 위에서 확인했고
                // 메인 스레드 전용이라 정상 경로에서 실패할 수 없지만, 어긋나면 방금 넣은 typed chunk까지
                // purge하는 cancel 경로로 닫아 stale transfer를 남기지 않는다.
                if (!server.updateInFlightDeadline(entry.async_id, next_deadline)) {
                    cancelBrowserTransfer(server, index, .failed);
                }
                return 1;
            },
        }
    }
    return 0;
}

/// Swift wait coordinator가 다음 poll 전에 async_id가 여전히 유효한지 확인한다. revoke/close/reap/완료 뒤 0이라 timer가
/// DOM eval을 더 수행하지 않는다. 메인 스레드 전용(호출도 @MainActor wait coordinator).
pub export fn maru_macos_control_browser_wait_is_active(async_id: u64) u32 {
    if (!control_server_active) return 0;
    return if (activeBrowserWait(async_id) and control_server_storage.inFlightPending(async_id) != null) 1 else 0;
}

/// Swift가 off-main syntax validation을 끝낸 뒤 page script를 실제 시작하기 직전 재검사한다. running execution,
/// live client pending, 현재 capability/grant 인가를 모두 만족해야 1이다. timeout도 이 경계에서 먼저 reap해
/// revoke/expiry/timeout 뒤 사용자 expression의 page side effect가 실행되는 창을 닫는다. 메인 스레드 전용.
pub export fn maru_macos_control_browser_execution_may_start(async_id: u64) u32 {
    if (!control_server_active) return 0;
    const server = &control_server_storage;
    const now_ns = std.Io.Clock.awake.now(appHostIo()).nanoseconds;
    expireActiveBrowserExecutions(server, now_ns);
    const execution = active_browser_executions.get(async_id) orelse return 0;
    if (execution.phase != .running or server.inFlightPending(async_id) == null) return 0;
    const now: u64 = @intCast(@max(@as(i128, 0), @divFloor(now_ns, std.time.ns_per_s)));
    return if (browserExecutionAuthorized(execution, now)) 1 else 0;
}

/// 5f-1: screenshot op 완료(§9.5.7 chunk-streaming). `png`=Swift `takeSnapshot`이 만든 PNG 바이트(status 0). PNG를
/// `screenshot_chunk_bytes` 조각으로 나눠 `browser.screenshotChunk` notification을 요청 연결 `pending.outbound`에 seq
/// 순서로 push한 뒤 `completeInFlight`로 최종 응답(complete+metadata)을 resolve한다. **순서 보장**: 메인이 chunk를 먼저
/// outbound에 넣고 completeInFlight가 reader(waitResolved)를 깨워 응답을 그 **뒤**에 push하므로, 단일 writer가 FIFO로
/// chunk 0..N-1 → 최종 응답 순으로 write한다. 실패(status!=0·비-PNG·크기초과·push Full·OOM)는 chunk 없이 단일
/// `internal_error` 응답으로 resolve(부분 push 후 실패면 client가 error 응답을 보고 폐기). **메인 스레드 전용**(WKWebView 콜백).
fn completeScreenshotOp(
    server: *control_server_mod.ControlServer,
    async_id: u64,
    pending: *control_server_mod.PendingRequest,
    status: u32,
    png: []const u8,
) void {
    // 실패 콜백(takeSnapshot 에러) → internal_error(serializeBrowserResponse의 ok=false 경로 재사용 — id 재파싱).
    if (status != 0) {
        _ = server.completeInFlight(async_id, control_browser.serializeBrowserResponse(server.cross_gpa, pending.request_bytes, false, png) catch null);
        return;
    }
    // metadata: PNG IHDR width/height. 비-PNG(스냅샷이 PNG가 아님)면 internal_error.
    const dims = control_browser.pngDimensions(png) orelse {
        _ = server.completeInFlight(async_id, control_browser.serializeBrowserResponse(server.cross_gpa, pending.request_bytes, false, "screenshot not png") catch null);
        return;
    };
    // legacy raw-pointer fallback의 상한. 정상 Swift 성공 경로는 registry + progressive pump를 사용한다.
    const chunk_bytes = control_browser.screenshot_chunk_bytes;
    const n_chunks = std.math.divCeil(usize, png.len, chunk_bytes) catch unreachable; // chunk_bytes는 nonzero 상수
    if (n_chunks > control_browser.screenshot_max_chunks) {
        _ = server.completeInFlight(async_id, control_browser.serializeBrowserResponse(server.cross_gpa, pending.request_bytes, false, "screenshot too large") catch null);
        return;
    }
    // 요청 연결의 outbound(chunk push 대상). 정상 in-flight browser op은 serveConnection이 non-null로 세팅하나, 필드가
    // optional이라 방어적 언랩 — null(도달 불가)이면 internal_error resolve(chunk 없이).
    const outbound = pending.outbound orelse {
        _ = server.completeInFlight(async_id, control_browser.serializeBrowserResponse(server.cross_gpa, pending.request_bytes, false, "screenshot no outbound") catch null);
        return;
    };
    const capture_id = screenshot_capture_id_next;
    screenshot_capture_id_next +%= 1;
    const tag: u64 = control_browser.parseScreenshotTargetId(server.cross_gpa, pending.request_bytes) orelse 0; // surface tag(revoke/close purge)
    // chunk 프레임을 seq 순서로 outbound에 push(coalesce=null[유실·병합 불가]·tag=surface). 실패면 error 응답으로 종료.
    var seq: usize = 0;
    var off: usize = 0;
    while (off < png.len) : (seq += 1) {
        const end = @min(off + chunk_bytes, png.len);
        const frame = control_browser.serializeScreenshotChunk(server.cross_gpa, capture_id, seq, png[off..end]) catch {
            _ = server.completeInFlight(async_id, control_browser.serializeBrowserResponse(server.cross_gpa, pending.request_bytes, false, "screenshot serialize failed") catch null);
            return;
        };
        outbound.push(server.cross_gpa, .{ .bytes = frame, .coalesce_key = null, .purge_key = if (tag == 0) .none else .{ .surface_event = tag } }) catch {
            server.cross_gpa.free(frame); // push 실패(Full=writer 정체, QueueClosed=종료) → 소유권 반환·해제
            _ = server.completeInFlight(async_id, control_browser.serializeBrowserResponse(server.cross_gpa, pending.request_bytes, false, "screenshot delivery congested") catch null);
            return;
        };
        off = end;
    }
    // 최종 응답 = complete 마커 + metadata(seq_total=chunk 수). reader가 이 응답을 chunk 뒤에 outbound push(FIFO 순서).
    _ = server.completeInFlight(async_id, control_browser.serializeScreenshotComplete(server.cross_gpa, pending.request_bytes, capture_id, seq, png.len, dims) catch null);
}

/// 5f-0b-3c: Swift가 WKWebView `url` KVO(메인 스레드)에서 호출 — 그 web surface의 `browser.navigated` 이벤트를 그 surface
/// 구독자들의 연결 outbound로 push한다(§9.5.2). 구독자 없으면 `pushEvent`가 match-first로 직렬화 없이 조기 반환(핫패스 무비용).
/// 서버 미시작이면 무동작. `url`은 이 호출 중만 유효(pushEvent가 프레임에 복사). **메인 스레드 전용**(KVO=메인; registry=leaf-mutex).
pub export fn maru_macos_control_push_browser_navigated(surface_id: u64, url_ptr: ?[*]const u8, url_len: usize) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    const url: []const u8 = if (url_ptr) |p| p[0..url_len] else "";
    _ = server.subscriber_reg.pushEvent(server.cross_gpa, surface_id, .{ .navigated = url });
}

/// 5f-3a: Swift가 WKWebView `isLoading` KVO(메인)에서 호출 — `browser.loadState` 이벤트(`loading`!=0 → loading, else idle)를
/// 구독자에 push. navigated와 동형(coalescible KVO 이벤트). 서버 미시작/무구독이면 무비용. **메인 스레드 전용**.
pub export fn maru_macos_control_push_browser_load_state(surface_id: u64, loading: u8) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    _ = server.subscriber_reg.pushEvent(server.cross_gpa, surface_id, .{ .load_state = if (loading != 0) .loading else .idle });
}

/// 5f-3b: Swift `WKUIDelegate`(runJavaScript{Alert,Confirm,TextInput}Panel, 메인)에서 호출 — `browser.dialog` 이벤트
/// (`kind`: 0=alert·1=confirm·2=prompt, `message`=JS 다이얼로그 메시지)를 구독자에 push. 이산 이벤트(비-coalescible). `message`는
/// 이 호출 중만 유효(pushEvent가 복사). 미지 kind는 alert로 폴백. 서버 미시작/무구독이면 무비용. **메인 스레드 전용**.
pub export fn maru_macos_control_push_browser_dialog(surface_id: u64, kind: u8, message_ptr: ?[*]const u8, message_len: usize) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    const message: []const u8 = if (message_ptr) |p| p[0..message_len] else "";
    const dk: maru.session.control_events.DialogKind = switch (kind) {
        1 => .confirm,
        2 => .prompt,
        else => .alert,
    };
    _ = server.subscriber_reg.pushEvent(server.cross_gpa, surface_id, .{ .dialog = .{ .kind = dk, .message = message } });
}

/// 5f-3c: Swift `WKNavigationDelegate.webViewWebContentProcessDidTerminate`(메인)에서 호출 — `browser.crashed` 이벤트를
/// 구독자에 push(추가 payload 없음). 이산. 서버 미시작/무구독이면 무비용. **메인 스레드 전용**.
pub export fn maru_macos_control_push_browser_crashed(surface_id: u64) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    // crash는 logical surface close가 아니므로 cap/grant/subscription은 보존하지만, 그 WebContent realm에 걸린 현재 op은
    // 더는 완료를 신뢰할 수 없다. event보다 먼저 process-exited terminal을 commit하고 Swift가 backend registry를 비운다.
    cancelBrowserOpsForCrashedSurface(server, surface_id);
    _ = server.subscriber_reg.pushEvent(server.cross_gpa, surface_id, .crashed);
}

/// 5f-3d: Swift가 web surface 소멸(패널 close) **직전**에 호출 — `browser.closed`를 그 surface의 **모든 구독자**(필터 무관 —
/// 종료 마커라 opt-out 불가, 21차 [0])에게 push한 **뒤** 구독을 제거한다(`pushSurfaceClosed`가 락 아래 원자로 push+remove).
/// closed 프레임은 큐에 남아 writer가 배달하고(remove는 큐 안 건드림 — cap revoke의 `purgeSurface`[프레임 폐기]와 구분), Full인
/// 구독자는 outbound close로 teardown(subscriber-lagged, 21차 [5]). 서버 미시작이면 무동작. **메인 스레드 전용**.
pub export fn maru_macos_control_push_browser_closed(surface_id: u64) void {
    if (!control_server_active) return;
    const server = &control_server_storage;
    // AppSession destroyTerm 훅이 먼저 호출하는 정상 경로에선 멱등이다. popup/adopt 등 별도 host 경로도 이 export 하나로
    // target wait·pane-origin grant 수명을 함께 닫도록 재호출한다.
    onAppSessionSurfaceClosed(null, surface_id);
    _ = server.subscriber_reg.pushSurfaceClosed(server.cross_gpa, surface_id);
}

/// grant UX(revoke, §9.2 Model B): 사용자가 부여한 **모든** pane-bound browser grant를 취소한다 — 메뉴 "Revoke Browser
/// Grants"가 호출. 이후 browser 요청은 다시 확인 모달을 거친다. grant store는 앱-전역(control_pane_grant_store)이라 세션
/// 무관. 서버 미시작이어도 store는 살아 있으므로 게이트 없이 클리어. 취소된 grant 수 반환(Swift가 사용자 피드백에 쓸 수 있음).
pub export fn maru_macos_control_revoke_all_browser_grants() u32 {
    const n: u32 = @intCast(control_pane_grant_store.len);
    control_pane_grant_store.clearAll();
    if (control_server_active) {
        cancelAllPaneGrantBrowserWaits(&control_server_storage);
        cancelAllPaneGrantBrowserExecutions(&control_server_storage);
    }
    return n;
}

// grant scope ABI wire(0=browser·1=browser_storage). @intFromEnum이 아니라 **명시 매핑** — ScopeClass 순서가 바뀌어도
// Swift 메뉴가 잘못된 grant를 revoke하지 않게(grant에는 이 둘만 저장되나 방어로 browser에 접음/거부).
fn grantScopeToWire(sc: control_capability.ScopeClass) u8 {
    return switch (sc) {
        .browser => 0,
        .browser_storage => 1,
        else => 0,
    };
}
fn grantScopeFromWire(w: u8) ?control_capability.ScopeClass {
    return switch (w) {
        0 => .browser,
        1 => .browser_storage,
        else => null,
    };
}

/// grant UX(per-grant revoke, §9.2 Model B): 현재 활성 pane-bound browser grant 수. Swift "Browser Grants" 서브메뉴가
/// 열릴 때 이걸로 항목을 동적 생성한다(count → grant_at[0..count]). 메인 스레드 전용(store 소유 §8.8).
pub export fn maru_macos_control_browser_grant_count() u32 {
    return @intCast(control_pane_grant_store.len);
}

/// index `i`의 grant를 out에 채운다(1=ok·0=범위밖). scope=wire u8(grantScopeToWire). 인덱스는 **호출 시점 스냅샷**이라
/// 메뉴 열 때마다 count→at로 새로 읽는다(revoke의 swap-remove로 인덱스가 바뀌므로 캐시 금지). 메인 스레드 전용.
pub export fn maru_macos_control_browser_grant_at(index: u32, out_pane: ?*u64, out_target: ?*u64, out_scope: ?*u8) u32 {
    if (index >= control_pane_grant_store.len) return 0;
    const g = control_pane_grant_store.grants[index];
    if (out_pane) |p| p.* = g.pane;
    if (out_target) |p| p.* = g.target;
    if (out_scope) |p| p.* = grantScopeToWire(g.scope);
    return 1;
}

/// (pane, target, scope) grant **하나**만 취소(1=취소됨·0=없음/잘못된 scope). scope=wire u8. **값 기반**이라 인덱스
/// 시프트에 안전(멱등 — 이미 없어도 0). 이후 그 (pane,target,scope) browser 요청은 다시 확인 모달을 거친다. 메인 스레드 전용.
pub export fn maru_macos_control_revoke_browser_grant(pane: u64, target: u64, scope: u8) u32 {
    const sc = grantScopeFromWire(scope) orelse return 0;
    const before = control_pane_grant_store.len;
    control_pane_grant_store.revoke(pane, target, sc);
    const removed = control_pane_grant_store.len < before;
    if (removed and control_server_active) {
        cancelBrowserWaitsForGrant(&control_server_storage, pane, target, sc);
        cancelBrowserExecutionsForGrant(&control_server_storage, pane, target, sc);
    }
    return if (removed) 1 else 0;
}

pub export fn maru_macos_control_server_stop() void {
    if (!control_server_active) return;
    while (active_browser_transfers.items.items.len > 0) {
        const index = active_browser_transfers.items.items.len - 1;
        const entry = active_browser_transfers.items.items[index];
        if (control_server_storage.inFlightPending(entry.async_id)) |pending| if (pending.outbound) |outbound| {
            _ = outbound.purgeDetailed(control_server_storage.cross_gpa, .{ .browser_result = entry.result_id });
        };
        _ = control_server_storage.abortInFlightConnection(entry.async_id);
        _ = entry.release_result(entry.context, entry.source_id);
        // stop 뒤에는 새 execution admission이 없고 Swift가 곧 registry.releaseAll을 호출한다. callback 자체가
        // 손상돼 0을 반환해도 Zig terminal/예약을 남겨 server.stop 회계를 깨뜨리지 않는다.
        control_server_storage.cross_gpa.free(entry.terminal);
        _ = active_browser_executions.finish(entry.async_id);
        _ = active_browser_transfers.items.swapRemove(index);
        _ = control_server_storage.completeInFlight(entry.async_id, null);
    }
    control_server_active = false;
    active_browser_executions.stop();
    control_server_storage.stop();
    // 5e-2b: 큐에 남은 browser op의 arg·안정 슬롯 해제. stop이 in-flight pending은 cancel하지만 큐 arg는 별도. arg는
    // dispatchAuthenticated가 cross_gpa로 dupe했고 cross_gpa==`allocator`(start가 그렇게 넘김)라 여기서 allocator로 free
    // (stop 후 control_server_storage.cross_gpa는 undefined라 접근 금지 — self.*=undefined).
    browser_op_queue.deinit(allocator, allocator);
    browser_op_queue = .{};
    browser_op_take_buf.deinit(allocator);
    browser_op_take_buf = .empty;
    active_browser_waits.deinit(allocator);
    active_browser_waits = .empty;
    active_browser_transfers.items.deinit(allocator);
    active_browser_transfers = .{};
    browser_transfer_scratch.deinit(allocator);
    browser_transfer_scratch = .empty;
    // 1e-confirm-2a: 대기 grant 확인 큐 해제(엔트리는 값 타입 — arg 소유 없음, stop이 in-flight pending은 cancel).
    grant_prompt_queue.deinit(allocator);
    grant_prompt_queue = .{};
}

/// 5e-2b-2(**테스트 전용 훅**): env `MARU_TEST_BROWSER_CAP`이 설정됐을 때만 `surface_id`에 묶인 `browser` scope
/// capability를 라이브 `control_cap_store`에 발급하고 그 nonce(raw 32B)를 out으로 넘긴다. 실 fd 발급(1e-confirm)
/// 전이라 store가 비어 browser 요청이 default-deny인 상태에서, macos smoke가 소켓 `browser.navigate`(이 nonce)→실
/// WKWebView 이동을 자동 증명하게 하는 것이 유일한 목적이다. **프로덕션 무영향**: env 미설정이면 아무것도 안 하고 0을
/// 반환한다(호출자 Swift도 같은 env 게이트 뒤에서만 부른다 — 이중 게이트, capability 발급이라 방어적으로 Zig에도 게이트).
/// 발급은 §8.8대로 메인 스레드에서만(Swift tick). `generation`=0(collector가 web surface를 generation 0으로 방출 —
/// `app_session.collectSessionInto`; authz는 target id·cap.generation 앵커라 값 자체가 자기-정합). raw nonce는 store에
/// 저장 안 됨(hashNonce만). 반환 1=발급+nonce 채움, 0=env 미설정·out null·용량 부족·발급 실패. `out_nonce` 최소 32B.
pub export fn maru_macos_control_test_issue_browser_cap(surface_id: u64, out_nonce: ?[*]u8, out_nonce_cap: usize) u32 {
    if (std.c.getenv("MARU_TEST_BROWSER_CAP") == null) return 0; // env 게이트(테스트 전용 — 프로덕션 경로 무영향)
    const np = out_nonce orelse return 0;
    if (out_nonce_cap < control_capability.nonce_len) return 0;
    // 결정적 테스트 nonce(고정 바이트 파생). 실 crypto-random 생성은 1e-confirm 발급 경로 소유 — 이 훅은 smoke 왕복만.
    var nonce: control_capability.Nonce = undefined;
    for (&nonce, 0..) |*b, i| b.* = @intCast((i * 7 + 0x5e) & 0xff);
    control_cap_store.issueForFd(allocator, nonce, .{
        .surface_id = surface_id,
        .generation = 0,
        .scope = .browser,
    }) catch return 0; // validateFdIssuance(browser=allowed·TTL 불요) 통과가 정상 — OOM만 0
    @memcpy(np[0..control_capability.nonce_len], &nonce);
    return 1;
}

/// 5e-2b-2(**테스트 전용 훅**): 라이브 컨트롤 서버가 바인딩한 유닉스 소켓 경로를 out으로 복사하고 그 길이를 반환한다
/// (0=서버 미시작·out null·용량 부족). macos smoke의 인-프로세스 소켓 클라이언트가 자기 앱 소켓에 connect하는 데 쓴다
/// (경로는 비밀이 아님 — same-uid peer가 control dir을 열거 가능, §4.2). NUL 미포함 길이.
pub export fn maru_macos_control_socket_path(out: ?[*]u8, out_cap: usize) usize {
    if (!control_server_active) return 0;
    const p = out orelse return 0;
    const path = control_server_storage.server.socketPath(); // [:0]const u8
    if (path.len > out_cap) return 0;
    @memcpy(p[0..path.len], path);
    return path.len;
}

test "macOS app host ABI header and Zig declarations stay aligned" {
    // Swift는 C header를 보고, Zig는 이 파일의 extern struct를 쓴다. 둘의 숫자와
    // layout이 갈라지면 다음 제품 앱 PR에서 런타임 버그가 되므로 컴파일 단계에서 막는다.
    try std.testing.expectEqual(@as(u32, c.MARU_MACOS_APP_HOST_ABI_VERSION), abi_version);
    try std.testing.expectEqual(@as(u16, @intCast(c.MaruAppHostMetalCellRoleDockToggle)), maru.renderer.metal_frame.native_cell_role_dock_toggle);
    const dock_policy = c.maru_metal_cell_glyph_policy(c.MaruAppHostMetalCellRoleDockToggle, 13, 30, 8, 18);
    try std.testing.expectEqual(@as(u32, 1), dock_policy.is_dock_toggle);
    try std.testing.expectApproxEqAbs(@as(f32, 13.0 / 8.0), dock_policy.scale_x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0 / 18.0), dock_policy.scale_y, 0.0001);
    const normal_pua_policy = c.maru_metal_cell_glyph_policy(0, 13, 30, 8, 18);
    try std.testing.expectEqual(@as(u32, 0), normal_pua_policy.is_dock_toggle);
    try std.testing.expectEqual(@as(f32, 1), normal_pua_policy.scale_x);
    try std.testing.expectEqual(@as(f32, 1), normal_pua_policy.scale_y);
    try std.testing.expectEqual(@as(u32, @intCast(c.MARU_FILE_TREE_TRASH_KIND_REGULAR)), @as(u32, @intFromEnum(file_tree_mutation_backend.IdentityKind.regular)));
    try std.testing.expectEqual(@as(u32, @intCast(c.MARU_FILE_TREE_TRASH_KIND_DIRECTORY)), @as(u32, @intFromEnum(file_tree_mutation_backend.IdentityKind.directory)));
    try std.testing.expectEqual(@as(u32, @intCast(c.MARU_FILE_TREE_TRASH_KIND_SYMLINK)), @as(u32, @intFromEnum(file_tree_mutation_backend.IdentityKind.symlink)));
    try std.testing.expectEqual(@as(u32, @intCast(c.MARU_FILE_TREE_TRASH_KIND_OTHER)), @as(u32, @intFromEnum(file_tree_mutation_backend.IdentityKind.other)));
    try std.testing.expectEqual(@as(u32, @intCast(c.MARU_FILE_TREE_TRASH_OUTCOME_NOT_MOVED)), @as(u32, @intFromEnum(session_mod.FileTreeTrashOutcome.not_moved)));
    try std.testing.expectEqual(@as(u32, @intCast(c.MARU_FILE_TREE_TRASH_OUTCOME_MOVED_VERIFIED)), @as(u32, @intFromEnum(session_mod.FileTreeTrashOutcome.moved_verified)));
    try std.testing.expectEqual(@as(u32, @intCast(c.MARU_FILE_TREE_TRASH_OUTCOME_MOVED_UNVERIFIED)), @as(u32, @intFromEnum(session_mod.FileTreeTrashOutcome.moved_unverified)));
    try std.testing.expectEqual(@as(usize, @intCast(c.MARU_FILE_TREE_PATH_CAPACITY)), file_tree_mutation_backend.trash_path_capacity);
    try std.testing.expectEqual(@as(u32, @intCast(c.MARU_BROWSER_WAIT_DEFAULT_TIMEOUT_MS)), control_browser.wait_default_timeout_ms);
    try std.testing.expectEqual(@as(u32, @intCast(c.MARU_BROWSER_WAIT_MAX_TIMEOUT_MS)), control_browser.wait_max_timeout_ms);
    try std.testing.expectEqual(@as(u32, @intCast(c.MARU_BROWSER_WAIT_POLL_INTERVAL_MS)), control_browser.wait_poll_interval_ms);
    // url_at out_kind 계약: @intFromEnum(LinkKind)를 그대로 싣고 Swift handleUrlClick이 kind==1=file_path로 분기한다.
    // LinkKind 순서를 바꾸면 분기가 silent하게 뒤집히므로(웹↔파일) 태그 값을 고정한다(C typedef 없는 enum 가드 — Status/EventKind 선례).
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(terminal.LinkKind.url));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(terminal.LinkKind.file_path));
    // 5e-2b op_kind wire 계약: take_browser_op이 @intFromEnum(BrowserMethod)를 그대로 op_kind로 싣고 Swift
    // drainBrowserOps가 0=navigate·1=getUrl·2=executeScript·4=getCookies·5=screenshot·6=setCookie·7=deleteCookie·8~11=localStorage/clear·12=click·13=type·14=scroll·15=wait로 디코드한다. BrowserMethod 순서를 바꾸면
    // op_kind가 silent하게 재매핑돼 navigate 요청이 다른 op을 구동하므로(컴파일·테스트 무경보) 태그 값을 고정한다
    // (LinkKind 선례 — .h 주석·Swift switch와 단일 계약). 신규 메서드는 **끝에** 추가한다(3=subscribe는 async op이
    // 아니라 op_kind로 안 실림 — get_cookies는 그 뒤 4).
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @intFromEnum(control_browser.BrowserMethod.navigate)));
    try std.testing.expectEqual(@as(u8, 1), @as(u8, @intFromEnum(control_browser.BrowserMethod.get_url)));
    try std.testing.expectEqual(@as(u8, 2), @as(u8, @intFromEnum(control_browser.BrowserMethod.execute_script)));
    try std.testing.expectEqual(@as(u8, 4), @as(u8, @intFromEnum(control_browser.BrowserMethod.get_cookies))); // 5f-4c
    try std.testing.expectEqual(@as(u8, 5), @as(u8, @intFromEnum(control_browser.BrowserMethod.screenshot))); // 5f-1
    try std.testing.expectEqual(@as(u8, 6), @as(u8, @intFromEnum(control_browser.BrowserMethod.set_cookie))); // cookie write
    try std.testing.expectEqual(@as(u8, 7), @as(u8, @intFromEnum(control_browser.BrowserMethod.delete_cookie)));
    try std.testing.expectEqual(@as(u8, 8), @as(u8, @intFromEnum(control_browser.BrowserMethod.get_local_storage))); // localStorage/clear
    try std.testing.expectEqual(@as(u8, 9), @as(u8, @intFromEnum(control_browser.BrowserMethod.set_local_storage)));
    try std.testing.expectEqual(@as(u8, 10), @as(u8, @intFromEnum(control_browser.BrowserMethod.remove_local_storage)));
    try std.testing.expectEqual(@as(u8, 11), @as(u8, @intFromEnum(control_browser.BrowserMethod.clear_storage)));
    try std.testing.expectEqual(@as(u8, 12), @as(u8, @intFromEnum(control_browser.BrowserMethod.click))); // act 5f-2
    try std.testing.expectEqual(@as(u8, 13), @as(u8, @intFromEnum(control_browser.BrowserMethod.type_text)));
    try std.testing.expectEqual(@as(u8, 14), @as(u8, @intFromEnum(control_browser.BrowserMethod.scroll)));
    try std.testing.expectEqual(@as(u8, 15), @as(u8, @intFromEnum(control_browser.BrowserMethod.wait)));
    try std.testing.expectEqual(@as(u8, 16), @as(u8, @intFromEnum(control_browser.BrowserMethod.snapshot))); // §9.5.4
    try std.testing.expectEqual(@as(u8, 17), @as(u8, @intFromEnum(control_browser.BrowserMethod.console))); // §9.5.9

    // workspace 헤더도 .h define과 Zig 단일 출처(session.workspace.header)가 갈라지면 저장/로드가 어긋나므로 고정.
    try std.testing.expectEqualStrings(c.MARU_WORKSPACE_HEADER, maru.session.workspace.header);
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusOk), @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusNullOut), @intFromEnum(Status.null_out));
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusInvalidConfig), @intFromEnum(Status.invalid_config));
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusSessionEnded), @intFromEnum(Status.session_ended));
    // M3d-2b: cross-window 이동 거부 status(=10)를 Swift가 이 값으로 판정하므로 .h와 고정 정합(값 드리프트면 이동 실패를 성공으로 오독).
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusMoveFailed), @intFromEnum(Status.move_failed));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostEventKeyDown), @intFromEnum(EventKind.key_down));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostEventAppShouldTerminate), @intFromEnum(EventKind.app_should_terminate));
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostKeyCodeArrowUp)), @intFromEnum(KeyCode.arrow_up));
    // PC-style 기능키 C 상수 ↔ enum 정합(경계 1개씩 + F12로 확인).
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostKeyCodeHome)), @intFromEnum(KeyCode.home));
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostKeyCodePageDown)), @intFromEnum(KeyCode.page_down));
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostKeyCodeF1)), @intFromEnum(KeyCode.f1));
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostKeyCodeF12)), @intFromEnum(KeyCode.f12));
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostCommandControlledSmoke)), @intFromEnum(AppCommandKind.controlled_smoke));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostCapabilities), @sizeOf(Capabilities));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostCapabilities), @alignOf(Capabilities));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostKeyEvent), @sizeOf(KeyEvent));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostResizeEvent), @sizeOf(ResizeEvent));
    // M3d-2b MoveResult(Swift가 이동/merge 결과를 이 layout으로 읽는다). 필드 타입이 달라 @sizeOf가 대부분의 reorder를
    // 잡지만, source_window_closed↔moved_count(둘 다 u32) 뒤바뀜은 못 잡으므로 @offsetOf로 세 필드 위치를 대조한다.
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostMoveResult), @sizeOf(MoveResult));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostMoveResult), @alignOf(MoveResult));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMoveResult, "status"), @offsetOf(MoveResult, "status"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMoveResult, "source_window_closed"), @offsetOf(MoveResult, "source_window_closed"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMoveResult, "moved_count"), @offsetOf(MoveResult, "moved_count"));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostSessionConfig), @sizeOf(AppSessionConfig));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostSessionConfig), @alignOf(AppSessionConfig));
    // AS4-c fixture probe는 mixed-width ABI라 size만으로 field reorder를 잡지 못한다.
    try std.testing.expectEqual(@as(u32, c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_CARD), @intFromEnum(session_mod.AgentSessionArchiveSmokeProbeTarget.session_dock_card));
    try std.testing.expectEqual(@as(u32, c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME), @intFromEnum(session_mod.AgentSessionArchiveSmokeProbeTarget.archive_resume));
    try std.testing.expectEqual(@as(u32, c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REVEAL_LOG), @intFromEnum(session_mod.AgentSessionArchiveSmokeProbeTarget.archive_reveal_log));
    try std.testing.expectEqual(@as(u32, c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_FOCUS_LIVE), @intFromEnum(session_mod.AgentSessionArchiveSmokeProbeTarget.archive_focus_live));
    try std.testing.expectEqual(@as(u32, c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_AGENT_SESSIONS), @intFromEnum(session_mod.AgentSessionArchiveSmokeProbeTarget.dock_agent_sessions));
    try std.testing.expectEqual(@as(u32, c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_LAUNCHER), @intFromEnum(session_mod.AgentSessionArchiveSmokeProbeTarget.dock_launcher));
    try std.testing.expectEqual(@as(u32, c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REFRESH), @intFromEnum(session_mod.AgentSessionArchiveSmokeProbeTarget.archive_refresh));
    try std.testing.expectEqual(@as(u32, c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_EXPANDED_SCROLL_ANCHOR), @intFromEnum(session_mod.AgentSessionArchiveSmokeProbeTarget.archive_expanded_scroll_anchor));
    try std.testing.expectEqual(@as(u32, c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SCOPE_ROW), @intFromEnum(session_mod.AgentSessionArchiveSmokeProbeTarget.archive_scope_row));
    try std.testing.expectEqual(@as(u32, c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SEARCH), @intFromEnum(session_mod.AgentSessionArchiveSmokeProbeTarget.archive_search));
    try std.testing.expectEqual(@as(u32, c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_EXPANDED_CARD), @intFromEnum(session_mod.AgentSessionArchiveSmokeProbeTarget.archive_expanded_card));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostAgentSessionArchiveSmokeProbe), @sizeOf(AgentSessionArchiveSmokeProbe));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostAgentSessionArchiveSmokeProbe), @alignOf(AgentSessionArchiveSmokeProbe));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostAgentSessionArchiveSmokeProbe, "request_id"), @offsetOf(AgentSessionArchiveSmokeProbe, "request_id"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostAgentSessionArchiveSmokeProbe, "generation"), @offsetOf(AgentSessionArchiveSmokeProbe, "generation"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostAgentSessionArchiveSmokeProbe, "x_px"), @offsetOf(AgentSessionArchiveSmokeProbe, "x_px"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostAgentSessionArchiveSmokeProbe, "state"), @offsetOf(AgentSessionArchiveSmokeProbe, "state"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostAgentSessionArchiveSmokeProbe, "enabled"), @offsetOf(AgentSessionArchiveSmokeProbe, "enabled"));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostQuickTerminalConfig), @sizeOf(session_mod.QuickTerminalConfig));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostQuickTerminalConfig), @alignOf(session_mod.QuickTerminalConfig));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostQuickTerminalFrames), @sizeOf(session_mod.QuickTerminalFrames));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostQuickTerminalFrames), @alignOf(session_mod.QuickTerminalFrames));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostQuickTerminalChromeMinimal), @intFromEnum(maru.config.theme.QuickTerminalChrome.minimal));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostQuickTerminalPositionCenter), @intFromEnum(maru.config.theme.QuickTerminalPosition.center));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostCommand), @sizeOf(session_mod.CommandEntry));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostCommand), @alignOf(session_mod.CommandEntry));
    // CommandEntry는 동일-폭 포인터 4개라 @sizeOf가 필드 reorder를 못 잡는다 — @offsetOf로 C↔Zig 위치를
    // 대조한다(AppMetalFrame 포인터 필드 선례와 동형). title↔action_key 등이 뒤바뀌면 Swift가 잘못된 문자열을 읽는다.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostCommand, "action_key"), @offsetOf(session_mod.CommandEntry, "action_key"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostCommand, "title"), @offsetOf(session_mod.CommandEntry, "title"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostCommand, "key_display"), @offsetOf(session_mod.CommandEntry, "key_display"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostCommand, "key_equivalent"), @offsetOf(session_mod.CommandEntry, "key_equivalent"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostCommand, "key_modifiers"), @offsetOf(session_mod.CommandEntry, "key_modifiers"));
    // A2b ControlSessionRef ABI 정합(Swift가 창마다 채워 drain에 넘긴다). offsetOf로 필드 위치까지 대조.
    try std.testing.expectEqual(@sizeOf(c.MaruControlSessionRef), @sizeOf(ControlSessionRef));
    try std.testing.expectEqual(@alignOf(c.MaruControlSessionRef), @alignOf(ControlSessionRef));
    try std.testing.expectEqual(@offsetOf(c.MaruControlSessionRef, "app_session"), @offsetOf(ControlSessionRef, "app_session"));
    try std.testing.expectEqual(@offsetOf(c.MaruControlSessionRef, "window_id"), @offsetOf(ControlSessionRef, "window_id"));
    try std.testing.expectEqual(@offsetOf(c.MaruControlSessionRef, "window_kind"), @offsetOf(ControlSessionRef, "window_kind"));
    // GlobalHotkey ABI 정합(전역 단축키 enumerate가 out_ptr로 노출) — 이전엔 대조가 통째로 빠져 있었다.
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostGlobalHotkey), @sizeOf(session_mod.GlobalHotkey));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostGlobalHotkey), @alignOf(session_mod.GlobalHotkey));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostFrameSummary), @sizeOf(AppFrameSummary));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostFrameSummary), @alignOf(AppFrameSummary));
    // v102(4e-5): web_surfaces_present는 quit_decision 뒤 4B tail padding을 채워 @sizeOf가 176으로 불변이라 필드 존재를
    // 못 강제한다 — offset을 C↔Zig 대조해 패딩 자리에 정확히 들어갔는지(위치 정합) 고정한다(GpuQuad 동일-폭 필드 선례).
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostFrameSummary, "web_surfaces_present"), @offsetOf(AppFrameSummary, "web_surfaces_present"));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostMetalCell), @sizeOf(AppMetalCell));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostMetalCell), @alignOf(AppMetalCell));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostMetalRasterUpload), @sizeOf(AppMetalRasterUpload));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostMetalRasterUpload), @alignOf(AppMetalRasterUpload));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostMetalFrame), @sizeOf(AppMetalFrame));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostMetalFrame), @alignOf(AppMetalFrame));
    // append-only면 @sizeOf가 필드 존재를 강제하지만, 같은 폭(포인터/usize) 필드 reorder는 못 잡는다 — C4b가
    // 추가한 포인터/인덱스 필드는 @offsetOf로 C↔Zig 위치를 대조한다(GpuQuad 선례와 동형).
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "gpu_quads"), @offsetOf(AppMetalFrame, "gpu_quads"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "gpu_shadows"), @offsetOf(AppMetalFrame, "gpu_shadows"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "gpu_glyphs"), @offsetOf(AppMetalFrame, "gpu_glyphs"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "gpu_glyph_count"), @offsetOf(AppMetalFrame, "gpu_glyph_count"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "modal_cells_start"), @offsetOf(AppMetalFrame, "modal_cells_start"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "overlay_cells_present"), @offsetOf(AppMetalFrame, "overlay_cells_present"));
    // v169: 셀이 clip 표의 항목을 index로 가리킨다. index는 셀 안의 u16 이웃들과 같은 폭이고 표 포인터/개수도
    // 프레임의 다른 포인터/usize와 같은 폭이라 @sizeOf로는 어느 쪽도 reorder를 못 잡는다 — 자리까지 고정한다.
    // 어긋나면 렌더러가 **다른 사각형으로** 자르므로 화면은 그럴듯한데 틀린 곳이 잘린다.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalCell, "clip_index"), @offsetOf(AppMetalCell, "clip_index"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "cell_clips"), @offsetOf(AppMetalFrame, "cell_clips"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "cell_clip_count"), @offsetOf(AppMetalFrame, "cell_clip_count"));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostClipRect), @sizeOf(maru.renderer.metal_frame.ClipPx));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostClipRect), @alignOf(maru.renderer.metal_frame.ClipPx));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostClipRect, "h"), @offsetOf(maru.renderer.metal_frame.ClipPx, "h"));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostGpuQuad), @sizeOf(AppGpuQuad));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostGpuQuad), @alignOf(AppGpuQuad));
    // 모든 필드가 4B라 @sizeOf만으론 필드 reorder(예: corner_radii↔border_widths)를 못 잡는다 — offset도 대조한다.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuQuad, "corner_radii"), @offsetOf(AppGpuQuad, "corner_radii"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuQuad, "border_widths"), @offsetOf(AppGpuQuad, "border_widths"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuQuad, "fill_color0"), @offsetOf(AppGpuQuad, "fill_color0"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuQuad, "gradient_kind"), @offsetOf(AppGpuQuad, "gradient_kind"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuQuad, "layer"), @offsetOf(AppGpuQuad, "layer"));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostGpuShadow), @sizeOf(AppGpuShadow));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostGpuShadow), @alignOf(AppGpuShadow));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuShadow, "corner_radii"), @offsetOf(AppGpuShadow, "corner_radii"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuShadow, "blur_radius"), @offsetOf(AppGpuShadow, "blur_radius"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuShadow, "color"), @offsetOf(AppGpuShadow, "color"));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostGpuGlyph), @sizeOf(AppGpuGlyph));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostGpuGlyph), @alignOf(AppGpuGlyph));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuGlyph, "x"), @offsetOf(AppGpuGlyph, "x"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuGlyph, "u0"), @offsetOf(AppGpuGlyph, "u0"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuGlyph, "atlas_x_px"), @offsetOf(AppGpuGlyph, "atlas_x_px"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuGlyph, "atlas_height_px"), @offsetOf(AppGpuGlyph, "atlas_height_px"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuGlyph, "foreground"), @offsetOf(AppGpuGlyph, "foreground"));
    // kitty graphics(K2c): 이미지 드로우/업로드 프리미티브 + frame 채널. append-only라 @sizeOf가 필드 존재를
    // 강제하지만, 같은 폭 필드(GpuImage는 전부 4B, frame은 포인터/usize)는 reorder를 못 잡으므로 offset도 대조한다.
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostGpuImage), @sizeOf(AppGpuImage));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostGpuImage), @alignOf(AppGpuImage));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImage, "dest_x"), @offsetOf(AppGpuImage, "dest_x"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImage, "origin_x"), @offsetOf(AppGpuImage, "origin_x"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImage, "src_u0"), @offsetOf(AppGpuImage, "src_u0"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImage, "z"), @offsetOf(AppGpuImage, "z"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImage, "pass"), @offsetOf(AppGpuImage, "pass"));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostGpuImageUpload), @sizeOf(AppGpuImageUpload));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostGpuImageUpload), @alignOf(AppGpuImageUpload));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImageUpload, "generation"), @offsetOf(AppGpuImageUpload, "generation"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImageUpload, "pixels_offset"), @offsetOf(AppGpuImageUpload, "pixels_offset"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostGpuImageUpload, "pixels_len"), @offsetOf(AppGpuImageUpload, "pixels_len"));
    // frame에 추가된 kitty graphics 채널 필드(append-only) — 위치 대조로 C↔Zig 정합 보장.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "gpu_images"), @offsetOf(AppMetalFrame, "gpu_images"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "image_uploads"), @offsetOf(AppMetalFrame, "image_uploads"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "image_pixels"), @offsetOf(AppMetalFrame, "image_pixels"));
    // K4c: 텍스처 eviction용 live image id 집합 채널.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "live_image_ids"), @offsetOf(AppMetalFrame, "live_image_ids"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "live_image_id_count"), @offsetOf(AppMetalFrame, "live_image_id_count"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "terminal_bg"), @offsetOf(AppMetalFrame, "terminal_bg"));
    // v66: 상단 타이틀바 띠 높이(접힘 펼치기 토글 ◧ 세로 중앙 정렬용) — 끝에 추가, 위치 대조로 C↔Zig 정합 보장.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "titlebar_strip_px"), @offsetOf(AppMetalFrame, "titlebar_strip_px"));
    // v70: 창 배경 투명도 × 1000(clear color alpha) — 끝에 추가, 위치 대조로 C↔Zig 정합 보장.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "window_opacity_milli"), @offsetOf(AppMetalFrame, "window_opacity_milli"));
    // v86: 사이드바 세로 스크롤량(px) — 끝에 추가, 위치 대조로 C↔Zig 정합 보장.
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostMetalFrame, "sidebar_scroll_offset_px"), @offsetOf(AppMetalFrame, "sidebar_scroll_offset_px"));
    // v99 Phase 4c: 웹 패널 surface 전이 struct — mixed-width(u32/u64/f64)라 @sizeOf만으론 필드 reorder를 못 잡으므로
    // 모든 필드 offset을 C↔Zig 대조한다(surface_id↔frame_pt 뒤바뀌면 Swift가 엉뚱한 frame을 읽는다).
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostWebSurfaceTransition), @sizeOf(WebSurfaceTransitionAbi));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostWebSurfaceTransition), @alignOf(WebSurfaceTransitionAbi));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "op"), @offsetOf(WebSurfaceTransitionAbi, "op"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "visible"), @offsetOf(WebSurfaceTransitionAbi, "visible"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "surface_id"), @offsetOf(WebSurfaceTransitionAbi, "surface_id"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "panel_kind"), @offsetOf(WebSurfaceTransitionAbi, "panel_kind"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "seam_edges"), @offsetOf(WebSurfaceTransitionAbi, "seam_edges")); // v103: panel_kind 뒤 pad 자리(size 불변)
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "divider_grab_left_pt"), @offsetOf(WebSurfaceTransitionAbi, "divider_grab_left_pt"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "divider_grab_right_pt"), @offsetOf(WebSurfaceTransitionAbi, "divider_grab_right_pt"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "divider_grab_bottom_pt"), @offsetOf(WebSurfaceTransitionAbi, "divider_grab_bottom_pt"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "frame_pt_x"), @offsetOf(WebSurfaceTransitionAbi, "frame_pt_x"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "frame_pt_y"), @offsetOf(WebSurfaceTransitionAbi, "frame_pt_y"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "frame_pt_w"), @offsetOf(WebSurfaceTransitionAbi, "frame_pt_w"));
    try std.testing.expectEqual(@offsetOf(c.MaruAppHostWebSurfaceTransition, "frame_pt_h"), @offsetOf(WebSurfaceTransitionAbi, "frame_pt_h"));
    // op enum 값(C ↔ session_mod.WebSurfaceOp) 정합 — Swift switch가 이 정수로 분기하므로 값이 어긋나면 안 된다.
    try std.testing.expectEqual(@as(u32, c.MaruAppHostWebSurfaceOpNone), @intFromEnum(session_mod.WebSurfaceOp.none));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostWebSurfaceOpCreate), @intFromEnum(session_mod.WebSurfaceOp.create));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostWebSurfaceOpDestroy), @intFromEnum(session_mod.WebSurfaceOp.destroy));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostWebSurfaceOpReframe), @intFromEnum(session_mod.WebSurfaceOp.reframe));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostWebSurfaceOpHide), @intFromEnum(session_mod.WebSurfaceOp.hide));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostWebSurfaceOpShow), @intFromEnum(session_mod.WebSurfaceOp.show));
}

test "browser wait revoke/close matching preserves capability-origin and isolates pane grant key" {
    const capability_origin: ActiveBrowserWait = .{ .async_id = 1, .surface_id = 11, .pane_grant = null };
    try std.testing.expect(!waitOriginMatchesGrant(capability_origin, 5, 11, .browser));
    try std.testing.expectEqual(control_browser.BrowserCompletionStatus.process_exited, waitStatusForClosedSurface(capability_origin, 11).?);
    try std.testing.expect(waitStatusForClosedSurface(capability_origin, 5) == null); // capability-origin은 pane close와 무관

    const pane_origin: ActiveBrowserWait = .{
        .async_id = 2,
        .surface_id = 11,
        .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser },
    };
    try std.testing.expect(waitOriginMatchesGrant(pane_origin, 5, 11, .browser));
    try std.testing.expect(!waitOriginMatchesGrant(pane_origin, 6, 11, .browser));
    try std.testing.expect(!waitOriginMatchesGrant(pane_origin, 5, 12, .browser));
    try std.testing.expect(!waitOriginMatchesGrant(pane_origin, 5, 11, .browser_storage));
    try std.testing.expectEqual(control_browser.BrowserCompletionStatus.process_exited, waitStatusForClosedSurface(pane_origin, 11).?);
    try std.testing.expectEqual(control_browser.BrowserCompletionStatus.unauthorized, waitStatusForClosedSurface(pane_origin, 5).?);
    try std.testing.expect(waitStatusForClosedSurface(pane_origin, 6) == null);
}

test "live hello capabilities advertise browser.wait and only parsed browser methods" {
    var wait_count: usize = 0;
    for (control_hello_caps) |method| {
        const parsed = control_plane.parseMethod(method);
        if (parsed.core != .browser) continue;
        try std.testing.expect(control_browser.parseBrowserMethod(parsed.rest) != null);
        if (std.mem.eql(u8, method, "browser.wait")) wait_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), wait_count);
}

test "macOS app host capabilities describe ownership before runtime exists" {
    var capabilities: Capabilities = undefined;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_host_capabilities(&capabilities));
    try std.testing.expectEqual(abi_version, capabilities.abi_version);
    try std.testing.expectEqual(@as(u32, 1), capabilities.swift_owns_ns_application);
    try std.testing.expectEqual(@as(u32, 1), capabilities.swift_owns_window_lifecycle);
    try std.testing.expectEqual(@as(u32, 1), capabilities.swift_owns_focus_and_input);
    try std.testing.expectEqual(@as(u32, 1), capabilities.zig_owns_live_pty_sessions);
    try std.testing.expectEqual(@as(u32, 1), capabilities.zig_owns_frame_loop);
    try std.testing.expectEqual(@as(u32, 1), capabilities.objective_c_smokes_remain);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_host_capabilities(null));
}

test "macOS app host event DTOs are explicit fixed-width C ABI records" {
    // Swift struct layout을 추측해서 포인터로 넘기면 위험하다. C header와 같은 fixed-width
    // record만 ABI에 둬야 key input, resize, close event가 platform 별로 흔들리지 않는다.
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(KeyEvent));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ResizeEvent));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(KeyEvent));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(ResizeEvent));
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(AppSessionConfig)); // 11 u32(abi/cols/rows/queue/cmd/chrome_minimal/minimal_tabs/defer_initial_surface + width_px/height_px/scale_milli)
    try std.testing.expectEqual(@as(usize, 176), @sizeOf(AppFrameSummary)); // quit_decision(u32,v90)+web_surfaces_present(u32,v102)가 168→176 정렬 패딩을 채워 176 불변
    try std.testing.expectEqual(@as(usize, 8), @alignOf(AppFrameSummary));
    try std.testing.expectEqual(@as(u32, @intFromEnum(session_mod.FileTreeRootOperation.none)), @as(u32, c.MARU_FILE_TREE_ROOT_PICK_NONE));
    try std.testing.expectEqual(@as(u32, @intFromEnum(session_mod.FileTreeRootOperation.replace)), @as(u32, c.MARU_FILE_TREE_ROOT_PICK_REPLACE));
    try std.testing.expectEqual(@as(u32, @intFromEnum(session_mod.FileTreeRootOperation.add)), @as(u32, c.MARU_FILE_TREE_ROOT_PICK_ADD));
}

test "FP7 watch-root ABI short output reports required length without consuming one-shot" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "page.md", .data = "# page" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "page.md" });
    defer std.testing.allocator.free(path);

    const config: AppSessionConfig = .{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(AppCommandKind.controlled_smoke),
    };
    var session: ?*AppSession = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_session_create(&config, &session));
    defer maru_macos_app_session_destroy(session);
    try std.testing.expectEqual(@as(u32, 1), maru_macos_app_session_open_file_panel_path(session, path.ptr, path.len));

    const required = maru_macos_app_session_take_file_tree_watch_root(session, null, 0);
    try std.testing.expect(required > 1);
    var short: [1]u8 = undefined;
    try std.testing.expectEqual(required, maru_macos_app_session_take_file_tree_watch_root(session, &short, short.len));
    const out = try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(required, maru_macos_app_session_take_file_tree_watch_root(session, out.ptr, out.len));
    try std.testing.expectEqual(@as(usize, 0), maru_macos_app_session_take_file_tree_watch_root(session, out.ptr, out.len));
}

test "Explorer v137 root picker ABI drains typed operations and cancel or invalid input is inert" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const config: AppSessionConfig = .{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(AppCommandKind.controlled_smoke),
    };
    var session: ?*AppSession = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_session_create(&config, &session));
    defer maru_macos_app_session_destroy(session);

    session.?.file_tree_root_pick_pending = .replace;
    try std.testing.expectEqual(@as(u32, c.MARU_FILE_TREE_ROOT_PICK_REPLACE), maru_macos_app_session_take_file_tree_root_pick_request(session));
    try std.testing.expectEqual(@as(u32, c.MARU_FILE_TREE_ROOT_PICK_NONE), maru_macos_app_session_take_file_tree_root_pick_request(session));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_session_provide_file_tree_root_pick(session, null, 0));
    try std.testing.expectEqual(session_mod.FileTreeRootOperation.none, session.?.file_tree_root_picker_inflight);

    session.?.file_tree_root_pick_pending = .add;
    try std.testing.expectEqual(@as(u32, c.MARU_FILE_TREE_ROOT_PICK_ADD), maru_macos_app_session_take_file_tree_root_pick_request(session));
    const generation = session.?.file_tree.rootGeneration();
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_session_provide_file_tree_root_pick(session, "relative", "relative".len));
    try std.testing.expectEqual(generation, session.?.file_tree.rootGeneration());
    try std.testing.expect(session.?.file_tree_root_validation == null);
}

test "workspace restore ABI preserves multi-window count active and apply" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const config: AppSessionConfig = .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(AppCommandKind.controlled_smoke),
    };
    var session0: ?*AppSession = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_session_create(&config, &session0));
    defer maru_macos_app_session_destroy(session0);
    var deferred_config = config;
    deferred_config.defer_initial_surface = 1;
    var session1: ?*AppSession = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_session_create(&deferred_config, &session1));
    defer maru_macos_app_session_destroy(session1);
    try std.testing.expectEqual(@as(usize, 0), session1.?.tabs.items.len); // restore 전 throwaway tab/PTY 0.
    try std.testing.expect(!session1.?.surface_initialized);

    const text =
        "maru.workspace.v1\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=2 active-pane=1 custom-name=\"first\"\n" ++
        "tree-node split vertical ratio=300\n" ++
        "tree-node leaf pane=0\n" ++
        "tree-node leaf pane=1\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"left\"\n" ++
        "surface custom-name=\"one\" title=\"\" cwd=\"/tmp\" command=\"\" cols=40 rows=12\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"right\"\n" ++
        "surface custom-name=\"two\" title=\"\" cwd=\"/\" command=\"\" cols=40 rows=12\n" ++
        "window tabs=1 active-tab=0 active-window=1\n" ++
        "tab panes=1 active-pane=0 custom-name=\"second\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"only\"\n" ++
        "surface custom-name=\"three\" title=\"\" cwd=\"/tmp\" command=\"\" cols=50 rows=15\n";

    try std.testing.expectEqual(@as(i64, 2), maru_macos_app_session_workspace_window_count(session0, text.ptr, text.len));
    try std.testing.expectEqual(@as(i64, 2), maru_macos_app_session_workspace_window_count(null, text.ptr, text.len));
    try std.testing.expectEqual(@as(i64, 1), maru_macos_app_session_workspace_active_window(session0, text.ptr, text.len));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_session_apply_workspace_window(session0, text.ptr, text.len, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_session_apply_workspace_window(session1, text.ptr, text.len, 1));
    try std.testing.expectEqual(@as(usize, 1), session0.?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), session0.?.tabs.items[0].panes.items.len);
    try std.testing.expectEqual(@as(usize, 1), session0.?.tabs.items[0].active_pane);
    try std.testing.expectEqualStrings("first", session0.?.tabs.items[0].custom_name.?);
    try std.testing.expectEqual(@as(usize, 1), session1.?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), session1.?.tabs.items[0].panes.items.len);
    try std.testing.expectEqualStrings("second", session1.?.tabs.items[0].custom_name.?);
    try std.testing.expect(session1.?.surface_initialized);
}

test "workspace preflight ABI rejects cross-window duplicate runtime owner before session creation" {
    const text =
        "maru.workspace.v1\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=1 active-pane=0 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" runtime-handle=\"fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdef\" cols=80 rows=24\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=1 active-pane=0 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" runtime-handle=\"fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdef\" cols=80 rows=24\n";
    try std.testing.expectEqual(
        @as(i64, -1),
        maru_macos_app_session_workspace_window_count(null, text.ptr, text.len),
    );
    if (@import("builtin").os.tag != .macos) return;
    const config: AppSessionConfig = .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(AppCommandKind.controlled_smoke),
        .defer_initial_surface = 1,
    };
    var session: ?*AppSession = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_session_create(&config, &session));
    defer maru_macos_app_session_destroy(session);
    session.?.restore_runtime_host_id = "preflight-sentinel";
    session.?.restore_runtime_id = "preflight-sentinel";
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.invalid_config)),
        maru_macos_app_session_apply_workspace_window(session, text.ptr, text.len, 0),
    );
    try std.testing.expectEqual(@as(usize, 0), session.?.tabs.items.len);
    try std.testing.expectEqualStrings("preflight-sentinel", session.?.restore_runtime_host_id);
    try std.testing.expectEqualStrings("preflight-sentinel", session.?.restore_runtime_id);
}

test "Metal key-down ABI: 터미널이 활성이면 Cmd+W가 파일 패널을 건드리지 않는다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dirty.md", .data = "# dirty" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "dirty.md" });
    defer std.testing.allocator.free(path);

    const config: AppSessionConfig = .{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(AppCommandKind.controlled_smoke),
    };
    var session: ?*AppSession = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_session_create(&config, &session));
    defer maru_macos_app_session_destroy(session);
    try std.testing.expectEqual(@as(u32, 1), maru_macos_app_session_open_file_panel_path(session, path.ptr, path.len));
    const entry = session.?.fileEntryAt(0).?;
    entry.mode = .source_edit;
    entry.dirty = true;
    // FP16 §3.4: 입력 소유가 별도 축이 아니라 **활성 Term**에서 파생되면서, "logical owner만 stale"이라는
    // 상태 자체가 구조적으로 불가능해졌다. 남은 계약은 그 불변식이다 — 터미널이 활성이면 ⌘W는 파일
    // 패널을 건드리지 않고 터미널 cascade를 따른다.
    session.?.focusTerm(0);
    try std.testing.expectEqual(@as(?u64, null), session.?.focusedDockSurface());

    const event: KeyEvent = .{
        .codepoint = 'w',
        .base_codepoint = 'w',
        .key_code = 0,
        .modifier_shift = 0,
        .modifier_control = 0,
        .modifier_option = 0,
        .modifier_command = 1,
        .is_repeat = 0,
        .raw_key_code = 0x0D,
    };
    var summary: AppFrameSummary = undefined;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_session_key_down(session, &event, &summary));
    var request_id: u64 = 0;
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_take_file_panel_dirty_sync_action_v2(session, &request_id));
    try std.testing.expect(session.?.pending_file_panel_close == null);
    try std.testing.expect(session.?.focus_owner == .workspace);
}

test "macOS app exported session API reports null outputs as ABI errors" {
    const config: AppSessionConfig = .{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(AppCommandKind.controlled_smoke),
    };
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_create(&config, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_tick(null, maru.config.theme.render_frame_rate_default, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_key_down(null, null, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_set_agent_session_archive_detail_smoke_gate(null, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        maru_macos_app_session_agent_session_archive_detail_smoke_gate_reached(null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_set_agent_session_archive_smoke_gate(null, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        maru_macos_app_session_agent_session_archive_smoke_gate_reached(null),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        maru_macos_app_session_agent_session_archive_smoke_active_surface_id(null),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        maru_macos_app_session_agent_session_archive_smoke_term_count(null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_agent_session_archive_smoke_probe(null, c.MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_CARD, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_input_smoke_probe(null, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_resize(null, null, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_session_close(null, null),
    );
    // v18~v21 신규 IME/focus export도 null session을 ABI 오류로 닫는지 — 헤더에 선언만 되고
    // 계약 테스트가 안 건드리던 공백(리뷰 #13)을 메운다(심볼 존재 + null-safety 동시 확인).
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_ime_begin(null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_ime_insert(null, null, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_ime_marked(null, null, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_ime_end(null, null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_ime_delete_backward(null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_set_focus(null, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_ime_cursor_rect(null, null, null, null, null));
    // v40 chrome Notice: null session은 ABI 오류, null bytes(len>0)도 오류, len==0은 무동작 ok(붙여넣기와 같은 규율).
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_show_notice(null, null, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_show_notice(null, "x", 1));
    // M3f workspace_window_frame: null session·null out 포인터는 -1(조용한 폴백 = count/active-window와 동형, Status가
    // 아니라 present/absent/fail의 정수 신호). Swift는 -1/0을 "frame 없음 → 현행 기본"으로 동일 처리한다.
    try std.testing.expectEqual(@as(c_int, -1), maru_macos_app_session_workspace_window_frame(null, null, 0, 0, null, null, null, null));
    // v106 Phase 7e-3 take_web_nav_action: null session·null out-ptr는 -1(신호 없음/유실 방지 — take_web_addr_navigate 동형).
    try std.testing.expectEqual(@as(i32, -1), maru_macos_app_session_take_web_nav_action(null, null));
    var nav_action_sid: u64 = 0;
    try std.testing.expectEqual(@as(i32, -1), maru_macos_app_session_take_web_nav_action(null, &nav_action_sid));
    // v107 Phase 7e-4 browser_nav: null session은 0(무동작). 알 수 없는 code(3)도 0 — 세션 있어도 매핑 안 되면 무동작이나
    // 여기선 null session이 먼저라 0. (활성 판정·pending 세움은 코어 setBrowserNavAction 헤드리스 테스트가 덮는다.)
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_app_session_browser_nav(null, 42, 0));
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_app_session_browser_nav(null, 42, 3));
    // v108 Phase 7e-4 후속 active_web_surface_id: null session은 0(browser 아님 sentinel).
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_active_web_surface_id(null));
    // v112 Phase 4g-0 active_web_surface_id_any_kind: null session은 0(web 아님 sentinel).
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_active_web_surface_id_any_kind(null));
    // v114 Phase 4g-1 후속 terminal_owns_input: null session은 0.
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_terminal_owns_input(null));
    // v121 FP5 파일 패널: null session은 one-shot 없음, open 실패, entry 없음으로 안전하게 접힌다.
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_take_file_panel_pick_request(null));
    try std.testing.expectEqual(@as(u32, 2), maru_macos_app_session_open_file_panel_path(null, "x", 1));
    // v137 탐색기 root picker: null session은 요청 없음, provide는 typed null_out이다.
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_take_file_tree_root_pick_request(null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.null_out)), maru_macos_app_session_provide_file_tree_root_pick(null, null, 0));
    var file_panel_path: ?[*]const u8 = undefined;
    var file_panel_path_len: usize = 99;
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_file_panel_entry(null, 1, &file_panel_path, &file_panel_path_len));
    try std.testing.expect(file_panel_path == null);
    try std.testing.expectEqual(@as(usize, 0), file_panel_path_len);
    // v124 FP8 native file-panel focus sync: null session은 파일 surface가 아니므로 0.
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_focus_file_panel_surface(null, 1));
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_complete_pending_dock_focus(null, 1));
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_pending_dock_focus_surface(null));
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_focused_dock_surface(null));
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_take_pending_dock_focus_action(null));
    // v125 외부 링크 action: null/stale ABI 입력은 열기·action 모두 0으로 닫는다.
    var external_link_buf: [8]u8 = undefined;
    var external_link_sid: u64 = 99;
    var external_link_kind: u32 = 99;
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_open_file_panel_link(null, 1, "https://example.com", 19, 0));
    try std.testing.expectEqual(
        @as(usize, 0),
        maru_macos_app_session_take_external_link_action(
            null,
            &external_link_buf,
            external_link_buf.len,
            &external_link_sid,
            &external_link_kind,
        ),
    );
    // v126 focus/save-close additions: null session은 무동작/one-shot 없음.
    maru_macos_app_session_focus_workspace_input(null);
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_take_workspace_focus_action(null));
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_take_file_tree_focus_action(null));
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_take_file_tree_restore_surface_action(null));
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_take_workspace_restore_dropped(null)); // v144
    var save_request_id: u64 = 99;
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_take_file_panel_save_close_action(null, &save_request_id));
    var dirty_request_id: u64 = 99;
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_take_file_panel_dirty_sync_action_v2(null, &dirty_request_id));
    maru_macos_app_session_fail_file_panel_dirty_sync(null, 1, 1);
    maru_macos_app_session_complete_file_panel_save_close(null, 1, 1, 1, 1);
    var unlock_request_id: u64 = 99;
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_take_file_panel_close_unlock_action(null, &unlock_request_id));
    maru_macos_app_session_fail_file_panel_close_unlock(null, 1, 1);
    // v123 FP7 파일 트리: null session은 watcher/reload/external-open 신호 없음이며 changed event는 무동작.
    try std.testing.expectEqual(@as(u32, 0), maru_macos_app_session_take_file_tree_watch_reset(null));
    var file_tree_buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), maru_macos_app_session_take_file_tree_watch_root(null, &file_tree_buf, file_tree_buf.len));
    maru_macos_app_session_file_tree_changed(null, "/tmp/a", 6);
    var file_tree_conflict: u32 = 99;
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_take_file_tree_reload_action(null, &file_tree_conflict));
    try std.testing.expectEqual(@as(u32, 0), file_tree_conflict);
    try std.testing.expectEqual(@as(usize, 0), maru_macos_app_session_take_file_tree_external_open(null, &file_tree_buf, file_tree_buf.len));
    var trash_request_id: u64 = 99;
    var trash_device: u64 = 99;
    var trash_inode: u64 = 99;
    var trash_kind: u32 = 99;
    try std.testing.expectEqual(@as(usize, 0), maru_macos_app_session_take_file_tree_trash_action(
        null,
        &file_tree_buf,
        file_tree_buf.len,
        &trash_request_id,
        &trash_device,
        &trash_inode,
        &trash_kind,
    ));
    maru_macos_app_session_complete_file_tree_trash(null, 1, c.MARU_FILE_TREE_TRASH_OUTCOME_MOVED_VERIFIED, null, 0);
    // v109 Phase 7f-0 create_adopted_web_term: null session은 0(생성 실패 sentinel).
    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_create_adopted_web_term(null));
    // v111 Phase 7f-2 popup_target_allowed: null url_ptr는 -1(정책 판정 전 방어). 실 정책은 app_scheme 헤드리스 테스트.
    try std.testing.expectEqual(@as(c_int, -1), maru_macos_app_popup_target_allowed(null, 5));
}

test {
    std.testing.refAllDecls(session_mod);
    // 전역 핫키 descriptor 매핑(a2의 Swift가 ABI로 소비)도 테스트 빌드에 포함한다.
    std.testing.refAllDecls(@import("global_hotkey.zig"));
    // 커맨드 카탈로그(메뉴바·팝업 공유) round-trip·chord 포맷 테스트도 테스트 빌드에 포함한다.
    std.testing.refAllDecls(@import("command_catalog.zig"));
    // 커맨드 팝업 상태머신(필터·선택·selectedAction) 테스트도 테스트 빌드에 포함한다.
    std.testing.refAllDecls(@import("command_palette.zig"));
    // 스크롤백 Find는 chrome 컴포넌트(maru.chrome.components.find)로 이주 — 그 테스트는 maru.chrome 집계가 포함.
}

test "layout-independent shortcut: Hangul-mode Ctrl+B normalizes to latin b via the physical keycode" {
    // 한글 입력 모드에서 Ctrl+B: AppKit 글자는 'ㅂ'(0x3142)이지만 물리 키코드는 B(0x0B).
    const event = KeyEvent{
        .codepoint = 0x3142, // 'ㅂ'
        .base_codepoint = 0x3142, // shift 없음 → base도 'ㅂ'; keyEventFromAbi가 US 'b'로 정규화
        .key_code = 0, // unknown
        .modifier_shift = 0,
        .modifier_control = 1,
        .modifier_option = 0,
        .modifier_command = 0,
        .is_repeat = 0,
        .raw_key_code = 0x0B, // kVK_ANSI_B
    };
    const key_event = try keyEventFromAbi(event);
    try std.testing.expectEqual(terminal.Key{ .char = 'b' }, key_event.key);
    try std.testing.expect(key_event.modifiers.control);
    // 인코딩까지: Ctrl+b -> 0x02 (멀티플렉서 prefix가 한글 모드에서도 동작).
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const encoded = try terminal.input.encodeKey(key_event, &buffer, .{});
    try std.testing.expectEqualSlices(u8, &.{0x02}, encoded);
}

test "latin layouts are preserved: Ctrl+B with an ascii codepoint does not consult the keycode table" {
    // Dvorak 등 라틴 배열: 현재 레이아웃 결과(ASCII)를 존중한다 — 물리 키코드로 덮지 않는다.
    const event = KeyEvent{
        .codepoint = 'x', // Dvorak에서 다른 물리 키가 'x'를 낼 수 있다
        .base_codepoint = 'x',
        .key_code = 0,
        .modifier_shift = 0,
        .modifier_control = 1,
        .modifier_option = 0,
        .modifier_command = 0,
        .is_repeat = 0,
        .raw_key_code = 0x0B, // 물리 B여도
    };
    const key_event = try keyEventFromAbi(event);
    try std.testing.expectEqual(terminal.Key{ .char = 'x' }, key_event.key);
}

test "keyEventFromAbi maps function keys to terminal.Key" {
    const mk = struct {
        fn f(code: KeyCode) KeyEvent {
            return .{ .codepoint = 0, .base_codepoint = 0, .key_code = @intFromEnum(code), .modifier_shift = 0, .modifier_control = 0, .modifier_option = 0, .modifier_command = 0, .is_repeat = 0, .raw_key_code = 0 };
        }
    }.f;
    try std.testing.expectEqual(terminal.input.Key.delete, (try keyEventFromAbi(mk(.delete))).key);
    try std.testing.expectEqual(terminal.input.Key.page_up, (try keyEventFromAbi(mk(.page_up))).key);
    try std.testing.expectEqual(terminal.input.Key.home, (try keyEventFromAbi(mk(.home))).key);
    try std.testing.expectEqual(@as(u8, 1), (try keyEventFromAbi(mk(.f1))).key.function);
    try std.testing.expectEqual(@as(u8, 12), (try keyEventFromAbi(mk(.f12))).key.function);
}

test "keypad Enter chains through ABI to terminal .enter (keypad=true) — confirm 모달이 닫히고, app keypad는 SS3" {
    // 키패드 Enter는 Swift normalizedKeyEvent가 메인 Return과 같이 key_code=Enter로 매핑하고 codepoint=0으로 넘긴다.
    // raw_key_code=0x4C(kVK_ANSI_KeypadEnter)라 keycode.isKeypad가 keypad=true를 채운다. 회귀: 이 매핑이 빠지면
    // codepoint(NSEnterCharacter 0x03)가 흘러 `.char`가 되고, chrome 확인 모달의 `.enter` 분기가 안 잡혀 안 닫혔다.
    const abi_event = KeyEvent{
        .codepoint = 0, // Swift가 keypad Enter를 잡아 codepoint를 비운다(default로 안 떨어짐)
        .base_codepoint = 0,
        .key_code = @intFromEnum(KeyCode.enter),
        .modifier_shift = 0,
        .modifier_control = 0,
        .modifier_option = 0,
        .modifier_command = 0,
        .is_repeat = 0,
        .raw_key_code = 0x4C, // kVK_ANSI_KeypadEnter
    };
    const ev = try keyEventFromAbi(abi_event);
    try std.testing.expectEqual(terminal.input.Key.enter, ev.key); // chrome 모달의 `.enter` 경로를 탄다
    try std.testing.expect(ev.keypad); // numpad 판정은 물리 키코드로 보존
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    // numeric(기본) keypad → CR. application keypad(DECKPAM) → SS3 `ESC O M`. raw 0x03이 아니다.
    try std.testing.expectEqualStrings("\r", try terminal.input.encodeKey(ev, &buf, .{}));
    try std.testing.expectEqualStrings("\x1bOM", try terminal.input.encodeKey(ev, &buf, .{ .application_keypad = true }));
}

test "Option+Backspace chains through ABI to meta-DEL (\\e\\x7f, word delete)" {
    const abi_event = KeyEvent{
        .codepoint = 0,
        .base_codepoint = 0,
        .key_code = @intFromEnum(KeyCode.backspace),
        .modifier_shift = 0,
        .modifier_control = 0,
        .modifier_option = 1,
        .modifier_command = 0,
        .is_repeat = 0,
        .raw_key_code = 51,
    };
    const ev = try keyEventFromAbi(abi_event);
    try std.testing.expect(ev.modifiers.option);
    try std.testing.expectEqual(terminal.input.Key.backspace, ev.key);
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b\x7f", try terminal.input.encodeKey(ev, &buf, .{}));
}

// 5e-2b: BrowserOpQueue FIFO push/take + bounded + cancel-remove/deinit(arg 해제). arg 소유권 이전 규약을 testing.allocator로
// 검증(누수/이중free 없음). ABI take/complete_browser_op 글루·handleControlRequest defer는 5e-2b-2 macos smoke가 e2e로.
test "5e-2b BrowserOpQueue: FIFO push/take + bounded(Full) + cancel remove가 capacity/arg 회수" {
    const gpa = std.testing.allocator;
    var q: BrowserOpQueue = .{ .max = 2 };
    // push 2개(각 arg는 gpa 소유 — 큐가 인수).
    try q.push(gpa, .{ .async_id = 1, .surface_id = 10, .op_kind = 0, .arg = try gpa.dupe(u8, "https://a") });
    try q.push(gpa, .{ .async_id = 2, .surface_id = 11, .op_kind = 2, .arg = try gpa.dupe(u8, "1+1") });
    // 3번째는 bounded → Full(호출자가 arg free 책임 — 여기선 dupe 안 하고 바로 검사).
    try std.testing.expectError(error.Full, q.push(gpa, .{ .async_id = 3, .surface_id = 12, .op_kind = 1, .arg = "" }));
    // close/revoke terminal이 queued 2번을 취소하면 물리 entry와 arg를 즉시 회수해 다른 surface push를 막지 않는다.
    try std.testing.expect(q.remove(gpa, 2));
    try std.testing.expect(!q.remove(gpa, 2));
    try q.push(gpa, .{ .async_id = 3, .surface_id = 12, .op_kind = 1, .arg = try gpa.dupe(u8, "") });
    // FIFO take: 1번 먼저. arg 소유권 이전 → 호출자 free.
    const e1 = q.take().?;
    try std.testing.expectEqual(@as(u64, 1), e1.async_id);
    try std.testing.expectEqual(@as(u8, 0), e1.op_kind);
    try std.testing.expectEqualStrings("https://a", e1.arg);
    gpa.free(e1.arg);
    // 남은 1개(async_id 3)는 deinit이 arg 해제(누수 없음 — testing.allocator가 잡음).
    q.deinit(gpa, gpa);
}

test "5f-5b ActiveBrowserExecutions: busy, queued cancel, running abandon, shrink, duplicate terminal" {
    const gpa = std.testing.allocator;
    var executions = ActiveBrowserExecutions.init(10, 2);
    defer executions.deinit(gpa);
    const provenance: ExecutionProvenance = .{ .capability = .{ .nonce = [_]u8{0xA5} ** control_capability.nonce_len, .generation = 0 } };

    try executions.admit(gpa, .{ .async_id = 1, .surface_id = 11, .reserved_bytes = 6, .provenance = provenance });
    try std.testing.expectEqual(@as(usize, 6), executions.budget.usedBytes());
    try std.testing.expectError(error.ResourceBusy, executions.admit(gpa, .{ .async_id = 2, .surface_id = 11, .reserved_bytes = 5, .provenance = provenance }));
    try std.testing.expectEqual(@as(usize, 1), executions.items.items.len);

    executions.abandon(1); // queued: backend 미시작 → 즉시 반환
    try std.testing.expectEqual(@as(usize, 0), executions.budget.usedBytes());
    try std.testing.expect(executions.get(1) == null);

    try executions.admit(gpa, .{ .async_id = 3, .surface_id = 11, .reserved_bytes = 10, .provenance = provenance });
    try std.testing.expect(executions.markRunning(3));
    executions.abandon(3); // running: callback 전까지 pin
    try std.testing.expectEqual(ExecutionPhase.abandoned, executions.get(3).?.phase);
    try std.testing.expectEqual(@as(usize, 10), executions.budget.usedBytes());
    try std.testing.expect(executions.finish(3));
    try std.testing.expect(!executions.finish(3)); // duplicate/late terminal은 no-op
    try std.testing.expectEqual(@as(usize, 0), executions.budget.usedBytes());

    try executions.admit(gpa, .{ .async_id = 4, .surface_id = 11, .reserved_bytes = 10, .provenance = provenance });
    try std.testing.expect(executions.markRunning(4));
    try std.testing.expect(executions.beginTransfer(4, 44, 3));
    try std.testing.expectEqual(ExecutionPhase.transferring, executions.get(4).?.phase);
    try std.testing.expectEqual(@as(u64, 44), executions.get(4).?.transfer_id);
    try std.testing.expectEqual(@as(usize, 3), executions.budget.usedBytes());
    try std.testing.expect(executions.finish(4));
    try std.testing.expectEqual(@as(usize, 0), executions.budget.usedBytes());

    try executions.admit(gpa, .{ .async_id = 5, .surface_id = 11, .reserved_bytes = 5, .provenance = provenance });
    try executions.admit(gpa, .{ .async_id = 6, .surface_id = 11, .reserved_bytes = 5, .provenance = provenance });
    try std.testing.expect(executions.markRunning(6));
    executions.stop();
    try std.testing.expect(executions.get(5) == null); // queued는 stop 즉시 반환
    try std.testing.expectEqual(ExecutionPhase.abandoned, executions.get(6).?.phase);
    try std.testing.expectEqual(@as(usize, 5), executions.budget.usedBytes());
    try std.testing.expectError(error.ResourceBusy, executions.admit(gpa, .{ .async_id = 7, .surface_id = 11, .reserved_bytes = 6, .provenance = provenance }));
    try std.testing.expect(executions.finish(6)); // late callback/backend terminal
    try executions.admit(gpa, .{ .async_id = 7, .surface_id = 11, .reserved_bytes = 6, .provenance = provenance });
    try std.testing.expect(executions.finish(7));

    var slots = ActiveBrowserExecutions.init(100, 1);
    defer slots.deinit(gpa);
    try slots.admit(gpa, .{ .async_id = 8, .surface_id = 11, .reserved_bytes = 1, .provenance = provenance });
    try std.testing.expectError(error.ExecutionSlotsFull, slots.admit(gpa, .{ .async_id = 9, .surface_id = 11, .reserved_bytes = 1, .provenance = provenance }));
}

test "browser op lifecycle classification and exact authorization method stay exhaustive" {
    const Case = struct { method: control_browser.BrowserMethod, scope: control_capability.ScopeClass, reserved: usize };
    const cases = [_]Case{
        .{ .method = .navigate, .scope = .browser, .reserved = 0 },
        .{ .method = .get_url, .scope = .browser, .reserved = 0 },
        .{ .method = .execute_script, .scope = .browser, .reserved = 123 },
        .{ .method = .get_cookies, .scope = .browser_storage, .reserved = 0 },
        .{ .method = .screenshot, .scope = .browser, .reserved = control_browser.screenshot_max_result_bytes },
        .{ .method = .set_cookie, .scope = .browser_storage, .reserved = 0 },
        .{ .method = .delete_cookie, .scope = .browser_storage, .reserved = 0 },
        .{ .method = .get_local_storage, .scope = .browser, .reserved = 0 },
        .{ .method = .set_local_storage, .scope = .browser, .reserved = 0 },
        .{ .method = .remove_local_storage, .scope = .browser, .reserved = 0 },
        .{ .method = .clear_storage, .scope = .browser_storage, .reserved = 0 },
        .{ .method = .click, .scope = .browser, .reserved = 0 },
        .{ .method = .type_text, .scope = .browser, .reserved = 0 },
        .{ .method = .scroll, .scope = .browser, .reserved = 0 },
    };
    for (cases) |case| {
        try std.testing.expect(browserMethodHasTrackedLifecycle(case.method));
        try std.testing.expectEqual(case.scope, control_capability.methodRequiredScope(browserMethodWireName(case.method)).?);
        try std.testing.expectEqual(case.reserved, browserMethodReservedBytes(case.method, 123));
    }
    try std.testing.expect(!browserMethodHasTrackedLifecycle(.subscribe));
    try std.testing.expect(!browserMethodHasTrackedLifecycle(.wait));
}

fn lifecycleTestServer() control_server_mod.ControlServer {
    var server: control_server_mod.ControlServer = undefined;
    server.in_flight = .empty;
    server.items_gpa = std.testing.allocator;
    server.cross_gpa = allocator;
    server.max_in_flight = 8;
    return server;
}

const LifecycleTestGlobalsGuard = struct {
    saved_executions: ActiveBrowserExecutions,
    saved_queue: BrowserOpQueue,
    saved_transfers: ActiveBrowserTransfers,
    saved_scratch: std.ArrayList(u8),

    fn install() LifecycleTestGlobalsGuard {
        const guard = LifecycleTestGlobalsGuard{
            .saved_executions = active_browser_executions,
            .saved_queue = browser_op_queue,
            .saved_transfers = active_browser_transfers,
            .saved_scratch = browser_transfer_scratch,
        };
        active_browser_executions = ActiveBrowserExecutions.init(execution_result_budget_bytes, 8);
        browser_op_queue = .{};
        active_browser_transfers = .{};
        browser_transfer_scratch = .empty;
        return guard;
    }

    fn restore(self: LifecycleTestGlobalsGuard) void {
        active_browser_executions.deinit(allocator);
        browser_op_queue.deinit(allocator, allocator);
        for (active_browser_transfers.items.items) |entry| allocator.free(entry.terminal);
        active_browser_transfers.items.deinit(allocator);
        browser_transfer_scratch.deinit(allocator);
        active_browser_executions = self.saved_executions;
        browser_op_queue = self.saved_queue;
        active_browser_transfers = self.saved_transfers;
        browser_transfer_scratch = self.saved_scratch;
    }
};

fn expectPendingErrorCode(pending: *control_server_mod.PendingRequest, code: control_plane.ErrorCode) !void {
    const response = pending.response orelse return error.ExpectedResponse;
    defer allocator.free(response);
    pending.response = null;
    var pm = try control_plane.parseMessage(std.testing.allocator, response);
    defer pm.deinit();
    try std.testing.expectEqual(@as(i64, @intFromEnum(code)), pm.message.response.err.?.code);
}

const FakeBrowserResultProvider = struct {
    data: []const u8,
    max_copy: usize = std.math.maxInt(usize),
    fail_at_offset: ?usize = null,
    write_bytes: bool = true,
    release_status: u32 = 1,
    release_failures_remaining: usize = 0,
    copy_calls: usize = 0,
    release_calls: usize = 0,
    budget_at_release: usize = 0,

    fn copy(context: ?*anyopaque, _: u64, offset: u64, dst: ?[*]u8, cap: usize) callconv(.c) i64 {
        const self: *FakeBrowserResultProvider = @ptrCast(@alignCast(context.?));
        self.copy_calls += 1;
        const start: usize = @intCast(offset);
        if (self.fail_at_offset) |fail_at| if (start >= fail_at) return 0;
        if (start >= self.data.len or dst == null) return -1;
        const n = @min(@min(cap, self.max_copy), self.data.len - start);
        if (self.write_bytes) @memcpy(dst.?[0..n], self.data[start..][0..n]);
        return @intCast(n);
    }

    fn release(context: ?*anyopaque, _: u64) callconv(.c) u32 {
        const self: *FakeBrowserResultProvider = @ptrCast(@alignCast(context.?));
        self.release_calls += 1;
        self.budget_at_release = active_browser_executions.budget.usedBytes();
        if (self.release_failures_remaining > 0) {
            self.release_failures_remaining -= 1;
            return 0;
        }
        return self.release_status;
    }
};

fn installTransferTestServer() void {
    std.debug.assert(!control_server_active);
    control_server_storage = lifecycleTestServer();
    control_server_active = true;
    control_pane_grant_store.clearAll();
}

fn uninstallTransferTestServer() void {
    control_server_active = false;
    control_server_storage.in_flight.deinit(std.testing.allocator);
    control_pane_grant_store.clearAll();
}

test "generic async browser op: target close wins once and late callback only releases lifecycle slot" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();

    const request = "{\"jsonrpc\":\"2.0\",\"id\":70,\"method\":\"browser.getCookies\",\"params\":{\"id\":11}}";
    var pending: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const id = try control_server_storage.deferRequest(&pending, std.math.maxInt(i128));
    pushBrowserOp(&control_server_storage, id, .{
        .surface_id = 11,
        .method = .get_cookies,
        .arg = try allocator.dupe(u8, ""),
        .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser_storage },
    });
    const execution = active_browser_executions.get(id) orelse return error.ExpectedActiveExecution;
    try std.testing.expectEqual(control_browser.BrowserMethod.get_cookies, execution.method);
    try std.testing.expectEqual(@as(usize, 0), execution.reserved_bytes);
    try std.testing.expect(active_browser_executions.markRunning(id));

    cancelBrowserExecutionsForClosedSurface(&control_server_storage, 11);
    try expectPendingErrorCode(&pending, .process_exited);
    try std.testing.expectEqual(ExecutionPhase.abandoned, active_browser_executions.get(id).?.phase);

    const secret = "[{\"name\":\"sid\",\"value\":\"secret\"}]";
    maru_macos_control_complete_browser_op(id, @intFromEnum(control_browser.BrowserCompletionStatus.success), secret.ptr, secret.len);
    try std.testing.expect(active_browser_executions.get(id) == null);
    try std.testing.expectEqual(control_server_mod.PendingRequest.State.done, pending.state);
    // 중복 backend callback도 client terminal을 되살리거나 새 response를 만들지 않는다.
    maru_macos_control_complete_browser_op(id, @intFromEnum(control_browser.BrowserCompletionStatus.success), secret.ptr, secret.len);
    try std.testing.expect(pending.response == null);

    var revoked_pending: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const revoked_id = try control_server_storage.deferRequest(&revoked_pending, std.math.maxInt(i128));
    pushBrowserOp(&control_server_storage, revoked_id, .{
        .surface_id = 11,
        .method = .get_cookies,
        .arg = try allocator.dupe(u8, ""),
        .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser_storage },
    });
    try std.testing.expect(!queuedExecutionReady(&control_server_storage, revoked_id, 0));
    rejectUnreadyBrowserExecution(&control_server_storage, revoked_id, 0);
    try expectPendingErrorCode(&revoked_pending, .unauthorized);
    try std.testing.expect(active_browser_executions.get(revoked_id) == null);

    try control_pane_grant_store.grant(.{ .pane = 5, .target = 12, .scope = .browser_storage });
    const crash_request = "{\"jsonrpc\":\"2.0\",\"id\":71,\"method\":\"browser.getCookies\",\"params\":{\"id\":12}}";
    var crash_pending: control_server_mod.PendingRequest = .{ .request_bytes = crash_request, .selector = null, .io = std.testing.io };
    const crash_id = try control_server_storage.deferRequest(&crash_pending, std.math.maxInt(i128));
    pushBrowserOp(&control_server_storage, crash_id, .{
        .surface_id = 12,
        .method = .get_cookies,
        .arg = try allocator.dupe(u8, ""),
        .pane_grant = .{ .pane = 5, .target = 12, .scope = .browser_storage },
    });
    try std.testing.expect(active_browser_executions.markRunning(crash_id));
    cancelBrowserOpsForCrashedSurface(&control_server_storage, 12);
    try expectPendingErrorCode(&crash_pending, .process_exited);
    try std.testing.expect(control_pane_grant_store.isGranted(5, 12, .browser_storage)); // crash는 logical surface/grant close 아님
    maru_macos_control_complete_browser_op(crash_id, @intFromEnum(control_browser.BrowserCompletionStatus.failed), null, 0);
    try std.testing.expect(active_browser_executions.get(crash_id) == null);
}

test "5f-5b pull ABI: partial copy reconstructs JSON and releases Data before reservation" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const request = "{\"jsonrpc\":\"2.0\",\"id\":71,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":64}}";
    var pending: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const id = try control_server_storage.deferRequest(&pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{
        .async_id = id,
        .surface_id = 11,
        .reserved_bytes = 64,
        .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } },
    });
    try std.testing.expect(active_browser_executions.markRunning(id));
    var provider = FakeBrowserResultProvider{ .data = "{\"answer\":42}", .max_copy = 3 };
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_complete_browser_result(id, 99, provider.data.len, &provider, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    try std.testing.expect(provider.copy_calls > 1);
    try std.testing.expectEqual(@as(usize, 1), provider.release_calls);
    try std.testing.expectEqual(provider.data.len, provider.budget_at_release);
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());
    const response = pending.response orelse return error.ExpectedResponse;
    defer allocator.free(response);
    pending.response = null;
    try std.testing.expect(std.mem.indexOf(u8, response, "\"answer\":42") != null);
}

test "5f-5b inline terminal: live outbound accounting과 typed purge key로 직접 enqueue" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const request = "{\"jsonrpc\":\"2.0\",\"id\":70,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":64}}";
    var process_budget = control_server_mod.ProcessOutboundBudget.init(std.testing.io, 32 * 1024 * 1024, 1024 * 1024);
    var outbound = control_server_mod.OutboundChannel.initWithProcessBudget(std.testing.io, 8, &process_budget);
    defer outbound.deinit(allocator);
    var pending: control_server_mod.PendingRequest = .{ .connection_id = 40, .request_bytes = request, .selector = null, .outbound = &outbound, .io = std.testing.io };
    const id = try control_server_storage.deferRequest(&pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = id, .surface_id = 11, .reserved_bytes = 64, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(id));
    var provider = FakeBrowserResultProvider{ .data = "{\"ok\":true}", .max_copy = 3 };
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_complete_browser_result(id, 98, provider.data.len, &provider, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    try std.testing.expectEqual(control_server_mod.PendingRequest.State.enqueued, pending.state);
    try std.testing.expectEqual(@as(usize, 1), provider.release_calls);
    try std.testing.expect(process_budget.snapshot().total_bytes > 0);
    const frame = outbound.popWait() orelse return error.ExpectedFrame;
    try std.testing.expect(frame.purge_key.eql(.{ .browser_request = id }));
    try std.testing.expect(frame.class == .general);
    outbound.writeComplete(frame.bytes);
    allocator.free(frame.bytes);
    try std.testing.expectEqual(@as(usize, 0), process_budget.snapshot().total_bytes);
}

test "5f-5b pull ABI: request bound rejects and larger result registers pump without copying" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser });

    const request_limit = "{\"jsonrpc\":\"2.0\",\"id\":72,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":8}}";
    var limited: control_server_mod.PendingRequest = .{ .request_bytes = request_limit, .selector = null, .io = std.testing.io };
    const limited_id = try control_server_storage.deferRequest(&limited, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = limited_id, .surface_id = 11, .reserved_bytes = 8, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(limited_id));
    var limited_provider = FakeBrowserResultProvider{ .data = "ignored" };
    _ = maru_macos_control_complete_browser_result(limited_id, 100, 9, &limited_provider, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release);
    try std.testing.expectEqual(@as(usize, 0), limited_provider.copy_calls);
    try std.testing.expectEqual(@as(usize, 1), limited_provider.release_calls);
    try std.testing.expectEqual(@as(usize, 8), limited_provider.budget_at_release);
    try expectPendingErrorCode(&limited, .result_too_large);

    const inline_total = control_browser.execute_script_inline_max_result_bytes + 1;
    const request_inline = "{\"jsonrpc\":\"2.0\",\"id\":73,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":2097152}}";
    var inline_pending: control_server_mod.PendingRequest = .{ .request_bytes = request_inline, .selector = null, .io = std.testing.io };
    const inline_id = try control_server_storage.deferRequest(&inline_pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = inline_id, .surface_id = 11, .reserved_bytes = 2 * 1024 * 1024, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(inline_id));
    var inline_provider = FakeBrowserResultProvider{ .data = "ignored" };
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_complete_browser_result(inline_id, 101, inline_total, &inline_provider, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    try std.testing.expectEqual(@as(usize, 0), inline_provider.copy_calls);
    try std.testing.expectEqual(@as(usize, 0), inline_provider.release_calls);
    try std.testing.expectEqual(@as(usize, 1), active_browser_transfers.items.items.len);
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_pump_browser_result());
    try std.testing.expectEqual(@as(usize, 1), inline_provider.release_calls);
    try std.testing.expectEqual(inline_total, inline_provider.budget_at_release);
    try std.testing.expectEqual(@as(usize, 0), active_browser_transfers.items.items.len);

    const max_entry = control_browser.execute_script_default_max_result_bytes;
    const request_host_oversize = "{\"jsonrpc\":\"2.0\",\"id\":76,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\"}}";
    var host_oversize: control_server_mod.PendingRequest = .{ .request_bytes = request_host_oversize, .selector = null, .io = std.testing.io };
    const host_oversize_id = try control_server_storage.deferRequest(&host_oversize, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = host_oversize_id, .surface_id = 11, .reserved_bytes = max_entry, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(host_oversize_id));
    maru_macos_control_complete_browser_result_too_large(host_oversize_id, max_entry + 1);
    try expectPendingErrorCode(&host_oversize, .result_too_large);
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());
}

test "5f-5b pump: tick당 한 chunk 뒤 terminal을 enqueue하고 Data와 예약을 정확히 한 번 반환" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const total = control_browser.execute_script_chunk_bytes + 1;
    const data = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(data);
    @memset(data, ' ');
    data[0] = '0';
    const request = "{\"jsonrpc\":\"2.0\",\"id\":79,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":600000}}";
    var process_budget = control_server_mod.ProcessOutboundBudget.init(std.testing.io, 32 * 1024 * 1024, 1024 * 1024);
    var outbound = control_server_mod.OutboundChannel.initWithProcessBudget(std.testing.io, 8, &process_budget);
    defer outbound.deinit(allocator);
    var pending: control_server_mod.PendingRequest = .{ .connection_id = 41, .request_bytes = request, .selector = null, .outbound = &outbound, .io = std.testing.io };
    const id = try control_server_storage.deferRequest(&pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = id, .surface_id = 11, .reserved_bytes = total, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(id));
    var provider = FakeBrowserResultProvider{ .data = data };
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_complete_browser_result(id, 111, total, &provider, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    // 같은 callback은 이미 인수한 source를 release하지 않고, 다른 source callback만 독립적으로 정리한다.
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_complete_browser_result(id, 111, total, &provider, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    try std.testing.expectEqual(@as(usize, 0), provider.release_calls);
    var duplicate_source = FakeBrowserResultProvider{ .data = "null" };
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_complete_browser_result(id, 999, duplicate_source.data.len, &duplicate_source, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    try std.testing.expectEqual(@as(usize, 1), duplicate_source.release_calls);
    var colliding_registry = FakeBrowserResultProvider{ .data = "null" };
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_complete_browser_result(id, 111, colliding_registry.data.len, &colliding_registry, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    try std.testing.expectEqual(@as(usize, 1), colliding_registry.release_calls);
    maru_macos_control_complete_browser_result_too_large(id, total + 1);
    maru_macos_control_complete_browser_script_error(id, null, 0);
    try std.testing.expectEqual(@as(usize, 1), active_browser_transfers.items.items.len);
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_pump_browser_result());
    try std.testing.expectEqual(@as(usize, 1), provider.copy_calls);
    try std.testing.expectEqual(@as(usize, 0), provider.release_calls);
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_pump_browser_result());
    try std.testing.expectEqual(@as(usize, 2), provider.copy_calls);
    try std.testing.expectEqual(@as(usize, 0), provider.release_calls);
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_pump_browser_result());
    try std.testing.expectEqual(@as(usize, 1), provider.release_calls);
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());
    try std.testing.expectEqual(control_server_mod.PendingRequest.State.enqueued, pending.state);

    var frames: usize = 0;
    while (frames < 3) : (frames += 1) {
        const frame = outbound.popWait() orelse return error.ExpectedFrame;
        if (frames < 2) try std.testing.expect(std.mem.indexOf(u8, frame.bytes, "browser.executeScriptChunk") != null) else try std.testing.expect(std.mem.indexOf(u8, frame.bytes, "\"transfer\":\"chunked\"") != null);
        outbound.writeComplete(frame.bytes);
        allocator.free(frame.bytes);
    }
}

test "5f-5b screenshot: 작은 PNG도 공통 pump와 byte-counted terminal을 사용" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const png_header = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 3, 0, 0, 0, 4 };
    const request = "{\"jsonrpc\":\"2.0\",\"id\":80,\"method\":\"browser.screenshot\",\"params\":{\"id\":11}}";
    var process_budget = control_server_mod.ProcessOutboundBudget.init(std.testing.io, 32 * 1024 * 1024, 1024 * 1024);
    var outbound = control_server_mod.OutboundChannel.initWithProcessBudget(std.testing.io, 8, &process_budget);
    defer outbound.deinit(allocator);
    var pending: control_server_mod.PendingRequest = .{ .connection_id = 42, .request_bytes = request, .selector = null, .outbound = &outbound, .io = std.testing.io };
    const id = try control_server_storage.deferRequest(&pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = id, .surface_id = 11, .reserved_bytes = control_browser.screenshot_max_result_bytes, .method = .screenshot, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(id));
    var provider = FakeBrowserResultProvider{ .data = &png_header, .max_copy = 8 };
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_complete_browser_screenshot_result(id, 112, png_header.len, &provider, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_complete_browser_screenshot_result(id, 112, png_header.len, &provider, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    try std.testing.expectEqual(@as(usize, 0), provider.release_calls);
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_pump_browser_result());
    try std.testing.expectEqual(@as(usize, 6), provider.copy_calls); // registration header 3회 + pump chunk 3회
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_pump_browser_result());
    try std.testing.expectEqual(@as(usize, 1), provider.release_calls);

    const chunk = outbound.popWait() orelse return error.ExpectedFrame;
    try std.testing.expect(std.mem.indexOf(u8, chunk.bytes, "browser.screenshotChunk") != null);
    outbound.writeComplete(chunk.bytes);
    allocator.free(chunk.bytes);
    const final_frame = outbound.popWait() orelse return error.ExpectedFrame;
    try std.testing.expect(std.mem.indexOf(u8, final_frame.bytes, "\"bytes\":24") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_frame.bytes, "\"width\":3") != null);
    outbound.writeComplete(final_frame.bytes);
    allocator.free(final_frame.bytes);
}

test "5f-5b cancel: release 확인 전 terminal을 노출하지 않고 재시도 뒤 한 번만 enqueue" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const total = control_browser.execute_script_inline_max_result_bytes + 1;
    const data = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(data);
    @memset(data, ' ');
    data[0] = '0';
    const request = "{\"jsonrpc\":\"2.0\",\"id\":82,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":600000}}";
    var process_budget = control_server_mod.ProcessOutboundBudget.init(std.testing.io, 32 * 1024 * 1024, 1024 * 1024);
    var outbound = control_server_mod.OutboundChannel.initWithProcessBudget(std.testing.io, 8, &process_budget);
    defer outbound.deinit(allocator);
    var pending: control_server_mod.PendingRequest = .{ .connection_id = 43, .request_bytes = request, .selector = null, .outbound = &outbound, .io = std.testing.io };
    const id = try control_server_storage.deferRequest(&pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = id, .surface_id = 11, .reserved_bytes = total, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(id));
    var provider = FakeBrowserResultProvider{ .data = data, .release_failures_remaining = 1 };
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_complete_browser_result(id, 113, total, &provider, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    control_pane_grant_store.revoke(5, 11, .browser);

    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_pump_browser_result());
    try std.testing.expectEqual(@as(usize, 0), outbound.q.len());
    try std.testing.expectEqual(control_server_mod.PendingRequest.State.pending, pending.state);
    try std.testing.expectEqual(@as(usize, 1), active_browser_transfers.items.items.len);

    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_pump_browser_result());
    try std.testing.expectEqual(@as(usize, 0), active_browser_transfers.items.items.len);
    try std.testing.expectEqual(control_server_mod.PendingRequest.State.enqueued, pending.state);
    const cancel_frame = outbound.popWait() orelse return error.ExpectedFrame;
    defer {
        outbound.writeComplete(cancel_frame.bytes);
        allocator.free(cancel_frame.bytes);
    }
    var parsed_cancel = try control_plane.parseMessage(std.testing.allocator, cancel_frame.bytes);
    defer parsed_cancel.deinit();
    try std.testing.expectEqual(@as(i64, @intFromEnum(control_plane.ErrorCode.unauthorized)), parsed_cancel.message.response.err.?.code);
}

test "5f-5b cancel: writer-owned chunk는 연결을 abort하고 terminal을 섞지 않음" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const total = control_browser.execute_script_inline_max_result_bytes + 1;
    const data = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(data);
    @memset(data, ' ');
    data[0] = '0';
    const request = "{\"jsonrpc\":\"2.0\",\"id\":83,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":600000}}";
    var process_budget = control_server_mod.ProcessOutboundBudget.init(std.testing.io, 32 * 1024 * 1024, 1024 * 1024);
    var outbound = control_server_mod.OutboundChannel.initWithProcessBudget(std.testing.io, 8, &process_budget);
    defer outbound.deinit(allocator);
    var pending: control_server_mod.PendingRequest = .{ .connection_id = 44, .request_bytes = request, .selector = null, .outbound = &outbound, .io = std.testing.io };
    const id = try control_server_storage.deferRequest(&pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = id, .surface_id = 11, .reserved_bytes = total, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(id));
    var provider = FakeBrowserResultProvider{ .data = data };
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_complete_browser_result(id, 114, total, &provider, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_pump_browser_result());

    // writer가 이미 청크를 pop한 시점의 revoke는 같은 연결에 terminal을 추가하면 안 된다.
    const writer_frame = outbound.popWait() orelse return error.ExpectedFrame;
    control_pane_grant_store.revoke(5, 11, .browser);
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_pump_browser_result());
    try std.testing.expect(outbound.isClosed());
    try std.testing.expectEqual(@as(usize, 0), outbound.q.len());
    try std.testing.expectEqual(@as(usize, 1), provider.release_calls);
    try std.testing.expectEqual(@as(usize, 0), active_browser_transfers.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());
    try std.testing.expectEqual(control_server_mod.PendingRequest.State.done, pending.state);
    try std.testing.expect(pending.response == null);

    outbound.writeComplete(writer_frame.bytes);
    allocator.free(writer_frame.bytes);
    try std.testing.expectEqual(@as(usize, 0), process_budget.snapshot().total_bytes);
}

test "5f-5a script-error ABI: typed terminal, revoke override, abandoned late callback release reservation" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();
    const provenance: control_browser.GrantProvenance = .{ .pane = 5, .target = 11, .scope = .browser };
    try control_pane_grant_store.grant(.{ .pane = provenance.pane, .target = provenance.target, .scope = provenance.scope });
    const request = "{\"jsonrpc\":\"2.0\",\"id\":81,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":64}}";
    const payload = "{\"kind\":\"serialization\",\"name\":\"TypeError\",\"message\":\"cycle\",\"stack\":\"\",\"diagnostics_truncated\":false}";

    var typed: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const typed_id = try control_server_storage.deferRequest(&typed, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = typed_id, .surface_id = 11, .reserved_bytes = 64, .provenance = .{ .pane_grant = provenance } });
    try std.testing.expect(active_browser_executions.markRunning(typed_id));
    maru_macos_control_complete_browser_script_error(typed_id, payload.ptr, payload.len);
    try expectPendingErrorCode(&typed, .script_error);
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());

    var revoked: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const revoked_id = try control_server_storage.deferRequest(&revoked, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = revoked_id, .surface_id = 11, .reserved_bytes = 64, .provenance = .{ .pane_grant = provenance } });
    try std.testing.expect(active_browser_executions.markRunning(revoked_id));
    control_pane_grant_store.revoke(provenance.pane, provenance.target, provenance.scope);
    maru_macos_control_complete_browser_script_error(revoked_id, payload.ptr, payload.len);
    try expectPendingErrorCode(&revoked, .unauthorized);

    var abandoned: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const abandoned_id = try control_server_storage.deferRequest(&abandoned, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = abandoned_id, .surface_id = 11, .reserved_bytes = 64, .provenance = .{ .pane_grant = provenance } });
    try std.testing.expect(active_browser_executions.markRunning(abandoned_id));
    active_browser_executions.get(abandoned_id).?.phase = .abandoned;
    maru_macos_control_complete_browser_script_error(abandoned_id, payload.ptr, payload.len);
    try std.testing.expect(abandoned.response == null);
    try std.testing.expect(active_browser_executions.get(abandoned_id) == null);
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());
}

test "5f-5b pull ABI: premature EOF and duplicate terminal release exactly once" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const request = "{\"jsonrpc\":\"2.0\",\"id\":74,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":64}}";
    var pending: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const id = try control_server_storage.deferRequest(&pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = id, .surface_id = 11, .reserved_bytes = 64, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(id));
    var provider = FakeBrowserResultProvider{ .data = "1234", .max_copy = 2, .fail_at_offset = 2 };
    _ = maru_macos_control_complete_browser_result(id, 102, provider.data.len, &provider, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release);
    try std.testing.expectEqual(@as(usize, 2), provider.copy_calls);
    try std.testing.expectEqual(@as(usize, 1), provider.release_calls);
    try std.testing.expectEqual(provider.data.len, provider.budget_at_release);
    try expectPendingErrorCode(&pending, .internal_error);
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());

    var duplicate = FakeBrowserResultProvider{ .data = "null" };
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_complete_browser_result(id, 103, duplicate.data.len, &duplicate, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    try std.testing.expectEqual(@as(usize, 0), duplicate.copy_calls);
    try std.testing.expectEqual(@as(usize, 1), duplicate.release_calls);
    var unknown_release_failure = FakeBrowserResultProvider{ .data = "null", .release_status = 0 };
    try std.testing.expectEqual(@as(u32, 0), maru_macos_control_complete_browser_result(id, 108, unknown_release_failure.data.len, &unknown_release_failure, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    try std.testing.expectEqual(@as(usize, 1), unknown_release_failure.release_calls);
}

test "5f-5b pull ABI: lying copy cannot expose heap and release failure pins reservation" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const request = "{\"jsonrpc\":\"2.0\",\"id\":75,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":64}}";

    var lying_pending: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const lying_id = try control_server_storage.deferRequest(&lying_pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = lying_id, .surface_id = 11, .reserved_bytes = 64, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(lying_id));
    var liar = FakeBrowserResultProvider{ .data = "null", .write_bytes = false };
    _ = maru_macos_control_complete_browser_result(lying_id, 104, liar.data.len, &liar, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release);
    try expectPendingErrorCode(&lying_pending, .internal_error); // zero-initialized bytes는 valid JSON/heap content가 아니다.

    var failed_release_pending: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const failed_release_id = try control_server_storage.deferRequest(&failed_release_pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = failed_release_id, .surface_id = 11, .reserved_bytes = 64, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(failed_release_id));
    var failed_release = FakeBrowserResultProvider{ .data = "null", .release_status = 0 };
    try std.testing.expectEqual(@as(u32, 0), maru_macos_control_complete_browser_result(failed_release_id, 105, failed_release.data.len, &failed_release, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release));
    try std.testing.expectEqual(ExecutionPhase.release_pending, active_browser_executions.get(failed_release_id).?.phase);
    try std.testing.expectEqual(failed_release.data.len, active_browser_executions.budget.usedBytes());
    // Swift fallback은 registry를 직접 release한 뒤 old completion을 불러 pinned reservation을 반환한다.
    maru_macos_control_complete_browser_op(failed_release_id, @intFromEnum(control_browser.BrowserCompletionStatus.failed), null, 0);
    try std.testing.expect(active_browser_executions.get(failed_release_id) == null);
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());
    const success_response = failed_release_pending.response orelse return error.ExpectedResponse;
    allocator.free(success_response);
    failed_release_pending.response = null;
}

test "5f-5b pull ABI: revoke and inactive late callback release without copying" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const request = "{\"jsonrpc\":\"2.0\",\"id\":77,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":64}}";
    var revoked_pending: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const revoked_id = try control_server_storage.deferRequest(&revoked_pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = revoked_id, .surface_id = 11, .reserved_bytes = 64, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(revoked_id));
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_browser_execution_may_start(revoked_id));
    control_pane_grant_store.clearAll();
    try std.testing.expectEqual(@as(u32, 0), maru_macos_control_browser_execution_may_start(revoked_id));
    var revoked = FakeBrowserResultProvider{ .data = "null" };
    _ = maru_macos_control_complete_browser_result(revoked_id, 106, revoked.data.len, &revoked, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release);
    try std.testing.expectEqual(@as(usize, 0), revoked.copy_calls);
    try std.testing.expectEqual(@as(usize, 64), revoked.budget_at_release);
    try expectPendingErrorCode(&revoked_pending, .unauthorized);

    const inactive_id: u64 = 9_999_991;
    try active_browser_executions.admit(allocator, .{ .async_id = inactive_id, .surface_id = 11, .reserved_bytes = 32, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(inactive_id));
    control_server_active = false;
    var inactive = FakeBrowserResultProvider{ .data = "null" };
    _ = maru_macos_control_complete_browser_result(inactive_id, 107, inactive.data.len, &inactive, FakeBrowserResultProvider.copy, FakeBrowserResultProvider.release);
    control_server_active = true;
    try std.testing.expectEqual(@as(usize, 0), inactive.copy_calls);
    try std.testing.expectEqual(@as(usize, 1), inactive.release_calls);
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());
}

test "5f-5c execution may-start ABI: running pending authorized만 허용하고 timeout·phase·server stop 거부" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    installTransferTestServer();
    defer uninstallTransferTestServer();
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    const request = "{\"jsonrpc\":\"2.0\",\"id\":78,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":64}}";

    var pending: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const id = try control_server_storage.deferRequest(&pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = id, .surface_id = 11, .reserved_bytes = 64, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expectEqual(@as(u32, 0), maru_macos_control_browser_execution_may_start(id)); // queued
    try std.testing.expect(active_browser_executions.markRunning(id));
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_browser_execution_may_start(id));
    control_server_active = false;
    try std.testing.expectEqual(@as(u32, 0), maru_macos_control_browser_execution_may_start(id));
    control_server_active = true;
    active_browser_executions.abandon(id);
    try std.testing.expectEqual(@as(u32, 0), maru_macos_control_browser_execution_may_start(id));
    try std.testing.expect(active_browser_executions.finish(id));
    _ = control_server_storage.completeInFlight(id, null);

    var missing_pending: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const missing_id = try control_server_storage.deferRequest(&missing_pending, std.math.maxInt(i128));
    try active_browser_executions.admit(allocator, .{ .async_id = missing_id, .surface_id = 11, .reserved_bytes = 64, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(missing_id));
    _ = control_server_storage.completeInFlight(missing_id, null);
    try std.testing.expectEqual(@as(u32, 0), maru_macos_control_browser_execution_may_start(missing_id));
    try std.testing.expect(active_browser_executions.finish(missing_id));

    var expired: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const expired_id = try control_server_storage.deferRequest(&expired, 0);
    try active_browser_executions.admit(allocator, .{ .async_id = expired_id, .surface_id = 11, .reserved_bytes = 64, .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } } });
    try std.testing.expect(active_browser_executions.markRunning(expired_id));
    try std.testing.expectEqual(@as(u32, 0), maru_macos_control_browser_execution_may_start(expired_id));
    try expectPendingErrorCode(&expired, .timeout);
    try std.testing.expectEqual(ExecutionPhase.abandoned, active_browser_executions.get(expired_id).?.phase);
    try std.testing.expect(active_browser_executions.finish(expired_id));
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());
}

test "5f-5b glue: queue Full rollback과 queued/running typed timeout" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    var server = lifecycleTestServer();
    defer server.in_flight.deinit(std.testing.allocator);
    const request = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":64}}";
    const nonce = [_]u8{0x3C} ** control_capability.nonce_len;

    var queue_full: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const full_id = try server.deferRequest(&queue_full, 100);
    browser_op_queue.max = 0;
    pushBrowserOp(&server, full_id, .{
        .surface_id = 11,
        .method = .execute_script,
        .arg = try allocator.dupe(u8, "1"),
        .capability_nonce = nonce,
        .capability_generation = 0,
        .max_result_bytes = 64,
    });
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());
    try std.testing.expectEqual(@as(usize, 0), server.in_flight.items.len);
    try std.testing.expectEqual(control_server_mod.PendingRequest.State.done, queue_full.state);
    try std.testing.expect(queue_full.response == null);
    browser_op_queue.max = 8;

    var queued: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const queued_id = try server.deferRequest(&queued, 100);
    try active_browser_executions.admit(allocator, .{
        .async_id = queued_id,
        .surface_id = 11,
        .reserved_bytes = 64,
        .provenance = .{ .capability = .{ .nonce = nonce, .generation = 0 } },
    });
    try browser_op_queue.push(allocator, .{
        .async_id = queued_id,
        .surface_id = 11,
        .op_kind = @intFromEnum(control_browser.BrowserMethod.execute_script),
        .arg = try allocator.dupe(u8, "1"),
    });
    expireActiveBrowserExecutions(&server, 101);
    try expectPendingErrorCode(&queued, .timeout);
    try std.testing.expect(active_browser_executions.get(queued_id) == null);
    try std.testing.expectEqual(@as(usize, 0), browser_op_queue.items.items.len); // 같은 tick에 arg/capacity까지 회수
    // max=1 큐에서도 timeout 직후 새 요청이 stale entry 때문에 Full이 되지 않는다.
    browser_op_queue.max = 1;
    try browser_op_queue.push(allocator, .{
        .async_id = queued_id + 1,
        .surface_id = 12,
        .op_kind = @intFromEnum(control_browser.BrowserMethod.get_url),
        .arg = try allocator.dupe(u8, ""),
    });
    const replacement = browser_op_queue.take().?;
    allocator.free(replacement.arg);
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());

    var running: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const running_id = try server.deferRequest(&running, 200);
    try active_browser_executions.admit(allocator, .{
        .async_id = running_id,
        .surface_id = 11,
        .reserved_bytes = 64,
        .provenance = .{ .capability = .{ .nonce = nonce, .generation = 0 } },
    });
    try std.testing.expect(active_browser_executions.markRunning(running_id));
    expireActiveBrowserExecutions(&server, 201);
    try expectPendingErrorCode(&running, .timeout);
    try std.testing.expectEqual(ExecutionPhase.abandoned, active_browser_executions.get(running_id).?.phase);
    try std.testing.expectEqual(@as(usize, 64), active_browser_executions.budget.usedBytes());
    try std.testing.expect(active_browser_executions.finish(running_id));
    try std.testing.expect(!active_browser_executions.finish(running_id));
}

test "5f-5b glue: running revoke는 client terminal 뒤 late backend terminal까지 예약 유지" {
    const globals = LifecycleTestGlobalsGuard.install();
    defer globals.restore();
    var server = lifecycleTestServer();
    defer server.in_flight.deinit(std.testing.allocator);
    const request = "{\"jsonrpc\":\"2.0\",\"id\":43,\"method\":\"browser.executeScript\",\"params\":{\"id\":11,\"script\":\"1\",\"max_result_bytes\":32}}";
    var pending: control_server_mod.PendingRequest = .{ .request_bytes = request, .selector = null, .io = std.testing.io };
    const id = try server.deferRequest(&pending, 1_000);
    try active_browser_executions.admit(allocator, .{
        .async_id = id,
        .surface_id = 11,
        .reserved_bytes = 32,
        .provenance = .{ .pane_grant = .{ .pane = 5, .target = 11, .scope = .browser } },
    });
    try std.testing.expect(active_browser_executions.markRunning(id));
    cancelActiveBrowserExecution(&server, id, .unauthorized);
    try expectPendingErrorCode(&pending, .unauthorized);
    try std.testing.expectEqual(ExecutionPhase.abandoned, active_browser_executions.get(id).?.phase);
    try std.testing.expectEqual(@as(usize, 32), active_browser_executions.budget.usedBytes());
    try std.testing.expect(active_browser_executions.finish(id));
    try std.testing.expectEqual(@as(usize, 0), active_browser_executions.budget.usedBytes());
}

// WP-F1 적대적 R10: **ABI 래퍼는 Swift만 부르므로 여기서 안 보면 영영 안 본다.** 여기서 지키는 것은
// **null 안전**이다 — Swift teardown 중(창이 닫히는 프레임) 세션이 이미 없는 채로 불릴 수 있고, 그때
// 크래시하면 앱이 죽는다. 세 export 모두 null에 무해해야 한다.
//
// 한계: "용량 부족·out-ptr null이면 pending을 소비하지 않는다"는 계약은 여기서 못 태운다 — pending을
// 세우려면 웹 탭이 활성이어야 하고, 그 설정은 `activePane`/`createWebTerm` 같은 **비-pub 내부 헬퍼**를
// 만져야 한다(경계를 뚫느니 안 태운다). 그 계약은 app_session.zig의 WP-F1 테스트들이 `peekWebFindQueryLen`
// (래퍼가 소비 전에 쓰는 바로 그 함수)로 덮는다.
test "WP-F1 ABI: web find export 3종이 null session에 무해하다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var buf: [64]u8 = undefined;
    var qlen: usize = 0;
    var sid: u64 = 0;
    var backwards: u32 = 0;

    try std.testing.expectEqual(@as(u64, 0), maru_macos_app_session_take_web_find_query(null, &buf, buf.len, &qlen, &sid, &backwards));
    maru_macos_app_session_provide_web_find_result(null, 1, 1);
    maru_macos_app_session_web_find_undeliverable(null, 1);
}

test "grant scope wire round-trip: browser=0·browser_storage=1, 그 외 from-wire는 null" {
    try std.testing.expectEqual(@as(u8, 0), grantScopeToWire(.browser));
    try std.testing.expectEqual(@as(u8, 1), grantScopeToWire(.browser_storage));
    try std.testing.expectEqual(control_capability.ScopeClass.browser, grantScopeFromWire(0).?);
    try std.testing.expectEqual(control_capability.ScopeClass.browser_storage, grantScopeFromWire(1).?);
    try std.testing.expect(grantScopeFromWire(2) == null); // 알 수 없는 wire → null(revoke가 0 반환)
}

test "per-grant revoke export: count/grant_at 스냅샷 + 값기반 revoke_browser_grant(멱등)" {
    // 앱-전역 store라 테스트 격리 위해 시작·끝에 clear.
    control_pane_grant_store.clearAll();
    defer control_pane_grant_store.clearAll();
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser });
    try control_pane_grant_store.grant(.{ .pane = 5, .target = 11, .scope = .browser_storage });
    try std.testing.expectEqual(@as(u32, 2), maru_macos_control_browser_grant_count());

    // grant_at: index 0 읽기(값 반환·scope wire). 범위밖=0.
    var pane: u64 = 0;
    var target: u64 = 0;
    var scope: u8 = 99;
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_browser_grant_at(0, &pane, &target, &scope));
    try std.testing.expectEqual(@as(u64, 5), pane);
    try std.testing.expectEqual(@as(u64, 11), target);
    try std.testing.expect(scope == 0 or scope == 1); // 순서 무보장 — browser|browser_storage 둘 중 하나
    try std.testing.expectEqual(@as(u32, 0), maru_macos_control_browser_grant_at(2, &pane, &target, &scope)); // 범위밖

    // revoke_browser_grant: browser 하나만 취소(storage 보존). 값 기반이라 인덱스 무관.
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_revoke_browser_grant(5, 11, 0));
    try std.testing.expectEqual(@as(u32, 1), maru_macos_control_browser_grant_count());
    try std.testing.expect(!control_pane_grant_store.isGranted(5, 11, .browser));
    try std.testing.expect(control_pane_grant_store.isGranted(5, 11, .browser_storage));
    // 이미 없는 grant revoke = 0(멱등). 잘못된 scope wire도 0.
    try std.testing.expectEqual(@as(u32, 0), maru_macos_control_revoke_browser_grant(5, 11, 0));
    try std.testing.expectEqual(@as(u32, 0), maru_macos_control_revoke_browser_grant(5, 11, 2));
}

// 파일 선택 안내가 **현재 UI 언어를 따르는지** 본다.
//
// 이 네 문장은 예전에 Swift 에 한국어로 박혀 있었다 — `ui.language` 를 바꿔도 그대로였고, 번역 대상이
// 두 언어(Zig·Swift)에 흩어져 한쪽만 고쳐질 수 있었다. 그 구멍을 ABI 로 옮겼으므로, 옮긴 것이 실제로
// 동작하는지(그리고 종류→키 대응이 어긋나지 않았는지) 여기서 확인한다.
test "파일 선택 안내는 UI 언어를 따르고 종류마다 다른 문장을 낸다" {
    const before = maru.i18n.lang();
    defer maru.i18n.setLang(before);

    const kinds = [_]u32{
        MARU_FILE_PICK_MESSAGE_BACKGROUND_PNG,
        MARU_FILE_PICK_MESSAGE_DOCK_FILE,
        MARU_FILE_PICK_MESSAGE_EXPLORER_FOLDER,
        MARU_FILE_PICK_MESSAGE_WORKSPACE_FOLDER,
    };
    const keys = [_]maru.i18n.Key{ .pick_background_png, .pick_dock_file, .pick_explorer_folder, .pick_workspace_folder };

    for ([_]maru.i18n.Lang{ .ko, .en }) |lang| {
        maru.i18n.setLang(lang);
        for (kinds, keys) |kind, key| {
            const got = std.mem.span(maru_macos_file_pick_message(kind));
            try std.testing.expectEqualStrings(maru.i18n.tIn(lang, key), got);
        }
    }

    // 네 종류가 **서로 다른 문장**이어야 한다 — 같은 키를 두 종류에 잘못 이으면 위 단언은 통과하지만
    // 사용자는 엉뚱한 안내를 본다.
    maru.i18n.setLang(.ko);
    for (kinds, 0..) |a, i| {
        for (kinds[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(
                u8,
                std.mem.span(maru_macos_file_pick_message(a)),
                std.mem.span(maru_macos_file_pick_message(b)),
            ));
        }
    }

    // 알 수 없는 종류는 빈 문자열 — 크래시하지 않는다(패널이 안내 없이 뜬다).
    try std.testing.expectEqualStrings("", std.mem.span(maru_macos_file_pick_message(9999)));
}

test "앱 종료 마커는 시그널·보낸 쪽·정상 종료를 구분하고, 버퍼가 모자라면 자른다" {
    // 이 테스트가 증명하는 것: 마커가 **무엇을 쓰는지**. 실제 기록은 `write(2, …)` 라 테스트가
    // 건드릴 수 없으므로, 그 앞의 순수 포맷만이라도 고정하지 않으면 "핸들러는 도는데 로그를 봐도
    // 무슨 뜻인지 모른다"가 된다 — 이 기능을 만든 이유가 정확히 그 상황이었다.
    var buf: [128]u8 = undefined;

    // 시그널로 죽은 경우: 번호뿐 아니라 **누가 보냈는지**가 남는다. `signal=15` 만으로는
    // "SIGTERM 을 받았다"까지고, 조용한 종료를 추적할 때 정작 알아야 하는 것은 `from` 이다.
    try std.testing.expectEqualStrings(
        "=== maru app exit pid=4242 signal=15 code=0 from=4282 ===\n",
        formatSignalExitMarker(&buf, 4242, 15, 0, 4282),
    );

    // `si_code` 는 음수 값을 쓴다. 부호를 버리면 커널 상수와 대조가 안 된다.
    try std.testing.expectEqualStrings(
        "=== maru app exit pid=9 signal=11 code=-1 from=0 ===\n",
        formatSignalExitMarker(&buf, 9, 11, -1, 0),
    );

    // `exit()` 로 끝난 경우: 붙일 숫자가 없다.
    try std.testing.expectEqualStrings(
        "=== maru app exit pid=7 via=exit ===\n",
        formatCleanExitMarker(&buf, 7),
    );

    // `si_code` 는 i32 범위지만 서명이 i64 다. 뒤집기(`-value`)로 크기를 구하면 최솟값에서
    // **핸들러 안에서 오버플로 패닉**이 난다 — 도달 불가에 기대지 않고 여기서 고정한다.
    try std.testing.expectEqualStrings(
        "=== maru app exit pid=1 signal=6 code=-9223372036854775808 from=0 ===\n",
        formatSignalExitMarker(&buf, 1, 6, std.math.minInt(i64), 0),
    );

    // 버퍼가 모자라도 넘치지 않는다. 시그널 핸들러 안에서 도는 코드라 이 성질이 곧 안전성이다.
    var tiny: [8]u8 = undefined;
    try std.testing.expect(formatSignalExitMarker(&tiny, 999999, 11, -7, 12345).len <= tiny.len);
    try std.testing.expect(formatCleanExitMarker(&tiny, 999999).len <= tiny.len);
}

test "app 진단 로그 fd는 base 아래 app.log를 append로 열고 상한을 넘으면 비운다" {
    // 이 테스트가 증명하는 것: GUI 실행의 진단을 담을 파일이 **실제로 열린다**. 여기서 부작용을
    // `openAppLogFd` 하나로 좁혀 둔 이유가 이것이다 — `dup2`로 프로세스 stderr를 바꾸는 쪽은
    // 테스트가 건드릴 수 없어, 열기·append·상한 계약만이라도 실물로 재지 않으면 "빌드는 되는데
    // 파일이 안 생긴다"를 아무도 못 잡는다(실제로 그렇게 한 번 놓쳤다).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &resolved);
    const base = try std.fmt.bufPrintZ(&base_buf, "{s}/cache-base", .{resolved[0..len]});

    // base가 아직 없어도 만들어 연다 — 첫 실행에서 진단이 사라지면 안 된다.
    const fd = openAppLogFd(base);
    try std.testing.expect(fd >= 0);
    const first_line = "hello\n";
    try std.testing.expectEqual(@as(isize, first_line.len), std.c.write(fd, first_line.ptr, first_line.len));
    _ = std.c.close(fd);

    // 두 번째 열기는 append다 — 이전 실행의 진단을 덮지 않는다.
    const again = openAppLogFd(base);
    try std.testing.expect(again >= 0);
    try std.testing.expectEqual(@as(i64, first_line.len), std.c.lseek(again, 0, std.c.SEEK.END));
    _ = std.c.close(again);

    // 상한을 넘긴 파일은 비우고 시작한다.
    const grow = openAppLogFd(base);
    try std.testing.expect(grow >= 0);
    try std.testing.expectEqual(@as(c_int, 0), std.c.ftruncate(grow, app_log_max_bytes + 1));
    _ = std.c.close(grow);
    const after_cap = openAppLogFd(base);
    try std.testing.expect(after_cap >= 0);
    try std.testing.expectEqual(@as(i64, 0), std.c.lseek(after_cap, 0, std.c.SEEK.END));
    _ = std.c.close(after_cap);
}

test "TIG5 활성 Term 질의 ABI 가 Term 종류를 그대로 전한다 (선-가로채기 게이트 배선)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    // **파생만 재면 배선이 빠져도 초록이다.** `TIG2` 는 `term_ops.activeTermIsTerminal` 을 **직접**
    // 부르는데 Swift 가 부르는 것은 **이 export** 다 — 래퍼가 늘 1 을 내면 게이트가 죽고 편집기는
    // 그 키들을 계속 못 받는다(1회차 `T9`·`T10` 이 그 자리다).

    // ⑴ **세션이 없으면 fail-open(1)** — 시작 중에는 선-가로채기가 종전대로 돌아야 한다. 0 으로
    //    뒤집히면 창이 뜨는 동안 터미널에서 `⌘↑`·`⇧PageUp` 이 조용히 사라진다.
    try std.testing.expectEqual(@as(c_int, 1), maru_macos_app_session_active_term_is_terminal(null));

    const config: AppSessionConfig = .{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(AppCommandKind.controlled_smoke),
    };
    var session: ?*AppSession = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Status.ok)), maru_macos_app_session_create(&config, &session));
    defer maru_macos_app_session_destroy(session);
    const s = session orelse return error.NoSession;
    s.surface_initialized = true;

    // ⑵ **터미널이면 1** — 새 세션의 활성 Term 은 터미널이다.
    try std.testing.expectEqual(@as(c_int, 1), maru_macos_app_session_active_term_is_terminal(session));

    // ⑶ **편집기면 0**(요점) — 그래야 Swift 가 비켜서고 키가 편집기에 닿는다. 한쪽만 재면 상수를
    //    낸 변이가 산다.
    const tab = s.tabs.items[s.app_window.active_tab];
    const pane = tab.panes.items[tab.active_pane];
    const term = pane.terms.items[pane.active_term];
    const saved = term.kind;
    term.kind = .editor;
    try std.testing.expectEqual(@as(c_int, 0), maru_macos_app_session_active_term_is_terminal(session));
    term.kind = saved;
}
