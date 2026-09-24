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
extern "c" fn sandbox_check(pid: c_int, operation: ?[*:0]const u8, kind: c_int) c_int;

/// 샌드박스를 켜기 전에는 아무것도 하지 않도록 최소 진입점을 쓴다(할당자·Io 준비 없음).
pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    const argc: c_int = @intCast(argv.len);
    const argv_c: [*c][*c]u8 = @ptrCast(@constCast(argv.ptr));

    var dir_buf: layout.PathBuf = undefined;
    const dir = layout.executableDir(&dir_buf) catch return fail("cannot resolve the executable path");

    var sandbox_path: layout.PathBuf = undefined;
    const sandbox_lib = layout.join(&sandbox_path, dir, layout.sandbox_library_rel) catch return fail("path too long");
    const sandbox_handle = std.c.dlopen(sandbox_lib, .{ .NOW = true, .LOCAL = true }) orelse return fail("cannot open libcef_sandbox");
    const sandbox_symbol = std.c.dlsym(sandbox_handle, "cef_sandbox_initialize") orelse return fail("cef_sandbox_initialize is missing");
    const sandbox_initialize: SandboxInitialize = @ptrCast(@alignCast(sandbox_symbol));
    // 돌려받는 문맥은 프로세스가 끝날 때까지 쥔다 — 풀면 샌드박스가 풀린다.
    if (sandbox_initialize(argc, argv_c) == null) return fail("sandbox initialization failed");
    // `cef_sandbox_initialize` 는 샌드박스를 요청받지 않은(브라우저가 `--seatbelt-client` 를 안 준) helper 에게도 성공을
    // 돌려준다(적대 검증 실측) — 그러면 샌드박스 없이 프레임워크를 올린다. 실제로 샌드박스 안인지 확인하고, 아니면 끝낸다.
    if (sandbox_check(std.c.getpid(), null, 0) != 1) {
        std.debug.print("maru-web-helper: sandbox is not active after initialization ({s} {s})\n", .{ argValue(argv, "--type="), argValue(argv, "--utility-sub-type=") });
        return 1;
    }

    var framework_path: layout.PathBuf = undefined;
    const framework = layout.join(&framework_path, dir, layout.framework_dir_name ++ "/" ++ layout.framework_binary_name) catch return fail("path too long");
    const api = library.load(framework) catch return fail("cannot open the CEF framework");

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

/// 진단용 — `--type=` 같은 인자의 값(없으면 빈 글).
fn argValue(argv: []const [*:0]const u8, prefix: []const u8) []const u8 {
    for (argv) |raw| {
        const arg = std.mem.span(raw);
        if (std.mem.startsWith(u8, arg, prefix)) return arg[prefix.len..];
    }
    return "";
}
