//! sidecar 의 `cef_app_t`(W1b·W1c). 브라우저 프로세스 명령줄에 제품 스위치를 넣고,
//!
//! 같은 프로필로 다시 실행될 때 Chrome 창을 열지 않게 막는다(`onAlreadyRunningAppRelaunch`).
//!
//! `use-mock-keychain`(D7, docs/plans/web-osr-backend.md) — 진짜 Keychain 을 쓰면 항목 이름이 Chromium 브라우저와 같은
//! 「Chromium Safe Storage」이고, 소스 빌드는 업그레이드마다 서명이 바뀌어 허용 창이 반복될 수 있으며, 거부·실패하면
//! 쿠키가 조용히 저장되지 않는다(실측). 이 스위치면 Keychain 을 건드리지 않고 재시작 뒤에도 로그인이 남았다(실측).

const std = @import("std");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");

var app: c.cef_app_t = undefined;
var browser_process: c.cef_browser_process_handler_t = undefined;
var api: *const library.Api = undefined;

pub const product_switches = [_][]const u8{"use-mock-keychain"};

/// 프로세스 수명 동안 사는 앱 객체를 돌려준다. `cef_initialize` 전에 한 번 부른다.
pub fn get(loaded: *const library.Api) *c.cef_app_t {
    api = loaded;
    app = object.zeroed(c.cef_app_t);
    object.staticRefCounted(&app.base);
    app.on_before_command_line_processing = &onBeforeCommandLineProcessing;
    browser_process = object.zeroed(c.cef_browser_process_handler_t);
    object.staticRefCounted(&browser_process.base);
    browser_process.on_already_running_app_relaunch = &onAlreadyRunningAppRelaunch;
    app.get_browser_process_handler = &getBrowserProcessHandler;
    return &app;
}

fn getBrowserProcessHandler(_: [*c]c.cef_app_t) callconv(.c) [*c]c.cef_browser_process_handler_t {
    return &browser_process;
}

/// 같은 프로필로 다른 프로세스가 CEF 를 띄우면 Chromium 은 그 실행을 먼저 떠 있던 이 프로세스로 넘기고, 기본 동작은
/// **새 Chrome 창**이다(헤더 문서·실측 — 「New Tab - Chromium」 창이 열리고 그 창 때문에 종료가 멈췄다). maru 가
/// 통제하지 못하는 창이므로 「처리했다」고 답하고 아무것도 하지 않는다. 넘어온 쪽은 `profile_in_use` 로 끝난다.
fn onAlreadyRunningAppRelaunch(
    _: [*c]c.cef_browser_process_handler_t,
    command_line: [*c]c.cef_command_line_t,
    _: [*c]const c.cef_string_t,
) callconv(.c) c_int {
    object.releaseArg(command_line);
    return 1;
}

fn onBeforeCommandLineProcessing(
    _: [*c]c.cef_app_t,
    process_type: [*c]const c.cef_string_t,
    command_line: [*c]c.cef_command_line_t,
) callconv(.c) void {
    // 빈 process_type 이 브라우저 프로세스다. helper 에게는 CEF 가 필요한 것만 넘긴다.
    if (process_type != null and process_type.*.length != 0) return;
    for (product_switches) |name| {
        var value: c.cef_string_t = std.mem.zeroes(c.cef_string_t);
        library.setString(api, &value, name);
        defer api.string_utf16_clear(&value);
        command_line.*.append_switch.?(command_line, &value);
    }
}
