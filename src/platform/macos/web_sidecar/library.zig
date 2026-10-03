//! CEF 프레임워크를 dlopen 하고 쓰는 함수만 찾는다(W1b). 링크 시점에 붙이지 않는 이유는 둘이다 — helper 는 샌드박스를
//! 켠 **뒤에** 프레임워크를 올려야 하고(docs/plans/web-osr-backend.md C1 — 링크하면 dyld 가 먼저 올려 GPU 가 죽었다),
//! 빌드가 프레임워크 바이너리 없이 헤더만으로 끝난다.

const std = @import("std");
const c = @import("cef.zig").c;

/// 쓰는 함수만 찾는다. 타입은 헤더 선언에서 그대로 가져와 서명이 어긋나면 컴파일이 멈춘다.
pub const Api = struct {
    api_hash: *const @TypeOf(c.cef_api_hash),
    execute_process: *const @TypeOf(c.cef_execute_process),
    initialize: *const @TypeOf(c.cef_initialize),
    run_message_loop: *const @TypeOf(c.cef_run_message_loop),
    quit_message_loop: *const @TypeOf(c.cef_quit_message_loop),
    shutdown: *const @TypeOf(c.cef_shutdown),
    post_task: *const @TypeOf(c.cef_post_task),
    string_utf8_to_utf16: *const @TypeOf(c.cef_string_utf8_to_utf16),
    string_utf16_clear: *const @TypeOf(c.cef_string_utf16_clear),
    string_utf16_to_utf8: *const @TypeOf(c.cef_string_utf16_to_utf8),
    string_utf8_clear: *const @TypeOf(c.cef_string_utf8_clear),
    get_exit_code: *const @TypeOf(c.cef_get_exit_code),
    post_delayed_task: *const @TypeOf(c.cef_post_delayed_task),
    browser_host_create_browser_sync: *const @TypeOf(c.cef_browser_host_create_browser_sync),
    request_context_get_global_context: *const @TypeOf(c.cef_request_context_get_global_context),
    value_create: *const @TypeOf(c.cef_value_create),
    // 파일 선택(W5a) — 고른 경로를 CEF 에 넘기고 받을 형식을 읽는다.
    string_list_alloc: *const @TypeOf(c.cef_string_list_alloc),
    string_list_append: *const @TypeOf(c.cef_string_list_append),
    string_list_free: *const @TypeOf(c.cef_string_list_free),
    string_list_size: *const @TypeOf(c.cef_string_list_size),
    string_list_value: *const @TypeOf(c.cef_string_list_value),
    // 대화상자 제목의 출처(W5a) — 사용자 정보·경로를 떼고 IDN 은 안전할 때만 유니코드로(Chrome 의 보안 표시 규칙).
    format_url_for_security_display: *const @TypeOf(c.cef_format_url_for_security_display),
    string_userfree_utf16_free: *const @TypeOf(c.cef_string_userfree_utf16_free),
    // 웹 알림(W5c) — helper(렌더러)가 대리 스크립트에 네이티브 함수를 넘기고 프로세스 메시지를 보낸다.
    v8_value_create_function: *const @TypeOf(c.cef_v8_value_create_function),
    v8_value_create_int: *const @TypeOf(c.cef_v8_value_create_int),
    v8_context_get_current_context: *const @TypeOf(c.cef_v8_context_get_current_context),
    process_message_create: *const @TypeOf(c.cef_process_message_create),
};

pub const LoadError = error{ FrameworkOpenFailed, SymbolMissing };

pub fn load(framework_binary: [*:0]const u8) LoadError!Api {
    const handle = std.c.dlopen(framework_binary, .{ .NOW = true, .LOCAL = true }) orelse return error.FrameworkOpenFailed;
    return .{
        .api_hash = try find(handle, "cef_api_hash", @TypeOf(c.cef_api_hash)),
        .execute_process = try find(handle, "cef_execute_process", @TypeOf(c.cef_execute_process)),
        .initialize = try find(handle, "cef_initialize", @TypeOf(c.cef_initialize)),
        .run_message_loop = try find(handle, "cef_run_message_loop", @TypeOf(c.cef_run_message_loop)),
        .quit_message_loop = try find(handle, "cef_quit_message_loop", @TypeOf(c.cef_quit_message_loop)),
        .shutdown = try find(handle, "cef_shutdown", @TypeOf(c.cef_shutdown)),
        .post_task = try find(handle, "cef_post_task", @TypeOf(c.cef_post_task)),
        .string_utf8_to_utf16 = try find(handle, "cef_string_utf8_to_utf16", @TypeOf(c.cef_string_utf8_to_utf16)),
        .string_utf16_clear = try find(handle, "cef_string_utf16_clear", @TypeOf(c.cef_string_utf16_clear)),
        .string_utf16_to_utf8 = try find(handle, "cef_string_utf16_to_utf8", @TypeOf(c.cef_string_utf16_to_utf8)),
        .string_utf8_clear = try find(handle, "cef_string_utf8_clear", @TypeOf(c.cef_string_utf8_clear)),
        .get_exit_code = try find(handle, "cef_get_exit_code", @TypeOf(c.cef_get_exit_code)),
        .post_delayed_task = try find(handle, "cef_post_delayed_task", @TypeOf(c.cef_post_delayed_task)),
        .browser_host_create_browser_sync = try find(handle, "cef_browser_host_create_browser_sync", @TypeOf(c.cef_browser_host_create_browser_sync)),
        .request_context_get_global_context = try find(handle, "cef_request_context_get_global_context", @TypeOf(c.cef_request_context_get_global_context)),
        .value_create = try find(handle, "cef_value_create", @TypeOf(c.cef_value_create)),
        .string_list_alloc = try find(handle, "cef_string_list_alloc", @TypeOf(c.cef_string_list_alloc)),
        .string_list_append = try find(handle, "cef_string_list_append", @TypeOf(c.cef_string_list_append)),
        .string_list_free = try find(handle, "cef_string_list_free", @TypeOf(c.cef_string_list_free)),
        .string_list_size = try find(handle, "cef_string_list_size", @TypeOf(c.cef_string_list_size)),
        .string_list_value = try find(handle, "cef_string_list_value", @TypeOf(c.cef_string_list_value)),
        .format_url_for_security_display = try find(handle, "cef_format_url_for_security_display", @TypeOf(c.cef_format_url_for_security_display)),
        .string_userfree_utf16_free = try find(handle, "cef_string_userfree_utf16_free", @TypeOf(c.cef_string_userfree_utf16_free)),
        .v8_value_create_function = try find(handle, "cef_v8_value_create_function", @TypeOf(c.cef_v8_value_create_function)),
        .v8_value_create_int = try find(handle, "cef_v8_value_create_int", @TypeOf(c.cef_v8_value_create_int)),
        .v8_context_get_current_context = try find(handle, "cef_v8_context_get_current_context", @TypeOf(c.cef_v8_context_get_current_context)),
        .process_message_create = try find(handle, "cef_process_message_create", @TypeOf(c.cef_process_message_create)),
    };
}

fn find(handle: *anyopaque, name: [*:0]const u8, comptime F: type) LoadError!*const F {
    const symbol = std.c.dlsym(handle, name) orelse return error.SymbolMissing;
    return @ptrCast(@alignCast(symbol));
}

/// UTF-8 을 CEF 문자열(UTF-16)로 옮긴다. `out` 은 호출자가 `api.string_utf16_clear` 로 비운다.
pub fn setString(api: *const Api, out: *c.cef_string_t, value: []const u8) void {
    _ = api.string_utf8_to_utf16(value.ptr, value.len, out);
}

/// CEF 문자열(UTF-16)을 `out` 에 UTF-8 로 옮긴다. 넘치면 글자 경계에서 자르고, 제어 문자는 바꾼다 — codec 이 제어
/// 문자가 든 글을 거절하므로(W1a) 그대로 보내면 `document.title = "a\x07b"` 같은 제목이 조용히 사라진다.
pub fn readString(api: *const Api, value: [*c]const c.cef_string_t, out: []u8) []const u8 {
    if (value == null or value.*.str == null) return out[0..0];
    var utf8: c.cef_string_utf8_t = std.mem.zeroes(c.cef_string_utf8_t);
    _ = api.string_utf16_to_utf8(value.*.str, value.*.length, &utf8);
    defer api.string_utf8_clear(&utf8);
    if (utf8.str == null) return out[0..0];
    const clamped = protocol_text.clampUtf8(utf8.str[0..utf8.length], out.len);
    @memcpy(out[0..clamped.len], clamped);
    protocol_text.replaceControl(out[0..clamped.len]);
    return out[0..clamped.len];
}

/// 대화상자 글(W5a) — `readString` 과 같되 탭·줄바꿈은 남긴다(대화상자 문구는 여러 줄이 흔하다).
pub fn readDialogString(api: *const Api, value: [*c]const c.cef_string_t, out: []u8) []const u8 {
    if (value == null or value.*.str == null) return out[0..0];
    var utf8: c.cef_string_utf8_t = std.mem.zeroes(c.cef_string_utf8_t);
    _ = api.string_utf16_to_utf8(value.*.str, value.*.length, &utf8);
    defer api.string_utf8_clear(&utf8);
    if (utf8.str == null) return out[0..0];
    const clamped = protocol_text.clampUtf8(utf8.str[0..utf8.length], out.len);
    @memcpy(out[0..clamped.len], clamped);
    protocol_text.replaceControlKeepLines(out[0..clamped.len]);
    return out[0..clamped.len];
}

const protocol_text = @import("web_sidecar_protocol").text;
