//! **테스트는 환경 변수를 `getenv` 포인터로 되돌리지 않는다** — 값을 복사해 둔다(`src/platform/macos/test_env.zig`).
//!
//! `std.c.getenv` 가 준 포인터를 들고 있다가 `setenv(name, 그 포인터)` 로 되돌리면, 앞선 테스트가 그 변수를 한 번이라도
//! `setenv` 한 뒤에는 되돌리지 못한다 — macOS libc 가 그 버퍼를 제자리에서 덮어써 포인터가 새 값(이 테스트의 tmp 경로)을
//! 가리킨다(실측 2026-10-07: 두 번째 복원 뒤 `XDG_CACHE_HOME` 이 `/tmp/maru-B-tmp` 로 남았다). 그런 자리가 16 곳이었다.
//!
//! 규칙: `src/`·`tests/` 의 모든 `.zig` 에서 `const <v> = std.c.getenv("<NAME>");` 을 찾고, 그 뒤에 `setenv("<NAME>", <v>` 또는
//! `if (<v>) |<c>|` 의 `setenv("<NAME>", <c>` 가 나오면 위반이다. 탐지기가 비어 통과하지 않도록 합성 표본을 먼저 잡게 한다.

const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;
const window_bytes = 4000;

fn identAt(src: []const u8, at: usize) []const u8 {
    var end = at;
    while (end < src.len and (std.ascii.isAlphanumeric(src[end]) or src[end] == '_')) end += 1;
    return src[at..end];
}

/// `src` 안의 위반 자리 수. `getenv` 한 자리에 위반이 여럿이어도 한 번만 센다.
fn countPointerRestores(src: []const u8) usize {
    const open = "const ";
    const call = " = std.c.getenv(\"";
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, call)) |at| : (i = at + call.len) {
        const line_start = (std.mem.lastIndexOfScalar(u8, src[0..at], '\n') orelse 0);
        const decl = std.mem.indexOfPos(u8, src, line_start, open) orelse continue;
        if (decl > at) continue;
        const var_name = src[decl + open.len .. at];
        const name_start = at + call.len;
        const name_end = std.mem.indexOfScalarPos(u8, src, name_start, '"') orelse continue;
        const env_name = src[name_start..name_end];
        const window = src[name_end..@min(src.len, name_end + window_bytes)];
        var needle_buf: [256]u8 = undefined;
        // ① 직접: `setenv("NAME", v`
        const direct = std.fmt.bufPrint(&needle_buf, "setenv(\"{s}\", {s}", .{ env_name, var_name }) catch continue;
        if (std.mem.indexOf(u8, window, direct) != null) {
            count += 1;
            continue;
        }
        // ② 캡처: `if (v) |c|` … `setenv("NAME", c` — 단, 그 사이에 같은 이름의 캡처 `|c|` 가 **다시 열리면** 그 setenv 의
        // `c` 는 원래 포인터가 아니다(값을 복사해 둔 뒤 그 복사본을 같은 이름으로 여는 꼴 — `app_host_abi.zig`·`app_session.zig`).
        var cap_buf: [256]u8 = undefined;
        const cap_open = std.fmt.bufPrint(&cap_buf, "if ({s}) |", .{var_name}) catch continue;
        if (std.mem.indexOf(u8, window, cap_open)) |c_at| {
            const cap = identAt(window, c_at + cap_open.len);
            if (cap.len == 0) continue;
            const via = std.fmt.bufPrint(&needle_buf, "setenv(\"{s}\", {s}", .{ env_name, cap }) catch continue;
            const after_cap = c_at + cap_open.len + cap.len;
            const via_at = std.mem.indexOfPos(u8, window, after_cap, via) orelse continue;
            var bar_buf: [258]u8 = undefined;
            const rebound = std.fmt.bufPrint(&bar_buf, "|{s}|", .{cap}) catch continue;
            if (std.mem.indexOf(u8, window[after_cap..via_at], rebound) == null) count += 1;
        }
    }
    return count;
}

test "test env restore: no test keeps a getenv pointer to restore an environment variable" {
    // 탐지기 자체가 그 꼴을 잡는다 — 셋 다(직접·캡처+else·defer 블록) 예전 소스에 실제로 있던 모양이다.
    const bad_capture =
        \\    const saved = std.c.getenv("HOME");
        \\    defer if (saved) |v| {
        \\        _ = setenv("HOME", v, 1);
        \\    } else {
        \\        _ = unsetenv("HOME");
        \\    };
    ;
    const bad_block =
        \\        const prev_cache = std.c.getenv("XDG_CACHE_HOME");
        \\        defer {
        \\            if (prev_cache) |old| {
        \\                _ = app_session_mod.setenv("XDG_CACHE_HOME", old, 1);
        \\            }
        \\        }
    ;
    const bad_direct =
        \\    const had = std.c.getenv("MARU_CONFIG");
        \\    defer _ = setenv("MARU_CONFIG", had.?, 1);
    ;
    const good =
        \\    const saved = test_env.Saved.save("HOME");
        \\    defer saved.restore();
        \\    const v = std.c.getenv("HOME"); // 읽기만 한다
        \\    _ = v;
    ;
    try std.testing.expectEqual(@as(usize, 1), countPointerRestores(bad_capture));
    try std.testing.expectEqual(@as(usize, 1), countPointerRestores(bad_block));
    try std.testing.expectEqual(@as(usize, 1), countPointerRestores(bad_direct));
    // 값을 복사한 뒤 그 복사본을 **같은 캡처 이름**으로 여는 꼴은 위반이 아니다(제품 소스에 실제로 있는 두 모양).
    const good_copy_same_capture =
        \\    const saved_home = std.c.getenv("HOME");
        \\    const saved: ?[:0]const u8 = if (saved_home) |h| std.fmt.bufPrintZ(&saved_buf, "{s}", .{std.mem.span(h)}) catch null else null;
        \\    defer {
        \\        if (saved) |h| _ = setenv("HOME", h.ptr, 1) else _ = unsetenv("HOME");
        \\    }
    ;
    try std.testing.expectEqual(@as(usize, 0), countPointerRestores(good));
    try std.testing.expectEqual(@as(usize, 0), countPointerRestores(good_copy_same_capture));

    const allocator = std.testing.allocator;
    var scanned: usize = 0;
    var violations: usize = 0;
    for ([_][]const u8{ "src", "tests" }) |root| {
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            // 이 판정자 자신은 표본을 문자열로 든다.
            if (std.mem.eql(u8, root, "tests") and std.mem.eql(u8, entry.path, "test_env_restore_copies_boundary.zig")) continue;
            const src = try dir.readFileAlloc(std.testing.io, entry.path, allocator, .limited(max_source_bytes));
            defer allocator.free(src);
            scanned += 1;
            const n = countPointerRestores(src);
            if (n > 0) std.debug.print("getenv-pointer restore: {s}/{s} ({d})\n", .{ root, entry.path, n });
            violations += n;
        }
    }
    // 훑은 파일 수로 「아무것도 안 봤다」를 막는다(cwd 가 저장소 뿌리가 아니면 0 이다).
    try std.testing.expect(scanned > 500);
    try std.testing.expectEqual(@as(usize, 0), violations);
}
