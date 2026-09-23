//! `maru-web-helper` — CEF 의 렌더러·GPU·유틸리티 프로세스(W1b, docs/plans/web-osr-backend.md C1).
//!
//! 순서가 계약이다: ① `libcef_sandbox.dylib` 를 올려 `cef_sandbox_initialize` 로 샌드박스를 켠다 ② **그 뒤에**
//! 프레임워크를 dlopen 한다 ③ `cef_execute_process` 로 자식 역할을 한다. 프레임워크를 먼저 올리면(링크 시점 포함)
//! GPU 프로세스가 죽는다(§13.1 「남은 미해결」 1 — 실측). 샌드박스를 못 켜면 **샌드박스 없이 돌지 않고** 끝낸다 —
//! 이 프로세스는 신뢰할 수 없는 웹을 그린다.

const std = @import("std");
const cef = @import("cef.zig");
const library = @import("library.zig");
const layout = @import("layout.zig");

const SandboxInitialize = *const fn (argc: c_int, argv: [*c][*c]u8) callconv(.c) ?*anyopaque;

/// 샌드박스를 켜기 전에는 아무것도 하지 않도록 최소 진입점을 쓴다(할당자·Io 준비 없음).
pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    const argc: c_int = @intCast(argv.len);
    const argv_c: [*c][*c]u8 = @ptrCast(@constCast(argv.ptr));

    var dir_buf: layout.PathBuf = undefined;
    const dir = layout.executableDir(&dir_buf) catch return fail("실행 파일 경로를 못 구했다");

    var sandbox_path: layout.PathBuf = undefined;
    const sandbox_lib = layout.join(&sandbox_path, dir, layout.sandbox_library_rel) catch return fail("경로가 너무 길다");
    const sandbox_handle = std.c.dlopen(sandbox_lib, .{ .NOW = true, .LOCAL = true }) orelse return fail("libcef_sandbox 를 못 열었다");
    const sandbox_symbol = std.c.dlsym(sandbox_handle, "cef_sandbox_initialize") orelse return fail("cef_sandbox_initialize 가 없다");
    const sandbox_initialize: SandboxInitialize = @ptrCast(@alignCast(sandbox_symbol));
    // 돌려받는 문맥은 프로세스가 끝날 때까지 쥔다 — 풀면 샌드박스가 풀린다.
    if (sandbox_initialize(argc, argv_c) == null) return fail("샌드박스를 켜지 못했다");

    var framework_path: layout.PathBuf = undefined;
    const framework = layout.join(&framework_path, dir, layout.framework_dir_name ++ "/" ++ layout.framework_binary_name) catch return fail("경로가 너무 길다");
    const api = library.load(framework) catch return fail("프레임워크를 못 열었다");

    // 다른 어떤 CEF 호출보다 먼저 API 버전을 등록한다(첫 호출 뒤의 값은 무시된다 — cef_api_hash.h).
    _ = api.api_hash(cef.api_version, 0);
    var main_args: cef.c.cef_main_args_t = .{ .argc = argc, .argv = argv_c };
    const code = api.execute_process(&main_args, null, null);
    return @intCast(std.math.clamp(code, 0, 255));
}

fn fail(reason: []const u8) u8 {
    std.debug.print("maru-web-helper: {s}\n", .{reason});
    return 1;
}
