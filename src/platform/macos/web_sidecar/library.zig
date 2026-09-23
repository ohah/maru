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
