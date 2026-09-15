//! `unsetenv` 뒤에 std 의 debug Io 가 붙잡은 **환경 조각을 갱신**한다.
//!
//! std 는 프로세스 시작 시 envp 조각(포인터+길이)을 `Io.Threaded.global_single_threaded.environ` 에
//! 붙잡아 두고(`start.zig` `callMainWithArgs`), stderr 를 처음 잠글 때 그 조각을 훑어 `NO_COLOR` 같은
//! 변수를 읽는다(`initLockedStderr → scanEnviron → scan`). 그런데 macOS libc 의 `unsetenv` 는 `environ`
//! 배열을 **제자리에서 줄인다.** 그러면 std 가 붙잡은 옛 길이만큼 훑을 때 끝에 null 이 나오고,
//! `scan` 의 `opt_entry.?` 가 「attempt to use null value」로 프로세스를 죽인다.
//!
//! 호스트는 시작하자마자 `MARU_SESSION_HOST_STARTUP_FD` 를 읽고 지운다(`startup_readiness`). 그
//! 순간부터 호스트 안의 **첫 `std.log` 가 곧 크래시**였다 — `host_log` 가 `std.log` 를 금지해야 했던
//! 이유, 과거 로그 3건이 `enqueueCommand` 에서 죽은 이유, 그리고 `DebugAllocator` 의 누수 보고가
//! 자연 종료 때 한 줄도 못 남기고 죽던 이유가 전부 이것이다(실측 2026-09-15: 누수 하나를 심고 자연
//! 종료시키면 `deinit → detectLeaks → std.log.terminalMode → lockStderr → scan` 에서 죽고 `leaked`
//! 는 0줄).
//!
//! 독립 프로브로 기전을 확정했다: 지울 변수가 없으면 살고, 있으면 같은 프레임에서 죽고, `setenv` 로
//! 늘리는 건 무해하며, 지운 직후 이 모듈처럼 조각을 갈아 끼우면 산다.
//!
//! 그래서 호스트에서 **존재하는 변수를 지울 때는 반드시 이 모듈을 거친다.** 지우는 것과 갱신을 한
//! 함수에 묶어 두는 이유는, 둘을 따로 부르게 두면 한쪽만 고쳐지는 날 판정자가 공허해지기 때문이다.
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern var environ: [*:null]?[*:0]u8;

/// 환경변수를 지우고, std 의 debug Io 가 보는 환경 조각을 지금의 `environ` 으로 갈아 끼운다.
pub fn unsetenvKeepingStdView(name: [*:0]const u8) void {
    _ = unsetenv(name);
    refreshStdDebugView();
}

/// std 의 debug Io 가 붙잡은 환경 조각을 현재 `environ` 으로 갈아 끼운다. `unsetenv` 를 직접 부른
/// 자리가 있다면 그 뒤에 이걸 불러야 한다 — 다만 그런 자리는 두지 말고 `unsetenvKeepingStdView` 를
/// 써라.
///
/// 루트가 `std_options_debug_threaded_io` 로 다른 Io 를 꽂았다면(`null` 포함) 손댈 조각이 없으므로
/// 아무것도 하지 않는다.
pub fn refreshStdDebugView() void {
    if (builtin.os.tag == .windows) return; // Windows 는 PEB 를 직접 읽어 조각을 안 붙잡는다.
    const t = std.Options.debug_threaded_io orelse return;
    t.environ = .{ .process_environ = .{ .block = .{ .slice = std.mem.span(environ) } } };
    t.environ_initialized = false;
}

/// 판정자용: std 의 debug Io 가 지금 붙잡고 있는 환경 조각.
pub fn stdDebugViewSlice() ?[:null]const ?[*:0]const u8 {
    if (builtin.os.tag == .windows) return null;
    const t = std.Options.debug_threaded_io orelse return null;
    return t.environ.process_environ.block.slice;
}

fn sliceHasNullEntry(slice: [:null]const ?[*:0]const u8) bool {
    for (slice) |entry| if (entry == null) return true;
    return false;
}

/// 판정자 전제: 앞선 테스트가 std 뷰를 결함 상태(길이 안에 null)로 남겨 두지 않았다. 이 모듈의 규칙을 자기
/// 테스트가 어기면 여기서 걸린다 — 어느 테스트가 먼저 돌든.
fn expectViewHasNoNull() !void {
    const s = stdDebugViewSlice() orelse return;
    try std.testing.expect(!sliceHasNullEntry(s));
}

test "unsetenv 만 하면 std 의 조각 끝에 null 이 생기고, 갱신하면 사라진다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try expectViewHasNoNull();
    // 먼저 조각을 **현재** `environ` 배열에 맞춘다. std 가 시작 때 붙잡은 것은 커널이 준 원본인데, 이 프로세스에서
    // 누가 먼저 `setenv` 를 했으면 libc 는 자기 사본으로 갈아탄 뒤라 원본은 더 이상 안 건드린다 — 그러면 아래
    // 부정 대조가 «null 이 안 생긴다» 로 어긋난다(단독 실행에서 실제로 그랬다). 결함의 본질은 「libc 가 고치는
    // 배열과 std 가 보는 조각이 같은 길이로 어긋난다」이므로, 같은 배열을 보게 맞춰 놓고 시작해야 순서와 무관하다.
    refreshStdDebugView();
    const before = stdDebugViewSlice() orelse return error.SkipZigTest;
    if (before.len == 0) return error.SkipZigTest;

    // 시작 시 조각에 실제로 들어 있던 첫 변수를 고른다 — 지금 setenv 로 더한 변수는 옛 조각에
    // 없어서 지워도 옛 조각이 안 줄어든다. 그래서 «있던 것»을 지워야 결함이 드러난다.
    const first = before[0] orelse return error.SkipZigTest;
    const pair = std.mem.span(first);
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.SkipZigTest;
    var name_buf: [512]u8 = undefined;
    var value_buf: [4096]u8 = undefined;
    if (eq >= name_buf.len or pair.len - eq - 1 >= value_buf.len) return error.SkipZigTest;
    const name = try std.fmt.bufPrintZ(&name_buf, "{s}", .{pair[0..eq]});
    const value = try std.fmt.bufPrintZ(&value_buf, "{s}", .{pair[eq + 1 ..]});
    defer {
        _ = setenv(name.ptr, value.ptr, 1);
        refreshStdDebugView();
    }

    // **부정 대조** — 결함 그대로: 지우기만 하면 옛 조각(길이 그대로) 끝에 null 이 들어온다.
    // 이것이 없으면 아래 「갱신하면 null 이 없다」는 「원래 없었다」로 공허하게 통과한다.
    const before_len = before.len;
    _ = unsetenv(name.ptr);
    const stale = stdDebugViewSlice() orelse return error.SkipZigTest;
    try std.testing.expectEqual(before_len, stale.len);
    try std.testing.expect(sliceHasNullEntry(stale));

    // 처방: 조각을 갈아 끼우면 길이가 하나 줄고 null 이 없다.
    refreshStdDebugView();
    const fresh = stdDebugViewSlice() orelse return error.SkipZigTest;
    try std.testing.expectEqual(before_len - 1, fresh.len);
    try std.testing.expect(!sliceHasNullEntry(fresh));
}

test "unsetenvKeepingStdView 는 변수를 실제로 지우고 조각도 함께 갱신한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try expectViewHasNoNull();
    refreshStdDebugView(); // 위 테스트와 같은 이유 — 순서와 무관하게 현재 배열에서 시작한다.
    const before = stdDebugViewSlice() orelse return error.SkipZigTest;
    if (before.len == 0) return error.SkipZigTest;
    const first = before[0] orelse return error.SkipZigTest;
    const pair = std.mem.span(first);
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.SkipZigTest;
    var name_buf: [512]u8 = undefined;
    var value_buf: [4096]u8 = undefined;
    if (eq >= name_buf.len or pair.len - eq - 1 >= value_buf.len) return error.SkipZigTest;
    const name = try std.fmt.bufPrintZ(&name_buf, "{s}", .{pair[0..eq]});
    const value = try std.fmt.bufPrintZ(&value_buf, "{s}", .{pair[eq + 1 ..]});
    defer {
        _ = setenv(name.ptr, value.ptr, 1);
        refreshStdDebugView();
    }

    const before_len = before.len;
    unsetenvKeepingStdView(name.ptr);
    try std.testing.expect(std.c.getenv(name.ptr) == null);
    const fresh = stdDebugViewSlice() orelse return error.SkipZigTest;
    try std.testing.expectEqual(before_len - 1, fresh.len);
    try std.testing.expect(!sliceHasNullEntry(fresh));
}

test "앞서 setenv 로 libc 가 사본으로 갈아탄 뒤에도 같은 대조가 선다 — 단독 실행에서 어긋났던 그 조건" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try expectViewHasNoNull();
    // libc 를 먼저 사본 상태로 만든다(새 이름 추가). 이 뒤로 std 의 원본 조각과 libc 배열은 다른 메모리다.
    try std.testing.expectEqual(@as(c_int, 0), setenv("MARU_STD_ENVIRON_VIEW_PRIME", "1", 1));
    // defer 는 역순이라 이 줄이 **마지막**에 풀린다 — 날것 `unsetenv` 로 두면 아래 defer 의 갱신 뒤에 PRIME 이
    // 제자리에서 지워져 std 뷰가 결함 상태 그대로 남는다(적대적 검증에서 잡혔다). 이 모듈의 규칙을 자기
    // 테스트가 어기면 안 된다.
    defer unsetenvKeepingStdView("MARU_STD_ENVIRON_VIEW_PRIME");
    refreshStdDebugView();
    const before = stdDebugViewSlice() orelse return error.SkipZigTest;
    if (before.len == 0) return error.SkipZigTest;
    const first = before[0] orelse return error.SkipZigTest;
    const pair = std.mem.span(first);
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.SkipZigTest;
    var name_buf: [512]u8 = undefined;
    var value_buf: [4096]u8 = undefined;
    if (eq >= name_buf.len or pair.len - eq - 1 >= value_buf.len) return error.SkipZigTest;
    const name = try std.fmt.bufPrintZ(&name_buf, "{s}", .{pair[0..eq]});
    const value = try std.fmt.bufPrintZ(&value_buf, "{s}", .{pair[eq + 1 ..]});
    defer {
        _ = setenv(name.ptr, value.ptr, 1);
        refreshStdDebugView();
    }
    const before_len = before.len;
    _ = unsetenv(name.ptr);
    const stale = stdDebugViewSlice() orelse return error.SkipZigTest;
    try std.testing.expectEqual(before_len, stale.len);
    try std.testing.expect(sliceHasNullEntry(stale));
    refreshStdDebugView();
    const fresh = stdDebugViewSlice() orelse return error.SkipZigTest;
    try std.testing.expectEqual(before_len - 1, fresh.len);
    try std.testing.expect(!sliceHasNullEntry(fresh));
}
