//! **앱이 받은 이미지 세그먼트 fd 가 자식 프로세스로 새는 spawn 이 0 인가**(docs/session-host-image-channel.md §7, 계획 IC4).
//!
//! 앱은 이미지 채널로 공유 메모리 fd 를 받는다. macOS 에는 `MSG_CMSG_CLOEXEC` 가 없어 받은 fd 는 `F_SETFD` 까지 CLOEXEC 가 꺼져
//! 있고, 그 틈은 fork 울타리(`session_host/fork_fd_fence.zig` — `pthread_atfork` 의 읽기 잠금)가 덮는다. 그런데 `posix_spawn`
//! 계열(Darwin `system()` 포함)은 **atfork 를 부르지 않는다** — 헬퍼 밖 호출 하나가 울타리를 건너 받은 fd 를 자식에게 넘긴다(오래
//! 사는 자식이 물려받으면 host 원장은 반환됐는데 메모리는 계속 붙잡힌다).
//!
//! 그래서 `posix_spawn`·`posix_spawnp`·`system` 은 `POSIX_SPAWN_CLOEXEC_DEFAULT` 헬퍼(`src/pty/macos_spawn.zig`) 밖에서 부르지
//! 않는다. fork(·`std.process.spawn` — Zig 0.16 은 fork 로 띄운다)는 울타리가 덮으므로 여기서 세지 않는다.
//!
//! **세는 것**(최상위 test 블록 밖):
//! - `posix_spawn`·`posix_spawnp`·`popen`(Darwin `popen` 은 안에서 posix_spawn 을 쓴다) 식별자 — 뒤 토큰과 상관없이. 별칭
//!   (`const ps = std.c.posix_spawn;`)·함수 포인터·`@call` 로도 피하지 못한다.
//! - `system` 식별자 바로 뒤의 `(` — 호출과 extern 선언(`.system` 열거 값은 흔해서 이름만으로는 안 센다).
//! - `@field(…, "posix_spawn")` 처럼 이름을 문자열로 꺼내는 자리.
//! 주석·문자열(그 밖의)은 토크나이저가 거른다. 허용 재고는 **파일·개수·이유**로 박는다 — 개수가 늘어도 줄어도 빨갛다.

const std = @import("std");

const Allowed = struct { path: []const u8, count: usize, why: []const u8 };

const allowed = [_]Allowed{
    .{ .path = "src/pty/macos_spawn.zig", .count = 1, .why = "헬퍼 자신 — CLOEXEC_DEFAULT 를 켜고 stdio 만 넘긴다" },
    .{ .path = "src/main.zig", .count = 4, .why = "`maru` CLI 프로세스(`maru terminfo` 의 `system` 선언 하나·호출 셋) — 이미지 채널을 협상하지 않아 받은 fd 가 없다" },
};

/// 이름만으로 센다(어디에 쓰여도 부를 뜻이다).
const always = [_][]const u8{ "posix_spawn", "posix_spawnp", "popen" };
/// 바로 뒤에 `(` 가 올 때만 센다.
const called = [_][]const u8{"system"};
/// `@field(…, "<이름>")` 으로 꺼내도 센다.
const by_name = [_][]const u8{ "\"posix_spawn\"", "\"posix_spawnp\"", "\"popen\"", "\"system\"" };

fn isOneOf(text: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, text, name)) return true;
    return false;
}

/// 최상위 test 블록 밖의 spawn 자리 수.
fn countSpawnCalls(source: [:0]const u8) usize {
    var tokenizer = std.zig.Tokenizer.init(source);
    var brace_depth: usize = 0;
    var waiting_for_test_body = false;
    var test_body_depth: ?usize = null;
    var pending_watched = false;
    // `@field` 다음의 `(`·첫 인자·`,` 를 지나 문자열 인자를 기다린다.
    var field_stage: u8 = 0;
    var count: usize = 0;
    while (true) {
        const token = tokenizer.next();
        const was_pending = pending_watched;
        pending_watched = false;
        const in_product = test_body_depth == null;
        if (token.tag == .builtin and std.mem.eql(u8, source[token.loc.start..token.loc.end], "@field")) {
            field_stage = 1;
        } else if (field_stage == 1) {
            field_stage = if (token.tag == .l_paren) 2 else 0;
        } else if (field_stage == 2) {
            if (token.tag == .comma) field_stage = 3;
        } else if (field_stage == 3) {
            if (token.tag == .string_literal and in_product and isOneOf(source[token.loc.start..token.loc.end], &by_name)) count += 1;
            field_stage = 0;
        }
        switch (token.tag) {
            .eof => return count,
            .keyword_test => if (brace_depth == 0 and test_body_depth == null) {
                waiting_for_test_body = true;
            },
            .l_brace => {
                brace_depth += 1;
                if (waiting_for_test_body) {
                    test_body_depth = brace_depth;
                    waiting_for_test_body = false;
                }
            },
            .r_brace => {
                if (test_body_depth != null and test_body_depth.? == brace_depth) test_body_depth = null;
                if (brace_depth > 0) brace_depth -= 1;
            },
            .identifier => {
                const text = source[token.loc.start..token.loc.end];
                if (in_product and isOneOf(text, &always)) count += 1;
                if (in_product and isOneOf(text, &called)) pending_watched = true;
            },
            .l_paren => if (was_pending) {
                count += 1;
            },
            else => {},
        }
    }
}

fn readZigFileZ(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buffer = try allocator.allocSentinel(u8, @intCast(stat.size), 0);
    errdefer allocator.free(buffer);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(buffer);
    return buffer;
}

fn collectZigFiles(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => {
                defer allocator.free(child);
                try collectZigFiles(allocator, io, child, out);
            },
            .file => if (std.mem.endsWith(u8, entry.name, ".zig")) {
                try out.append(allocator, child);
            } else allocator.free(child),
            else => allocator.free(child),
        }
    }
}

test "spawn cloexec axis: the scanner counts calls, declarations, aliases and by-name lookups, not test bodies, comments or strings" {
    try std.testing.expectEqual(@as(usize, 2), countSpawnCalls(
        \\extern "c" fn system(command: [*:0]const u8) c_int;
        \\fn f() void { _ = std.c.posix_spawnp(a, b, c, d, e, f); }
        \\fn g() void { _ = .system; const x = "system(1)"; } // system(2)
        \\test "t" { _ = system("x"); _ = posix_spawn(a, b, c, d, e, f); }
    ));
    // 별칭·`@call`·`popen`·이름 문자열로도 피하지 못한다.
    try std.testing.expectEqual(@as(usize, 4), countSpawnCalls(
        \\const ps = std.c.posix_spawn;
        \\fn h() void { _ = @call(.auto, std.c.posix_spawnp, .{}); _ = popen("ls", "r"); }
        \\fn k() void { _ = @field(std.c, "system")("ls"); _ = @field(theme, "light"); }
    ));
}

test "spawn cloexec axis: no app code spawns outside the CLOEXEC_DEFAULT helper" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try collectZigFiles(allocator, io, "src", &paths);
    try std.testing.expect(paths.items.len > 100);

    var failed = false;
    var seen: [allowed.len]bool = @splat(false);
    for (paths.items) |path| {
        const source = try readZigFileZ(allocator, io, path);
        defer allocator.free(source);
        const count = countSpawnCalls(source);
        var expected: usize = 0;
        var why: []const u8 = "";
        for (allowed, 0..) |entry, i| if (std.mem.eql(u8, entry.path, path)) {
            seen[i] = true;
            expected = entry.count;
            why = entry.why;
        };
        if (count != expected) {
            failed = true;
            std.debug.print(
                \\
                \\[spawn cloexec 축] {s}: `posix_spawn`·`posix_spawnp`·`system` 호출·선언이 {d} 곳(재고 {d}).
                \\  앱 코드는 `maru.pty.macos_spawn`(CLOEXEC_DEFAULT)으로 띄운다 — posix_spawn 계열은 fork 울타리를 지나지 않아
                \\  이미지 채널로 받은 fd 를 자식에게 넘긴다(docs/session-host-image-channel.md §7).
                \\  앱이 아닌 프로세스라면 재고에 **이유와 함께** 개수를 올려라. 재고 사유: {s}
                \\
            , .{ path, count, expected, why });
        }
    }
    for (allowed, 0..) |entry, i| if (!seen[i]) {
        failed = true;
        std.debug.print("\n[spawn cloexec 축] 재고의 {s} 가 없다 — 재고를 고쳐라.\n", .{entry.path});
    };
    try std.testing.expect(!failed);
}

test "spawn cloexec axis: the app installs the fork fence before any session exists" {
    // fork 쪽 절반 — 울타리(`pthread_atfork`)는 앱 세션을 만들 때 받은 fd 가 생기기 전에 건다. 이 한 줄이 빠지면 fork 가 수신
    // 창을 기다리지 않는다(fork 울타리 판정자는 모듈 단독으로 재므로 앱이 설치하는지는 못 본다).
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = try readZigFileZ(allocator, io, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(source);
    const entry = std.mem.indexOf(u8, source, "pub export fn maru_macos_app_session_create(") orelse return error.TestUnexpectedResult;
    const body_end = std.mem.indexOfPos(u8, source, entry, "\n}\n") orelse return error.TestUnexpectedResult;
    const body = source[entry..body_end];
    const install_at = std.mem.indexOf(u8, body, "fork_fd_fence." ++ "install();") orelse return error.TestUnexpectedResult;
    // 세션을 만들기(`session.init`) 전이다.
    const init_at = std.mem.indexOf(u8, body, "session.init(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(install_at < init_at);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "fork_fd_fence." ++ "install();"));
}
