const std = @import("std");
const app_dev_session = @import("app_dev_session.zig");

const c = @cImport({
    @cInclude("app_host_abi.h");
});

pub const abi_version: u32 = 2;
const allocator = std.heap.smp_allocator;

pub const Status = enum(c_int) {
    ok = 0,
    null_out = 1,
    unsupported_abi = 2,
    invalid_config = 3,
    create_failed = 4,
    tick_failed = 5,
    close_failed = 6,
};

pub const EventKind = enum(u32) {
    none = 0,
    frame_tick = 1,
    key_down = 2,
    resize = 3,
    close_requested = 4,
    app_should_terminate = 5,
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
    key_code: u32,
    modifier_shift: u32,
    modifier_control: u32,
    modifier_option: u32,
    modifier_command: u32,
    is_repeat: u32,
    reserved: u32,
};

pub const ResizeEvent = extern struct {
    width_px: u32,
    height_px: u32,
    scale_milli: u32,
    cols: u32,
    rows: u32,
    reserved: u32,
};

pub const DevCommandKind = app_dev_session.CommandKind;
pub const DevSession = app_dev_session.DevSession;
pub const DevSessionConfig = app_dev_session.SessionConfig;
pub const DevFrameSummary = app_dev_session.FrameSummary;

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

pub export fn maru_macos_app_dev_session_create(
    config: ?*const DevSessionConfig,
    out_session: ?*?*DevSession,
) c_int {
    const raw_config = (config orelse return @intFromEnum(Status.null_out)).*;
    const out = out_session orelse return @intFromEnum(Status.null_out);
    out.* = null;

    _ = app_dev_session.normalizeConfig(raw_config) catch |err| switch (err) {
        error.UnsupportedAbi => return @intFromEnum(Status.unsupported_abi),
        error.InvalidConfig => return @intFromEnum(Status.invalid_config),
    };

    const session = allocator.create(DevSession) catch return @intFromEnum(Status.create_failed);
    errdefer allocator.destroy(session);

    session.init(std.Io.Threaded.global_single_threaded.io(), allocator, raw_config) catch {
        return @intFromEnum(Status.create_failed);
    };

    out.* = session;
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_dev_session_tick(
    session: ?*DevSession,
    out_summary: ?*DevFrameSummary,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    out.* = dev_session.tick() catch return @intFromEnum(Status.tick_failed);
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_dev_session_close(
    session: ?*DevSession,
    out_summary: ?*DevFrameSummary,
) c_int {
    const dev_session = session orelse return @intFromEnum(Status.null_out);
    const out = out_summary orelse return @intFromEnum(Status.null_out);
    out.* = dev_session.close();
    return @intFromEnum(Status.ok);
}

pub export fn maru_macos_app_dev_session_destroy(session: ?*DevSession) void {
    const dev_session = session orelse return;
    dev_session.deinit();
    allocator.destroy(dev_session);
}

test "macOS app host ABI header and Zig declarations stay aligned" {
    // Swift는 C header를 보고, Zig는 이 파일의 extern struct를 쓴다. 둘의 숫자와
    // layout이 갈라지면 다음 제품 앱 PR에서 런타임 버그가 되므로 컴파일 단계에서 막는다.
    try std.testing.expectEqual(@as(u32, c.MARU_MACOS_APP_HOST_ABI_VERSION), abi_version);
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusOk), @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusNullOut), @intFromEnum(Status.null_out));
    try std.testing.expectEqual(@as(c_int, c.MaruAppHostStatusInvalidConfig), @intFromEnum(Status.invalid_config));
    try std.testing.expectEqual(@as(u32, c.MaruAppHostEventKeyDown), @intFromEnum(EventKind.key_down));
    try std.testing.expectEqual(@as(u32, @intCast(c.MaruAppHostDevCommandControlledSmoke)), @intFromEnum(DevCommandKind.controlled_smoke));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostCapabilities), @sizeOf(Capabilities));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostCapabilities), @alignOf(Capabilities));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostKeyEvent), @sizeOf(KeyEvent));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostResizeEvent), @sizeOf(ResizeEvent));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostDevSessionConfig), @sizeOf(DevSessionConfig));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostDevSessionConfig), @alignOf(DevSessionConfig));
    try std.testing.expectEqual(@sizeOf(c.MaruAppHostDevFrameSummary), @sizeOf(DevFrameSummary));
    try std.testing.expectEqual(@alignOf(c.MaruAppHostDevFrameSummary), @alignOf(DevFrameSummary));
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
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(KeyEvent));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ResizeEvent));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(KeyEvent));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(ResizeEvent));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(DevSessionConfig));
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(DevFrameSummary));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(DevFrameSummary));
}

test "macOS app dev exported session API reports null outputs as ABI errors" {
    const config: DevSessionConfig = .{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(DevCommandKind.controlled_smoke),
    };
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_dev_session_create(&config, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_dev_session_tick(null, null),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(Status.null_out)),
        maru_macos_app_dev_session_close(null, null),
    );
}

test {
    std.testing.refAllDecls(app_dev_session);
}
