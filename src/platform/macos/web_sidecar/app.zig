//! sidecar 의 `cef_app_t`(W1b). 브라우저 프로세스 명령줄에 제품 스위치를 넣는다.
//!
//! `use-mock-keychain`(D7, docs/plans/web-osr-backend.md) — 진짜 Keychain 을 쓰면 항목 이름이 Chromium 브라우저와 같은
//! 「Chromium Safe Storage」이고, 소스 빌드는 업그레이드마다 서명이 바뀌어 허용 창이 반복될 수 있으며, 거부·실패하면
//! 쿠키가 조용히 저장되지 않는다(실측). 이 스위치면 Keychain 을 건드리지 않고 재시작 뒤에도 로그인이 남았다(실측).

const std = @import("std");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");

var app: c.cef_app_t = undefined;
var api: *const library.Api = undefined;

pub const product_switches = [_][]const u8{"use-mock-keychain"};

/// 프로세스 수명 동안 사는 앱 객체를 돌려준다. `cef_initialize` 전에 한 번 부른다.
pub fn get(loaded: *const library.Api) *c.cef_app_t {
    api = loaded;
    app = object.zeroed(c.cef_app_t);
    object.staticRefCounted(&app.base);
    app.on_before_command_line_processing = &onBeforeCommandLineProcessing;
    return &app;
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
